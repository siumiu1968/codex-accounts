import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let outputDirectory = root.appendingPathComponent("docs/assets", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

struct Copy {
    let code: String
    let outputName: String
    let flag: String
    let language: String
    let appTitle: String
    let subtitle: String
    let today: String
    let automation: String
    let syncSubtitle: String
    let refresh: String
    let autoSync: String
    let syncNow: String
    let shareAll: String
    let systemTools: String
    let toolsSubtitle: String
    let mobile: String
    let mobileSubtitle: String
    let appearance: String
    let updates: String
    let updateSubtitle: String
    let profilesTitle: String
    let headerLine1: String
    let headerLine2: String
    let signedIn: String
    let open: String
    let logIn: String
    let waiting: String
    let theme: String
    let updateChannel: String
}

let copies = [
    Copy(
        code: "zh-HK",
        outputName: "codex-accounts-v2.2-zh-HK.png",
        flag: "🇭🇰",
        language: "繁中 HK",
        appTitle: "Codex 帳戶",
        subtitle: "多帳戶登入，共用本機紀錄。",
        today: "今日使用",
        automation: "自動化",
        syncSubtitle: "同步：剛剛",
        refresh: "每分鐘重新整理",
        autoSync: "每分鐘同步記憶",
        syncNow: "立即同步",
        shareAll: "共享全部",
        systemTools: "系統工具",
        toolsSubtitle: "防睡眠關 · 清潔關",
        mobile: "對話包",
        mobileSubtitle: "匯出 / 導入",
        appearance: "外觀",
        updates: "更新",
        updateSubtitle: "目前 2.2.0",
        profilesTitle: "帳戶",
        headerLine1: "選擇要開邊個 Codex 登入視窗。",
        headerLine2: "登入狀態每分鐘更新。",
        signedIn: "已登入",
        open: "打開",
        logIn: "登入",
        waiting: "等待恢復",
        theme: "石墨",
        updateChannel: "GitHub 更新通道"
    ),
    Copy(
        code: "zh-CN",
        outputName: "codex-accounts-v2.2-zh-CN.png",
        flag: "🇨🇳",
        language: "简中",
        appTitle: "Codex 账号",
        subtitle: "多账号登录，共享本机记录。",
        today: "今日使用",
        automation: "自动化",
        syncSubtitle: "同步：刚刚",
        refresh: "每分钟刷新",
        autoSync: "每分钟同步记忆",
        syncNow: "立即同步",
        shareAll: "共享全部",
        systemTools: "系统工具",
        toolsSubtitle: "防睡眠关 · 清洁关",
        mobile: "对话包",
        mobileSubtitle: "未启动",
        appearance: "外观",
        updates: "更新",
        updateSubtitle: "当前 2.2.0",
        profilesTitle: "账号",
        headerLine1: "选择要打开的 Codex 登录窗口。",
        headerLine2: "登录状态每分钟更新。",
        signedIn: "已登录",
        open: "开启",
        logIn: "登录",
        waiting: "等待恢复",
        theme: "石墨",
        updateChannel: "GitHub 更新通道"
    ),
    Copy(
        code: "en",
        outputName: "codex-accounts-v2.2-en.png",
        flag: "🇺🇸",
        language: "English",
        appTitle: "Codex Accounts",
        subtitle: "Separate logins. Shared local history.",
        today: "Today",
        automation: "Automation",
        syncSubtitle: "Sync: just now",
        refresh: "Auto refresh",
        autoSync: "Auto sync",
        syncNow: "Sync now",
        shareAll: "Share all",
        systemTools: "System Tools",
        toolsSubtitle: "Awake off · Clean off",
        mobile: "Packages",
        mobileSubtitle: "Export / Import",
        appearance: "Appearance",
        updates: "Updates",
        updateSubtitle: "Current 2.2.0",
        profilesTitle: "Profiles",
        headerLine1: "Choose an account window.",
        headerLine2: "Login state refreshes every minute.",
        signedIn: "Signed in",
        open: "Open",
        logIn: "Log In",
        waiting: "Waiting",
        theme: "Graphite",
        updateChannel: "GitHub update channel"
    )
]

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
    value.draw(in: NSRect(x: x, y: y, width: maxWidth, height: size * 1.6), withAttributes: attrs)
}

