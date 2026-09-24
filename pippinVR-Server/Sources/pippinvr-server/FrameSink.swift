import Foundation
import Network

protocol FrameSink: AnyObject {
    func start(streams: [StreamDescriptor]) throws
    func send(frame: EncodedFrame, streamID: UInt8)
    func reconfigure(streams: [StreamDescriptor])
    func stop()

    var onClientConnected: (@Sendable () -> Void)? { get set }

    var onClientDisconnected: (@Sendable () -> Void)? { get set }

    var hasClient: Bool { get }
}

// MARK: File verification with sink

final class FileFrameSink: FrameSink {
    private let basePath: String
    private var handles: [UInt8: FileHandle] = [:]

    var onClientConnected: (@Sendable () -> Void)?
    var onClientDisconnected: (@Sendable () -> Void)?

    var hasClient: Bool {
        true
    }

    init(path: String) {
        basePath = path
    }

    func start(streams: [StreamDescriptor]) throws {
        let single = streams.count == 1
        for s in streams {
            let path = single ? basePath : Self.path(basePath, streamID: s.id)
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let h = FileHandle(forWritingAtPath: path) else {
                throw FrameSinkError.cannotOpen(path)
            }
            handles[s.id] = h
            FileHandle.standardError.write(Data("FileFrameSink: stream \(s.id) -> \(path)\n".utf8))
        }
    }

    func send(frame: EncodedFrame, streamID: UInt8) {
        handles[streamID]?.write(frame.data)
    }

    func reconfigure(streams _: [StreamDescriptor]) {
        FileHandle.standardError.write(Data("FileFrameSink: reconfigure not supported for file output\n".utf8))
    }

    func stop() {
        for h in handles.values {
            try? h.close()
        }
        handles.removeAll()
    }

    private static func path(_ base: String, streamID: UInt8) -> String {
        let url = URL(fileURLWithPath: base)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().path
        return ext.isEmpty ? "\(stem).s\(streamID)" : "\(stem).s\(streamID).\(ext)"
    }
}

enum FrameSinkError: Error, CustomStringConvertible {
    case cannotOpen(String)
    var description: String {
        switch self {
        case let .cannotOpen(p): "cannot open sink file \(p)"
        }
    }
}

// MARK: Wire transport using TCP

final class TCPFrameSink: FrameSink, @unchecked Sendable {
    private static let maxInFlightBytes = 8 * 1024 * 1024

    private let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pippinvr.sink.tcp")

    private let lock = NSLock()
    private var _connection: NWConnection?
    private var _streams: [StreamDescriptor] = []
    private var _awaitingKeyframe: Set<UInt8> = []
    private var _inFlight = 0
    private var _dropped = 0

    var onClientConnected: (@Sendable () -> Void)?
    var onClientDisconnected: (@Sendable () -> Void)?

    var hasClient: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connection != nil
    }

    init(port: UInt16) throws {
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start(streams: [StreamDescriptor]) throws {
        lock.lock()
        _streams = streams
        lock.unlock()

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            lock.lock()
            _connection?.cancel()
            _connection = conn
            _awaitingKeyframe = Set(_streams.map(\.id))
            _inFlight = 0
            _dropped = 0
            let header = WireFormat.sessionHeader(_streams)
            let count = _streams.count
            lock.unlock()

            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    var wasCurrent = false
                    lock.lock()
                    if let current = _connection, current === conn {
                        _connection = nil
                        wasCurrent = true
                    }
                    lock.unlock()
                    if wasCurrent {
                        FileHandle.standardError.write(
                            Data("TCPFrameSink: client disconnected\n".utf8)
                        )
                        onClientDisconnected?()
                    }
                default:
                    break
                }
            }

            conn.start(queue: queue)
            conn.send(content: header, completion: .contentProcessed { _ in })
            FileHandle.standardError.write(
                Data("TCPFrameSink: client connected; sent header for \(count) stream(s)\n".utf8)
            )

            onClientConnected?()
        }
        listener.start(queue: queue)
    }

    func send(frame: EncodedFrame, streamID: UInt8) {
        lock.lock()
        guard let conn = _connection else { lock.unlock(); return } // no client: drop

        if _awaitingKeyframe.contains(streamID) {
            guard frame.isKeyframe else { lock.unlock(); return }
            _awaitingKeyframe.remove(streamID)
        }
        if _inFlight > Self.maxInFlightBytes, !frame.isKeyframe {
            _dropped += 1
            let n = _dropped
            lock.unlock()
            if n % 60 == 0 {
                FileHandle.standardError.write(
                    Data("TCPFrameSink: link saturated, dropped \(n) frames\n".utf8)
                )
            }
            return
        }

        let packet = WireFormat.framePacket(streamID: streamID, frame: frame)
        _inFlight += packet.count
        lock.unlock()

        conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            lock.lock()
            _inFlight -= packet.count
            lock.unlock()
        })
    }

    func reconfigure(streams: [StreamDescriptor]) {
        lock.lock()
        guard let conn = _connection else {
            lock.unlock()
            FileHandle.standardError.write(Data("TCPFrameSink: reconfigure requested but no client connected\n".utf8))
            return
        }

        _streams = streams
        _awaitingKeyframe = Set(streams.map(\.id))

        let packet = WireFormat.reconfigurationPacket(streams)
        let count = streams.count
        lock.unlock()

        conn.send(content: packet, completion: .contentProcessed { _ in })
        FileHandle.standardError.write(
            Data("TCPFrameSink: sent reconfiguration packet for \(count) stream(s)\n".utf8)
        )
    }

    func stop() {
        lock.lock()
        _connection?.cancel()
        _connection = nil
        lock.unlock()
        listener.cancel()
    }
}
