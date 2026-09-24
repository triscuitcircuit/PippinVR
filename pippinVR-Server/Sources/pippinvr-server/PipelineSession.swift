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
        log("stop requested")
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

        var built: [DisplayPipeline] = []
        for (index, entry) in displays.enumerated() {
            let pipeline = DisplayPipeline(streamID: UInt8(index),
                                           entry: entry,
                                           encoderConfig: options.config.encoderConfig(for: entry))
            pipeline.onLog = { [weak self] message in self?.log(message) }
            try pipeline.createDisplay(index: index)
            built.append(pipeline)
        }

        setPipelines(built, streaming: true)

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
            log("reconfigured with \(displays.count) display(s), saved to \(path)")
        } else {
            log("reconfigured with \(displays.count) display(s)")
        }
    }

    enum ReconfigurationError: Error, CustomStringConvertible {
        case notRunning
        case notStreaming

        var description: String {
            switch self {
            case .notRunning:
                "reconfiguration failed: session not running"
            case .notStreaming:
                "reconfiguration failed: not currently streaming"
            }
        }
    }

    func resetToDefault() async throws {
        let defaultConfig = ServerConfig.defaultConfig()
        try await reconfigure(displays: defaultConfig.displays)
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
            log("sink: file \(path)")
        case let .tcp(port):
            sink = try TCPFrameSink(port: port)
            sinkNeedsClient = true
            log("sink: tcp :\(port) (protocol v\(WireFormat.version), \(descriptors.count) stream(s))")
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

        // 2. Either stream immediately, or wait for a viewer first.
        let waitMode = sinkNeedsClient && options.waitForClient
        if !waitMode {
            if sinkNeedsClient {
                log("WARNING: --eager-displays : virtual displays are being created " +
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
            log("waiting for a client to connect " +
                (timeout > 0 ? " (giving up after \(Int(timeout))s)" : ""))

            let waitStarted = Date()
            while !clientConnected {
                if stopRequested {
                    return
                }
                if timeout > 0, Date().timeIntervalSince(waitStarted) >= timeout {
                    log("no client connected within \(Int(timeout))s; exiting without " +
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
        log("streaming \(forever ? "until the client disconnects" : "\(Int(duration))s")" +
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
        for (index, entry) in config.displays.enumerated() {
            let pipeline = DisplayPipeline(streamID: UInt8(index),
                                           entry: entry,
                                           encoderConfig: config.encoderConfig(for: entry))
            pipeline.onLog = { [weak self] message in self?.log(message) }
            try pipeline.createDisplay(index: index)
            built.append(pipeline)
        }

        setPipelines(built, streaming: true)

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

    private func stopStreaming() async {
        let current = pipelinesSnapshot()
        guard !current.isEmpty else { return }

        for pipeline in current {
            await pipeline.shutdown()
        }

        setPipelines([], streaming: false)
        log("virtual displays torn down")
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
            log("totals: frames=\(totals.f) keyframes=\(totals.k) bytes=\(totals.b)")
        }
        log("shutdown complete")
    }

    // MARK: ADB connection

    private func armAdbReverse(port: UInt16) {
        let candidates = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ]
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log("adb not found; skipping `adb reverse` (looked in Android SDK and Homebrew)")
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
                log("adb reverse tcp:\(port) armed")
            } else {
                let errorMsg =
                    "adb reverse failed (status \(process.terminationStatus)): Check if headset is plugged in and authorized for Homebrew"
                log(errorMsg)

                DispatchQueue.main.async {
                    showModalError(title: "ADB Command Failed", message: errorMsg)
                }
            }
        } catch {
            let errorMsg = "could not run adb command: \(error)"
            log(errorMsg)
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
        log("stats: " + parts.joined(separator: " | "))
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[pipeline] \(message)\n".utf8))
    }
}
