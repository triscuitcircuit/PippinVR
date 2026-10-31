import Darwin
import Foundation

enum VRMirrorConfiguration {
    static var socketPath: String { "/tmp/pippin-vr-view-\(getuid()).sock" }
    static var fpsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PippinVR/vr-view-fps.txt")
    }

    static func writeFPS(_ fps: Int) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fpsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(String(fps).utf8).write(to: fpsURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fpsURL.path)
    }
}
