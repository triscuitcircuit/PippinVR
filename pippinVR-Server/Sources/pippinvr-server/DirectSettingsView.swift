import AppKit
import SwiftUI

struct DirectSettingsView: View {
    @ObservedObject var controller: DirectStatusItemController

    var body: some View {
        TabView {
            screens.tabItem { Label("Screens", systemImage: "display.2") }
            quality.tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
            devices.tabItem { Label("Device", systemImage: "visionpro") }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 560)
    }

    private var screens: some View {
        Form {
            Section("Screens and feeds") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Add another screen").font(.headline)
                        Text("Create an independent 1920 × 1200 Mac desktop in your headset.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    control("Add Screen", prominent: true)
                }
                Text(controller.running ? "\(controller.panelCount) of \(controller.maxPanels) panels in this session" : "Connect USB Direct from the menu bar to add screens and feeds.")
                    .foregroundStyle(.secondary)
                control("Add Existing Screen")
                control("Add Camera Feed")
                control("Add Video / Media Feed")
            }
            Section("3D view") {
                control("Selected Screen 3D")
                Text("Applies to the selected headset panel. Use stereo side-by-side or over-under content; a flat app window does not contain separate eye views. Native OpenXR apps launch from the menu bar’s Launch 3D App… action.").foregroundStyle(.secondary)
            }
            Section("Arrange panels") {
                control("Remove Last Panel")
                control("Reset Panel Positions")
                Text("Trigger selects the next panel. With the dashboard hidden, use the left stick to move it and the right stick to resize or change distance. Hold squeeze to grab and rotate.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var quality: some View {
        Form {
            Section("Capture") {
                control("Capture Frame Rate")
                control("Panel Resolution")
                Text("Changes apply during the session, or are saved for your next connection. Camera frame rate also depends on the camera.")
                    .foregroundStyle(.secondary)
            }
            Section("Headset") {
                control("Headset Refresh (next connection)")
                control("Encode Scale (next connection)")
                ForEach(controller.settingsMenu.items.filter { $0.title.hasPrefix("Headset refresh from config:") }, id: \.title) { entry in
                    Text(entry.title).foregroundStyle(.secondary)
                }
                Text("Reconnect to apply refresh and encoding changes. In-process Newt requires an app restart. A refresh value in the configuration file takes priority over the setting here; explicit launch environment overrides take priority over both.")
                    .foregroundStyle(.secondary)
            }
            Section("Configuration file") {
                control("Open Config File…")
                ForEach(controller.settingsMenu.items.filter { $0.title.hasPrefix("Config:") }, id: \.title) { entry in
                    Text(entry.title).font(.caption).textSelection(.enabled)
                }
                Text("The file also controls pointer idle time and the movement threshold that brings the pointer back.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var devices: some View {
        Form {
            Section("USB connection") {
                LabeledContent("Session", value: controller.running ? "Active / connecting" : "Disconnected")
                if controller.deviceInfo.isEmpty {
                    Text("No Meta headset detected over USB. Connect your headset with a data cable to see its information.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(controller.deviceInfo) { device in
                Section(device.model == "Unavailable" ? "USB device" : device.model) {
                    LabeledContent("Manufacturer", value: device.manufacturer)
                    LabeledContent("Model / product name", value: device.model)
                    LabeledContent("Device ID / serial number", value: device.serial)
                    LabeledContent("USB vendor ID", value: device.vendorID)
                    LabeledContent("USB product ID", value: device.productID)
                    LabeledContent("USB connection speed", value: device.speed)
                }.textSelection(.enabled)
            }
            Section {
                Text("Information is reported by USB and refreshes automatically. Product names may be generic; a detailed model or serial number is shown only when the device supplies it. USB speed is the negotiated link speed, not measured streaming throughput.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder
    private func control(_ title: String, prominent: Bool = false) -> some View {
        if let entry = controller.settingsMenu.items.first(where: { $0.title == title }) {
            if let submenu = entry.submenu {
                let selected = submenu.items.first(where: { $0.state == .on })?.title
                LabeledContent(title) {
                    Menu(selected ?? "Choose…") {
                        ForEach(Array(submenu.items.enumerated()), id: \.offset) { _, choice in
                            Button {
                                controller.perform(choice)
                            } label: {
                                if choice.state == .on {
                                    Label(choice.title, systemImage: "checkmark")
                                } else {
                                    Text(choice.title)
                                }
                            }.disabled(!choice.isEnabled || choice.action == nil)
                        }
                    }.fixedSize()
                }
            } else if prominent {
                Button(title) { controller.perform(entry) }
                    .buttonStyle(.borderedProminent).disabled(!entry.isEnabled)
            } else {
                Button(title) { controller.perform(entry) }.disabled(!entry.isEnabled)
            }
        }
    }
}
