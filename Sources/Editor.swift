import SwiftUI
import AppKit
import AVKit
import AVFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case original, hevc, mp4_1080, mp4_720, mp4_540, mp4_480
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original quality (.mov)"
        case .hevc: return "Smaller file — HEVC (.mov)"
        case .mp4_1080: return "MP4 — up to 1080p"
        case .mp4_720: return "MP4 — up to 720p"
        case .mp4_540: return "MP4 — up to 540p (small)"
        case .mp4_480: return "MP4 — up to 480p (smallest)"
        }
    }
    var preset: String {
        switch self {
        case .original: return AVAssetExportPresetPassthrough
        case .hevc: return AVAssetExportPresetHEVCHighestQuality
        case .mp4_1080: return AVAssetExportPreset1920x1080
        case .mp4_720: return AVAssetExportPreset1280x720
        case .mp4_540: return AVAssetExportPreset960x540
        case .mp4_480: return AVAssetExportPreset640x480
        }
    }
    var fileType: AVFileType { (self == .original || self == .hevc) ? .mov : .mp4 }
    var ext: String { fileType == .mp4 ? "mp4" : "mov" }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var url: URL
    @Published private(set) var player: AVPlayer
    @Published var trimRange: CMTimeRange?
    @Published var format: ExportFormat = .original
    @Published var exporting = false
    @Published var progress: Double = 0
    @Published var message: String?
    @Published var lastExport: URL?
    weak var playerView: AVPlayerView?

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
    }

    func trim() {
        guard let v = playerView, v.canBeginTrimming else {
            message = "The video is still loading — try again in a moment"
            return
        }
        v.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self, result == .okButton, let item = self.player.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                self.trimRange = CMTimeRange(start: start, end: end)
                self.message = nil
            }
        }
    }

    func resetTrim() {
        player.currentItem?.reversePlaybackEndTime = .invalid
        player.currentItem?.forwardPlaybackEndTime = .invalid
        trimRange = nil
    }

    func export(replace: Bool) async {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: format.preset) else {
            message = "That export format isn't available for this video"
            return
        }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let out = replace
            ? folder.appendingPathComponent(".export-\(UUID().uuidString)").appendingPathExtension(format.ext)
            : uniqueURL(folder: folder, base: base + " (edited)", ext: format.ext)
        session.outputURL = out
        session.outputFileType = format.fileType
        session.shouldOptimizeForNetworkUse = format.fileType == .mp4
        if let r = trimRange { session.timeRange = r }

        exporting = true
        progress = 0
        message = "Exporting…"
        let poll = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            let p = Double(session.progress)
            Task { @MainActor in self?.progress = p }
        }
        RunLoop.main.add(poll, forMode: .common)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        poll.invalidate()
        exporting = false

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            message = "Export failed: \(session.error?.localizedDescription ?? "unknown error")"
            return
        }

        if replace {
            do {
                player.replaceCurrentItem(with: nil)
                var final = url.deletingPathExtension().appendingPathExtension(format.ext)
                if final == url {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: out)
                } else {
                    if FileManager.default.fileExists(atPath: final.path) {
                        final = uniqueURL(folder: folder, base: base, ext: format.ext)
                    }
                    try FileManager.default.moveItem(at: out, to: final)
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                url = final
                player = AVPlayer(url: final)
                playerView?.player = player
                trimRange = nil
                message = "Original replaced"
            } catch {
                try? FileManager.default.removeItem(at: out)
                player = AVPlayer(url: url)
                playerView?.player = player
                message = "Couldn't replace the original: \(error.localizedDescription)"
            }
        } else {
            lastExport = out
            message = "Saved “\(out.lastPathComponent)”"
        }
        Recorder.shared.library.refresh()
    }
}

struct PlayerViewRep: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = model.player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        model.playerView = v
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== model.player { v.player = model.player }
        model.playerView = v
    }
}

struct EditorView: View {
    @StateObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReplace = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?

    init(url: URL) { _model = StateObject(wrappedValue: EditorModel(url: url)) }

    var body: some View {
        VStack(spacing: 0) {
            PlayerViewRep(model: model)
                .frame(minWidth: 760, minHeight: 428)
            Divider()
            HStack(spacing: 10) {
                Button { model.trim() } label: { Label("Trim…", systemImage: "scissors") }
                    .help("Drag the yellow handles to choose the part to keep")
                if let r = model.trimRange {
                    Text("Keeping \(Media.formatPrecise(r.start)) – \(Media.formatPrecise(r.end))")
                        .font(.callout.monospacedDigit())
                    Button("Reset") { model.resetTrim() }
                }
                Spacer()
                Picker("Export as", selection: $model.format) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 300)
                Button("Save as New File") { Task { await model.export(replace: false) } }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Replace Original…") { confirmReplace = true }
            }
            .disabled(model.exporting)
            .padding(.horizontal, 14).padding(.top, 12)

            HStack(spacing: 10) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                Button("Rename…") { newName = model.url.deletingPathExtension().lastPathComponent; renaming = true }
                Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                Spacer()
                if model.exporting {
                    ProgressView(value: model.progress).frame(width: 160)
                }
                if let m = model.message {
                    Text(m).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let out = model.lastExport, !model.exporting {
                    Button("Show Export") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    Button("Open Export") { Recorder.shared.edit(out) }
                }
            }
            .disabled(model.exporting)
            .padding(14)
        }
        .navigationTitle(model.url.lastPathComponent)
        .onDisappear { model.player.pause() }
        .confirmationDialog("Replace the original recording?", isPresented: $confirmReplace) {
            Button("Replace Original", role: .destructive) { Task { await model.export(replace: true) } }
        } message: {
            Text(model.trimRange == nil
                 ? "The original file will be re-saved as “\(model.format.label)”."
                 : "Everything outside the trimmed part will be removed from the original file.")
        }
        .confirmationDialog("Move this recording to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                model.player.pause()
                Recorder.shared.library.trash(model.url)
                dismiss()
            }
        }
        .alert("Rename Recording", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                do {
                    let new = try Recorder.shared.library.rename(model.url, to: newName)
                    model.player.pause()
                    model.url = new
                } catch { renameError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(renameError ?? "", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") {}
        }
    }
}
