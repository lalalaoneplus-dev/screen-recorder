import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

enum RecState: Equatable {
    case idle, countdown(Int), recording, paused, saving
}

enum CaptureMode: String { case screens, area }

/// Output resolution: like a streaming quality picker, caps the shorter side of the video.
enum RecResolution: String, CaseIterable, Identifiable {
    case full, p1440, p1080, p720, p480
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Full"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
    var maxShortSide: Int? {
        switch self {
        case .full: return nil
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

/// Bitrate level: how much detail is kept per frame.
enum RecQuality: String, CaseIterable, Identifiable {
    case high, standard, small
    var id: String { rawValue }
    var label: String {
        switch self {
        case .high: return "High"
        case .standard: return "Standard"
        case .small: return "Small file"
        }
    }
    var factor: Double {
        switch self {
        case .high: return 1.0
        case .standard: return 0.55
        case .small: return 0.3
        }
    }
}

/// What one capture will produce — used both to record and to show the size estimate.
struct PlannedOutput {
    var label: String
    var w: Int, h: Int
    var codec: VideoCodec
    var bitrate: Int
}

/// An area of one display, in that display's points with a top-left origin.
struct AreaSelection: Codable, Equatable {
    var displayID: UInt32
    var x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

func screen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
}

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()
    static let defaultTemplate = "Screen Recording {date} at {time}"

    let library = Library()
    private let defaults = UserDefaults.standard
    private let overlays = Overlays()

    @Published var displays: [SCDisplay] = []
    @Published var selected: Set<CGDirectDisplayID> = []
    @Published var mode: CaptureMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var area: AreaSelection? {
        didSet { defaults.set(area.flatMap { try? JSONEncoder().encode($0) }, forKey: "area") }
    }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "systemAudio") } }
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: "microphone") } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: "showCursor") } }
    @Published var countdownSeconds: Int { didSet { defaults.set(countdownSeconds, forKey: "countdown") } }
    @Published var resolution: RecResolution { didSet { defaults.set(resolution.rawValue, forKey: "resolution") } }
    @Published var quality: RecQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }

    @Published private(set) var state: RecState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var status = "Ready"
    @Published var needsPermission = false
    /// Files currently being written, so the list can mark them "Recording…".
    @Published private(set) var activeURLs: Set<URL> = []

    /// Set by the UI so AppKit code (thumbnail panel, hotkeys) can open the editor.
    var openEditor: ((URL) -> Void)?

    private var sessions: [CaptureSession] = []
    private var ticker: Timer?
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var countdownTask: Task<Void, Never>?

    private init() {
        defaults.register(defaults: [
            "systemAudio": true, "microphone": false, "showCursor": true, "countdown": 3,
            "fps": 60, "showThumbnail": true, "codec": VideoCodec.h264.rawValue,
            "mode": CaptureMode.screens.rawValue, "nameTemplate": Recorder.defaultTemplate,
            "resolution": RecResolution.full.rawValue, "quality": RecQuality.standard.rawValue,
        ])
        mode = CaptureMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .screens
        area = defaults.data(forKey: "area").flatMap { try? JSONDecoder().decode(AreaSelection.self, from: $0) }
        captureSystemAudio = defaults.bool(forKey: "systemAudio")
        captureMicrophone = defaults.bool(forKey: "microphone")
        showCursor = defaults.bool(forKey: "showCursor")
        countdownSeconds = defaults.integer(forKey: "countdown")
        resolution = RecResolution(rawValue: defaults.string(forKey: "resolution") ?? "") ?? .full
        quality = RecQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .standard
    }

    // MARK: Output size & bitrate

    var fps: Int { max(defaults.integer(forKey: "fps"), 15) }
    var preferredCodec: VideoCodec { VideoCodec(rawValue: defaults.string(forKey: "codec") ?? "") ?? .h264 }

    /// Scale a source pixel size down to the chosen resolution (never up), keeping the shape.
    func plan(label: String, source: (w: Int, h: Int)) -> PlannedOutput {
        var w = Double(source.w), h = Double(source.h)
        if let cap = resolution.maxShortSide, min(w, h) > Double(cap) {
            let k = Double(cap) / min(w, h)
            w *= k; h *= k
        }
        let size = even((Int(w.rounded()), Int(h.rounded())))
        // H.264 hardware encoding tops out at 4096×2304.
        var codec = preferredCodec
        if codec == .h264 && (size.w > 4096 || size.h > 2304) { codec = .hevc }
        let bitsPerPixel = (codec == .h264 ? 0.12 : 0.07) * quality.factor
        let bitrate = Int(min(max(Double(size.w * size.h) * Double(fps) * bitsPerPixel, 500_000), 120_000_000))
        return PlannedOutput(label: label, w: size.w, h: size.h, codec: codec, bitrate: bitrate)
    }

    /// What pressing Record right now would produce.
    func plannedOutputs() -> [PlannedOutput] {
        switch mode {
        case .screens:
            return displays.filter { selected.contains($0.displayID) }
                .map { plan(label: "Screen \(screenNumber($0.displayID))", source: nativeSize($0)) }
        case .area:
            guard let a = area, let d = displays.first(where: { $0.displayID == a.displayID }) else { return [] }
            let scale = Double(nativeSize(d).w) / Double(d.width)
            return [plan(label: "Area", source: (Int(a.w * scale), Int(a.h * scale)))]
        }
    }

    /// Upper estimate of disk use, like a streaming service's "up to X GB per hour".
    var sizeEstimate: String {
        let outs = plannedOutputs()
        guard !outs.isEmpty else { return "" }
        let audioBits = (captureSystemAudio ? 192_000 : 0) + (captureMicrophone ? 192_000 : 0)
        let bitsPerSec = outs.reduce(0) { $0 + $1.bitrate } + audioBits
        let perMin = Int64(Double(bitsPerSec) / 8 * 60)
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let sizes = outs.map { "\($0.label) \($0.w)×\($0.h)" }.joined(separator: ", ")
        return "Up to ≈ \(fmt.string(fromByteCount: perMin)) per minute · \(fmt.string(fromByteCount: perMin * 60)) per hour\n\(sizes) · \(fps) fps"
    }

    // MARK: Derived state

    var isCapturing: Bool { state == .recording || state == .paused }
    var isBusy: Bool { state != .idle }

    var saveFolder: URL {
        if SelfTest.isActive, let t = ProcessInfo.processInfo.environment["SR_SAVE_FOLDER"] { return URL(fileURLWithPath: t, isDirectory: true) }
        if let p = defaults.string(forKey: "saveFolder"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("Screen Recordings", isDirectory: true)
    }

    var timeString: String {
        let t = Int(elapsed)
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    func screenNumber(_ id: CGDirectDisplayID) -> Int { (displays.firstIndex { $0.displayID == id } ?? 0) + 1 }

    /// The real pixel resolution the screen is drawing at right now.
    func nativeSize(_ d: SCDisplay) -> (w: Int, h: Int) {
        if let mode = CGDisplayCopyDisplayMode(d.displayID), mode.pixelWidth > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        let scale = screen(for: d.displayID)?.backingScaleFactor ?? 1
        return (Int(CGFloat(d.width) * scale), Int(CGFloat(d.height) * scale))
    }

    func displayName(_ d: SCDisplay) -> String {
        let name = screen(for: d.displayID)?.localizedName ?? "Display \(d.displayID)"
        let s = nativeSize(d)
        return "Screen \(screenNumber(d.displayID)): \(name) — \(s.w)×\(s.h)"
    }

    var areaDescription: String {
        guard let a = area else { return "No area selected yet" }
        guard let d = displays.first(where: { $0.displayID == a.displayID }) else { return "Area on a screen that isn't connected" }
        let scale = Double(nativeSize(d).w) / Double(d.width)
        return "Screen \(screenNumber(d.displayID)) · \(Int(a.w * scale))×\(Int(a.h * scale)) px"
    }

    func isSelected(_ id: CGDirectDisplayID) -> Bool { selected.contains(id) }
    func setSelected(_ id: CGDirectDisplayID, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    // MARK: Displays & permission

    func loadDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let main = CGMainDisplayID()
            displays = content.displays.sorted {
                if $0.displayID == main { return true }
                if $1.displayID == main { return false }
                return $0.frame.minX < $1.frame.minX
            }
            selected = selected.intersection(Set(displays.map(\.displayID)))
            if selected.isEmpty, let first = displays.first { selected = [first.displayID] }
            if needsPermission { status = "Ready" }
            needsPermission = false
        } catch {
            needsPermission = true
            status = "Screen Recording permission needed"
        }
    }

    // MARK: Actions

    /// Record / Stop / cancel countdown — the big button, ⌥⇧⌘R and the menu bar item.
    func primaryAction() {
        switch state {
        case .idle: Task { await start() }
        case .countdown: cancelCountdown()
        case .recording, .paused: Task { await stop() }
        case .saving: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        if needsPermission || displays.isEmpty { await loadDisplays() }
        guard !needsPermission else { return }
        if mode == .area && area == nil { selectArea(thenRecord: true); return }
        if mode == .screens && selected.isEmpty { status = "Pick at least one screen"; return }

        let n = SelfTest.isActive ? 0 : countdownSeconds
        guard n > 0 else { await begin(); return }
        state = .countdown(n)
        status = "Starting…"
        overlays.showCountdown(n, frames: targetFrames())
        countdownTask = Task { @MainActor [weak self] in
            var left = n
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                left -= 1
                if left > 0 { self.state = .countdown(left); self.overlays.updateCountdown(left) }
            }
            guard let self, !Task.isCancelled else { return }
            self.overlays.hideCountdown()
            await self.begin()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        overlays.hideCountdown()
        state = .idle
        status = "Countdown cancelled"
    }

    private func begin() async {
        countdownTask = nil
        state = .saving   // "busy" while streams spin up
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)

            var micOK = false
            if captureMicrophone {
                micOK = await AVCaptureDevice.requestAccess(for: .audio)
                if !micOK { status = "Microphone access denied — recording without mic" }
            }

            let stamp = Date()
            var specs: [CaptureSpec] = []
            switch mode {
            case .screens:
                let targets = displays.filter { selected.contains($0.displayID) }
                    .compactMap { d in content.displays.first { $0.displayID == d.displayID } }
                guard !targets.isEmpty else { abort("The selected screen isn't connected"); return }
                for (i, d) in targets.enumerated() {
                    let label = "Screen \(screenNumber(d.displayID))"
                    let out = plan(label: label, source: nativeSize(d))
                    specs.append(CaptureSpec(
                        display: d,
                        filter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []),
                        sourceRect: nil, pixelSize: (out.w, out.h), fps: fps, codec: out.codec, bitrate: out.bitrate,
                        showsCursor: showCursor,
                        systemAudio: captureSystemAudio && i == 0, microphone: micOK && i == 0,
                        url: makeURL(stamp, label: label, multi: targets.count > 1)))
                }
            case .area:
                guard let a = area, let d = content.displays.first(where: { $0.displayID == a.displayID }) else {
                    abort("The area's screen isn't connected — select the area again"); return
                }
                let scale = Double(nativeSize(d).w) / Double(d.width)
                let out = plan(label: "Area", source: (Int(a.w * scale), Int(a.h * scale)))
                specs.append(CaptureSpec(
                    display: d,
                    filter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []),
                    sourceRect: a.rect, pixelSize: (out.w, out.h), fps: fps, codec: out.codec, bitrate: out.bitrate,
                    showsCursor: showCursor, systemAudio: captureSystemAudio, microphone: micOK,
                    url: makeURL(stamp, label: "Area", multi: false)))
            }

            var started: [CaptureSession] = []
            do {
                for spec in specs {
                    let s = try CaptureSession(spec: spec)
                    s.onFailure = { [weak self] err in
                        Task { @MainActor in self?.sessionFailed(err) }
                    }
                    do { try await s.start() } catch { s.cancel(); throw error }
                    started.append(s)
                }
            } catch {
                for s in started { _ = await s.finish(); try? FileManager.default.removeItem(at: s.url) }
                throw error
            }

            sessions = started
            activeURLs = Set(started.map(\.url))
            library.reload(saveFolder)
            accumulated = 0
            segmentStart = Date()
            elapsed = 0
            state = .recording
            if !status.hasPrefix("Microphone") {
                status = specs.count > 1 ? "Recording \(specs.count) screens…" : "Recording…"
            }
            if mode == .area, let f = areaGlobalFrame() { overlays.showBorder(f) }
            startTicker()
        } catch {
            let ns = error as NSError
            if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
                needsPermission = true
                abort("Screen Recording permission needed")
            } else {
                abort("Couldn't start: \(error.localizedDescription)")
            }
        }
    }

    private func abort(_ message: String) {
        state = .idle
        status = message
    }

    func togglePause() {
        switch state {
        case .recording:
            sessions.forEach { $0.pause() }
            if let s = segmentStart { accumulated += Date().timeIntervalSince(s) }
            segmentStart = nil
            state = .paused
            status = "Paused"
        case .paused:
            sessions.forEach { $0.resume() }
            segmentStart = Date()
            state = .recording
            status = "Recording…"
        default:
            break
        }
    }

    func stop() async {
        guard isCapturing else { return }
        state = .saving
        status = "Saving…"
        stopTicker()
        overlays.hideAll()
        let current = sessions
        sessions = []
        defer { activeURLs = [] }

        var saved: [URL] = []
        var errors: [String] = []
        for s in current {
            if let e = await s.finish() { errors.append(e.localizedDescription) }
            if FileManager.default.fileExists(atPath: s.url.path) { saved.append(s.url) }
        }
        state = .idle
        if saved.isEmpty {
            status = errors.first.map { "Recording failed: \($0)" } ?? "Nothing was recorded"
        } else if saved.count == 1 {
            status = "Saved: \(saved[0].lastPathComponent)"
        } else {
            status = "Saved \(saved.count) files"
        }
        library.reload(saveFolder)
        if !saved.isEmpty && defaults.bool(forKey: "showThumbnail") {
            ThumbnailPanel.show(urls: saved)
        }
    }

    /// Stop without keeping the file (it goes to the Trash, so it can be recovered).
    func discard() async {
        if case .countdown = state { cancelCountdown(); return }
        guard isCapturing else { return }
        state = .saving
        stopTicker()
        overlays.hideAll()
        let current = sessions
        sessions = []
        activeURLs = []
        for s in current {
            _ = await s.finish()
            try? FileManager.default.trashItem(at: s.url, resultingItemURL: nil)
        }
        elapsed = 0
        state = .idle
        status = "Recording discarded (moved to Trash)"
        library.reload(saveFolder)
    }

    /// Throw away this take and start again.
    func restart() async {
        guard isCapturing else { return }
        await discard()
        await start()
    }

    private func sessionFailed(_ error: Error) {
        guard isCapturing else { return }
        Task {
            await stop()
            status = "Recording stopped: \(error.localizedDescription)"
        }
    }

    func selectArea(thenRecord: Bool) {
        guard state == .idle else { return }
        AreaSelector.begin { [weak self] sel in
            guard let self else { return }
            guard let sel else { self.status = "Area selection cancelled"; return }
            self.area = sel
            self.mode = .area
            Task {
                await self.loadDisplays()
                if thenRecord { await self.start() } else { self.status = "Area selected: \(self.areaDescription)" }
            }
        }
    }

    // MARK: Helpers

    private func startTicker() {
        ticker?.invalidate()   // (must not reset segmentStart — that froze the clock at 0)
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = self.accumulated + (self.segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        elapsed = accumulated + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
        segmentStart = nil
    }

    private func even(_ s: (w: Int, h: Int)) -> (w: Int, h: Int) {
        (max(2, s.w - s.w % 2), max(2, s.h - s.h % 2))
    }

    private func targetFrames() -> [NSRect] {
        switch mode {
        case .screens:
            return displays.filter { selected.contains($0.displayID) }.compactMap { screen(for: $0.displayID)?.frame }
        case .area:
            return areaGlobalFrame().map { [$0] } ?? []
        }
    }

    /// The selected area in AppKit global coordinates (bottom-left origin).
    func areaGlobalFrame() -> NSRect? {
        guard let a = area, let s = screen(for: a.displayID) else { return nil }
        return NSRect(x: s.frame.minX + a.x, y: s.frame.maxY - a.y - a.h, width: a.w, height: a.h)
    }

    private func makeURL(_ date: Date, label: String, multi: Bool) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH.mm.ss"
        var template = defaults.string(forKey: "nameTemplate") ?? Self.defaultTemplate
        if template.trimmingCharacters(in: .whitespaces).isEmpty { template = Self.defaultTemplate }
        var name = template
            .replacingOccurrences(of: "{date}", with: df.string(from: date))
            .replacingOccurrences(of: "{time}", with: tf.string(from: date))
            .replacingOccurrences(of: "{screen}", with: label)
        if multi && !template.contains("{screen}") { name += " (\(label))" }
        return uniqueURL(folder: saveFolder, base: sanitizeFileName(name), ext: "mov")
    }

    // MARK: System

    /// macOS only applies a new Screen Recording grant after the app restarts.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }

    func edit(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        openEditor?(url)
    }
}

