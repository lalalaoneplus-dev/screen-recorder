import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var rec: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            RecordPanel().frame(width: 410)
            Divider()
            RecentList().frame(minWidth: 400, maxWidth: .infinity)
        }
        .frame(minHeight: 800)
        .onAppear {
            rec.openEditor = { url in openWindow(value: url) }
            rec.library.reload(rec.saveFolder)
        }
        .task { await rec.loadDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if rec.state == .idle { Task { await rec.loadDisplays() } }
            rec.library.reload(rec.saveFolder)
        }
    }
}

struct RecordPanel: View {
    @EnvironmentObject var rec: Recorder
    // Read here only so the size estimate refreshes when these change in Settings.
    @AppStorage("fps") private var fpsSetting = 60
    @AppStorage("codec") private var codecSetting = VideoCodec.h264.rawValue

    private var dotColor: Color {
        switch rec.state {
        case .recording: return .red
        case .paused: return .orange
        case .countdown: return .yellow
        default: return .secondary.opacity(0.4)
        }
    }

    private var hint: String {
        switch rec.state {
        case .idle: return "Click, press Space or ⌥⇧⌘R to record"
        case .countdown(let n): return "Starting in \(n)… click to cancel"
        case .recording: return "Recording — ⌥⇧⌘P pauses, ⌥⇧⌘R stops"
        case .paused: return "Paused — ⌥⇧⌘P resumes"
        case .saving: return "Working…"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 12, height: 12)
                    .opacity(rec.state == .recording && Int(rec.elapsed * 2) % 2 == 1 ? 0.35 : 1)
                Text(rec.timeString).font(.system(size: 34, weight: .semibold, design: .monospaced))
            }
            .padding(.top, 4)

