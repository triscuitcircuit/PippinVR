import Combine
import Foundation

struct DirectEncodeSample: Identifiable {
    let id: Int
    let date: Date
    let encoded: UInt64
    let stageMs: Double
    let txMs: Double
    let offsetMs: Double?
}

struct DirectNewtSample: Identifiable {
    let id: Int
    let date: Date
    let frames: UInt64
    let fps: Double
    var waitMs: Double?
    var inputMs: Double?
    var prepareMs: Double?
    var renderMs: Double?
    var periodMs: Double?
}

enum DirectMetricEvent {
    case encode(encoded: UInt64, stageMs: Double, txMs: Double, offsetMs: Double?)
    case newtFrames(frames: UInt64, fps: Double)
    case newtStages(waitMs: Double, inputMs: Double, prepareMs: Double, renderMs: Double, periodMs: Double)
    case decoded(frame: Int, predictionDeltaMs: Double)
    case metalFX(input: String, output: String)
}

enum DirectMetricsParser {
    static func parse(line rawLine: String) -> DirectMetricEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.contains("\"source\"") && line.contains("questlink"),
           let data = line.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let json = object as? [String: Any] {
            let encoded = (json["encoded"] as? NSNumber)?.uint64Value ?? 0
            let stage = (json["stage_ms"] as? NSNumber)?.doubleValue
            let tx = (json["tx_ms"] as? NSNumber)?.doubleValue
            if let stage, let tx, stage.isFinite, tx.isFinite, stage >= 0, tx >= 0,
               json["source"] as? String == "questlink" {
                return .encode(encoded: encoded, stageMs: stage, txMs: tx,
                               offsetMs: (json["offset_ms"] as? NSNumber)?.doubleValue)
            }
        }

        if let groups = captures(
            in: line,
            pattern: #"Avg: tx ([0-9.]+)ms, encode [0-9.]+ms.*encoded=([0-9]+).*stage=([0-9.]+)ms"#),
           groups.count == 3,
           let tx = Double(groups[0]), let encoded = UInt64(groups[1]), let stage = Double(groups[2]) {
            let offset = captures(in: line, pattern: #"offset=([0-9.]+)ms"#).flatMap { $0.first }.flatMap(Double.init)
            return .encode(encoded: encoded, stageMs: stage, txMs: tx, offsetMs: offset)
        }

        if let groups = captures(
            in: line,
            pattern: #"rendered ([0-9]+) frames \(([0-9.]+) fps"#),
           groups.count == 2,
           let frames = UInt64(groups[0]), let fps = Double(groups[1]) {
            return .newtFrames(frames: frames, fps: fps)
        }

        if let groups = captures(
            in: line,
            pattern: #"frame stages avg ms: wait=([0-9.]+) input=([0-9.]+) prepare=([0-9.]+) render=([0-9.]+) period=([0-9.]+)"#),
           groups.count == 5 {
            let values = groups.compactMap(Double.init)
            if values.count == 5 {
                return .newtStages(waitMs: values[0], inputMs: values[1], prepareMs: values[2],
                                   renderMs: values[3], periodMs: values[4])
            }
        }

        if let groups = captures(
            in: line,
            pattern: #"Frame ([0-9]+) decoded, delta in prediction time: (-?[0-9.]+)ms"#),
           groups.count == 2,
           let frame = Int(groups[0]), let delta = Double(groups[1]) {
            return .decoded(frame: frame, predictionDeltaMs: delta)
        }

        if let groups = captures(
            in: line,
            pattern: #"MetalFX Spatial Scaler active \(([0-9]+x[0-9]+) -> ([0-9]+x[0-9]+)"#),
           groups.count == 2 {
            return .metalFX(input: groups[0], output: groups[1])
        }

        return nil
    }

    private static let expressions: [String: NSRegularExpression] = {
        let patterns = [
            #"Avg: tx ([0-9.]+)ms, encode [0-9.]+ms.*encoded=([0-9]+).*stage=([0-9.]+)ms"#,
            #"offset=([0-9.]+)ms"#,
            #"rendered ([0-9]+) frames \(([0-9.]+) fps"#,
            #"frame stages avg ms: wait=([0-9.]+) input=([0-9.]+) prepare=([0-9.]+) render=([0-9.]+) period=([0-9.]+)"#,
            #"Frame ([0-9]+) decoded, delta in prediction time: (-?[0-9.]+)ms"#,
            #"MetalFX Spatial Scaler active \(([0-9]+x[0-9]+) -> ([0-9]+x[0-9]+)"#
        ]
        return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (pattern, $0) }
        })
    }()

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = expressions[pattern] else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}

@MainActor
final class DirectMetricsStore: ObservableObject {
    @Published private(set) var encodeSamples: [DirectEncodeSample] = []
    @Published private(set) var newtSamples: [DirectNewtSample] = []
    @Published private(set) var latestDecodedFrame: Int?
    @Published private(set) var latestDecodePredictionDeltaMs: Double?
    @Published private(set) var metalFXDescription: String?
    @Published private(set) var lastUpdated: Date?

    nonisolated static let localLogNotification = Notification.Name("PippinVR.DirectMetricsLog")
    private var logSubscription: AnyCancellable?
    private var timer: Timer?
    private var offsets: [URL: UInt64] = [:]
    private var partialLines: [URL: Data] = [:]
    private var nextEncodeID = 0
    private var nextNewtID = 0
    private var pendingNewtID: Int?
    private var lastJSONSample: Date?
    private var fileIdentities: [URL: UInt64] = [:]

    nonisolated static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NEWT_STATE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Newt")
    }

    nonisolated static var metricsFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["QL_METRICS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return stateDirectory.appendingPathComponent("pippin-metrics.jsonl")
    }

    nonisolated static var childrenLogURL: URL {
        stateDirectory.appendingPathComponent("children.log")
    }

    nonisolated static func publishLocalLog(_ line: String) {
        guard line.contains("rendered ") || line.contains("frame stages avg ms:") ||
              line.contains("MetalFX Spatial Scaler active") else { return }
        NotificationCenter.default.post(name: localLogNotification, object: line)
    }

    func start() {
        guard timer == nil else { return }
        logSubscription = NotificationCenter.default.publisher(for: Self.localLogNotification)

            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? String }
            .sink { [weak self] line in
                self?.ingest(line: line)
            }
        for url in [Self.metricsFileURL, Self.childrenLogURL] {
            prime(url)
        }
        pollNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
    }

