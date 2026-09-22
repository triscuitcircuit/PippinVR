import AppKit
import Foundation
import SwiftUI

@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?

    private var settingsViewController: NSWindowController?

    private let session: PipelineSession
    private let onQuit: @Sendable () -> Void

    init(session: PipelineSession, onQuit: @escaping @Sendable () -> Void) {
        self.session = session
        self.onQuit = onQuit
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "visionpro",
                accessibilityDescription: "PippinVr")
            ?? NSImage(systemSymbolName: "display",
                accessibilityDescription: "PippinVr")
            button.image?.isTemplate = true
        }

        rebuildMenu()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuildMenu() }
        }

        let note = "[pipeline] menu bar item active \n"
        FileHandle.standardError.write(Data(note.utf8))
    }

    func remove() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func rebuildMenu() {
        guard let statusItem else { return }

        let streaming = session.isStreaming
        let connected = session.clientConnected

        let menu = NSMenu()

        let status = if streaming && connected {
            "Streaming to headset"
        } else if streaming {
            "Streaming (client gone)"
        } else {
            "Waiting for headset"
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")

        let display_count = streaming
        ? "\(session.configuredDisplayCount) virtual display(s) active"
        : "No virtual displays created"
        let display_names = streaming ? session.displayNames : [("No virtual displays created", 0, 0)]
        menu.addItem(withTitle: display_count, action: nil, keyEquivalent: "")

        menu.addItem(.separator())

        for (name, width, height) in display_names {
            let title = "\"Display \(name)\" : \(width)x\(height)"
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.target = self
        }

        menu.addItem(.separator())

        let configItem = NSMenuItem(title: "Settings", action: #selector(showConfigWindow), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit PippinVr",
            action: #selector(quitSelected),
            keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu

        if let button = statusItem.button {
            button.appearsDisabled = !streaming
        }
    }
    
    @objc private func showConfigWindow() {
        if settingsViewController == nil {
            let contentView = SettingsView(session: self.session)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "PippinVr"
            window.contentViewController = NSHostingController(rootView: contentView)
            window.isReleasedWhenClosed = false

            settingsViewController = NSWindowController(window: window)
        }

        settingsViewController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitSelected() {
        onQuit()
    }
}
