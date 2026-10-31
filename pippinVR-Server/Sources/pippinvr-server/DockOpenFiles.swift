import Foundation

enum DockOpenFileKind: Equatable {
    case model
    case video
}

struct DockOpenedFile: Equatable {
    let url: URL
    let kind: DockOpenFileKind
}

enum DockOpenClassifier {
    static let modelExtensions: Set<String> = ["usdz", "usd", "usda", "usdc", "obj", "gltf", "glb"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func classify(_ url: URL) -> DockOpenedFile? {
        guard url.isFileURL && !url.path.contains("\n") && !url.path.contains("\r") else { return nil }
        let ext = url.pathExtension.lowercased()
        if modelExtensions.contains(ext) { return DockOpenedFile(url: url, kind: .model) }
        if videoExtensions.contains(ext) { return DockOpenedFile(url: url, kind: .video) }
        return nil
    }

    static func classify(_ urls: [URL]) -> [DockOpenedFile] {
        urls.compactMap(classify)
    }
}

@MainActor
protocol DockOpenedFileReceiving: AnyObject {
    func enqueueDockOpenedFiles(_ files: [DockOpenedFile])
}

@MainActor
final class DockFileOpenRouter {
    static let shared = DockFileOpenRouter()

    private weak var receiver: (any DockOpenedFileReceiving)?
    private var pending: [DockOpenedFile] = []

    func register(_ receiver: any DockOpenedFileReceiving) {
        self.receiver = receiver
        guard !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll()
        receiver.enqueueDockOpenedFiles(queued)
    }

    @discardableResult
    func open(_ urls: [URL]) -> [DockOpenedFile] {
        let files = DockOpenClassifier.classify(urls)
        guard !files.isEmpty else { return [] }
        if let receiver {
            receiver.enqueueDockOpenedFiles(files)
        } else {
            pending.append(contentsOf: files)
        }
        return files
    }
}
