import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }
    private let acknowledgements: [(name: String, detail: String)] = [
        ("Max Thomas (shinyquagsire23)", "Original macOS Quest Link port of Monado and the XRSP protocol work this driver was seeded from."),
        ("Monado contributors", "OpenXR runtime, compositor, and driver framework (Collabora / freedesktop.org)."),
        ("WiVRn contributors", "Streaming video encoder, YUV conversion, and VideoToolbox encoder code."),
        ("Khronos Group", "OpenXR and Vulkan APIs and the OpenXR SDK loader."),
        ("MoltenVK contributors", "Vulkan-to-Metal translation on macOS."),
        ("libusb contributors", "USB device access for the Quest Link transport."),
        ("Cap'n Proto contributors", "Serialization used by the XRSP protocol."),
        ("Eigen contributors", "Linear algebra used by Monado."),
        ("Boost.PFR contributors", "Reflection utilities used by Monado."),
        ("SDL contributors", "Platform support libraries bundled with the runtime.")
    ]

    private func openBundleResource(_ name: String, subdirectory: String? = nil) {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: subdirectory) {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
      ScrollView {
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

            Text("PippinVR is open source under GPLv3.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Link("Read the license", destination: URL(string: "https://github.com/triscuitcircuit/PippinVR/blob/main/LICENSE")!)
                .font(.system(size: 11))
            Link("Report a problem", destination: URL(string: "https://github.com/triscuitcircuit/PippinVR/issues/new?template=bug_report.md")!)
                .font(.system(size: 11))

            Divider()
                .padding(.vertical, 6)
                .frame(width: 160)

            Text("Made by")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Link("triscuitcircuit", destination: URL(string: "https://trzroy.com")!)
                .font(.system(size: 12, weight: .medium))
                .help("https://trzroy.com")

            Divider()
                .padding(.vertical, 6)
                .frame(width: 260)

            Text("Acknowledgements")
                .font(.system(size: 13, weight: .bold))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(acknowledgements, id: \.name) { credit in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(credit.name)
                            .font(.system(size: 11, weight: .semibold))
                        Text(credit.detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button("Acknowledgements (readme.org)") { openBundleResource("readme.org") }
                Button("Open Licenses Folder") {
                    if let url = Bundle.main.url(forResource: "Licenses", withExtension: nil) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
        .frame(width: 420)
      }
      .frame(width: 460, height: 620)
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