func sanitizeFileName(_ s: String) -> String {
    let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
}

func uniqueURL(folder: URL, base: String, ext: String) -> URL {
    var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return url
}

// MARK: - Self-test (run the binary with --selftest; only for development)

@MainActor
enum SelfTest {
    static var isActive: Bool { CommandLine.arguments.contains("--selftest") }

    static func run() async {
        let rec = Recorder.shared
        func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        let savedMode = rec.mode, savedArea = rec.area
        await rec.loadDisplays()
        log("permission ok: \(!rec.needsPermission), displays: \(rec.displays.map { rec.displayName($0) })")
        guard !rec.needsPermission else { exit(2) }

        // 1) All screens: 2s record, 2s pause, 2s record  → expect ~4s files
        let savedRes = rec.resolution, savedQ = rec.quality
        rec.mode = .screens
        rec.selected = Set(rec.displays.map(\.displayID))
        if let r = ProcessInfo.processInfo.environment["SR_RES"].flatMap(RecResolution.init) { rec.resolution = r }
        if let q = ProcessInfo.processInfo.environment["SR_Q"].flatMap(RecQuality.init) { rec.quality = q }
        log("estimate: \(rec.sizeEstimate)")
        await rec.start(); log("state after start: \(rec.state) — \(rec.status)")
        await wait(2); rec.togglePause(); log("paused")
        await wait(2); rec.togglePause(); log("resumed")
        await wait(2); await rec.stop(); log("screens: \(rec.status)")

        // 2) Area on the main screen, with a restart in the middle → expect ~2s file, one file only
        if let d = rec.displays.first {
            rec.area = AreaSelection(displayID: d.displayID, x: 100, y: 100, w: 640, h: 360)
            rec.mode = .area
            await rec.start()
            await wait(1.5); await rec.restart(); log("restarted: \(rec.state)")
            await wait(2); await rec.stop(); log("area: \(rec.status)")
        }

        // 3) Discard → expect no new file
        rec.mode = .screens
        await rec.start(); await wait(1); await rec.discard(); log("discard: \(rec.status)")

        rec.mode = savedMode; rec.area = savedArea; rec.resolution = savedRes; rec.quality = savedQ
        ThumbnailPanel.close()
        log("done")
        exit(0)
    }
}
