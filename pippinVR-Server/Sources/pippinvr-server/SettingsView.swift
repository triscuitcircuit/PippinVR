import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, displays, cameras, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .displays: return "Displays"
        case .cameras: return "Cameras"
        case .appearance: return "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .displays: return "display"
        case .cameras: return "camera"
        case .appearance: return "paintpalette"
        }
    }
}

private let tintOptions: [Color] = [
    Color(red: 0.04, green: 0.52, blue: 1.0),   // blue
    Color(red: 0.69, green: 0.32, blue: 0.87),  // purple
    Color(red: 1.0, green: 0.22, blue: 0.37),   // pink
    Color(red: 1.0, green: 0.62, blue: 0.04),   // orange
    Color(red: 0.19, green: 0.82, blue: 0.35)   // green
]

struct SettingsView: View {
    let session: PipelineSession

    @State private var selection: SettingsSection = .general
    @State private var editMode = false
    @State private var editedDisplays: [DisplayEntry] = []
    @State private var showError: String?
    @State private var isApplying = false
    @StateObject private var deviceManager = CaptureDeviceManager()

    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("tintIndex") private var tintIndex = 0
    @AppStorage("sidebarIconSize") private var iconSize = 1.0

    private var tint: Color { tintOptions[min(max(tintIndex, 0), tintOptions.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
            Divider()

            HStack(spacing: 0) {
                sidebar
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(selection.title)
                        .font(.system(size: 20, weight: .bold))

                        if let error = showError {
                            errorBanner(error)
                        }

                        switch selection {
                        case .general: generalPanel
                        case .displays: displaysPanel
                        case .cameras: camerasPanel
                        case .appearance: appearancePanel
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .tint(tint)
        .onAppear { applyAppearance() }
        .onChange(of: appearanceMode) { _ in applyAppearance() }
    }

    private var sidebarIconFont: CGFloat { [12, 15, 18][min(max(Int(iconSize), 0), 2)] }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PREFERENCES")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 9)
            .padding(.bottom, 6)

            ForEach(SettingsSection.allCases) { section in
                let selected = selection == section
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: section.icon)
                        .font(.system(size: sidebarIconFont))
                        .frame(width: 20)
                        Text(section.title)
                        .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .foregroundColor(selected ? .white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? AnyShapeStyle(LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 9)
        .frame(width: 190)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                SettingRow("Configuration file") {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundColor(.accentColor)
                        Text(session.configPath ?? "Using default configuration")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                        Button("Reveal in Finder") {
                            if let path = session.configPath {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                        }
                        .disabled(session.configPath == nil)
                    }
                }
            }

            SettingsGroup {
                SettingRow("Port") { valueText("\(session.config.port)") }
                SettingRow("Codec") {
                    valueText(session.config.codec == .hevc ? "HEVC (H.265)" : "H.264")
                }
                SettingRow("Bitrate") { valueText("\(session.config.bitrateMbps) Mbps") }
                SettingRow("FPS", showsDivider: false) { valueText("\(session.config.fps)") }
            }
        }
    }

    // MARK: Displays

    private var displaysPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Virtual Displays")
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                if session.isStreaming {
                    if editMode {
                        Button("Cancel") {
                            editMode = false
                            editedDisplays = []
                        }
                        .disabled(isApplying)

                        Button("Apply Changes") { applyChanges() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplying || editedDisplays.isEmpty)
                    } else {
                        Button("Edit") {
                            editMode = true
                            editedDisplays = session.config.displays
                        }
                    }
                }
            }

            if editMode {
                VStack(spacing: 10) {
                    ForEach(editedDisplays.indices, id: \.self) { index in
                        DisplayEditorRow(display: $editedDisplays[index]) {
                            guard editedDisplays.indices.contains(index) else { return }
                            editedDisplays.remove(at: index)
                        }
                    }

                    Button {
                        editedDisplays.append(DisplayEntry(
                            name: "Display \(editedDisplays.count + 1)",
                            width: 2560,
                            height: 1440,
                            refreshHz: 60,
                            hiDPI: true
                        ))
                    } label: {
                        Label("Add Display", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                }
            } else if session.displayNames.isEmpty {
                SettingsGroup {
                    SettingRow("No displays configured", showsDivider: false) { EmptyView() }
                }
            } else {
                SettingsGroup {
                    ForEach(Array(session.displayNames.enumerated()), id: \.element.0) { offset, display in
                        SettingRow(display.0,
                            help: "\(display.1) × \(display.2)",
                            icon: "display",
                            showsDivider: offset < session.displayNames.count - 1) {
                            EmptyView()
                        }
                    }
                }
            }

            if !session.isStreaming {
                Text("Displays can only be edited while streaming to a headset.")
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }
    
    private var camerasPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Capture Devices")
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    deviceManager.discoverDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh device list")
            }

            if !session.isStreaming {
                SettingsGroup {
                    SettingRow("Connect to a headset to add camera devices.", showsDivider: false) { EmptyView() }
                }
            } else if deviceManager.availableDevices.isEmpty {
                SettingsGroup {
                    SettingRow("No cameras or iPads detected. Connect a device and click refresh.",
                        showsDivider: false) { EmptyView() }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(deviceManager.availableDevices) { device in
                        CaptureDeviceRow(
                            device: device,
                            isConnected: session.isDeviceConnected(device.id)
                        ) {
                            connectDevice(device)
                        } onDisconnect: {
                            disconnectDevice(device)
                        }
                    }
                }
            }
        }
    }

