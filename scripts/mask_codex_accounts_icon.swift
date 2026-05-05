import AppKit

guard CommandLine.arguments.count >= 3 else {
    fatalError("Usage: swift mask_codex_accounts_icon.swift input.png output.png")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: input) else {
    fatalError("Could not load input image")
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024), xRadius: 210, yRadius: 210)
clip.addClip()

let sourceRect = NSRect(x: 28, y: 28, width: source.size.width - 56, height: source.size.height - 56)
source.draw(in: NSRect(x: -16, y: -16, width: 1056, height: 1056), from: sourceRect, operation: .sourceOver, fraction: 1)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode output image")
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
