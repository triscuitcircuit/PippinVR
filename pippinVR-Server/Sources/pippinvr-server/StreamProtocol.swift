import CoreMedia
import Foundation

struct StreamDescriptor {
    let id: UInt8
    let codec: CodecType
    let width: Int
    let height: Int
    let refreshHz: Double
    let hiDPI: Bool
    let name: String
}

enum WireFormat {
    static let magic: [UInt8] = Array("MVRS".utf8)
    static let version: UInt16 = 2

    static let keyframeFlag: UInt8 = 0x01
    static let hiDPIFlag: UInt8 = 0x01

    static func sessionHeader(_ streams: [StreamDescriptor]) -> Data {
        var d = Data()
        d.append(contentsOf: magic)
        d.appendBE(version)
        d.appendBE(UInt16(streams.count))
        for s in streams {
            var nameBytes = Array(s.name.utf8)
            if nameBytes.count > Int(UInt8.max) {
                nameBytes = Array(nameBytes.prefix(Int(UInt8.max)))
            }

            d.append(s.id)
            d.append(s.codec.wireID)
            d.appendBE(UInt16(clamping: s.width))
            d.appendBE(UInt16(clamping: s.height))
            d.appendBE(UInt16(clamping: Int(s.refreshHz.rounded())))
            d.append(s.hiDPI ? hiDPIFlag : UInt8(0))
            d.append(UInt8(nameBytes.count))
            d.append(contentsOf: nameBytes)
        }
        return d
    }

    static func framePacket(streamID: UInt8, frame: EncodedFrame) -> Data {
        var d = Data(capacity: 14 + frame.data.count)
        d.append(streamID)
        d.append(frame.isKeyframe ? keyframeFlag : UInt8(0))
        d.appendBE(UInt32(frame.data.count))
        d.appendBE(frame.pts.microseconds)
        d.append(frame.data)
        return d
    }
}

// MARK: Helper functions with writing data

extension Data {
    mutating func appendBE(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ v: UInt64) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
}

extension CMTime {
    var microseconds: UInt64 {
        guard isValid, !isIndefinite, timescale != 0 else { return 0 }
        let usec = (Double(value) / Double(timescale)) * 1_000_000
        return usec > 0 ? UInt64(usec) : 0
    }
}
