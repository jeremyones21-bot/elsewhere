// Draws the app icon: a flat map tile with a pin that has stepped away from its own spot.
// Usage: icongen <out.icns>
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Tile (macOS grid: 824pt body inside 1024 canvas).
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.93, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Two streets.
    NSColor.white.setStroke()
    let roads = NSBezierPath()
    roads.lineWidth = 70 * s
    roads.move(to: NSPoint(x: 100 * s, y: 380 * s)); roads.line(to: NSPoint(x: 924 * s, y: 560 * s))
    roads.move(to: NSPoint(x: 560 * s, y: 100 * s)); roads.line(to: NSPoint(x: 470 * s, y: 924 * s))
    roads.stroke()
    NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
    let edges = NSBezierPath(); edges.lineWidth = 4 * s
    edges.append(roads)
    NSGraphicsContext.restoreGraphicsState()

    // The real spot: a hollow ring.
    NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
    let ring = NSBezierPath(ovalIn: r(250, 250, 120, 120)); ring.lineWidth = 22 * s
    ring.stroke()

    // Dotted trail from the real spot to the pin.
    NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
    for i in 0..<4 {
        let t = CGFloat(i + 1) / 5
        let x = 310 + (560 - 310) * t, y = 310 + (440 - 310) * t
        NSBezierPath(ovalIn: r(x - 14, y - 14, 28, 28)).fill()
    }

    // The pin.
    let pin = NSBezierPath()
    let cx: CGFloat = 640, cy: CGFloat = 640, rad: CGFloat = 150
    pin.move(to: NSPoint(x: cx * s, y: (cy - rad - 190) * s))
    pin.appendArc(withCenter: NSPoint(x: cx * s, y: cy * s), radius: rad * s, startAngle: 220, endAngle: -40, clockwise: true)
    pin.close()
    NSColor(calibratedRed: 0.10, green: 0.43, blue: 0.95, alpha: 1).setFill()
    pin.fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: r(cx - 58, cy - 58, 116, 116)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Elsewhere.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run()
p.waitUntilExit()
