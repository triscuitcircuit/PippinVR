import AppKit
import Foundation
import UniformTypeIdentifiers

struct AddonManifest: Codable, Identifiable {
    struct Panel: Codable {
        struct Button: Codable {
            let id: String
            let label: String
        }
        struct Rotation: Codable {
            let mode: String
            let degreesPerSecond: Double?
        }
        struct Decoration: Codable {
            let shape: String
            let size: Double?
            let color: [Double]?
            let degreesPerSecond: Double?
        }
        let title: String
        let lines: [String]
        let buttons: [Button]
        let anchor: String?
        let position: [Double]?
        let orientation: [Double]?
        let rotation: Rotation?
        let decoration: Decoration?
    }
    let apiVersion: Int
    let id: String
    let name: String
    let version: String
    let description: String
    let panel: Panel?
    let entrypoint: String?

    init(apiVersion: Int, id: String, name: String, version: String, description: String, panel: Panel?, entrypoint: String? = nil) {
        self.apiVersion = apiVersion; self.id = id; self.name = name; self.version = version
        self.description = description; self.panel = panel; self.entrypoint = entrypoint
    }

    func validate() throws {
        guard apiVersion == 1 else { throw AddonError.invalid("This add-on requires an unsupported API version.") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...48).contains(id.utf8.count), id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              id.first != "-", id.last != "-" else {
            throw AddonError.invalid("The add-on ID must use lowercase letters, numbers, and hyphens.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !version.isEmpty, version.count <= 40, description.count <= 240,
              (panel == nil) != (entrypoint == nil) else {
            throw AddonError.invalid("An add-on must contain either a panel or an executable entry point.")
        }
        if let entrypoint {
            let pieces = entrypoint.split(separator: "/", omittingEmptySubsequences: false)
            guard !entrypoint.hasPrefix("/"), entrypoint.utf8.count <= 512,
                  pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !entrypoint.contains("\0") else { throw AddonError.invalid("Invalid add-on entry point.") }
            return
        }
        guard let panel, !panel.title.isEmpty, panel.title.count <= 80,
              panel.lines.count <= 16, panel.lines.allSatisfy({ $0.count <= 120 }),
              panel.buttons.count <= 9,
              panel.buttons.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && !$0.label.isEmpty && $0.label.count <= 40 }),
              Set(panel.buttons.map(\.id)).count == panel.buttons.count,
              panel.anchor == nil || ["world", "head", "dashboard"].contains(panel.anchor!),
              panel.position == nil || (panel.position!.count == 3 && panel.position!.allSatisfy { $0.isFinite && abs($0) <= 5 }),
              panel.orientation == nil || (panel.orientation!.count == 4 && panel.orientation!.allSatisfy { $0.isFinite && abs($0) <= 1 } && abs(panel.orientation!.reduce(0) { $0 + $1 * $1 } - 1) <= 0.001),
              panel.rotation == nil || (["fixed", "spin", "faceUser"].contains(panel.rotation!.mode) && (panel.rotation!.degreesPerSecond == nil || (panel.rotation!.degreesPerSecond!.isFinite && abs(panel.rotation!.degreesPerSecond!) <= 180))),
              panel.decoration == nil || (["cube", "cutCube", "fractal"].contains(panel.decoration!.shape) &&
                  (panel.decoration!.size == nil || (panel.decoration!.size!.isFinite && (0.04...0.3).contains(panel.decoration!.size!))) &&
                  (panel.decoration!.color == nil || (panel.decoration!.color!.count == 3 && panel.decoration!.color!.allSatisfy { $0.isFinite && (0...1).contains($0) })) &&
                  (panel.decoration!.degreesPerSecond == nil || (panel.decoration!.degreesPerSecond!.isFinite && abs(panel.decoration!.degreesPerSecond!) <= 180))) else {
            throw AddonError.invalid("The add-on has invalid panel details.")
        }
    }
}

enum AddonError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct InstalledAddon: Codable, Identifiable {
    let manifest: AddonManifest
    var enabled: Bool
    var autoStart: Bool?
    var id: String { manifest.id }
}

@MainActor
final class AddonManager: ObservableObject {
    static let shared = AddonManager()
    @Published private(set) var addons: [InstalledAddon] = []
    @Published private(set) var runningIDs: Set<String> = []
    @Published private(set) var stoppingIDs: Set<String> = []
    @Published private(set) var processErrors: [String: String] = [:]
    private var processes: [String: Process] = [:]
    private let files: FileManager
    private let registry: URL
    private let panels: URL

    init(files: FileManager = .default, registry: URL? = nil, panels: URL? = nil) {
        self.files = files
        self.registry = registry ?? files.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PippinVR/Addons", isDirectory: true)
        self.panels = panels ?? DirectMetricsStore.stateDirectory.appendingPathComponent("ui/panels", isDirectory: true)
        reload()
    }