    // MARK: Appearance

    private var appearancePanel: some View {
        SettingsGroup {
            SettingRow("Appearance") {
                Picker("", selection: $appearanceMode) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            SettingRow("Tint color") {
                Button {
                    tintIndex = (tintIndex + 1) % tintOptions.count
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: 27, height: 17)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.2)))
                    .padding(3)
                }
                .buttonStyle(.bordered)
                .help("Click to cycle tint color")
            }

            SettingRow("Sidebar icon size", showsDivider: false) {
                VStack(spacing: 1) {
                    Slider(value: $iconSize, in: 0...2, step: 1)
                    .frame(width: 200)
                    HStack {
                        Text("Small"); Spacer(); Text("Medium"); Spacer(); Text("Large")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 200)
                }
            }
        }
    }

    // MARK: Helpers

    private func valueText(_ text: String) -> some View {
        Text(text).foregroundColor(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)
            Text(message)
            .foregroundColor(.secondary)
            Spacer()
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .cornerRadius(6)
    }

    private func applyAppearance() {
        switch appearanceMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func applyChanges() {
        isApplying = true
        showError = nil

        Task {
            do {
                try await session.reconfigure(displays: editedDisplays)
                await MainActor.run {
                    editMode = false
                    editedDisplays = []
                    isApplying = false
                }
            } catch {
                await MainActor.run {
                    showError = error.localizedDescription
                    isApplying = false
                }
            }
        }
    }

    private func connectDevice(_ device: CaptureDevice) {
        showError = nil

        Task {
            do {
                let (width, height) = deviceManager.defaultResolution(for: device)
                let fps = device.supportedResolutions.first?.maxFps ?? 30.0
                try await session.connectCameraDevice(device: device, width: width, height: height, fps: Int(fps))
            } catch {
                await MainActor.run {
                    showError = "Failed to connect \(device.name): \(error.localizedDescription)"
                }
            }
        }
    }

    private func disconnectDevice(_ device: CaptureDevice) {
        showError = nil

        Task {
            do {
                try await session.disconnectCameraDevice(device.id)
            } catch {
                await MainActor.run {
                    showError = "Failed to disconnect \(device.name): \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Spacer()
            Text("PippinVR")
            .font(.system(size: 20, weight: .bold))
            Spacer()

            HStack(spacing: 4) {
                Text("by")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Link("triscuitcircuit", destination: URL(string: "https://github.com/triscuitcircuit")!)
                    .font(.system(size: 12))
                    .help("https://github.com/triscuitcircuit")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .controlBackgroundColor),
                         Color(nsColor: .windowBackgroundColor)],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

// MARK: Groupings

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    var help: String?
    var icon: String?
    var showsDivider = true
    @ViewBuilder let trailing: Trailing

    init(_ title: String,
    help: String? = nil,
    icon: String? = nil,
    showsDivider: Bool = true,
    @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.help = help
        self.icon = icon
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon).foregroundColor(.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let help {
                        Text(help).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 20)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 48)

            if showsDivider { Divider() }
        }
    }
}

// MARK: Display editor row

struct DisplayEditorRow: View {
    @Binding var display: DisplayEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Display Name", text: $display.name)
                .textFieldStyle(.roundedBorder)

                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 16) {
                labeled("Width") {
                    TextField("Width", value: $display.width, format: .number)
                    .frame(width: 80)
                }
                labeled("Height") {
                    TextField("Height", value: $display.height, format: .number)
                    .frame(width: 80)
                }
                labeled("Refresh Hz") {
                    TextField("Hz", value: $display.refreshHz, format: .number)
                    .frame(width: 60)
                }
                Toggle("HiDPI", isOn: $display.hiDPI)
                .toggleStyle(.checkbox)
                Spacer()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }
}

struct CaptureDeviceRow: View {
    let device: CaptureDevice
    let isConnected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon)
            .font(.title2)
            .foregroundColor(deviceColor)
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 0) {
                Text(device.name).font(.system(size: 13, weight: .medium))

                HStack(spacing: 6) {
                    Text(device.type.label)
                    if let resolution = device.supportedResolutions.first {
                        Text("•")
                        Text("\(resolution.width)×\(resolution.height) @ \(Int(resolution.maxFps))fps")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isConnected {
                Text("Connected")
                .font(.caption)
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)

                Button("Disconnect", action: onDisconnect)
                .buttonStyle(.bordered)
            } else {
                Button("Connect", action: onConnect)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(isConnected ? Color.green.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
            .stroke(isConnected ? Color.green.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var deviceIcon: String {
        if isConnected {
            switch device.type {
            case .builtInCamera: return "camera.fill"
            case .ipad: return "ipad.badge.play"
            case .externalCamera: return "camera.metering.unknown"
            }
        } else {
            return device.type.icon
        }
    }

    private var deviceColor: Color {
        isConnected ? .green : .accentColor
    }
}