func drawIcon(letter: String, rect: NSRect, accent: NSColor) {
    rounded(rect, 14, fill: color(0.08, 0.24, 0.30), stroke: color(0.12, 0.95, 0.58), lineWidth: 4)
    NSGradient(colors: [accent, color(0.12, 0.70, 1.00)])?.draw(in: rect.insetBy(dx: 5, dy: 5), angle: -35)
    text(letter, x: rect.minX + 15, y: rect.minY + 15, size: 25, weight: .heavy, color: .white, maxWidth: 28)
}

func drawSwitch(_ rect: NSRect, on: Bool) {
    let accent = on ? color(0.00, 0.82, 0.68) : color(0.42, 0.47, 0.54)
    rounded(rect, rect.height / 2, fill: accent.withAlphaComponent(on ? 0.62 : 0.34), stroke: color(1, 1, 1, 0.20))
    let knobX = on ? rect.maxX - rect.height + 3 : rect.minX + 3
    NSColor.white.withAlphaComponent(0.88).setFill()
    NSBezierPath(ovalIn: NSRect(x: knobX, y: rect.minY + 3, width: rect.height - 6, height: rect.height - 6)).fill()
}

func drawDisclosure(_ rect: NSRect, title: String, subtitle: String, symbol: String, accent: NSColor, expanded: Bool = false) {
    rounded(rect, 13, fill: accent.withAlphaComponent(expanded ? 0.16 : 0.08), stroke: accent.withAlphaComponent(expanded ? 0.42 : 0.18))
    text(symbol, x: rect.minX + 16, y: rect.minY + 18, size: 18, weight: .semibold, color: accent, maxWidth: 24)
    text(title, x: rect.minX + 50, y: rect.minY + 28, size: 16, weight: .bold, color: color(1, 1, 1, 0.86), maxWidth: rect.width - 90)
    text(subtitle, x: rect.minX + 50, y: rect.minY + 10, size: 12, weight: .semibold, color: color(1, 1, 1, 0.46), maxWidth: rect.width - 90)
    text(expanded ? "⌃" : "⌄", x: rect.maxX - 34, y: rect.minY + 21, size: 18, weight: .bold, color: color(1, 1, 1, 0.56), maxWidth: 20)
}

func drawQuotaBar(_ rect: NSRect, percent: CGFloat, accent: NSColor, label: String) {
    rounded(rect, rect.height / 2, fill: color(1, 1, 1, 0.12))
    rounded(NSRect(x: rect.minX, y: rect.minY, width: max(8, rect.width * percent), height: rect.height), rect.height / 2, fill: accent)
    text(label, x: rect.maxX - 54, y: rect.minY + 4, size: 14, weight: .heavy, color: .white, mono: true, maxWidth: 46)
}

