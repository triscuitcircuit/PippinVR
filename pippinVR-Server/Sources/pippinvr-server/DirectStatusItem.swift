import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DirectStatusItemController: NSObject, ObservableObject, DockOpenedFileReceiving {
    private var item: NSStatusItem?
    private var timer: Timer?
    private var requestTimer: Timer?
    private let session: DirectMonadoSession
    private var virtualDisplays: [VirtualDisplay] = []
    private var panelSources: [CGDirectDisplayID?] = [nil]
    private var captureFPS = UserDefaults.standard.integer(forKey: "directCaptureFPS") == 0 ? 30 : UserDefaults.standard.integer(forKey: "directCaptureFPS")
    private var panelWidth = UserDefaults.standard.integer(forKey: "directPanelWidth") == 0 ? 1024 : UserDefaults.standard.integer(forKey: "directPanelWidth")
    @Published var running = false
    @Published var panelCount = 1
    @Published var deviceInfo: [USBLinkSpeed.DeviceInfo] = []
    @Published var settingsMenu = NSMenu()
    @Published var apps: [AppEntry] = []
    @Published var environmentImageURL: URL?
    @Published var environmentFlippedVertically = false
    @Published var environmentFlippedHorizontally = false

    @Published var environmentModelURLs: [URL] = []

    private var sceneSyncedAt: Date?
    var hasEnvironmentModel: Bool { !environmentModelURLs.isEmpty }

    @Published var nextScreenWidth = UserDefaults.standard.integer(forKey: "directNextScreenWidth") == 0 ? 1920 : UserDefaults.standard.integer(forKey: "directNextScreenWidth") {
        didSet { UserDefaults.standard.set(nextScreenWidth, forKey: "directNextScreenWidth") }
    }
    @Published var nextScreenHeight = UserDefaults.standard.integer(forKey: "directNextScreenHeight") == 0 ? 1200 : UserDefaults.standard.integer(forKey: "directNextScreenHeight") {
        didSet { UserDefaults.standard.set(nextScreenHeight, forKey: "directNextScreenHeight") }
    }
    private var switchingApplication = false
    private var presentingPicker = false
    private var returnToDashboard = false
    private var settingsWindow: NSWindow?
    private var pendingDockOpenedFiles: [DockOpenedFile] = []
    private var dockOpenTimer: Timer?
    private var dockOpenWaitingForSession = false
    private var dockOpenNotBefore: Date?
    private var dockOpenPanelLimitNotified = false

    @Published var wristClockEnabled = DirectWristClockPreferences.enabled
    @Published var passthroughAllowed = DirectPassthroughPreferences.allowed
    @Published var passthroughEnabled = DirectPassthroughPreferences.enabled
    @Published var audioMode = DirectAudioPreferences.mode
    @Published var audioMacSpeakers = DirectAudioPreferences.macSpeakers
    @Published var audioStatus = DirectAudioPreferences.statusText
    @Published var showMetricsInVR = UserDefaults.standard.bool(forKey: "directShowMetricsInVR")
    @Published var metalFXEnabled = (UserDefaults.standard.object(forKey: "directMetalFXUpscale") as? Bool) ?? true
    @Published var metalFXScale: Double = {
        let stored = UserDefaults.standard.double(forKey: "directMetalFXScale")
        return [0, 1.25, 1.5, 2].contains(stored) ? stored : 0
    }()
    let metricsStore = DirectMetricsStore()
    private var nextSerial: UInt32 = 0x7000
    static let panelLimit = 24
    var maxPanels: Int { Self.panelLimit }

    init(session: DirectMonadoSession) { self.session = session }

    var configPath: String? { session.configPath }

    func install() {
        metricsStore.start()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        item?.button?.image = NSImage(systemSymbolName: "visionpro", accessibilityDescription: "PippinVR Direct USB")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "PippinVR Direct USB")
        item?.button?.image?.isTemplate = true
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self
            appMenu.insertItem(settings, at: 1)
        }
        requestTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for request in self.session.takeHostRequests() {
                    guard self.session.state.running else { continue }
                    if request == 3 || request >= 100 { self.launch3DApp(); continue }
                    if request == 4 { self.addMediaFile(); continue }
                    if request == 1 { self.addVirtualScreen() } else if request == 2 {
                        let item = NSMenuItem(); item.representedObject = "remove-last"
                        self.sendCommand(item)
                        self.session.command("notice:Last panel removed")
                    }
                }
            }
        }
        rebuild()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
        DockFileOpenRouter.shared.register(self)
    }

    func enqueueDockOpenedFiles(_ files: [DockOpenedFile]) {
        let valid = files.filter { file in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        guard !valid.isEmpty else { return }
        Logger.info("Dock open queued: \(valid.map { $0.url.lastPathComponent }.joined(separator: ", "))")
        pendingDockOpenedFiles.append(contentsOf: valid)

        if session.applicationName != nil {
            dockOpenWaitingForSession = true
            returnToDashboard = true
            if session.state.running { session.requestStop() }
        } else if !session.state.running {
            dockOpenWaitingForSession = true
            session.connect()
        }
        startDockOpenTimerIfNeeded()
        flushPendingDockOpenedFiles()
    }

    private func startDockOpenTimerIfNeeded() {
        guard dockOpenTimer == nil else { return }
        dockOpenTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushPendingDockOpenedFiles() }
        }
    }

    private func flushPendingDockOpenedFiles() {
        guard !pendingDockOpenedFiles.isEmpty else {
            dockOpenTimer?.invalidate()
            dockOpenTimer = nil
            dockOpenWaitingForSession = false
            dockOpenNotBefore = nil
            return
        }
        if session.applicationName != nil {
            dockOpenWaitingForSession = true
            returnToDashboard = true
            if session.state.running { session.requestStop() }
            return
        }
        guard session.state.running else { return }
        if dockOpenWaitingForSession {
            guard let dockOpenNotBefore else {
                dockOpenNotBefore = Date().addingTimeInterval(1)
                return
            }
            guard Date() >= dockOpenNotBefore else { return }
        }

        var delivered = 0
        while let file = pendingDockOpenedFiles.first {
            switch file.kind {
            case .model:
                session.command("environment-model:\(file.url.path)")
                environmentModelURLs.append(file.url)
            case .video:
                guard panelSources.count < maxPanels else {
                    if !dockOpenPanelLimitNotified {
                        session.command("notice:Panel limit reached — remove a panel to open the queued video")
                        dockOpenPanelLimitNotified = true
                    }
                    if delivered > 0 { rebuild() }
                    return
                }
                dockOpenPanelLimitNotified = false
                let entry = NSMenuItem()
                entry.representedObject = "add-media-file:\(file.url.path)"
                sendCommand(entry)
            }
            pendingDockOpenedFiles.removeFirst()
            delivered += 1
            Logger.info("Dock open delivered: \(file.url.lastPathComponent)")
        }

        dockOpenWaitingForSession = false
        dockOpenNotBefore = nil
        dockOpenTimer?.invalidate()
        dockOpenTimer = nil
        if delivered > 0 {
            session.command("notice:Opened \(delivered) file\(delivered == 1 ? "" : "s") from Dock")
            rebuild()
        }
    }

    private func action(_ title: String, _ command: String, menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: #selector(sendCommand(_:)), keyEquivalent: "")
        menu.autoenablesItems = false
        entry.target = self
        entry.representedObject = command
        entry.isEnabled = session.applicationName == nil && (command.hasPrefix("fps:") || command.hasPrefix("resolution:") || session.state.running) && (!command.hasPrefix("add-") && !command.hasPrefix("display:") || panelSources.count < maxPanels)
    }

    private func updateStatusColor(running: Bool, present: Bool) {
        item?.button?.setStatusDot(running && present ? .systemGreen : present ? .systemYellow : .systemRed)
    }

    private func rebuild() {
        wristClockEnabled = DirectWristClockPreferences.enabled
        passthroughAllowed = DirectPassthroughPreferences.allowed
        passthroughEnabled = DirectPassthroughPreferences.enabled

        if audioMode != DirectAudioPreferences.mode { audioMode = DirectAudioPreferences.mode }
        if audioMacSpeakers != DirectAudioPreferences.macSpeakers { audioMacSpeakers = DirectAudioPreferences.macSpeakers }
        let status = session.state.running ? DirectAudioPreferences.statusText : nil
        if audioStatus != status { audioStatus = status }
        syncSavedScene()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let present = USBLinkSpeed.detectQuestLinkSpeed() != nil
        let state = session.state
        updateStatusColor(running: state.running, present: present)
        if state.externallyActive {
            menu.addItem(withTitle: "Headset in use by another app (e.g. Godot Play)", action: nil, keyEquivalent: "")
            let waiting = menu.addItem(withTitle: "Waiting for it to finish…", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(.separator())
            let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "Quit PippinVR", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            item?.menu = menu
            running = false
            panelCount = 0
            deviceInfo = USBLinkSpeed.connectedDevices()
            return
        }
        if !shuttingDown && returnToDashboard && !state.running && session.applicationName == nil && !switchingApplication {
            returnToDashboard = false
            if state.error == nil { session.connect(); return }
        }
        if !state.running { virtualDisplays.removeAll(); panelSources = [nil] }
        menu.addItem(withTitle: state.running ? (session.applicationName.map { "3D app: \($0)" } ?? "Direct USB session active") : (present ? "Ready to connect" : "Connect a Quest USB cable"), action: nil, keyEquivalent: "")
        let connect = menu.addItem(withTitle: state.running ? (session.applicationName == nil ? "Disconnect (fade out)" : "Return to Pippin") : "Connect USB Direct", action: #selector(toggleConnection), keyEquivalent: "")
        connect.target = self
        connect.isEnabled = !switchingApplication && (state.running || present)
        let launch = menu.addItem(withTitle: defaultAppTitle.map { "Launch: \($0)" } ?? "Launch 3D App…", action: #selector(launch3DApp), keyEquivalent: "")
        launch.target = self
        launch.isEnabled = present && !switchingApplication
        if defaultAppTitle != nil {
            let change = menu.addItem(withTitle: "Change Default 3D App…", action: #selector(chooseDefault3DApp), keyEquivalent: "")
            change.target = self
            change.isEnabled = present && !switchingApplication
        }
        let media = menu.addItem(withTitle: "Add Media…", action: #selector(addMediaFile), keyEquivalent: "")
        media.target = self
        media.isEnabled = state.running && session.applicationName == nil && panelSources.count < maxPanels
        if let error = state.error { menu.addItem(withTitle: "Last connection: \(error)", action: nil, keyEquivalent: "") }
        menu.addItem(withTitle: "Uses Quest Link", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let questClient = menu.addItem(withTitle: "Use Quest APK Client", action: #selector(switchToQuestClient), keyEquivalent: "")
        questClient.target = self
        questClient.isEnabled = !switchingApplication
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit PippinVR", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        item?.menu = menu
        running = state.running
        panelCount = state.running ? panelSources.count : 0
        deviceInfo = USBLinkSpeed.connectedDevices()
        rebuildSettings()
    }

    private func rebuildSettings() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let state = session.state
        let displays = NSMenu()
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        for (index, id) in ids.prefix(Int(count)).enumerated() {
            action("Display \(index + 1) (\(CGDisplayPixelsWide(id))×\(CGDisplayPixelsHigh(id)))", "display:\(id)", menu: displays)
        }
        let displayItem = menu.addItem(withTitle: "Add Existing Screen", action: nil, keyEquivalent: "")
        displayItem.submenu = displays
        let add = menu.addItem(withTitle: "Add Screen", action: #selector(addVirtualScreen), keyEquivalent: "")
        add.target = self
        add.isEnabled = state.running && session.applicationName == nil && panelSources.count < maxPanels

        let cameras = NSMenu()
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: nil, position: .unspecified).devices
        for device in devices { action(device.localizedName, "add-device:\(device.uniqueID)", menu: cameras) }
        if devices.isEmpty { cameras.addItem(withTitle: "No cameras detected", action: nil, keyEquivalent: "") }
        let cameraItem = menu.addItem(withTitle: "Add Camera Feed", action: nil, keyEquivalent: "")
        cameraItem.submenu = cameras
        action("Add Video / Media Feed", "add-media", menu: menu)
        action("Remove Video / Media Feed", "remove-media", menu: menu)
        action("Remove Last Panel", "remove-last", menu: menu)
        action("Reset Panel Positions", "reset", menu: menu)
        menu.addItem(withTitle: "Up to \(maxPanels) panels · trigger selects next panel", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Hide dashboard: sticks move / resize · squeeze grabs and rotates", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let stereo = NSMenu()
        for (index, title) in ["Flat (2D)", "Side-by-side 3D", "Side-by-side 3D (swap eyes)", "Over-under 3D", "Over-under 3D (swap eyes)"].enumerated() {
            action(title, "stereo:\(index)", menu: stereo)
        }
        menu.addItem(withTitle: "Selected Screen 3D", action: nil, keyEquivalent: "").submenu = stereo
        let fps = NSMenu()
        for value in [15, 30, 60] {
            action("\(value) FPS", "fps:\(value)", menu: fps)
            fps.items.last?.state = value == captureFPS ? .on : .off
        }
        menu.addItem(withTitle: "Capture Frame Rate", action: nil, keyEquivalent: "").submenu = fps
        let resolution = NSMenu()
        for width in [1024, 1536, 2048] {
            action("\(width)×\(width * 5 / 8)", "resolution:\(width)", menu: resolution)
            resolution.items.last?.state = width == panelWidth ? .on : .off
        }
        menu.addItem(withTitle: "Panel Resolution", action: nil, keyEquivalent: "").submenu = resolution
        let fileRefresh = (try? session.fileSettings())?.refreshHz
        apps = session.configPath.flatMap { try? ServerConfig.load(path: $0) }?.apps ?? []
        if let path = session.configPath {
            let configItem = menu.addItem(withTitle: "Open Config File…", action: #selector(openConfigFile), keyEquivalent: "")
            configItem.target = self
            menu.addItem(withTitle: "Config: \(path)", action: nil, keyEquivalent: "")
        }
        if let hz = fileRefresh {
            menu.addItem(withTitle: "Headset refresh from config: \(hz == 0 ? "Auto" : "\(hz) Hz")", action: nil, keyEquivalent: "")
        }
        for (title, key, values) in [
            ("Headset Refresh (next connection)", "directRefreshHz", ["Auto", "72", "80", "90", "120"]),
            ("Encode Scale (next connection)", "directEncodeScale", ["Auto", "0.5", "0.75", "1.0"])
        ] {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let selected = key == "directRefreshHz" && fileRefresh != nil
                ? (fileRefresh == 0 ? "Auto" : String(fileRefresh!))
                : UserDefaults.standard.string(forKey: key) ?? "Auto"
            for value in values {
                let entry = submenu.addItem(withTitle: value, action: #selector(saveStartupSetting(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [key, value]
                entry.state = selected == value ? .on : .off
                entry.isEnabled = key != "directRefreshHz" || fileRefresh == nil
            }
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        }
        menu.addItem(withTitle: "Reconnect to apply; in-process Newt requires app restart", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        settingsMenu = menu
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "PippinVR Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(questSession: nil, directController: self))
            window.center()
            settingsWindow = window
        }
        rebuild()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func perform(_ entry: NSMenuItem) {
        guard entry.isEnabled, let action = entry.action else { return }
        NSApp.sendAction(action, to: entry.target, from: entry)
        rebuild()
    }

    @objc private func openConfigFile() {
        guard let path = session.configPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func saveStartupSetting(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2 else { return }
        if values[1] == "Auto" { UserDefaults.standard.removeObject(forKey: values[0]) } else { UserDefaults.standard.set(values[1], forKey: values[0]) }
    }

    @objc private func sendCommand(_ sender: NSMenuItem) {
        guard var command = sender.representedObject as? String else { return }
        guard session.state.running || command.hasPrefix("fps:") || command.hasPrefix("resolution:") else { return }
        if command.hasPrefix("display:") { command = "add-display:" + command.dropFirst(8) }
        if command.hasPrefix("fps:"), let value = Int(command.dropFirst(4)) { captureFPS = value; UserDefaults.standard.set(value, forKey: "directCaptureFPS") }
        if command.hasPrefix("resolution:"), let value = Int(command.dropFirst(11)) { panelWidth = value; UserDefaults.standard.set(value, forKey: "directPanelWidth") }
        if command.hasPrefix("add-") {
            guard panelSources.count < maxPanels else { return }
            panelSources.append(nil)
        } else if command == "remove-last" {
            guard !panelSources.isEmpty else { return }
            if let id = panelSources.removeLast() { virtualDisplays.removeAll { $0.displayID == id } }
        }
        if command.hasPrefix("add-camera:") || command.hasPrefix("add-device:"), AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let queuedCommand = command
            AVCaptureDevice.requestAccess(for: .video) { [session] _ in
                session.command(queuedCommand)
            }
        } else { session.command(command) }
    }

    @objc private func addVirtualScreen() {
        guard session.state.running else { return }
        guard panelSources.count < maxPanels else {
            session.command("notice:\(maxPanels)-panel limit reached")
            return
        }
        do {
            var config = DisplayConfig()
            config.width = min(max(nextScreenWidth, 2), 16384) / 2 * 2
            config.height = min(max(nextScreenHeight, 2), 16384) / 2 * 2
            config.refreshHz = Double(captureFPS)
            config.hiDPI = false
            config.serial = nextSerial

            config.productID = 0x1234 + nextSerial
            nextSerial += 1
            config.name = "PippinVR Direct \(virtualDisplays.count + 1)"
            let display = try VirtualDisplay(config: config)
            virtualDisplays.append(display)

            fixupDisplayArrangement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.fixupDisplayArrangement() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.fixupDisplayArrangement() }
            panelSources.append(display.displayID)
            session.command("add-display:\(display.displayID)")
            session.command("notice:Virtual screen added — Hide dashboard to arrange it")
            for (index, tracked) in virtualDisplays.enumerated() {
                let cached = tracked.displayID
                let live = tracked.liveDisplayID
                if cached != live {
                    Logger.warning("VirtualDisplay[\(index)] ID reassigned: cached=\(cached) live=\(live)")
                } else {
                    Logger.debug("VirtualDisplay[\(index)] ID stable: \(cached)")
                }
            }
        } catch {
            session.command("notice:Could not create screen — check Mac Settings")
            let alert = NSAlert()
            alert.messageText = "Could not add virtual screen"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    private func fixupDisplayArrangement() {
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else { return }
        var originX: Int32 = 0
        for (index, tracked) in virtualDisplays.enumerated() {
            if tracked.disableMirroringInTransaction(transaction) {
                Logger.debug("Un-mirrored VirtualDisplay[\(index)] (ID=\(tracked.displayID))")
            } else {
                Logger.debug("VirtualDisplay[\(index)] (ID=\(tracked.displayID)) had nothing to un-mirror")
            }
            let originErr = CGConfigureDisplayOrigin(transaction, tracked.displayID, originX, 0)
            Logger.debug("Positioned VirtualDisplay[\(index)] (ID=\(tracked.displayID)) at x=\(originX): \(originErr == .success ? "ok" : "error \(originErr.rawValue)")")
            originX += Int32(tracked.width)
        }
        CGCompleteDisplayConfiguration(transaction, .forSession)
    }

    @objc private func addMediaFile() {
        guard !presentingPicker else { return }
        presentingPicker = true
        defer { presentingPicker = false }
        guard session.state.running && session.applicationName == nil && panelSources.count < maxPanels else { return }
        let picker = NSOpenPanel()
        picker.title = "Add a video to Pippin"
        picker.allowedContentTypes = [.movie]
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url=picker.url else {
            session.command("notice:Media selection cancelled"); return
        }
        guard !url.path.contains("\n") && !url.path.contains("\r") else { return }
        let entry=NSMenuItem(); entry.representedObject="add-media-file:\(url.path)"
        sendCommand(entry)
        session.command("notice:Media added — stereo options are in Mac Settings")
        rebuild()
    }

    func setWristClockEnabled(_ enabled: Bool) {
        wristClockEnabled = enabled
        do { try DirectWristClockPreferences.setEnabled(enabled) } catch { Logger.warning("Could not save wrist-clock setting: \(error)") }
        session.command(enabled ? "wrist-clock:1" : "wrist-clock:0")
    }

    private func syncSavedScene() {
        guard session.state.running, let modified = DirectScenePreferences.modificationDate,
              modified != sceneSyncedAt, let scene = DirectScenePreferences.load() else { return }
        sceneSyncedAt = modified
        environmentModelURLs = scene.models
        environmentImageURL = scene.environment
        environmentFlippedVertically = scene.flippedVertically
        environmentFlippedHorizontally = scene.flippedHorizontally
    }

    func setPassthroughAllowed(_ allowed: Bool) {
        if allowed {
            let alert = NSAlert()
            alert.messageText = "Allow headset camera access?"
            alert.informativeText = """
                PippinVR will receive video from your headset’s passthrough cameras over USB \
                and show it in a portal inside VR. The cameras stream only while the portal is \
                open. Video is decoded on this Mac only to display it in your headset; it is \
                never recorded, saved, or sent anywhere else.

                Takes effect from the next headset session. You can turn this off at any time.
                """
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                passthroughAllowed = false
                return
            }
        }
        do { try DirectPassthroughPreferences.setAllowed(allowed) } catch { Logger.warning("Could not save camera access setting: \(error)") }
        passthroughAllowed = DirectPassthroughPreferences.allowed
        passthroughEnabled = DirectPassthroughPreferences.enabled
        session.command("passthrough:reload")
    }

    func setAudioMode(_ mode: DirectAudioPreferences.Mode) {
        do { try DirectAudioPreferences.setMode(mode) } catch { Logger.warning("Could not save headset sound setting: \(error)") }
        audioMode = DirectAudioPreferences.mode
        session.command("audio:reload")
    }

    func setAudioMacSpeakers(_ on: Bool) {
        do { try DirectAudioPreferences.setMacSpeakers(on) } catch { Logger.warning("Could not save Mac speakers setting: \(error)") }
        audioMacSpeakers = DirectAudioPreferences.macSpeakers
        session.command("audio:reload")
    }

    func setPassthroughEnabled(_ enabled: Bool) {
        guard passthroughAllowed || !enabled else { return }
        do { try DirectPassthroughPreferences.setEnabled(enabled) } catch { Logger.warning("Could not save passthrough portal setting: \(error)") }
        passthroughEnabled = DirectPassthroughPreferences.enabled
        session.command("passthrough:reload")
    }

    func setShowMetricsInVR(_ enabled: Bool) {
        showMetricsInVR = enabled
        UserDefaults.standard.set(enabled, forKey: "directShowMetricsInVR")
        session.command(enabled ? "metrics:1" : "metrics:0")
    }

    func setMetalFXScale(_ scale: Double) {
        guard [0, 1.25, 1.5, 2].contains(scale) else { return }
        metalFXScale = scale
        UserDefaults.standard.set(scale, forKey: "directMetalFXScale")
        let value = scale == 0 ? "0" : (scale == 2 ? "2" : String(scale))
        session.command("metalfx-scale:\(value)")
    }

    func setMetalFXEnabled(_ enabled: Bool) {
        metalFXEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "directMetalFXUpscale")
        session.command(enabled ? "metalfx:1" : "metalfx:0")
    }

    func chooseEnvironmentImage() {
        guard !presentingPicker else { return }
        presentingPicker = true
        defer { presentingPicker = false }
        guard session.state.running && session.applicationName == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose a 360 panoramic image"
        picker.message = "Equirectangular (360×180) images work best — this wraps around a sphere."
        picker.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else {
            session.command("notice:Environment selection cancelled"); return
        }
        guard !url.path.contains("\n") && !url.path.contains("\r") else { return }
        session.command("environment:\(url.path)")
        environmentImageURL = url
        environmentFlippedVertically = false
        environmentFlippedHorizontally = false
    }

    func clearEnvironmentImage() {
        session.command("environment-clear")
        environmentImageURL = nil
        environmentFlippedVertically = false
        environmentFlippedHorizontally = false
        environmentModelURLs.removeAll()
    }

    func setEnvironmentFlipVertical(_ newValue: Bool) {
        guard environmentImageURL != nil, environmentFlippedVertically != newValue else { return }
        session.command("environment-flip-v")
        environmentFlippedVertically = newValue
    }

    func setEnvironmentFlipHorizontal(_ newValue: Bool) {
        guard environmentImageURL != nil, environmentFlippedHorizontally != newValue else { return }
        session.command("environment-flip-h")
        environmentFlippedHorizontally = newValue
    }

    func toggleEnvironmentFlipVertical() {
        setEnvironmentFlipVertical(!environmentFlippedVertically)
    }

    func toggleEnvironmentFlipHorizontal() {
        setEnvironmentFlipHorizontal(!environmentFlippedHorizontally)
    }

    private static var modelContentTypes: [UTType] {
        var types: [UTType] = [.usdz, .threeDContent, .sceneKitScene]
        for ext in ["usdz", "usd", "usda", "usdc", "obj", "gltf", "glb"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    func chooseEnvironmentModel() {
        guard !presentingPicker else { return }
        presentingPicker = true
        defer { presentingPicker = false }
        guard session.state.running && session.applicationName == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose a 3D environment model (.usdz/.obj/.gltf/.glb)"
        picker.message = "Supports USDZ (.usdz/.usd), Wavefront OBJ (.obj + .mtl), and glTF 2.0 (.gltf/.glb)."
        picker.allowedContentTypes = Self.modelContentTypes
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else {
            session.command("notice:3D model selection cancelled"); return
        }
        guard !url.path.contains("\n") && !url.path.contains("\r") else { return }
        session.command("environment-model:\(url.path)")
        environmentModelURLs.append(url)
        rebuild()
    }

    func scaleSelectedEnvironmentModel(up: Bool) {
        guard hasEnvironmentModel else { return }
        session.command(up ? "environment-scale-up" : "environment-scale-down")
    }

    func rotateSelectedEnvironmentModel() {
        guard hasEnvironmentModel else { return }
        session.command("environment-rotate-y")
    }

    func toggleSelectedEnvironmentModelPosition() {
        guard hasEnvironmentModel else { return }
        session.command("environment-toggle-origin")
    }

    func removeSelectedEnvironmentModel() {
        guard hasEnvironmentModel else { return }
        session.command("remove-model")
        if !environmentModelURLs.isEmpty { environmentModelURLs.removeLast() }
        rebuild()
    }

    func presentAddAppPicker() {
        guard !presentingPicker else { return }
        presentingPicker = true
        defer { presentingPicker = false }
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.title = "Add a 3D app"
        picker.message = "Choose a Mac .app/executable that supports OpenXR, or a Godot project folder (containing project.godot)."
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        guard picker.runModal() == .OK, let url = picker.url else { return }
        addApp(title: url.deletingPathExtension().lastPathComponent, url: url)
    }

    private func isGodotProject(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("project.godot").path)
    }

    private func withSavedApps(_ mutate: (inout ServerConfig) -> Void) {
        guard let configPath = session.configPath else { return }
        var config = (try? ServerConfig.load(path: configPath)) ?? ServerConfig()
        mutate(&config)
        do {
            try config.validate()
            try config.save(to: configPath)
            apps = config.apps
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save app list"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    func addApp(title: String, url: URL) {
        var entry = AppEntry(title: title)
        if isGodotProject(url) {
            entry.project = url.path
        } else {
            let executable = (Bundle(url: url)?.executableURL ?? url).path
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                let alert = NSAlert()
                alert.messageText = "Choose an executable Mac OpenXR app or a Godot project folder"
                alert.runModal()
                return
            }
            entry.game = url.path
        }
        withSavedApps { $0.apps.append(entry) }
    }

    func removeApp(at index: Int) {
        withSavedApps { config in
            guard config.apps.indices.contains(index) else { return }
            config.apps.remove(at: index)
        }
    }

    func renameApp(at index: Int, title: String) {
        withSavedApps { config in
            guard config.apps.indices.contains(index) else { return }
            config.apps[index].title = title
        }
    }

    private var defaultAppPath: String? {
        get { UserDefaults.standard.string(forKey: "directDefaultAppPath") }
        set { UserDefaults.standard.set(newValue, forKey: "directDefaultAppPath") }
    }
    private var defaultAppTitle: String? {
        get { UserDefaults.standard.string(forKey: "directDefaultAppTitle") }
        set { UserDefaults.standard.set(newValue, forKey: "directDefaultAppTitle") }
    }

    @objc private func launch3DApp() {
        guard !switchingApplication && !presentingPicker else { return }
        if let saved = defaultAppPath, FileManager.default.isExecutableFile(atPath: saved) {
            launchApp(at: URL(fileURLWithPath: saved))
            return
        }
        chooseAndLaunch3DApp()
    }

    @objc private func chooseDefault3DApp() {
        guard !switchingApplication && !presentingPicker else { return }
        chooseAndLaunch3DApp()
    }

    private func chooseAndLaunch3DApp() {
        presentingPicker = true
        defer { presentingPicker = false }
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSOpenPanel()
        picker.title = "Choose a native OpenXR application"
        picker.message = "Choose a Mac .app or executable that supports OpenXR. Pippin releases USB Link while it runs and returns to the dashboard when it exits. Remembered for next time -- use \"Change Default 3D App…\" to pick a different one."
        picker.canChooseFiles = true; picker.canChooseDirectories = false
        guard picker.runModal() == .OK, let chosen = picker.url else {
            session.command("notice:App selection cancelled"); return
        }
        let executable = Bundle(url: chosen)?.executableURL ?? chosen
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let alert=NSAlert(); alert.messageText="Choose an executable Mac OpenXR app"; alert.runModal(); return
        }
        defaultAppPath = executable.path
        defaultAppTitle = chosen.deletingPathExtension().lastPathComponent
        rebuild()
        launchApp(at: executable)
    }

    private func launchApp(at executable: URL) {
        switchingApplication = true
        returnToDashboard = false
        rebuild()
        Task { @MainActor in
            if await session.launchViaManager(executable: executable) {
                switchingApplication = false
                returnToDashboard = true
                rebuild()
                return
            }
            session.requestStop()
            rebuild()
            let deadline = Date().addingTimeInterval(5)
            while session.state.running && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            switchingApplication = false
            guard !shuttingDown else { return }
            guard !session.state.running else {
                let alert=NSAlert(); alert.messageText="USB session has not stopped yet"; alert.informativeText="Disconnect before launching a 3D app."; alert.runModal(); rebuild(); return
            }
            virtualDisplays.removeAll(); panelSources = [nil]
            session.connect(application: executable)
            returnToDashboard = true
            rebuild()
        }
    }

    @objc private func toggleConnection() {
        returnToDashboard = session.applicationName != nil
        if session.state.running { session.requestStop() } else { session.connect() }
        rebuild()
    }

    @objc func switchToQuestClient() {
        guard let executable = Bundle.main.executableURL else { return }
        let child = Process()
        child.executableURL = executable

        child.arguments = ["--quest-client", "--gui", "--adb-reverse"]
        var environment = ProcessInfo.processInfo.environment
        environment["PIPPINVR_WAIT_FOR_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        child.environment = environment
        do {
            try child.run()
            quitApp()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start Quest Client mode"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    @objc private func quitApp() { returnToDashboard = false; beginShutdown(exitCode: 0) }
}

@MainActor
final class DirectApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        DockFileOpenRouter.shared.open(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginShutdown(exitCode: 0)
        return .terminateCancel
    }
}
