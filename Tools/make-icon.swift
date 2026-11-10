// Draws the HostPulse app icon and writes Resources/AppIcon.icns.
//   swiftc Tools/make-icon.swift -o build/make-icon && build/make-icon
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt squircle centered in 1024.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Three server "slots".
    for i in 0..<3 {
        let y = (560 - CGFloat(i) * 150) * s
        let slot = NSBezierPath(roundedRect: NSRect(x: 230 * s, y: y, width: 564 * s, height: 104 * s), xRadius: 26 * s, yRadius: 26 * s)
        NSColor.white.withAlphaComponent(0.08).setFill()
        slot.fill()
        let led = NSBezierPath(ovalIn: NSRect(x: 690 * s, y: y + 36 * s, width: 32 * s, height: 32 * s))
        [NSColor(red: 0.25, green: 0.85, blue: 0.50, alpha: 1), NSColor(red: 0.30, green: 0.62, blue: 1, alpha: 1), NSColor(red: 0.70, green: 0.48, blue: 1, alpha: 1)][i].setFill()
        led.fill()
    }

    // Pulse line across the slots.
    let pulse = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(200, 512), (380, 512), (440, 650), (520, 330), (590, 600), (640, 512), (824, 512)]
    pulse.move(to: NSPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for p in pts.dropFirst() { pulse.line(to: NSPoint(x: p.0 * s, y: p.1 * s)) }
    pulse.lineWidth = 46 * s
    pulse.lineJoinStyle = .round
    pulse.lineCapStyle = .round
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    let glow = NSShadow()
    glow.shadowColor = NSColor(red: 0.30, green: 0.95, blue: 0.75, alpha: 0.8)
    glow.shadowBlurRadius = 30 * s
    glow.set()
    NSColor(red: 0.35, green: 0.95, blue: 0.75, alpha: 1).setStroke()
    pulse.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
print("wrote \(iconset.path)")
