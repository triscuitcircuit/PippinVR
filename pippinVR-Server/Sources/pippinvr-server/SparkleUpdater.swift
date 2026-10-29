import AppKit
import Sparkle

@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(feed?.isEmpty ?? true) && !(key?.isEmpty ?? true)
    }

    func startIfConfigured() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? isConfigured }

    func checkForUpdates(_ sender: Any?) {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Software updates are not configured in this build"
            alert.informativeText = "This build does not have software updates configured."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        startIfConfigured()
        controller?.checkForUpdates(sender)
    }
}