func drawRow(_ rect: NSRect, initial: String, name: String, path: String, fiveHour: String?, weekly: String, reset: String, action: String, accent: NSColor, depleted: Bool = false) {
    rounded(rect, 20, fill: color(1, 1, 1, 0.075), stroke: accent.withAlphaComponent(0.82), lineWidth: 1.7)
    NSGradient(colors: [accent.withAlphaComponent(0.14), color(1, 1, 1, 0.02)])?.draw(in: rect, angle: 0)
    drawIcon(letter: initial, rect: NSRect(x: rect.minX + 18, y: rect.minY + 16, width: 54, height: 54), accent: accent)
    text(name, x: rect.minX + 88, y: rect.minY + 45, size: 20, weight: .bold, maxWidth: 220)
    text(path, x: rect.minX + 88, y: rect.minY + 20, size: 12, weight: .medium, color: color(1, 1, 1, 0.48), mono: true, maxWidth: 285)

    let buttonRect = NSRect(x: rect.maxX - 104, y: rect.minY + 27, width: 76, height: 34)
    let resetX = buttonRect.minX - 92
    let barWidth: CGFloat = 276
    let barX = resetX - barWidth - 14
    let labelX = barX - 42

    if let fiveHour {
        text("5H", x: labelX, y: rect.minY + 51, size: 14, weight: .heavy, color: color(0.28, 0.78, 1.00), maxWidth: 34)
        drawQuotaBar(NSRect(x: barX, y: rect.minY + 53, width: barWidth, height: 20), percent: depleted ? 0.04 : 0.84, accent: depleted ? color(0.92, 0.12, 0.20) : color(0.02, 0.82, 0.70), label: fiveHour)
        text(reset, x: resetX, y: rect.minY + 51, size: 15, weight: .bold, color: color(1, 1, 1, 0.70), mono: true, maxWidth: 74)
        text("1W", x: labelX, y: rect.minY + 21, size: 14, weight: .heavy, color: color(1.00, 0.72, 0.20), maxWidth: 34)
        drawQuotaBar(NSRect(x: barX, y: rect.minY + 23, width: barWidth, height: 20), percent: 0.58, accent: color(0.52, 0.84, 0.30), label: weekly)
    } else {
        text("1W", x: labelX, y: rect.minY + 36, size: 14, weight: .heavy, color: color(1.00, 0.72, 0.20), maxWidth: 34)
        drawQuotaBar(NSRect(x: barX, y: rect.minY + 38, width: barWidth, height: 20), percent: 0.78, accent: color(0.10, 0.82, 0.68), label: weekly)
        text(reset, x: resetX, y: rect.minY + 36, size: 15, weight: .bold, color: color(1, 1, 1, 0.70), mono: true, maxWidth: 74)
    }

    let buttonAccent = depleted ? color(1.00, 0.16, 0.20) : color(0.12, 0.86, 0.66)
    rounded(buttonRect, 17, fill: buttonAccent.withAlphaComponent(0.24), stroke: buttonAccent.withAlphaComponent(0.52))
    text(action, x: buttonRect.minX + 18, y: buttonRect.minY + 9, size: 14, weight: .bold, color: depleted ? buttonAccent : .white, maxWidth: 46)
}

