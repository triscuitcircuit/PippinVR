import Foundation
#if PIPPINVR_DIRECT
import Newt
#endif

enum DirectMonadoError: Error, CustomStringConvertible {
    case missingClient
    case missingRuntimeManifest
    case missingMoltenVKManifest
    case clientExited(Int32)
    case managerError(String)

    var description: String {
        switch self {
        case .missingClient:
            "bundled PippinXR client not found (build with BUNDLE_MONADO=1)"
        case .missingRuntimeManifest:
            "bundled Monado OpenXR manifest not found"
        case .missingMoltenVKManifest:
            "bundled MoltenVK ICD manifest not found"
        case let .clientExited(status):
            "PippinXR / Newt client exited with status \(status)"
        case let .managerError(message):
            "Newt session manager: \(message)"
        }
    }
}

private enum ManagedSetupFailure: Error {
    case notAvailable(Error)
}

final class DirectMonadoSession: @unchecked Sendable {
    private let lock = NSLock()
    private var hostRequests: [Int] = []
    private var hostOutput = DirectHostRequests()
    private var metricsOutput = Data()

    func takeHostRequests() -> [Int] {
        var requests = lock.withLock { let pending = hostRequests; hostRequests.removeAll(); return pending }
        #if PIPPINVR_DIRECT
        while true {
            let request = Int(Newt_PollHostRequest())
            if request == 0 { break }
            requests.append(request)
        }
        #endif
        return requests
    }

    private func receiveHostOutput(_ data: Data) {
        let lines: [String] = lock.withLock {
            metricsOutput.append(data)
            var lines: [String] = []
            while let newline = metricsOutput.firstIndex(of: 0x0A) {
                if let line = String(data: metricsOutput[..<newline], encoding: .utf8) { lines.append(line) }
                metricsOutput.removeSubrange(...newline)
            }
            if metricsOutput.count > 64 * 1024 { metricsOutput.removeAll() }
            for request in hostOutput.receive(data) where hostRequests.count < 16 {
                hostRequests.append(request)
            }
            return lines
        }
        for line in lines { DirectMetricsStore.publishLocalLog(line) }
    }
    let configPath: String?
    private let inheritedEnvironment = ProcessInfo.processInfo.environment

    private static let installLogBridge: Void = {
        #if PIPPINVR_DIRECT
        Newt_SetLogHandler({ _, level, message in
            guard let message else { return }
            let text = "[Newt] \(String(cString: message))"
            DirectMetricsStore.publishLocalLog(text)
            switch level {
            case 0: Logger.debug(text)
            case 2: Logger.warning(text)
            case 3: Logger.error(text)
            default: Logger.info(text)
            }
        }, nil)
        #endif
    }()

    init(configPath: String? = nil) {
        _ = DirectMonadoSession.installLogBridge
        self.configPath = configPath
    }

    func fileSettings() throws -> DirectUSBConfig? {
        guard let configPath else { return nil }
        return try ServerConfig.load(path: configPath).directUSB
    }

