import AppKit
import Foundation

let usage = """
pippinvr-server

  --config PATH        JSON config (see Config.swift for the schema)
  --tcp PORT           stream over TCP (use with `adb reverse` for USB)
  --file PATH          write elementary streams to disk instead
  --displays N         quick multi-display: N clones of the default display
  --codec NAME         hevc (default) or h264
  --bitrate MBPS       per-display bitrate, default 40
  --fps N              capture frame rate, default 60
  --width W            display width  (single-display shorthand)
  --height H           display height (single-display shorthand)
  --duration SECS      run time; 0 or omitted-with-config means until stopped

  --eager-displays     create virtual displays immediately instead of waiting for a
                       client. NOT recommended: if nothing connects, windows can
                       migrate onto displays you cannot see.
  --client-timeout S   exit if no client connects for S seconds (default 120, 0 = never)
  --adb-reverse        run `adb reverse tcp:PORT tcp:PORT` at startup. adb reverse is
                       lost on reboot and replug, which is the usual reason the
                       headset silently fails to connect.
  --no-menu-bar        do not install the menu bar item
  --no-dock-icon       run as background accessory (status bar only, no dock icon)
  --gui                run as dock application with menu bar (default if no args)

  --print-config       print the effective config as JSON and exit
  --help               this message

"""

func parseArgs() -> (PipelineOptions, printOnly: Bool, menuBar: Bool, dockIcon: Bool) {
    let args = CommandLine.arguments
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    func has(_ flag: String) -> Bool {
        args.contains(flag)
    }

    if has("--help") || has("-h") {
        print(usage)
        exit(0)
    }

    let (loadedConfig, configPath) = ServerConfig.loadOrCreate(path: value("--config"))
    var config = loadedConfig

    if let c = value("--codec") {
        config.codec = (c.lowercased() == "h264") ? CodecType.h264 : CodecType.hevc
    }
    if let b = value("--bitrate"), let mbps = Int(b) {
        config.bitrateMbps = mbps
    }
    if let f = value("--fps"), let fps = Int(f) {
        config.fps = fps
    }
    if let d = value("--duration"), let dur = Double(d) {
        config.durationSeconds = dur
    }

    // --- display-level shorthands (apply to every configured display) ---
    if let w = value("--width"), let width = Int(w) {
        for i in config.displays.indices {
            config.displays[i].width = width
        }
    }
    if let h = value("--height"), let height = Int(h) {
        for i in config.displays.indices {
            config.displays[i].height = height
        }
    }
    if let n = value("--displays"), let count = Int(n), count > 0 {
        let template = config.displays.first ?? DisplayEntry()
        config.displays = (0 ..< count).map { i in
            var e = template
            e.name = count == 1 ? template.name : "\(template.name)-\(i + 1)"
            return e
        }
    }

    var options = PipelineOptions(config: config)
    options.configPath = configPath

    var sinkExplicitlySet = false
    if let p = value("--tcp"), let port = UInt16(p) {
        options.config.port = port
        options.sink = PipelineOptions.SinkKind.tcp(port: port)
        sinkExplicitlySet = true
    } else if let path = value("--file") {
        options.sink = PipelineOptions.SinkKind.file(path: path)
        sinkExplicitlySet = true
    } else if has("--tcp") {
        options.sink = PipelineOptions.SinkKind.tcp(port: config.port)
        sinkExplicitlySet = true
    }

    let hasAnyFlag = args.count > 1 && args[1 ..< args.count].contains { $0.hasPrefix("--") }
    let wantDockIcon = has("--gui") || (!hasAnyFlag && !has("--no-dock-icon"))
    let wantMenuBar = !has("--no-menu-bar")
    let isGUIMode = wantMenuBar || wantDockIcon

    if has("--eager-displays") {
        options.waitForClient = false
    } else if isGUIMode {
        options.waitForClient = false
    } else {
        options.waitForClient = true
    }

    options.adbReverse = has("--adb-reverse")
    if let t = value("--client-timeout"), let seconds = Double(t) {
        options.clientTimeoutSeconds = seconds
    }

    if !sinkExplicitlySet, isGUIMode {
        options.sink = PipelineOptions.SinkKind.tcp(port: config.port)
    }

    return (options, printOnly: has("--print-config"), menuBar: wantMenuBar, dockIcon: wantDockIcon)
}

let (options, printOnly, wantMenuBar, wantDockIcon) = parseArgs()

if printOnly {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(options.config), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(0)
}

nonisolated(unsafe) var activeSession: PipelineSession?
nonisolated(unsafe) var shuttingDown = false
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

@Sendable func beginShutdown(exitCode: Int32) {
    if shuttingDown {
        exit(exitCode)
    }
    shuttingDown = true
    FileHandle.standardError.write(Data("\n[pipeline] shutting down\n".utf8))
    let session = activeSession
    session?.requestStop()
    Task {
        await session?.shutdown()
        exit(exitCode)
    }
}

func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { beginShutdown(exitCode: 0) }
        src.resume()
        signalSources.append(src)
    }
}

installSignalHandlers()

let session = PipelineSession(options: options)
activeSession = session

Task { @MainActor in
    var statusController: StatusItemController?
    if wantMenuBar {
        statusController = StatusItemController(session: session) {
            beginShutdown(exitCode: 0)
        }
        statusController?.install()
    }

    do {
        try await session.run()
    } catch {
        FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
        statusController?.remove()
        await session.shutdown()
        exit(1)
    }
    statusController?.remove()
    exit(0)
}

if wantMenuBar || wantDockIcon {
    let app = NSApplication.shared
    app.setActivationPolicy(wantDockIcon ? .regular : .accessory)
    app.run()
} else {
    dispatchMain()
}
