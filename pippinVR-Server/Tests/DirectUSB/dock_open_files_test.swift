import Foundation

@MainActor
final class FakeDockReceiver: DockOpenedFileReceiving {
    var received: [DockOpenedFile] = []
    func enqueueDockOpenedFiles(_ files: [DockOpenedFile]) { received.append(contentsOf: files) }
}

@main
struct DockOpenFilesTest {
    static func main() async {
        let model = URL(fileURLWithPath: "/tmp/Scene.GLTF")
        let video = URL(fileURLWithPath: "/tmp/Clip.MOV")
        let text = URL(fileURLWithPath: "/tmp/notes.txt")
        let remote = URL(string: "https://example.com/clip.mp4")!

        assert(DockOpenClassifier.classify(model) == DockOpenedFile(url: model, kind: .model))
        assert(DockOpenClassifier.classify(video) == DockOpenedFile(url: video, kind: .video))
        assert(DockOpenClassifier.classify(text) == nil)
        assert(DockOpenClassifier.classify(remote) == nil)

        for ext in ["usdz", "usd", "usda", "usdc", "obj", "gltf", "glb"] {
            assert(DockOpenClassifier.classify(URL(fileURLWithPath: "/tmp/a.\(ext)"))?.kind == .model, ext)
        }
        for ext in ["mp4", "mov", "m4v"] {
            assert(DockOpenClassifier.classify(URL(fileURLWithPath: "/tmp/a.\(ext)"))?.kind == .video, ext)
        }

        let router = DockFileOpenRouter()
        let queued = await router.open([text, model])
        assert(queued.map(\.kind) == [.model])

        let receiver = FakeDockReceiver()
        await router.register(receiver)
        let coldLaunch = await receiver.received
        assert(coldLaunch.map(\.url) == [model])

        await router.open([video])
        let all = await receiver.received
        assert(all.map(\.url) == [model, video])
        assert(all.map(\.kind) == [.model, .video])
        print("PASS: Dock classifier and cold-launch queue")
    }
}
