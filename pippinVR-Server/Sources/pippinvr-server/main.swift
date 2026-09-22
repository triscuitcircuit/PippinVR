// Over the cable, to a Quest with developer mode on:
//   pippinvr-server --config pippinvr.json --tcp 9943 --adb-reverse

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

  --print-config       print the effective config as JSON and exit
  --help               this message

"""

func parseArgs() -> (PipelineOptions, printOnly: Bool, menuBar: Bool) {
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

    var config: ServerConfig
    if let path = value("--config") {
        do {
            config = try ServerConfig.load(path: path)
        } catch {
            FileHandle.standardError.write(Data("fatal: cannot load \(path): \(error)\n".utf8))
            exit(1)
        }
    } else {
        config = ServerConfig()
        // Without a config file, keep the historical 10s default so a bare run
        // terminates on its own.
        config.durationSeconds = 10
    }

    // --- server-level overrides ---
    if let c = value("--codec") {
        config.codec = (c.lowercased() == "h264") ? .h264 : .hevc
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
    // --displays N clones the first entry N times, giving each a distinct name so the
    // client (and System Settings) can tell them apart.
    if let n = value("--displays"), let count = Int(n), count > 0 {
        let template = config.displays.first ?? DisplayEntry()
        config.displays = (0 ..< count).map { i in
            var e = template
            e.name = count == 1 ? template.name : "\(template.name)-\(i + 1)"
            return e
        }
    }

    var options = PipelineOptions(config: config)
    if let p = value("--tcp"), let port = UInt16(p) {
        options.config.port = port
        options.sink = .tcp(port: port)
    } else if let path = value("--file") {
        options.sink = .file(path: path)
    } else if has("--tcp") {
        options.sink = .tcp(port: config.port)
    }

    options.waitForClient = !has("--eager-displays")
    options.adbReverse = has("--adb-reverse")
    if let t = value("--client-timeout"), let seconds = Double(t) {
        options.clientTimeoutSeconds = seconds
    }

    return (options, printOnly: has("--print-config"), menuBar: !has("--no-menu-bar"))
}

let (options, printOnly, wantMenuBar) = parseArgs()

if printOnly {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(options.config), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    exit(0)
}

// Held so the signal handler and the menu bar can tear the virtual displays down:
// they persist for as long as the CGVirtualDisplay object lives, so exiting without
// shutdown() leaves phantom displays attached until the process is reaped.
nonisolated(unsafe) var activeSession: PipelineSession?
nonisolated(unsafe) var shuttingDown = false
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

@Sendable func beginShutdown(exitCode: Int32) {
    if shuttingDown {
        exit(exitCode)
    } // second request: hard exit
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
        signal(sig, SIG_IGN) // ignore the default action; the source below handles it
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { beginShutdown(exitCode: 0) }
        src.resume()
        signalSources.append(src)
    }
}

installSignalHandlers()

let session = PipelineSession(options: options)
activeSession = session

// The menu bar item needs AppKit's event loop, so this becomes an NSApplication with
// .accessory policy: a menu bar presence, no Dock icon, no bundle required. That loop
// also services the main dispatch queue, which CGVirtualDisplay and the capture
// callbacks depend on -- so it replaces dispatchMain() rather than competing with it.
//
// We must NOT block the main thread (e.g. with a semaphore): starving the main queue
// deadlocks display setup.
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

if wantMenuBar {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    dispatchMain()
}
