import AppKit
import Combine
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, screens, quality, apps, cameras, device, appearance, transport, environment, performance

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
        case .performance: return "Performance"
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
        case .performance: return "gauge"
        }
    }
}

private let tintOptions: [Color] = [
    Color(red: 0.04, green: 0.52, blue: 1.0),
    Color(red: 0.69, green: 0.32, blue: 0.87),
    Color(red: 1.0, green: 0.22, blue: 0.37),
    Color(red: 1.0, green: 0.62, blue: 0.04),
    Color(red: 0.19, green: 0.82, blue: 0.35)
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
    @State private var startupMode = StartupPreferences.mode

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
                        case .performance: performancePanel
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

            if let directController {
                SettingsGroup {
                    SettingRow("Wrist clock", help: "Turn either palm toward your face to show the time.") {
                        Toggle("Wrist clock", isOn: Binding(
                            get: { directController.wristClockEnabled },
                            set: { directController.setWristClockEnabled($0) })).labelsHidden()
                    }
                }
                Text("The wrist clock requires hand tracking enabled on the headset and available through the connected runtime. Hold your palm toward your face briefly; turn it away to hide the clock.")
                    .font(.caption).foregroundColor(.secondary)

                SettingsGroup {
                    SettingRow("Headset sound", help: "Your Mac's sound in the headset. HRTF places it at the screen you're using, so it stays there as you turn your head.") {
                        Picker("Headset sound", selection: Binding(
                            get: { directController.audioMode },
                            set: { directController.setAudioMode($0) })) {
                            ForEach(DirectAudioPreferences.Mode.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    SettingRow("Also play on Mac", help: "Off: the Mac's speakers go quiet while the headset has the sound.", showsDivider: false) {
                        Toggle("Also play on Mac", isOn: Binding(
                            get: { directController.audioMacSpeakers },
                            set: { directController.setAudioMacSpeakers($0) })).labelsHidden()
                            .disabled(directController.audioMode == .off)
                    }
                }
                Text("Also switchable in the headset under Settings › Appearance › Sound. Muting the Mac needs macOS 14.2 or later and the system audio recording permission; without them the Mac keeps playing too.")
                    .font(.caption).foregroundColor(.secondary)
                if let status = directController.audioStatus {
                    Text(status).font(.caption).foregroundColor(status.contains("keeps playing.") ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsGroup {
                    SettingRow("Headset camera access",
                               help: "Off by default. Lets PippinVR show your headset's passthrough cameras in VR.") {
                        Toggle("Headset camera access", isOn: Binding(
                            get: { directController.passthroughAllowed },
                            set: { directController.setPassthroughAllowed($0) })).labelsHidden()
                    }
                    SettingRow("Passthrough portal", showsDivider: false) {
                        Toggle("Passthrough portal", isOn: Binding(
                            get: { directController.passthroughEnabled },
                            set: { directController.setPassthroughEnabled($0) })).labelsHidden()
                            .disabled(!directController.passthroughAllowed)
                    }
                }
                Text(ProcessInfo.processInfo.environment["PIPPIN_HAND_BENCHMARK"] == "1"
                     ? "During the hand benchmark, headset camera video also appears in the Mac preview window. Nothing is recorded or saved. Changes to camera access apply from the next headset session."
                     : "The portal is a movable window showing your room, also switchable in the headset under Settings › Passthrough. Grab its bar to move it; squeeze both grips to stretch it. Camera video is shown only in your headset and never recorded or saved. Changes to camera access apply from the next headset session.")
                    .font(.caption).foregroundColor(.secondary)
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

            SettingsGroup {
                SettingRow("Start PippinVR in",
                    help: "When opened from the Dock or Finder. Direct USB connects to the headset right away.",
                    showsDivider: false) {
                    Picker("", selection: $startupMode) {
                        ForEach(StartupMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: startupMode) { StartupPreferences.mode = $0 }
                }
            }

            Text("Switching relaunches PippinVR in the other mode and this window closes automatically. "
                + "The start-up choice applies the next time PippinVR is opened.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var environmentPanel: some View {
        if let directController {
            DirectEnvironmentSettingsPanel(controller: directController)
        } else {
            inactiveModeNote("Direct USB", "lets you set a 360° panoramic background image and add 3D models")
        }
    }

    @ViewBuilder
    private var performancePanel: some View {
        if let directController {
            DirectPerformancePanel(controller: directController, metrics: directController.metricsStore)
        } else {
            inactiveModeNote("Direct USB", "shows live Quest Link encode, Newt frame, decode, and MetalFX metrics")
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

    private var screensPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let questSession {
                questScreens(questSession)
                if directController == nil {
                    inactiveModeNote("Direct USB", "adds screens from the headset's dock menu up to \(DirectStatusItemController.panelLimit) panels, each independently positioned and resized in VR.")
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
        Text(controller.running ? "\(controller.panelCount) of \(controller.maxPanels) panels in this session" : "Connect USB Direct from the menu bar to add screens and feeds.")
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

private struct DirectEnvironmentSettingsPanel: View {
    @ObservedObject var controller: DirectStatusItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup {
                SettingRow("360° panorama", showsDivider: controller.environmentImageURL != nil) {
                    Button(controller.environmentImageURL == nil ? "Choose…" : "Change…") {
                        controller.chooseEnvironmentImage()
                    }
                    .disabled(!controller.running)
                }
                if controller.environmentImageURL != nil {
                    SettingRow("Flip vertically", showsDivider: true) {
                        Toggle("", isOn: Binding(
                            get: { controller.environmentFlippedVertically },
                            set: { controller.setEnvironmentFlipVertical($0) }
                        )).labelsHidden()
                    }
                    SettingRow("Flip horizontally", showsDivider: true) {
                        Toggle("", isOn: Binding(
                            get: { controller.environmentFlippedHorizontally },
                            set: { controller.setEnvironmentFlipHorizontal($0) }
                        )).labelsHidden()
                    }
                }
                if controller.environmentImageURL != nil || controller.hasEnvironmentModel {
                    SettingRow("Clear environment", showsDivider: false) {
                        Button("Remove All", role: .destructive) {
                            controller.clearEnvironmentImage()
                        }
                    }
                }
            }

            if let url = controller.environmentImageURL, let nsImage = NSImage(contentsOf: url) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview").font(.caption).foregroundColor(.secondary)
                    Image(nsImage: nsImage)
                        .resizable().scaledToFit()
                        .scaleEffect(
                            x: controller.environmentFlippedHorizontally ? -1 : 1,
                            y: controller.environmentFlippedVertically ? -1 : 1
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

            SettingsGroup {
                SettingRow("3D models",
                           help: "USDZ, OBJ, glTF, or GLB. Added models also get controls on the model in VR.",
                           showsDivider: controller.hasEnvironmentModel) {
                    Button("Add…") { controller.chooseEnvironmentModel() }
                        .disabled(!controller.running)
                }
                if controller.hasEnvironmentModel {
                    ForEach(controller.environmentModelURLs, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: "cube.transparent")
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    SettingRow("Selected model scale", showsDivider: true) {
                        HStack(spacing: 8) {
                            Button("Smaller") { controller.scaleSelectedEnvironmentModel(up: false) }
                            Button("Larger") { controller.scaleSelectedEnvironmentModel(up: true) }
                        }
                        .disabled(!controller.running)
                    }
                    SettingRow("Selected model rotation", showsDivider: true) {
                        Button("Rotate 45°") { controller.rotateSelectedEnvironmentModel() }
                            .disabled(!controller.running)
                    }
                    SettingRow("Selected model position", showsDivider: true) {
                        Button("Room / In Front") { controller.toggleSelectedEnvironmentModelPosition() }
                            .disabled(!controller.running)
                    }
                    SettingRow("Selected model", showsDivider: false) {
                        Button("Remove", role: .destructive) {
                            controller.removeSelectedEnvironmentModel()
                        }
                        .disabled(!controller.running)
                    }
                }
            }

            Text("The panorama replaces the dashboard background. In VR, aim at a model to select it; squeeze to move/rotate it and use two grips to scale it.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct DirectMetricsLineGraph: View {
    struct Point {
        let date: Date
        let value: Double
    }
    struct Series {
        let name: String
        let color: Color
        let points: [Point]
    }

    let series: [Series]
    let now: Date
    let budgetMs: Double?
    private let window: TimeInterval = 60

    private var maxValue: Double {
        let peak = series.flatMap(\.points)
            .filter { now.timeIntervalSince($0.date) <= window && $0.value.isFinite }
            .map(\.value).max() ?? 0
        return max(10, ceil(max(peak, budgetMs ?? 0) / 5) * 5)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack {
                    Text("\(Int(maxValue)) ms")
                    Spacer()
                    Text("0")
                }
                .font(.caption2).foregroundColor(.secondary).frame(width: 42, height: 150, alignment: .trailing)
                Canvas { context, size in
                    for step in 0...4 {
                        let y = size.height * Double(step) / 4.0
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                    }
                    if let budgetMs, budgetMs > 0 {
                        let y = size.height * (1 - budgetMs / maxValue)
                        var budget = Path()
                        budget.move(to: CGPoint(x: 0, y: y))
                        budget.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(budget, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    for item in series {
                        var path = Path()
                        var previous: Date?
                        for point in item.points where point.value.isFinite && point.value >= 0 {
                            let age = now.timeIntervalSince(point.date)
                            guard age >= 0 && age <= window else { continue }
                            let position = CGPoint(x: size.width * (1 - age / window),
                                                   y: size.height * (1 - point.value / maxValue))
                            if let previous, point.date.timeIntervalSince(previous) < 5 {
                                path.addLine(to: position)
                            } else {
                                path.move(to: position)
                            }
                            previous = point.date
                            context.fill(Path(ellipseIn: CGRect(x: position.x - 1.5, y: position.y - 1.5,
                                                                 width: 3, height: 3)), with: .color(item.color))
                        }
                        context.stroke(path, with: .color(item.color), lineWidth: 1.8)
                    }
                }
                .frame(height: 150)
                .background(Color.black.opacity(0.12))
                .cornerRadius(8)
                .accessibilityLabel("Frame timing over the last 60 seconds, in milliseconds")
            }
            HStack {
                Text("60 seconds ago")
                Spacer()
                Text("Now")
            }.font(.caption2).foregroundColor(.secondary).padding(.leading, 48)
        }
    }
}

private struct DirectPerformancePanel: View {
    @ObservedObject var controller: DirectStatusItemController
    @ObservedObject var metrics: DirectMetricsStore

    private func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f ms", value)
    }

    private func isLive(_ date: Date?, now: Date) -> Bool {
        guard controller.running, let date else { return false }
        return now.timeIntervalSince(date) < 5
    }

    private func metric(_ title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundColor(color)
            Text(detail).font(.caption2).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let latestEncode = metrics.encodeSamples.last
            let latestNewt = metrics.newtSamples.last
            let encodeLive = isLive(latestEncode?.date, now: now)
            let newtLive = isLive(latestNewt?.date, now: now)
            let budget = newtLive ? latestNewt?.periodMs : nil
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroup {
                    SettingRow("Show performance in headset") {
                        Toggle("", isOn: Binding(get: { controller.showMetricsInVR },
                                               set: { controller.setShowMetricsInVR($0) })).labelsHidden()
                    }
                    SettingRow("MetalFX spatial upscaling") {
                        Toggle("", isOn: Binding(get: { controller.metalFXEnabled },
                                               set: { controller.setMetalFXEnabled($0) })).labelsHidden()
                    }
                    SettingRow("MetalFX resolution", help: "Scale applies to width and height.", showsDivider: false) {
                        Picker("MetalFX resolution", selection: Binding(
                            get: { controller.metalFXScale }, set: { controller.setMetalFXScale($0) })) {
                            Text("Auto (1.5×–2×)").tag(0.0)
                            Text("1.25× (+25%)").tag(1.25)
                            Text("1.5× (+50%)").tag(1.5)
                            Text("2× (+100%)").tag(2.0)
                        }.labelsHidden().frame(width: 170).disabled(!controller.metalFXEnabled)
                    }
                }

                Text("MetalFX scales desktop captures before they enter the VR scene. 2× uses up to four times as many pixels. Output is capped at 3840 × 2400 while preserving aspect ratio; this does not change the headset’s render resolution.")
                    .font(.caption).foregroundColor(.secondary)

                HStack {
                    Label(!controller.running ? "Session stopped" :
                          (encodeLive || newtLive ? "Receiving performance data" : "Waiting for fresh samples"),
                          systemImage: encodeLive || newtLive ? "waveform.path" : "clock")
                    Spacer()
                    if let budget, budget > 0 {
                        Text(String(format: "Target %.0f Hz · %.2f ms/frame", 1000 / budget, budget))
                    }
                }.font(.caption).foregroundColor(.secondary)

                SettingsGroup {
                    HStack(spacing: 0) {
                        metric("Dashboard FPS", value: newtLive ? String(format: "%.1f", latestNewt!.fps) : "—",
                               detail: newtLive ? "Application frame rate" : "No fresh dashboard sample", color: .primary)
                        metric("Encode stage", value: encodeLive ? ms(latestEncode?.stageMs) : "—",
                               detail: encodeLive ? "Video pipeline" : "No fresh encode sample", color: .orange)
                        metric("USB transfer", value: encodeLive ? ms(latestEncode?.txMs) : "—",
                               detail: encodeLive ? "Video transmission" : "No fresh transfer sample", color: .purple)
                    }
                }

                SettingsGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            Label("Frame interval", systemImage: "circle.fill").foregroundColor(.blue)
                            Label("CPU render", systemImage: "circle.fill").foregroundColor(.green)
                            Label("Encode", systemImage: "circle.fill").foregroundColor(.orange)
                            Label("USB", systemImage: "circle.fill").foregroundColor(.purple)
                        }.font(.caption)
                        DirectMetricsLineGraph(series: [
                            .init(name: "Frame interval", color: .blue, points: metrics.newtSamples.compactMap {
                                $0.fps > 0 ? .init(date: $0.date, value: 1000 / $0.fps) : nil
                            }),
                            .init(name: "CPU render", color: .green, points: metrics.newtSamples.compactMap { sample in
                                sample.renderMs.map { .init(date: sample.date, value: $0) }
                            }),
                            .init(name: "Encode", color: .orange, points: metrics.encodeSamples.map { .init(date: $0.date, value: $0.stageMs) }),
                            .init(name: "USB", color: .purple, points: metrics.encodeSamples.map { .init(date: $0.date, value: $0.txMs) })
                        ], now: now, budgetMs: budget)
                        Text("Shared time axis · scale adjusts to peaks · dashed line is the headset frame budget")
                            .font(.caption2).foregroundColor(.secondary)
                    }.padding(12)
                }

                SettingsGroup {
                    SettingRow("Dashboard prepare / CPU render") {
                        Text(newtLive ? "\(ms(latestNewt?.prepareMs)) / \(ms(latestNewt?.renderMs))" : "—")
                            .monospacedDigit().foregroundColor(.secondary)
                    }
                    SettingRow("Frames encoded") {
                        Text(encodeLive ? String(latestEncode!.encoded) : "—").monospacedDigit().foregroundColor(.secondary)
                    }
                    SettingRow("MetalFX", showsDivider: false) {
                        Text(!controller.metalFXEnabled ? "Off" : (metrics.metalFXDescription.map { "Last reported: \($0)" } ?? "Enabled; awaiting capture"))
                            .foregroundColor(.secondary)
                    }
                }
                Text("FPS measures the dashboard loop, not headset presentation. CPU render includes submission; it is not GPU time. Encode and USB stages overlap and should not be added as total latency. Readings expire after 5 seconds.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear { metrics.start() }
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
                    .font(.system(size: 12)).help("https://github.com/triscuitcircuit")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .controlBackgroundColor),
                         Color(nsColor: .windowBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom)
        )
    }
}

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
