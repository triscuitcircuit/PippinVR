import Foundation

@main
struct MetricsParserTest {
    @MainActor
    static func main() async throws {
        guard case let .encode(encoded, stageMs, txMs, offsetMs)? = DirectMetricsParser.parse(
            line: #"{"source":"questlink","ts_ns":1,"encoded":1234,"stage_ms":17.5,"tx_ms":1.25,"offset_ms":12.0}"#
        ) else { fatalError("JSON encode parse failed") }
        assert(encoded == 1234 && stageMs == 17.5 && txMs == 1.25 && offsetMs == 12.0)

        guard case let .encode(encoded2, stage2, tx2, _)? = DirectMetricsParser.parse(
            line: " INFO [comp_ql_calc_frame_pacing] Avg: tx 1.000082ms, encode 5.000000ms, add 0.000000ms (encoded=196 ooo_prevented=65 offset=12.000000ms stage=16.636829ms rawenc=24.067187ms)"
        ) else { fatalError("log encode parse failed") }
        assert(encoded2 == 196 && stage2 > 16.6 && stage2 < 16.7 && tx2 > 0.99 && tx2 < 1.01)

        guard case let .newtFrames(frames, fps)? = DirectMetricsParser.parse(
            line: "[Newt] rendered 90 frames (118.7929 fps, runtime shouldRender=1, submitted=1)"
        ) else { fatalError("newt frames parse failed") }
        assert(frames == 90 && fps > 118.7 && fps < 118.9)

        guard case let .newtStages(wait, _, _, render, period)? = DirectMetricsParser.parse(
            line: "[Newt] frame stages avg ms: wait=7.18 input=0.03 prepare=0.15 render=1.03 period=8.33"
        ) else { fatalError("stage parse failed") }
        assert(wait == 7.18 && render == 1.03 && period == 8.33)

        guard case let .decoded(frame, delta)? = DirectMetricsParser.parse(
            line: " INFO [ql_xrsp_handle_logging] Frame 268 decoded, delta in prediction time: -1.500000ms"
        ) else { fatalError("decoded parse failed") }
        assert(frame == 268 && delta == -1.5)

        guard case let .metalFX(input, output)? = DirectMetricsParser.parse(
            line: "[Newt] MetalFX Spatial Scaler active (2048x1330 -> 3072x1994, Perceptual)"
        ) else { fatalError("metalfx parse failed") }
        assert(input == "2048x1330" && output == "3072x1994")

        assert(DirectMetricsParser.parse(line: " unrelated log ") == nil)

        let store = DirectMetricsStore()
        store.ingest(line: "[Newt] rendered 90 frames (120.0 fps, runtime shouldRender=1, submitted=1)")
        store.ingest(line: "[Newt] frame stages avg ms: wait=7.00 input=0.01 prepare=0.10 render=0.50 period=8.33")
        let samples = store.newtSamples
        assert(samples.count == 1 && samples[0].frames == 90 && samples[0].renderMs == 0.5)
        store.ingest(line: "[Newt] rendered 180 frames (90.0 fps)")
        assert(store.newtSamples.count == 2 && store.newtSamples.last?.fps == 90,
               "FPS must publish without a matching stage line")
        store.ingest(line: "[Newt] frame stages avg ms: wait=7.00 input=0.01 prepare=0.10 render=0.50 period=11.11")
        assert(store.newtSamples.count == 2 && store.newtSamples.last?.periodMs == 11.11)
        store.ingest(line: "[Newt] frame stages avg ms: wait=7.00 input=0.01 prepare=0.10 render=0.50 period=11.11")
        assert(store.newtSamples.count == 2, "Unpaired stage lines must not create fake FPS readings")
        assert(DirectMetricsParser.parse(line: #"{"source":"other","label":"questlink","stage_ms":2,"tx_ms":1}"#) == nil)
        assert(DirectMetricsParser.parse(line: #"{"source":"questlink","stage_ms":-2,"tx_ms":1}"#) == nil)
        for i in 1...300 { store.ingest(line: "[Newt] rendered \(i) frames (90.0 fps)") }
        assert(store.newtSamples.count == 240)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("NEWT_STATE_DIR", directory.path, 1)
        let json = directory.appendingPathComponent("pippin-metrics.jsonl")
        setenv("QL_METRICS_FILE", json.path, 1)
        let log = directory.appendingPathComponent("children.log")
        let sample = #"{"source":"questlink","encoded":10,"stage_ms":16,"tx_ms":1}"# + "\n"
        try sample.write(to: json, atomically: false, encoding: .utf8)
        try "old log\n".write(to: log, atomically: false, encoding: .utf8)
        let tail = DirectMetricsStore()
        tail.start()
        assert(tail.encodeSamples.isEmpty && tail.lastUpdated == nil, "Old files must not appear live")
        func append(_ text: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        try append(sample, to: json)
        try append("Avg: tx 1.000ms, encode 5.000ms (encoded=10 stage=16.000ms)\n", to: log)
        tail.pollNow()
        assert(tail.encodeSamples.count == 1, "JSON and log copies must not double count")
        try append(String(sample.dropLast()), to: json)
        tail.pollNow()
        assert(tail.encodeSamples.count == 1, "Incomplete lines must wait for a newline")
        try append("\n", to: json)
        tail.pollNow()
        assert(tail.encodeSamples.count == 2)
        try sample.write(to: json, atomically: false, encoding: .utf8)
        tail.pollNow()
        assert(tail.encodeSamples.count == 3, "Truncated files must restart at zero")
        try sample.write(to: json, atomically: true, encoding: .utf8)
        tail.pollNow()
        assert(tail.encodeSamples.count == 4, "Same-sized replacement files must restart at zero")

        await Task.detached {
            DirectMetricsStore.publishLocalLog("[Newt] rendered 90 frames (90.0 fps)")
            DirectMetricsStore.publishLocalLog("[Newt] frame stages avg ms: wait=8.00 input=0.01 prepare=0.10 render=0.50 period=11.11")
        }.value
        for _ in 0..<100 {
            if tail.newtSamples.last?.periodMs != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        assert(tail.newtSamples.count == 1 && tail.newtSamples.last?.periodMs == 11.11,
               "Embedded/direct-child log measurements must reach the live store")
        print("PASS: parser, frame/stage pairing, retention, live tail, duplicate sources, partial lines, truncation, rotation and local log bridge")
    }
}
