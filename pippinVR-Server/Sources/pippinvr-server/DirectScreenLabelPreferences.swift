import Foundation

enum DirectScreenLabelPreferences {
    static var url: URL { DirectMetricsStore.stateDirectory.appendingPathComponent("screen-labels.json") }

    static var visible: Bool {
        if let data = try? Data(contentsOf: url),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let visible = object["visible"] as? Bool { return visible }
        return (UserDefaults.standard.object(forKey: "directShowScreenLabels") as? Bool) ?? true
    }

    static func setVisible(_ visible: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["visible": visible])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
