import AppKit

@MainActor
final class MenuActions: NSObject, NSMenuItemValidation {
    static let shared = MenuActions()

    @objc func showAbout() {
        AboutWindowController.shared.show()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        SparkleUpdater.shared.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates(_:)) || SparkleUpdater.shared.canCheckForUpdates
    }
}

@MainActor
enum MainMenu {
    static func install(appName: String = "PippinVR") {
        SparkleUpdater.shared.startIfConfigured()
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: appName)
        appItem.submenu = appMenu

        let about = NSMenuItem(title: "About \(appName)",
                               action: #selector(MenuActions.showAbout),
                               keyEquivalent: "")
        about.target = MenuActions.shared
        appMenu.addItem(about)

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(MenuActions.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = MenuActions.shared
        appMenu.addItem(updates)
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
