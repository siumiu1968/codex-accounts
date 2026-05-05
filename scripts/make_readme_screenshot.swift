import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let outputURL = root.appendingPathComponent("docs/assets/codex-accounts-overview.png")
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let size = NSSize(width: 1600, height: 980)
let image = NSImage(size: size)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func rounded(_ rect: NSRect, _ radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, mono: Bool = false, maxWidth: CGFloat? = nil) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    let rect = NSRect(x: x, y: y, width: maxWidth ?? 900, height: size * 1.45)
    value.draw(in: rect, withAttributes: attrs)
}

func drawIcon(name: String, rect: NSRect) {
    let iconURL = root.appendingPathComponent("macos/CodexAccounts/ProfileLetterIcons/ProfileIcon-\(name).png")
    if let icon = NSImage(contentsOf: iconURL) {
        icon.draw(in: rect)
    }
}

image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

NSGradient(colors: [
    color(0.02, 0.08, 0.11),
    color(0.04, 0.05, 0.08),
    color(0.12, 0.05, 0.04)
])?.draw(in: NSRect(origin: .zero, size: size), angle: -28)

let window = NSRect(x: 84, y: 72, width: 1432, height: 836)
rounded(window, 22, fill: color(0.05, 0.06, 0.07, 0.86), stroke: color(1, 1, 1, 0.16), lineWidth: 1.2)

let titlebar = NSRect(x: window.minX, y: window.maxY - 54, width: window.width, height: 54)
rounded(titlebar, 22, fill: color(0.05, 0.13, 0.18, 0.72))
NSColor.black.withAlphaComponent(0.18).setFill()
NSRect(x: window.minX, y: window.maxY - 54, width: window.width, height: 12).fill()

for (index, dotColor) in [color(1, 0.34, 0.34), color(1, 0.78, 0.12), color(0.18, 0.82, 0.32)].enumerated() {
    dotColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: window.minX + 24 + CGFloat(index) * 28, y: window.maxY - 34, width: 14, height: 14)).fill()
}
text("Codex Accounts", x: window.minX + 116, y: window.maxY - 39, size: 15, weight: .semibold, color: color(1, 1, 1, 0.72))

let sidebar = NSRect(x: window.minX, y: window.minY, width: 318, height: window.height - 54)
NSColor.black.withAlphaComponent(0.26).setFill()
sidebar.fill()
NSGradient(colors: [color(0.00, 0.24, 0.28, 0.34), color(0.02, 0.04, 0.07, 0.54)])?.draw(in: sidebar, angle: -38)

let appIconRect = NSRect(x: sidebar.minX + 52, y: sidebar.maxY - 156, width: 96, height: 96)
rounded(appIconRect, 24, fill: color(0.05, 0.08, 0.10, 0.76), stroke: color(1, 1, 1, 0.14))
if let appIcon = NSImage(contentsOf: root.appendingPathComponent("macos/CodexAccounts/AppIcon.png")) {
    appIcon.draw(in: appIconRect.insetBy(dx: 12, dy: 12))
}

text("Codex 帳戶", x: sidebar.minX + 52, y: sidebar.maxY - 230, size: 31, weight: .semibold)
text("多帳戶登入，共用本機紀錄。", x: sidebar.minX + 52, y: sidebar.maxY - 272, size: 15, weight: .medium, color: color(1, 1, 1, 0.68))

let settings = NSRect(x: sidebar.minX + 52, y: sidebar.maxY - 548, width: 222, height: 236)
rounded(settings, 18, fill: color(0.08, 0.09, 0.10, 0.68), stroke: color(1, 1, 1, 0.13))
text("語言", x: settings.minX + 18, y: settings.maxY - 39, size: 14, weight: .semibold, color: color(1, 1, 1, 0.72))
rounded(NSRect(x: settings.minX + 18, y: settings.maxY - 72, width: 92, height: 28), 8, fill: color(0.10, 0.50, 0.96, 1))
text("中文", x: settings.minX + 38, y: settings.maxY - 66, size: 14, weight: .semibold)
rounded(NSRect(x: settings.minX + 104, y: settings.maxY - 72, width: 62, height: 28), 8, fill: color(1, 1, 1, 0.12))
text("EN", x: settings.minX + 126, y: settings.maxY - 66, size: 14, weight: .semibold, color: color(1, 1, 1, 0.76))
NSColor.white.withAlphaComponent(0.18).setStroke()
let divider = NSBezierPath()
divider.move(to: NSPoint(x: settings.minX + 18, y: settings.maxY - 96))
divider.line(to: NSPoint(x: settings.maxX - 18, y: settings.maxY - 96))
divider.stroke()
text("自動化", x: settings.minX + 18, y: settings.maxY - 129, size: 14, weight: .semibold, color: color(1, 1, 1, 0.72))
text("每分鐘重新整理", x: settings.minX + 18, y: settings.maxY - 160, size: 14, weight: .medium)
text("每分鐘同步記憶", x: settings.minX + 18, y: settings.maxY - 194, size: 14, weight: .medium)
for y in [settings.maxY - 160, settings.maxY - 194] {
    rounded(NSRect(x: settings.maxX - 62, y: y - 4, width: 42, height: 22), 11, fill: color(0.0, 0.48, 1.0))
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: settings.maxX - 42, y: y - 2, width: 18, height: 18)).fill()
}
text("已自動同步 14:57", x: sidebar.minX + 52, y: sidebar.minY + 48, size: 13, weight: .medium, color: color(1, 1, 1, 0.52))

