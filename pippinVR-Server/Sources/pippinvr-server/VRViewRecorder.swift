import AppKit
import AVFoundation
import CoreGraphics

enum VRViewMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side-by-Side"
    case left = "Left Eye"
    case right = "Right Eye"
    var id: String { rawValue }
}

struct VREyes: @unchecked Sendable {
    let left: CGImage
    let right: CGImage
}

final class VRViewRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pippin.vr-view.recording", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let mode: VRViewMode
    private let destination: URL
    private let temporaryURL: URL
    private let replaceExisting: Bool
    private let width: Int
    private let height: Int
    private var startNs: UInt64?
    private var lastTime = CMTime.invalid
    private var appended = 0

    init(url: URL, eyes: VREyes, mode: VRViewMode) throws {
        self.mode = mode
        destination = url
        replaceExisting = FileManager.default.fileExists(atPath: url.path)
        temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".pippinvr-recording-\(UUID().uuidString).mp4")
        width = eyes.left.width * (mode == .sideBySide ? 2 : 1)
        height = eyes.left.height
        writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw RecorderError.cannotStart }
        writer.add(input)
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw writer.error ?? RecorderError.cannotStart
        }
        writer.startSession(atSourceTime: .zero)
    }

    enum RecorderError: LocalizedError {
        case cannotStart
        var errorDescription: String? { "The video recorder could not start with this view size." }
    }

    func append(_ eyes: VREyes, at timestamp: UInt64) {
        guard gate.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { gate.signal() }
            guard writer.status == .writing, input.isReadyForMoreMediaData,
                  eyes.left.width * (mode == .sideBySide ? 2 : 1) == width,
                  eyes.left.height == height, let pool = adaptor.pixelBufferPool else { return }
            if startNs == nil { startNs = timestamp }
            guard let startNs, timestamp >= startNs else { return }
            let time = CMTime(value: Int64(timestamp - startNs), timescale: 1_000_000_000)
            guard !lastTime.isValid || CMTimeCompare(time, lastTime) > 0 else { return }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                  let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            let eyeWidth = width / (mode == .sideBySide ? 2 : 1)
            if mode == .sideBySide {
                context.draw(eyes.left, in: CGRect(x: 0, y: 0, width: eyeWidth, height: height))
                context.draw(eyes.right, in: CGRect(x: eyeWidth, y: 0, width: eyeWidth, height: height))
            } else {
                context.draw(mode == .left ? eyes.left : eyes.right, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            if adaptor.append(buffer, withPresentationTime: time) { lastTime = time; appended += 1 }
        }
    }

    func finish(_ completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard appended > 0, writer.status == .writing else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: temporaryURL)
                completion(writer.error?.localizedDescription ?? "No video frames were recorded.")
                return
            }
            input.markAsFinished()
            writer.finishWriting { [self] in
                guard writer.status == .completed else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    completion(writer.error?.localizedDescription ?? "Recording could not be saved.")
                    return
                }
                do {
                    if replaceExisting {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
                    } else {
                        try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    }
                    completion(nil)
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    completion(error.localizedDescription)
                }
            }
        }
    }
}
