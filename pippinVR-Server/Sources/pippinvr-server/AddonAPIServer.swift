import Darwin
import Foundation
import ImageIO
@preconcurrency import Network
import Security

@MainActor
final class AddonAPIServer: ObservableObject {
    static let shared = AddonAPIServer()
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var error: String?
    @Published private(set) var port: UInt16?
    @Published private(set) var cameraAccess = false
    private let queue = DispatchQueue(label: "com.pippinvr.addon-api")
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var token = ""
    private var generation = UUID()
    private var lockFD: Int32 = -1
    private var statusProvider: (() -> Bool)?
    private var cameraAllowedProvider: (() -> Bool)?
    private var createDisplay: ((Int) throws -> UInt32)?
    private var removeDisplay: ((UInt32) -> Void)?
    private let directory: URL
    private let panels: URL
    private let maxLine = 65536
    private let maxClients = 8
    private let maxPanels = 8
    private var lastImageUpdate: Date?
    private var audioOwner: UUID?
    private var audioSequence: UInt64 = 0
    private var cameraCleanup: DispatchSourceTimer?
    private var inputCleanup: DispatchSourceTimer?

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var panels: [String: URL] = [:]
        var models: [String: (request: URL, status: URL, revision: String)] = [:]
        var displays: [String: UInt32] = [:]
        var panelSpecs: [String: AddonManifest.Panel] = [:]
        var images: [String: URL] = [:]
        var lastImageUpdate: [String: Date] = [:]
        var eventOffset: UInt64 = 0
        var eventIdentity: UInt64?
        var eventPartial = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(directory: URL? = nil, panels: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PippinVR/API", isDirectory: true)
        self.panels = panels ?? DirectMetricsStore.stateDirectory.appendingPathComponent("ui/panels", isDirectory: true)
    }
    private var modelDirectory: URL { panels.deletingLastPathComponent().appendingPathComponent("api-models", isDirectory: true) }
    private var modelStatusDirectory: URL { panels.deletingLastPathComponent().appendingPathComponent("api-model-status", isDirectory: true) }
    private var inputDirectory: URL { panels.deletingLastPathComponent().appendingPathComponent("api-input", isDirectory: true) }
    private var cameraDirectory: URL { panels.deletingLastPathComponent().appendingPathComponent("api-camera", isDirectory: true) }
    private var audioDirectory: URL { panels.deletingLastPathComponent().appendingPathComponent("addon-audio", isDirectory: true) }
    private var infoURL: URL { directory.appendingPathComponent("connection.json") }
    private var eventURL: URL { panels.deletingLastPathComponent().appendingPathComponent("events.jsonl") }
    private func eventAttributes() -> (size: UInt64, identity: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: eventURL.path),
              let size = attrs[.size] as? NSNumber, let identity = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return (size.uint64Value, identity.uint64Value)
    }

    func start(cameraAllowed: @escaping () -> Bool = { false }, createDisplay: ((Int) throws -> UInt32)? = nil,
               removeDisplay: ((UInt32) -> Void)? = nil, status: @escaping () -> Bool) {
        guard listener == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard chmod(directory.path, 0o700) == 0 else { throw APIError.message("Cannot protect API directory.") }
            lockFD = open(directory.appendingPathComponent("server.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                if lockFD >= 0 { close(lockFD); lockFD = -1 }
                throw APIError.message("Another PippinVR API is already running.")
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: panels, includingPropertiesForKeys: nil) {
                for url in files where url.pathExtension == "json" {
                    let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
                    guard parts.count == 3, parts[0] == "pippin-api", UUID(uuidString: parts[1]) != nil,
                          !parts[2].isEmpty,
                          parts[2].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }) else { continue }
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in files where url.pathExtension == "image" {
                    let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
                    guard parts.count == 3, parts[0] == "pippin-api", UUID(uuidString: parts[1]) != nil,
                          !parts[2].isEmpty,
                          parts[2].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }) else { continue }
                    try? FileManager.default.removeItem(at: url)
                }
            }
            for location in [modelDirectory, modelStatusDirectory] {
                if let files = try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil) {
                    for url in files where url.pathExtension == "json" {
                        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "--")
                        guard parts.count == 3, parts[0] == "pippin-api", UUID(uuidString: parts[1]) != nil,
                              !parts[2].isEmpty, parts[2].unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }) else { continue }
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw APIError.message("Could not create an API credential.")
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            statusProvider = status
            cameraAllowedProvider = cameraAllowed
            self.createDisplay = createDisplay
            self.removeDisplay = removeDisplay
            clearCameraFiles()
            clearInputFiles()
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let newListener = try NWListener(using: params, on: .any)
            let activeGeneration = UUID()
            generation = activeGeneration
            listener = newListener
            starting = true
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection, generation: activeGeneration) }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.listenerState(state, generation: activeGeneration) }
            }
            error = nil
            newListener.start(queue: queue)
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        if lockFD >= 0 {
            setCameraAccess(false)
            inputCleanup?.cancel(); inputCleanup = nil
            clearInputFiles()
        }
        generation = UUID()
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { removeClient(id) }
        if lockFD >= 0 {
            try? FileManager.default.removeItem(at: infoURL)
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
        token = ""
        port = nil
        running = false
        starting = false
        statusProvider = nil
        cameraAllowedProvider = nil
        createDisplay = nil
        removeDisplay = nil
        lastImageUpdate = nil
        audioOwner = nil
    }

    private func listenerState(_ state: NWListener.State, generation: UUID) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            guard let listeningPort = listener?.port?.rawValue else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "host": "127.0.0.1", "port": listeningPort, "token": token])
                try data.write(to: infoURL, options: .atomic)
                guard chmod(infoURL.path, 0o600) == 0 else { throw APIError.message("Cannot protect API connection file.") }
                port = listeningPort
                starting = false
                running = true
            } catch { stop(); self.error = error.localizedDescription }
        case let .failed(failure): stop(); error = failure.localizedDescription
        default: break
        }
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard generation == self.generation, running, clients.count < maxClients else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection)
        if let attributes = eventAttributes() { client.eventOffset = attributes.size; client.eventIdentity = attributes.identity }
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor [weak self] in self?.removeClient(id) } }
            if case .cancelled = state { Task { @MainActor [weak self] in self?.removeClient(id) } }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, failure in
            Task { @MainActor [weak self] in
                guard let self, let client = self.clients[id] else { return }
                if let data { client.buffer.append(data) }
                while let newline = client.buffer.firstIndex(of: 10) {
                    let line = Data(client.buffer[..<newline])
                    client.buffer.removeSubrange(...newline)
                    guard line.count <= self.maxLine else { self.removeClient(id); return }
                    self.handle(line, clientID: id)
                    guard self.clients[id] != nil else { return }
                }
                if client.buffer.count > self.maxLine || complete || failure != nil { self.removeClient(id); return }
                self.receive(id)
            }
        }
    }

    private func handle(_ data: Data, clientID: UUID) {
        guard let client = clients[clientID],
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let requestID = request["id"] as? String, !requestID.isEmpty, requestID.utf8.count <= 64,
              let suppliedToken = request["token"] as? String, suppliedToken == token,
              let apiVersion = request["apiVersion"] as? Int, apiVersion == 1,
              let method = request["method"] as? String else { removeClient(clientID); return }
        do {
            var result: [String: Any] = [:]
            switch method {
            case "status":
                var capabilities = ["status", "panel.set", "panel.remove", "panel.image", "panel.decoration", "events.poll", "audio.push", "audio.spatial", "audio.release", "camera.frame", "input.controllers", "model.load", "model.status", "model.remove", "model.attach"]
                if createDisplay != nil && removeDisplay != nil { capabilities += ["display.create", "display.remove"] }
                result = ["sessionRunning": statusProvider?() ?? false, "capabilities": capabilities, "cameraAccess": cameraAccess && (cameraAllowedProvider?() ?? false)]
            case "display.create":
                guard statusProvider?() == true, let createDisplay, removeDisplay != nil else { throw APIError.message("Desktop displays are unavailable. Connect Direct USB first.") }
                guard let id = request["displayId"] as? String, (1...48).contains(id.utf8.count),
                      id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }),
                      let index = request["index"] as? Int, (0..<24).contains(index), client.displays[id] == nil,
                      client.displays.count < 24 else { throw APIError.message("Invalid or duplicate display ID, position, or display limit reached.") }
                let displayID = try createDisplay(index)
                client.displays[id] = displayID
                result = ["displayID": displayID]
            case "display.remove":
                guard let id = request["displayId"] as? String, let displayID = client.displays.removeValue(forKey: id) else { throw APIError.message("Display not found.") }
                removeDisplay?(displayID)
            case "input.controllers":
                guard statusProvider?() == true else { clearInputFiles(); throw APIError.message("Start a Direct USB session first.") }
                try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard chmod(inputDirectory.path, 0o700) == 0 else { throw APIError.message("Cannot protect controller bridge.") }
                let lease = generation.uuidString
                let marker = inputDirectory.appendingPathComponent("controllers.request")
                try Data(lease.utf8).write(to: marker, options: .atomic)
                guard chmod(marker.path, 0o600) == 0 else { throw APIError.message("Cannot protect controller request.") }
                startInputCleanup()
                let file = inputDirectory.appendingPathComponent("controllers.json")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let date = attrs[.modificationDate] as? Date, abs(date.timeIntervalSinceNow) < 0.5,
                   let data = try? Data(contentsOf: file), data.count <= 16384,
                   var snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   snapshot["lease"] as? String == lease {
                    snapshot.removeValue(forKey: "lease")
                    snapshot["available"] = true
                    result = snapshot
                } else { result = ["available": false] }
            case "camera.frame":
                guard cameraAccess, cameraAllowedProvider?() == true else {
                    setCameraAccess(false)
                    throw APIError.message("Enable API camera access in settings first.")
                }
                guard statusProvider?() == true else { clearCameraFiles(); throw APIError.message("Start a Direct USB session first.") }
                guard let eye = request["eye"] as? String, ["left", "right"].contains(eye) else {
                    throw APIError.message("Choose the left or right camera.")
                }
                try FileManager.default.createDirectory(at: cameraDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard chmod(cameraDirectory.path, 0o700) == 0 else { throw APIError.message("Cannot protect camera bridge.") }
                let lease = generation.uuidString
                let marker = cameraDirectory.appendingPathComponent(eye + ".request")
                try Data(lease.utf8).write(to: marker, options: .atomic)
                guard chmod(marker.path, 0o600) == 0 else { throw APIError.message("Cannot protect camera request.") }
                let frame = cameraDirectory.appendingPathComponent(eye + ".json")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: frame.path),
                   let modified = attrs[.modificationDate] as? Date, abs(modified.timeIntervalSinceNow) < 1.0,
                   let bytes = try? Data(contentsOf: frame), bytes.count <= 50000,
                   var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                   object["lease"] as? String == lease {
                    object.removeValue(forKey: "lease")
                    object["available"] = true
                    result = object
                } else { result = ["available": false, "eye": eye] }
            case "model.load":
                guard statusProvider?() == true else { throw APIError.message("Start a Direct USB session first.") }
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
                guard let modelID = request["modelId"] as? String, (1...48).contains(modelID.utf8.count),
                      modelID.first != "-", modelID.last != "-", modelID.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                      let path = request["path"] as? String, path.hasPrefix("/"), path.utf8.count <= 4096,
                      !path.contains("\0"), ["usdz", "usd", "usda", "usdc", "obj", "gltf", "glb"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                    throw APIError.message("Expected a valid model ID and absolute USDZ, OBJ, glTF or GLB path.")
                }
                guard client.models[modelID] == nil, client.models.count < 4 else { throw APIError.message("Model ID already exists or connection model limit reached.") }
                let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular, FileManager.default.isReadableFile(atPath: source.path),
                      let size = attrs[.size] as? NSNumber, size.uint64Value > 0, size.uint64Value <= 512 * 1024 * 1024 else {
                    throw APIError.message("Model must be a readable file no larger than 512 MiB.")
                }
                let rotation = request["rotation"] as? [String: Any] ?? ["mode": "fixed"]
                guard request["rotation"] == nil || request["rotation"] is [String: Any],
                      let mode = rotation["mode"] as? String, ["fixed", "spin", "faceUser"].contains(mode) else { throw APIError.message("Invalid model rotation.") }
                let speedValue = rotation["degreesPerSecond"] ?? 30
                guard let speed = speedValue as? NSNumber, CFGetTypeID(speed) != CFBooleanGetTypeID(), speed.doubleValue.isFinite, abs(speed.doubleValue) <= 180 else {
                    throw APIError.message("Rotation speed must be between -180 and 180 degrees per second.")
                }
                var parentName: String?
                var requestedSize: Double?
                if let value = request["panelId"] {
                    guard let panelID = value as? String, let panelURL = client.panels[panelID] else {
                        throw APIError.message("The model must attach to a panel owned by this connection.")
                    }
                    parentName = panelURL.deletingPathExtension().lastPathComponent
                    let value = request["size"] ?? 0.22
                    guard let size = value as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(), size.doubleValue.isFinite, (0.05...1).contains(size.doubleValue) else {
                        throw APIError.message("Attached model size must be 0.05–1 meter.")
                    }
                    requestedSize = size.doubleValue
                } else if request["size"] != nil {
                    throw APIError.message("Model size requires a panel attachment.")
                }
                for location in [modelDirectory, modelStatusDirectory] {
                    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    guard chmod(location.path, 0o700) == 0 else { throw APIError.message("Cannot protect model bridge.") }
                }
                let name = "pippin-api--\(clientID.uuidString.lowercased())--\(modelID).json"
                let modelURL = modelDirectory.appendingPathComponent(name)
                let statusURL = modelStatusDirectory.appendingPathComponent(name)
                let revision = UUID().uuidString
                var payload: [String: Any] = ["path": source.path, "revision": revision, "rotation": ["mode": mode, "degreesPerSecond": speed]]
                if let parentName, let requestedSize { payload["parentPanel"] = parentName; payload["size"] = requestedSize }
                let data = try JSONSerialization.data(withJSONObject: payload)
                try? FileManager.default.removeItem(at: statusURL)
                try data.write(to: modelURL, options: .atomic)
                guard chmod(modelURL.path, 0o600) == 0 else { try? FileManager.default.removeItem(at: modelURL); throw APIError.message("Cannot protect model request.") }
                client.models[modelID] = (modelURL, statusURL, revision)
                result = ["state": "pending"]
            case "model.status":
                guard statusProvider?() == true else { throw APIError.message("Start a Direct USB session first.") }
                guard let id = request["modelId"] as? String, let model = client.models[id] else { throw APIError.message("Model not found.") }
                if let data = try? Data(contentsOf: model.status), data.count <= 4096,
                   var state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], state["revision"] as? String == model.revision {
                    state.removeValue(forKey: "revision"); result = state
                } else { result = ["state": "pending"] }
            case "model.remove":
                guard let id = request["modelId"] as? String, let model = client.models[id] else { throw APIError.message("Model not found.") }
                try FileManager.default.removeItem(at: model.request)
                try? FileManager.default.removeItem(at: model.status)
                client.models.removeValue(forKey: id)
            case "panel.set":
                guard let panelID = request["panelId"] as? String,
                      let rawPanel = request["panel"] as? [String: Any],
                      let panelData = try? JSONSerialization.data(withJSONObject: rawPanel),
                      let panel = try? JSONDecoder().decode(AddonManifest.Panel.self, from: panelData) else {
                    throw APIError.message("Invalid panel data.")
                }
                let manifest = AddonManifest(apiVersion: 1, id: panelID, name: "API panel", version: "1", description: "", panel: panel)
                try manifest.validate()
                guard client.panels[panelID] != nil || client.panels.count < maxPanels else { throw APIError.message("Panel limit reached.") }
                try FileManager.default.createDirectory(at: panels, withIntermediateDirectories: true)
                let name = "pippin-api--\(clientID.uuidString.lowercased())--\(panelID)"
                let url = panels.appendingPathComponent(name + ".json")
                if client.panels[panelID] == nil && FileManager.default.fileExists(atPath: url.path) { throw APIError.message("Panel already exists.") }
                try writePanel(panel, image: client.images[panelID], to: url)
                client.panels[panelID] = url
                client.panelSpecs[panelID] = panel
                result = ["panel": name]
            case "panel.image":
                if let last = lastImageUpdate, Date().timeIntervalSince(last) < 0.55 {
                    throw APIError.message("Total image updates are limited to 4 per second.")
                }
                guard let panelID = request["panelId"] as? String, let url = client.panels[panelID],
                      let panel = client.panelSpecs[panelID], let encoded = request["data"] as? String,
                      encoded.utf8.count <= 49152, let image = Data(base64Encoded: encoded),
                      image.count <= 36864, let source = CGImageSourceCreateWithData(image as CFData, nil),
                      CGImageSourceGetCount(source) == 1,
                      let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      (1...2048).contains(width), (1...2048).contains(height), width * height <= 2_000_000,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    throw APIError.message("Expected a valid PNG or JPEG under 36 KiB and 2 megapixels for an owned panel.")
                }
                if let last = client.lastImageUpdate[panelID], Date().timeIntervalSince(last) < 0.5 {
                    throw APIError.message("Image updates are limited to 2 per second per panel.")
                }
                let imageURL = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).image")
                try image.write(to: imageURL, options: .atomic)
                do { try writePanel(panel, image: imageURL, to: url) } catch {
                    if client.images[panelID] == nil { try? FileManager.default.removeItem(at: imageURL) }
                    throw error
                }
                client.images[panelID] = imageURL
                client.lastImageUpdate[panelID] = Date()
                lastImageUpdate = Date()
                result = ["width": width, "height": height]
            case "audio.push", "audio.spatial":
                guard statusProvider?() == true else { throw APIError.message("Start a Direct USB session first.") }
                guard audioOwner == nil || audioOwner == clientID else { throw APIError.message("Another client is using add-on audio.") }
                let spatial = method == "audio.spatial"
                let blockBytes = spatial ? 1920 : 3840
                guard let encoded = request["data"] as? String, encoded.utf8.count <= 40960,
                      let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= blockBytes * 8,
                      data.count % blockBytes == 0 else {
                    throw APIError.message("Expected 10–80 ms of 48 kHz float32 PCM in 10 ms blocks.")
                }
                var spatialData: Data?
                if spatial {
                    func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
                        guard let value = request[key] else { return fallback }
                        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                              n.doubleValue.isFinite, range.contains(n.doubleValue) else {
                            throw APIError.message("Invalid spatial audio parameter: \(key).")
                        }
                        return n.doubleValue
                    }
                    guard request["mode"] == nil || request["mode"] is String else { throw APIError.message("Invalid spatial audio mode.") }
                    let mode = request["mode"] as? String ?? "hrtf"
                    guard ["hrtf", "hrtfHQ", "cues"].contains(mode) else { throw APIError.message("Invalid spatial audio mode.") }
                    let x = try number("x", default: 0, range: -100...100)
                    let y = try number("y", default: 0, range: -100...100)
                    let z = try number("z", default: -1, range: -100...100)
                    guard mode == "cues" || x*x + y*y + z*z >= 0.0001 else { throw APIError.message("HRTF source position must be away from the listener.") }
                    let payload: [String: Any] = ["mode": mode, "x": x, "y": y, "z": z,
                        "itdUs": try number("itdUs", default: 0, range: -2000...2000),
                        "ildDb": try number("ildDb", default: 0, range: -24...24),
                        "gain": try number("gain", default: 1, range: 0...1),
                        "referenceDistance": try number("referenceDistance", default: 1, range: 0.01...100),
                        "rolloff": try number("rolloff", default: 1, range: 0...10), "data": encoded]
                    spatialData = try JSONSerialization.data(withJSONObject: payload)
                }
                let valid = data.withUnsafeBytes { bytes in
                    stride(from: 0, to: bytes.count, by: 4).allSatisfy { offset in
                        let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        let sample = Float(bitPattern: bits)
                        return sample.isFinite && abs(sample) <= 1
                    }
                }
                guard valid else { throw APIError.message("Audio samples must be finite and between -1 and 1.") }
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard chmod(audioDirectory.path, 0o700) == 0 else { throw APIError.message("Cannot protect audio queue.") }
                let prefix = clientID.uuidString.lowercased() + "--"
                let pending = (try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)).filter { $0.hasPrefix(prefix) && ($0.hasSuffix(".pcm") || $0.hasSuffix(".spatial")) }
                guard pending.count < 4 else { throw APIError.message("Audio queue full; retry after playback catches up.") }
                audioSequence &+= 1
                let name = prefix + String(format: "%020llu", audioSequence) + (spatial ? ".spatial" : ".pcm")
                try (spatialData ?? data).write(to: audioDirectory.appendingPathComponent(name), options: .atomic)
                audioOwner = clientID
                result = ["framesQueued": data.count / (spatial ? 4 : 8)]
            case "audio.release":
                guard audioOwner == nil || audioOwner == clientID else { throw APIError.message("Another client is using add-on audio.") }
                clearAudio(clientID)
            case "events.poll":
                result = ["events": try pollEvents(client)]
            case "panel.remove":
                guard let panelID = request["panelId"] as? String, let url = client.panels[panelID] else { throw APIError.message("Panel not found.") }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                client.panels.removeValue(forKey: panelID)
                client.panelSpecs.removeValue(forKey: panelID)
                if let image = client.images.removeValue(forKey: panelID) { try? FileManager.default.removeItem(at: image) }
                client.lastImageUpdate.removeValue(forKey: panelID)
            default: throw APIError.message("Unknown method.")
            }
            send(["id": requestID, "ok": true, "result": result], to: client)
        } catch { send(["id": requestID, "ok": false, "error": error.localizedDescription], to: client) }
    }

    private func startInputCleanup() {
        guard inputCleanup == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let marker = self.inputDirectory.appendingPathComponent("controllers.request")
                let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path)
                if let date = attrs?[.modificationDate] as? Date, abs(date.timeIntervalSinceNow) <= 2 { return }
                self.clearInputFiles()
                self.inputCleanup?.cancel(); self.inputCleanup = nil
            }
        }
        inputCleanup = timer
        timer.resume()
    }

    private func clearInputFiles() {
        for name in ["controllers.request", "controllers.json"] {
            try? FileManager.default.removeItem(at: inputDirectory.appendingPathComponent(name))
        }
    }

    func setCameraAccess(_ enabled: Bool) {
        cameraAccess = enabled && running && (cameraAllowedProvider?() ?? false)
        if cameraAccess, cameraCleanup == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.clearExpiredCameraFiles() }
            }
            cameraCleanup = timer
            timer.resume()
        } else if !cameraAccess {
            cameraCleanup?.cancel()
            cameraCleanup = nil
            clearCameraFiles()
        }
    }

    private func clearExpiredCameraFiles() {
        for eye in ["left", "right"] {
            let marker = cameraDirectory.appendingPathComponent(eye + ".request")
            let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path)
            if let date = attributes?[.modificationDate] as? Date, abs(date.timeIntervalSinceNow) <= 2 { continue }
            for suffix in [".request", ".json"] {
                try? FileManager.default.removeItem(at: cameraDirectory.appendingPathComponent(eye + suffix))
            }
        }
    }

    private func clearCameraFiles() {
        for eye in ["left", "right"] {
            for suffix in [".request", ".json"] {
                try? FileManager.default.removeItem(at: cameraDirectory.appendingPathComponent(eye + suffix))
            }
        }
    }

    private func writePanel(_ panel: AddonManifest.Panel, image: URL?, to url: URL) throws {
        let data = try JSONEncoder().encode(panel)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.message("Invalid panel data.")
        }
        if let image { object["image"] = image.path }
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    private func pollEvents(_ client: Client) throws -> [[String: Any]] {
        guard let attributes = eventAttributes() else {
            client.eventOffset = 0; client.eventIdentity = nil; client.eventPartial = Data()
            return []
        }
        if client.eventIdentity != attributes.identity || client.eventOffset > attributes.size {
            client.eventOffset = 0; client.eventPartial = Data()
        }
        client.eventIdentity = attributes.identity
        guard client.eventOffset < attributes.size else { return [] }
        let handle = try FileHandle(forReadingFrom: eventURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: client.eventOffset)
        let data = try handle.read(upToCount: 16384) ?? Data()
        client.eventOffset += UInt64(data.count)
        client.eventPartial.append(data)
        let owned = Set(client.panels.values.map { $0.deletingPathExtension().lastPathComponent })
        var events: [[String: Any]] = []
        while let newline = client.eventPartial.firstIndex(of: 10) {
            let line = Data(client.eventPartial[..<newline])
            client.eventPartial.removeSubrange(...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let panel = event["panel"] as? String, owned.contains(panel) else { continue }
            events.append(event)
        }
        if client.eventPartial.count > maxLine { client.eventPartial = Data() }
        return events
    }

    private func clearAudio(_ clientID: UUID) {
        guard audioOwner == clientID else { return }
        let prefix = clientID.uuidString.lowercased() + "--"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path) {
            for name in names where name.hasPrefix(prefix) && (name.hasSuffix(".pcm") || name.hasSuffix(".spatial")) {
                try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
            }
        }
        audioOwner = nil
        audioSequence &+= 1
    }

    private func send(_ object: [String: Any], to client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        client.connection.send(content: data + Data([10]), completion: .contentProcessed { _ in })
    }
    private func removeClient(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        if clients.isEmpty && lockFD >= 0 { clearCameraFiles(); clearInputFiles() }
        clearAudio(id)
        for display in client.displays.values { removeDisplay?(display) }
        for model in client.models.values {
            try? FileManager.default.removeItem(at: model.request)
            try? FileManager.default.removeItem(at: model.status)
        }
        for url in client.panels.values { try? FileManager.default.removeItem(at: url) }
        for url in client.images.values { try? FileManager.default.removeItem(at: url) }
    }
    private enum APIError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