            Button(action: rec.primaryAction) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.22), lineWidth: 4).frame(width: 84, height: 84)
                    switch rec.state {
                    case .recording, .paused:
                        RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 32, height: 32)
                    case .countdown(let n):
                        Text("\(n)").font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.red)
                    default:
                        Circle().fill(Color.red).frame(width: 64, height: 64)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(rec.state == .saving || (rec.state == .idle && rec.needsPermission))
            .keyboardShortcut(.space, modifiers: [])
            .help("Start / stop (Space or ⌥⇧⌘R)")

            HStack(spacing: 8) {
                Button {
                    rec.togglePause()
                } label: {
                    Label(rec.state == .paused ? "Resume" : "Pause",
                          systemImage: rec.state == .paused ? "play.fill" : "pause.fill")
                }
                .disabled(!rec.isCapturing)
                Button { Task { await rec.restart() } } label: { Label("Restart", systemImage: "arrow.counterclockwise") }
                    .disabled(!rec.isCapturing)
                    .help("Throw away this take and start again")
                Button(role: .destructive) { Task { await rec.discard() } } label: { Label("Discard", systemImage: "trash") }
                    .disabled(!(rec.isCapturing || { if case .countdown = rec.state { return true }; return false }()))
                    .help("Stop without keeping the recording (it goes to the Trash)")
            }
            .controlSize(.regular)

            Text(hint).font(.caption).foregroundStyle(.secondary)

            if rec.needsPermission {
                VStack(spacing: 8) {
                    Text("Allow Screen Recorder in System Settings → Privacy & Security → Screen & System Audio Recording, then click Quit & Reopen.")
                        .font(.callout).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Settings") { rec.openPrivacySettings() }
                        Button("Quit & Reopen") { rec.relaunch() }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
                .padding(.horizontal, 14)
            }

            Form {
                Picker("Capture", selection: $rec.mode) {
                    Text("Whole screens").tag(CaptureMode.screens)
                    Text("Area").tag(CaptureMode.area)
                }
                .pickerStyle(.segmented)

                if rec.mode == .screens {
                    Section("Screens to record") {
                        ForEach(rec.displays, id: \.displayID) { d in
                            Toggle(rec.displayName(d), isOn: Binding(
                                get: { rec.isSelected(d.displayID) },
                                set: { rec.setSelected(d.displayID, $0) }))
                        }
                    }
                } else {
                    Section("Area") {
                        HStack {
                            Text(rec.areaDescription).foregroundStyle(rec.area == nil ? .secondary : .primary)
                            Spacer()
                            Button(rec.area == nil ? "Select Area…" : "Change…") { rec.selectArea(thenRecord: false) }
                        }
                    }
                }

                Section("Video size") {
                    Picker("Resolution", selection: $rec.resolution) {
                        ForEach(RecResolution.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: $rec.quality) {
                        ForEach(RecQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !rec.sizeEstimate.isEmpty {
                        Text(rec.sizeEstimate)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(fpsSetting.description + codecSetting)
                    }
                }

                Section {
                    Toggle("Record system audio", isOn: $rec.captureSystemAudio)
                    Toggle("Record microphone", isOn: $rec.captureMicrophone)
                    Toggle("Show mouse cursor", isOn: $rec.showCursor)
                    Picker("Countdown", selection: $rec.countdownSeconds) {
                        Text("Off").tag(0); Text("3 s").tag(3); Text("5 s").tag(5); Text("10 s").tag(10)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .disabled(rec.isBusy)

            Text(rec.status)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 14)

            HStack {
                Button("Open Folder") { rec.openFolder() }
                SettingsLink { Text("Settings…") }
            }
            .padding(.bottom, 14)
        }
        .padding(.top, 14)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("saveFolder") private var saveFolder = ""
    @AppStorage("nameTemplate") private var template = Recorder.defaultTemplate
    @AppStorage("codec") private var codec = VideoCodec.h264.rawValue
    @AppStorage("fps") private var fps = 60
    @AppStorage("showThumbnail") private var showThumbnail = true

    private var folderPath: String { Recorder.shared.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private var example: String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HH.mm.ss"
        let t = template.trimmingCharacters(in: .whitespaces).isEmpty ? Recorder.defaultTemplate : template
        return sanitizeFileName(t.replacingOccurrences(of: "{date}", with: df.string(from: Date()))
            .replacingOccurrences(of: "{time}", with: tf.string(from: Date()))
            .replacingOccurrences(of: "{screen}", with: "Screen 1")) + ".mov"
    }

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folderPath).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                        if !saveFolder.isEmpty { Button("Default") { saveFolder = ""; reloadLibrary() } }
                    }
                }
                TextField("File name", text: $template)
                Text("Tokens: {date}  {time}  {screen}\nExample: \(example)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Video") {
                Picker("Format", selection: $codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Frame rate", selection: $fps) {
                    Text("30 fps").tag(30); Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                Text("Screens larger than 4096×2304 always use HEVC.").font(.caption).foregroundStyle(.secondary)
            }
            Section("After recording") {
                Toggle("Show floating thumbnail", isOn: $showThumbnail)
            }
            Section("Global shortcuts") {
                ForEach(HotKeys.list, id: \.keys) { item in
                    LabeledContent(item.action) { Text(item.keys).font(.body.monospaced()) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use This Folder"
        p.directoryURL = Recorder.shared.saveFolder
        if p.runModal() == .OK, let url = p.url {
            saveFolder = url.path
            reloadLibrary()
        }
    }

    private func reloadLibrary() {
        Task { @MainActor in Recorder.shared.library.reload(Recorder.shared.saveFolder) }
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @EnvironmentObject var rec: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch rec.state {
        case .idle: Button("Start Recording") { rec.primaryAction() }
        case .countdown: Button("Cancel Countdown") { rec.primaryAction() }
        case .recording, .paused: Button("Stop & Save") { rec.primaryAction() }
        case .saving: Text("Saving…")
        }
        if rec.isCapturing {
            Button(rec.state == .paused ? "Resume" : "Pause") { rec.togglePause() }
            Button("Restart") { Task { await rec.restart() } }
            Button("Discard") { Task { await rec.discard() } }
        }
        Divider()
        Button("Record Area…") { rec.selectArea(thenRecord: true) }.disabled(rec.isBusy)
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Recordings Folder") { rec.openFolder() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Screen Recorder") { NSApp.terminate(nil) }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeys.install()
        HotKeys.register(id: 1, keyCode: kVK_ANSI_R) { Recorder.shared.primaryAction() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_P) { Recorder.shared.togglePause() }
        HotKeys.register(id: 3, keyCode: kVK_ANSI_A) { Recorder.shared.selectArea(thenRecord: true) }
        if SelfTest.isActive { Task { await SelfTest.run() } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Never lose a recording on quit: finish writing the file first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let rec = Recorder.shared
        guard rec.isCapturing else { return .terminateNow }
        Task { @MainActor in
            await rec.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var rec = Recorder.shared

    var body: some Scene {
        Window("Screen Recorder", id: "main") {
            MainView()
                .environmentObject(rec)
                .environmentObject(rec.library)
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Edit Recording", for: URL.self) { $url in
            if let url {
                EditorView(url: url)
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuContent().environmentObject(rec)
        } label: {
            if rec.isCapturing {
                Image(systemName: rec.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                Text(rec.timeString)
            } else {
                Image(systemName: "record.circle")
            }
        }
    }
}
