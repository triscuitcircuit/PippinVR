import Foundation

enum DirectAudioPreferences {
    enum Mode: Int, CaseIterable, Identifiable {
        case off = 0, stereo, hrtf, hrtfHQ
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Off (Mac only)"
            case .stereo: return "Stereo"
            case .hrtf: return "HRTF (3D)"
            case .hrtfHQ: return "HRTF HQ (3D)"
            }
        }
    }

    static var url: URL { DirectMetricsStore.stateDirectory.appendingPathComponent("audio.json") }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    static var mode: Mode { (read()["mode"] as? NSNumber).flatMap { Mode(rawValue: $0.intValue) } ?? .stereo }

    static var macSpeakers: Bool { (read()["macSpeakers"] as? NSNumber)?.boolValue ?? false }

    static func setMode(_ mode: Mode) throws { try write { $0["mode"] = mode.rawValue } }
    static func setMacSpeakers(_ on: Bool) throws { try write { $0["macSpeakers"] = on } }

    static var statusText: String? {
        guard let data = try? Data(contentsOf: DirectMetricsStore.stateDirectory.appendingPathComponent("audio-status.json")),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (status["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        let fromTerminal = (status["fromTerminal"] as? NSNumber)?.boolValue ?? false
        switch status["capture"] as? String {
        case "tap":
            return (status["macMuted"] as? NSNumber)?.boolValue == true
                ? "Now: the Mac is muted while the headset plays the sound."
                : "Now: capturing Mac sound; the Mac keeps playing until the headset takes it."
        case "screencapturekit":
            switch status["reason"] as? String {
            case "no-permission" where fromTerminal:
                return "Now: the Mac keeps playing. PippinVR was started from a terminal, so macOS checks that terminal's permission. Add your terminal app to the System Audio Recording Only list (Privacy & Security › Screen & System Audio Recording; being in the screen recording list above it isn't enough), then restart the terminal. Or open PippinVR from Finder."
            case "no-permission":
                return "Now: the Mac keeps playing. Allow PippinVR under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then reconnect."
            case "tap-silent":
                return "Now: the Mac keeps playing. The system audio tap didn't start although the permission is allowed; reconnect to try it again."
            default:
                return "Now: the Mac keeps playing (muting it needs macOS 14.2 or later)."
            }
        default:
            return nil
        }
    }

    private static func write(_ change: (inout [String: Any]) -> Void) throws {
        var values = read()
        change(&values)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
