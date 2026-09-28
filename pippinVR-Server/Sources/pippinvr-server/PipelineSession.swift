import AppKit
import CoreMedia
import Foundation

@MainActor
func showModalError(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.icon = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: nil)
    alert.runModal()
}

struct PipelineOptions {
    var config = ServerConfig()
    var configPath: String?
    var sink: SinkKind = .file(path: "/tmp/pippin-out.h265")

    var waitForClient = true
    var clientTimeoutSeconds: Double = 120
    var adbReverse = false

    enum SinkKind {
        case file(path: String)
        case tcp(port: UInt16)
    }
}

final class PipelineSession: @unchecked Sendable {
    private var options: PipelineOptions
    private var pipelines: [DisplayPipeline] = []
    private var sink: FrameSink?

    private let stateLock = NSLock()
    private var _clientConnected = false
    private var _everConnected = false
    private var _stopRequested = false
    private var _streaming = false

    init(options: PipelineOptions) {
        self.options = options
    }

    // MARK: For Menu Bar Status generation

    var clientConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _clientConnected
    }

    var isStreaming: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _streaming
    }

    var configuredDisplayCount: Int {
        options.config.displays.count
    }

    var displayNames: [(String, Int, Int)] {
        options.config.displays.map { ($0.name, $0.width, $0.height) }
    }

    var displays: [DisplayEntry] {
        options.config.displays
    }

    var configPath: String? {
        options.configPath
    }

    var config: ServerConfig {
        options.config
    }

    func requestStop() {
        stateLock.lock()
        _stopRequested = true
        stateLock.unlock()
        Logger.error("stop requested")
    }

    private var stopRequested: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _stopRequested
    }

    func reconfigure(displays: [DisplayEntry]) async throws {
        guard sink != nil else {
            throw ReconfigurationError.notRunning
        }

        guard isStreaming else {
            throw ReconfigurationError.notStreaming
        }

        options.config.displays = displays

        try options.config.validate()

        let descriptors = displays.enumerated().map { index, entry in
            StreamDescriptor(id: UInt8(index),
                             codec: options.config.encoderConfig(for: entry).codec,
                             width: entry.width,
                             height: entry.height,
                             refreshHz: entry.refreshHz,
                             hiDPI: entry.hiDPI,
                             name: entry.name)
        }

        let current = pipelinesSnapshot()
        for pipeline in current {
            await pipeline.shutdown()
        }

        // Create display configuration transaction
        var displayConfig: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&displayConfig)
        
        if beginResult != .success || displayConfig == nil {
            Logger.warning("Reconfigure: Failed to begin display configuration transaction")
        }

        var built: [DisplayPipeline] = []
        for (index, entry) in displays.enumerated() {
            let pipeline = DisplayPipeline(streamID: UInt8(index),
                                           entry: entry,
                                           encoderConfig: options.config.encoderConfig(for: entry))
            pipeline.onLog = { message in
                Logger.debug(message)
            }
            try pipeline.createDisplay(index: index)
            
            // Configure position in transaction
            if let config = displayConfig, let display = pipeline.display {
                let xOffset = Int32(index) * 10000
                let arrangeResult = CGConfigureDisplayOrigin(config, display.displayID, xOffset, 0)
                if arrangeResult == .success {
                    Logger.debug("Reconfigure: Configured display \(display.displayID) at x=\(xOffset)")
                }
            }
            
            built.append(pipeline)
        }

        if let config = displayConfig {
            var activeDisplays: [CGDirectDisplayID] = []
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            if count > 0 {
                activeDisplays = Array(repeating: 0, count: Int(count))
                CGGetActiveDisplayList(count, &activeDisplays, &count)
                
                Logger.info("Reconfigure: Disabling mirroring for ALL \(count) active displays")
                for displayID in activeDisplays {
                    _ = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                }
            }
            
            _ = CGCompleteDisplayConfiguration(config, .permanently)
        }

        setPipelines(built, streaming: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.verifyAndFixMirroring(pipelines: built)
        }

        try await Task.sleep(nanoseconds: 700_000_000)

        let capturedSink = sink
        for pipeline in built {
            pipeline.onEncodedFrame = { frame, streamID in
                capturedSink?.send(frame: frame, streamID: streamID)
            }
        }

        for pipeline in built {
            try await pipeline.startCapture()
        }

        sink?.reconfigure(streams: descriptors)

        if let path = options.configPath {
            try? options.config.save(to: path)
            Logger.info("reconfigured with \(displays.count) display(s), saved to \(path)")
        } else {
            Logger.info("reconfigured with \(displays.count) display(s)")
        }
    }

    enum ReconfigurationError: Error, CustomStringConvertible {
        case notRunning
        case notStreaming
        case noConfigPath
        case displayConfigFailed

        var description: String {
            switch self {
            case .notRunning:
                "Session not running"
            case .notStreaming:
                "Not streaming"
            case .noConfigPath:
                "Config path not specified"
            case .displayConfigFailed:
                "Display Configration failed"
            }
        }
    }

    func verifyAndFixMirroring(pipelines: [DisplayPipeline]) {
        var activeDisplays: [CGDirectDisplayID] = []
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        if count > 0 {
            activeDisplays = Array(repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &activeDisplays, &count)
        }
        
        var foundMirroring = false
        for displayID in activeDisplays {
            let mirrorSource = CGDisplayMirrorsDisplay(displayID)
            if mirrorSource != kCGNullDirectDisplay {
                Logger.warning("Display mirrored \(mirrorSource) after transaction")
                foundMirroring = true
            }
        }
        
        if foundMirroring {
            var config: CGDisplayConfigRef?
            let beginResult = CGBeginDisplayConfiguration(&config)
            guard beginResult == .success, let config = config else {
                Logger.error("Failed to create fix transaction: \(beginResult.rawValue)")
                return
            }
            
            for displayID in activeDisplays {
                let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                if result == .success {
                    Logger.debug("Fixed mirroring for display \(displayID)")
                } else {
                    Logger.warning("Failed to fix mirroring for display \(displayID)")
                }
            }
            
            let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
            if completeResult == .success {
                Logger.info("Mirror screen changed")
            } else {
                Logger.error("Mirroring fix transaction failed: \(completeResult.rawValue)")
            }
        } else {
            Logger.info("Mirroring verification passed - no mirrors detected")
        }
    }
    
    func resetToDefault() async throws {
        let defaultConfig = ServerConfig.defaultConfig()
        try await reconfigure(displays: defaultConfig.displays)
    }
    
    func loadConfig(path: String) async throws {
        let (loadedConfig, _) = ServerConfig.loadOrCreate(path: path)
        options.configPath = path
        options.config = loadedConfig
        try await reconfigure(displays: loadedConfig.displays)
        Logger.info("\(path) Config loaded")
    }
    
    func reloadConfig() async throws {
        guard let path = options.configPath else {
            throw ReconfigurationError.noConfigPath
        }
        try await loadConfig(path: path)
    }

    func isDeviceConnected(_ deviceID: String) -> Bool {
        options.config.displays.contains { display in
            if case let .camera(id) = display.source {
                return id == deviceID
            }
            return false
        }
    }

    func connectCameraDevice(device: CaptureDevice, width: Int, height: Int, fps: Int = 30) async throws {
        guard isStreaming else {
            throw ReconfigurationError.notStreaming
        }

        guard !isDeviceConnected(device.id) else {
            Logger.warning("camera '\(device.name)' is already connected")
            return
        }

        var newDisplays = options.config.displays
        newDisplays.append(DisplayEntry(
            name: device.name,
            width: width,
            height: height,
            refreshHz: Double(fps),
            hiDPI: false,
            source: .camera(deviceID: device.id)
        ))

        try await reconfigure(displays: newDisplays)
        Logger.info("connected camera '\(device.name)' as new display")
    }

    func disconnectCameraDevice(_ deviceID: String) async throws {
        guard isStreaming else {
            throw ReconfigurationError.notStreaming
        }

        let newDisplays = options.config.displays.filter { display in
            if case let .camera(id) = display.source {
                return id != deviceID
            }
            return true
        }

        guard newDisplays.count < options.config.displays.count else {
            Logger.error("camera device '\(deviceID)' not found")
            return
        }

        try await reconfigure(displays: newDisplays)
        Logger.warning("disconnected camera device '\(deviceID)'")
    }

    // MARK: Runtime

    func run() async throws {
        let config = options.config
        try config.validate()

        let descriptors = config.displays.enumerated().map { index, entry in
            StreamDescriptor(id: UInt8(index),
                             codec: config.encoderConfig(for: entry).codec,
                             width: entry.width,
                             height: entry.height,
                             refreshHz: entry.refreshHz,
                             hiDPI: entry.hiDPI,
                             name: entry.name)
        }

        let sink: FrameSink
        var sinkNeedsClient = false
        switch options.sink {
        case let .file(path):
            sink = FileFrameSink(path: path)
            Logger.info("sink: file \(path)")
        case let .tcp(port):
            sink = try TCPFrameSink(port: port)
            sinkNeedsClient = true
            Logger.info("sink: tcp :\(port) (protocol v\(WireFormat.version), \(descriptors.count) stream(s))")
        }

        sink.onClientConnected = { [weak self] in
            guard let self else { return }
            stateLock.lock()
            _clientConnected = true
            _everConnected = true
            stateLock.unlock()
            for pipeline in pipelinesSnapshot() {
                pipeline.requestKeyframe()
            }
        }
        sink.onClientDisconnected = { [weak self] in
            guard let self else { return }
            stateLock.lock()
            _clientConnected = false
            stateLock.unlock()
        }

        try sink.start(streams: descriptors)
        self.sink = sink

        if options.adbReverse, case let .tcp(port) = options.sink {
            armAdbReverse(port: port)
        }

        let waitMode = sinkNeedsClient && options.waitForClient
        if !waitMode {
            if sinkNeedsClient {
                Logger.warning("--eager-displays : virtual displays are being created " +
                    "before any client has connected. If nothing attaches, windows may " +
                    "migrate onto screens you cannot see. Stop with the menu bar")
            }
            try await runOneStreamingSession(startedAt: Date())
            await shutdown()
            return
        }

        try await runWaitingLoop()
        await shutdown()
    }

    private func runWaitingLoop() async throws {
        let timeout = options.clientTimeoutSeconds
        let oneShot = options.config.durationSeconds > 0

        while !stopRequested {
            Logger.info("waiting for a client to connect " +
                (timeout > 0 ? " (giving up after \(Int(timeout))s)" : ""))

            let waitStarted = Date()
            while !clientConnected {
                if stopRequested {
                    return
                }
                if timeout > 0, Date().timeIntervalSince(waitStarted) >= timeout {
                    Logger.info("no client connected within \(Int(timeout))s; exiting without " +
                        "creating any virtual displays")
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            try await runOneStreamingSession(startedAt: Date())
            await stopStreaming()

            if oneShot {
                return
            }
            if stopRequested {
                return
            }
        }
    }

    private func runOneStreamingSession(startedAt start: Date) async throws {
        try await startStreaming()

        let duration = options.config.durationSeconds
        let forever = duration <= 0
        Logger.info("streaming \(forever ? "until the client disconnects" : "\(Int(duration))s")" +
            "; \(pipelines.count) display(s)")

        while !stopRequested {
            if !forever, Date().timeIntervalSince(start) >= duration {
                break
            }
            if options.waitForClient, !clientConnected, isTCPSink {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            printStats(elapsed: Date().timeIntervalSince(start))
        }
    }

    private var isTCPSink: Bool {
        if case .tcp = options.sink {
            return true
        }
        return false
    }

    // MARK: Lifecycle for streaming

    private func startStreaming() async throws {
        let config = options.config

        var built: [DisplayPipeline] = []

        var displayConfig: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&displayConfig)
        
        if beginResult != .success || displayConfig == nil {
            Logger.warning("Displays may overlap")
        }
        
        for (index, entry) in config.displays.enumerated() {
            let pipeline = DisplayPipeline(streamID: UInt8(index),
                                           entry: entry,
                                           encoderConfig: config.encoderConfig(for: entry))
            pipeline.onLog = { message in
                Logger.debug(message)
            }
            try pipeline.createDisplay(index: index)

            if let config = displayConfig, let display = pipeline.display {
                let xOffset = Int32(index) * 10000
                let arrangeResult = CGConfigureDisplayOrigin(config, display.displayID, xOffset, 0)
                if arrangeResult == .success {
                    Logger.debug("Configured display \(display.displayID) position at x=\(xOffset)")
                } else {
                    Logger.warning("Failed to configure position for display \(display.displayID) at x=\(xOffset) (error: \(arrangeResult.rawValue))")
                }
            }
            
            built.append(pipeline)
        }

        if let config = displayConfig {
            var activeDisplays: [CGDirectDisplayID] = []
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            if count > 0 {
                activeDisplays = Array(repeating: 0, count: Int(count))
                CGGetActiveDisplayList(count, &activeDisplays, &count)
                
                for displayID in activeDisplays {
                    let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                    if result == .success {
                        Logger.debug("Disabled mirroring for display \(displayID)")
                    } else {
                        Logger.warning("Failed to disable mirroring for display \(displayID) (error: \(result.rawValue))")
                    }
                }
            }
            
            let completeResult = CGCompleteDisplayConfiguration(config, .permanently)
            if completeResult == .success {
                Logger.info("Successfully arranged \(built.count) displays in non-overlapping positions")
            } else {
                Logger.warning("Failed to commit display arrangement (error: \(completeResult.rawValue))")
            }
        }

        setPipelines(built, streaming: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.verifyAndFixMirroring(pipelines: built)
        }

        logFinalDisplayConfiguration(pipelines: built)

        try await Task.sleep(nanoseconds: 700_000_000)

        for pipeline in built {
            pipeline.onEncodedFrame = { [weak sink] frame, streamID in
                sink?.send(frame: frame, streamID: streamID)
            }
        }

        for pipeline in built {
            try await pipeline.startCapture()
        }
    }
    
    private func logFinalDisplayConfiguration(pipelines: [DisplayPipeline]) {
        Logger.info("Created \(pipelines.count) new pipeline(s)")

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            Logger.warning("Could not get active display count")
            return
        }
        
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            Logger.warning("Could not get active display list")
            return
        }
        
        Logger.info("Total active displays in system: \(displayCount)")
    }

    private func stopStreaming() async {
        let current = pipelinesSnapshot()
        guard !current.isEmpty else { return }

        for pipeline in current {
            await pipeline.shutdown()
        }

        setPipelines([], streaming: false)
        Logger.info("virtual displays torn down")
    }

    private func pipelinesSnapshot() -> [DisplayPipeline] {
        stateLock.lock(); defer { stateLock.unlock() }
        return pipelines
    }

    private func setPipelines(_ value: [DisplayPipeline], streaming: Bool) {
        stateLock.lock()
        pipelines = value
        _streaming = streaming
        stateLock.unlock()
    }

    func shutdown() async {
        let totals = pipelinesSnapshot().reduce(into: (f: 0, b: 0, k: 0)) { acc, pipeline in
            let stats = pipeline.stats
            acc.f += stats.frames; acc.b += stats.bytes; acc.k += stats.keyframes
        }
        await stopStreaming()
        sink?.stop()
        sink = nil
        if totals.f > 0 {
            Logger.info("totals: frames=\(totals.f) keyframes=\(totals.k) bytes=\(totals.b)")
        }
        Logger.warning("shutdown complete")
    }

    // MARK: ADB connection

    private func armAdbReverse(port: UInt16) {
        let candidates = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ]
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            Logger.error("adb not found; skipping `adb reverse` (looked in Android SDK and Homebrew)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                Logger.info("adb reverse tcp:\(port) armed")
            } else {
                let errorMsg =
                    "adb reverse failed (status \(process.terminationStatus)): Check if headset is plugged in and authorized for Homebrew"
                Logger.error(errorMsg)

                DispatchQueue.main.async {
                    showModalError(title: "ADB Command Failed", message: errorMsg)
                }
            }
        } catch {
            let errorMsg = "could not run adb command: \(error)"
            Logger.error(errorMsg)
            DispatchQueue.main.async {
                showModalError(title: "ADB Command Failed", message: errorMsg)
            }
        }
    }

    // MARK: Stat Printout

    private func printStats(elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        let current = pipelinesSnapshot()
        guard !current.isEmpty else { return }
        let parts = current.map { pipeline -> String in
            let stats = pipeline.stats
            return String(format: "s%d %.0ffps %.1fMbps", pipeline.streamID,
                          Double(stats.frames) / elapsed,
                          Double(stats.bytes) * 8 / elapsed / 1_000_000)
        }
        Logger.info("stats: " + parts.joined(separator: " | "))
    }
}