func render(_ copy: Copy) throws {
    let size = NSSize(width: 1600, height: 980)
    let image = NSImage(size: size)
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    NSGradient(colors: [color(0.02, 0.08, 0.11), color(0.05, 0.06, 0.08), color(0.10, 0.05, 0.05)])?.draw(in: NSRect(origin: .zero, size: size), angle: -28)
    let window = NSRect(x: 80, y: 70, width: 1440, height: 840)
    rounded(window, 30, fill: color(0.04, 0.05, 0.07, 0.88), stroke: color(1, 1, 1, 0.18), lineWidth: 1.2)
    NSGradient(colors: [color(0.00, 0.30, 0.28, 0.56), color(0.06, 0.14, 0.20, 0.74)])?.draw(in: window, angle: -22)

    for (index, dot) in [color(1, 0.35, 0.35), color(1, 0.78, 0.12), color(0.18, 0.82, 0.32)].enumerated() {
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: window.minX + 24 + CGFloat(index) * 28, y: window.maxY - 36, width: 16, height: 16)).fill()
    }
    text(copy.appTitle, x: window.minX + 116, y: window.maxY - 38, size: 16, weight: .semibold, color: color(1, 1, 1, 0.70), maxWidth: 220)

    let sidebar = NSRect(x: window.minX, y: window.minY, width: 360, height: window.height)
    NSColor.black.withAlphaComponent(0.28).setFill()
    sidebar.fill()
    NSGradient(colors: [color(0.00, 0.27, 0.28, 0.44), color(0.03, 0.04, 0.07, 0.42)])?.draw(in: sidebar, angle: -30)

    let iconRect = NSRect(x: sidebar.minX + 44, y: sidebar.maxY - 174, width: 112, height: 112)
    rounded(iconRect, 28, fill: color(1, 1, 1, 0.07), stroke: color(1, 1, 1, 0.14))
    if let icon = NSImage(contentsOf: root.appendingPathComponent("macos/CodexAccounts/AppIcon.png")) {
        icon.draw(in: iconRect.insetBy(dx: 16, dy: 16))
    }
    rounded(NSRect(x: sidebar.minX + 184, y: sidebar.maxY - 146, width: 138, height: 54), 18, fill: color(0.10, 0.30, 0.42, 0.70), stroke: color(0.22, 0.66, 1.00, 0.35))
    text(copy.flag, x: sidebar.minX + 202, y: sidebar.maxY - 128, size: 15, weight: .bold, maxWidth: 22)
    text(copy.language, x: sidebar.minX + 230, y: sidebar.maxY - 122, size: 14, weight: .heavy, maxWidth: 72)
    text(copy.code == "en" ? "Language" : "語言", x: sidebar.minX + 230, y: sidebar.maxY - 140, size: 10, weight: .semibold, color: color(1, 1, 1, 0.54), maxWidth: 80)

    text(copy.appTitle, x: sidebar.minX + 44, y: sidebar.maxY - 220, size: 34, weight: .semibold, maxWidth: 280)
    text(copy.subtitle, x: sidebar.minX + 44, y: sidebar.maxY - 260, size: 16, weight: .medium, color: color(1, 1, 1, 0.62), maxWidth: 280)

    let panel = NSRect(x: sidebar.minX + 44, y: sidebar.minY + 82, width: 280, height: 500)
    rounded(panel, 20, fill: color(0.08, 0.09, 0.12, 0.72), stroke: color(1, 1, 1, 0.12))
    text(copy.today, x: panel.minX + 18, y: panel.maxY - 38, size: 15, weight: .bold, color: color(1, 1, 1, 0.70), maxWidth: 120)
    text("0H22M", x: panel.maxX - 76, y: panel.maxY - 38, size: 14, weight: .heavy, color: color(0.30, 0.86, 1.00), mono: true, maxWidth: 60)
    rounded(NSRect(x: panel.minX + 18, y: panel.maxY - 62, width: panel.width - 36, height: 8), 4, fill: color(1, 1, 1, 0.12))
    rounded(NSRect(x: panel.minX + 18, y: panel.maxY - 62, width: 10, height: 8), 4, fill: color(0.00, 0.90, 0.72))
    drawDisclosure(NSRect(x: panel.minX + 18, y: panel.maxY - 126, width: panel.width - 36, height: 54), title: copy.automation, subtitle: copy.syncSubtitle, symbol: "⚡", accent: color(0.28, 0.70, 1.00), expanded: true)
    text(copy.refresh, x: panel.minX + 24, y: panel.maxY - 164, size: 14, weight: .bold, maxWidth: 160)
    drawSwitch(NSRect(x: panel.maxX - 84, y: panel.maxY - 170, width: 60, height: 30), on: true)
    text(copy.autoSync, x: panel.minX + 24, y: panel.maxY - 204, size: 14, weight: .bold, maxWidth: 160)
    drawSwitch(NSRect(x: panel.maxX - 84, y: panel.maxY - 210, width: 60, height: 30), on: true)
    rounded(NSRect(x: panel.minX + 24, y: panel.maxY - 256, width: 118, height: 34), 10, fill: color(1, 1, 1, 0.12))
    text(copy.syncNow, x: panel.minX + 48, y: panel.maxY - 246, size: 13, weight: .bold, maxWidth: 80)
    rounded(NSRect(x: panel.minX + 154, y: panel.maxY - 256, width: 118, height: 34), 10, fill: color(1, 1, 1, 0.12))
    text(copy.shareAll, x: panel.minX + 178, y: panel.maxY - 246, size: 13, weight: .bold, maxWidth: 80)
    drawDisclosure(NSRect(x: panel.minX + 18, y: panel.maxY - 316, width: panel.width - 36, height: 54), title: copy.systemTools, subtitle: copy.toolsSubtitle, symbol: "☰", accent: color(1, 1, 1, 0.55))
    drawDisclosure(NSRect(x: panel.minX + 18, y: panel.maxY - 374, width: panel.width - 36, height: 54), title: copy.mobile, subtitle: copy.mobileSubtitle, symbol: "▣", accent: color(1.00, 0.55, 0.12))
    drawDisclosure(NSRect(x: panel.minX + 18, y: panel.maxY - 432, width: panel.width - 36, height: 54), title: copy.appearance, subtitle: copy.theme, symbol: "●", accent: color(0.22, 0.74, 1.00))
    drawDisclosure(NSRect(x: panel.minX + 18, y: panel.maxY - 490, width: panel.width - 36, height: 54), title: copy.updates, subtitle: copy.updateSubtitle, symbol: "✓", accent: color(0.00, 0.90, 0.78))

    let mainX = sidebar.maxX + 58
    text(copy.profilesTitle, x: mainX, y: window.maxY - 142, size: 38, weight: .semibold, maxWidth: 260)
    text(copy.headerLine1, x: mainX, y: window.maxY - 182, size: 16, weight: .medium, color: color(1, 1, 1, 0.62), maxWidth: 430)
    text(copy.headerLine2, x: mainX, y: window.maxY - 206, size: 16, weight: .medium, color: color(1, 1, 1, 0.62), maxWidth: 430)
    for (index, symbol) in ["✓", "◌", "↺"].enumerated() {
        rounded(NSRect(x: mainX + 486 + CGFloat(index) * 54, y: window.maxY - 182, width: 48, height: 48), 16, fill: color(1, 1, 1, 0.10), stroke: color(1, 1, 1, 0.14))
        text(symbol, x: mainX + 504 + CGFloat(index) * 54, y: window.maxY - 168, size: 22, weight: .bold, color: index == 0 ? color(0.15, 0.90, 0.58) : color(1.0, 0.62, 0.12), maxWidth: 22)
    }
    for (index, symbol) in ["+", "↻", "▭", "⨯"].enumerated() {
        let accent = [color(0.30, 0.78, 1.00), color(0.22, 0.92, 0.74), color(1, 0.74, 0.24), color(1, 0.20, 0.18)][index]
        rounded(NSRect(x: window.maxX - 272 + CGFloat(index) * 60, y: window.maxY - 182, width: 48, height: 48), 16, fill: accent.withAlphaComponent(0.12), stroke: accent.withAlphaComponent(0.35))
        text(symbol, x: window.maxX - 254 + CGFloat(index) * 60, y: window.maxY - 168, size: 22, weight: .bold, color: accent, maxWidth: 24)
    }

    rounded(NSRect(x: mainX, y: window.maxY - 258, width: 128, height: 34), 17, fill: color(0.08, 0.38, 0.30, 0.68), stroke: color(0.12, 0.92, 0.62, 0.42))
    text("✓  \(copy.signedIn)", x: mainX + 18, y: window.maxY - 249, size: 15, weight: .bold, color: color(0.18, 0.95, 0.62), maxWidth: 100)
    rounded(NSRect(x: mainX + 146, y: window.maxY - 244, width: window.maxX - mainX - 250, height: 2), 1, fill: color(0.18, 0.95, 0.62, 0.35))

    let rowWidth = window.maxX - mainX - 96
    let rows: [(String, String, String, String?, String, String, NSColor, Bool)] = [
        ("G", "demo-pro", "/Users/demo/.codex-accounts/demo-pro", "98%", "72%", "18:42", color(1.00, 0.72, 0.08), false),
        ("R", "research", "/Users/demo/.codex-accounts/research", "100%", "24%", "19:01", color(0.12, 0.74, 1.00), false),
        ("C", "client", "/Users/demo/.codex-accounts/client", nil, "81%", "05/13", color(0.06, 0.84, 0.72), false),
        ("T", "trial", "/Users/demo/.codex-accounts/trial", "0%", "68%", "14:01", color(1.00, 0.20, 0.20), true),
        ("P", "personal", "/Users/demo/.codex-accounts/personal", nil, "88%", "05/16", color(0.22, 0.74, 1.00), false)
    ]
    for (index, row) in rows.enumerated() {
        let y = window.maxY - 352 - CGFloat(index) * 96
        drawRow(
            NSRect(x: mainX, y: y, width: rowWidth, height: 78),
            initial: row.0,
            name: row.1,
            path: row.2,
            fiveHour: row.3,
            weekly: row.4,
            reset: row.5,
            action: row.7 ? copy.logIn : copy.open,
            accent: row.6,
            depleted: row.7
        )
    }

    text(copy.updateChannel, x: window.maxX - 360, y: window.minY + 48, size: 16, weight: .semibold, color: color(0.00, 0.90, 0.78), maxWidth: 260)
    text("Demo profiles · /Users/demo paths only", x: window.minX + 42, y: window.minY + 48, size: 14, weight: .medium, color: color(1, 1, 1, 0.42), maxWidth: 360)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
        throw NSError(domain: "MultilingualScreenshots", code: 1)
    }

    let outputURL = outputDirectory.appendingPathComponent(copy.outputName)
    try png.write(to: outputURL)
    print(outputURL.path)
}

for copy in copies {
    try render(copy)
}
