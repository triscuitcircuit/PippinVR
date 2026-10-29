import Foundation

@main
struct WristClockPreferencesTest {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("NEWT_STATE_DIR", directory.path, 1)
        let url = DirectWristClockPreferences.url
        try Data(#"{"enabled":true,"hand":2,"size":2,"format":2,"showDate":false,"position":1,"color":2}"#.utf8).write(to: url)
        assert(DirectWristClockPreferences.enabled)
        try DirectWristClockPreferences.setEnabled(false)
        assert(!DirectWristClockPreferences.enabled)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        assert(saved["hand"] as? Int == 2 && saved["color"] as? Int == 2 && saved["showDate"] as? Bool == false)
        DirectWristClockPreferences.migrateIfNeeded()
        assert(!DirectWristClockPreferences.enabled)
        try Data(#"{"enabled":true,"color":3}"#.utf8).write(to: url, options: .atomic)
        assert(DirectWristClockPreferences.enabled)
        print("PASS: desktop toggle preserves headset customization and observes external preference updates")
    }
}
