import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "macos/CodexAccounts/ProfileLetterIcons"
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

struct Palette {
    let top: NSColor
    let middle: NSColor
    let bottom: NSColor
    let glow: NSColor
}

let palettes: [Palette] = [
    Palette(top: NSColor(calibratedRed: 0.22, green: 0.91, blue: 1.00, alpha: 1), middle: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.98, alpha: 1), bottom: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.42, alpha: 1), glow: NSColor(calibratedRed: 0.20, green: 0.90, blue: 1.00, alpha: 1)),
    Palette(top: NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 1), middle: NSColor(calibratedRed: 0.98, green: 0.24, blue: 0.52, alpha: 1), bottom: NSColor(calibratedRed: 0.32, green: 0.11, blue: 0.46, alpha: 1), glow: NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.18, alpha: 1)),
    Palette(top: NSColor(calibratedRed: 0.38, green: 1.00, blue: 0.66, alpha: 1), middle: NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.58, alpha: 1), bottom: NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.28, alpha: 1), glow: NSColor(calibratedRed: 0.38, green: 1.00, blue: 0.66, alpha: 1)),
    Palette(top: NSColor(calibratedRed: 0.78, green: 0.52, blue: 1.00, alpha: 1), middle: NSColor(calibratedRed: 0.34, green: 0.32, blue: 0.96, alpha: 1), bottom: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.34, alpha: 1), glow: NSColor(calibratedRed: 0.70, green: 0.48, blue: 1.00, alpha: 1)),
    Palette(top: NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.28, alpha: 1), middle: NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.16, alpha: 1), bottom: NSColor(calibratedRed: 0.42, green: 0.10, blue: 0.08, alpha: 1), glow: NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.24, alpha: 1)),
    Palette(top: NSColor(calibratedRed: 0.88, green: 0.96, blue: 1.00, alpha: 1), middle: NSColor(calibratedRed: 0.32, green: 0.56, blue: 1.00, alpha: 1), bottom: NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.60, alpha: 1), glow: NSColor(calibratedRed: 0.60, green: 0.78, blue: 1.00, alpha: 1))
]

func drawIcon(letter: String?, palette: Palette, outputName: String) throws {
    let size = NSSize(width: 128, height: 128)
    let image = NSImage(size: size)

    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let iconRect = NSRect(x: 8, y: 8, width: 112, height: 112)
    let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 30, yRadius: 30)
    NSGraphicsContext.saveGraphicsState()
    iconPath.addClip()

    NSGradient(colors: [palette.top, palette.middle, palette.bottom])?.draw(in: iconPath, angle: -38)

    palette.glow.withAlphaComponent(0.36).setFill()
    NSBezierPath(ovalIn: NSRect(x: 64, y: -10, width: 74, height: 74)).fill()

    NSColor.white.withAlphaComponent(0.30).setFill()
    NSBezierPath(ovalIn: NSRect(x: -10, y: 76, width: 74, height: 74)).fill()

    NSColor.white.withAlphaComponent(0.12).setStroke()
    let slash = NSBezierPath()
    slash.lineWidth = 8
    slash.move(to: NSPoint(x: 18, y: 104))
    slash.line(to: NSPoint(x: 98, y: 24))
    slash.stroke()

    if let letter {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 66, weight: .black),
            .foregroundColor: NSColor.white,
            .kern: -1.5
        ]
        let textSize = letter.size(withAttributes: attrs)
        let point = NSPoint(x: iconRect.midX - textSize.width / 2, y: iconRect.midY - textSize.height / 2 - 1)
        NSShadow().with {
            $0.shadowBlurRadius = 7
            $0.shadowOffset = NSSize(width: 0, height: -2)
            $0.shadowColor = NSColor.black.withAlphaComponent(0.32)
        }.set()
        letter.draw(at: point, withAttributes: attrs)
    } else {
        let symbol = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 56, weight: .semibold)
        let configured = symbol?.withSymbolConfiguration(config)
        configured?.isTemplate = true
        NSColor.white.set()
        configured?.draw(in: NSRect(x: 36, y: 36, width: 56, height: 56))
    }

    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.24).setStroke()
    let stroke = NSBezierPath(roundedRect: iconRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 30, yRadius: 30)
    stroke.lineWidth = 1.5
    stroke.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ProfileIconGeneration", code: 1)
    }
    try png.write(to: outputURL.appendingPathComponent(outputName))
}

extension NSShadow {
    func with(_ configure: (NSShadow) -> Void) -> NSShadow {
        configure(self)
        return self
    }
}

let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
for (index, char) in letters.enumerated() {
    try drawIcon(letter: String(char), palette: palettes[index % palettes.count], outputName: "ProfileIcon-\(char).png")
}
try drawIcon(letter: nil, palette: palettes[3], outputName: "ProfileIcon-Default.png")

