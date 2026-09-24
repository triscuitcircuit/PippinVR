import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum CodecType {
    case hevc
    case h264

    var cmType: CMVideoCodecType {
        switch self {
        case .hevc: kCMVideoCodecType_HEVC
        case .h264: kCMVideoCodecType_H264
        }
    }
}

struct EncoderConfig {
    var codec: CodecType = .hevc
    var width: Int = 2560
    var height: Int = 1440
    var bitrateBps: Int = 40_000_000
    var keyframeIntervalFrames: Int = 60
    var keyframeIntervalSeconds: Double = 2.0
    var realtime: Bool = true
}

struct EncodedFrame {
    var data: Data
    var pts: CMTime
    var isKeyframe: Bool
}

enum VideoEncoderError: Error, CustomStringConvertible {
    case sessionCreate(OSStatus)
    var description: String {
        switch self {
        case let .sessionCreate(s): "VTCompressionSessionCreate failed: \(s)"
        }
    }
}

final class VideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let config: EncoderConfig

    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private let keyframeLock = NSLock()
    private var forceKeyframeNext = false

    private static let annexBStart: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    init(config: EncoderConfig) throws {
        self.config = config

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: config.codec.cmType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw VideoEncoderError.sessionCreate(status)
        }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, config.realtime as CFBoolean)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean)
        set(kVTCompressionPropertyKey_AverageBitRate, config.bitrateBps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, config.keyframeIntervalFrames as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            config.keyframeIntervalSeconds as CFNumber)
        let profile = config.codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel
        set(kVTCompressionPropertyKey_ProfileLevel, profile)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func requestKeyframe() {
        keyframeLock.lock()
        forceKeyframeNext = true
        keyframeLock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }

        keyframeLock.lock()
        let force = forceKeyframeNext
        forceKeyframeNext = false
        keyframeLock.unlock()

        let frameProperties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            handleEncoded(sampleBuffer)
        }
    }

    func flush() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    func dispose() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: Handle Output

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var out = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            out.append(parameterSets(from: format))
        }
        out.append(annexB(from: blockBuffer))

        onEncodedFrame?(EncodedFrame(data: out, pts: pts, isKeyframe: isKeyframe))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first
        else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private func parameterSets(from format: CMFormatDescription) -> Data {
        var out = Data()
        var count = 0
        if config.codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
        }
        for i in 0 ..< count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = if config.codec == .hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            }
            if status == noErr, let ptr {
                out.append(contentsOf: Self.annexBStart)
                out.append(ptr, count: size)
            }
        }
        return out
    }

    private func annexB(from blockBuffer: CMBlockBuffer) -> Data {
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == noErr,
            let base = dataPointer
        else {
            return Data()
        }

        var out = Data()
        let bytes = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        // Big Endian decoding
        while offset + 4 <= totalLength {
            let nalLength =
                (Int(bytes[offset]) << 24) |
                (Int(bytes[offset + 1]) << 16) |
                (Int(bytes[offset + 2]) << 8) |
                Int(bytes[offset + 3])
            offset += 4
            if nalLength <= 0 || offset + nalLength > totalLength {
                break
            }
            out.append(contentsOf: Self.annexBStart)
            out.append(bytes + offset, count: nalLength)
            offset += nalLength
        }
        return out
    }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        if let session {
            VTSessionSetProperty(session, key: key, value: value)
        }
    }
}
