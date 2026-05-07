import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let outputURL = root.appendingPathComponent("docs/assets/codex-accounts-v2-remote.png")
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

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, mono: Bool = false, maxWidth: CGFloat = 900) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    value.draw(in: NSRect(x: x, y: y, width: maxWidth, height: size * 1.7), withAttributes: attrs)
}

func circle(_ rect: NSRect, fill: NSColor) {
    fill.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

func drawBar(_ rect: NSRect, percent: CGFloat, fill: NSColor) {
    rounded(rect, rect.height / 2, fill: color(1, 1, 1, 0.12))
    rounded(NSRect(x: rect.minX, y: rect.minY, width: max(6, rect.width * percent), height: rect.height), rect.height / 2, fill: fill)
}

func drawProfileRow(_ rect: NSRect, initial: String, name: String, quota: String, reset: String, stroke: NSColor) {
    rounded(rect, 18, fill: color(1, 1, 1, 0.07), stroke: stroke.withAlphaComponent(0.72), lineWidth: 1.4)
    rounded(NSRect(x: rect.minX + 18, y: rect.minY + 13, width: 50, height: 50), 14, fill: color(0.08, 0.24, 0.28), stroke: color(0.12, 0.92, 0.62), lineWidth: 3)
    text(initial, x: rect.minX + 34, y: rect.minY + 27, size: 23, weight: .heavy, color: color(0.84, 1, 0.96), maxWidth: 24)
    text(name, x: rect.minX + 84, y: rect.minY + 42, size: 18, weight: .semibold)
    text("/Users/demo/.codex-accounts/\(name.lowercased())", x: rect.minX + 84, y: rect.minY + 21, size: 12, weight: .medium, color: color(1, 1, 1, 0.48), mono: true, maxWidth: 330)
    text("5H", x: rect.maxX - 430, y: rect.minY + 43, size: 13, weight: .bold, color: color(0.32, 0.78, 1), maxWidth: 32)
    drawBar(NSRect(x: rect.maxX - 382, y: rect.minY + 45, width: 230, height: 16), percent: quota == "100%" ? 1.0 : 0.82, fill: color(0.05, 0.84, 0.72))
    text(quota, x: rect.maxX - 142, y: rect.minY + 42, size: 13, weight: .bold, color: color(1, 1, 1, 0.92), maxWidth: 48)
    text(reset, x: rect.maxX - 88, y: rect.minY + 42, size: 13, weight: .bold, color: color(1, 1, 1, 0.70), mono: true, maxWidth: 52)
    rounded(NSRect(x: rect.maxX - 96, y: rect.minY + 15, width: 68, height: 30), 15, fill: color(0.08, 0.38, 0.30, 0.72), stroke: color(0.16, 0.95, 0.74, 0.48))
    text("打開", x: rect.maxX - 74, y: rect.minY + 22, size: 13, weight: .bold, maxWidth: 40)
}

image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

NSGradient(colors: [
    color(0.00, 0.12, 0.15),
    color(0.03, 0.05, 0.08),
    color(0.14, 0.05, 0.05)
])?.draw(in: NSRect(origin: .zero, size: size), angle: -24)

let mac = NSRect(x: 100, y: 118, width: 1040, height: 744)
rounded(mac, 28, fill: color(0.05, 0.06, 0.07, 0.88), stroke: color(1, 1, 1, 0.18), lineWidth: 1.2)
rounded(NSRect(x: mac.minX, y: mac.maxY - 58, width: mac.width, height: 58), 28, fill: color(0.04, 0.14, 0.18, 0.76))
for (index, dot) in [color(1, 0.34, 0.34), color(1, 0.78, 0.12), color(0.18, 0.82, 0.32)].enumerated() {
    circle(NSRect(x: mac.minX + 28 + CGFloat(index) * 28, y: mac.maxY - 36, width: 14, height: 14), fill: dot)
}
text("Codex Accounts", x: mac.minX + 116, y: mac.maxY - 40, size: 15, weight: .semibold, color: color(1, 1, 1, 0.72))

let sidebar = NSRect(x: mac.minX, y: mac.minY, width: 300, height: mac.height - 58)
NSGradient(colors: [color(0.00, 0.26, 0.28, 0.32), color(0.03, 0.04, 0.07, 0.76)])?.draw(in: sidebar, angle: -28)
rounded(NSRect(x: sidebar.minX + 40, y: sidebar.maxY - 142, width: 84, height: 84), 23, fill: color(1, 1, 1, 0.08), stroke: color(1, 1, 1, 0.14))
if let appIcon = NSImage(contentsOf: root.appendingPathComponent("macos/CodexAccounts/AppIcon.png")) {
    appIcon.draw(in: NSRect(x: sidebar.minX + 52, y: sidebar.maxY - 130, width: 60, height: 60))
}
text("Codex 帳戶", x: sidebar.minX + 40, y: sidebar.maxY - 210, size: 28, weight: .semibold)
text("多帳戶登入，共用本機紀錄。", x: sidebar.minX + 40, y: sidebar.maxY - 250, size: 14, weight: .medium, color: color(1, 1, 1, 0.62), maxWidth: 230)

let bridge = NSRect(x: sidebar.minX + 40, y: sidebar.maxY - 474, width: 220, height: 178)
rounded(bridge, 18, fill: color(0.08, 0.10, 0.11, 0.72), stroke: color(0.12, 0.92, 0.72, 0.26))
text("手機遠端", x: bridge.minX + 16, y: bridge.maxY - 36, size: 15, weight: .semibold, color: color(1, 1, 1, 0.76))
circle(NSRect(x: bridge.maxX - 72, y: bridge.maxY - 28, width: 8, height: 8), fill: color(0.04, 0.92, 0.64))
text("已啟動", x: bridge.maxX - 58, y: bridge.maxY - 34, size: 11, weight: .bold, color: color(0.04, 0.92, 0.64), maxWidth: 48)
text("2 個手機帳號", x: bridge.minX + 16, y: bridge.maxY - 68, size: 12, weight: .semibold, color: color(1, 1, 1, 0.56))
text("http://192.168.1.24:47621", x: bridge.minX + 16, y: bridge.maxY - 94, size: 11, weight: .medium, color: color(0.32, 0.86, 1), mono: true, maxWidth: 190)
rounded(NSRect(x: bridge.minX + 16, y: bridge.minY + 24, width: 88, height: 32), 9, fill: color(1, 1, 1, 0.10))
text("停止 Bridge", x: bridge.minX + 28, y: bridge.minY + 33, size: 11, weight: .semibold, maxWidth: 70)
rounded(NSRect(x: bridge.minX + 114, y: bridge.minY + 24, width: 88, height: 32), 9, fill: color(1, 1, 1, 0.10))
text("新增登入", x: bridge.minX + 134, y: bridge.minY + 33, size: 11, weight: .semibold, maxWidth: 60)

let mainX = sidebar.maxX + 48
text("帳戶", x: mainX, y: mac.maxY - 142, size: 32, weight: .semibold)
text("選擇要開邊個 Codex 登入視窗。登入狀態每分鐘更新。", x: mainX, y: mac.maxY - 182, size: 15, weight: .medium, color: color(1, 1, 1, 0.62), maxWidth: 500)
drawProfileRow(NSRect(x: mainX, y: mac.maxY - 292, width: 650, height: 76), initial: "G", name: "gtc", quota: "100%", reset: "06:32", stroke: color(1, 0.65, 0.06))
drawProfileRow(NSRect(x: mainX, y: mac.maxY - 390, width: 650, height: 76), initial: "P", name: "pro", quota: "82%", reset: "03:10", stroke: color(0.30, 0.88, 0.40))
drawProfileRow(NSRect(x: mainX, y: mac.maxY - 488, width: 650, height: 76), initial: "R", name: "research", quota: "100%", reset: "05:39", stroke: color(0.10, 0.74, 1.00))

let phone = NSRect(x: 1070, y: 84, width: 390, height: 812)
rounded(phone, 46, fill: color(0.02, 0.03, 0.04), stroke: color(1, 1, 1, 0.22), lineWidth: 2)
let screen = phone.insetBy(dx: 16, dy: 18)
rounded(screen, 34, fill: color(0.03, 0.08, 0.11), stroke: color(1, 1, 1, 0.08))
NSGradient(colors: [color(0.02, 0.24, 0.24, 0.62), color(0.05, 0.07, 0.12, 0.80), color(0.18, 0.05, 0.06, 0.55)])?.draw(in: screen, angle: -35)
rounded(NSRect(x: phone.midX - 58, y: phone.maxY - 38, width: 116, height: 20), 10, fill: color(0, 0, 0, 0.82))

let hero = NSRect(x: screen.minX + 22, y: screen.maxY - 194, width: screen.width - 44, height: 150)
rounded(hero, 24, fill: color(1, 1, 1, 0.09), stroke: color(0.12, 0.92, 0.78, 0.26))
text("Mac bridge control", x: hero.minX + 18, y: hero.maxY - 38, size: 12, weight: .bold, color: color(0.48, 0.92, 0.88), maxWidth: 220)
text("Codex Remote", x: hero.minX + 18, y: hero.maxY - 80, size: 30, weight: .heavy, maxWidth: 260)
text("Signed in as mobile-demo", x: hero.minX + 18, y: hero.maxY - 116, size: 13, weight: .medium, color: color(1, 1, 1, 0.72), maxWidth: 260)

let login = NSRect(x: screen.minX + 22, y: screen.maxY - 396, width: screen.width - 44, height: 174)
rounded(login, 22, fill: color(1, 1, 1, 0.08), stroke: color(0.18, 0.72, 1.00, 0.26))
text("Connection", x: login.minX + 18, y: login.maxY - 38, size: 18, weight: .bold)
for (i, value) in ["https://codex-demo.example.com", "CF Access Client ID", "••••••••••••••••"].enumerated() {
    let y = login.maxY - 78 - CGFloat(i) * 38
    rounded(NSRect(x: login.minX + 18, y: y, width: login.width - 36, height: 28), 12, fill: color(1, 1, 1, 0.10), stroke: color(1, 1, 1, 0.12))
    text(value, x: login.minX + 32, y: y + 7, size: 11, weight: .medium, color: color(1, 1, 1, 0.62), mono: i == 0, maxWidth: login.width - 64)
}

let action = NSRect(x: screen.minX + 22, y: screen.minY + 214, width: screen.width - 44, height: 150)
rounded(action, 22, fill: color(1, 1, 1, 0.08), stroke: color(0.12, 0.92, 0.72, 0.26))
text("Automation", x: action.minX + 18, y: action.maxY - 38, size: 18, weight: .bold)
for (i, value) in ["Refresh", "Sync", "Share All", "Close All"].enumerated() {
    let col = i % 2
    let row = i / 2
    let rect = NSRect(x: action.minX + 18 + CGFloat(col) * 150, y: action.maxY - 82 - CGFloat(row) * 50, width: 132, height: 38)
    rounded(rect, 16, fill: i == 3 ? color(1, 0.20, 0.28, 0.40) : color(0.10, 0.74, 0.72, 0.40), stroke: color(1, 1, 1, 0.14))
    text(value, x: rect.minX + 24, y: rect.minY + 12, size: 13, weight: .bold, maxWidth: 90)
}

text("Secure phone control for Codex profiles", x: 138, y: 46, size: 22, weight: .semibold, color: color(1, 1, 1, 0.74), maxWidth: 620)
text("Demo data only. No real usernames, paths, tokens, or account details.", x: 930, y: 46, size: 15, weight: .medium, color: color(1, 1, 1, 0.48), maxWidth: 520)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
    throw NSError(domain: "Screenshot", code: 1)
}

try png.write(to: outputURL)
print(outputURL.path)
