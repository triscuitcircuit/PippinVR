import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum CameraCaptureError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case noVideoInput(String)
    case sessionConfigurationFailed(String)
    case permissionDenied
    case formatConfigurationFailed(String)

    var description: String {
        switch self {
        case let .deviceNotFound(id): 
            "AVCaptureDevice not found for ID: \(id)"
        case let .noVideoInput(reason): 
            "Could not create video input from device: \(reason)"
        case let .sessionConfigurationFailed(reason): 
            "Failed to configure capture session: \(reason)"
        case .permissionDenied: 
            "Camera access permission denied"
        case let .formatConfigurationFailed(reason):
            "Could not configure device format: \(reason)"
        }
    }
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let device: AVCaptureDevice
    private let config: CaptureConfig
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "pippinvr.camera.output", qos: .userInteractive)

    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    init(device: AVCaptureDevice, config: CaptureConfig) {
        self.device = device
        self.config = config
        super.init()
    }

    func start() async throws {
        Logger.info("Started capture for device: \(device.localizedName)")
        Logger.info("UID: \(device.uniqueID)")
        Logger.info("ModelID: \(device.modelID)")
        Logger.info("DeviceType: \(device.deviceType.rawValue)")
        
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        Logger.info("Camera permission status: \(status.rawValue)")
        switch status {
            case .authorized:
                Logger.info("Camera access")
            case .notDetermined:
                Logger.warning("Requesting camera access")
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted {
                    Logger.error("Camera access denied by user")
                    throw CameraCaptureError.permissionDenied
                }
                Logger.info("Camera access granted")
            case .denied, .restricted:
                
                Logger.error("Camera access denied or restricted")
                throw CameraCaptureError.permissionDenied
            @unknown default:
                Logger.error("Unknown camera permission status")
                throw CameraCaptureError.permissionDenied
            }

        Logger.info("Creating AVCaptureSession")
        let session = AVCaptureSession()

        let isIOSDevice = device.modelID == "iOS Device"
        
        if !isIOSDevice {
            session.sessionPreset = .high
            Logger.info("Configuring device format")
            do {
                try configureDeviceFormat()
            } catch {
                Logger.warning("Failed to configure format: \(error)")
                throw CameraCaptureError.formatConfigurationFailed(error.localizedDescription)
            }
        } else {
            Logger.warning("Skipping preset for iOS screen")
        }

        Logger.info("Initializing AVCaptureDeviceInput")
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
            Logger.info("AVCaptureDeviceInput successfully created")
        } catch {
            Logger.error("Failed to create AVCaptureDeviceInput: \(error)")
            throw CameraCaptureError.noVideoInput("AVCaptureDeviceInput creation failed: \(error.localizedDescription)")
        }

        Logger.info("Adding input to Pippin session")
        if session.canAddInput(input) {
            session.addInput(input)
            Logger.info("New input added to Pippin Session")
        } else {
            Logger.error("Could not add input to Pippin")
            throw CameraCaptureError.sessionConfigurationFailed("Cannot add video input to Pippin session")
        }
        Logger.info("Creating AVCaptureVideoDataOutput")
        let output = AVCaptureVideoDataOutput()
        
        if !isIOSDevice {
            Logger.info("Setting video capture format: \(config.pixelFormat)")
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(config.pixelFormat)
            ]
        } else {
            Logger.warning("Using DAL capture format for iOS device")
        }
        
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        Logger.info("Video capture configuration complete")

        if session.canAddOutput(output) {
            session.addOutput(output)
            Logger.info("Output added to Pippin session")
        } else {
            Logger.error("Could not add output to Pippin session")
            throw CameraCaptureError.sessionConfigurationFailed("Cannot add video output to session")
        }

        Logger.info("Initializing capture session")
        self.session = session
        session.startRunning()
        Logger.info("Pippin Capture session created")
        Logger.info("Waiting on first frame input")
    }

    func stop() async {
        guard let session else { return }
        session.stopRunning()
        self.session = nil
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    
    private var frameCount = 0
    private var firstFrameLogged = false

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from _: AVCaptureConnection) {
        guard sampleBuffer.isValid else { 
            Logger.warning("Invalid sample buffer recieved")
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { 
            Logger.warning("Could not find pixel data from sample buffer")
            return
        }

        frameCount += 1
        
        if !firstFrameLogged {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let formatName = pixelFormatToString(pixelFormat)
            
            Logger.info(
                """
                   First frame from device: \(device.localizedName) recieved
                   Resolution: \(width)×\(height)
                   Pixel Format: \(formatName) (0x\(String(format: "%08x", pixelFormat)))
                   modelID: \(device.modelID)
                """
            )
            firstFrameLogged = true
        }
        
        if frameCount % 60 == 0 {
            Logger.info("\(frameCount) frames captured from \(device.localizedName)")
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onPixelBuffer?(pixelBuffer, pts)
    }

    func captureOutput(_: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from _: AVCaptureConnection) {
        if frameCount < 10 {
            Logger.warning("Frame dropped early: #\(frameCount)")
        }
    }
    
    private func pixelFormatToString(_ format: OSType) -> String {
        let chars = [
            UInt8((format >> 24) & 0xFF),
            UInt8((format >> 16) & 0xFF),
            UInt8((format >> 8) & 0xFF),
            UInt8(format & 0xFF)
        ]
        if let string = String(bytes: chars, encoding: .ascii) {
            return string
        }
        return "unknown"
    }

    // MARK: Private

    private func configureDeviceFormat() throws {
        if let format = bestFormat(for: device, desiredWidth: config.width, desiredHeight: config.height) {
            try device.lockForConfiguration()
            device.activeFormat = format

            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(config.fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            device.unlockForConfiguration()
        }
    }

    private func bestFormat(for device: AVCaptureDevice, desiredWidth: Int, desiredHeight: Int) -> AVCaptureDevice.Format? {
        // Find format with exact resolution match
        let exactMatches = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == desiredWidth && dimensions.height == desiredHeight
        }

        if !exactMatches.isEmpty {
            return exactMatches.max { f1, f2 in
                let fps1 = f1.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 0
                let fps2 = f2.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 0
                return fps1 < fps2
            }
        }

        return device.formats
            .min { f1, f2 in
                let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
                let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)

                let diff1 = abs(Int(d1.width) - desiredWidth) + abs(Int(d1.height) - desiredHeight)
                let diff2 = abs(Int(d2.width) - desiredWidth) + abs(Int(d2.height) - desiredHeight)

                return diff1 < diff2
            }
    }
}
