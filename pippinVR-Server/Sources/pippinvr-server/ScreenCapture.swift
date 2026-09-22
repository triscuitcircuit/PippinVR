import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CaptureConfig {
    var width: Int = 2560
    var height: Int = 1440
    var fps: Int = 60
    var pixelFormat: OSType = kCVPixelFormatType_32BGRA
}

enum ScreenCaptureError: Error, CustomStringConvertible {
    case displayNotFound(CGDirectDisplayID)
    var description: String {
        switch self {
        case let .displayNotFound(id): "no SCDisplay for CGDirectDisplayID \(id)"
        }
    }
}

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let config: CaptureConfig
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "pippinvr.capture.output")

    /// Called on the capture queue for every delivered frame.
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    init(displayID: CGDirectDisplayID, config: CaptureConfig) {
        self.displayID = displayID
        self.config = config
    }

    func start() async throws {
        if !CGRequestScreenCaptureAccess() {
            let msg = "ScreenCapture: Screen Recording permission not granted.\n" +
                "Grant it in System Settings > Privacy & Security > Screen Recording\n" +
                "for PippinVR and/or the app running this (terminal)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound(displayID)
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = config.width
        cfg.height = config.height
        cfg.pixelFormat = config.pixelFormat
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        cfg.queueDepth = 5
        cfg.showsCursor = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
    }

    // MARK: Stream Output

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType)
    {
        guard type == .screen, sampleBuffer.isValid else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                     createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status != .complete
        {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onPixelBuffer?(pixelBuffer, pts)
    }

    func stream(_: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
