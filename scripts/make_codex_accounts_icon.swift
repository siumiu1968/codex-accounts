import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "macos/CodexAccounts/AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillLinear(_ rect: NSRect, top: NSColor, bottom: NSColor, radius: CGFloat) {
    let path = roundedRect(rect, radius: radius)
    path.addClip()
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
}

func drawShadowedWindow(_ rect: NSRect, tint: NSColor, terminal: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    shadow.set()

    fillLinear(rect, top: NSColor(calibratedWhite: 0.34, alpha: 1), bottom: NSColor(calibratedWhite: 0.13, alpha: 1), radius: 56)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.18).setStroke()
    roundedRect(rect, radius: 56).lineWidth = 3
    roundedRect(rect, radius: 56).stroke()

    let titleBar = NSRect(x: rect.minX, y: rect.maxY - 115, width: rect.width, height: 115)
    fillLinear(titleBar, top: NSColor(calibratedWhite: 0.43, alpha: 1), bottom: NSColor(calibratedWhite: 0.27, alpha: 1), radius: 56)
    NSColor.black.withAlphaComponent(0.18).setFill()
    NSRect(x: rect.minX, y: rect.maxY - 125, width: rect.width, height: 18).fill()

    for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
        color.setFill()
        let dot = NSRect(x: rect.minX + 50 + CGFloat(index) * 55, y: rect.maxY - 76, width: 34, height: 34)
        NSBezierPath(ovalIn: dot).fill()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        NSBezierPath(ovalIn: dot).stroke()
    }

    tint.withAlphaComponent(0.7).setFill()
    roundedRect(NSRect(x: rect.minX + 150, y: rect.maxY - 220, width: rect.width * 0.55, height: 28), radius: 14).fill()
    tint.withAlphaComponent(0.42).setFill()
    roundedRect(NSRect(x: rect.minX + 150, y: rect.maxY - 285, width: rect.width * 0.42, height: 24), radius: 12).fill()
    NSColor.white.withAlphaComponent(0.2).setFill()
    roundedRect(NSRect(x: rect.minX + 150, y: rect.maxY - 350, width: rect.width * 0.5, height: 24), radius: 12).fill()

    if terminal {
        NSColor.white.setStroke()
        let prompt = NSBezierPath()
        prompt.lineWidth = 18
        prompt.lineCapStyle = .round
        prompt.move(to: NSPoint(x: rect.minX + 65, y: rect.maxY - 245))
        prompt.line(to: NSPoint(x: rect.minX + 110, y: rect.maxY - 280))
        prompt.line(to: NSPoint(x: rect.minX + 65, y: rect.maxY - 315))
        prompt.stroke()

        NSColor.white.withAlphaComponent(0.9).setFill()
        roundedRect(NSRect(x: rect.minX + 130, y: rect.maxY - 318, width: 75, height: 15), radius: 8).fill()
    }

    tint.setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 110, y: rect.minY + 68, width: 54, height: 54)).fill()
    roundedRect(NSRect(x: rect.maxX - 128, y: rect.minY + 30, width: 90, height: 50), radius: 24).fill()
}

func drawArrow(center: NSPoint, radius: CGFloat, color: NSColor, clockwise: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 22
    shadow.shadowColor = color.withAlphaComponent(0.45)
    shadow.set()

    color.setStroke()
    let arc = NSBezierPath()
    arc.lineWidth = 32
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: center, radius: radius, startAngle: clockwise ? 130 : -55, endAngle: clockwise ? 15 : -175, clockwise: !clockwise)
    arc.stroke()

    color.setFill()
    let head = NSBezierPath()
    if clockwise {
        head.move(to: NSPoint(x: center.x + radius + 25, y: center.y + 10))
        head.line(to: NSPoint(x: center.x + radius - 55, y: center.y + 62))
        head.line(to: NSPoint(x: center.x + radius - 48, y: center.y - 36))
    } else {
        head.move(to: NSPoint(x: center.x - radius - 25, y: center.y - 10))
        head.line(to: NSPoint(x: center.x - radius + 55, y: center.y - 62))
        head.line(to: NSPoint(x: center.x - radius + 48, y: center.y + 36))
    }
    head.close()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()
}

image.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

NSGraphicsContext.saveGraphicsState()
let bg = roundedRect(NSRect(x: 34, y: 34, width: 956, height: 956), radius: 210)
bg.addClip()
NSGradient(
    colors: [
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)
    ]
)?.draw(in: NSRect(x: 34, y: 34, width: 956, height: 956), angle: -45)
NSGraphicsContext.restoreGraphicsState()

drawArrow(center: NSPoint(x: 250, y: 675), radius: 120, color: NSColor.systemCyan, clockwise: true)
drawArrow(center: NSPoint(x: 770, y: 315), radius: 120, color: NSColor.systemOrange, clockwise: false)

drawShadowedWindow(NSRect(x: 370, y: 410, width: 540, height: 360), tint: NSColor.systemGreen)
drawShadowedWindow(NSRect(x: 270, y: 255, width: 545, height: 355), tint: NSColor.systemYellow)
drawShadowedWindow(NSRect(x: 140, y: 165, width: 565, height: 350), tint: NSColor.systemCyan, terminal: true)

NSColor.white.withAlphaComponent(0.11).setStroke()
roundedRect(NSRect(x: 34, y: 34, width: 956, height: 956), radius: 210).lineWidth = 3
roundedRect(NSRect(x: 34, y: 34, width: 956, height: 956), radius: 210).stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}

try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: output).deletingLastPathComponent().path, withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: output))
