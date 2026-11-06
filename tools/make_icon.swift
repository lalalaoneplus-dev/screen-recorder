import AppKit

// Draws the app icon at a given pixel size and writes PNGs into an .iconset folder.
func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Drop shadow
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill(); bg.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // Monitor outline
    let mw = rect.width * 0.64, mh = rect.width * 0.42
    let mRect = NSRect(x: rect.midX - mw / 2, y: rect.midY - mh / 2 + rect.width * 0.06, width: mw, height: mh)
    let monitor = NSBezierPath(roundedRect: mRect, xRadius: s * 0.03, yRadius: s * 0.03)
    monitor.lineWidth = s * 0.028
    NSColor.white.withAlphaComponent(0.92).setStroke()
    monitor.stroke()
    // Stand
    let stand = NSBezierPath()
    stand.lineWidth = s * 0.028
    stand.lineCapStyle = .round
    stand.move(to: NSPoint(x: rect.midX, y: mRect.minY))
    stand.line(to: NSPoint(x: rect.midX, y: mRect.minY - rect.width * 0.08))
    stand.move(to: NSPoint(x: rect.midX - rect.width * 0.12, y: mRect.minY - rect.width * 0.08))
    stand.line(to: NSPoint(x: rect.midX + rect.width * 0.12, y: mRect.minY - rect.width * 0.08))
    stand.stroke()

    // Record dot
    let r = rect.width * 0.13
    let dot = NSBezierPath(ovalIn: NSRect(x: mRect.midX - r, y: mRect.midY - r, width: 2 * r, height: 2 * r))
    NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1),
                        NSColor(calibratedRed: 0.86, green: 0.10, blue: 0.12, alpha: 1)])!
        .draw(in: dot, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: CGFloat(base)).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try draw(size: CGFloat(base * 2)).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
