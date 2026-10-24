// Draws the app icon and writes Icon/AppIcon.icns.
// Run from the project folder: swift Icon/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // macOS icon grid: an 824-point rounded square centred on a 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.16, blue: 0.55, alpha: 1),
                        NSColor(red: 0.55, green: 0.22, blue: 0.70, alpha: 1),
                        NSColor(red: 0.98, green: 0.45, blue: 0.45, alpha: 1)])!
        .draw(in: tilePath, angle: 60)

    // A desktop screen with a looping play button.
    let screen = NSRect(x: 230 * s, y: 330 * s, width: 564 * s, height: 380 * s)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 36 * s, yRadius: 36 * s)
    NSColor.white.withAlphaComponent(0.95).setFill()
    screenPath.fill()
    let stand = NSBezierPath(roundedRect: NSRect(x: 412 * s, y: 250 * s, width: 200 * s, height: 44 * s),
                             xRadius: 22 * s, yRadius: 22 * s)
    stand.fill()

    let c = NSPoint(x: screen.midX, y: screen.midY)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: c, radius: 112 * s, startAngle: 120, endAngle: 420)
    ring.lineWidth = 26 * s
    ring.lineCapStyle = .round
    NSColor(red: 0.45, green: 0.22, blue: 0.68, alpha: 1).setStroke()
    ring.stroke()

    let play = NSBezierPath()
    play.move(to: NSPoint(x: c.x - 34 * s, y: c.y - 52 * s))
    play.line(to: NSPoint(x: c.x - 34 * s, y: c.y + 52 * s))
    play.line(to: NSPoint(x: c.x + 56 * s, y: c.y))
    play.close()
    NSColor(red: 0.45, green: 0.22, blue: 0.68, alpha: 1).setFill()
    play.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "Icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Icon/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote Icon/AppIcon.icns")
