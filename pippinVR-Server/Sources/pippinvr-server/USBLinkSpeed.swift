import Foundation
import IOKit
enum USBLinkSpeed {
    private static let vidMeta: Int = 0x2833

    struct DeviceInfo: Identifiable {
        let id: UInt64
        let manufacturer: String
        let model: String
        let serial: String
        let vendorID: String
        let productID: String
        let speed: String
    }

    static func connectedDevices() -> [DeviceInfo] {
        for ioClass in ["IOUSBHostDevice", "IOUSBDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(ioClass), &iterator) == KERN_SUCCESS else { continue }
            var result: [DeviceInfo] = []
            var service = IOIteratorNext(iterator)
            while service != 0 {
                if intProperty(service, "idVendor") == vidMeta {
                    var registryID: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(service, &registryID)
                    result.append(DeviceInfo(id: registryID,
                        manufacturer: stringProperty(service, "USB Vendor Name") ?? "Unavailable",
                        model: stringProperty(service, "USB Product Name") ?? "Unavailable",
                        serial: stringProperty(service, "USB Serial Number") ?? "Unavailable",
                        vendorID: String(format: "0x%04X", vidMeta),
                        productID: intProperty(service, "idProduct").map { String(format: "0x%04X", $0) } ?? "Unavailable",
                        speed: intProperty(service, "Device Speed").map { description(forSpeed: $0) } ?? "Unavailable"))
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
            if !result.isEmpty { return result }
        }
        return []
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0),
              let text = value.takeRetainedValue() as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func metaInterfaceName(subclass: Int) -> String? {
        switch subclass {
        case 0x8a: return "XRSP"
        case 0x8b: return "Crosswind"
        case 0x8c: return "Highwind"
        default: return nil
        }
    }

    static func detectQuestLinkSpeed() -> String? {
        for ioClass in ["IOUSBHostDevice", "IOUSBDevice"] {
            if let found = scan(ioClass: ioClass) {
                return found
            }
        }
        return nil
    }

    private static func scan(ioClass: String) -> String? {
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching(ioClass)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard intProperty(service, "idVendor") == vidMeta else {
                continue
            }

            if let speedRaw = intProperty(service, "Device Speed") {
                return description(forSpeed: speedRaw)
            }
            return "Speed not available"
        }
        return nil
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (value.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func description(forSpeed raw: Int) -> String {
        switch raw {
        case 0: return "USB 1.1 Low Speed (1.5 Mbps)"
        case 1: return "USB 1.1 Full Speed (12 Mbps)"
        case 2: return "USB 2.0 High Speed (480 Mbps)"
        case 3: return "USB 3.x SuperSpeed (5 Gbps)"
        case 4: return "USB 3.1 SuperSpeed+ (10 Gbps)"
        case 5: return "USB 3.2 SuperSpeed+ x2 (20 Gbps)"
        default: return "USB (unrecognized speed code \(raw))"
        }
    }
}
