import Foundation

enum DirectScenePreferences {
    static var url: URL { DirectMetricsStore.stateDirectory.appendingPathComponent("scene.json") }

    struct Scene {
        var environment: URL?
        var flippedVertically = false
        var flippedHorizontally = false
        var models: [URL] = []
    }

    static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func load() -> Scene? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var scene = Scene()
        let fileManager = FileManager.default
        if let environment = json["environment"] as? [String: Any], let path = environment["path"] as? String,
           (environment["missing"] as? Bool) != true, fileManager.isReadableFile(atPath: path) {
            scene.environment = URL(fileURLWithPath: path)
            scene.flippedVertically = environment["flipV"] as? Bool ?? false
            scene.flippedHorizontally = environment["flipH"] as? Bool ?? false
        }
        for case let model as [String: Any] in json["models"] as? [Any] ?? [] {
            guard let path = model["path"] as? String, (model["missing"] as? Bool) != true,
                  fileManager.isReadableFile(atPath: path) else { continue }
            scene.models.append(URL(fileURLWithPath: path))
        }
        return scene
    }
}
