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

        VirtualDisplay.logActiveDisplays()

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

        logDisplayDiagnostics()
    }
    
    func disableMirroringInTransaction(_ config: CGDisplayConfigRef) -> Bool {
        let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        
        if result == .success {
            Logger.debug("Configured display \(displayID) to disable mirroring")
            return true
        } else {
            Logger.warning("Failed to configure mirroring disable for display \(displayID) (error: \(result.rawValue))")
            return false
        }
    }
    
    private func logDisplayDiagnostics() {
        let isMirrored = CGDisplayIsInMirrorSet(displayID) != 0
        let mirrorPrimary = CGDisplayMirrorsDisplay(displayID)
        
        let bounds = CGDisplayBounds(displayID)
        
        let isMain = CGDisplayIsMain(displayID) != 0
        
        let isActive = CGDisplayIsActive(displayID) != 0
        Logger.info("""
                    VirtualDisplay created: ID=\(displayID), size=\(width)x\(height)
                            bounds=\(bounds), isMain=\(isMain), isActive=\(isActive)
                            isMirrored=\(isMirrored), mirrorPrimary=\(mirrorPrimary)
                    """)
        
        if isMirrored {
            Logger.warning("Display \(displayID) Mirrored")
        }
        
        if mirrorPrimary != kCGNullDirectDisplay {
            Logger.warning("Display \(displayID) is mirroring display \(mirrorPrimary)")
        }
    }

    func dispose() {}

    // MARK: Diagnostic functions
    
    private static func logActiveDisplays() {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            Logger.warning("Failed to get active display count")
            return
        }
        
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            Logger.warning("Failed to get active display list")
            return
        }
        
        Logger.debug("Currently \(displayCount) active display(s) before creating new virtual display")
        
        for (index, displayID) in displays.enumerated() {
            let bounds = CGDisplayBounds(displayID)
            let isMain = CGDisplayIsMain(displayID) != 0
            let isMirrored = CGDisplayIsInMirrorSet(displayID) != 0
            Logger.debug("  [\(index)] ID=\(displayID), \(Int(bounds.width))x\(Int(bounds.height)), main=\(isMain), mirrored=\(isMirrored)")
        }
    }

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
