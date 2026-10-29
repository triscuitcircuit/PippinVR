import Darwin
import Foundation

actor NewtManagerClient {
    enum ClientError: Error, CustomStringConvertible {
        case bundledDaemonMissing
        case connectionFailed(String)
        case protocolError(String)
        case commandFailed(String)

        var description: String {
            switch self {
            case .bundledDaemonMissing:
                "Bundled Newt manager daemon (newtd) not found (build with Newt packaging enabled)"
            case let .connectionFailed(message):
                "Newt manager connection failed: \(message)"
            case let .protocolError(message):
                "Newt manager protocol error: \(message)"
            case let .commandFailed(message):
                message
            }
        }
    }

    private static let maxMessageBytes = 65536

    private let stateDir: String
    private let socketPath: String

    init() {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        stateDir = environment["NEWT_STATE_DIR"] ?? home + "/Library/Application Support/Newt"
        let ipcDir = environment["NEWT_IPC_DIR"] ?? "/tmp/newt-session-\(getuid())"
        socketPath = ipcDir + "/session.sock"
    }

    private func request(_ message: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.connectionFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClientError.connectionFailed("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw ClientError.connectionFailed(String(cString: strerror(errno)))
        }

        let payload = try JSONSerialization.data(withJSONObject: message) + Data([0x0A])
        try payload.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard n > 0 else {
                    throw ClientError.connectionFailed("send failed: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let n = chunk.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
            }
            guard n > 0 else {
                throw ClientError.connectionFailed("recv failed or connection closed")
            }
            received.append(chunk, count: n)
            guard received.count <= Self.maxMessageBytes else {
                throw ClientError.protocolError("response too large")
            }
        }
        guard let newline = received.firstIndex(of: 0x0A) else {
            throw ClientError.protocolError("missing newline")
        }
        guard let json = try JSONSerialization.jsonObject(with: received[..<newline]) as? [String: Any] else {
            throw ClientError.protocolError("expected a JSON object")
        }
        return json
    }

    struct ManagerStatus: Sendable {
        let ok: Bool
        let state: String?
        let error: String?
        let lastDashboardExit: Int32?
    }

    func status() async throws -> ManagerStatus {
        let response = try request(["action": "status"])
        return ManagerStatus(ok: (response["ok"] as? Bool) ?? false,
                              state: response["state"] as? String,
                              error: response["error"] as? String,
                              lastDashboardExit: (response["last_dashboard_exit"] as? NSNumber)?.int32Value)
    }

    func command(_ text: String) async throws -> Bool {
        let response = try request(["action": "command", "command": text])
        return (response["delivered"] as? Bool) ?? false
    }

    func pollHostRequests() async throws -> [Int] {
        let response = try request(["action": "poll-host-requests"])
        return (response["requests"] as? [Int]) ?? []
    }

    func launch(argv: [String], cwd: String? = nil) async throws {
        var message: [String: Any] = ["action": "launch", "argv": argv]
        if let cwd { message["cwd"] = cwd }
        let response = try request(message)
        guard (response["ok"] as? Bool) == true else {
            throw ClientError.commandFailed((response["error"] as? String) ?? "launch failed")
        }
    }

    func stopGame() async throws {
        _ = try request(["action": "stop-game"])
    }

    func stop() async throws {
        _ = try request(["action": "stop"])
    }

    func resume() async throws {
        let response = try request(["action": "resume"])
        guard (response["ok"] as? Bool) == true else {
            throw ClientError.commandFailed((response["error"] as? String) ?? "resume failed")
        }
    }

    func ensureRunning() async throws {
        _ = try runBundledCLI(["start"])
    }

    func configure(dashboard: String, runtime: String, icd: String?, apps: [(title: String, target: String)],
                    environment: [String: String] = [:]) async throws {
        var arguments = ["configure", "--dashboard", dashboard, "--runtime", runtime]
        if let icd { arguments += ["--icd", icd] }
        for app in apps {
            arguments += ["--app", "\(app.title)=\(app.target)"]
        }
        for (key, value) in environment {
            arguments += ["--env", "\(key)=\(value)"]
        }
        _ = try runBundledCLI(arguments)
    }

    private static func bundledDaemonURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["PIPPINVR_NEWT_DAEMON"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("newtd")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func runBundledCLI(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        if let daemon = Self.bundledDaemonURL() {
            process.executableURL = daemon
            process.arguments = arguments
        } else {
            throw ClientError.bundledDaemonMissing
        }
        process.environment = ProcessInfo.processInfo.environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClientError.commandFailed("newtd \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.protocolError("expected a JSON object from newtd")
        }
        return json
    }
}