    private func launchEnvironment() throws -> [String: String] {
        var environment = inheritedEnvironment
        for (key, variable) in [("directRefreshHz", "QL_OVERRIDE_FPS"), ("directEncodeScale", "QL_OVERRIDE_SCALE"),
                                ("directCaptureFPS", "PIPPINVR_CAPTURE_FPS"), ("directPanelWidth", "PIPPINVR_PANEL_WIDTH")] {
            if environment[variable] == nil, let value = UserDefaults.standard.string(forKey: key) {
                environment[variable] = value
            }
        }
        let settings = try fileSettings()
        if inheritedEnvironment["QL_OVERRIDE_FPS"] == nil, let hz = settings?.refreshHz {
            environment["QL_OVERRIDE_FPS"] = hz == 0 ? nil : String(hz)
        }
        for (variable, value) in [
            ("PIPPINVR_RAY_IDLE_SECONDS", settings?.rayIdleSeconds ?? 2),
            ("PIPPINVR_RAY_WAKE_METERS", settings?.rayWakeDistanceMeters ?? 0.02),
            ("PIPPINVR_RAY_WAKE_DEGREES", settings?.rayWakeAngleDegrees ?? 3)
        ] where inheritedEnvironment[variable] == nil {
            environment[variable] = String(value)
        }
        if environment["QL_METRICS_FILE"] == nil {
            let metricsURL = DirectMetricsStore.metricsFileURL
            try? FileManager.default.createDirectory(
                at: metricsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            environment["QL_METRICS_FILE"] = metricsURL.path
        }

        DirectWristClockPreferences.migrateIfNeeded()

        if environment["QL_PASSTHROUGH"] == nil {
            environment["QL_PASSTHROUGH"] = DirectPassthroughPreferences.allowed ? "1" : "0"
        }
        if environment["NEWT_METRICS"] == nil {
            environment["NEWT_METRICS"] = UserDefaults.standard.bool(forKey: "directShowMetricsInVR") ? "1" : "0"
        }
        if environment["NEWT_METALFX_UPSCALE"] == nil {
            let enabled = (UserDefaults.standard.object(forKey: "directMetalFXUpscale") as? Bool) ?? true
            environment["NEWT_METALFX_UPSCALE"] = enabled ? "1" : "0"
        }
        if environment["NEWT_METALFX_SCALE"] == nil {
            let scale = UserDefaults.standard.double(forKey: "directMetalFXScale")
            environment["NEWT_METALFX_SCALE"] = String([0, 1.25, 1.5, 2].contains(scale) ? scale : 0)
        }

        for variable in Self.moltenVKCompatKeys where environment[variable] == nil {
            environment[variable] = "0"
        }
        for suffix in ["CAPTURE_FPS", "PANEL_WIDTH", "RAY_IDLE_SECONDS", "RAY_WAKE_METERS", "RAY_WAKE_DEGREES", "VIDEO_PATH"] {
            let key = "NEWT_" + suffix
            if environment[key] == nil { environment[key] = environment["PIPPINVR_" + suffix] }
        }
        return environment
    }
    private var process: Process?
    private var inProcessRunning = false
    private var stdinPipe: Pipe?
    private var running = false
    private var stopRequested = false
    private var lastError: String?
    private let managerClient = NewtManagerClient()
    private var usingManager = false
    private var externallyActive = false
    private var selfInitiatedGame = false
    var state: (running: Bool, error: String?, externallyActive: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (running, lastError, externallyActive)
    }

    private var externalName: String?
    var applicationName: String? { lock.withLock { externalName } }

    func connect(application: URL? = nil) {
        guard USBLinkSpeed.detectQuestLinkSpeed() != nil else {
            Logger.warning("Direct USB: no Quest on USB; not starting session")
            return
        }
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        stopRequested = false
        lastError = nil
        externalName = application?.lastPathComponent
        lock.unlock()
        Task.detached { [self] in
            do { try await run(application: application) } catch {
                lock.withLock { lastError = String(describing: error) }
                Logger.warning("Direct USB: \(error)")
            }
            lock.withLock { running = false; externalName = nil }
        }
    }

    static var clientURL: URL? {
        if let override = ProcessInfo.processInfo.environment["PIPPINVR_XR_CLIENT"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable
                .deletingLastPathComponent()
                .appendingPathComponent("pippinvr-xr")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        return Bundle.main.url(forAuxiliaryExecutable: "pippinvr-xr")
    }

    static var isAvailable: Bool {
        if clientURL != nil && runtimeManifestURL != nil && moltenVKManifestURL != nil {
            return true
        }
        return true
    }

    private static var runtimeManifestURL: URL? {
        discoveredManifestURL(envKey: "XR_RUNTIME_JSON", bundledName: "monado-runtime.json",
                              managerKey: "runtime")
    }

    private static var moltenVKManifestURL: URL? {
        discoveredManifestURL(envKey: "VK_ICD_FILENAMES", bundledName: "MoltenVK_icd.json",
                              managerKey: "icd")
    }

    private static func discoveredManifestURL(envKey: String, bundledName: String,
                                              managerKey: String) -> URL? {
        if let bundled = bundledOpenXRResource(bundledName) { return bundled }
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[envKey],
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let configured = managerConfigValue(managerKey),
           FileManager.default.fileExists(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        return nil
    }

    private static func managerConfigValue(_ key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let stateDir = environment["NEWT_STATE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Newt").path
        let configURL = URL(fileURLWithPath: stateDir).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func bundledOpenXRResource(_ name: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("OpenXR")
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func configuredApps() -> [(title: String, target: String)] {
        guard let configPath, let config = try? ServerConfig.load(path: configPath) else { return [] }
        return config.apps.map { (title: $0.title, target: $0.game ?? $0.project ?? "") }
    }

    private static let moltenVKCompatKeys = ["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "MVK_CONFIG_USE_MTLHEAP"]

    private static let dashboardOverrideKeys = [
        "QL_OVERRIDE_FPS", "QL_OVERRIDE_SCALE", "QUEST_LINK_LOG", "QL_METRICS_FILE",
        "QL_LINK_PROBE", "QL_AUDIO_PROBE", "QL_CAMERA_PROBE", "QL_PASSTHROUGH",
        "QL_FLOAT_PROBE", "QL_FLOAT_PROBE_SECONDS", "QL_AUDIO_TEST_TONE",
        "PIPPIN_HAND_BENCHMARK", "PIPPIN_HAND_BENCHMARK_DIR", "PIPPIN_HAND_BENCHMARK_WIDTH",
        "PIPPIN_HAND_BENCHMARK_HZ",
        "NEWT_WRIST_CLOCK", "NEWT_METRICS", "NEWT_METALFX_UPSCALE", "NEWT_METALFX_SCALE",
        "NEWT_CAPTURE_FPS", "NEWT_PANEL_WIDTH",
        "NEWT_RAY_IDLE_SECONDS", "NEWT_RAY_WAKE_METERS", "NEWT_RAY_WAKE_DEGREES", "NEWT_VIDEO_PATH"
    ] + moltenVKCompatKeys

    private func dashboardOverrides(from environment: [String: String]) -> [String: String] {
        environment.filter { Self.dashboardOverrideKeys.contains($0.key) }
    }

    private func runManaged(clientURL: URL, runtimeManifestURL: URL, moltenVKManifestURL: URL,
                             resolvedEnvironment: [String: String]) async throws {
        do {
            try await managerClient.configure(dashboard: clientURL.path, runtime: runtimeManifestURL.path,
                                               icd: moltenVKManifestURL.path, apps: configuredApps(),
                                               environment: dashboardOverrides(from: resolvedEnvironment))
            try await managerClient.ensureRunning()
        } catch {
            throw ManagedSetupFailure.notAvailable(error)
        }
        Logger.info("Direct USB: launching PippinXR (Newt) via the shared Newt session manager")
        try await runManagedPollLoop()
    }

    private func runManagedPollLoop() async throws {
        lock.withLock { usingManager = true }
        defer { lock.withLock { usingManager = false; externallyActive = false; selfInitiatedGame = false; externalName = nil } }
        while true {
            if lock.withLock({ stopRequested }) { return }
            if let requests = try? await managerClient.pollHostRequests(), !requests.isEmpty {
                lock.withLock {
                    for request in requests where hostRequests.count < 16 { hostRequests.append(request) }
                }
            }
            let status: NewtManagerClient.ManagerStatus
            do {
                status = try await managerClient.status()
            } catch {
                if lock.withLock({ stopRequested }) { return }
                throw error
            }
            lock.withLock {
                let selfInitiated = selfInitiatedGame
                externallyActive = (status.state == "game" || status.state == "preparing") && !selfInitiated
                if status.state != "game" { selfInitiatedGame = false; externalName = nil }
            }
            if status.state == "idle", let message = status.error, !message.isEmpty {
                if status.lastDashboardExit == 0 { return }
                throw DirectMonadoError.managerError(message)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    func launchViaManager(executable: URL) async -> Bool {
        guard lock.withLock({ usingManager }) else { return false }
        do {
            try await managerClient.launch(argv: [executable.path], cwd: executable.deletingLastPathComponent().path)
            lock.withLock { selfInitiatedGame = true; externalName = executable.lastPathComponent }
            return true
        } catch {
            Logger.warning("Direct USB: manager launch failed, falling back to a direct launch: \(error)")
            return false
        }
    }

    func run(application: URL? = nil) async throws {
        lock.withLock { running = true }
        defer { lock.withLock { running = false } }
        if lock.withLock({ stopRequested }) { return }
        if let value = ProcessInfo.processInfo.environment["PIPPINVR_WAIT_FOR_PID"], let pid = Int32(value) {
            let deadline = Date().addingTimeInterval(15)
            while kill(pid, 0) == 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        let resolvedEnvironment = try launchEnvironment()
        if lock.withLock({ stopRequested }) { return }
        let forceInProcess = application == nil && ProcessInfo.processInfo.environment["NEWT_IN_PROCESS"] == "1"
        if application == nil, !forceInProcess,
           let clientURL = Self.clientURL,
           let runtimeManifestURL = Self.runtimeManifestURL,
           let moltenVKManifestURL = Self.moltenVKManifestURL {
            do {
                try await runManaged(clientURL: clientURL, runtimeManifestURL: runtimeManifestURL, moltenVKManifestURL: moltenVKManifestURL,
                                     resolvedEnvironment: resolvedEnvironment)
                return
            } catch ManagedSetupFailure.notAvailable(let underlying) {
                if (try? await managerClient.status()) != nil {
                    Logger.warning("Direct USB: manager setup failed (\(underlying)) but a session manager is already running; adopting its session instead of launching a second dashboard")
                    try await managerClient.resume()
                    try await runManagedPollLoop()
                    return
                }
                Logger.warning("Direct USB: Newt session manager unavailable (\(underlying)); falling back to direct launch")
            }
        }
        if !forceInProcess,
           let clientURL = application ?? Self.clientURL,
           let runtimeManifestURL = Self.runtimeManifestURL,
           let moltenVKManifestURL = Self.moltenVKManifestURL {
            let monadoDir = runtimeManifestURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks/Monado")

            var environment = resolvedEnvironment
            environment["XR_RUNTIME_JSON"] = runtimeManifestURL.path
            environment["VK_ICD_FILENAMES"] = moltenVKManifestURL.path
            environment["DYLD_FALLBACK_LIBRARY_PATH"] = monadoDir.path
            if environment["QUEST_LINK_LOG"] == nil {
                environment["QUEST_LINK_LOG"] = "info"
            }

            let child = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            if application == nil { environment["NEWT_HOST_EVENTS"] = "1" }
            child.executableURL = clientURL
            child.arguments = application == nil ? ["-g", "Vulkan"] : []
            if application != nil { child.currentDirectoryURL = clientURL.deletingLastPathComponent() }
            child.environment = environment
            child.standardInput = inputPipe
            child.standardOutput = outputPipe
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if application == nil { self?.receiveHostOutput(data) }
                FileHandle.standardOutput.write(data)
            }
            child.standardError = FileHandle.standardError

            lock.withLock { process = child; stdinPipe = inputPipe }

            Logger.info("Direct USB: launching PippinXR (Newt) via bundled Monado")
            Logger.info("Direct USB: runtime manifest \(runtimeManifestURL.path)")
            defer {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                lock.withLock { process = nil; stdinPipe = nil; hostRequests.removeAll(); hostOutput = DirectHostRequests(); metricsOutput.removeAll() }
            }
            try child.run()
            if lock.withLock({ stopRequested }) { command("stop") }
            child.waitUntilExit()

            if child.terminationStatus != 0 && !lock.withLock({ stopRequested }) {
                throw DirectMonadoError.clientExited(child.terminationStatus)
            }
            return
        }

        if application != nil { throw DirectMonadoError.missingRuntimeManifest }

        #if PIPPINVR_DIRECT
        Logger.info("Direct USB: running Newt_Run() in-process")
        lock.withLock { inProcessRunning = true }

        for variable in Self.dashboardOverrideKeys {
            if let value = resolvedEnvironment[variable] { setenv(variable, value, 1) } else { unsetenv(variable) }
        }
        if inheritedEnvironment["XR_RUNTIME_JSON"] == nil, let url = Self.runtimeManifestURL {
            setenv("XR_RUNTIME_JSON", url.path, 1)
        }
        if inheritedEnvironment["VK_ICD_FILENAMES"] == nil, let url = Self.moltenVKManifestURL {
            setenv("VK_ICD_FILENAMES", url.path, 1)
        }
        let status = Newt_Run()

        lock.withLock { inProcessRunning = false }
        #else
        _ = resolvedEnvironment
        let status: Int32 = -1
        Logger.error("Direct USB: built without PIPPINVR_DIRECT; in-process Newt_Run() is unavailable")
        #endif

        if status != 0 {
            throw DirectMonadoError.clientExited(status)
        }
    }

    func command(_ command: String) {
        lock.lock()
        let pipe = stdinPipe
        let managed = usingManager
        lock.unlock()
        if let pipe {
            do { try pipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8)) } catch { Logger.warning("Direct USB command failed: \(error)") }
        } else if managed {
            Task.detached { [managerClient] in
                do { _ = try await managerClient.command(command) } catch { Logger.warning("Direct USB command failed: \(error)") }
            }
        } else {
            #if PIPPINVR_DIRECT
            command.withCString { Newt_Command($0) }
            #else
            Logger.warning("Direct USB command dropped: built without PIPPINVR_DIRECT")
            #endif
        }
    }

    func requestStop() {
        let managed = beginStop()
        if managed {
            Task.detached { [managerClient] in try? await managerClient.stop() }
        }
    }

    func stopAndWait(timeout: TimeInterval = 4) async {
        let managed = beginStop()
        if managed {
            Logger.warning("Direct USB: stopping Newt-managed session")
            try? await managerClient.stop()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while state.running && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @discardableResult
    private func beginStop() -> Bool {
        lock.lock()
        stopRequested = true
        let child = process
        let runningInProcess = inProcessRunning
        let managed = usingManager
        lock.unlock()
        if let child, child.isRunning {
            Logger.warning("Direct USB: stopping PippinXR client")
            command("stop")
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { child.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
        if runningInProcess {
            Logger.warning("Direct USB: stopping in-process Newt session")
            #if PIPPINVR_DIRECT
            "stop".withCString { Newt_Command($0) }
            #endif
        }
        if managed {
            Logger.warning("Direct USB: stopping Newt-managed session")
        }
        return managed
    }
}