    func pollNow() {
        for url in [Self.metricsFileURL, Self.childrenLogURL] {
            for line in readLines(from: url) {
                if case .encode? = DirectMetricsParser.parse(line: line) {
                    if url == Self.metricsFileURL { lastJSONSample = Date() } else if let lastJSONSample, Date().timeIntervalSince(lastJSONSample) < 5 { continue }
                }
                ingest(line: line)
            }
        }
    }

    func ingest(line: String, date: Date = Date()) {
        guard let event = DirectMetricsParser.parse(line: line) else { return }
        lastUpdated = date
        switch event {
        case let .encode(encoded, stageMs, txMs, offsetMs):
            encodeSamples.append(DirectEncodeSample(
                id: nextEncodeID, date: date, encoded: encoded,
                stageMs: stageMs, txMs: txMs, offsetMs: offsetMs))
            nextEncodeID += 1
            if encodeSamples.count > 240 { encodeSamples.removeFirst(encodeSamples.count - 240) }
        case let .newtFrames(frames, fps):

            newtSamples.append(DirectNewtSample(id: nextNewtID, date: date, frames: frames, fps: fps))
            pendingNewtID = nextNewtID
            nextNewtID += 1
            if newtSamples.count > 240 { newtSamples.removeFirst(newtSamples.count - 240) }
        case let .newtStages(waitMs, inputMs, prepareMs, renderMs, periodMs):

            guard let index = newtSamples.indices.last,
                  newtSamples[index].id == pendingNewtID,
                  date.timeIntervalSince(newtSamples[index].date) < 5 else { return }
            newtSamples[index].waitMs = waitMs
            newtSamples[index].inputMs = inputMs
            newtSamples[index].prepareMs = prepareMs
            newtSamples[index].renderMs = renderMs
            newtSamples[index].periodMs = periodMs
            pendingNewtID = nil
        case let .decoded(frame, deltaMs):
            latestDecodedFrame = frame
            latestDecodePredictionDeltaMs = deltaMs
        case let .metalFX(input, output):
            metalFXDescription = "\(input) → \(output)"
        }
    }

    private func prime(_ url: URL) {
        guard let size = fileSize(url) else { offsets[url] = 0; return }

        offsets[url] = size
        fileIdentities[url] = fileIdentity(url)
        partialLines[url] = Data()
    }

    private func fileIdentity(_ url: URL) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    private func readLines(from url: URL) -> [String] {
        guard let size = fileSize(url), let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var offset = offsets[url] ?? 0
        let identity = fileIdentity(url)
        if offset > size || (fileIdentities[url] != nil && fileIdentities[url] != identity) {
            offset = 0
            partialLines[url] = Data()
        }
        fileIdentities[url] = identity
        guard offset < size else { offsets[url] = size; return [] }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offsets[url] = offset + UInt64(data.count)
            var buffer = partialLines[url] ?? Data()
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
            }
            if buffer.count > 64 * 1024 { buffer.removeAll() }
            partialLines[url] = buffer
            return lines
        } catch {
            return []
        }
    }
}
