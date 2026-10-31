import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
#if PIPPINVR_DIRECT
import Newt

private final class VRViewReadState: @unchecked Sendable {
    var sequence: UInt64 = 0
    var lastFrame = DispatchTime.now().uptimeNanoseconds
    var reportedStale = false
    var reportedLoss = false
    var rateStart = DispatchTime.now().uptimeNanoseconds
    var rateFrames = 0
}

@MainActor
private final class VRViewModel: ObservableObject {
    @Published var mode: VRViewMode = .sideBySide
    @Published var fps: Int = {
        let saved = UserDefaults(suiteName: "com.pippinvr.server")?.integer(forKey: "directVRViewFPS") ?? 0
        return [10, 20, 30].contains(saved) ? saved : 10
    }() {
        didSet {
            let preferences = UserDefaults(suiteName: "com.pippinvr.server")
            preferences?.set(fps, forKey: "directVRViewFPS")
            preferences?.synchronize()
            do { try VRMirrorConfiguration.writeFPS(fps) } catch { Logger.warning("VR View: could not update capture rate: \(error)") }
        }
    }
    @Published var hideFromHeadset: Bool = {
        let preferences = UserDefaults(suiteName: "com.pippinvr.server")
        return preferences?.object(forKey: "directVRViewHideFromHeadset") as? Bool ?? true
    }() {
        didSet {
            let preferences = UserDefaults(suiteName: "com.pippinvr.server")
            preferences?.set(hideFromHeadset, forKey: "directVRViewHideFromHeadset")
            preferences?.synchronize()
        }
    }
    @Published var eyes: VREyes?
    @Published var status = "Waiting for the Direct USB headset view…"
    @Published var measuredFPS: Double?
    @Published var recording = false
    @Published var saving = false
    @Published var cleanViewOpen = false
    @Published var recordingMessage = ""
    private let queue = DispatchQueue(label: "pippin.vr-view.receiver", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var recorder: VRViewRecorder?
    private var recordingSize: CGSize?
    private var choosingFile = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    func start() -> Bool {
        do { try VRMirrorConfiguration.writeFPS(fps) } catch { Logger.warning("VR View: could not set capture rate: \(error)") }
        guard Newt_VRMirrorStart() else {
            status = "Could not open the VR view. Close any other viewer and try again."
            return false
        }
        let run = UUID()
        generation = run
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(3))
        timer.setEventHandler(handler: Self.readHandler(model: self, run: run))
        self.timer = timer
        timer.resume()
        return true
    }

    nonisolated private static func readHandler(model: VRViewModel, run: UUID) -> @Sendable () -> Void {
        let state = VRViewReadState()
        return { [weak model] in
            var width: UInt32 = 0, height: UInt32 = 0, format: UInt32 = 0
            if let cf = Newt_VRMirrorCopy(&state.sequence, &width, &height, &format) {
                let data = cf as Data
                let bytes = Int(width) * Int(height) * 4
                guard bytes > 0, data.count == bytes * 2,
                      let left = Self.image(data.subdata(in: 0..<bytes), width: Int(width), height: Int(height), format: format),
                      let right = Self.image(data.subdata(in: bytes..<(bytes * 2)), width: Int(width), height: Int(height), format: format) else { return }
                state.lastFrame = DispatchTime.now().uptimeNanoseconds
                if state.reportedStale {
                    state.rateStart = state.lastFrame
                    state.rateFrames = 0
                }
                state.reportedStale = false
                state.reportedLoss = false
                state.rateFrames += 1
                let elapsed = state.lastFrame - state.rateStart
                var observedFPS: Double?
                if elapsed >= 1_000_000_000 {
                    observedFPS = Double(state.rateFrames) * 1_000_000_000 / Double(elapsed)
                    state.rateFrames = 0
                    state.rateStart = state.lastFrame
                }
                let fps = observedFPS
                Task { @MainActor [weak model] in
                    guard let self = model, self.generation == run else { return }
                    if let fps { self.measuredFPS = fps }
                    let eyes = VREyes(left: left, right: right)
                    self.eyes = eyes
                    if let size = self.recordingSize, size != CGSize(width: left.width, height: left.height) {
                        self.stopRecording(reason: "The headset view size changed.")
                    } else {
                        self.recorder?.append(eyes, at: DispatchTime.now().uptimeNanoseconds)
                    }
                    self.status = "Direct USB view"
                }
            } else {
                let age = DispatchTime.now().uptimeNanoseconds - state.lastFrame
                if age > 2_000_000_000 && !state.reportedStale {
                    state.reportedStale = true
                    state.rateFrames = 0
                    state.rateStart = DispatchTime.now().uptimeNanoseconds
                    Task { @MainActor [weak model] in
                        guard let self = model, self.generation == run else { return }
                        self.eyes = nil
                        self.measuredFPS = nil
                        self.status = "Waiting for the Direct USB headset view…"
                    }
                }
                if age > 5_000_000_000 && !state.reportedLoss {
                    state.reportedLoss = true
                    Task { @MainActor [weak model] in
                        guard let self = model, self.generation == run else { return }
                        self.stopRecording(reason: "The headset view stopped.")
                    }
                }
            }
        }
    }

