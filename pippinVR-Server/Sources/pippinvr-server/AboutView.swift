import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            
            Text("PippinVR")
                .font(.system(size: 22, weight: .bold))
            
            Text(version)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            Divider()
                .padding(.vertical, 6)
                .frame(width: 160)
            
            Link("PippinVR Github Repository ", destination: URL(string: "https://github.com/triscuitcircuit/PippinVR")!)
                .font(.system(size: 12, weight: .medium))
                .help("https://github.com/triscuitcircuit/PippinVR")
            
            Divider()
                .padding(.vertical, 6)
                .frame(width: 160)
            
            Text("Made by")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            Link("triscuitcircuit", destination: URL(string: "https://trzroy.com")!)
                .font(.system(size: 12, weight: .medium))
                .help("https://trzroy.com")
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .frame(width: 300)
    }
}
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable]
            w.title = ""
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
