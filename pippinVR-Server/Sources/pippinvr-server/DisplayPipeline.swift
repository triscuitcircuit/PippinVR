
import CoreMedia
import Foundation

final class DisplayPipeline: @unchecked Sendable {
    let streamID: UInt8
    let entry: DisplayEntry

    private(set) var display: VirtualDisplay?
    private var capture: ScreenCapture?
    private let encoderConfig: EncoderConfig

    private let encoderLock = NSLock()
    private var _encoder: VideoEncoder?

    private var encoder: VideoEncoder? {
        get { encoderLock.lock(); defer { encoderLock.unlock() }; return _encoder }
        set { encoderLock.lock(); _encoder = newValue; encoderLock.unlock() }
    }

    private let statsLock = NSLock()
    private var _frames = 0
    private var _bytes = 0
    private var _keyframes = 0

    /// Set by the session to route encoded frames into the shared sink.
    var onEncodedFrame: ((EncodedFrame, UInt8) -> Void)?
    var onLog: ((String) -> Void)?

    init(streamID: UInt8, entry: DisplayEntry, encoderConfig: EncoderConfig) {
        self.streamID = streamID
        self.entry = entry
        self.encoderConfig = encoderConfig
    }

    func createDisplay(index: Int) throws {
        let d = try VirtualDisplay(config: entry.displayConfig(index: index))
        display = d
        onLog?("stream \(streamID) '\(entry.name)': display up id=\(d.displayID) \(d.width)x\(d.height)")
    }

    func descriptor() -> StreamDescriptor {
        StreamDescriptor(
            id: streamID,
            codec: encoderConfig.codec,
            width: entry.width,
            height: entry.height,
            refreshHz: entry.refreshHz,
            hiDPI: entry.hiDPI,
            name: entry.name
        )
    }

    func startCapture() async throws {
        guard let display else { return }

        let encoder = try VideoEncoder(config: encoderConfig)
        encoder.onEncodedFrame = { [weak self] frame in
            guard let self else { return }
            statsLock.lock()
            _frames += 1
            _bytes += frame.data.count
            if frame.isKeyframe {
                _keyframes += 1
            }
            statsLock.unlock()
            onEncodedFrame?(frame, streamID)
        }
        self.encoder = encoder

        let capture = ScreenCapture(
            displayID: display.displayID,
            config: CaptureConfig(width: entry.width,
                                  height: entry.height,
                                  fps: entry.fps ?? Int(entry.refreshHz.rounded()))
        )
        capture.onPixelBuffer = { [weak encoder] pixelBuffer, pts in
            encoder?.encode(pixelBuffer: pixelBuffer, pts: pts)
        }
        capture.onError = { [weak self] err in
            self?.onLog?("stream \(self?.streamID ?? 0) capture error: \(err)")
        }
        try await capture.start()
        self.capture = capture

        let mbps = encoderConfig.bitrateBps / 1_000_000
        onLog?("stream \(streamID) '\(entry.name)': capture + \(encoderConfig.codec) \(mbps) Mbps")
    }

    func requestKeyframe() {
        encoder?.requestKeyframe()
    }

    func shutdown() async {
        await capture?.stop()
        encoder?.flush()
        encoder?.dispose()
        capture = nil
        encoder = nil
        display?.dispose()
        display = nil
    }

    var stats: (frames: Int, bytes: Int, keyframes: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (_frames, _bytes, _keyframes)
    }
}
