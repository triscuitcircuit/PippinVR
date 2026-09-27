import AppKit
import SwiftUI

struct SettingsView: View {
    let session: PipelineSession
    @State private var editMode = false
    @State private var editedDisplays: [DisplayEntry] = []
    @State private var showError: String?
    @State private var isApplying = false
    @StateObject private var deviceManager = CaptureDeviceManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Configuration File")
                    .font(.headline)

                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.accentColor)
                    Text(session.configPath ?? "Using default configuration")
                        .font(.system(.body, design: .serif))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Reveal in Finder") {
                        if let path = session.configPath {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        }
                    }
                    .disabled(session.configPath == nil)
                }
                .padding(12)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(10)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Server Settings")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Port:").gridColumnAlignment(.trailing)
                        Text("\(session.config.port)")
                            .foregroundColor(.secondary)
                    }
                    GridRow {
                        Text("Codec:").gridColumnAlignment(.trailing)
                        Text(session.config.codec == .hevc ? "HEVC (H.265)" : "H.264")
                            .foregroundColor(.secondary)
                    }
                    GridRow {
                        Text("Bitrate:").gridColumnAlignment(.trailing)
                        Text("\(session.config.bitrateMbps) Mbps")
                            .foregroundColor(.secondary)
                    }
                    GridRow {
                        Text("FPS:").gridColumnAlignment(.trailing)
                        Text("\(session.config.fps)")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Virtual Displays")
                        .font(.headline)
                    Spacer()
                    if session.isStreaming {
                        if editMode {
                            Button("Cancel") {
                                editMode = false
                                editedDisplays = []
                            }
                            .disabled(isApplying)

                            Button("Apply Changes") {
                                applyChanges()
                            }
                            .disabled(isApplying || editedDisplays.isEmpty)
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Edit") {
                                editMode = true
                                editedDisplays = session.config.displays
                            }
                        }
                    }
                }

                if let error = showError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                }

                if editMode {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach($editedDisplays.indices, id: \.self) { index in
                                DisplayEditorRow(display: $editedDisplays[index]) {
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
                        .padding(.vertical, 4)
                    }
                } else {
                    if session.displayNames.isEmpty {
                        Text("No displays configured")
                            .foregroundColor(.secondary)
                            .padding(12)
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(session.displayNames, id: \.0) { display in
                                    HStack {
                                        Image(systemName: "display")
                                            .foregroundColor(.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(display.0)
                                                .font(.system(.body, design: .default).weight(.medium))
                                            Text("\(display.1) × \(display.2)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(12)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
            }

            if !session.isStreaming {
                Text("Displays can only be edited while streaming to a headset.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Capture Devices")
                        .font(.headline)
                    Spacer()
                    Button {
                        deviceManager.discoverDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh device list")
                }

                if !session.isStreaming {
                    Text("Connect to headset to add camera devices.")
                        .foregroundColor(.secondary)
                        .padding(12)
                } else if deviceManager.availableDevices.isEmpty {
                    Text("No cameras or iPads detected. Connect a device and click refresh.")
                        .foregroundColor(.secondary)
                        .padding(12)
                } else {
                    ScrollView {
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

            Spacer()
        }
        .padding()
        .frame(minWidth: 550, minHeight: 600)
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

struct DisplayEditorRow: View {
    @Binding var display: DisplayEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Display Name", text: $display.name)
                    .textFieldStyle(.roundedBorder)

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width").font(.caption).foregroundColor(.secondary)
                    TextField("Width", value: $display.width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Height").font(.caption).foregroundColor(.secondary)
                    TextField("Height", value: $display.height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Refresh Hz").font(.caption).foregroundColor(.secondary)
                    TextField("Hz", value: $display.refreshHz, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }

                Toggle("HiDPI", isOn: $display.hiDPI)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.body)

                HStack(spacing: 8) {
                    Text(device.type.label)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let resolution = device.supportedResolutions.first {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text("\(resolution.width)×\(resolution.height) @ \(Int(resolution.maxFps))fps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if isConnected {
                Text("Connected")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(4)

                Button("Disconnect") {
                    onDisconnect()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Connect") {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(isConnected ? Color.green.opacity(0.05) : Color.gray.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isConnected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
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