let mainX = sidebar.maxX + 48
text("帳戶", x: mainX, y: window.maxY - 138, size: 31, weight: .semibold)
text("選擇要開邊個 Codex 登入視窗。登入狀態每分鐘更新。", x: mainX, y: window.maxY - 176, size: 15, weight: .medium, color: color(1, 1, 1, 0.62))

for (i, symbol) in ["+", "↻", "▭"].enumerated() {
    let rect = NSRect(x: window.maxX - 196 + CGFloat(i) * 56, y: window.maxY - 170, width: 42, height: 42)
    rounded(rect, 14, fill: color(1, 1, 1, 0.10), stroke: color(1, 1, 1, 0.14))
    text(symbol, x: rect.minX + 12, y: rect.minY + 8, size: 22, weight: .semibold, color: color(1, 1, 1, 0.84), maxWidth: 30)
}

let rows: [(String, String, String, Bool)] = [
    ("A", "Account 1", "/Users/demo/.codex", true),
    ("W", "Work", "/Users/demo/.codex-account2", true),
    ("R", "Research", "/Users/demo/.codex-accounts/research", false),
    ("C", "Client", "/Users/demo/.codex-accounts/client", false),
    ("P", "Personal", "/Users/demo/.codex-accounts/personal", true)
]

let rowWidth: CGFloat = window.maxX - mainX - 52
for (index, row) in rows.enumerated() {
    let y = window.maxY - 250 - CGFloat(index) * 76
    let rect = NSRect(x: mainX, y: y, width: rowWidth, height: 58)
    rounded(rect, 18, fill: color(1, 1, 1, 0.07), stroke: color(1, 1, 1, 0.10))
    drawIcon(name: row.0, rect: NSRect(x: rect.minX + 18, y: rect.minY + 10, width: 38, height: 38))
    text(row.1, x: rect.minX + 72, y: rect.minY + 32, size: 16, weight: .semibold, maxWidth: 360)
    text(row.2, x: rect.minX + 72, y: rect.minY + 12, size: 12, weight: .medium, color: color(1, 1, 1, 0.50), mono: true, maxWidth: 460)
    let statusColor = row.3 ? color(0.16, 0.88, 0.38) : color(1.0, 0.60, 0.16)
    rounded(NSRect(x: rect.maxX - 352, y: rect.minY + 16, width: 92, height: 26), 13, fill: statusColor.withAlphaComponent(0.16))
    text(row.3 ? "已登入" : "要登入", x: rect.maxX - 326, y: rect.minY + 22, size: 13, weight: .semibold, color: statusColor, maxWidth: 64)
    text("用量 未知", x: rect.maxX - 226, y: rect.minY + 30, size: 11, weight: .medium, color: color(1, 1, 1, 0.50), maxWidth: 70)
    text("重設 未知", x: rect.maxX - 226, y: rect.minY + 13, size: 11, color: color(1, 1, 1, 0.34), maxWidth: 70)
    let actionColor = row.3 ? color(0.20, 0.92, 0.96) : color(1.0, 0.62, 0.16)
    rounded(NSRect(x: rect.maxX - 118, y: rect.minY + 14, width: 64, height: 30), 15, fill: color(0, 0, 0, 0.34), stroke: actionColor.withAlphaComponent(0.55))
    text(row.3 ? "打開" : "登入", x: rect.maxX - 96, y: rect.minY + 21, size: 13, weight: .semibold, maxWidth: 40)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.maxX - 42, y: rect.minY + 14, width: 30, height: 30)).fill()
    text("×", x: rect.maxX - 34, y: rect.minY + 19, size: 18, weight: .semibold, color: color(1, 1, 1, 0.72), maxWidth: 20)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
    throw NSError(domain: "Screenshot", code: 1)
}

try png.write(to: outputURL)
print(outputURL.path)