    func stop() {
        stopRecording()
        generation = UUID()
        timer?.cancel()
        timer = nil
        // Drain any in-flight read before closing the native receiver.
        queue.sync {}
        Newt_VRMirrorStop()
        eyes = nil
        measuredFPS = nil
    }

    @discardableResult
    func toggleRecording() -> String {
        if recording { stopRecording(); return "Saving recording on your Mac" }
        guard !saving, !choosingFile else { return "Finish saving the previous recording first." }
        guard eyes != nil else { recordingMessage = "Wait for the headset view before recording."; return recordingMessage }
        choosingFile = true
        defer { choosingFile = false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "PippinVR Recording.mp4"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return "Recording cancelled" }
        guard let eyes else { recordingMessage = "The headset view stopped before recording began."; return recordingMessage }
        do {
            recorder = try VRViewRecorder(url: url, eyes: eyes, mode: mode)
            recordingSize = CGSize(width: eyes.left.width, height: eyes.left.height)
            recording = true
            recordingMessage = "Recording video · \(mode.rawValue)"
        } catch {
            recordingMessage = "Could not start recording: \(error.localizedDescription)"
        }
        return recording ? "Recording started" : "Could not start recording; check your Mac"
    }

    private func stopRecording(reason: String? = nil) {
        guard let recorder else { return }
        self.recorder = nil
        recordingSize = nil
        recording = false
        saving = true
        recordingMessage = "Saving recording…"
        recorder.finish { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.saving = false
                self.recordingMessage = error.map { "Recording failed: \($0)" } ?? [reason, "Recording saved."].compactMap { $0 }.joined(separator: " ")
                let waiters = self.shutdownWaiters
                self.shutdownWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    func finishBeforeShutdown() async {
        guard recording || saving else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
            if recording { stopRecording() }
        }
    }

    nonisolated private static func image(_ bytes: Data, width: Int, height: Int, format: UInt32) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = format == 1 ? .premultipliedFirst : .premultipliedLast
        let order: CGBitmapInfo = format == 1 ? .byteOrder32Little : .byteOrder32Big
        let bitmap = order.union(CGBitmapInfo(rawValue: alpha.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private struct VRViewContent: View {
    @ObservedObject var model: VRViewModel
    @State private var cleanMode = false
    @State private var pointerInside = false

    var body: some View {
        Group {
            if cleanMode {
                ZStack(alignment: .topTrailing) {
                    VRViewImage(model: model)
                    Button("Show Controls") { cleanMode = false }
                        .keyboardShortcut(.escape, modifiers: [])
                        .padding(10)
                        .opacity(pointerInside ? 1 : 0)
                }.onHover { pointerInside = $0 }
            } else {
                VStack(spacing: 0) {
                    BrandHeader()
                    Divider()
                    HStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("VR View").font(.system(size: 20, weight: .bold))
                                Text("Choose the view and recording options for Direct USB.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                SettingsGroup {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Eye layout").font(.system(size: 13, weight: .medium))
                                        Picker("Eye layout", selection: $model.mode) {
                                            ForEach(VRViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                                        }.labelsHidden().pickerStyle(.segmented).disabled(model.recording || model.saving)
                                    }.padding(14)
                                    Divider()
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Frame rate").font(.system(size: 13, weight: .medium))
                                        Picker("Frame rate", selection: $model.fps) {
                                            ForEach([10, 20, 30], id: \.self) { value in Text("\(value) fps").tag(value) }
                                        }.labelsHidden().pickerStyle(.segmented)
                                        Text(model.measuredFPS.map { String(format: "Receiving %.0f fps", $0) } ?? "Waiting for headset frames")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(14)
                                    Divider()
                                    Toggle("Hide viewer from headset desktop", isOn: $model.hideFromHeadset)
                                        .font(.system(size: 13)).padding(14)
                                }
                                SettingsGroup {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text("Recording").font(.system(size: 13, weight: .medium))
                                        Button(model.recording ? "Stop Recording" : "Record…") { model.toggleRecording() }
                                            .disabled(model.saving)
                                        Text(model.recordingMessage.isEmpty ? "Video only; save as an MP4." : model.recordingMessage)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                }
                                Text("Showing the viewer in the headset desktop may create a repeating image.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 330)
                        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Headset Preview").font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Button("Clean View") { cleanMode = true }
                                Button(model.cleanViewOpen ? "Show Separate Window" : "Open Separate Window") {
                                    VRViewWindowController.shared.showCleanView()
                                }
                            }
                            VRViewImage(model: model)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            Text("Clean View hides controls. Hover over the view or press Escape to restore them.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("OBS: macOS Screen Capture → Window Capture → PippinVR — VR View. Keep the window open and reselect it after restarting PippinVR. AirPlay: Control Center → Screen Mirroring.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
        }.frame(minWidth: 860, minHeight: 560)
    }
}

private struct VRViewImage: View {
    @ObservedObject var model: VRViewModel
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let eyes = model.eyes {
                    HStack(spacing: 0) {
                        if model.mode != .right { eye(eyes.left) }
                        if model.mode != .left { eye(eyes.right) }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                } else { Text(model.status).foregroundColor(.white) }
            }
        }
    }
    private func eye(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class VRViewWindowController: NSObject, NSWindowDelegate {
    static let shared = VRViewWindowController()
    private var window: NSWindow?
    private var cleanWindow: NSWindow?
    private let model = VRViewModel()

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "PippinVR — VR View"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: VRViewContent(model: model))
        self.window = window
        _ = model.start()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === cleanWindow {
            cleanWindow = nil
            model.cleanViewOpen = false
            return
        }
        cleanWindow?.close()
        model.stop()
        window = nil
    }

    func showCleanView() {
        if let cleanWindow {
            NSApp.activate(ignoringOtherApps: true)
            cleanWindow.deminiaturize(nil)
            cleanWindow.makeKeyAndOrderFront(nil)
            cleanWindow.orderFrontRegardless()
            return
        }
        let clean = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        clean.title = "PippinVR — Clean VR View"
        clean.isReleasedWhenClosed = false
        clean.delegate = self
        clean.contentViewController = NSHostingController(rootView: VRViewImage(model: model))
        cleanWindow = clean
        model.cleanViewOpen = true
        if let screen = window?.screen {
            let visible = screen.visibleFrame
            let frame = clean.frame
            clean.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        } else {
            clean.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        clean.makeKeyAndOrderFront(nil)
        clean.orderFrontRegardless()
    }

    func toggleRecordingFromHeadset() -> String {
        show()
        return model.toggleRecording()
    }

    func cycleModeFromHeadset() -> String {
        show()
        guard !model.recording, !model.saving else { return "Finish the recording before changing the view" }
        let modes = VRViewMode.allCases
        guard let current = modes.firstIndex(of: model.mode) else { return "Could not change recording view" }
        model.mode = modes[(current + 1) % modes.count]
        return "Recording view: \(model.mode.rawValue)"
    }

    func toggleHeadsetVisibility() -> String {
        show()
        model.hideFromHeadset.toggle()
        return model.hideFromHeadset ? "Viewer hidden from headset desktop" : "Viewer visible in headset desktop; feedback may occur"
    }

    func finishBeforeShutdown() async { await model.finishBeforeShutdown() }
}
#endif
