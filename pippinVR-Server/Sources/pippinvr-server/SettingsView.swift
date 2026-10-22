import AppKit
import Combine
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, screens, quality, apps, cameras, device, appearance, transport, environment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .screens: return "Screens"
        case .quality: return "Quality"
        case .apps: return "Apps"
        case .cameras: return "Cameras"
        case .device: return "Device"
        case .appearance: return "Appearance"
        case .transport: return "Transport"
        case .environment: return "Environment"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .screens: return "display.2"
        case .quality: return "slider.horizontal.3"
        case .apps: return "cube"
        case .cameras: return "camera"
        case .device: return "visionpro"
        case .appearance: return "paintpalette"
        case .transport: return "cable.connector"
        case .environment: return "globe"
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
    var questSession: PipelineSession?
    var directController: DirectStatusItemController?
    var onQuit: (() -> Void)?
    @State private var tick = false

    @State private var selection: SettingsSection = .general
    @State private var editMode = false
    @State private var editedDisplays: [DisplayEntry] = []
    @State private var showError: String?
    @State private var isApplying = false
    @StateObject private var deviceManager = CaptureDeviceManager()
    @State private var showDirectUSBPrompt = false

    @State private var wireSpeedMbps: Double = 0
    @State private var discoveredPeakMbps: Double = 0
    @State private var speedTestRunning = false
    @State private var speedTestResult: String?
    @State private var usbLinkSpeed: String?
    @State private var deviceInfo: [USBLinkSpeed.DeviceInfo] = []
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

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
                        case .screens: screensPanel
                        case .quality: qualityPanel
                        case .apps: appsPanel
                        case .cameras: camerasPanel
                        case .device: devicePanel
                        case .appearance: appearancePanel
                        case .transport: transportPanel
                        case .environment: environmentPanel
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .tint(tint)
        .onAppear { applyAppearance() }
        .onChange(of: appearanceMode) { _ in applyAppearance() }
        .onReceive(refreshTimer) { _ in
            if let questSession {
                wireSpeedMbps = questSession.currentThroughputMbps
                usbLinkSpeed = USBLinkSpeed.detectQuestLinkSpeed()
            }
            deviceInfo = USBLinkSpeed.connectedDevices()
            tick.toggle()
        }
        .alert("Direct USB needs Newt", isPresented: $showDirectUSBPrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Switch to Direct USB") { switchToDirectUSB() }
        } message: {
            Text("Direct USB connects over a USB cable with no sideloaded APK required, but it "
                + "talks to Newt instead of this app's built-in TCP "
                + "transport. PippinVR will quit this window and relaunch in Direct "
                + "USB mode.")
        }
    }

    private func switchToDirectUSB() {
        guard let executable = Bundle.main.executableURL else { return }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--direct-usb", "--gui", "--connect-direct"]
        var environment = ProcessInfo.processInfo.environment
        environment["PIPPINVR_WAIT_FOR_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        child.environment = environment
        do {
            try child.run()
            onQuit?()
        } catch {
            showError = "Could not start USB Direct: \(error)"
        }
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

    // MARK: General

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                SettingRow("Mode") {
                    valueText(questSession != nil ? "Quest Client (APK)" : "Direct USB")
                }
                SettingRow("Configuration file", showsDivider: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundColor(.accentColor)
                        Text(configPath ?? "Using default configuration")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                        Button("Reveal in Finder") {
                            if let path = configPath {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                        }
                        .disabled(configPath == nil)
                    }
                }
            }

            if let questSession {
                Text("Wire Protocol")
                .font(.system(size: 13, weight: .semibold))

                SettingsGroup {
                    SettingRow("Port") { valueText("\(questSession.config.port)") }
                    SettingRow("Codec") {
                        valueText(questSession.config.codec == .hevc ? "HEVC (H.265)" : "H.264")
                    }
                    SettingRow("Bitrate") { valueText("\(questSession.config.bitrateMbps) Mbps") }
                    SettingRow("FPS", showsDivider: false) { valueText("\(questSession.config.fps)") }
                }
            }
        }
    }

    private var configPath: String? {
        questSession?.configPath ?? directController?.configPath
    }

    // MARK: Transport

    private var transportPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                SettingRow("Current transport", showsDivider: false) {
                    valueText(questSession != nil ? "Quest Client (APK)" : "Direct USB")
                }
            }

            if questSession != nil {
                SettingsGroup {
                    SettingRow("Switch to Direct USB",
                        help: "No sideloaded APK required, but requires Newt",
                        showsDivider: false) {
                        Button("Switch…") { showDirectUSBPrompt = true }
                    }
                }
            } else if let directController {
                SettingsGroup {
                    SettingRow("Switch to Quest Client (APK)",
                        help: "Use the sideloaded Pippin APK over adb reverse/forward instead of Direct USB.",
                        showsDivider: false) {
                        Button("Switch…") { directController.switchToQuestClient(); tick.toggle() }
                    }
                }
            }

            Text("Switching relaunches PippinVR in the other mode and this window closes automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Environment

    private var environmentPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let directController {
                SettingsGroup {
                    SettingRow("360° panorama", showsDivider: directController.environmentImageURL != nil) {
                        Button(directController.environmentImageURL == nil ? "Choose…" : "Change…") {
                            directController.chooseEnvironmentImage(); tick.toggle()
                        }
                    }
                    if directController.environmentImageURL != nil {
                        SettingRow("Flip vertically", showsDivider: true) {
                            Toggle("", isOn: Binding(
                                get: { directController.environmentFlippedVertically },
                                set: { _ in directController.toggleEnvironmentFlipVertical(); tick.toggle() }
                            )).labelsHidden()
                        }
                        SettingRow("Flip horizontally", showsDivider: true) {
                            Toggle("", isOn: Binding(
                                get: { directController.environmentFlippedHorizontally },
                                set: { _ in directController.toggleEnvironmentFlipHorizontal(); tick.toggle() }
                            )).labelsHidden()
                        }
                        SettingRow("Clear", showsDivider: false) {
                            Button("Remove") { directController.clearEnvironmentImage(); tick.toggle() }
                        }
                    }
                }

                if let url = directController.environmentImageURL, let nsImage = NSImage(contentsOf: url) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview").font(.caption).foregroundColor(.secondary)
                        Image(nsImage: nsImage)
                            .resizable().scaledToFit()
                            .scaleEffect(
                                x: directController.environmentFlippedHorizontally ? -1 : 1,
                                y: directController.environmentFlippedVertically ? -1 : 1
                            )
                            .frame(maxWidth: 420, maxHeight: 210)
                            .clipped()
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(6)
                        Text("Approximates the flip — the real wraparound only renders in VR.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Replaces the headset dashboard's own background while a panorama is set.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                inactiveModeNote("Direct USB", "lets you set a 360° panoramic background image")
            }
        }
    }

    private var wireMagicString: String {
        String(bytes: WireFormat.magic, encoding: .ascii) ?? "MVRS"
    }

    private func runWireSpeedTest() {
        guard let questSession else { return }
        speedTestRunning = true
        speedTestResult = nil

        Task {
            var samples: [Double] = []
            for _ in 0 ..< 12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                samples.append(questSession.currentThroughputMbps)
            }
            await MainActor.run {
                speedTestRunning = false
                let peak = samples.max() ?? 0
                if peak > 0 {
                    discoveredPeakMbps = max(discoveredPeakMbps, peak)
                    let mean = samples.reduce(0, +) / Double(samples.count)
                    let mode = Self.modeMbps(of: samples)
                    speedTestResult = String(
                        format: "Peak %.1f · Mean %.1f · Mode %.1f Mbps over 3s",
                        peak, mean, mode
                    )
                } else {
                    speedTestResult = "Connect Headset"
                }
            }
        }
    }

    private static func modeMbps(of samples: [Double]) -> Double {
        var counts: [Double: Int] = [:]
        for s in samples {
            let rounded = (s * 10).rounded() / 10
            counts[rounded, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 0
    }

    // MARK: Screens

    private var screensPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let questSession {
                questScreens(questSession)
                if directController == nil {
                    inactiveModeNote("Direct USB", "adds screens from the headset's dock menu up to 6 panels, each independently positioned and resized in VR.")
                }
            }
            if let directController {
                directScreens(directController)
                if questSession == nil {
                    inactiveModeNote("Quest Client (APK)", "manages virtual displays as a list here in Settings")
                }
            }
        }
    }

    @ViewBuilder
    private func questScreens(_ session: PipelineSession) -> some View {
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

                    Button("Apply Changes") { applyChanges(session) }
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

    @ViewBuilder
    private func directScreens(_ controller: DirectStatusItemController) -> some View {
        Text("Screens and feeds")
        .font(.system(size: 13, weight: .semibold))
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add another screen").font(.headline)
                Text("Create an independent Mac desktop in your headset with a specified size")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Width", value: Binding(
                get: { controller.nextScreenWidth },
                set: { controller.nextScreenWidth = $0; tick.toggle() }
            ), format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text("×").foregroundStyle(.secondary)
            TextField("Height", value: Binding(
                get: { controller.nextScreenHeight },
                set: { controller.nextScreenHeight = $0; tick.toggle() }
            ), format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            directControl(controller, "Add Screen", prominent: true)
        }
        Text(controller.running ? "\(controller.panelCount) of 6 panels in this session" : "Connect USB Direct from the menu bar to add screens and feeds.")
            .foregroundStyle(.secondary)
        directControl(controller, "Add Existing Screen")
        directControl(controller, "Add Camera Feed")
        directControl(controller, "Add Video / Media Feed")

        Text("3D view")
        .font(.system(size: 13, weight: .semibold))
        directControl(controller, "Selected Screen 3D")

        Text("Arrange panels")
        .font(.system(size: 13, weight: .semibold))
        directControl(controller, "Remove Last Panel")
        directControl(controller, "Reset Panel Positions")
        Text("Trigger selects the next panel. With the dashboard hidden, use the left stick to move it and the right stick to resize or change distance. Hold squeeze to grab and rotate.")
            .foregroundStyle(.secondary)
    }

    // MARK: Quality

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let questSession {
                questQuality(questSession)
                if directController == nil {
                    inactiveModeNote("Direct USB", "offers Capture Frame Rate, Panel Resolution, Headset Refresh, and Encode Scale from the dock menu or Settings.")
                }
            }
            if let directController {
                directQuality(controller: directController)
                if questSession == nil {
                    inactiveModeNote("Quest Client (APK)", "live wire-speed gauge with a speed test.")
                }
            }
        }
    }

    @ViewBuilder
    private func questQuality(_ session: PipelineSession) -> some View {
        Text("Wire Protocol")
        .font(.system(size: 13, weight: .semibold))
        SettingsGroup {
            SettingRow("USB link speed", icon: "bolt.horizontal") {
                valueText(usbLinkSpeed ?? "No Quest detected over USB")
            }
            SettingRow("Current wire speed",
                help: "1 second window measure",
                icon: "speedometer") {
                WireSpeedGauge(
                    current: wireSpeedMbps,
                    ceiling: discoveredPeakMbps > 0 ? discoveredPeakMbps : Double(session.config.bitrateMbps),
                    calibrated: discoveredPeakMbps > 0
                )
            }
            SettingRow("Dropped frames", icon: "exclamationmark.arrow.triangle.2.circlepath") {
                valueText("\(session.droppedFrameCount)")
            }
            SettingRow("Speed test",
                help: speedTestResult ?? "Measures sustained output for 3s",
                icon: "gauge.with.dots.needle.67percent",
                showsDivider: false) {
                Button(speedTestRunning ? "Testing" : "Run Test") { runWireSpeedTest() }
                    .disabled(speedTestRunning || !session.isStreaming)
            }
        }
    }

    @ViewBuilder
    private func directQuality(controller: DirectStatusItemController) -> some View {
        Text("Capture")
        .font(.system(size: 13, weight: .semibold))
        directControl(controller, "Capture Frame Rate")
        directControl(controller, "Panel Resolution")

        Text("Headset")
        .font(.system(size: 13, weight: .semibold))
        directControl(controller, "Headset Refresh (next connection)")
        directControl(controller, "Encode Scale (next connection)")
        Text("Reconnect to apply refresh and encoding changes.")
            .foregroundStyle(.secondary)
    }

    // MARK: Apps

    private var appsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let directController {
                Text("3D apps on the headset's Apps page")
                .font(.system(size: 13, weight: .semibold))
                if directController.apps.isEmpty {
                    Text("No apps configured yet. Add a native OpenXR app (.app or executable) or a Godot project folder below")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(directController.apps.enumerated()), id: \.offset) { index, entry in
                        AppRow(entry: entry,
                               onRename: { directController.renameApp(at: index, title: $0); tick.toggle() },
                               onRemove: { directController.removeApp(at: index); tick.toggle() })
                    }
                }
                Button {
                    directController.presentAddAppPicker()
                    tick.toggle()
                } label: {
                    Label("Add App…", systemImage: "plus.circle")
                }
                Text("The app list is sent to the session manager the next time Pippin connects — reconnect to apply a change made here mid-session.")
                    .foregroundStyle(.secondary)
            } else {
                inactiveModeNote("Direct USB", "lets you add native OpenXR apps and Godot projects here so they appear directly on the in-headset Apps page.")
                SettingsGroup {
                    SettingRow("Example App", icon: "cube") { EmptyView() }
                    Button {} label: { Label("Add App…", systemImage: "plus.circle") }.disabled(true)
                }
                .disabled(true)
                .opacity(0.5)
            }
        }
    }

    // MARK: Cameras

    private var camerasPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let questSession {
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

                if !questSession.isStreaming {
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
                                isConnected: questSession.isDeviceConnected(device.id)
                            ) {
                                connectDevice(questSession, device)
                            } onDisconnect: {
                                disconnectDevice(questSession, device)
                            }
                        }
                    }
                }
            } else {
                inactiveModeNote("Quest Client (APK)", "lets you connect external cameras or iPads here as additional capture devices streamed to the headset.")
                SettingsGroup {
                    SettingRow("Example Camera", icon: "camera") { EmptyView() }
                }
                .disabled(true)
                .opacity(0.5)
            }
        }
    }

    // MARK: Device

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Section {
                LabeledContent("Mode", value: questSession != nil ? "Quest Client (APK)" : "Direct USB")
            }
            if deviceInfo.isEmpty {
                Text("No Meta headset detected over USB.")
                    .foregroundStyle(.secondary)
            }
            ForEach(deviceInfo) { device in
                Text(device.model == "Unavailable" ? "USB device" : device.model)
                    .font(.system(size: 13, weight: .semibold))
                SettingsGroup {
                    SettingRow("Manufacturer", showsDivider: true) { valueText(device.manufacturer) }
                    SettingRow("Model / product name", showsDivider: true) { valueText(device.model) }
                    SettingRow("Device ID / serial number", showsDivider: true) { valueText(device.serial) }
                    SettingRow("USB vendor ID", showsDivider: true) { valueText(device.vendorID) }
                    SettingRow("USB product ID", showsDivider: true) { valueText(device.productID) }
                    SettingRow("USB connection speed", showsDivider: false) { valueText(device.speed) }
                }
                .textSelection(.enabled)
            }
            Text("Information is reported by USB and refreshes automatically, regardless of which transport is active.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Appearance (mode-agnostic)

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

    @ViewBuilder
    private func inactiveModeNote(_ mode: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text("\(mode) \(text) Switch to \(mode) (Transport tab) to use this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func directControl(_ controller: DirectStatusItemController, _ title: String, prominent: Bool = false) -> some View {
        if let entry = controller.settingsMenu.items.first(where: { $0.title == title }) {
            if let submenu = entry.submenu {
                let selected = submenu.items.first(where: { $0.state == .on })?.title
                LabeledContent(title) {
                    Menu(selected ?? "Choose…") {
                        ForEach(Array(submenu.items.enumerated()), id: \.offset) { _, choice in
                            Button {
                                controller.perform(choice)
                                tick.toggle()
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
                Button(title) { controller.perform(entry); tick.toggle() }
                    .buttonStyle(.borderedProminent).disabled(!entry.isEnabled)
            } else {
                Button(title) { controller.perform(entry); tick.toggle() }.disabled(!entry.isEnabled)
            }
        }
    }

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

    private func applyChanges(_ session: PipelineSession) {
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

    private func connectDevice(_ session: PipelineSession, _ device: CaptureDevice) {
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

    private func disconnectDevice(_ session: PipelineSession, _ device: CaptureDevice) {
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

// MARK: Wire speed gauge

private struct WireSpeedGauge: View {
    let current: Double
    let ceiling: Double
    let calibrated: Bool

    private var fraction: Double {
        guard ceiling > 0 else { return 0 }
        return min(max(current / ceiling, 0), 1)
    }

    private var tint: Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text(current > 0 ? String(format: "%.1f Mbps", current) : "idle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                Text(calibrated
                    ? "of \(String(format: "%.0f", ceiling)) discovered"
                    : "of \(String(format: "%.0f", ceiling)) configured")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(tint)
            .frame(width: 160)
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

private struct AppRow: View {
    let entry: AppEntry
    let onRename: (String) -> Void
    let onRemove: () -> Void
    @State private var title: String

    init(entry: AppEntry, onRename: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.entry = entry
        self.onRename = onRename
        self.onRemove = onRemove
        _title = State(initialValue: entry.title)
    }

    var body: some View {
        HStack {
            TextField("Title", text: $title).onSubmit { onRename(title) }
                .frame(maxWidth: 160)
            Text(entry.project != nil ? "Godot project" : "App")
                .foregroundStyle(.secondary).font(.caption)
            Text(entry.game ?? entry.project ?? "")
                .foregroundStyle(.secondary).font(.caption)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "minus.circle")
            }.buttonStyle(.plain)
        }
    }
}