    private func recordURL(_ id: String) -> URL { registry.appendingPathComponent(id + ".json") }
    private func packageURL(_ id: String) -> URL { registry.appendingPathComponent("Packages", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    private func panelURL(_ id: String) -> URL { panels.appendingPathComponent("pippin-addon--" + id + ".json") }

    func reload() {
        let urls = (try? files.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []
        addons = urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url), data.count <= 65536,
                  let item = try? JSONDecoder().decode(InstalledAddon.self, from: data),
                  (try? item.manifest.validate()) != nil,
                  url.lastPathComponent == item.id + ".json" else { return nil }
            return item
        }.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    private func executable(_ entrypoint: String, inside root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = base.appendingPathComponent(entrypoint).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/"),
              (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              files.isExecutableFile(atPath: target.path) else {
            throw AddonError.invalid("The entry point must be an executable file inside the add-on folder.")
        }
        return target
    }

    func install(from url: URL) throws {
        let sourceInfo = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard sourceInfo.isSymbolicLink != true else { throw AddonError.invalid("Choose the add-on folder itself, not a symbolic link.") }
        let folder = sourceInfo.isDirectory == true
        let manifestURL = folder ? url.appendingPathComponent("pippin-addon.json") : url
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let fileSize = size.fileSize, fileSize <= 65536 else {
            throw AddonError.invalid("Choose a manifest under 64 KB or a folder containing pippin-addon.json.")
        }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 65536 else { throw AddonError.invalid("The add-on manifest is too large.") }
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
        try manifest.validate()
        guard !files.fileExists(atPath: recordURL(manifest.id).path),
              !files.fileExists(atPath: panelURL(manifest.id).path),
              !files.fileExists(atPath: packageURL(manifest.id).path) else {
            throw AddonError.invalid("An add-on or panel with this ID already exists.")
        }
        if let entrypoint = manifest.entrypoint {
            guard folder else { throw AddonError.invalid("Choose the add-on folder so its files can be installed.") }
            _ = try executable(entrypoint, inside: url)
        }
        try files.createDirectory(at: registry, withIntermediateDirectories: true)
        try files.createDirectory(at: panels, withIntermediateDirectories: true)
        let destination = packageURL(manifest.id)
        do {
            if manifest.entrypoint != nil {
                try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: url, to: destination)
                _ = try executable(manifest.entrypoint!, inside: destination)
            }
            let item = InstalledAddon(manifest: manifest, enabled: false)
            try JSONEncoder().encode(item).write(to: recordURL(item.id), options: .atomic)
        } catch {
            if manifest.entrypoint != nil { try? files.removeItem(at: destination) }
            throw error
        }
        reload()
    }

    func run(id: String) throws {
        guard let item = addons.first(where: { $0.id == id }), let entrypoint = item.manifest.entrypoint else {
            throw AddonError.invalid("Executable add-on not found.")
        }
        guard processes[id] == nil else { throw AddonError.invalid("This add-on is already running.") }
        let root = packageURL(id)
        let executableURL = try executable(entrypoint, inside: root)
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.processes[id] === process else { return }
                let wasStopping = self.stoppingIDs.contains(id)
                self.processes.removeValue(forKey: id)
                self.runningIDs.remove(id)
                self.stoppingIDs.remove(id)
                if !wasStopping && process.terminationStatus != 0 {
                    self.processErrors[id] = "Add-on exited with status \(process.terminationStatus)."
                }
            }
        }
        try process.run()
        processErrors.removeValue(forKey: id)
        processes[id] = process
        runningIDs.insert(id)
    }

    func stop(id: String) {
        guard let process = processes[id], process.isRunning, !stoppingIDs.contains(id) else { return }
        stoppingIDs.insert(id)
        process.terminate()
    }

    func stopAll() { for id in Array(processes.keys) { stop(id: id) } }

    func setAutoStart(_ enabled: Bool, id: String) throws {
        guard let index = addons.firstIndex(where: { $0.id == id }), addons[index].manifest.entrypoint != nil else {
            throw AddonError.invalid("Executable add-on not found.")
        }
        var item = addons[index]
        item.autoStart = enabled
        try JSONEncoder().encode(item).write(to: recordURL(id), options: .atomic)
        reload()
    }

    func reportStartError(_ message: String, id: String) { processErrors[id] = message }

    func setEnabled(_ enabled: Bool, id: String) throws {
        guard let index = addons.firstIndex(where: { $0.id == id }) else { throw AddonError.invalid("Add-on not found.") }
        var item = addons[index]
        guard let panel = item.manifest.panel else { throw AddonError.invalid("Use Run to start this add-on.") }
        guard item.enabled != enabled else { return }
        let url = panelURL(id)
        if enabled {
            guard !files.fileExists(atPath: url.path) else { throw AddonError.invalid("The add-on's panel already exists.") }
            try files.createDirectory(at: panels, withIntermediateDirectories: true)
            try JSONEncoder().encode(panel).write(to: url, options: .atomic)
        } else if files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
        do {
            item.enabled = enabled
            try JSONEncoder().encode(item).write(to: recordURL(id), options: .atomic)
        } catch {
            if enabled { try? files.removeItem(at: url) } else { try? JSONEncoder().encode(panel).write(to: url, options: .atomic) }
            throw error
        }
        reload()
    }

    func remove(id: String) throws {
        guard let item = addons.first(where: { $0.id == id }) else { throw AddonError.invalid("Add-on not found.") }
        guard processes[id] == nil else { throw AddonError.invalid("Stop the add-on before removing it.") }
        if item.enabled { try setEnabled(false, id: id) }
        try files.removeItem(at: recordURL(id))
        if item.manifest.entrypoint != nil, files.fileExists(atPath: packageURL(id).path) {
            try files.removeItem(at: packageURL(id))
        }
        processErrors.removeValue(forKey: id)
        reload()
    }

    func chooseManifest() throws {
        let picker = NSOpenPanel()
        picker.title = "Install PippinVR Add-on"
        picker.message = "Choose an add-on folder or a panel manifest (.json)."
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowedContentTypes = [.json, .folder]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        try install(from: url)
    }
}
