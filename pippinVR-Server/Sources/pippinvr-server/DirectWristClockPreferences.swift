import Foundation

enum DirectWristClockPreferences {
    static var url: URL { DirectMetricsStore.stateDirectory.appendingPathComponent("wrist-clock.json") }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    static var enabled: Bool {
        (read()["enabled"] as? NSNumber)?.boolValue ??
            (UserDefaults.standard.object(forKey: "directWristClock") as? Bool) ?? true
    }

    static func setEnabled(_ enabled: Bool) throws {
        var values = read()
        values["enabled"] = enabled
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func migrateIfNeeded() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? setEnabled(enabled)
    }
}
