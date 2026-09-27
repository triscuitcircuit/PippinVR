import AVFoundation
import CoreMediaIO
import Foundation
import IOSDeviceCore
import LoggingCore

struct CaptureDevice: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let type: DeviceType
    let supportedResolutions: [Resolution]

    enum DeviceType: Equatable, Hashable {
        case builtInCamera
        case ipad
        case externalCamera

        var icon: String {
            switch self {
            case .builtInCamera: "camera"
            case .ipad: "ipad"
            case .externalCamera: "camera.metering.unknown"
            }
        }

        var label: String {
            switch self {
            case .builtInCamera: "Built-in Camera"
            case .ipad: "iPad Screen (USB)"
            case .externalCamera: "External Camera"
            }
        }
    }

    struct Resolution: Equatable, Hashable {
        let width: Int
        let height: Int
        let maxFps: Double

        var description: String {
            "\(width)×\(height) @ \(Int(maxFps))fps"
        }
    }

    static func == (lhs: CaptureDevice, rhs: CaptureDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
class CaptureDeviceManager: ObservableObject {
    @Published var availableDevices: [CaptureDevice] = []

    private var discoverySession: AVCaptureDevice.DiscoverySession?

    init() {
        setupDeviceDiscovery()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.discoverDevices()
        }
    }

    func discoverDevices() {
        Logger.info("Searching for devices")

        guard let iosDeviceInfos = IOSDeviceCore.discoverDevices() else {
            Logger.warning("Could not find any devices from search")
            availableDevices = []
            return
        }
        
        Logger.info("Found devices: \(iosDeviceInfos.count)")
        
        var devices: [CaptureDevice] = []
        
        for info in iosDeviceInfos {
            guard let avDevice = AVCaptureDevice(uniqueID: info.uniqueID) else {
                Logger.warning("Could not access \(info.name) by UID")
                continue
            }
            
            let type: CaptureDevice.DeviceType
            if info.isIOSDevice {
                type = .ipad
                Logger.info("Device: \(info.name) (modelID: \(info.modelID), \(info.width)×\(info.height))")
            } else if avDevice.deviceType == AVCaptureDevice.DeviceType.builtInWideAngleCamera {
                type = .builtInCamera
            } else {
                type = .externalCamera
            }
            
            let resolutions = extractResolutions(from: avDevice)
            
            devices.append(CaptureDevice(
                id: info.uniqueID,
                name: info.name,
                type: type,
                supportedResolutions: resolutions
            ))
        }
        
        let builtinSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        
        for device in builtinSession.devices {
            if devices.contains(where: { $0.id == device.uniqueID }) {
                continue
            }
            
            devices.append(CaptureDevice(
                id: device.uniqueID,
                name: device.localizedName,
                type: .builtInCamera,
                supportedResolutions: extractResolutions(from: device)
            ))
        }
        
        var seen = Set<String>()
        availableDevices = devices.filter { device in
            if seen.contains(device.id) {
                return false
            }
            seen.insert(device.id)
            return true
        }
        Logger.info("Total Devices Discovered: \(availableDevices.count)")
    }

    func device(for id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }

    func defaultResolution(for device: CaptureDevice) -> (Int, Int) {
        if let res = device.supportedResolutions.first(where: { $0.width == 1920 && $0.height == 1080 }) {
            return (res.width, res.height)
        }

        if let highest = device.supportedResolutions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return (highest.width, highest.height)
        }

        return (1920, 1080)
    }

    // MARK: Private Functions

    private func setupDeviceDiscovery() {
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.discoverDevices()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.discoverDevices()
            }
        }
    }

    private func detectDeviceType(_ device: AVCaptureDevice) -> CaptureDevice.DeviceType {
        if device.modelID == "iOS Device" {
            Logger.info("Found iOS device screen: \(device.localizedName) (modelID: \(device.modelID))")
            return .ipad
        }
        
        let name = device.localizedName.lowercased()

        if name.contains("ipad") || name.contains("iphone") {
            return .ipad
        }

        if name.contains("facetime") || name.contains("isight") || device.deviceType == .builtInWideAngleCamera {
            return .builtInCamera
        }

        return .externalCamera
    }

    private func extractResolutions(from device: AVCaptureDevice) -> [CaptureDevice.Resolution] {
        var resolutionSet = Set<CaptureDevice.Resolution>()

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxFps = format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30.0

            guard dimensions.width > 0 && dimensions.height > 0 else {
                Logger.info("Skipping invalid resolution 0x0 for device \(device.localizedName)")
                continue
            }

            let resolution = CaptureDevice.Resolution(
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                maxFps: maxFps
            )

            resolutionSet.insert(resolution)
        }

        return resolutionSet.sorted { r1, r2 in
            if r1.width * r1.height != r2.width * r2.height {
                return r1.width * r1.height > r2.width * r2.height
            }
            return r1.maxFps > r2.maxFps
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
