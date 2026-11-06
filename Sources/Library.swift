import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Recordings on disk

@MainActor
final class Library: ObservableObject {
    struct Item: Identifiable, Hashable {
        let url: URL
        let date: Date
        let size: Int64
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    private(set) var folder: URL?

    func reload(_ folder: URL) {
        self.folder = folder
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            .map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return Item(url: u, date: v?.creationDate ?? v?.contentModificationDate ?? .distantPast,
                            size: Int64(v?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    func refresh() { if let folder { reload(folder) } }

    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        let clean = sanitizeFileName(newName)
        guard !clean.isEmpty else { throw message("Please enter a name") }
        let dest = url.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension(url.pathExtension)
        if dest == url { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw message("A file named “\(dest.lastPathComponent)” already exists") }
        try FileManager.default.moveItem(at: url, to: dest)
        refresh()
        return dest
    }

    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        refresh()
    }

    private func message(_ s: String) -> NSError {
        NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }
}

enum Media {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(_ url: URL, maxSize: CGFloat) async -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(maxSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        guard let result = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        let img = NSImage(cgImage: result.image, size: .zero)
        cache.setObject(img, forKey: key)
        return img
    }

    static func duration(_ url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return nil }
        return CMTimeGetSeconds(d)
    }

    static func format(_ secs: Double) -> String {
        let t = Int(secs.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func formatPrecise(_ time: CMTime) -> String {
        let s = max(0, CMTimeGetSeconds(time))
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    static func copyToClipboard(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
}

// MARK: - Floating thumbnail after a recording

@MainActor
enum ThumbnailPanel {
    private static var panel: NSPanel?
    private static var closeWork: DispatchWorkItem?

    static func show(urls: [URL]) {
        close()
        guard !urls.isEmpty, let s = NSScreen.main else { return }
        let size = NSSize(width: 300, height: 240)
        let frame = NSRect(x: s.visibleFrame.maxX - size.width - 18, y: s.visibleFrame.minY + 18,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ThumbnailView(urls: urls))
        p.orderFrontRegardless()
        panel = p
        scheduleClose()
    }

    static func scheduleClose(after seconds: Double = 10) {
        closeWork?.cancel()
        let w = DispatchWorkItem { Task { @MainActor in close() } }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    static func cancelClose() { closeWork?.cancel() }

    static func close() {
        closeWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

struct ThumbnailView: View {
    let urls: [URL]
    @State private var image: NSImage?
    @State private var duration: Double?
    private var url: URL { urls[0] }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.black.opacity(0.4)).overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 276, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Drag into any app")

                Button { ThumbnailPanel.close() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            HStack {
                Text(urls.count > 1 ? "\(urls.count) recordings saved" : url.deletingPathExtension().lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let duration { Text(Media.format(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                button("Edit", "scissors") { Recorder.shared.edit(url); ThumbnailPanel.close() }
                button("Copy", "doc.on.doc") { Media.copyToClipboard(urls); ThumbnailPanel.close() }
                button("Show", "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls); ThumbnailPanel.close() }
                button("Delete", "trash") {
                    urls.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
                    Recorder.shared.library.refresh()
                    Recorder.shared.status = "Recording moved to Trash"
                    ThumbnailPanel.close()
                }
            }
        }
        .padding(12)
        .frame(width: 300, height: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onHover { inside in inside ? ThumbnailPanel.cancelClose() : ThumbnailPanel.scheduleClose(after: 6) }
        .task {
            image = await Media.thumbnail(url, maxSize: 600)
            duration = await Media.duration(url)
        }
    }

    private func button(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Recent recordings list

struct RecentList: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var library: Library
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var deleting: URL?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recordings").font(.headline)
                Text("\(library.items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Button { rec.openFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Open recordings folder")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if library.items.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "video",
                                       description: Text("Recordings you make will appear here."))
            } else {
                List {
                    ForEach(library.items) { item in
                        RecordingRow(item: item,
                                     onRename: { newName = item.name; renaming = item.url },
                                     onDelete: { deleting = item.url })
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let u = renaming {
                    do { try library.rename(u, to: newName) } catch { errorText = error.localizedDescription }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move this recording to the Trash?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let u = deleting { library.trash(u) }
                deleting = nil
            }
        } message: {
            Text(deleting?.lastPathComponent ?? "")
        }
        .alert(errorText ?? "", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        }
    }
}

struct RecordingRow: View {
    let item: Library.Item
    let onRename: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var rec: Recorder
    @State private var thumb: NSImage?
    @State private var duration: Double?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if isLive {
                    Label("Recording…", systemImage: "record.circle.fill").font(.caption).foregroundStyle(.red)
                } else {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !isLive { HStack(spacing: 0) {
                icon("play.fill", "Play") { NSWorkspace.shared.open(item.url) }
                icon("scissors", "Edit / trim") { rec.edit(item.url) }
                icon("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                icon("pencil", "Rename", onRename)
                icon("trash", "Move to Trash", onDelete)
            }
            .opacity(hovering ? 1 : 0.45) }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if !isLive { rec.edit(item.url) } }
        .contextMenu {
            Button("Play") { NSWorkspace.shared.open(item.url) }
            Button("Edit / Trim…") { rec.edit(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy") { Media.copyToClipboard([item.url]) }
            Button("Rename…", action: onRename)
            Divider()
            Button("Move to Trash", role: .destructive, action: onDelete)
        }
        .task(id: item) {   // re-run when the file changes size (e.g. a recording just finished)
            thumb = await Media.thumbnail(item.url, maxSize: 240)
            duration = await Media.duration(item.url)
        }
    }

    private var isLive: Bool { rec.activeURLs.contains(item.url) }

    private var details: String {
        let date = item.date.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return [date, duration.map(Media.format), size].compactMap { $0 }.joined(separator: " · ")
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
