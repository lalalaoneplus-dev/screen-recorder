import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Area selection

/// Full-screen dimmed overlay on every display; drag to pick an area, Esc to cancel.
@MainActor
enum AreaSelector {
    private static var windows: [NSWindow] = []
    private static var completion: ((AreaSelection?) -> Void)?
    private static var escMonitor: Any?

    static func begin(_ done: @escaping (AreaSelection?) -> Void) {
        if !windows.isEmpty { finish(nil) }
        completion = done
        let mouse = NSEvent.mouseLocation
        for s in NSScreen.screens {
            // A non-activating panel can sit over every screen and Space (including another
            // app's full-screen meeting window) and still take the drag.
            let w = OverlayPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.setFrame(s.frame, display: false)
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = SelectionView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.targetScreen = s
            w.contentView = v
            w.orderFrontRegardless()
            if s.frame.contains(mouse) { w.makeKey(); w.makeFirstResponder(v) }
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { finish(nil); return nil }
            return e
        }
    }

    static func finish(_ result: AreaSelection?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        escMonitor = nil
        let c = completion
        completion = nil
        c?(result)
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var targetScreen: NSScreen!
    private var start: NSPoint?
    private var current: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = clamp(convert(e.locationInWindow, from: nil))
        current = nil
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let p = clamp(convert(e.locationInWindow, from: nil))
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let r = current?.integral, r.width >= 16, r.height >= 16 else {
            start = nil; current = nil; needsDisplay = true
            return
        }
        let sel = AreaSelection(displayID: displayID(of: targetScreen),
                                x: r.minX, y: bounds.height - r.maxY, w: r.width, h: r.height)
        Task { @MainActor in AreaSelector.finish(sel) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let r = current else {
            drawLabel("Drag on any screen to select the area to record  ·  Esc to cancel",
                      at: NSPoint(x: bounds.midX, y: bounds.midY), centered: true, size: 18)
            return
        }
        NSColor.clear.setFill()
        r.fill(using: .copy)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        let scale = targetScreen.backingScaleFactor
        let text = "\(Int(r.width * scale)) × \(Int(r.height * scale))"
        let below = r.minY - 28 > 0
        drawLabel(text, at: NSPoint(x: r.maxX, y: below ? r.minY - 26 : r.minY + 6), centered: false, size: 12, rightAligned: true)
    }

    private func drawLabel(_ s: String, at p: NSPoint, centered: Bool, size: CGFloat, rightAligned: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let sz = str.size()
        var origin = p
        if centered { origin = NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2) }
        if rightAligned { origin.x = p.x - sz.width - 12 }
        let bg = NSRect(x: origin.x - 8, y: origin.y - 4, width: sz.width + 16, height: sz.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        str.draw(at: origin)
    }
}

// MARK: - Countdown + area border

@MainActor
final class Overlays {
    final class CountModel: ObservableObject { @Published var n = 3 }
    private let model = CountModel()
    private var countdownWindows: [NSWindow] = []
    private var borderWindow: NSWindow?

    private func makeWindow(_ frame: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }

    func showCountdown(_ n: Int, frames: [NSRect]) {
        hideCountdown()
        model.n = n
        for f in frames {
            let size: CGFloat = 180
            let w = makeWindow(NSRect(x: f.midX - size / 2, y: f.midY - size / 2, width: size, height: size))
            w.contentView = NSHostingView(rootView: CountdownBubble(model: model))
            w.orderFrontRegardless()
            countdownWindows.append(w)
        }
    }

    func updateCountdown(_ n: Int) { model.n = n }

    func hideCountdown() {
        countdownWindows.forEach { $0.orderOut(nil) }
        countdownWindows = []
    }

    func showBorder(_ frame: NSRect) {
        hideBorder()
        let w = makeWindow(frame.insetBy(dx: -4, dy: -4))
        w.level = .statusBar
        w.contentView = NSHostingView(rootView:
            Rectangle().strokeBorder(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
        w.orderFrontRegardless()
        borderWindow = w
    }

    func hideBorder() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    func hideAll() { hideCountdown(); hideBorder() }
}

struct CountdownBubble: View {
    @ObservedObject var model: Overlays.CountModel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36).fill(Color.black.opacity(0.72))
            Text("\(model.n)")
                .font(.system(size: 100, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Global hotkeys (Carbon; needs no Accessibility permission)

@MainActor
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static let mods = UInt32(cmdKey | optionKey | shiftKey)
    static let list: [(keys: String, action: String)] = [
        ("⌥⇧⌘R", "Start / stop recording"),
        ("⌥⇧⌘P", "Pause / resume"),
        ("⌥⇧⌘A", "Select an area and record"),
    ]

    static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKeys.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(id: UInt32, keyCode: Int, _ handler: @escaping () -> Void) {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), mods, EventHotKeyID(signature: OSType(0x5352_4543), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    static func fire(_ id: UInt32) { handlers[id]?() }
}
