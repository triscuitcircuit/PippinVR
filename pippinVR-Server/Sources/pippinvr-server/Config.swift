import Foundation

// MARK: Stream processing and declaration

extension CodecType: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "hevc", "h265": self = .hevc
        case "h264", "avc": self = .h264
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown codec '\(raw)' (expected hevc or h264)"
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(self == .hevc ? "hevc" : "h264")
    }

    var wireID: UInt8 {
        self == .hevc ? 0 : 1
    }
}

// MARK: Display config reading

struct DisplayEntry: Codable {
    var name: String = "pippinvr-display"
    var width: Int = 2560
    var height: Int = 1440
    var refreshHz: Double = 60.0
    var hiDPI: Bool = true

    var codec: CodecType? = nil
    var bitrateMbps: Int? = nil
    var fps: Int? = nil

    enum CodingKeys: String, CodingKey {
        case name, width, height, refreshHz, hiDPI, codec, bitrateMbps, fps
    }

    init(name: String = "pippinvr-display", width: Int = 2560, height: Int = 1440,
         refreshHz: Double = 60.0, hiDPI: Bool = true)
    {
        self.name = name; self.width = width; self.height = height
        self.refreshHz = refreshHz; self.hiDPI = hiDPI
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(String.self, forKey: .name) {
            name = v
        }
        if let v = try c.decodeIfPresent(Int.self, forKey: .width) {
            width = v
        }
        if let v = try c.decodeIfPresent(Int.self, forKey: .height) {
            height = v
        }
        if let v = try c.decodeIfPresent(Double.self, forKey: .refreshHz) {
            refreshHz = v
        }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) {
            hiDPI = v
        }
        codec = try c.decodeIfPresent(CodecType.self, forKey: .codec)
        bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps)
    }

    func displayConfig(index: Int) -> DisplayConfig {
        var d = DisplayConfig()
        d.name = name
        d.width = width
        d.height = height
        d.refreshHz = refreshHz
        d.hiDPI = hiDPI
        d.serial = UInt32(0x1000 + index)
        return d
    }
    
}

// MARK: Server Configuration

struct ServerConfig: Codable {
    var port: UInt16 = 9943
    var codec: CodecType = .hevc
    var bitrateMbps: Int = 40
    var fps: Int = 60
    var keyframeIntervalFrames: Int? = nil
    var durationSeconds: Double = 0
    var displays: [DisplayEntry] = [DisplayEntry(name: "pippinvr-main")]

    enum CodingKeys: String, CodingKey {
        case port, codec, bitrateMbps, fps, keyframeIntervalFrames, durationSeconds, displays
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = try c.decodeIfPresent(UInt16.self, forKey: .port) {
            port = v
        }
        if let v = try c.decodeIfPresent(CodecType.self, forKey: .codec) {
            codec = v
        }
        if let v = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) {
            bitrateMbps = v
        }
        if let v = try c.decodeIfPresent(Int.self, forKey: .fps) {
            fps = v
        }
        keyframeIntervalFrames = try c.decodeIfPresent(Int.self, forKey: .keyframeIntervalFrames)
        if let v = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) {
            durationSeconds = v
        }
        if let v = try c.decodeIfPresent([DisplayEntry].self, forKey: .displays), !v.isEmpty {
            displays = v
        }
    }

    static func load(path: String) throws -> ServerConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(ServerConfig.self, from: data)
    }

    func encoderConfig(for entry: DisplayEntry) -> EncoderConfig {
        let effectiveFps = entry.fps ?? fps
        return EncoderConfig(
            codec: entry.codec ?? codec,
            width: entry.width,
            height: entry.height,
            bitrateBps: (entry.bitrateMbps ?? bitrateMbps) * 1_000_000,
            keyframeIntervalFrames: keyframeIntervalFrames ?? effectiveFps,
            realtime: true
        )
    }

    func validate() throws {
        guard displays.count <= Int(UInt8.max) else {
            throw ConfigError.tooManyDisplays(displays.count)
        }
        for d in displays {
            guard d.width > 0, d.height > 0,
                  d.width <= 16384, d.height <= 16384
            else {
                throw ConfigError.badDimensions(d.name, d.width, d.height)
            }
            guard d.width % 2 == 0, d.height % 2 == 0 else {
                throw ConfigError.oddDimensions(d.name, d.width, d.height)
            }
            guard d.refreshHz > 0, d.refreshHz <= 240 else {
                throw ConfigError.badRefresh(d.name, d.refreshHz)
            }
        }
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case tooManyDisplays(Int)
    case badDimensions(String, Int, Int)
    case oddDimensions(String, Int, Int)
    case badRefresh(String, Double)

    var description: String {
        switch self {
        case let .tooManyDisplays(n):
            "too many displays (\(n)); stream ids are a single byte, max 255"
        case let .badDimensions(n, w, h):
            "display '\(n)': invalid dimensions \(w)x\(h)"
        case let .oddDimensions(n, w, h):
            "display '\(n)': dimensions \(w)x\(h) must be even (chroma subsampling)"
        case let .badRefresh(n, hz):
            "display '\(n)': invalid refresh rate \(hz)"
        }
    }
}
