import Foundation

@main
struct AddonManagerTest {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("registry")
        let panels = root.appendingPathComponent("panels")
        let source = root.appendingPathComponent("addon.json")
        let valid = #"{"apiVersion":1,"id":"sample-addon","name":"Sample","version":"1.0","description":"Test","panel":{"title":"Hello","lines":["World"],"buttons":[{"id":"ok","label":"OK"}],"anchor":"dashboard"}}"#
        try valid.write(to: source, atomically: true, encoding: .utf8)
        let manager = AddonManager(registry: registry, panels: panels)
        try manager.install(from: source)
        assert(manager.addons.count == 1 && !manager.addons[0].enabled)
        let panel = panels.appendingPathComponent("pippin-addon--sample-addon.json")
        assert(!files.fileExists(atPath: panel.path))
        do { try manager.install(from: source); fatalError("duplicate was accepted") } catch {}
        try manager.setEnabled(true, id: "sample-addon")
        assert(manager.addons[0].enabled && files.fileExists(atPath: panel.path))
        let data = try Data(contentsOf: panel)
        let panelJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        assert(panelJSON["title"] as? String == "Hello")
        let reopened = AddonManager(registry: registry, panels: panels)
        assert(reopened.addons.count == 1 && reopened.addons[0].enabled)
        try reopened.setEnabled(false, id: "sample-addon")
        assert(!files.fileExists(atPath: panel.path) && !reopened.addons[0].enabled)
        try reopened.remove(id: "sample-addon")
        assert(reopened.addons.isEmpty)
        for invalid in [valid.replacingOccurrences(of: "sample-addon", with: "../escape"), valid.replacingOccurrences(of: "\"apiVersion\":1", with: "\"apiVersion\":2")] {
            try invalid.write(to: source, atomically: true, encoding: .utf8)
            do { try reopened.install(from: source); fatalError("invalid manifest was accepted") } catch {}
        }
        let package = root.appendingPathComponent("package")
        try files.createDirectory(at: package, withIntermediateDirectories: true)
        let program = package.appendingPathComponent("run.command")
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: program, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let packageManifest = #"{"apiVersion":1,"id":"program-addon","name":"Program","version":"1","description":"Test","entrypoint":"run.command"}"#
        try packageManifest.write(to: package.appendingPathComponent("pippin-addon.json"), atomically: true, encoding: .utf8)
        try reopened.install(from: package)
        try reopened.setAutoStart(true, id: "program-addon")
        let persisted = AddonManager(registry: registry, panels: panels)
        assert(persisted.addons.first?.autoStart == true)
        try reopened.setAutoStart(false, id: "program-addon")
        assert(reopened.addons.first?.autoStart == false)
        let installed = registry.appendingPathComponent("Packages/program-addon/run.command")
        assert(files.isExecutableFile(atPath: installed.path))
        try files.removeItem(at: package)
        try reopened.run(id: "program-addon")
        assert(reopened.runningIDs.contains("program-addon"))
        do { try reopened.run(id: "program-addon"); fatalError("duplicate process accepted") } catch {}
        do { try reopened.remove(id: "program-addon"); fatalError("running add-on removed") } catch {}
        reopened.stop(id: "program-addon")
        for _ in 0..<100 where reopened.runningIDs.contains("program-addon") { try await Task.sleep(for: .milliseconds(20)) }
        assert(!reopened.runningIDs.contains("program-addon"))
        try reopened.remove(id: "program-addon")
        assert(!files.fileExists(atPath: installed.path))
        let escape = root.appendingPathComponent("escape.json")
        try packageManifest.replacingOccurrences(of: "run.command", with: "../run.command").write(to: escape, atomically: true, encoding: .utf8)
        do { try reopened.install(from: escape); fatalError("unsafe entry point accepted") } catch {}
        print("PASS: panel and executable add-ons, install, launch, stop, removal and invalid manifests")
    }
}
