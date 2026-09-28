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
        Logger.info("menu bar item active")
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
        
        let configPath = session.configPath ?? "~/.pippinvr/config.json (default)"
        let configPathItem = NSMenuItem(title: "Config: \(configPath)", action: nil, keyEquivalent: "")
        configPathItem.isEnabled = false
        menu.addItem(configPathItem)
        
        let chooseConfigItem = NSMenuItem(title: "Choose Config File...", action: #selector(chooseConfigFile), keyEquivalent: "")
        chooseConfigItem.target = self
        menu.addItem(chooseConfigItem)
        
        let reloadConfigItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadConfigItem.target = self
        menu.addItem(reloadConfigItem)

        menu.addItem(.separator())

        let configItem = NSMenuItem(title: "Settings", action: #selector(showConfigWindow), keyEquivalent: ",")
        configItem.target = self
        menu.addItem(configItem)

        let resetItem = NSMenuItem(title: "Reset to Default", action: #selector(resetToDefault), keyEquivalent: "")
        resetItem.target = self
        resetItem.isEnabled = streaming
        menu.addItem(resetItem)

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
            let contentView = SettingsView(session: session)

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

    @objc private func resetToDefault() {
        Task { @MainActor in
            do {
                try await session.resetToDefault()

                let alert = NSAlert()
                alert.messageText = "Reset Complete"
                alert.informativeText = "Configuration has been reset to 3 default displays."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Reset Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func chooseConfigFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Config File"
        panel.message = "Select a PippinVR config file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                do {
                    try await session.loadConfig(path: url.path)
                    
                    let alert = NSAlert()
                    alert.messageText = "Config Loaded"
                    alert.informativeText = "Configuration loaded from: \(url.path)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Load Config"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
    
    @objc private func reloadConfig() {
        Task { @MainActor in
            do {
                try await session.reloadConfig()
                
                let alert = NSAlert()
                alert.messageText = "Config Reloaded"
                alert.informativeText = "Configuration Loaded"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Reload Config"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func quitSelected() {
        onQuit()
    }
}
