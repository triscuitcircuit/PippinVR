import Foundation

enum DirectPassthroughPreferences {
    static var url: URL { DirectMetricsStore.stateDirectory.appendingPathComponent("passthrough.json") }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    static var allowed: Bool { (read()["allowed"] as? NSNumber)?.boolValue ?? false }
    static var enabled: Bool { allowed && ((read()["enabled"] as? NSNumber)?.boolValue ?? false) }

    static func setAllowed(_ allowed: Bool) throws {
        try write { values in
            values["allowed"] = allowed
            if !allowed { values["enabled"] = false }
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        try write { $0["enabled"] = enabled }
    }

    private static func write(_ change: (inout [String: Any]) -> Void) throws {
        var values = read()
        change(&values)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
