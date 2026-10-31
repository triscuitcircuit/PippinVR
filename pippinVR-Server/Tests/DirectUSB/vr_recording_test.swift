import AppKit
import AVFoundation
import CoreGraphics
import Foundation

@main
struct RecordingTest {
    static func image(red: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 48, width: 64, height: 16))
        return context.makeImage()!
    }

    static func check(_ url: URL, mode: VRViewMode) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { fatalError("Missing video track") }
        let expectedWidth = mode == .sideBySide ? 128 : 64
        precondition(Int(track.naturalSize.width) == expectedWidth && Int(track.naturalSize.height) == 64)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { fatalError("Missing frame") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func colors(_ x: Int) -> (Int, Int) {
            let offset = 32 * stride + x * 4
            return (Int(data[offset + 2]), Int(data[offset]))
        }
        let first = colors(32)
        if mode == .right { precondition(first.1 > first.0 + 60) } else { precondition(first.0 > first.1 + 60) }
        if mode == .sideBySide { let second = colors(96); precondition(second.1 > second.0 + 60) }
        let top = 8 * stride + 32 * 4
        let bottom = 56 * stride + 32 * 4
        precondition(Int(data[top + 1]) > max(Int(data[top]), Int(data[top + 2])) + 60, "Video is vertically inverted")
        precondition(Int(data[bottom + 1]) < max(Int(data[bottom]), Int(data[bottom + 2])) - 60, "Video is vertically inverted")
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pippin-record-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eyes = VREyes(left: image(red: 1, blue: 0), right: image(red: 0, blue: 1))
        do {
            let emptyURL = directory.appendingPathComponent("empty.mp4")
            let original = Data("existing recording".utf8)
            try original.write(to: emptyURL)
            let empty = try VRViewRecorder(url: emptyURL, eyes: eyes, mode: .left)
            let done = DispatchSemaphore(value: 0)
            let result = RecordingResult()
            empty.finish { error in result.error = error; done.signal() }
            precondition(done.wait(timeout: .now() + 20) == .success && result.error != nil)
            let retained = try Data(contentsOf: emptyURL)
            precondition(retained == original)
        }
        for mode in VRViewMode.allCases {
            let url = directory.appendingPathComponent(mode.rawValue + ".mp4")
            let original = Data("existing recording".utf8)
            if mode == .right { try original.write(to: url) }
            let recorder = try VRViewRecorder(url: url, eyes: eyes, mode: mode)
            if mode == .right {
                let retained = try Data(contentsOf: url)
                precondition(retained == original)
            }
            let origin = DispatchTime.now().uptimeNanoseconds
            for index in 0..<6 {
                recorder.append(eyes, at: origin + UInt64(index) * 100_000_000)
                Thread.sleep(forTimeInterval: 0.1)
            }
            let done = DispatchSemaphore(value: 0)
            let result = RecordingResult()
            recorder.finish { error in result.error = error; done.signal() }
            precondition(done.wait(timeout: .now() + 20) == .success, "Recorder timed out")
            precondition(result.error == nil, result.error ?? "")
            try check(url, mode: mode)
        }
        print("PASS: recorded SBS, left and right MP4 dimensions and eye pixels")
    }
}
final class RecordingResult: @unchecked Sendable { var error: String? }
