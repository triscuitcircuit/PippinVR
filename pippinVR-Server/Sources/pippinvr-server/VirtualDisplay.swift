import CoreGraphics
import Foundation
import ObjectiveC.runtime

struct DisplayConfig {
    var width: Int = 2560
    var height: Int = 1440
    var refreshHz: Double = 60.0
    var hiDPI: Bool = true
    var name: String = "pippinvr-display"
    var productID: UInt32 = 0x1234
    var vendorID: UInt32 = 0x3456
    var serial: UInt32 = 0x0001
}

enum VirtualDisplayError: Error, CustomStringConvertible {
    case classUnavailable(String)
    case selectorMissing(String)
    case creationFailed
    case zeroDisplayID

    var description: String {
        switch self {
        case let .classUnavailable(n): "CGVirtualDisplay class unavailable: \(n)"
        case let .selectorMissing(s): "expected selector missing: \(s)"
        case .creationFailed: "CGVirtualDisplay init returned nil"
        case .zeroDisplayID: "virtual display created but displayID is 0"
        }
    }
}

final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int

    private let display: NSObject

    init(config: DisplayConfig) throws {
        width = config.width
        height = config.height

        guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass = NSClassFromString("CGVirtualDisplay")
        else {
            throw VirtualDisplayError.classUnavailable("CGVirtualDisplay*")
        }
        let desc = descClass.init()
        VirtualDisplay.setIfPresent(desc, "name", config.name)
        VirtualDisplay.setIfPresent(desc, "maxPixelsWide", UInt32(config.width))
        VirtualDisplay.setIfPresent(desc, "maxPixelsHigh", UInt32(config.height))
        VirtualDisplay.setIfPresent(
            desc, "sizeInMillimeters",
            NSValue(size: CGSize(width: Double(config.width) / 5.0,
                                 height: Double(config.height) / 5.0))
        )
        VirtualDisplay.setIfPresent(desc, "productID", config.productID)
        VirtualDisplay.setIfPresent(desc, "vendorID", config.vendorID)
        VirtualDisplay.setIfPresent(desc, "serialNum", config.serial)
        VirtualDisplay.setIfPresent(desc, "queue", DispatchQueue.main)
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let modeAlloc = VirtualDisplay.rtAlloc(modeClass)
        guard modeAlloc.responds(to: modeSel) else {
            throw VirtualDisplayError.selectorMissing("initWithWidth:height:refreshRate:")
        }
        typealias ModeInit = @convention(c)
            (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>
        let modeImp = modeAlloc.method(for: modeSel)!
        let mode = unsafeBitCast(modeImp, to: ModeInit.self)(
            modeAlloc, modeSel, UInt32(config.width), UInt32(config.height),
            config.refreshHz
        ).takeRetainedValue()

        let dispSel = NSSelectorFromString("initWithDescriptor:")
        let dispAlloc = VirtualDisplay.rtAlloc(displayClass)
        guard dispAlloc.responds(to: dispSel) else {
            throw VirtualDisplayError.selectorMissing("initWithDescriptor:")
        }
        typealias DispInit = @convention(c)
            (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>
        let dispImp = dispAlloc.method(for: dispSel)!
        let dispObject = unsafeBitCast(dispImp, to: DispInit.self)(
            dispAlloc, dispSel, desc
        ).takeRetainedValue()
        guard let disp = dispObject as? NSObject else {
            throw VirtualDisplayError.creationFailed
        }

        let settings = settingsClass.init()
        VirtualDisplay.setIfPresent(settings, "hiDPI", UInt32(config.hiDPI ? 1 : 0))
        VirtualDisplay.setIfPresent(settings, "modes", [mode])

        let applySel = NSSelectorFromString("applySettings:")
        guard disp.responds(to: applySel) else {
            throw VirtualDisplayError.selectorMissing("applySettings:")
        }
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applyImp = disp.method(for: applySel)!
        _ = unsafeBitCast(applyImp, to: Apply.self)(disp, applySel, settings)

        let idSel = NSSelectorFromString("displayID")
        guard disp.responds(to: idSel) else {
            throw VirtualDisplayError.selectorMissing("displayID")
        }
        typealias GetID = @convention(c) (AnyObject, Selector) -> UInt32
        let idImp = disp.method(for: idSel)!
        let did = unsafeBitCast(idImp, to: GetID.self)(disp, idSel)
        guard did != 0 else { throw VirtualDisplayError.zeroDisplayID }

        displayID = did
        display = disp
    }

    func dispose() {}

    // MARK: Helper functions for runtime

    private static func rtAlloc(_ cls: AnyClass) -> AnyObject {
        let sel = NSSelectorFromString("alloc")
        let meta: AnyClass = object_getClass(cls)!
        let imp = method_getImplementation(class_getInstanceMethod(meta, sel)!)
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject
        return unsafeBitCast(imp, to: AllocFn.self)(cls, sel)
    }

    private static func setIfPresent(_ obj: NSObject, _ key: String, _ value: Any) {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        if obj.responds(to: NSSelectorFromString(setter)) {
            obj.setValue(value, forKey: key)
        } else {
            FileHandle.standardError.write(Data("VirtualDisplay: no setter for \(key)\n".utf8))
        }
    }
}
