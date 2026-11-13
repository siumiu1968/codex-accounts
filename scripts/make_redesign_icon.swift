// Draws the Codex Accounts 3.2 icon: a dark rounded square, a quota ring (violet to cyan, three quarters full)
// and two account silhouettes. Usage: swift scripts/make_redesign_icon.swift <output-dir>
// Writes AppIcon.iconset/*, AppIcon.png (1024) and AccountsLogo.png (1024) into <output-dir>.
import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func channel(_ value: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((value >> shift) & 0xFF) / 255 }
    return CGColor(
        red: channel(a, 16) + (channel(b, 16) - channel(a, 16)) * t,
        green: channel(a, 8) + (channel(b, 8) - channel(a, 8)) * t,
        blue: channel(a, 0) + (channel(b, 0) - channel(a, 0)) * t,
        alpha: 1
    )
}

func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Tile: macOS grid, 824 px inside a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.45))
    context.addPath(tilePath)
    context.setFillColor(color(0x10121A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x272B42), color(0x12141E), color(0x0B0C12)] as CFArray,
        locations: [0, 0.62, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glow behind the ring.
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x7C5CFF, 0.30), color(0x7C5CFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0, endCenter: CGPoint(x: 512, y: 520), endRadius: 400, options: [])
    context.restoreGState()

    // Hairline highlight along the top edge.
    context.saveGState()
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // Quota ring.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 268
    let lineWidth: CGFloat = 64
    context.setLineCap(.round)
    context.setLineWidth(lineWidth)
    context.setStrokeColor(color(0xFFFFFF, 0.09))
    context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()

    let start = CGFloat.pi / 2              // 12 o'clock
    let sweep = CGFloat.pi * 2 * 0.74       // three quarters, clockwise
    let steps = 220
    context.setLineCap(.butt)
    for step in 0..<steps {
        let t0 = CGFloat(step) / CGFloat(steps)
        let t1 = CGFloat(step + 1) / CGFloat(steps)
        let colorAt = t0 < 0.5 ? mix(0xA06BFF, 0x5B8CFF, t0 * 2) : mix(0x5B8CFF, 0x3DDCFF, (t0 - 0.5) * 2)
        context.setStrokeColor(colorAt)
        context.addArc(center: center, radius: radius, startAngle: start - sweep * t0, endAngle: start - sweep * t1 - 0.004, clockwise: true)
        context.strokePath()
    }
    // Rounded caps in the end colours.
    let startCap = CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start))
    let endAngle = start - sweep
    let endCap = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
    context.setFillColor(color(0xA06BFF))
    context.fillEllipse(in: CGRect(x: startCap.x - lineWidth / 2, y: startCap.y - lineWidth / 2, width: lineWidth, height: lineWidth))
    context.setFillColor(color(0x3DDCFF))
    context.fillEllipse(in: CGRect(x: endCap.x - lineWidth / 2, y: endCap.y - lineWidth / 2, width: lineWidth, height: lineWidth))
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.fillEllipse(in: CGRect(x: endCap.x - 15, y: endCap.y - 15, width: 30, height: 30))

    // Two accounts: one behind, one in front.
    func person(at origin: CGPoint, scale s: CGFloat, fill: CGColor) {
        context.setFillColor(fill)
        let head = CGRect(x: origin.x - 60 * s, y: origin.y + 6 * s, width: 120 * s, height: 120 * s)
        context.fillEllipse(in: head)
        // Shoulders: the top half of an ellipse with a flat base.
        let width = 250 * s
        let height = 128 * s
        let base = origin.y - 140 * s
        context.saveGState()
        context.clip(to: CGRect(x: origin.x - width / 2 - 2, y: base, width: width + 4, height: height + 2))
        context.fillEllipse(in: CGRect(x: origin.x - width / 2, y: base - height, width: width, height: height * 2))
        context.restoreGState()
    }
    person(at: CGPoint(x: 572, y: 548), scale: 0.78, fill: color(0x8FA3FF, 0.55))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.35))
    person(at: CGPoint(x: 486, y: 516), scale: 1.0, fill: color(0xF4F6FB))
    context.restoreGState()

    context.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawIcon(in: context, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
] {
    try png(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}
let full = png(size: 1024)
try full.write(to: outputDirectory.appendingPathComponent("AppIcon.png"))
try full.write(to: outputDirectory.appendingPathComponent("AccountsLogo.png"))
print("icon written to \(outputDirectory.path)")
