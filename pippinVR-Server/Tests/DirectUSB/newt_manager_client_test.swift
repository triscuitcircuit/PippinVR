import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func waitFor(timeout: TimeInterval = 8, _ check: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await check() { return }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    fail("timed out waiting for condition")
}

@main struct Test {
    static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("newt-manager-client-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let state = root.appendingPathComponent("state")
        let ipc = URL(fileURLWithPath: "/tmp/newt-mct-\(String(UUID().uuidString.prefix(8)))")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: ipc) }

        let events = root.appendingPathComponent("events")
        let runtime = root.appendingPathComponent("runtime.json")
        try "{\"runtime\":{\"library_path\":\"./fake.dylib\"}}".write(to: runtime, atomically: true, encoding: .utf8)
        try "not loaded by fake programs".write(to: root.appendingPathComponent("fake.dylib"), atomically: true, encoding: .utf8)

        let helper = root.appendingPathComponent("dashboard")
        let helperScript = """
        #!/usr/bin/env python3
        from pathlib import Path
        import sys
        p = Path(\(events.path.debugDescription))
        with p.open("a") as f:
            f.write("dashboard-start\\n")
        for line in sys.stdin:
            s = line.strip()
            if s == "stop":
                break
            with p.open("a") as f:
                f.write(f"command:{s}\\n")
        with p.open("a") as f:
            f.write("dashboard-stop\\n")
        """
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let configJSON: [String: Any] = ["dashboard": helper.path, "runtime": runtime.path]
        try JSONSerialization.data(withJSONObject: configJSON)
            .write(to: state.appendingPathComponent("config.json"))

        let daemonCandidates = [
            ProcessInfo.processInfo.environment["NEWTD"],
            ProcessInfo.processInfo.environment["PIPPINVR_NEWT_DAEMON"],
            ".build/newt/newtd",
            "../Newt/build/newtd",
            "../Newt/build-install/newtd"
        ].compactMap { $0 }
        guard let daemonPath = daemonCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            fail("no built newtd found (set NEWTD or build Newt first)")
        }
        let daemon = URL(fileURLWithPath: daemonPath).standardizedFileURL

        var environment = ProcessInfo.processInfo.environment
        environment["NEWT_STATE_DIR"] = state.path
        environment["NEWT_IPC_DIR"] = ipc.path
        setenv("NEWT_STATE_DIR", state.path, 1)
        setenv("NEWT_IPC_DIR", ipc.path, 1)
        setenv("PIPPINVR_NEWT_DAEMON", daemon.path, 1)

        let serve = Process()
        serve.executableURL = daemon
        serve.arguments = ["serve"]
        serve.environment = environment
        let serveOutput = Pipe()
        serve.standardOutput = serveOutput
        serve.standardError = serveOutput
        try serve.run()
        defer {
            if serve.isRunning { serve.terminate(); serve.waitUntilExit() }
        }

        let client = NewtManagerClient()

        await waitFor {
            (try? await client.status()) != nil
        }

        let status1 = try await client.status()
        guard status1.state == "dashboard" else {
            fail("expected dashboard state, got \(status1)")
        }
        print("PASS: NewtManagerClient connects and reads status over the real socket")

        guard try await client.command("ping") else {
            fail("expected command to be delivered")
        }
        await waitFor {
            (try? String(contentsOf: events, encoding: .utf8))?.contains("command:ping") ?? false
        }
        print("PASS: command passthrough reaches the real dashboard's stdin")

        let drained = try await client.pollHostRequests()
        guard drained.isEmpty else {
            fail("expected no pending host requests yet, got \(drained)")
        }
        print("PASS: pollHostRequests returns empty with nothing queued")

        try await client.ensureRunning()
        let status2 = try await client.status()
        guard status2.state == "dashboard" else {
            fail("ensureRunning against an already-running manager changed state: \(status2)")
        }
        print("PASS: ensureRunning is idempotent against an already-running manager")

        try await client.stop()
        waitUntilExit(serve)
        print("PASS: stop ends the manager cleanly")
    }
}

func waitUntilExit(_ process: Process) {
    process.waitUntilExit()
}
