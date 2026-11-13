import AppKit
import ApplicationServices
import Charts
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hid
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private let codexAccountsWorkQueue = DispatchQueue(label: "local.codex.accounts.work", qos: .utility)
private let codexAccountsLaunchQueue = DispatchQueue(label: "local.codex.accounts.launch", qos: .userInitiated)
private let profileRefreshPayloadSeparator = "\u{1E}"

private func supportedCodexGUIExecutablePaths() -> [String] {
    let fileManager = FileManager.default
    let configuredValue = ProcessInfo.processInfo.environment["CODEX_APP"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let configuredPath = configuredValue?.isEmpty == false ? configuredValue : nil
    let applicationPaths = [
        "/Applications/Codex.app",
        "/Applications/ChatGPT.app",
        NSHomeDirectory() + "/Applications/Codex.app",
        NSHomeDirectory() + "/Applications/ChatGPT.app"
    ]
    let candidates = configuredPath.map { [$0] } ?? applicationPaths
    var executablePaths: [String] = []
    var seenPaths = Set<String>()

    for rawPath in candidates {
        let appPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let bundle = Bundle(path: appPath)
        let isConfiguredPath = configuredPath != nil
        let hasBundledCodex = fileManager.isExecutableFile(
            atPath: appPath + "/Contents/Resources/codex"
        )
        guard bundle?.bundleIdentifier != "com.openai.chat" else {
            continue
        }
        guard isConfiguredPath || bundle?.bundleIdentifier == "com.openai.codex" || hasBundledCodex else {
            continue
        }

        let conventionalPaths = ["ChatGPT", "Codex"].map {
            appPath + "/Contents/MacOS/" + $0
        }
        for executablePath in ([bundle?.executablePath].compactMap { $0 } + conventionalPaths)
            where fileManager.isExecutableFile(atPath: executablePath) && seenPaths.insert(executablePath).inserted {
            executablePaths.append(executablePath)
        }
    }

    return executablePaths
}

private final class ProcessFinishState {
    private let lock = NSLock()
    private var finished = false

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        let value = finished
        lock.unlock()
        return value
    }
}

private final class ProfileIconImageCache {
    static let shared = ProfileIconImageCache()

    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func image(for key: String, load: () -> NSImage?) -> NSImage? {
        lock.lock()
        if let image = images[key] {
            lock.unlock()
            return image
        }
        lock.unlock()

        guard let image = load() else { return nil }

        lock.lock()
        images[key] = image
        lock.unlock()
        return image
    }
}

struct CodexProfile: Identifiable {
    let id: String
    let displayName: String
    let home: String
    let authStatus: String
    let authMode: String
    let lastRefresh: String
    let quota: String
    let reset: String
    let resetCredits: String

    init(
        id: String,
        displayName: String,
        home: String,
        authStatus: String,
        authMode: String,
        lastRefresh: String,
        quota: String,
        reset: String,
        resetCredits: String = "unknown"
    ) {
        self.id = id
        self.displayName = displayName
        self.home = home
        self.authStatus = authStatus
        self.authMode = authMode
        self.lastRefresh = lastRefresh
        self.quota = quota
        self.reset = reset
        self.resetCredits = resetCredits
    }
}

private enum ProfileHistoryMode {
    case shared
    case privateOnly
}

private struct ExportableThread: Identifiable {
    let id: String
    let title: String
    let updatedAt: String
    let cwd: String
    let sizeBytes: Int64
}

private final class FlippedAccessoryView: NSView {
    override var isFlipped: Bool { true }
}

private final class ExportThreadTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let threads: [ExportableThread]
    private var selectedIDs: Set<String>

    init(threads: [ExportableThread]) {
        self.threads = threads
        self.selectedIDs = Set(threads.first.map { [$0.id] } ?? [])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        threads.count
    }

    func selectedThreads() -> [ExportableThread] {
        threads.filter { selectedIDs.contains($0.id) }
    }

    func isSelected(_ thread: ExportableThread) -> Bool {
        selectedIDs.contains(thread.id)
    }

    @objc func toggleSelection(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < threads.count else { return }
        let thread = threads[sender.tag]
        if sender.state == .on {
            selectedIDs.insert(thread.id)
        } else {
            selectedIDs.remove(thread.id)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < threads.count, let tableColumn else { return nil }
        let thread = threads[row]
        if tableColumn.identifier.rawValue == "selected" {
            let identifier = NSUserInterfaceItemIdentifier("ExportThreadCell-selected")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
                let newCell = NSTableCellView()
                newCell.identifier = identifier
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSelection(_:)))
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                newCell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.centerXAnchor.constraint(equalTo: newCell.centerXAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
                ])
                return newCell
            }()
            if let checkbox = cell.subviews.compactMap({ $0 as? NSButton }).first {
                checkbox.target = self
                checkbox.action = #selector(toggleSelection(_:))
                checkbox.tag = row
                checkbox.state = selectedIDs.contains(thread.id) ? .on : .off
            }
            cell.toolTip = thread.title
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("ExportThreadCell-\(tableColumn.identifier.rawValue)")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let newCell = NSTableCellView()
            newCell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = NSFont.systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            newCell.addSubview(field)
            newCell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: newCell.centerYAnchor)
            ])
            return newCell
        }()

        let value: String
        switch tableColumn.identifier.rawValue {
        case "updated":
            value = formattedExportThreadDate(thread.updatedAt)
            cell.textField?.alignment = .left
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.lineBreakMode = .byTruncatingTail
        case "size":
            value = humanFileSize(thread.sizeBytes)
            cell.textField?.alignment = .right
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.lineBreakMode = .byTruncatingTail
        case "cwd":
            value = thread.cwd
            cell.textField?.alignment = .left
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.lineBreakMode = .byTruncatingMiddle
        default:
            value = thread.title.isEmpty ? "Untitled" : thread.title
            cell.textField?.alignment = .left
            cell.textField?.textColor = .labelColor
            cell.textField?.lineBreakMode = .byTruncatingTail
        }
        cell.textField?.stringValue = value
        cell.toolTip = "\(thread.title)\n\(formattedExportThreadDate(thread.updatedAt))\n\(thread.cwd)"
        return cell
    }
}

private struct QuotaWindow: Identifiable {
    let id: String
    let labelZH: String
    let labelEN: String
    let percent: Int?
    let reset: String?
}

private struct ResetCreditSummary {
    let count: Int
    let expiries: [String]
}

private struct QuotaPoolRouteDecision {
    let requested: CodexProfile
    let target: CodexProfile
    let didSwitch: Bool
}

private struct LocalExternalProviderDetails {
    let model: String
    let providerLabel: String
}

private struct AppThemeOption: Identifiable {
    let id: String
    let zhTitle: String
    let primary: Color
    let secondary: Color
    let warm: Color
    let background: [Color]
    let mainTint: Color
    let sidebarTint: Color
    let rowTint: Color
}

private struct DailyUsageRecord: Codable {
    var dayKey: String
    var seconds: TimeInterval
}

private final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, enabled: Bool = true, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(runCallback), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runCallback() {
        callback()
    }
}

private enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHK = "zh-HK"
    case zhHant = "zh-Hant"
    case zhCN = "zh-CN"
    case en = "en"
    case ja = "ja"

    var id: String { rawValue }

    /// What a first launch starts in: the closest match to the Mac's own language, English when there is none.
    static var systemDefault: AppLanguage {
        let preferred = (Locale.preferredLanguages.first ?? "en").lowercased()
        if preferred.hasPrefix("yue") || preferred.hasSuffix("-hk") || preferred.hasSuffix("-mo") { return .zhHK }
        if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") { return .zhHant }
        if preferred.hasPrefix("zh") { return .zhCN }
        if preferred.hasPrefix("ja") { return .ja }
        return .en
    }

    static func normalized(_ rawValue: String?) -> AppLanguage {
        switch rawValue {
        case "zh", "yue", "yue-HK", "zh-HK", "zh-Hant-HK":
            return .zhHK
        case "zh-Hant", "zh-TW", "zh-Hant-TW":
            return .zhHant
        case "zh-CN", "zh-Hans", "zh-Hans-CN":
            return .zhCN
        case "en", "en-US":
            return .en
        case "ja", "ja-JP":
            return .ja
        default:
            return .zhHK
        }
    }

    var flag: String {
        switch self {
        case .zhHK: return "🇭🇰"
        case .zhHant: return "繁"
        case .zhCN: return "🇨🇳"
        case .en: return "🇺🇸"
        case .ja: return "🇯🇵"
        }
    }

    var shortTitle: String {
        switch self {
        case .zhHK: return "廣東話"
        case .zhHant: return "繁體"
        case .zhCN: return "简体"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    var displayTitle: String {
        switch self {
        case .zhHK: return "廣東話・香港"
        case .zhHant: return "繁體中文"
        case .zhCN: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    var subtitle: String {
        switch self {
        case .zhHK: return "香港粵語"
        case .zhHant: return "書面繁中"
        case .zhCN: return "简体界面"
        case .en: return "US English"
        case .ja: return "日本語 UI"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .zhHK: return "zh_Hant_HK"
        case .zhHant: return "zh_Hant"
        case .zhCN: return "zh_Hans_CN"
        case .en: return "en_US_POSIX"
        case .ja: return "ja_JP"
        }
    }

    var accent: Color {
        switch self {
        case .zhHK: return Color(red: 0.10, green: 0.56, blue: 1.00)
        case .zhHant: return Color(red: 0.10, green: 0.86, blue: 0.66)
        case .zhCN: return Color(red: 1.00, green: 0.34, blue: 0.28)
        case .en: return Color(red: 0.58, green: 0.42, blue: 1.00)
        case .ja: return Color(red: 1.00, green: 0.45, blue: 0.68)
        }
    }
}

private func localizedText(_ zhHK: String, _ en: String, language rawLanguage: String?) -> String {
    AppTextLocalizer.localized(zhHK, en, language: AppLanguage.normalized(rawLanguage))
}

private enum AppTextLocalizer {
    static func localized(_ zhHK: String, _ en: String, language: AppLanguage) -> String {
        switch language {
        case .en:
            return en
        case .zhHK:
            return cantoneseHongKong(zhHK)
        case .zhHant:
            return writtenTraditional(zhHK)
        case .zhCN:
            return simplifiedChinese(writtenTraditional(zhHK))
        case .ja:
            return japanese(zhHK, en)
        }
    }

    private static func cantoneseHongKong(_ text: String) -> String {
        applyingReplacements([
            ("简体中文", "簡體中文"),
            ("简体", "簡體"),
            ("账号", "帳戶"),
            ("账户", "帳戶"),
            ("登录", "登入"),
            ("退出登录", "登出"),
            ("窗口", "視窗"),
            ("文件夹", "資料夾"),
            ("本机", "本機"),
            ("记录", "紀錄"),
            ("记忆", "記憶"),
            ("对话", "對話"),
            ("开启", "開啟"),
            ("关闭", "關閉"),
            ("刷新", "重新整理"),
            ("共享", "共享"),
            ("等待恢复", "等待恢復"),
            ("添加", "新增"),
            ("创建", "建立"),
            ("选择", "選擇"),
            ("显示", "顯示"),
            ("删除", "刪除"),
            ("切换", "切換"),
            ("清洁模式", "清潔模式"),
            ("键盘", "鍵盤"),
            ("锁", "鎖"),
            ("无法", "無法"),
            ("错误", "錯誤"),
            ("需要登录", "要登入"),
            ("未登录", "未登入"),
            ("已登录", "已登入")
        ], to: text)
    }

    private static func writtenTraditional(_ text: String) -> String {
        var output = applyingReplacements([
            ("登入", "登入"),
            ("本機", "本機"),
            ("紀錄", "記錄"),
            ("視窗", "視窗"),
            ("資料夾", "資料夾"),
            ("用量", "用量"),
            ("重設", "重置"),
            ("共享", "共享"),
            ("立即", "立即"),
            ("防睡眠", "防止睡眠"),
            ("選擇要開邊個 Codex 登入視窗。", "選擇要開啟的 Codex 登入視窗。"),
            ("喺呢部 Mac", "在這台 Mac"),
            ("喺 Finder 顯示", "在 Finder 顯示"),
            ("喺長任務期間", "在長任務期間"),
            ("邊個", "哪個"),
            ("邊度", "哪裡"),
            ("邊啲", "哪些"),
            ("搵唔到", "找不到"),
            ("搵", "找"),
            ("無剔選", "未勾選"),
            ("剔選", "勾選"),
            ("無勾選", "未勾選"),
            ("先可以", "才可以"),
            ("撳返呢粒掣", "按此按鈕"),
            ("呢粒掣", "此按鈕"),
            ("掣", "按鈕"),
            ("傳俾", "傳給"),
            ("另一部機", "另一台電腦"),
            ("條可導出對話", "則可匯出的對話"),
            ("條新對話", "則新對話"),
            ("一條對話", "一則對話"),
            ("條對話", "則對話"),
            ("包入面", "包裡面"),
            ("入面", "裡面"),
            ("普通打開", "一般開啟"),
            ("正在同步對話同記憶", "正在同步對話與記憶"),
            ("同步對話同記憶", "同步對話與記憶"),
            ("對話同記憶已同步", "對話與記憶已同步"),
            ("已同全部 profile 共享", "已與全部 profile 共享"),
            ("而家", "現在"),
            ("咁樣", "這樣"),
            ("咁", "這樣"),
            ("撳", "按"),
            ("唔", "不"),
            ("咗", "了"),
            ("嘅", "的"),
            ("嗰個", "那個"),
            ("嗰", "那"),
            ("呢個", "這個"),
            ("呢部", "這台"),
            ("呢", "這"),
            ("冇", "沒有"),
            ("俾", "給"),
            ("要登入", "需要登入"),
            ("打開", "開啟"),
            ("刪除 Profile", "刪除 Profile"),
            ("好", "好")
        ], to: text)
        if output == "已開" { return "已開啟" }
        if output == "已關" { return "已關閉" }
        output = output
            .replacingOccurrences(of: "已開啟啟", with: "已開啟")
            .replacingOccurrences(of: "已關閉閉", with: "已關閉")
        return output
    }

    private static func japanese(_ zhHK: String, _ en: String) -> String {
        let exact: [String: String] = [
            "帳戶": "アカウント",
            "選擇要開邊個 Codex 登入視窗。": "開く Codex ログイン画面を選択します。",
            "登入狀態只會手動更新。": "ログイン状態は手動で更新されます。",
            "語言": "言語",
            "主題": "テーマ",
            "外觀": "外観",
            "更新": "更新",
            "已登入": "ログイン済み",
            "未登入": "未ログイン",
            "等待恢復": "回復待ち",
            "API": "API",
            "用量": "使用量",
            "今日使用": "今日の使用量",
            "自動化": "自動化",
            "功能說明": "機能説明",
            "每分鐘重新整理": "毎分更新",
            "每分鐘同步對話記憶": "毎分会話メモリを同期",
            "每 10 分鐘同步": "10分ごとに同期",
            "對話同步已開啟": "会話履歴の同期はオンです",
            "對話同步已暫停": "会話履歴の同期は一時停止中です",
            "整理側欄": "サイドバーを整理",
            "整理中": "整理中",
            "立即同步": "今すぐ同期",
            "共享全部": "すべて共有",
            "系統工具": "システムツール",
            "防睡眠": "スリープ防止",
            "電腦清潔": "キーボード清掃",
            "清理大對話": "大きい会話を整理",
            "已關": "オフ",
            "已開": "オン",
            "打開": "開く",
            "取消": "キャンセル",
            "繼續": "続行",
            "好": "OK",
            "選擇儲存位置": "保存先を選択",
            "導出對話包": "会話パッケージを書き出す",
            "導入對話包": "会話パッケージを読み込む",
            "包含已引用嘅生成圖片": "参照済みの生成画像を含める",
            "包含工作區入面被引用嘅檔案": "ワークスペース内の参照ファイルを含める",
            "語言已切換：": "言語を切り替えました：",
            "重設券": "リセット券",
            "張可用": "枚利用可能",
            "最早": "最短",
            "剩": "残り",
            "日": "日"
        ]
        if let translated = exact[zhHK] {
            return translated
        }

        var output = en
        let phraseReplacements: [(String, String)] = [
            ("Codex Accounts", "Codex アカウント"),
            ("Codex Account", "Codex アカウント"),
            ("Language", "言語"),
            ("Account", "アカウント"),
            ("Accounts", "アカウント"),
            ("Logged in", "ログイン済み"),
            ("Not logged in", "未ログイン"),
            ("Waiting", "待機中"),
            ("Recovery", "回復"),
            ("Usage", "使用量"),
            ("Today", "今日"),
            ("Open", "開く"),
            ("Cancel", "キャンセル"),
            ("Continue", "続行"),
            ("Choose", "選択"),
            ("Folder", "フォルダ"),
            ("Refresh", "更新"),
            ("Sync", "同期"),
            ("Share", "共有"),
            ("Update", "更新"),
            ("Theme", "テーマ"),
            ("Settings", "設定"),
            ("Clean Mode", "清掃モード"),
            ("Keep Awake", "スリープ防止"),
            ("Reset", "リセット"),
            ("Available", "利用可能"),
            ("Remaining", "残り"),
            ("Error", "エラー"),
            ("Failed", "失敗"),
            ("Disabled", "無効"),
            ("Enabled", "有効")
        ]
        output = applyingReplacements(phraseReplacements, to: output)
        return output
    }

    private static func applyingReplacements(_ replacements: [(String, String)], to text: String) -> String {
        var output = text
        for replacement in replacements {
            output = output.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
        return output
    }

    private static func simplifiedChinese(_ text: String) -> String {
        let phraseReplacements: [(String, String)] = [
            ("繁體中文", "简体中文"),
            ("帳號", "账号"),
            ("帳戶", "账户"),
            ("登入", "登录"),
            ("登出", "退出登录"),
            ("視窗", "窗口"),
            ("資料夾", "文件夹"),
            ("本機", "本机"),
            ("記錄", "记录"),
            ("紀錄", "记录"),
            ("記憶", "记忆"),
            ("對話", "对话"),
            ("防止睡眠", "防睡眠"),
            ("開啟", "开启"),
            ("關閉", "关闭"),
            ("重新整理", "刷新"),
            ("同步", "同步"),
            ("共用", "共享"),
            ("等待恢復", "等待恢复"),
            ("新增", "添加"),
            ("建立", "创建"),
            ("取消", "取消"),
            ("選擇", "选择"),
            ("顯示", "显示"),
            ("刪除", "删除"),
            ("切換", "切换"),
            ("清潔模式", "清洁模式"),
            ("鍵盤", "键盘"),
            ("鎖", "锁"),
            ("無法", "无法"),
            ("錯誤", "错误"),
            ("需要登入", "需要登录"),
            ("未登入", "未登录"),
            ("已登入", "已登录")
        ]
        var output = text
        for replacement in phraseReplacements {
            output = output.replacingOccurrences(of: replacement.0, with: replacement.1)
        }

        let characterMap: [Character: Character] = [
            "帳": "账", "戶": "户", "體": "体", "簡": "简", "開": "开", "關": "关",
            "機": "机", "記": "记", "錄": "录", "視": "视", "資": "资", "夾": "夹",
            "選": "选", "擇": "择", "預": "预", "設": "设", "輸": "输", "顯": "显",
            "點": "点", "擊": "击", "對": "对", "話": "话", "歷": "历",
            "語": "语", "換": "换", "區": "区", "類": "类", "標": "标",
            "導": "导", "線": "线", "個": "个", "這": "这", "裡": "里", "邊": "边",
            "應": "应", "啟": "启", "動": "动", "刪": "删", "除": "除", "復": "复",
            "務": "务", "長": "长", "間": "间", "員": "员", "數": "数", "據": "据",
            "檔": "档", "儲": "储", "與": "与", "無": "无", "錯": "错", "誤": "误",
            "綁": "绑", "認": "认", "證": "证", "權": "权", "限": "限", "彈": "弹",
            "潔": "洁", "鎖": "锁", "鍵": "键", "盤": "盘", "閉": "闭", "圖": "图",
            "庫": "库", "網": "网", "狀": "状", "態": "态", "掃": "扫",
            "遲": "迟", "瀏": "浏", "覽": "览", "遠": "远", "端": "端", "號": "号"
        ]
        output = String(output.map { characterMap[$0] ?? $0 })
        if output == "已开" { return "已开启" }
        if output == "已关" { return "已关闭" }
        return output
            .replacingOccurrences(of: "已开启启", with: "已开启")
            .replacingOccurrences(of: "已关闭闭", with: "已关闭")
    }
}

private func runProcess(
    executable: String,
    arguments: [String],
    input: Data? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval = 90
) -> (Int32, String) {
    let process = Process()
    let outputPipe = Pipe()
    let inputPipe = Pipe()
    let lock = NSLock()
    let finished = DispatchSemaphore(value: 0)
    let finishState = ProcessFinishState()
    let outputLimitBytes = 8 * 1024 * 1024
    var output = Data()

    func appendBoundedOutput(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if data.count >= outputLimitBytes {
            output = Data(data.suffix(outputLimitBytes))
            return
        }

        let overflow = output.count + data.count - outputLimitBytes
        if overflow > 0 {
            output.removeFirst(overflow)
        }
        output.append(data)
    }
    var timedOut = false

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    if let environment {
        process.environment = environment
    }
    if input != nil {
        process.standardInput = inputPipe
    }

    process.terminationHandler = { _ in
        finishState.markFinished()
        finished.signal()
    }

    outputPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        appendBoundedOutput(data)
    }

    do {
        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(input)
            inputPipe.fileHandleForWriting.closeFile()
        }
    } catch {
        process.terminationHandler = nil
        outputPipe.fileHandleForReading.readabilityHandler = nil
        return (127, error.localizedDescription)
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        signalChildProcesses(of: process, signal: "TERM")
        process.terminate()
        if finished.wait(timeout: .now() + 1.5) == .timedOut {
            signalChildProcesses(of: process, signal: "KILL")
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1.0)
        }
    }

    let processExited = finishState.isFinished || !process.isRunning

    process.terminationHandler = nil
    outputPipe.fileHandleForReading.readabilityHandler = nil
    if processExited {
        let remaining = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty {
            lock.lock()
    appendBoundedOutput(remaining)
            lock.unlock()
        }
    }

    lock.lock()
    let text = String(data: output, encoding: .utf8) ?? ""
    lock.unlock()

    if timedOut {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "Timed out after \(Int(timeout))s."
        return (124, message.isEmpty ? suffix : "\(message)\n\(suffix)")
    }
    return (process.terminationStatus, text)
}

private func signalChildProcesses(of process: Process, signal: String) {
    guard process.processIdentifier > 0 else { return }

    let killer = Process()
    killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    killer.arguments = ["-\(signal)", "-P", "\(process.processIdentifier)"]
    killer.standardOutput = FileHandle.nullDevice
    killer.standardError = FileHandle.nullDevice

    do {
        try killer.run()
        killer.waitUntilExit()
    } catch {
        return
    }
}

private func runDetachedProcess(
    executable: String,
    arguments: [String],
    environment: [String: String]? = nil
) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
        process.environment = environment
    }
    if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
        process.standardOutput = nullOutput
        process.standardError = nullOutput
    }

    do {
        try process.run()
        return (0, "")
    } catch {
        return (127, error.localizedDescription)
    }
}

private struct WindowContentSizeReader: NSViewRepresentable {
    @Binding var size: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(size: $size)
    }

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onSizeChange = { newSize in
            context.coordinator.update(newSize)
        }
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onSizeChange = { newSize in
            context.coordinator.update(newSize)
        }
        nsView.reportSize()
    }

    final class Coordinator {
        private var size: Binding<CGSize>

        init(size: Binding<CGSize>) {
            self.size = size
        }

        func update(_ newSize: CGSize) {
            guard newSize.width > 1, newSize.height > 1 else { return }
            let oldSize = size.wrappedValue
            guard abs(oldSize.width - newSize.width) > 0.5 || abs(oldSize.height - newSize.height) > 0.5 else { return }
            size.wrappedValue = newSize
        }
    }

    final class ReportingView: NSView {
        var onSizeChange: ((CGSize) -> Void)?
        private var frameObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeContentViewFrame()
            reportSize()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportSize()
        }

        func reportSize() {
            let measuredSize = window?.contentView?.bounds.size ?? bounds.size
            DispatchQueue.main.async { [weak self] in
                self?.onSizeChange?(measuredSize)
            }
        }

        private func observeContentViewFrame() {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
                self.frameObserver = nil
            }

            guard let contentView = window?.contentView else { return }
            contentView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in
                self?.reportSize()
            }
        }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.90
    var hoverScale: CGFloat = 1.035
    var glow: Color = .white
    var glowOpacity: Double = 0.15

    func makeBody(configuration: Configuration) -> some View {
        PressScaleButtonBody(
            configuration: configuration,
            scale: scale,
            hoverScale: hoverScale,
            glow: glow,
            glowOpacity: glowOpacity
        )
    }
}

private struct PressScaleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let scale: CGFloat
    let hoverScale: CGFloat
    let glow: Color
    let glowOpacity: Double

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : (isHovering ? hoverScale : 1))
            .brightness(configuration.isPressed ? 0.065 : (isHovering ? 0.035 : 0))
            .shadow(color: glow.opacity(isHovering ? glowOpacity : 0), radius: isHovering ? 12 : 0, x: 0, y: isHovering ? 5 : 0)
            .animation(.interactiveSpring(response: 0.20, dampingFraction: 0.44, blendDuration: 0.06), value: configuration.isPressed)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct StatusRingOverlay: View {
    let active: Bool
    let color: Color
    let cornerRadius: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(color.opacity(active ? 0.98 : 0.88), lineWidth: lineWidth)
            .shadow(
                color: color.opacity(active ? 0.34 : 0.24),
                radius: active ? 9 : 7,
                x: 0,
                y: 0
            )
    }
}

private struct HoverLiftGlow: ViewModifier {
    let glow: Color
    var scale: CGFloat = 1.03
    var opacity: Double = 0.34
    var radius: CGFloat = 16
    var y: CGFloat = 5

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? scale : 1)
            .shadow(color: glow.opacity(isHovering ? opacity : 0), radius: isHovering ? radius : 0, x: 0, y: isHovering ? y : 0)
            .brightness(isHovering ? 0.035 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.74), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private struct HoverCloseCircleButton: View {
    let side: CGFloat
    let iconSize: CGFloat
    let isBusy: Bool
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    private let danger = Color(red: 1.00, green: 0.16, blue: 0.18)

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "xmark")
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.system(size: iconSize, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: side, height: side)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.82, hoverScale: 1.10, glow: isHovering ? danger : Color.white, glowOpacity: isHovering ? 0.42 : 0.18))
        .foregroundStyle(isHovering ? danger : Color.white.opacity(0.72))
        .background(isHovering ? danger.opacity(0.18) : Color.white.opacity(0.08))
        .overlay(
            Circle()
                .stroke(isHovering ? danger.opacity(0.58) : Color.white.opacity(0.0), lineWidth: 1)
        )
        .clipShape(Circle())
        .shadow(color: danger.opacity(isHovering ? 0.30 : 0), radius: isHovering ? 10 : 0, x: 0, y: isHovering ? 4 : 0)
        .animation(.spring(response: 0.20, dampingFraction: 0.72), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
    }
}

private struct LiquidSwitchStyle: ToggleStyle {
    let isOnColor: Color
    var isOffColor: Color = Color(red: 1.00, green: 0.12, blue: 0.20)
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let width = (54 * scale).rounded()
        let height = (30 * scale).rounded()
        let knob = (22 * scale).rounded()
        let activeColor = configuration.isOn ? isOnColor : isOffColor

        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: configuration.isOn
                                        ? [isOnColor.opacity(0.72), isOnColor.opacity(0.34)]
                                        : [isOffColor.opacity(0.42), isOffColor.opacity(0.16)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.36),
                                        activeColor.opacity(configuration.isOn ? 0.72 : 0.62),
                                        Color.black.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .padding(1)
                    )

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.98), Color.white.opacity(0.76)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: knob, height: knob)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.72), lineWidth: 0.8)
                    )
                    .shadow(color: activeColor.opacity(configuration.isOn ? 0.42 : 0.30), radius: 9, x: 0, y: 3)
                    .padding(.horizontal, (4 * scale).rounded())
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96))
    }
}

private func runCodexScript(
    _ scriptPath: String,
    _ arguments: [String],
    wait: Bool = false,
    timeout: TimeInterval = 90,
    environment: [String: String]? = nil
) -> (Int32, String) {
    let processArguments = [scriptPath] + arguments
    if wait {
        return runProcess(executable: "/bin/zsh", arguments: processArguments, environment: environment, timeout: timeout)
    }
    return runDetachedProcess(executable: "/bin/zsh", arguments: processArguments, environment: environment)
}

private func parsedExportableThreads(_ output: String) -> [ExportableThread] {
    output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else { return nil }
        return ExportableThread(
            id: parts[0],
            title: parts[1].isEmpty ? "Untitled" : parts[1],
            updatedAt: parts[2],
            cwd: parts[3],
            sizeBytes: Int64(parts[4]) ?? 0
        )
    }
}

private func formattedExportThreadDate(_ raw: String) -> String {
    guard !raw.isEmpty else { return "未知時間" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    fallback.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: raw) ?? fallback.date(from: raw) else {
        return raw
    }
    let output = DateFormatter()
    output.locale = Locale(identifier: "zh_Hant_HK")
    output.dateFormat = "M月d日 HH:mm"
    return output.string(from: date)
}

private func safePackageFileStem(title: String, threadID: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
    let cleaned = title.unicodeScalars.map { scalar -> Character in
        allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let compact = String(cleaned).split(separator: " ").joined(separator: " ")
    let prefix = String(compact.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
    let base = prefix.isEmpty ? "codex-conversation" : prefix
    return "\(base)-\(threadID.prefix(8))"
}

private func safePackageFileName(title: String, threadID: String) -> String {
    "\(safePackageFileStem(title: title, threadID: threadID)).codexshare"
}

private func uniquePackageFileURL(directory: URL, thread: ExportableThread, usedNames: inout Set<String>) -> URL {
    let stem = safePackageFileStem(title: thread.title, threadID: thread.id)
    var candidate = "\(stem).codexshare"
    var suffix = 2
    while usedNames.contains(candidate) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
        candidate = "\(stem)-\(suffix).codexshare"
        suffix += 1
    }
    usedNames.insert(candidate)
    return directory.appendingPathComponent(candidate)
}

private func humanFileSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 KB" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.includesActualByteCount = false
    return formatter.string(fromByteCount: bytes)
}

private func parsedCodexProfiles(
    accountsOutput: String,
    statusOutput: String,
    displayNames: [String: String]
) -> [CodexProfile] {
    var statusByName: [String: [String]] = [:]
    for line in statusOutput.split(separator: "\n") {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = parts.first {
            statusByName[name] = parts
        }
    }

    return accountsOutput
        .split(separator: "\n")
        .compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count >= 2 else { return nil }
            let name = parts[0]
            // OpenCodex mode was removed in 3.3.1; an old lab folder is never listed.
            guard name != "opencodex-lab" else { return nil }
            let fallbackDisplay = name == "account1" ? "Account 1" : (name == "account2" ? "Account 2" : name)
            let display = displayNames[name] ?? fallbackDisplay
            let status = statusByName[name] ?? []
            let profile = CodexProfile(
                id: name,
                displayName: display,
                home: parts[1],
                authStatus: status.count > 1 ? status[1] : "unknown",
                authMode: status.count > 2 ? status[2] : "unknown",
                lastRefresh: status.count > 3 ? status[3] : "unknown",
                quota: status.count > 4 ? status[4] : "unknown",
                reset: status.count > 5 ? status[5] : "unknown",
                resetCredits: status.count > 6 ? status[6] : "unknown"
            )
            return profileWithLocalExternalProviderFallback(profile)
        }
}

private func profileWithCachedUsageFallback(_ profile: CodexProfile, hasLocalTokens knownHasLocalTokens: Bool? = nil) -> CodexProfile {
    let externalProfile = profileWithLocalExternalProviderFallback(profile)
    guard externalProfile.authMode != "external" else {
        return externalProfile
    }

    let quota = profile.quota.trimmingCharacters(in: .whitespacesAndNewlines)
    guard profile.authStatus != "auth_invalid" else {
        return profile
    }
    let hasLocalTokens = knownHasLocalTokens ?? localAuthTokensExist(in: profile.home)
    guard profile.authStatus != "login_needed" || hasLocalTokens else {
        return profile
    }
    guard let cachedUsage = cachedUsage(for: profile.id) else {
        return profile
    }
    if cachedUsage.quota == "__auth_invalid__" {
        return CodexProfile(
            id: externalProfile.id,
            displayName: externalProfile.displayName,
            home: externalProfile.home,
            authStatus: "auth_invalid",
            authMode: externalProfile.authMode,
            lastRefresh: externalProfile.lastRefresh,
            quota: "unknown",
            reset: "unknown",
            resetCredits: "unknown"
        )
    }

    let reset = profile.reset.trimmingCharacters(in: .whitespacesAndNewlines)
    let shouldUseCachedUsage = usageFieldIsMissing(quota)
    let resolvedResetCredits = bestResetCredits(primary: profile.resetCredits, fallback: cachedUsage.resetCredits)
    guard shouldUseCachedUsage || resolvedResetCredits != profile.resetCredits else {
        return profile
    }

    return CodexProfile(
        id: profile.id,
        displayName: profile.displayName,
        home: profile.home,
        authStatus: hasLocalTokens ? "signed_in_local" : profile.authStatus,
        authMode: hasLocalTokens && profile.authMode == "unknown" ? "checking" : profile.authMode,
        lastRefresh: profile.lastRefresh,
        quota: shouldUseCachedUsage ? cachedUsage.quota : profile.quota,
        reset: shouldUseCachedUsage || usageFieldIsMissing(reset) ? cachedUsage.reset : profile.reset,
        resetCredits: resolvedResetCredits
    )
}

/// The account script's usage cache (USAGE_CACHE_ROOT in codex_multi_account.zsh). Keep the version in step
/// with the script, or the app falls back to an old folder full of stale numbers.
private let codexUsageCacheFolder = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/Codex Accounts/.usage-cache-v9")

private func cachedUsage(for profileID: String) -> (quota: String, reset: String, resetCredits: String)? {
    let cacheURL = codexUsageCacheFolder.appendingPathComponent("\(profileID).status")

    guard let text = try? String(contentsOf: cacheURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
        return nil
    }

    let parts = text.split(separator: "\t", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard parts.count >= 2, !parts[0].isEmpty, parts[0] != "unknown" else {
        return nil
    }

    return (
        parts[0],
        parts[1].isEmpty ? "unknown" : parts[1],
        parts.count > 2 && !parts[2].isEmpty ? parts[2] : "unknown"
    )
}

private func usageFieldIsMissing(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == "unknown" || trimmed == "none" || trimmed == "--"
}

private func resetCreditAvailableCount(_ raw: String) -> Int? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !usageFieldIsMissing(trimmed) else { return nil }
    let pieces = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let rawCount = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let digits = rawCount.prefix { $0.isNumber }
    return Int(String(digits))
}

private func resetCreditHasExpiryList(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let count = resetCreditAvailableCount(trimmed), count > 0 else { return false }
    let pieces = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard pieces.count > 1 else { return false }
    return pieces[1]
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .contains { !$0.isEmpty && $0 != "unknown" && $0 != "null" }
}

private func resetCreditCountNeedsExpiryBackfill(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let count = resetCreditAvailableCount(trimmed), count > 0 else { return false }
    return !resetCreditHasExpiryList(trimmed)
}

private func bestResetCredits(primary: String, fallback: String) -> String {
    let primaryTrimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)

    if resetCreditHasExpiryList(primaryTrimmed) {
        return primary
    }

    if resetCreditHasExpiryList(fallbackTrimmed) {
        let primaryCount = resetCreditAvailableCount(primaryTrimmed)
        let fallbackCount = resetCreditAvailableCount(fallbackTrimmed)
        if usageFieldIsMissing(primaryTrimmed)
            || primaryCount == nil
            || fallbackCount == nil
            || primaryCount == fallbackCount
            || resetCreditCountNeedsExpiryBackfill(primaryTrimmed) {
            return fallback
        }
    }

    if usageFieldIsMissing(primaryTrimmed), !usageFieldIsMissing(fallbackTrimmed) {
        return fallback
    }

    return primary
}

private func localAuthTokensExist(in home: String) -> Bool {
    let authURL = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: authURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = json["tokens"] as? [String: Any],
          let accessToken = tokens["access_token"] as? String,
          let refreshToken = tokens["refresh_token"] as? String
    else {
        return false
    }

    return !accessToken.isEmpty && !refreshToken.isEmpty
}

private func profileWithLocalExternalProviderFallback(_ profile: CodexProfile) -> CodexProfile {
    guard let details = localExternalProviderDetails(in: profile.home) else {
        return profile
    }

    return CodexProfile(
        id: profile.id,
        displayName: profile.displayName,
        home: profile.home,
        authStatus: "signed_in_local",
        authMode: "external",
        lastRefresh: profile.lastRefresh == "unknown" || profile.lastRefresh == "never" ? "api-key" : profile.lastRefresh,
        quota: "external",
        reset: "\(details.providerLabel):\(details.model)",
        resetCredits: "none"
    )
}

private func localExternalProviderDetails(in home: String) -> LocalExternalProviderDetails? {
    let configURL = URL(fileURLWithPath: home).appendingPathComponent("config.toml")
    guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
        return nil
    }

    let topLevel = topLevelTomlText(config)
    let normalizedHome = URL(fileURLWithPath: home).standardizedFileURL
    let ownershipMarker = URL(fileURLWithPath: home)
        .appendingPathComponent(".codex-accounts-opencodex-lab")
    let isManagedOpenCodexLab = normalizedHome.lastPathComponent == "opencodex-lab"
        && (try? String(contentsOf: ownershipMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) == "managed-by-codex-accounts-opencodex-lab-v1"
    if isManagedOpenCodexLab {
        return LocalExternalProviderDetails(model: "2.31.0", providerLabel: "opencodex")
    }

    guard isPrimaryCodexHome(home) else { return nil }
    guard tomlStringValue("model_provider", in: topLevel) == "ai_proxy" else {
        return nil
    }

    let model = tomlStringValue("model", in: topLevel) ?? "qwen3.7-plus"
    let label = config.localizedCaseInsensitiveContains("dashscope.aliyuncs.com") ? "aliyun" : "external"
    return LocalExternalProviderDetails(model: model, providerLabel: label)
}

private func isPrimaryCodexHome(_ home: String) -> Bool {
    let primary = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex")
        .standardizedFileURL
        .path
    return URL(fileURLWithPath: home).standardizedFileURL.path == primary
}

private func topLevelTomlText(_ text: String) -> String {
    var lines: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            break
        }
        lines.append(String(line))
    }
    return lines.joined(separator: "\n")
}

private func tomlStringValue(_ key: String, in text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=")
        else {
            continue
        }

        let candidateKey = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidateKey == key else { continue }

        var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment = value.firstIndex(of: "#") {
            value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if value.hasPrefix("\""), let closing = value.dropFirst().firstIndex(of: "\"") {
            return String(value[value.index(after: value.startIndex)..<closing])
        }
        return value.split(separator: " ").first.map(String.init)
    }

    return nil
}

private func collectLocalAuthTokenProfileIDs(in profiles: [CodexProfile]) -> Set<String> {
    Set(profiles.compactMap { profile in
        localAuthTokensExist(in: profile.home) ? profile.id : nil
    })
}

private func profilePayloadText(from profiles: [CodexProfile]) -> String {
    profiles.map { profile in
        [
            profile.id,
            profile.displayName,
            profile.home,
            profile.authStatus,
            profile.authMode,
            profile.lastRefresh,
            profile.quota,
            profile.reset,
            profile.resetCredits
        ].joined(separator: "\t")
    }.joined(separator: "\n")
}

private func promptForAccountName(title: String, message: String, defaultName: String? = nil) -> String? {
    let language = UserDefaults.standard.string(forKey: "language")
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: localizedText("繼續", "Continue", language: language))
    alert.addButton(withTitle: localizedText("取消", "Cancel", language: language))

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
    field.placeholderString = defaultName ?? "account3"
    if let defaultName {
        field.stringValue = defaultName
    }
    alert.accessoryView = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? defaultName : name
}

private func alertMessage(_ title: String, _ message: String) {
    let language = UserDefaults.standard.string(forKey: "language")
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: localizedText("好", "OK", language: language))
    alert.runModal()
}

extension Notification.Name {
    static let keepAwakeStateChanged = Notification.Name("CodexAccountsKeepAwakeStateChanged")
    static let keyboardCleanStateChanged = Notification.Name("CodexAccountsKeyboardCleanStateChanged")
    static let updateStateChanged = Notification.Name("CodexAccountsUpdateStateChanged")
}

private struct HIDKeyMapping: Codable, Equatable {
    let src: UInt64
    let dst: UInt64
}

final class HIDMediaKeyBlocker {
    private let activeDefaultsKey = "keyboardCleanHIDMappingActive"
    private let previousDefaultsKey = "keyboardCleanPreviousHIDMapping"
    private let noEventUsage: UInt64 = 0x0007_0000_0000

    private let blockedUsages: [UInt64] = [
        0x0007_0000_003A, // F1 / brightness down on Apple keyboards
        0x0007_0000_003B, // F2 / brightness up on Apple keyboards
        0x0007_0000_0043, // F10 / mute on Apple keyboards
        0x0007_0000_0044, // F11 / volume down on Apple keyboards
        0x0007_0000_0045, // F12 / volume up on Apple keyboards
        0x0007_0000_0066, // keyboard power usage, when exposed as HID
        0x000C_0000_0030, // consumer power
        0x000C_0000_006F, // display brightness increment
        0x000C_0000_0070, // display brightness decrement
        0x000C_0000_0079, // keyboard illumination up
        0x000C_0000_007A, // keyboard illumination down
        0x000C_0000_00B0, // play
        0x000C_0000_00B1, // pause
        0x000C_0000_00B3, // fast forward
        0x000C_0000_00B4, // rewind
        0x000C_0000_00B5, // scan next track
        0x000C_0000_00B6, // scan previous track
        0x000C_0000_00B7, // stop
        0x000C_0000_00CD, // play/pause
        0x000C_0000_00E2, // mute
        0x000C_0000_00E9, // volume increment
        0x000C_0000_00EA, // volume decrement
        0x0001_0000_0081, // system power down
        0x0001_0000_0082  // system sleep
    ]

    init() {
        restoreIfLeftActive()
    }

    func enable() -> String? {
        let previous = currentMappings()
        persistPreviousMappings(previous)

        var combined = previous.filter { mapping in
            !blockedUsages.contains(mapping.src)
        }
        combined.append(contentsOf: blockedUsages.map { HIDKeyMapping(src: $0, dst: noEventUsage) })

        let result = applyMappings(combined)
        guard result.0 == 0 else {
            UserDefaults.standard.set(false, forKey: activeDefaultsKey)
            return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        UserDefaults.standard.set(true, forKey: activeDefaultsKey)
        return nil
    }

    func disable() {
        let previous = persistedPreviousMappings()
        _ = applyMappings(previous)
        UserDefaults.standard.set(false, forKey: activeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: previousDefaultsKey)
    }

    private func restoreIfLeftActive() {
        guard UserDefaults.standard.bool(forKey: activeDefaultsKey) else { return }
        disable()
    }

    private func currentMappings() -> [HIDKeyMapping] {
        let result = runProcess(executable: "/usr/bin/hidutil", arguments: ["property", "--get", "UserKeyMapping"], timeout: 2)
        guard result.0 == 0 else { return [] }
        return parseMappings(from: result.1)
    }

    private func parseMappings(from text: String) -> [HIDKeyMapping] {
        var mappings: [HIDKeyMapping] = []
        var currentSrc: UInt64?
        var currentDst: UInt64?

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.contains("HIDKeyboardModifierMappingSrc") {
                currentSrc = decimalValue(from: line)
            } else if line.contains("HIDKeyboardModifierMappingDst") {
                currentDst = decimalValue(from: line)
            }

            if let src = currentSrc, let dst = currentDst {
                mappings.append(HIDKeyMapping(src: src, dst: dst))
                currentSrc = nil
                currentDst = nil
            }
        }
        return mappings
    }

    private func decimalValue(from line: String) -> UInt64? {
        let digits = line.filter(\.isNumber)
        return UInt64(digits)
    }

    private func applyMappings(_ mappings: [HIDKeyMapping]) -> (Int32, String) {
        let entries = mappings.map { mapping in
            #"{"HIDKeyboardModifierMappingSrc":\#(mapping.src),"HIDKeyboardModifierMappingDst":\#(mapping.dst)}"#
        }.joined(separator: ",")
        let payload = #"{"UserKeyMapping":[\#(entries)]}"#
        return runProcess(executable: "/usr/bin/hidutil", arguments: ["property", "--set", payload], timeout: 2)
    }

    private func persistPreviousMappings(_ mappings: [HIDKeyMapping]) {
        guard let data = try? JSONEncoder().encode(mappings),
              let text = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(text, forKey: previousDefaultsKey)
    }

    private func persistedPreviousMappings() -> [HIDKeyMapping] {
        guard let text = UserDefaults.standard.string(forKey: previousDefaultsKey),
              let data = text.data(using: .utf8),
              let mappings = try? JSONDecoder().decode([HIDKeyMapping].self, from: data)
        else { return [] }
        return mappings
    }
}

final class KeyboardCleanController: ObservableObject {
    static let shared = KeyboardCleanController()

    @Published private(set) var isLocked = false
    @Published private(set) var isSwitching = false
    @Published private(set) var lastError = ""

    private let hidMediaKeyBlocker = HIDMediaKeyBlocker()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func setLocked(_ enabled: Bool) {
        DispatchQueue.main.async {
            guard !self.isSwitching else { return }
            if self.isLocked == enabled {
                self.updateState(enabled, error: self.lastError)
                return
            }
            self.isSwitching = true
            enabled ? self.start() : self.stop()
            self.finishSwitchingAfterDelay()
        }
    }

    func toggle() {
        setLocked(!isLocked)
    }

    func start() {
        if eventTap != nil {
            updateState(true, error: "")
            return
        }

        requestRequiredPermissionsIfNeeded()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon {
                    let controller = Unmanaged<KeyboardCleanController>
                        .fromOpaque(refcon)
                        .takeUnretainedValue()
                    controller.reenableTapSoon()
                }
                return Unmanaged.passUnretained(event)
            }

            if type.rawValue == 14 {
                return nil
            }

            switch type {
            case .keyDown, .keyUp, .flagsChanged:
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        guard let tap = createKeyboardEventTap(callback: callback) else {
            let language = UserDefaults.standard.string(forKey: "language")
            let message = localizedText(
                "未能鎖定鍵盤。請確認 Codex Accounts 喺「輔助使用」同「輸入監察」都有權限，然後完全退出再開一次 app。",
                "Could not lock the keyboard. Confirm Codex Accounts is allowed in both Accessibility and Input Monitoring, then fully quit and reopen the app.",
                language: language
            )
            updateState(false, error: message)
            alertMessage(localizedText("清潔模式啟動失敗", "Clean Mode Failed", language: language), message)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            eventTap = nil
            runLoopSource = nil
            let language = UserDefaults.standard.string(forKey: "language")
            let message = localizedText(
                "鍵盤攔截器建立咗但被 macOS 停用。請重新開啟 Codex Accounts，或重新勾選輔助使用/輸入監察權限。",
                "The keyboard event tap was created but macOS disabled it. Reopen Codex Accounts or re-check Accessibility/Input Monitoring permissions.",
                language: language
            )
            updateState(false, error: message)
            alertMessage(localizedText("清潔模式被系統停用", "Clean Mode Disabled", language: language), message)
            return
        }

        if let hidError = hidMediaKeyBlocker.enable() {
            let language = UserDefaults.standard.string(forKey: "language")
            let message = localizedText(
                "鍵盤已鎖，但音量/亮度硬件鍵未能完全映射：\(hidError)",
                "Keyboard locked, but media-key mapping failed: \(hidError)",
                language: language
            )
            updateState(true, error: message)
            return
        }
        updateState(true, error: "")
    }

    func stop() {
        hidMediaKeyBlocker.disable()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        updateState(false, error: "")
    }

    private var keyboardEventMask: CGEventMask {
        let keyDown = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        let keyUp = CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)
        let flagsChanged = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
        let systemDefined = CGEventMask(1) << CGEventMask(14)
        return keyDown | keyUp | flagsChanged | systemDefined
    }

    private func createKeyboardEventTap(callback: @escaping CGEventTapCallBack) -> CFMachPort? {
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let taps: [CGEventTapLocation] = [.cgSessionEventTap, .cghidEventTap]
        for tapLocation in taps {
            if let tap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: keyboardEventMask,
                callback: callback,
                userInfo: userInfo
            ) {
                return tap
            }
        }
        return nil
    }

    private func reenableTapSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    private func requestRequiredPermissionsIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if #available(macOS 10.15, *), !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    private func updateState(_ locked: Bool, error: String) {
        DispatchQueue.main.async {
            self.isLocked = locked
            self.lastError = error
            NotificationCenter.default.post(name: .keyboardCleanStateChanged, object: nil)
        }
    }

    private func finishSwitchingAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            self.isSwitching = false
            NotificationCenter.default.post(name: .keyboardCleanStateChanged, object: nil)
        }
    }
}

private final class ScreenCleanWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Blacks out every screen for a few seconds and pauses the touch screen, so the display can be wiped.
/// Nothing here is a system setting: the windows and the held touch device go away with the timer, or with
/// this process. Callers must have asked the user first.
final class ScreenCleanController: ObservableObject {
    static let shared = ScreenCleanController()
    static let seconds = 15.0

    @Published private(set) var isActive = false

    #if UI_PREVIEW
    // Test builds rehearse the timing only: invisible windows, no cursor change, the touch screen left alone.
    private let rehearsal = true
    var windowCount: Int { windows.count }
    #else
    private let rehearsal = false
    #endif

    private var windows: [NSWindow] = []
    private var touchScreen: IOHIDManager?
    private var keyMonitor: Any?
    private var timer: DispatchWorkItem?
    private var onFinish: (() -> Void)?
    private let sessionLock = NSLock()
    private var session = 0

    private init() {}

    func start(seconds: Double = ScreenCleanController.seconds, onFinish: @escaping () -> Void = {}) {
        guard !isActive else { return }
        isActive = true
        self.onFinish = onFinish
        windows = NSScreen.screens.map(makeWindow)
        if !rehearsal {
            holdTouchScreen()
            NSApp.activate(ignoringOtherApps: true)
            windows.first?.makeKeyAndOrderFront(nil)
            NSCursor.hide()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.finish() }   // Esc ends early; every other key is ignored.
                return nil
            }
        }
        let end = DispatchWorkItem { [weak self] in self?.finish() }
        timer = end
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
        armWatchdog(after: seconds + 5)
    }

    func finish() {
        guard isActive else { return }
        isActive = false
        timer?.cancel()
        timer = nil
        sessionLock.withLock { session += 1 }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        releaseTouchScreen()
        if !rehearsal { NSCursor.unhide() }
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
        let done = onFinish
        onFinish = nil
        done?()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = ScreenCleanWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = rehearsal
        window.alphaValue = 0
        window.orderFrontRegardless()
        if !rehearsal {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
        }
        return window
    }

    /// Takes the touch screen (and only the touch screen; the trackpad is a different usage) away from the
    /// system. If that is refused the black windows still swallow every touch.
    private func holdTouchScreen() {
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_Digitizer,
            kIOHIDPrimaryUsageKey as String: kHIDUsage_Dig_TouchScreen
        ]
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else { return }
        touchScreen = manager
    }

    private func releaseTouchScreen() {
        guard let manager = touchScreen else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        touchScreen = nil
    }

    /// The shield hides even Force Quit, so a stuck main thread must never leave the screen black: quitting is
    /// what gives the screen and the touch device back.
    private func armWatchdog(after seconds: Double) {
        let armed = sessionLock.withLock { session }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + seconds) { [self] in
            guard sessionLock.withLock({ session }) == armed else { return }
            _exit(0)
        }
    }
}

final class DisplayBrightnessController {
    static let shared = DisplayBrightnessController()

    private typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightnessFunction?
    private let setBrightness: SetBrightnessFunction?

    private init() {
        frameworkHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        if let frameworkHandle,
           let getSymbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness"),
           let setSymbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(getSymbol, to: GetBrightnessFunction.self)
            setBrightness = unsafeBitCast(setSymbol, to: SetBrightnessFunction.self)
        } else {
            getBrightness = nil
            setBrightness = nil
        }
    }

    func currentBuiltInBrightness() -> Float? {
        guard let getBrightness else { return nil }
        for displayID in builtInDisplayIDs() {
            var brightness: Float = 0
            if getBrightness(displayID, &brightness) == 0 {
                return min(max(brightness, 0), 1)
            }
        }
        return nil
    }

    func setBuiltInBrightness(_ brightness: Float) {
        guard let setBrightness else { return }
        let clamped = min(max(brightness, 0), 1)
        for displayID in builtInDisplayIDs() {
            _ = setBrightness(displayID, clamped)
        }
    }

    private func builtInDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return [CGMainDisplayID()]
        }

        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return [CGMainDisplayID()]
        }

        let builtIn = displays.filter { CGDisplayIsBuiltin($0) != 0 }
        return builtIn.isEmpty ? [CGMainDisplayID()] : builtIn
    }
}

enum KeepAwakeMode: Int, CaseIterable, Identifiable {
    case off = 0
    case display = 1
    case clamshell = 2

    var id: Int { rawValue }
}

private struct KeepAwakeLevelSlider: View {
    @Binding var mode: KeepAwakeMode
    let isEnabled: Bool
    let accessibilityLabelText: String
    let accessibilityValueText: String

    @State private var rawValue: Double
    @State private var isEditing = false

    private var previewMode: KeepAwakeMode {
        KeepAwakeMode(rawValue: Int(rawValue.rounded())) ?? mode
    }

    private var accentColors: [Color] {
        switch previewMode {
        case .off:
            return [
                Color(red: 0.58, green: 0.63, blue: 0.70),
                Color(red: 0.36, green: 0.41, blue: 0.49)
            ]
        case .display:
            return [
                Color(red: 0.08, green: 0.88, blue: 0.72),
                Color(red: 0.08, green: 0.64, blue: 0.92)
            ]
        case .clamshell:
            return [
                Color(red: 0.96, green: 0.40, blue: 0.78),
                Color(red: 0.62, green: 0.34, blue: 1.00)
            ]
        }
    }

    init(
        mode: Binding<KeepAwakeMode>,
        isEnabled: Bool,
        accessibilityLabelText: String,
        accessibilityValueText: String
    ) {
        _mode = mode
        _rawValue = State(initialValue: Double(mode.wrappedValue.rawValue))
        self.isEnabled = isEnabled
        self.accessibilityLabelText = accessibilityLabelText
        self.accessibilityValueText = accessibilityValueText
    }

    var body: some View {
        Slider(
            value: $rawValue,
            in: 0...2,
            step: 1,
            onEditingChanged: { editing in
                isEditing = editing
                guard !editing, isEnabled else { return }
                if let nextMode = KeepAwakeMode(rawValue: Int(rawValue.rounded())), nextMode != mode {
                    mode = nextMode
                }
            }
        )
        .tint(accentColors.last ?? Color.gray)
        .controlSize(.large)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            LinearGradient(
                colors: accentColors.map { $0.opacity(0.24) },
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: Capsule()
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.58)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityValue(Text(accessibilityValueText))
        .disabled(!isEnabled)
        .onAppear {
            rawValue = Double(mode.rawValue)
        }
        .onChange(of: mode) { _, newMode in
            guard !isEditing else { return }
            rawValue = Double(newMode.rawValue)
        }
        .onChange(of: isEnabled) { _, enabled in
            if enabled {
                rawValue = Double(mode.rawValue)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: previewMode)
    }
}

final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    @Published private(set) var mode: KeepAwakeMode = .off
    @Published private(set) var isSwitching = false

    var isAwake: Bool { mode != .off }

    private var sleepActivity: NSObjectProtocol?
    private let sleepActivityLock = NSLock()
    private var clamshellTimer: Timer?
    private var stateMonitorTimer: Timer?
    private var stateRefreshInFlight = false
    private var lastStateRefreshAt = Date.distantPast
    private var storedBrightnessBeforeLidClose: Float?
    private var dimmedForClosedLid = false
    private var ownsSystemSleepOverrideThisRun = false
    private let legacyPidFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Accounts/keep-awake.pid")
    private let sleepOwnershipFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Accounts/keep-awake-clamshell-owned")

    var ownsSystemSleepOverride: Bool {
        ownsSystemSleepOverrideThisRun
            || FileManager.default.fileExists(atPath: sleepOwnershipFileURL.path)
    }

    private init() {
        cleanupLegacyManagedCaffeinate()
        startStateMonitor()
    }

    func refreshState(force: Bool = false) {
        DispatchQueue.main.async {
            guard !self.isSwitching else { return }
            let now = Date()
            guard force || now.timeIntervalSince(self.lastStateRefreshAt) >= 2.5 else { return }
            guard !self.stateRefreshInFlight else { return }
            self.stateRefreshInFlight = true
            self.lastStateRefreshAt = now

            DispatchQueue.global(qos: .utility).async {
                defer { self.finishStateRefresh() }
                let sleepDisabled = self.systemSleepDisabled()
                if !sleepDisabled {
                    self.clearSystemSleepOwnership()
                }
                var hasActivity = self.nativeActivityIsActive()
                if sleepDisabled, !hasActivity {
                    hasActivity = self.ensureNativeActivity().0
                }

                let detectedMode: KeepAwakeMode = sleepDisabled
                    ? .clamshell
                    : (hasActivity ? .display : .off)
                self.updateMode(detectedMode)
            }
        }
    }

    func setMode(_ requestedMode: KeepAwakeMode, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            guard !self.isSwitching else {
                completion?(false)
                return
            }
            if self.mode == requestedMode, requestedMode != .off {
                self.refreshState(force: true)
                completion?(true)
                return
            }

            let previousMode = self.mode
            self.isSwitching = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.applyMode(requestedMode, previousMode: previousMode)
                DispatchQueue.main.async {
                    self.isSwitching = false
                    if result.0 {
                        self.updateMode(requestedMode)
                    } else {
                        self.updateMode(previousMode)
                        let language = UserDefaults.standard.string(forKey: "language")
                        alertMessage(
                            localizedText("防睡眠模式切換失敗", "Could Not Change Keep Awake Mode", language: language),
                            result.1
                        )
                    }
                    completion?(result.0)
                    self.refreshState(force: true)
                }
            }
        }
    }

    func setAwake(_ enabled: Bool) {
        setMode(enabled ? .display : .off)
    }

    func toggle() {
        setMode(isAwake ? .off : .display)
    }

    func start() {
        setMode(.display)
    }

    func stop() {
        setMode(.off)
    }

    func stopKeepAwakeForTermination() {
        stopNativeActivity()
        stopClamshellMonitor(restoreBrightness: true)
    }

    private func startStateMonitor() {
        DispatchQueue.main.async {
            self.stateMonitorTimer?.invalidate()
            self.stateMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                self.refreshState()
            }
        }
    }

    private func applyMode(_ requestedMode: KeepAwakeMode, previousMode: KeepAwakeMode) -> (Bool, String) {
        if requestedMode != .off {
            let activityResult = ensureNativeActivity()
            guard activityResult.0 else { return activityResult }
        }

        let shouldDisableSystemSleep = requestedMode == .clamshell
        if systemSleepDisabled() != shouldDisableSystemSleep {
            let privilegeResult = setSystemSleepDisabled(shouldDisableSystemSleep)
            guard privilegeResult.0 else {
                if previousMode == .off {
                    stopNativeActivity()
                }
                return privilegeResult
            }
        }

        if requestedMode == .off {
            stopNativeActivity()
        }
        if requestedMode != .clamshell {
            clearSystemSleepOwnership()
        }
        return (true, "")
    }

    private func ensureNativeActivity() -> (Bool, String) {
        sleepActivityLock.lock()
        defer { sleepActivityLock.unlock() }
        guard sleepActivity == nil else { return (true, "") }

        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Codex Accounts keeps the open display awake"
        )
        return (true, "")
    }

    private func nativeActivityIsActive() -> Bool {
        sleepActivityLock.lock()
        defer { sleepActivityLock.unlock() }
        return sleepActivity != nil
    }

    private func stopNativeActivity() {
        sleepActivityLock.lock()
        let activity = sleepActivity
        sleepActivity = nil
        sleepActivityLock.unlock()

        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private func systemSleepDisabled() -> Bool {
        let result = runProcess(executable: "/usr/bin/pmset", arguments: ["-g"], timeout: 4)
        guard result.0 == 0 else { return false }
        return result.1.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    private func setSystemSleepDisabled(_ disabled: Bool) -> (Bool, String) {
        let value = disabled ? "1" : "0"
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        let result = runProcess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 300
        )
        guard result.0 == 0 else {
            let message = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, message.isEmpty ? "Administrator authorization was cancelled." : message)
        }
        let applied = systemSleepDisabled() == disabled
        guard applied else { return (false, "pmset did not keep the requested setting.") }
        if disabled {
            markSystemSleepOwnership()
        } else {
            clearSystemSleepOwnership()
        }
        return (true, "")
    }

    private func markSystemSleepOwnership() {
        ownsSystemSleepOverrideThisRun = true
        do {
            try FileManager.default.createDirectory(
                at: sleepOwnershipFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "managed\n".write(to: sleepOwnershipFileURL, atomically: true, encoding: .utf8)
        } catch {
            // In-memory ownership still guarantees cleanup during this run.
        }
    }

    private func clearSystemSleepOwnership() {
        ownsSystemSleepOverrideThisRun = false
        try? FileManager.default.removeItem(at: sleepOwnershipFileURL)
    }

    private func cleanupLegacyManagedCaffeinate() {
        guard let text = try? String(contentsOf: legacyPidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            try? FileManager.default.removeItem(at: legacyPidFileURL)
            return
        }

        try? FileManager.default.removeItem(at: legacyPidFileURL)
        guard Darwin.kill(pid, 0) == 0 else { return }

        let result = runProcess(
            executable: "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "command="],
            timeout: 3
        )
        guard result.0 == 0 else { return }
        let command = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyCommands = [
            "/usr/bin/caffeinate -dims",
            "caffeinate -dims",
            "/usr/bin/caffeinate -d -i -m -s",
            "caffeinate -d -i -m -s"
        ]
        if legacyCommands.contains(command) {
            Darwin.kill(pid, SIGTERM)
        }
    }

    private func updateMode(_ newMode: KeepAwakeMode) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.updateMode(newMode)
            }
            return
        }

        let changed = mode != newMode
        mode = newMode
        if newMode == .clamshell {
            startClamshellMonitor()
        } else {
            stopClamshellMonitor(restoreBrightness: true)
        }
        guard changed else { return }
        NotificationCenter.default.post(name: .keepAwakeStateChanged, object: nil)
    }

    private func finishStateRefresh() {
        DispatchQueue.main.async {
            self.stateRefreshInFlight = false
        }
    }

    private func startClamshellMonitor() {
        DispatchQueue.main.async {
            if self.clamshellTimer?.isValid == true {
                self.handleClamshellState()
                return
            }
            self.clamshellTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                self.handleClamshellState()
            }
            self.handleClamshellState()
        }
    }

    private func stopClamshellMonitor(restoreBrightness: Bool) {
        DispatchQueue.main.async {
            self.clamshellTimer?.invalidate()
            self.clamshellTimer = nil
            if restoreBrightness {
                self.restoreBrightnessAfterLidOpen()
            }
        }
    }

    private func handleClamshellState() {
        guard mode == .clamshell else {
            restoreBrightnessAfterLidOpen()
            return
        }

        if isLidClosed() {
            dimBrightnessForClosedLid()
        } else {
            restoreBrightnessAfterLidOpen()
        }
    }

    private func dimBrightnessForClosedLid() {
        guard !dimmedForClosedLid else { return }
        storedBrightnessBeforeLidClose = DisplayBrightnessController.shared.currentBuiltInBrightness()
        DisplayBrightnessController.shared.setBuiltInBrightness(0)
        dimmedForClosedLid = true
    }

    private func restoreBrightnessAfterLidOpen() {
        guard dimmedForClosedLid else { return }
        let restored = storedBrightnessBeforeLidClose ?? 0.55
        DisplayBrightnessController.shared.setBuiltInBrightness(max(restored, 0.18))
        storedBrightnessBeforeLidClose = nil
        dimmedForClosedLid = false
    }

    private func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return false
        }
        return value
    }

}

struct AccountsRootView: View {
    let scriptPath: String

    @StateObject private var keepAwake = KeepAwakeController.shared
    @StateObject private var keyboardClean = KeyboardCleanController.shared
    @StateObject private var screenClean = ScreenCleanController.shared
    @StateObject private var updater = UpdateController.shared
    @State private var profiles: [CodexProfile] = []
    @State private var statusText = "就緒"
    @AppStorage("autoRefresh") private var autoRefresh = true
    @AppStorage("autoSync") private var autoSync = true
    @AppStorage("autoQuotaPool") private var autoQuotaPool = false
    @AppStorage("language") private var language = "zh"
    @State private var displayNames: [String: String] = UserDefaults.standard.dictionary(forKey: "profileDisplayNames") as? [String: String] ?? [:]
    @AppStorage("lastHistorySyncTimestamp") private var lastHistorySyncTimestamp = 0.0
    @State private var launchedAt = Date()
    @State private var lastAutoSyncAt = Date.distantPast
    @State private var layoutScale: CGFloat = 1
    @State private var visibleContentSize: CGSize = .zero
    @State private var activeOperationCount = 0
    @State private var loadingMessage = ""
    @State private var isRefreshing = false
    @State private var isSyncing = false
    @State private var isCleaningSidebarState = false
    @State private var isRepairingHistoryPayloads = false
    @State private var hasEntered = true
    @State private var showKeepAwakeHelp = false
    @State private var showKeyboardCleanHelp = false
    @State private var showSyncHelp = false
    @State private var busyProfiles: Set<String> = []
    @State private var isClosingAllAccounts = false
    @State private var expandedResetKeys: Set<String> = []
    @State private var expandedResetCreditProfileIDs: Set<String> = []
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showIntro = false
    @State private var iconVersion = 0
    @State private var pendingSectionScroll: String?
    @State private var quotaReplayActive = false
    @State private var resetScrambleActive = false
    @State private var resetScrambleReturning = false
    @State private var resetScrambleSeed = 0
    @State private var resetScrambleRunID = 0
    @State private var codexUsageSessionActive = false
    @State private var codexUsageLastSample: Date?
    @State private var usageProcessCheckInFlight = false
    @State private var usageTicker = Date()
    @State private var activeQuotaPoolProfileID: String?
    @State private var quotaPoolFailoverInProgress = false
    @State private var lastAutoQuotaRefreshAt = Date.distantPast
    @State private var lastResetCreditBackfillAt = Date.distantPast
    @State private var showLanguageMenu = false
    @State private var languageTransitionActive = false
    @State private var languagePulse = false
    @State private var hoveredProfileID: String?
    @State private var localAuthTokenProfileIDs: Set<String> = []
    @AppStorage("sidebarAutomationExpanded") private var sidebarAutomationExpanded = true
    @AppStorage("sidebarToolsExpanded") private var sidebarToolsExpanded = false
    @AppStorage("sidebarAppearanceExpanded") private var sidebarAppearanceExpanded = false
    @AppStorage("sidebarUpdatesExpanded") private var sidebarUpdatesExpanded = false
    @AppStorage("codexUsageRecordV2") private var codexUsageRecordData = ""
    @AppStorage("codexUsageDayKey") private var legacyCodexUsageDayKey = ""
    @AppStorage("codexUsageSecondsToday") private var legacyCodexUsageSecondsToday = 0.0
    @AppStorage("appTheme") private var appTheme = "graphite"
    @AppStorage("rdSection") private var rdSection = "accounts"
    @AppStorage("rdCompactRows") private var rdCompactRows = false
    @State private var rdSelectedProfileID: String?
    @State private var rdFilter = "all"
    @State private var rdSearch = ""
    @State private var rdRefreshingIDs: Set<String> = []
    @State private var rdFailedRefreshIDs: Set<String> = []
    @State private var rdLastRefreshAt: Date?
    @Namespace private var rdNamespace
    @FocusState private var rdSearchFocused: Bool
    @State private var rdRevealed = false
    @State private var rdToast: String?
    @State private var rdAnalytics: RDAnalyticsSnapshot?
    @State private var rdTokenData: RDTokenData?
    @State private var rdTokenReport: RDTokenReport?
    @State private var rdTokenOverallTotal = 0.0
    @AppStorage("rdAnalysisScope") private var rdAnalysisScope = ""
    @AppStorage("rdAnalysisDays") private var rdAnalysisDays = 7
    @AppStorage("rdTokenChartMode") private var rdTokenChartMode = "all"
    @State private var rdAnalyticsLoading = false
    @State private var rdChartProfileID: String?
    @State private var rdPreviousProfiles: [CodexProfile] = []
    @AppStorage("rdNotifyEnabled") private var rdNotifyEnabled = false
    @AppStorage("rdAppearance") private var rdAppearance = "dark"
    @AppStorage("rdGroupByTier") private var rdGroupByTier = true
    @AppStorage("rdCollapsedGroups") private var rdCollapsedGroups = ""
    @State private var rdMeta: [String: RDAccountMeta] = [:]
    @State private var rdApiPlans: [String: String] = [:]
    @State private var rdListScrolled = false
    @State private var rdBackdropPicture: NSImage? = RDBackdropStore.load()
    @State private var rdMissingTools: [String] = []
    @AppStorage("rdBackdropStrength") private var rdBackdropStrength = 0.2
    @AppStorage("rdSidebarWidth") private var rdSidebarWidth = 220.0
    @AppStorage("rdKeepAwakeLastMode") private var rdKeepAwakeLastMode = KeepAwakeMode.display.rawValue
    @State private var rdSidebarLive: Double?       // Width during a drag; saved when the drag ends.
    @State private var rdSidebarDragBase: Double?
    @State private var rdSidebarHandleHot = false
    @State private var rdHoverRowID: String?
    @Environment(\.colorScheme) private var rdSystemScheme
    @Namespace private var languageNamespace

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let autoQuotaLiveRefreshInterval: TimeInterval = 55     // Every timer tick, allowing for timer drift.
    private let resetCreditLiveBackfillInterval: TimeInterval = 90
    private let liveUsageParallelism = 10
    private let liveUsageStatusTimeout: TimeInterval = 60
    private let autoSyncStartupDelay: TimeInterval = 90
    private let autoSyncInterval: TimeInterval = 600

    var body: some View {
        ZStack {
            rdBackground
                .ignoresSafeArea()

            redesignedWorkspace
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
            .opacity(hasEntered ? 1 : 0)
            .scaleEffect(hasEntered ? 1 : 0.985)
            .blur(radius: hasEntered ? 0 : 4)

            loadingOverlay

            if languageTransitionActive {
                languageTransitionOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: sidebarCollapsed)
        .animation(.easeInOut(duration: 0.22), value: selectedLanguage.id)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: languageTransitionActive)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateLayoutScale(for: geometry.size) }
                    .onChange(of: geometry.size) { _, newSize in
                        updateLayoutScale(for: newSize)
                    }
            }
        )
        .background(WindowContentSizeReader(size: $visibleContentSize))
        .onAppear {
            launchedAt = Date()
            if lastHistorySyncTimestamp > 0 {
                lastAutoSyncAt = Date(timeIntervalSince1970: lastHistorySyncTimestamp)
            }
            if UserDefaults.standard.object(forKey: "language") == nil {
                language = AppLanguage.systemDefault.rawValue
            }
            let normalizedLanguage = AppLanguage.normalized(language).rawValue
            if normalizedLanguage != language {
                language = normalizedLanguage
            }
            let normalizedTheme = canonicalThemeID(appTheme)
            if normalizedTheme != appTheme {
                appTheme = normalizedTheme
            }
            hasEntered = true
            languageTransitionActive = false
            showLanguageMenu = false
            if hasSeenIntro {
                showIntro = false
            }
            if !hasSeenIntro {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    showIntro = true
                    hasSeenIntro = true
                }
            }
            if autoQuotaPool {
                autoQuotaPool = false
            }
            normalizeUsageRecord()
            reconcileUsageSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                refreshProfiles(showLoading: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                keepAwake.refreshState(force: true)
            }
            #if !UI_PREVIEW
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                updater.checkForUpdates(presentNoUpdate: false, notifyIfAvailable: false)
            }
            #endif
        }
        .sheet(isPresented: $showIntro) {
            introView
        }
        .onChange(of: language) { _, newValue in
            let normalized = AppLanguage.normalized(newValue).rawValue
            if normalized != newValue {
                language = normalized
                return
            }
            NotificationCenter.default.post(name: Notification.Name("CodexAccountsLanguageChanged"), object: nil)
        }
        .onChange(of: updater.availableRelease?.version) { _, version in
            if version != nil, updater.updateAvailable {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    sidebarUpdatesExpanded = true
                }
            }
        }
        .onReceive(timer) { _ in
            sampleUsageSession()
            reconcileUsageSession()
            runPeriodicMaintenance()
            keepAwake.refreshState()
            if autoRefresh { rdRecordQuota() }
            usageTicker = Date()
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage.normalized(language)
    }

    private func tr(_ zh: String, _ en: String) -> String {
        localizedText(zh, en, language: language)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        (value * layoutScale).rounded()
    }

    private var profileHoverPadding: CGFloat {
        scaled(42)
    }

    private var profileScrollBarReserve: CGFloat {
        scaled(12)
    }

    private var profileRightAlignmentInset: CGFloat {
        profileHoverPadding + profileScrollBarReserve
    }

    private func updateLayoutScale(for size: CGSize) {
        let widthProgress = min(max((size.width - 1100) / 800, 0), 1)
        let heightProgress = min(max((size.height - 680) / 420, 0), 1)
        let progress = min(widthProgress, heightProgress)
        let nextScale = 1 + progress * 0.20

        if abs(nextScale - layoutScale) > 0.01 {
            layoutScale = nextScale
        }
    }

    private var lastAutoSyncLabel: String {
        guard lastHistorySyncTimestamp > 0 else { return tr("未同步", "Not yet") }
        let date = Date(timeIntervalSince1970: lastHistorySyncTimestamp)
        if Calendar.current.isDateInToday(date) {
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private var syncSummaryText: String {
        autoSync
            ? tr("每 10 分鐘 · 上次 \(lastAutoSyncLabel)", "Every 10 min · Last \(lastAutoSyncLabel)")
            : tr("已關閉 · 上次 \(lastAutoSyncLabel)", "Off · Last \(lastAutoSyncLabel)")
    }

    private var syncAccent: Color {
        autoSync
            ? Color(red: 0.20, green: 0.82, blue: 0.66)
            : Color(red: 1.00, green: 0.64, blue: 0.24)
    }

    private func currentDayKey(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func maximumPlausibleUsage(at date: Date) -> TimeInterval {
        let elapsedToday = max(date.timeIntervalSince(Calendar.current.startOfDay(for: date)), 0)
        return min(elapsedToday + 120, 86_400)
    }

    private func validUsageSeconds(_ seconds: TimeInterval, at date: Date) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= maximumPlausibleUsage(at: date)
    }

    private func decodedUsageRecord(at date: Date, allowLegacyMigration: Bool = true) -> DailyUsageRecord {
        let today = currentDayKey(at: date)
        if let data = codexUsageRecordData.data(using: .utf8),
           let record = try? JSONDecoder().decode(DailyUsageRecord.self, from: data),
           record.dayKey == today,
           validUsageSeconds(record.seconds, at: date) {
            return record
        }

        if allowLegacyMigration,
           codexUsageRecordData.isEmpty,
           legacyCodexUsageDayKey == today,
           validUsageSeconds(legacyCodexUsageSecondsToday, at: date) {
            return DailyUsageRecord(dayKey: today, seconds: legacyCodexUsageSecondsToday)
        }

        return DailyUsageRecord(dayKey: today, seconds: 0)
    }

    private func persistUsageRecord(_ record: DailyUsageRecord) {
        guard let data = try? JSONEncoder().encode(record),
              let text = String(data: data, encoding: .utf8)
        else { return }
        if codexUsageRecordData != text {
            codexUsageRecordData = text
        }
    }

    private func normalizeUsageRecord(at date: Date = Date()) {
        let record = decodedUsageRecord(at: date)
        persistUsageRecord(record)
        legacyCodexUsageDayKey = currentDayKey(at: date)
        legacyCodexUsageSecondsToday = 0
    }

    private func startUsageSession() {
        let now = Date()
        normalizeUsageRecord(at: now)
        guard !codexUsageSessionActive else { return }
        codexUsageSessionActive = true
        codexUsageLastSample = now
        usageTicker = now
    }

    private func finishUsageSession() {
        guard codexUsageSessionActive else { return }
        sampleUsageSession()
        codexUsageSessionActive = false
        codexUsageLastSample = nil
        usageTicker = Date()
    }

    private func sampleUsageSession(at date: Date = Date()) {
        normalizeUsageRecord(at: date)
        guard codexUsageSessionActive, let lastSample = codexUsageLastSample else { return }

        guard currentDayKey(at: lastSample) == currentDayKey(at: date) else {
            codexUsageLastSample = date
            usageTicker = date
            return
        }

        // The timer normally fires every 60 seconds. Capping one sample avoids
        // counting sleep, a frozen process, or time spent powered off.
        let sample = min(max(date.timeIntervalSince(lastSample), 0), 90)
        var record = decodedUsageRecord(at: date, allowLegacyMigration: false)
        record.seconds = min(record.seconds + sample, maximumPlausibleUsage(at: date))
        persistUsageRecord(record)
        codexUsageLastSample = date
        usageTicker = date
    }

    private func reconcileUsageSession() {
        guard !usageProcessCheckInFlight else { return }
        usageProcessCheckInFlight = true

        DispatchQueue.global(qos: .utility).async {
            let result = runProcess(
                executable: "/bin/ps",
                arguments: ["axww", "-o", "command="],
                timeout: 3
            )
            let codexExecutablePaths = supportedCodexGUIExecutablePaths()
            let isManagedCodexRunning = result.0 == 0 && result.1.split(separator: "\n").contains { line in
                let command = String(line)
                let isCodexExecutable = codexExecutablePaths.contains { command.contains($0) }
                // The primary Codex window has no --user-data-dir argument;
                // account2 and named profiles do. The main executable is the
                // reliable signal shared by all three launch paths.
                return isCodexExecutable
            }

            DispatchQueue.main.async {
                usageProcessCheckInFlight = false
                if isManagedCodexRunning {
                    startUsageSession()
                } else {
                    finishUsageSession()
                }
            }
        }
    }

    private func currentUsageSeconds() -> TimeInterval {
        let now = Date()
        let record = decodedUsageRecord(at: now)
        let liveSeconds = codexUsageSessionActive
            ? min(max(now.timeIntervalSince(codexUsageLastSample ?? now), 0), 90)
            : 0
        _ = usageTicker
        return min(max(record.seconds + liveSeconds, 0), 86_400)
    }

    private func usageDurationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = min(max(Int(seconds / 60), 0), 24 * 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return tr(
            "\(hours) 小時 \(String(format: "%02d", minutes)) 分",
            "\(hours)h \(String(format: "%02d", minutes))m"
        )
    }

    private func appFont(size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false) -> Font {
        if monospaced {
            return .system(size: scaled(size), weight: weight, design: .monospaced)
        }
        return .system(size: scaled(size), weight: weight, design: .default)
    }

    private var themeTitle: String {
        selectedThemeOption.zhTitle
    }

    private var themeOptions: [AppThemeOption] {
        [
            AppThemeOption(
                id: "graphite",
                zhTitle: tr("石墨", "Graphite"),
                primary: Color(red: 0.70, green: 0.78, blue: 0.84),
                secondary: Color(red: 0.40, green: 0.48, blue: 0.54),
                warm: Color(red: 0.94, green: 0.96, blue: 0.98),
                background: [
                    Color(red: 0.035, green: 0.040, blue: 0.048).opacity(0.94),
                    Color(red: 0.12, green: 0.14, blue: 0.16).opacity(0.80),
                    Color(red: 0.055, green: 0.065, blue: 0.075).opacity(0.90)
                ],
                mainTint: Color(red: 0.18, green: 0.21, blue: 0.23),
                sidebarTint: Color(red: 0.10, green: 0.12, blue: 0.14),
                rowTint: Color(red: 0.42, green: 0.48, blue: 0.52)
            ),
            AppThemeOption(
                id: "aurora",
                zhTitle: tr("極光", "Aurora"),
                primary: Color(red: 0.08, green: 0.95, blue: 0.62),
                secondary: Color(red: 0.10, green: 0.82, blue: 0.88),
                warm: Color(red: 0.72, green: 1.00, blue: 0.30),
                background: [
                    Color(red: 0.015, green: 0.085, blue: 0.070).opacity(0.94),
                    Color(red: 0.02, green: 0.25, blue: 0.18).opacity(0.76),
                    Color(red: 0.025, green: 0.11, blue: 0.16).opacity(0.88)
                ],
                mainTint: Color(red: 0.04, green: 0.34, blue: 0.24),
                sidebarTint: Color(red: 0.02, green: 0.23, blue: 0.17),
                rowTint: Color(red: 0.10, green: 0.62, blue: 0.44)
            ),
            AppThemeOption(
                id: "amber",
                zhTitle: tr("日落", "Sunset"),
                primary: Color(red: 1.00, green: 0.64, blue: 0.12),
                secondary: Color(red: 1.00, green: 0.25, blue: 0.28),
                warm: Color(red: 1.00, green: 0.86, blue: 0.26),
                background: [
                    Color(red: 0.13, green: 0.035, blue: 0.035).opacity(0.94),
                    Color(red: 0.34, green: 0.095, blue: 0.035).opacity(0.76),
                    Color(red: 0.15, green: 0.07, blue: 0.13).opacity(0.88)
                ],
                mainTint: Color(red: 0.43, green: 0.16, blue: 0.07),
                sidebarTint: Color(red: 0.29, green: 0.10, blue: 0.06),
                rowTint: Color(red: 0.78, green: 0.34, blue: 0.12)
            ),
            AppThemeOption(
                id: "violet",
                zhTitle: tr("霓虹", "Neon"),
                primary: Color(red: 0.68, green: 0.38, blue: 1.00),
                secondary: Color(red: 1.00, green: 0.20, blue: 0.72),
                warm: Color(red: 0.30, green: 0.82, blue: 1.00),
                background: [
                    Color(red: 0.075, green: 0.025, blue: 0.14).opacity(0.95),
                    Color(red: 0.23, green: 0.045, blue: 0.30).opacity(0.78),
                    Color(red: 0.035, green: 0.10, blue: 0.18).opacity(0.88)
                ],
                mainTint: Color(red: 0.30, green: 0.10, blue: 0.42),
                sidebarTint: Color(red: 0.19, green: 0.07, blue: 0.29),
                rowTint: Color(red: 0.56, green: 0.22, blue: 0.68)
            ),
            AppThemeOption(
                id: "ocean",
                zhTitle: tr("深海", "Ocean"),
                primary: Color(red: 0.14, green: 0.62, blue: 1.00),
                secondary: Color(red: 0.06, green: 0.90, blue: 0.96),
                warm: Color(red: 0.22, green: 0.46, blue: 1.00),
                background: [
                    Color(red: 0.015, green: 0.045, blue: 0.13).opacity(0.96),
                    Color(red: 0.025, green: 0.16, blue: 0.34).opacity(0.78),
                    Color(red: 0.015, green: 0.13, blue: 0.20).opacity(0.90)
                ],
                mainTint: Color(red: 0.04, green: 0.20, blue: 0.46),
                sidebarTint: Color(red: 0.02, green: 0.13, blue: 0.31),
                rowTint: Color(red: 0.08, green: 0.40, blue: 0.76)
            ),
            AppThemeOption(
                id: "sakura",
                zhTitle: tr("櫻花", "Sakura"),
                primary: Color(red: 1.00, green: 0.52, blue: 0.72),
                secondary: Color(red: 0.78, green: 0.40, blue: 1.00),
                warm: Color(red: 1.00, green: 0.84, blue: 0.90),
                background: [
                    Color(red: 0.14, green: 0.035, blue: 0.09).opacity(0.95),
                    Color(red: 0.30, green: 0.08, blue: 0.20).opacity(0.78),
                    Color(red: 0.16, green: 0.08, blue: 0.20).opacity(0.88)
                ],
                mainTint: Color(red: 0.42, green: 0.13, blue: 0.27),
                sidebarTint: Color(red: 0.28, green: 0.08, blue: 0.18),
                rowTint: Color(red: 0.72, green: 0.30, blue: 0.48)
            ),
            AppThemeOption(
                id: "forest",
                zhTitle: tr("森林", "Forest"),
                primary: Color(red: 0.62, green: 0.86, blue: 0.24),
                secondary: Color(red: 0.18, green: 0.58, blue: 0.30),
                warm: Color(red: 0.98, green: 0.72, blue: 0.18),
                background: [
                    Color(red: 0.045, green: 0.095, blue: 0.045).opacity(0.96),
                    Color(red: 0.12, green: 0.23, blue: 0.08).opacity(0.78),
                    Color(red: 0.16, green: 0.12, blue: 0.045).opacity(0.88)
                ],
                mainTint: Color(red: 0.18, green: 0.32, blue: 0.10),
                sidebarTint: Color(red: 0.11, green: 0.22, blue: 0.07),
                rowTint: Color(red: 0.40, green: 0.60, blue: 0.20)
            ),
            AppThemeOption(
                id: "midnight",
                zhTitle: tr("午夜", "Midnight"),
                primary: Color(red: 1.00, green: 0.78, blue: 0.22),
                secondary: Color(red: 0.56, green: 0.66, blue: 0.88),
                warm: Color(red: 1.00, green: 0.92, blue: 0.58),
                background: [
                    Color(red: 0.015, green: 0.018, blue: 0.035).opacity(0.98),
                    Color(red: 0.045, green: 0.055, blue: 0.11).opacity(0.84),
                    Color(red: 0.13, green: 0.09, blue: 0.025).opacity(0.86)
                ],
                mainTint: Color(red: 0.16, green: 0.15, blue: 0.23),
                sidebarTint: Color(red: 0.075, green: 0.075, blue: 0.13),
                rowTint: Color(red: 0.55, green: 0.44, blue: 0.16)
            )
        ]
    }

    private func canonicalThemeID(_ rawValue: String) -> String {
        switch rawValue {
        case "sage": return "forest"
        case "copper", "ember": return "amber"
        case "rose": return "sakura"
        case "indigo": return "violet"
        case "glacier": return "ocean"
        case "slate": return "graphite"
        default:
            let known = RDTheme.all.contains { $0.id == rawValue } || themeOptions.contains { $0.id == rawValue }
            return known ? rawValue : "graphite"
        }
    }

    private var selectedThemeOption: AppThemeOption {
        themeOptions.first(where: { $0.id == appTheme }) ?? themeOptions[0]
    }

    private var themePrimary: Color {
        rdPalette.accent
    }

    private var themeSecondary: Color {
        rdPalette.accent2
    }

    private var themeWarm: Color {
        rdPalette.warm
    }

    private var themeBackgroundColors: [Color] {
        selectedThemeOption.background
    }

    private var themeMainTint: Color {
        selectedThemeOption.mainTint
    }

    private var themeSidebarTint: Color {
        selectedThemeOption.sidebarTint
    }

    private var themeRowTint: Color {
        selectedThemeOption.rowTint
    }

    private var activeProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { !isExternalProvider($0) && !isLoginNeeded($0) && !isWaitingForRecovery($0) })
    }

    private var apiProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { isExternalProvider($0) })
    }

    private var loginProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { !isExternalProvider($0) && isLoginNeeded($0) })
    }

    private var waitingProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { !isExternalProvider($0) && !isLoginNeeded($0) && isWaitingForRecovery($0) })
    }

    private func sortedProfileList(_ input: [CodexProfile]) -> [CodexProfile] {
        input.sorted { lhs, rhs in
            let leftRank = profileSortRank(lhs)
            let rightRank = profileSortRank(rhs)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            let leftName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if leftName != .orderedSame {
                return leftName == .orderedAscending
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private func profileDockInfluence(forIndex index: Int, hoveredIndex: Int?) -> CGFloat {
        guard let hoveredIndex else { return 0 }
        let distance = CGFloat(abs(index - hoveredIndex)) * scaled(76)
        let radius = max(scaled(220), 1)
        let raw = max(0, 1 - distance / radius)
        return CGFloat(pow(Double(raw), 1.12))
    }

    private func profileDockScale(forInfluence influence: CGFloat) -> CGFloat {
        guard influence > 0 else { return 1 }
        return 1 + 0.074 * influence
    }

    private func profileDockGlowOpacity(forInfluence influence: CGFloat) -> Double {
        return 0.24 * influence
    }

    private func isProfileDockFocused(index: Int, hoveredIndex: Int?) -> Bool {
        guard let hoveredIndex else { return false }
        return index == hoveredIndex
    }

    private func updateHoveredProfile(_ profileID: String, hovering: Bool) {
        if hovering {
            withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.70, blendDuration: 0.08)) {
                hoveredProfileID = profileID
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            guard hoveredProfileID == profileID else { return }
            withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.74, blendDuration: 0.08)) {
                hoveredProfileID = nil
            }
        }
    }

    private func clearHoveredProfileSoon() {
        let current = hoveredProfileID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard hoveredProfileID == current else { return }
            withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.74, blendDuration: 0.08)) {
                hoveredProfileID = nil
            }
        }
    }

    private func setHoveredProfile(_ profileID: String?) {
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.70, blendDuration: 0.08)) {
            hoveredProfileID = profileID
        }
    }

    private func isWaitingForRecovery(_ profile: CodexProfile) -> Bool {
        if isExternalProvider(profile) {
            return false
        }
        return quotaWindows(for: profile).contains { $0.percent == 0 }
    }

    private func isExternalProvider(_ profile: CodexProfile) -> Bool {
        profile.authMode == "external" || profile.quota == "external" || profile.reset.hasPrefix("aliyun:")
    }

    private func isSignedIn(_ profile: CodexProfile) -> Bool {
        if isExternalProvider(profile) {
            return true
        }
        return profile.authStatus == "signed_in_local"
    }

    private func isLoginNeeded(_ profile: CodexProfile) -> Bool {
        if isExternalProvider(profile) {
            return false
        }
        if profile.authStatus == "auth_invalid" {
            return true
        }
        if profileHasLocalAuthTokens(profile) {
            return false
        }
        return profile.authStatus == "login_needed" || profile.authStatus == "auth_incomplete"
    }

    private func isVisiblySignedIn(_ profile: CodexProfile) -> Bool {
        if isExternalProvider(profile) {
            return true
        }
        if profile.authStatus == "auth_invalid" {
            return false
        }
        return isSignedIn(profile) || profileHasLocalAuthTokens(profile) || (!isLoginNeeded(profile) && profile.quota != "unknown")
    }

    private func mergedAuthStatus(previous: String, current: String) -> String {
        if current == "auth_invalid" {
            return current
        }
        if current == "signed_in_local" {
            return current
        }
        if previous == "auth_invalid", current == "unknown" || current == "checking" {
            return previous
        }
        if previous == "unknown" || previous == "checking" {
            return current
        }
        return previous
    }

    private func profileSortRank(_ profile: CodexProfile) -> Int {
        let windows = quotaWindows(for: profile)
        if windows.contains(where: { $0.id == "5h" && $0.percent != nil }) {
            return 0
        }
        if windows.contains(where: { $0.id == "7d" && $0.percent != nil }) {
            return 1
        }
        return 2
    }

    private var loadingOverlay: some View {
        let message = loadingDisplayMessage

        return GeometryReader { geometry in
            let visibleSize = visibleOverlaySize(fallback: geometry.size)
            let edgeInset = scaled(18)
            let availableWidth = max(scaled(72), visibleSize.width - edgeInset * 2)

            ZStack(alignment: .bottomTrailing) {
                if activeOperationCount > 0 {
                    loadingPill(message: message, availableWidth: availableWidth)
                        .padding(.trailing, edgeInset)
                        .padding(.bottom, edgeInset)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
            }
            .frame(width: visibleSize.width, height: visibleSize.height, alignment: .bottomTrailing)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: activeOperationCount)
    }

    private func visibleOverlaySize(fallback: CGSize) -> CGSize {
        let measured = visibleContentSize
        let width = measured.width > 1 ? min(fallback.width, measured.width) : fallback.width
        let height = measured.height > 1 ? min(fallback.height, measured.height) : fallback.height
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private func runPeriodicMaintenance() {
        guard activeOperationCount == 0 else { return }
        let now = Date()

        if autoSync,
           !isSyncing,
           now.timeIntervalSince(launchedAt) >= autoSyncStartupDelay,
           now.timeIntervalSince(lastAutoSyncAt) >= autoSyncInterval {
            syncMemories(silent: true)
            return
        }

        if autoRefresh, !isRefreshing {
            refreshProfilesForAutoQuota()
        }
    }

    private func refreshProfilesForAutoQuota() {
        let shouldUseLiveQuota = Date().timeIntervalSince(lastAutoQuotaRefreshAt) >= autoQuotaLiveRefreshInterval
        if shouldUseLiveQuota {
            lastAutoQuotaRefreshAt = Date()
        }

        refreshProfiles(
            showLoading: false,
            replayQuota: false,
            liveUsage: shouldUseLiveQuota,
            liveParallelism: shouldUseLiveQuota ? liveUsageParallelism : 2,
            statusTimeout: shouldUseLiveQuota ? liveUsageStatusTimeout : 8,
            respectBackoff: true
        )
    }

    private func scheduleLiveUsageBackfillIfNeeded(_ refreshedProfiles: [CodexProfile], triggeredByLiveUsage: Bool) {
        guard !triggeredByLiveUsage else { return }
        let now = Date()
        let needsResetCreditBackfill = refreshedProfiles.contains(where: needsResetCreditExpiryBackfill)
        guard refreshedProfiles.contains(where: needsLiveUsageBackfill) else { return }

        if needsResetCreditBackfill {
            guard now.timeIntervalSince(lastResetCreditBackfillAt) >= resetCreditLiveBackfillInterval else { return }
            lastResetCreditBackfillAt = now
        } else {
            guard now.timeIntervalSince(lastAutoQuotaRefreshAt) >= autoQuotaLiveRefreshInterval else { return }
            lastAutoQuotaRefreshAt = now
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !isRefreshing else { return }
            refreshProfiles(
                showLoading: false,
                replayQuota: false,
                liveUsage: true,
                liveParallelism: liveUsageParallelism,
                statusTimeout: liveUsageStatusTimeout
            )
        }
    }

    private func needsLiveUsageBackfill(_ profile: CodexProfile) -> Bool {
        guard !isExternalProvider(profile),
              profileHasLocalAuthTokens(profile),
              profile.authStatus != "auth_invalid",
              profile.authStatus != "auth_incomplete",
              !isLoginNeeded(profile)
        else {
            return false
        }

        if profile.quota == "unknown" {
            return true
        }

        return resetCreditCountLacksExpiries(profile.resetCredits)
    }

    private func needsResetCreditExpiryBackfill(_ profile: CodexProfile) -> Bool {
        guard !isExternalProvider(profile),
              profileHasLocalAuthTokens(profile),
              profile.authStatus != "auth_invalid",
              profile.authStatus != "auth_incomplete",
              !isLoginNeeded(profile)
        else {
            return false
        }

        return resetCreditCountLacksExpiries(profile.resetCredits)
    }

    private func resetCreditCountLacksExpiries(_ raw: String) -> Bool {
        resetCreditCountNeedsExpiryBackfill(raw)
    }

    private var loadingDisplayMessage: String {
        loadingMessage.isEmpty ? tr("處理中...", "Working...") : loadingMessage
    }

    private func loadingPill(message: String, availableWidth: CGFloat) -> some View {
        let progressSize = scaled(16)
        let spacing = scaled(10)
        let horizontalPadding = scaled(14)
        let textWidth = loadingTextWidth(
            for: message,
            maximum: availableWidth - progressSize - spacing - horizontalPadding * 2
        )
        let pillWidth = min(availableWidth, progressSize + spacing + textWidth + horizontalPadding * 2)

        return HStack(spacing: spacing) {
            ProgressView()
                .controlSize(.small)
                .frame(width: progressSize, height: progressSize)
            Text(message)
                .font(appFont(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: textWidth, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, scaled(10))
        .frame(width: pillWidth, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(themeMainTint.opacity(0.26))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(themePrimary.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
    }

    private func loadingTextWidth(for message: String, maximum: CGFloat) -> CGFloat {
        let maximum = max(0, min(maximum, scaled(300)))
        guard maximum > 0 else { return 0 }
        let minimum = min(scaled(24), maximum)
        let font = NSFont.systemFont(ofSize: scaled(12), weight: .semibold)
        let measured = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        return min(max(measured, minimum), maximum)
    }

    private var appBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: themeBackgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [themePrimary.opacity(0.18), Color.clear], center: .topTrailing, startRadius: 70, endRadius: 560)
            RadialGradient(colors: [themeSecondary.opacity(0.13), Color.clear], center: .topLeading, startRadius: 50, endRadius: 430)
            RadialGradient(colors: [themeWarm.opacity(0.10), Color.clear], center: .bottomLeading, startRadius: 70, endRadius: 520)
            RadialGradient(colors: [Color.black.opacity(0.14), Color.clear], center: .bottomTrailing, startRadius: 90, endRadius: 620)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: appTheme)
    }

    private var introView: some View {
        VStack(alignment: .leading, spacing: scaled(18)) {
            HStack(spacing: scaled(12)) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: scaled(52), height: scaled(52))
                    .clipShape(RoundedRectangle(cornerRadius: scaled(14), style: .continuous))

                VStack(alignment: .leading, spacing: scaled(4)) {
                    Text(tr("快速開始", "Quick Start"))
                        .font(appFont(size: 24, weight: .semibold))
                    Text(tr("多帳戶登入；對話紀錄預設分開，需要時先共享。", "Separate logins; local history is separate unless shared."))
                        .font(appFont(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: scaled(11)) {
                introPoint("1.circle.fill", tr("撳右上角 + 新增 profile，逐個登入唔同 GPT 帳戶。", "Use + to add profiles, then log each one into a different GPT account."))
                introPoint("2.circle.fill", tr("切換帳戶前，先撳右上角紅色關閉全部，再打開你要用嗰個 profile。", "Before switching accounts, press the red close-all button, then open the profile you want."))
                introPoint("3.circle.fill", tr("卡片中間會顯示 5H / 1W / 1M 用量；紅色代表等待恢復。", "The card shows 5H / 1W / 1M usage; red means it is waiting for reset."))
                introPoint("4.circle.fill", tr("頂部三段掣可以快速跳去：已登入、未登入、等待恢復。", "The segmented control jumps to Signed in, Login needed, and Waiting sections."))
                introPoint("5.circle.fill", tr("開啟 profile 前會先補齊本機對話索引；共享全部會令所有 profile 共用同一份本機對話紀錄。", "Before a profile opens, its local conversation index is synchronized. Share all links every profile to one local chat history."))
                introPoint("6.circle.fill", tr("防睡眠會阻止 Mac 喺長任務期間自動睡眠。", "Keep Awake prevents Mac sleep during long tasks."))
            }

            HStack {
                Spacer()
                Button(tr("開始使用", "Get Started")) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                        showIntro = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(scaled(24))
        .frame(width: scaled(440))
    }

    private func introPoint(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: scaled(10)) {
            Image(systemName: icon)
                .font(.system(size: scaled(14), weight: .semibold))
                .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 1.00))
                .frame(width: scaled(22), height: scaled(22))
            Text(text)
                .font(appFont(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mainPane: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: scaled(14)) {
                header

                ScrollView {
                    profilesList
                        .padding(.bottom, scaled(96))
                }
                .scrollIndicators(.automatic)
                .safeAreaInset(edge: .trailing) {
                    Color.clear.frame(width: profileScrollBarReserve)
                }
                .onChange(of: pendingSectionScroll) { _, target in
                    guard let target else { return }
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    pendingSectionScroll = nil
                }
            }
            .padding(.top, scaled(56))
            .padding(.bottom, 0)
            .padding(.leading, scaled(24))
            .padding(.trailing, scaled(14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    themeMainTint.opacity(0.16)
                    LinearGradient(
                        colors: [
                            themePrimary.opacity(0.060),
                            themeWarm.opacity(0.035),
                            Color.black.opacity(0.020)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            )
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: scaled(48))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: scaled(16)) {
                    HStack(alignment: .center, spacing: scaled(12)) {
                        appIconView
                        languageSwitcher
                    }

                    VStack(alignment: .leading, spacing: scaled(8)) {
                        Text(tr("Codex 帳戶", "Codex Accounts"))
                            .font(appFont(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(tr("多帳戶登入，紀錄預設分開。", "Separate logins. Separate local history by default."))
                            .font(appFont(size: 13))
                            .foregroundStyle(.white.opacity(0.64))
                            .lineSpacing(scaled(3))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }

                    sidebarSettings
                }
                .padding(.top, scaled(14))
                .padding(.bottom, scaled(22))
                .padding(.leading, scaled(28))
                .padding(.trailing, scaled(24))
                .frame(width: scaled(272), alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .scrollClipDisabled(false)
        }
        .frame(width: scaled(272), alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                themeSidebarTint.opacity(0.28)
                LinearGradient(
                    colors: [
                        themePrimary.opacity(0.10),
                        themeWarm.opacity(0.055),
                        Color.black.opacity(0.030)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(colors: [themeSecondary.opacity(0.16), Color.clear], center: .topLeading, startRadius: 20, endRadius: 260)
            }
        )
    }

    private var appIconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scaled(23), style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: scaled(23), style: .continuous)
                .fill(Color.black.opacity(0.08))

            RoundedRectangle(cornerRadius: scaled(23), style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)

            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: scaled(70), height: scaled(70))
                .clipShape(RoundedRectangle(cornerRadius: scaled(18), style: .continuous))
        }
        .frame(width: scaled(86), height: scaled(86))
        .clipShape(RoundedRectangle(cornerRadius: scaled(23), style: .continuous))
        .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 8)
    }

    private var languageSwitcher: some View {
        let current = selectedLanguage
        let menuWidth = scaled(118)
        let expandedHeight = scaled(54 + CGFloat(AppLanguage.allCases.count) * 45)

        return ZStack(alignment: .topLeading) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    showLanguageMenu.toggle()
                }
            } label: {
                HStack(spacing: scaled(7)) {
                    Text(current.flag)
                        .font(.system(size: scaled(13)))
                        .frame(width: scaled(18), alignment: .center)

                    VStack(alignment: .leading, spacing: scaled(1)) {
                        Text(current.shortTitle)
                            .font(appFont(size: 11, weight: .heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                        Text(tr("語言", "Language"))
                            .font(appFont(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.46))
                            .lineLimit(1)
                    }

                    Spacer(minLength: scaled(2))

                    Image(systemName: "chevron.down")
                        .font(.system(size: scaled(9), weight: .bold))
                        .rotationEffect(.degrees(showLanguageMenu ? 180 : 0))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(.horizontal, scaled(10))
                .frame(width: menuWidth, height: scaled(42), alignment: .leading)
                .background(.ultraThinMaterial)
                .background(
                    LinearGradient(
                        colors: [current.accent.opacity(0.28), Color.white.opacity(0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: scaled(16), style: .continuous)
                        .stroke(current.accent.opacity(0.38), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.92, hoverScale: 1.035, glow: current.accent, glowOpacity: 0.20))
            .foregroundStyle(.white)
            .zIndex(2)

            if showLanguageMenu {
                languageMenuPanel
                    .padding(.top, scaled(48))
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.92, anchor: .topLeading))
                                .combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
                        )
                    )
                    .zIndex(3)
            }
        }
        .frame(width: menuWidth, height: showLanguageMenu ? expandedHeight : scaled(42), alignment: .topLeading)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: showLanguageMenu)
        .zIndex(showLanguageMenu ? 10 : 1)
    }

    private var languageMenuPanel: some View {
        VStack(spacing: scaled(5)) {
            ForEach(AppLanguage.allCases) { item in
                languageMenuRow(item)
            }
        }
        .padding(scaled(6))
        .frame(width: scaled(118), alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(
            LinearGradient(
                colors: [selectedLanguage.accent.opacity(0.22), themeMainTint.opacity(0.18), Color.black.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(18), style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(18), style: .continuous))
        .shadow(color: selectedLanguage.accent.opacity(0.18), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
    }

    private func languageMenuRow(_ item: AppLanguage) -> some View {
        let selected = selectedLanguage == item

        return Button {
            setLanguage(item)
        } label: {
            HStack(spacing: scaled(8)) {
                Text(item.flag)
                    .font(.system(size: scaled(13)))
                    .frame(width: scaled(18), alignment: .center)

                VStack(alignment: .leading, spacing: scaled(1)) {
                    Text(item.shortTitle)
                        .font(appFont(size: 10, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Text(item.subtitle)
                        .font(appFont(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 0.74 : 0.46))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }

                Spacer(minLength: scaled(2))

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: scaled(11), weight: .semibold))
                    .foregroundStyle(selected ? item.accent : .white.opacity(0.26))
            }
            .padding(.horizontal, scaled(8))
            .frame(width: scaled(106), height: scaled(40), alignment: .leading)
            .background(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: scaled(13), style: .continuous)
                            .fill(item.accent.opacity(0.24))
                            .matchedGeometryEffect(id: "languageSelection", in: languageNamespace)
                    } else {
                        RoundedRectangle(cornerRadius: scaled(13), style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: scaled(13), style: .continuous)
                    .stroke(selected ? item.accent.opacity(0.44) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: scaled(13), style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: scaled(13), style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.94, hoverScale: 1.025, glow: item.accent, glowOpacity: selected ? 0.20 : 0.11))
        .foregroundStyle(selected ? .white : .white.opacity(0.78))
    }

    private func setLanguage(_ item: AppLanguage) {
        guard selectedLanguage != item else {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                showLanguageMenu = false
            }
            return
        }

        let oldLanguage = selectedLanguage
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            showLanguageMenu = false
            languageTransitionActive = true
            languagePulse.toggle()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.easeInOut(duration: 0.22)) {
                language = item.rawValue
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.74) {
            withAnimation(.easeInOut(duration: 0.24)) {
                languageTransitionActive = false
            }
        }
        statusText = AppTextLocalizer.localized("語言已切換：\(item.displayTitle)", "Language: \(item.displayTitle)", language: oldLanguage)
    }

    private var languageTransitionOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .ignoresSafeArea()

            VStack(spacing: scaled(12)) {
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(selectedLanguage.accent.opacity(0.34 - Double(index) * 0.08), lineWidth: scaled(1.2))
                            .frame(width: scaled(CGFloat(42 + index * 16)), height: scaled(CGFloat(42 + index * 16)))
                            .scaleEffect(languagePulse ? 1.10 : 0.88)
                            .opacity(languagePulse ? 0.16 : 0.72)
                            .animation(
                                .easeInOut(duration: 0.62)
                                    .delay(Double(index) * 0.07),
                                value: languagePulse
                            )
                    }

                    HStack(spacing: scaled(5)) {
                        ForEach(0..<4, id: \.self) { index in
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [selectedLanguage.accent, themeSecondary, Color.white.opacity(0.88)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: scaled(5), height: scaled(languagePulse ? 18 + CGFloat((index % 2) * 8) : 10 + CGFloat((index % 2) * 6)))
                                .animation(
                                    .easeInOut(duration: 0.34)
                                        .repeatCount(2, autoreverses: true)
                                        .delay(Double(index) * 0.055),
                                    value: languagePulse
                                )
                        }
                    }
                }
                .frame(width: scaled(92), height: scaled(74))

                Text(tr("切換語言...", "Switching language..."))
                    .font(appFont(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, scaled(22))
            .padding(.vertical, scaled(18))
            .background(.ultraThinMaterial)
            .background(selectedLanguage.accent.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: scaled(24), style: .continuous)
                    .stroke(selectedLanguage.accent.opacity(0.34), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: scaled(24), style: .continuous))
            .shadow(color: selectedLanguage.accent.opacity(0.18), radius: 26, x: 0, y: 12)
            .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 14)
        }
        .allowsHitTesting(false)
    }

    private var sidebarSettings: some View {
        VStack(alignment: .leading, spacing: scaled(9)) {
            dailyUsagePanel

            sidebarDisclosureSection(
                title: tr("自動化", "Automation"),
                systemName: "bolt.fill",
                subtitle: syncSummaryText,
                accent: syncAccent,
                expanded: $sidebarAutomationExpanded
            ) {
                HStack(spacing: scaled(6)) {
                    Image(systemName: autoSync ? "checkmark.circle.fill" : "pause.circle.fill")
                        .font(.system(size: scaled(10), weight: .semibold))
                        .foregroundStyle(syncAccent)
                    Text(autoSync ? tr("對話同步已開啟", "History sync on") : tr("對話同步已暫停", "History sync paused"))
                        .font(appFont(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer(minLength: 0)
                    syncInfoIcon
                }

                sidebarToggle(tr("每分鐘重新整理", "Auto refresh"), isOn: $autoRefresh, tint: Color(red: 0.20, green: 0.64, blue: 1.00))
                sidebarToggle(tr("每 10 分鐘同步", "Sync every 10 min"), isOn: $autoSync, tint: syncAccent)

                HStack(spacing: scaled(8)) {
                    miniButton(tr("立即同步", "Sync now")) { syncMemories() }
                    miniButton(tr("同步共享 Profile", "Sync shared profiles")) { shareAll() }
                }
            }

            sidebarDisclosureSection(
                title: tr("系統工具", "System Tools"),
                systemName: "switch.2",
                subtitle: systemToolsSummary,
                accent: keepAwake.isAwake ? keepAwakeModeAccent : (keyboardClean.isLocked ? Color(red: 0.00, green: 0.88, blue: 0.68) : Color.white.opacity(0.62)),
                expanded: $sidebarToolsExpanded
            ) {
                keepAwakePanel
                Divider().background(Color.white.opacity(0.10))
                keyboardCleanPanel
                Divider().background(Color.white.opacity(0.10))
                HStack(spacing: scaled(8)) {
                    miniButton(isRepairingHistoryPayloads ? tr("清理中", "Cleaning") : tr("清理大對話", "Clean large chats")) {
                        repairLargeHistoryPayloads()
                    }
                    miniButton(isCleaningSidebarState ? tr("整理中", "Cleaning") : tr("整理側欄", "Clean sidebar")) {
                        cleanupSidebarProjects()
                    }
                }
            }

            sidebarDisclosureSection(
                title: tr("外觀", "Appearance"),
                systemName: "paintpalette.fill",
                subtitle: themeTitle,
                accent: themePrimary,
                expanded: $sidebarAppearanceExpanded
            ) {
                themeSelector
            }

            sidebarDisclosureSection(
                title: tr("更新", "Updates"),
                systemName: updater.updateAvailable ? "arrow.down.app.fill" : "checkmark.seal.fill",
                subtitle: updateSummaryText,
                accent: updater.updateAvailable ? Color(red: 0.00, green: 0.90, blue: 0.78) : Color.white.opacity(0.62),
                expanded: $sidebarUpdatesExpanded
            ) {
                updatePanel
            }

            Text(statusText)
                .font(appFont(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(scaled(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(themeSidebarTint.opacity(0.22))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(16), style: .continuous)
                .stroke(themePrimary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
    }

    private var systemToolsSummary: String {
        let awake: String
        switch keepAwake.mode {
        case .off: awake = tr("防睡眠關", "Awake off")
        case .display: awake = tr("開屏防睡眠", "Screen awake")
        case .clamshell: awake = tr("合蓋防睡眠", "Lid awake")
        }
        let clean = keyboardClean.isLocked ? tr("清潔開", "Clean on") : tr("清潔關", "Clean off")
        return "\(awake) · \(clean)"
    }

    private func sidebarDisclosureSection<Content: View>(
        title: String,
        systemName: String,
        subtitle: String,
        accent: Color,
        expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: scaled(8)) {
                    Image(systemName: systemName)
                        .font(.system(size: scaled(11), weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent)
                        .frame(width: scaled(18), height: scaled(18))

                    VStack(alignment: .leading, spacing: scaled(1)) {
                        Text(title)
                            .font(appFont(size: 12, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(appFont(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: scaled(4))

                    Image(systemName: "chevron.down")
                        .font(.system(size: scaled(9), weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
                }
                .padding(.horizontal, scaled(9))
                .padding(.vertical, scaled(8))
                .background(.ultraThinMaterial)
                .background(accent.opacity(expanded.wrappedValue ? 0.105 : 0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                        .stroke(accent.opacity(expanded.wrappedValue ? 0.28 : 0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.94, hoverScale: 1.018, glow: accent, glowOpacity: 0.14))

            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    content()
                }
                .padding(.horizontal, scaled(2))
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.985, anchor: .top)),
                        removal: .opacity.combined(with: .move(edge: .top))
                    )
                )
            }
        }
    }

    private var updateSummaryText: String {
        if updater.isInstalling {
            return tr("正在安裝", "Installing")
        }
        if updater.isChecking {
            return tr("檢查中", "Checking")
        }
        if let release = updater.availableRelease, updater.updateAvailable {
            return tr("可更新至 \(release.tagName)", "\(release.tagName) available")
        }
        return tr("目前 \(updater.currentVersion)", "Current \(updater.currentVersion)")
    }

    private var updatePanel: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(8)) {
                VStack(alignment: .leading, spacing: scaled(2)) {
                    Text(tr("目前版本", "Current"))
                        .font(appFont(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                    Text("V\(updater.currentVersion)")
                        .font(appFont(size: 13, weight: .heavy, monospaced: true))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }

                Spacer(minLength: scaled(8))

                VStack(alignment: .trailing, spacing: scaled(2)) {
                    Text(tr("更新通道", "Channel"))
                        .font(appFont(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                    Text("GitHub")
                        .font(appFont(size: 13, weight: .heavy))
                        .foregroundStyle(Color(red: 0.00, green: 0.90, blue: 0.78))
                        .lineLimit(1)
                }
            }

            if !updater.statusText.isEmpty {
                Text(updater.statusText)
                    .font(appFont(size: 10, weight: .medium))
                    .foregroundStyle(updater.updateAvailable ? Color(red: 0.00, green: 0.90, blue: 0.78) : .white.opacity(0.48))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }

            HStack(spacing: scaled(8)) {
                miniButton(tr("檢查更新", "Check")) {
                    updater.checkForUpdates(presentNoUpdate: true, notifyIfAvailable: true)
                }
                .disabled(updater.isChecking || updater.isInstalling)

                miniButton(updater.updateAvailable ? tr("下載並更新", "Install") : tr("自動更新", "Auto update")) {
                    updater.installAvailableUpdate()
                }
                .disabled(updater.isChecking || updater.isInstalling || !updater.updateAvailable)
                .opacity(updater.updateAvailable ? 1 : 0.56)
            }
        }
    }

    private var keepAwakeHelpText: String {
        tr(
            "三個級別：\n關閉：跟隨 macOS。\n開屏：螢幕打開時防止熄屏同睡眠。\n合蓋：合埋螢幕仍保持任務運行，需要 macOS 管理員確認。\n\nApp 唔會儲存管理員密碼；離開合蓋模式時亦會恢復系統設定。",
            "Three levels:\nOff: follow macOS settings.\nScreen: prevent display and system sleep while the lid is open.\nLid: keep tasks running with the lid closed; macOS administrator approval is required.\n\nThe app never stores the administrator password and restores the system setting when leaving Lid mode."
        )
    }

    private var keepAwakeModeTitle: String {
        switch keepAwake.mode {
        case .off: return tr("已關閉", "Off")
        case .display: return tr("開屏防睡眠", "Screen awake")
        case .clamshell: return tr("合蓋繼續運行", "Lid closed")
        }
    }

    private var keepAwakeModeAccent: Color {
        switch keepAwake.mode {
        case .off: return Color(red: 0.58, green: 0.63, blue: 0.70)
        case .display: return Color(red: 0.08, green: 0.84, blue: 0.74)
        case .clamshell: return Color(red: 0.70, green: 0.40, blue: 1.00)
        }
    }

    private var keepAwakeModeDescription: String {
        switch keepAwake.mode {
        case .off:
            return tr("跟隨 macOS 原本睡眠設定", "Uses the normal macOS sleep settings")
        case .display:
            return tr("開住螢幕時唔會熄屏或睡眠", "Prevents display and system sleep while open")
        case .clamshell:
            return tr("合埋螢幕都保持任務運行", "Keeps tasks running after the lid is closed")
        }
    }

    private var keepAwakePanel: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(6)) {
                Text(tr("防睡眠模式", "Keep Awake Mode"))
                    .font(appFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                keepAwakeInfoIcon
                Spacer(minLength: scaled(6))
                if keepAwake.isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(keepAwakeModeTitle)
                        .font(appFont(size: 10, weight: .heavy))
                        .foregroundStyle(keepAwakeModeAccent)
                        .lineLimit(1)
                }
            }

            KeepAwakeLevelSlider(
                mode: Binding<KeepAwakeMode>(
                    get: { keepAwake.mode },
                    set: { keepAwake.setMode($0) }
                ),
                isEnabled: !keepAwake.isSwitching,
                accessibilityLabelText: tr("防睡眠級別", "Keep Awake level"),
                accessibilityValueText: keepAwakeModeTitle
            )

            HStack(spacing: 0) {
                Text(tr("關閉", "Off"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(keepAwake.mode == .off ? keepAwakeModeAccent : Color.white.opacity(0.40))
                Text(tr("開屏", "Screen"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(keepAwake.mode == .display ? keepAwakeModeAccent : Color.white.opacity(0.40))
                Text(tr("合蓋", "Lid"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(keepAwake.mode == .clamshell ? keepAwakeModeAccent : Color.white.opacity(0.40))
            }
            .font(appFont(size: 9, weight: .semibold))

            HStack(spacing: scaled(5)) {
                Image(systemName: keepAwake.mode == .clamshell ? "lock.shield.fill" : (keepAwake.mode == .display ? "sun.max.fill" : "moon.zzz.fill"))
                    .font(.system(size: scaled(9), weight: .semibold))
                    .foregroundStyle(keepAwakeModeAccent)
                Text(keepAwakeModeDescription)
                    .font(appFont(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(2)
                }
        }
        .help(keepAwakeHelpText)
    }

    private var keyboardCleanHelpText: String {
        tr(
            "打開後會攔截鍵盤輸入，方便清潔鍵盤。滑鼠同觸控板仍然可以用，所以可以用滑鼠撳返呢粒掣關閉。",
            "Blocks keyboard input for keyboard cleaning. Mouse and trackpad remain usable, so turn it off with the pointer."
        )
    }

    private var keyboardCleanPanel: some View {
        let active = keyboardClean.isLocked
        let accent = active ? Color(red: 0.00, green: 0.88, blue: 0.72) : Color(red: 0.52, green: 0.58, blue: 0.66)

        return HStack(spacing: scaled(10)) {
            VStack(alignment: .leading, spacing: scaled(3)) {
                HStack(spacing: scaled(5)) {
                    Text(tr("電腦清潔", "Clean Mode"))
                        .font(appFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                    keyboardCleanInfoIcon
                }
                Text(active ? tr("鍵盤已鎖", "Keyboard locked") : tr("鍵盤正常", "Keyboard normal"))
                    .font(appFont(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color(red: 0.00, green: 0.95, blue: 0.78) : Color.white.opacity(0.46))
                    .lineLimit(1)
                if !keyboardClean.lastError.isEmpty {
                    Text(keyboardClean.lastError)
                        .font(appFont(size: 9))
                        .foregroundStyle(Color(red: 1.00, green: 0.35, blue: 0.32))
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }
            }

            Spacer(minLength: scaled(8))

            Button {
                keyboardClean.toggle()
            } label: {
                HStack(spacing: scaled(6)) {
                    if keyboardClean.isSwitching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: scaled(14), height: scaled(14))
                    } else {
                        Image(systemName: active ? "keyboard.badge.eye.fill" : "keyboard")
                            .font(.system(size: scaled(12), weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                        Text(active ? "ON" : "OFF")
                            .font(appFont(size: 10, weight: .heavy, monospaced: true))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.78))
                .frame(width: scaled(68), height: scaled(30))
                .background(.ultraThinMaterial)
                .background(
                    LinearGradient(
                        colors: [accent.opacity(active ? 0.34 : 0.16), Color.white.opacity(0.040)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.30), accent.opacity(active ? 0.58 : 0.30), Color.black.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.90, hoverScale: 1.04, glow: accent, glowOpacity: active ? 0.26 : 0.14))
            .disabled(keyboardClean.isSwitching)
            .opacity(keyboardClean.isSwitching ? 0.72 : 1)
            .help(keyboardCleanHelpText)
        }
    }

    private var dailyUsagePanel: some View {
        let seconds = currentUsageSeconds()
        let percent = min(max(seconds / 86_400, 0), 1)
        let label = usageDurationText(seconds)

        return VStack(alignment: .leading, spacing: scaled(7)) {
            HStack {
                Text(tr("今日使用", "Today"))
                    .font(appFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Text(label)
                    .font(appFont(size: 10, weight: .semibold, monospaced: true))
                    .foregroundStyle(themePrimary)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.11))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    themePrimary,
                                    themeSecondary,
                                    themeWarm
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * percent, percent > 0 ? scaled(6) : 0))
                }
            }
            .frame(height: scaled(8))
            .clipShape(Capsule())
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: usageTicker)

            HStack(spacing: scaled(5)) {
                Circle()
                    .fill(codexUsageSessionActive ? Color(red: 0.10, green: 0.90, blue: 0.66) : Color.white.opacity(0.32))
                    .frame(width: scaled(5), height: scaled(5))
                Text(codexUsageSessionActive ? tr("Codex 使用中", "Codex active") : tr("暫停計時", "Timer paused"))
                    .font(appFont(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer(minLength: scaled(4))
                Text(tr("睡眠／關機不計", "Sleep/offline excluded"))
                    .font(appFont(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
    }

    private var themeSelector: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: scaled(11)), count: 2)

        return VStack(alignment: .leading, spacing: scaled(6)) {
            HStack(spacing: scaled(6)) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: scaled(10), weight: .semibold))
                    .foregroundStyle(themePrimary.opacity(0.92))
                Text(tr("主題", "Theme"))
                    .font(appFont(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: scaled(6))
                Text(themeTitle)
                    .font(appFont(size: 10, weight: .semibold))
                    .foregroundStyle(themePrimary.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            LazyVGrid(columns: columns, spacing: scaled(10)) {
                ForEach(themeOptions) { option in
                    themeSwatchButton(option)
                }
            }
        }
        .padding(.horizontal, scaled(8))
        .padding(.vertical, scaled(7))
        .background(.ultraThinMaterial)
        .background(
            LinearGradient(
                colors: [themePrimary.opacity(0.10), Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                .stroke(themePrimary.opacity(0.20), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: appTheme)
    }

    private func themeSwatchButton(_ option: AppThemeOption) -> some View {
        let selected = appTheme == option.id

        return Button {
            setTheme(option.id)
        } label: {
            HStack(spacing: scaled(5)) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [option.primary, option.secondary, option.warm],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: scaled(22), height: scaled(22))
                    .overlay(Circle().stroke(Color.white.opacity(0.34), lineWidth: 1))
                    .shadow(color: option.primary.opacity(0.38), radius: scaled(5))

                Text(option.zhTitle)
                    .font(appFont(size: 10, weight: selected ? .heavy : .semibold))
                    .foregroundStyle(.white.opacity(selected ? 0.96 : 0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: scaled(10), weight: .bold))
                    .foregroundStyle(selected ? option.primary : Color.white.opacity(0.18))
                    .transition(.scale.combined(with: .opacity))
                }
            .padding(.horizontal, scaled(6))
            .frame(maxWidth: .infinity)
            .frame(height: scaled(40))
            .background(
                LinearGradient(
                    colors: [option.primary.opacity(selected ? 0.26 : 0.10), option.secondary.opacity(0.06), Color.black.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: scaled(9), style: .continuous)
                    .stroke(selected ? option.primary.opacity(0.82) : Color.white.opacity(0.12), lineWidth: selected ? 1.4 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: scaled(9), style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: scaled(9), style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96, hoverScale: 1.012, glow: option.primary, glowOpacity: selected ? 0.28 : 0.18))
        .help(option.zhTitle)
    }

    private func setTheme(_ theme: String) {
        showEphemeralLoading(tr("切換主題...", "Switching theme..."), duration: 0.30)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            appTheme = theme
        }
    }

    private var syncHelpText: String {
        tr(
            "立即同步：安全同步未使用中 profile 嘅對話索引同本機記憶；使用中 profile 會喺下次開啟前完成。\n\n共享全部：將所有 profile 連到同一份本機對話紀錄，再補齊可安全更新嘅索引。",
            "Sync now: safely updates conversation indexes and local memory for inactive profiles. Active profiles finish before their next launch.\n\nShare all: links every profile to one local history, then reconciles indexes that are safe to update."
        )
    }

    private var syncInfoIcon: some View {
        infoIcon(isPresented: $showSyncHelp, text: syncHelpText, width: 260)
    }

    private var keepAwakeInfoIcon: some View {
        infoIcon(isPresented: $showKeepAwakeHelp, text: keepAwakeHelpText, width: 238)
    }

    private var keyboardCleanInfoIcon: some View {
        infoIcon(isPresented: $showKeyboardCleanHelp, text: keyboardCleanHelpText, width: 238)
    }

    private func infoIcon(isPresented: Binding<Bool>, text: String, width: CGFloat) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            Image(systemName: "exclamationmark")
                .font(.system(size: scaled(8), weight: .heavy))
                .foregroundStyle(Color(red: 0.44, green: 0.83, blue: 1.00))
                .frame(width: scaled(16), height: scaled(16))
                .background(.ultraThinMaterial)
                .background(Color(red: 0.12, green: 0.50, blue: 0.95).opacity(0.14))
                .overlay(Circle().stroke(Color(red: 0.44, green: 0.83, blue: 1.00).opacity(0.34), lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.88))
        .help(text)
        .popover(isPresented: isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(appFont(size: 12, weight: .medium))
                .lineSpacing(scaled(4))
                .padding(scaled(12))
                .frame(width: scaled(width), alignment: .leading)
        }
    }

    private var header: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            let leadingInset = profileHoverPadding
            let trailingInset = profileRightAlignmentInset
            let compactContentWidth = max(0, geometry.size.width - leadingInset - trailingInset)
            let showCompactSectionJumps = compactContentWidth >= scaled(608)
            let compactReservedWidth = scaled(showCompactSectionJumps ? 374 : 232)
            let compactTitleWidth = min(scaled(292), max(scaled(218), compactContentWidth - compactReservedWidth))
            let titleWidth = compact ? compactTitleWidth : scaled(300)

            Group {
                if compact {
                    HStack(alignment: .center, spacing: scaled(9)) {
                        sidebarToggleButton

                        headerTitle
                            .frame(width: titleWidth, alignment: .leading)
                            .layoutPriority(3)

                        Spacer(minLength: scaled(8))

                        if showCompactSectionJumps {
                            sectionJumpControls(compact: true)
                                .layoutPriority(2)

                            Spacer(minLength: scaled(8))
                        }

                        headerActions(compact: true)
                            .layoutPriority(2)
                    }
                } else {
                    ZStack {
                        sectionJumpControls(compact: false)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, scaled(216))

                        HStack(alignment: .center, spacing: scaled(14)) {
                            sidebarToggleButton

                            headerTitle
                                .frame(width: titleWidth, alignment: .leading)
                                .layoutPriority(1)

                            Spacer(minLength: scaled(12))

                            headerActions(compact: false)
                                .layoutPriority(5)
                        }
                    }
                }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .frame(maxWidth: .infinity, minHeight: scaled(70), idealHeight: scaled(70), maxHeight: scaled(70), alignment: .center)
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                sidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: sidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                .font(.system(size: scaled(15), weight: .semibold))
                .frame(width: scaled(34), height: scaled(34))
                .contentShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.88, hoverScale: 1.055, glow: Color.white, glowOpacity: 0.18))
        .foregroundStyle(Color.white.opacity(0.78))
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
        .help(tr("收合側欄", "Toggle sidebar"))
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: scaled(6)) {
            Text(tr("帳戶", "Profiles"))
                .font(appFont(size: 28, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            VStack(alignment: .leading, spacing: scaled(1)) {
                Text(tr("選擇要開邊個 Codex 登入視窗。", "Choose an account window."))
                Text(autoRefresh
                    ? tr("登入狀態每分鐘更新。", "Login state refreshes every minute.")
                    : tr("登入狀態只會手動更新。", "Login state updates manually.")
                )
            }
            .font(appFont(size: 14))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.82)
            .allowsTightening(true)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func headerActions(compact: Bool) -> some View {
        HStack(spacing: scaled(compact ? 7 : 12)) {
            glassIconButton(systemName: "plus", label: tr("新增帳戶", "New Account"), compact: compact, accent: Color(red: 0.34, green: 0.78, blue: 1.00)) {
                createAccount()
            }

            glassIconButton(systemName: "arrow.clockwise", label: tr("重新整理", "Refresh"), compact: compact, accent: Color(red: 0.24, green: 0.95, blue: 0.78), isBusy: isRefreshing) {
                refreshProfiles(showLoading: true, replayQuota: false, liveUsage: true)
            }

            glassIconButton(systemName: "folder", label: tr("Profile 資料夾", "Profiles Folder"), compact: compact, accent: Color(red: 1.00, green: 0.74, blue: 0.26)) {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-accounts"))
            }

            closeAllIconButton(label: tr("關閉全部 Codex 視窗", "Close All Codex Windows"), compact: compact) {
                closeAllAccounts()
            }
        }
        .fixedSize()
    }

    private func sectionJumpControls(compact: Bool) -> some View {
        HStack(spacing: 0) {
            if !apiProfiles.isEmpty {
                sectionJumpButton(
                    systemName: "terminal",
                    label: tr("API 模型", "API models"),
                    sectionID: "section-api",
                    accent: Color(red: 0.10, green: 0.86, blue: 0.74),
                    compact: compact
                )
                sectionJumpDivider
            }
            sectionJumpButton(
                systemName: "checkmark.circle.fill",
                label: tr("已登入", "Signed in"),
                sectionID: "section-active",
                accent: Color(red: 0.12, green: 0.88, blue: 0.58),
                compact: compact
            )
            sectionJumpDivider
            sectionJumpButton(
                systemName: "person.crop.circle.badge.exclamationmark",
                label: tr("未登入", "Login needed"),
                sectionID: "section-login",
                accent: Color(red: 1.00, green: 0.55, blue: 0.12),
                compact: compact
            )
            sectionJumpDivider
            sectionJumpButton(
                systemName: "clock.arrow.circlepath",
                label: tr("等待恢復", "Waiting"),
                sectionID: "section-waiting",
                accent: Color(red: 1.00, green: 0.74, blue: 0.20),
                compact: compact
            )
        }
        .padding(scaled(4))
        .background(.ultraThinMaterial)
        .background(
            RoundedRectangle(cornerRadius: scaled(15), style: .continuous)
                .fill(Color.white.opacity(0.040))
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(15), style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(15), style: .continuous))
        .fixedSize()
    }

    private var sectionJumpDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: scaled(22))
    }

    private func sectionJumpButton(systemName: String, label: String, sectionID: String, accent: Color, compact: Bool) -> some View {
        Button {
            pendingSectionScroll = sectionID
        } label: {
            Image(systemName: systemName)
                .font(.system(size: scaled(compact ? 15 : 16), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: scaled(compact ? 38 : 48), height: scaled(compact ? 36 : 34))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.88, hoverScale: 1.06, glow: accent, glowOpacity: 0.24))
        .foregroundStyle(accent.opacity(0.95))
        .background(
            RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                .fill(accent.opacity(0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(11), style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(11), style: .continuous))
        .help(label)
    }

    private var profilesList: some View {
        let api = apiProfiles
        let active = activeProfiles
        let login = loginProfiles
        let waiting = waitingProfiles
        let orderedProfileIDs = (api + active + login + waiting).map(\.id)
        let hoveredIndex = hoveredProfileID.flatMap { orderedProfileIDs.firstIndex(of: $0) }

        return LazyVStack(spacing: 0) {
            if !api.isEmpty {
                sectionHeader(
                    id: "section-api",
                    systemName: "terminal",
                    title: tr("API", "API"),
                    accent: Color(red: 0.10, green: 0.86, blue: 0.74)
                )
                .padding(.top, scaled(2))

                ForEach(Array(api.enumerated()), id: \.element.id) { index, profile in
                    profileRow(profile, dockIndex: index, hoveredIndex: hoveredIndex)
                }
            }

            sectionHeader(
                id: "section-active",
                systemName: "checkmark.circle.fill",
                title: tr("已登入", "Signed in"),
                accent: Color(red: 0.16, green: 0.92, blue: 0.62)
            )
            .padding(.top, scaled(api.isEmpty ? 2 : 9))

            ForEach(Array(active.enumerated()), id: \.element.id) { index, profile in
                profileRow(profile, dockIndex: api.count + index, hoveredIndex: hoveredIndex)
            }

            sectionHeader(
                id: "section-login",
                systemName: "person.crop.circle.badge.exclamationmark",
                title: tr("未登入", "Login needed"),
                accent: Color(red: 1.00, green: 0.55, blue: 0.12)
            )
            .padding(.top, scaled(active.isEmpty ? 3 : 9))

            ForEach(Array(login.enumerated()), id: \.element.id) { index, profile in
                profileRow(profile, dockIndex: api.count + active.count + index, hoveredIndex: hoveredIndex)
            }

            sectionHeader(
                id: "section-waiting",
                systemName: "clock.arrow.circlepath",
                title: tr("等待恢復", "Waiting for Reset"),
                accent: Color(red: 1.00, green: 0.74, blue: 0.20)
            )
            .padding(.top, scaled(login.isEmpty ? 3 : 9))

            ForEach(Array(waiting.enumerated()), id: \.element.id) { index, profile in
                profileRow(profile, dockIndex: api.count + active.count + login.count + index, hoveredIndex: hoveredIndex)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.leading, profileHoverPadding)
        .padding(.trailing, profileHoverPadding)
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            if !hovering {
                clearHoveredProfileSoon()
            }
        }
    }

    private func sectionHeader(id: String, systemName: String, title: String, accent: Color) -> some View {
        HStack(spacing: scaled(10)) {
            HStack(spacing: scaled(6)) {
                Image(systemName: systemName)
                    .font(.system(size: scaled(14), weight: .semibold))
                Text(title)
                    .font(appFont(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, scaled(11))
            .padding(.vertical, scaled(5))
            .background(.ultraThinMaterial)
            .background(accent.opacity(0.16))
            .overlay(
                Capsule()
                    .stroke(accent.opacity(0.42), lineWidth: 1)
            )
            .clipShape(Capsule())

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.72), accent.opacity(0.18), Color.white.opacity(0.04)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: scaled(1.6))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, scaled(2))
        .padding(.top, scaled(10))
        .padding(.bottom, scaled(3))
        .id(id)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func profileRow(_ profile: CodexProfile, dockIndex: Int, hoveredIndex: Int?) -> some View {
        let dockInfluence = profileDockInfluence(forIndex: dockIndex, hoveredIndex: hoveredIndex)
        let dockScale = profileDockScale(forInfluence: dockInfluence)
        let dockGlowOpacity = profileDockGlowOpacity(forInfluence: dockInfluence)
        let dockFocused = isProfileDockFocused(index: dockIndex, hoveredIndex: hoveredIndex)

        return ViewThatFits(in: .horizontal) {
            regularProfileRowContent(profile)
                .frame(minWidth: scaled(780))

            compactProfileRowContent(profile)
        }
        .frame(maxWidth: .infinity, minHeight: scaled(profileRowMinimumHeight(for: profile)), alignment: .leading)
        .background(Color.white.opacity(0.040))
        .background(themeRowTint.opacity(profile.quota == "unknown" ? 0.030 : 0.085))
        .background(profileRowAccent(for: profile).opacity(profile.quota == "unknown" ? 0.020 : 0.074))
        .background(
            LinearGradient(
                colors: [themePrimary.opacity(0.050), themeWarm.opacity(0.032), Color.white.opacity(0.010)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            profileRowAccent(for: profile).opacity(profile.quota == "unknown" ? 0.42 : 0.92),
                            quotaAccent(for: profile).opacity(profile.quota == "unknown" ? 0.20 : 0.58)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: scaled(2.2)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: profileRowAccent(for: profile).opacity(profile.quota == "unknown" ? 0.04 : 0.08), radius: 5, x: 0, y: 2)
        .shadow(color: profileRowAccent(for: profile).opacity(dockGlowOpacity), radius: dockFocused ? 22 : 12, x: 0, y: dockFocused ? 8 : 4)
        .brightness(dockFocused ? 0.035 : (dockScale > 1 ? 0.016 : 0))
        .padding(.vertical, scaled(6))
        .contentShape(Rectangle())
        .onHover { hovering in
            updateHoveredProfile(profile.id, hovering: hovering)
        }
        .zIndex(Double(dockScale * 1000))
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: profile.quota)
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.72, blendDuration: 0.08), value: hoveredProfileID)
    }

    private func regularProfileRowContent(_ profile: CodexProfile) -> some View {
        HStack(spacing: scaled(10)) {
            profileBadge(profile)
                .layoutPriority(20)

            profileTitleBlock(profile, showsPath: true)
                .frame(minWidth: scaled(112), maxWidth: .infinity, alignment: .leading)
                .layoutPriority(18)

            Spacer(minLength: scaled(4))

            if isExternalProvider(profile) {
                externalProviderStatus(profile, compact: false)
                    .frame(width: scaled(430), alignment: .trailing)
                    .layoutPriority(30)
            } else {
                quotaMeter(profile, compact: false)
                    .frame(width: scaled(430), alignment: .trailing)
                    .layoutPriority(30)
            }

            openButton(profile)
                .frame(width: scaled(64))
                .layoutPriority(20)

            closeButton(profile)
                .frame(width: scaled(38))
                .layoutPriority(20)

            profileMenu(profile)
                .frame(width: scaled(44))
                .layoutPriority(20)
        }
        .padding(.horizontal, scaled(14))
        .padding(.vertical, scaled(isExternalProvider(profile) ? 0 : 6))
        .frame(maxWidth: .infinity, minHeight: scaled(profileRowMinimumHeight(for: profile)), alignment: .center)
    }

    private func profileRowMinimumHeight(for profile: CodexProfile) -> CGFloat {
        guard !isExternalProvider(profile) else { return 64 }
        guard let resetCredits = resetCreditSummary(for: profile), resetCredits.count > 0 else {
            return profile.quota == "unknown" ? 64 : 72
        }
        return expandedResetCreditProfileIDs.contains(profile.id) ? 148 : 88
    }

    private func compactProfileRowContent(_ profile: CodexProfile) -> some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(8)) {
                profileBadge(profile)
                    .layoutPriority(20)

                profileTitleBlock(profile, showsPath: false)
                    .frame(minWidth: scaled(118), maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(20)

                openButton(profile)
                    .frame(width: scaled(58))
                    .layoutPriority(20)

                closeButton(profile)
                    .frame(width: scaled(34))
                    .layoutPriority(20)

                profileMenu(profile)
                    .frame(width: scaled(40))
                    .layoutPriority(20)
            }

            if isExternalProvider(profile) {
                externalProviderStatus(profile, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                quotaMeter(profile, compact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, scaled(12))
        .padding(.vertical, scaled(10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileBadge(_ profile: CodexProfile) -> some View {
        let signedIn = isVisiblySignedIn(profile)
        let signedColor = Color(red: 0.20, green: 0.98, blue: 0.58)
        let loginColor = Color(red: 1.00, green: 0.52, blue: 0.12)
        let ringColor = signedIn ? signedColor : loginColor
        let ringWidth = scaled(7.0)

        return Button {
            chooseCustomIcon(for: profile)
        } label: {
            Image(nsImage: profileBadgeImage(for: profile))
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: scaled(38), height: scaled(38))
                .overlay(
                    RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .overlay(
                    StatusRingOverlay(
                        active: !signedIn,
                        color: ringColor,
                        cornerRadius: scaled(13),
                        lineWidth: ringWidth
                    )
                )
                .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 6)
                .clipShape(RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: scaled(14), style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.88, hoverScale: 1.08, glow: ringColor, glowOpacity: signedIn ? 0.24 : 0.34))
        .help(signedIn ? tr("已登入。點擊可自訂 Icon。", "Signed in. Click to customize icon.") : tr("需要登入。點擊可自訂 Icon。", "Login needed. Click to customize icon."))
    }

    private func profileBadgeImage(for profile: CodexProfile) -> NSImage {
        let customURL = customIconURL(for: profile.id)
        let customCacheKey = "custom:\(iconVersion):\(profile.id)"
        if let customImage = ProfileIconImageCache.shared.image(for: customCacheKey, load: {
            NSImage(contentsOf: customURL)
        }) {
            return customImage
        }
        let resourceName = "ProfileIcon-\(profileBadgeLetter(for: profile) ?? "Default")"
        if let image = ProfileIconImageCache.shared.image(for: "bundle:\(resourceName)", load: {
            guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png", subdirectory: "ProfileLetterIcons") else {
                return nil
            }
            return NSImage(contentsOf: url)
        }) {
            return image
        }
        return NSImage(named: "AppIcon") ?? NSImage()
    }

    private func customIconURL(for profileID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Codex Accounts/ProfileIcons", isDirectory: true)
            .appendingPathComponent("\(profileID).png")
    }

    private func profileBadgeLetter(for profile: CodexProfile) -> String? {
        let trimmed = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scalar = trimmed.uppercased().unicodeScalars.first else { return nil }
        guard scalar.value >= 65 && scalar.value <= 90 else { return nil }
        return String(Character(scalar))
    }

    private func profileTitleBlock(_ profile: CodexProfile, showsPath: Bool) -> some View {
        VStack(alignment: .leading, spacing: scaled(5)) {
            Text(profile.displayName)
                .font(appFont(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)

            if showsPath {
                Text(profile.home)
                    .font(appFont(size: 11, monospaced: true))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(true)
            }
        }
    }

    private func authBadge(_ profile: CodexProfile, compact: Bool = false) -> some View {
        let external = isExternalProvider(profile)
        let signedIn = isSignedIn(profile)
        let expired = profile.authStatus == "auth_invalid"
        let title = external
            ? (compact ? tr("外部", "External") : tr("阿里模型", "Aliyun"))
            : (signedIn
            ? tr("已登入", "Signed in")
            : (expired ? tr("登入過期", "Expired") : tr("需要登入", "Login needed")))
        let color = external
            ? Color(red: 0.10, green: 0.86, blue: 0.74)
            : (signedIn ? Color(red: 0.32, green: 0.96, blue: 0.46) : (expired ? Color(red: 1.00, green: 0.22, blue: 0.20) : Color.orange))

        return Text(title)
            .font(appFont(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(6))
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
            .minimumScaleFactor(0.72)
    }

    @ViewBuilder
    private func quotaMeter(_ profile: CodexProfile, compact: Bool) -> some View {
        let rows = quotaRows(for: quotaWindows(for: profile))
        let weeklyZero = rows.contains { $0.id == "7d" && $0.percent == 0 }
        let weeklyReset = rows.first { $0.id == "7d" }?.reset
        let resetCredits = resetCreditSummary(for: profile)
        let resetCreditsExpanded = expandedResetCreditProfileIDs.contains(profile.id)

        VStack(spacing: scaled(compact ? 5 : 7)) {
            if isLoginNeeded(profile) {
                quotaAuthenticationStatus(profile, compact: compact)
            } else if rows.count == 1, rows[0].id == "unknown" {
                quotaUnavailableStatus(compact: compact)
            } else {
                ForEach(rows) { window in
                    let blockedByWeekly = weeklyZero && window.id == "5h"
                    quotaMeterLine(
                        window,
                        profile: profile,
                        accent: blockedByWeekly ? Color(red: 1.00, green: 0.20, blue: 0.36) : quotaAccent(for: window.percent),
                        compact: compact,
                        blockedByWeeklyZero: blockedByWeekly,
                        forcedReset: blockedByWeekly ? weeklyReset : nil
                    )
                }
            }
            if let resetCredits, resetCredits.count > 0 {
                resetCreditsLine(resetCredits, profileID: profile.id, compact: compact, expanded: resetCreditsExpanded)
                if resetCreditsExpanded {
                    resetCreditsDetailPanel(resetCredits, compact: compact)
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, scaled(compact ? 1 : 5))
        .frame(maxWidth: .infinity, minHeight: scaled(resetCredits == nil ? 44 : (resetCreditsExpanded ? 138 : 84)), alignment: .center)
    }

    private func quotaAuthenticationStatus(_ profile: CodexProfile, compact: Bool) -> some View {
        let expired = profile.authStatus == "auth_invalid"
        let accent = expired ? Color(red: 1.00, green: 0.22, blue: 0.20) : Color.orange
        let action = expired
            ? tr("打開重新登入", "Open to sign in again")
            : tr("打開完成登入", "Open to finish sign-in")

        return HStack(spacing: scaled(compact ? 7 : 9)) {
            authBadge(profile, compact: compact)
                .frame(width: scaled(compact ? 82 : 96))

            Image(systemName: expired ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.questionmark")
                .font(.system(size: scaled(compact ? 12 : 13), weight: .semibold))
                .foregroundStyle(accent.opacity(0.88))

            Text(action)
                .font(appFont(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, scaled(compact ? 8 : 10))
        .padding(.vertical, scaled(compact ? 6 : 7))
        .frame(maxWidth: .infinity, minHeight: scaled(38), alignment: .leading)
        .background(accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
    }

    private func quotaUnavailableStatus(compact: Bool) -> some View {
        let accent = Color(red: 0.58, green: 0.64, blue: 0.74)

        return HStack(spacing: scaled(compact ? 7 : 9)) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: scaled(compact ? 12 : 13), weight: .semibold))
                .foregroundStyle(accent.opacity(0.88))

            Text(tr("暫時未能取得用量", "Usage is temporarily unavailable"))
                .font(appFont(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, scaled(compact ? 9 : 11))
        .padding(.vertical, scaled(compact ? 7 : 8))
        .frame(maxWidth: .infinity, minHeight: scaled(38), alignment: .leading)
        .background(accent.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
    }

    private func externalProviderStatus(_ profile: CodexProfile, compact: Bool) -> some View {
        let isOpenCodex = profile.reset.hasPrefix("opencodex:")
        let accent = isOpenCodex
            ? Color(red: 0.32, green: 0.68, blue: 1.00)
            : Color(red: 0.10, green: 0.86, blue: 0.74)
        let model: String
        if isOpenCodex {
            model = String(profile.reset.dropFirst("opencodex:".count))
        } else if profile.reset.hasPrefix("aliyun:") {
            model = String(profile.reset.dropFirst("aliyun:".count))
        } else {
            model = "qwen3.7-plus"
        }

        return HStack(alignment: .center, spacing: scaled(compact ? 8 : 10)) {
            apiStatusPill(
                title: isOpenCodex ? tr("本機代理", "Local proxy") : tr("外部 API", "External API"),
                accent: accent,
                compact: compact
            )
            apiStatusPill(
                title: isOpenCodex ? "OpenCodex" : "Coding Plan",
                accent: accent.opacity(0.82),
                compact: compact
            )
            Text(model)
                .font(appFont(size: compact ? 12 : 13, weight: .semibold, monospaced: true))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, scaled(compact ? 9 : 11))
        .padding(.vertical, scaled(compact ? 7 : 8))
        .frame(maxWidth: .infinity, minHeight: scaled(38), alignment: .leading)
        .background(accent.opacity(0.085))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
        .help(isOpenCodex
            ? tr("OpenCodex Lab 使用獨立本機 loopback 代理；本機對話可另外選擇共享。", "OpenCodex Lab uses an isolated local loopback proxy; local chats may be shared separately.")
            : tr("外部 API profile 不使用 OpenAI quota。", "External API profiles do not use OpenAI quota."))
    }

    private func apiStatusPill(title: String, accent: Color, compact: Bool) -> some View {
        Text(title)
            .font(appFont(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(accent.opacity(0.96))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, scaled(compact ? 7 : 9))
            .padding(.vertical, scaled(compact ? 4 : 5))
            .background(accent.opacity(0.12))
            .clipShape(Capsule())
    }

    private func quotaMeterLine(_ window: QuotaWindow, profile: CodexProfile, accent: Color, compact: Bool, blockedByWeeklyZero: Bool = false, forcedReset: String? = nil) -> some View {
        let resetText = blockedByWeeklyZero
            ? resetCaption(forcedReset, windowID: "5h", profileID: profile.id)
            : resetCaption(window.reset, windowID: window.id, profileID: profile.id)
        let tint = window.id == "5h" ? Color(red: 0.28, green: 0.78, blue: 1.00) : Color(red: 1.00, green: 0.74, blue: 0.20)
        let labelWidth = window.id == "unknown" ? scaled(compact ? 46 : 54) : scaled(compact ? 24 : 28)

        return HStack(alignment: .center, spacing: scaled(compact ? 3 : 4)) {
            Text(tr(window.labelZH, window.labelEN))
                .font(appFont(size: compact ? 13 : 14, weight: .bold, monospaced: true))
                .foregroundStyle(tint.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: labelWidth, alignment: .leading)

            quotaProgressBar(percent: window.percent, accent: accent, compact: compact, blocked: blockedByWeeklyZero)
                .frame(maxWidth: .infinity)

            Button {
                toggleResetExpansion(windowID: window.id, profileID: profile.id)
            } label: {
                Text(resetText)
                    .font(appFont(size: compact ? 13 : 14, weight: .bold, monospaced: true))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.72)
                    .frame(width: scaled(compact ? 42 : 48), alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.92, hoverScale: 1.05, glow: tint, glowOpacity: 0.20))
            .disabled(window.reset == nil || window.reset == "unknown" || window.reset == "none")
            .foregroundStyle(.white.opacity(0.62))
            .help(fullResetHelp(forcedReset ?? window.reset, windowID: window.id))
        }
        .frame(maxWidth: .infinity, minHeight: scaled(21), alignment: .center)
        .opacity(window.labelZH.isEmpty ? 0 : 1)
    }

    private func resetCreditsLine(_ summary: ResetCreditSummary, profileID: String, compact: Bool, expanded: Bool) -> some View {
        let accent = Color(red: 0.36, green: 0.88, blue: 1.00)
        let expiryText = resetCreditsExpirySummary(summary)

        return HStack(spacing: scaled(compact ? 5 : 7)) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: scaled(compact ? 10 : 11), weight: .semibold))
                .foregroundStyle(accent.opacity(0.90))
                .frame(width: scaled(compact ? 16 : 18), alignment: .leading)

            Text(tr("重設券", "Resets"))
                .font(appFont(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            Text(tr("\(summary.count) 張可用", "\(summary.count) available"))
                .font(appFont(size: compact ? 11 : 12, weight: .bold, monospaced: true))
                .foregroundStyle(accent.opacity(0.98))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: scaled(4))

            Text(expiryText)
                .font(appFont(size: compact ? 10 : 11, weight: .semibold, monospaced: true))
                .foregroundStyle(summary.expiries.isEmpty ? .white.opacity(0.34) : .white.opacity(0.66))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.72)

            Image(systemName: "chevron.down")
                .font(.system(size: scaled(compact ? 9 : 10), weight: .heavy))
                .foregroundStyle(accent.opacity(0.62))
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .animation(.easeOut(duration: 0.12), value: expanded)
                .frame(width: scaled(compact ? 12 : 14), alignment: .trailing)
        }
        .padding(.horizontal, scaled(compact ? 7 : 8))
        .padding(.vertical, scaled(compact ? 5 : 6))
        .frame(maxWidth: .infinity, minHeight: scaled(compact ? 24 : 26), alignment: .center)
        .background(accent.opacity(0.08))
        .overlay(
            Capsule()
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            toggleResetCreditExpansion(profileID: profileID)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tr("重設券詳情", "Reset credit details"))
        .accessibilityHint(tr("展開或收起每張券嘅到期時間", "Expand or collapse per-credit expiry times"))
        .help(resetCreditsHelp(summary))
    }

    private func resetCreditsDetailPanel(_ summary: ResetCreditSummary, compact: Bool) -> some View {
        VStack(spacing: scaled(compact ? 4 : 5)) {
            if summary.expiries.isEmpty {
                HStack(spacing: scaled(6)) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: scaled(10), weight: .semibold))
                    Text(tr("未能取得每張券嘅到期時間", "Per-credit expiry times unavailable"))
                        .font(appFont(size: compact ? 10 : 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.48))
            } else {
                resetCreditDetailHeader(compact: compact)

                ForEach(Array(summary.expiries.enumerated()), id: \.offset) { item in
                    resetCreditDetailRow(index: item.offset, expiry: item.element, compact: compact)
                }
            }
        }
        .padding(.horizontal, scaled(compact ? 8 : 10))
        .padding(.vertical, scaled(compact ? 6 : 7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.050))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(10), style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(10), style: .continuous))
    }

    private func resetCreditDetailHeader(compact: Bool) -> some View {
        let columns = resetCreditDetailColumnWidths(compact: compact)

        return HStack(spacing: scaled(compact ? 6 : 8)) {
            Text("")
                .frame(width: columns.label, alignment: .leading)

            Text(tr("到期日期", "Expiry date"))
                .font(appFont(size: compact ? 9 : 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .frame(width: columns.date, alignment: .leading)

            Text(tr("時間", "Time"))
                .font(appFont(size: compact ? 9 : 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .frame(width: columns.time, alignment: .leading)

            Spacer(minLength: scaled(4))

            Text(tr("剩餘日數", "Time left"))
                .font(appFont(size: compact ? 9 : 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .frame(width: columns.remaining, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: scaled(compact ? 14 : 16), alignment: .center)
    }

    private func resetCreditDetailRow(index: Int, expiry: String, compact: Bool) -> some View {
        let columns = resetCreditDetailColumnWidths(compact: compact)

        return HStack(spacing: scaled(compact ? 6 : 8)) {
            Text(tr("第 \(index + 1) 張", "#\(index + 1)"))
                .font(appFont(size: compact ? 10 : 11, weight: .bold))
                .foregroundStyle(Color(red: 0.36, green: 0.88, blue: 1.00).opacity(0.86))
                .frame(width: columns.label, alignment: .leading)

            Text(resetCreditDetailDatePartText(expiry))
                .font(appFont(size: compact ? 10 : 11, weight: .semibold, monospaced: true))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: columns.date, alignment: .leading)

            Text(resetCreditDetailTimePartText(expiry))
                .font(appFont(size: compact ? 10 : 11, weight: .semibold, monospaced: true))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(width: columns.time, alignment: .leading)

            Spacer(minLength: scaled(4))

            Text(resetCreditRemainingText(expiry))
                .font(appFont(size: compact ? 9 : 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.80)
                .frame(width: columns.remaining, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: scaled(compact ? 16 : 18), alignment: .center)
    }

    private func resetCreditDetailColumnWidths(compact: Bool) -> (label: CGFloat, date: CGFloat, time: CGFloat, remaining: CGFloat) {
        (
            label: scaled(compact ? 42 : 50),
            date: selectedLanguage == .en ? scaled(compact ? 84 : 96) : scaled(compact ? 98 : 112),
            time: scaled(compact ? 38 : 44),
            remaining: selectedLanguage == .en ? scaled(compact ? 48 : 56) : scaled(compact ? 42 : 50)
        )
    }

    private func quotaRows(for windows: [QuotaWindow]) -> [QuotaWindow] {
        guard !windows.isEmpty else {
            return [
                QuotaWindow(id: "unknown", labelZH: "用量", labelEN: "Usage", percent: nil, reset: nil)
            ]
        }

        let sorted = windows.sorted { lhs, rhs in
            quotaWindowRank(lhs.id) < quotaWindowRank(rhs.id)
        }
        return Array(sorted.prefix(2))
    }

    private func quotaWindowRank(_ id: String) -> Int {
        switch id {
        case "5h": return 0
        case "7d": return 1
        case "30d": return 2
        case "usage": return 3
        default: return 4
        }
    }

    private func quotaWindowID(from text: String) -> String? {
        guard let token = text.split(separator: " ").first else { return nil }
        let id = String(token).lowercased()
        if id == "5h" || id == "7d" || id == "30d" || id == "usage" {
            return id
        }
        guard let suffix = id.last, suffix == "h" || suffix == "d" || suffix == "m" else {
            return nil
        }
        guard Int(id.dropLast()) != nil else { return nil }
        return id
    }

    private func quotaWindowLabels(for id: String) -> (zh: String, en: String) {
        switch id {
        case "5h":
            return ("5H", "5H")
        case "7d":
            return ("1W", "1W")
        case "30d":
            return ("1M", "1M")
        case "usage":
            return ("用量", "Usage")
        default:
            guard let suffix = id.last, let number = Int(id.dropLast()) else {
                return ("用量", "Usage")
            }
            let upperSuffix = String(suffix).uppercased()
            return ("\(number)\(upperSuffix)", "\(number)\(upperSuffix)")
        }
    }

    private func quotaWindows(for profile: CodexProfile) -> [QuotaWindow] {
        let resets = quotaResetMap(from: profile.reset)

        if profile.quota == "unlimited" {
            return [
                QuotaWindow(id: "5h", labelZH: "5H", labelEN: "5H", percent: 100, reset: resets["5h"]),
                QuotaWindow(id: "7d", labelZH: "1W", labelEN: "1W", percent: 100, reset: resets["7d"])
            ]
        }

        guard profile.quota != "unknown" else { return [] }

        var parsed: [QuotaWindow] = []
        for part in profile.quota.split(separator: "/") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let percent = quotaPercents(from: text).first
            if let id = quotaWindowID(from: text), let percent {
                let labels = quotaWindowLabels(for: id)
                parsed.append(QuotaWindow(id: id, labelZH: labels.zh, labelEN: labels.en, percent: percent, reset: resets[id]))
            }
        }

        return parsed.sorted { quotaWindowRank($0.id) < quotaWindowRank($1.id) }
    }

    private func quotaResetMap(from reset: String) -> [String: String] {
        var result: [String: String] = [:]
        guard reset != "unknown", reset != "none" else { return result }

        for part in reset.components(separatedBy: " / ") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = quotaWindowID(from: text), let token = text.split(separator: " ").first {
                result[id] = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }

    private func shortResetText(_ reset: String?) -> String {
        guard let reset,
              !reset.isEmpty,
              reset != "unknown",
              reset != "none"
        else {
            return "--"
        }

        return reset
    }

    private func resetCreditSummary(for profile: CodexProfile) -> ResetCreditSummary? {
        guard !isExternalProvider(profile) else { return nil }
        let trimmed = profile.resetCredits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "unknown",
              trimmed != "none"
        else {
            return nil
        }

        let pieces = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let rawCount = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digits = rawCount.prefix { $0.isNumber }
        guard let count = Int(String(digits)), count > 0 else { return nil }

        let expiries: [String]
        if pieces.count > 1 {
            expiries = pieces[1]
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "unknown" && $0 != "null" }
        } else {
            expiries = []
        }

        let sortedExpiries = expiries.sorted { lhs, rhs in
            switch (resetCreditExpiryDate(from: lhs), resetCreditExpiryDate(from: rhs)) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs < rhs
            }
        }

        return ResetCreditSummary(count: count, expiries: sortedExpiries)
    }

    private func resetCreditsExpirySummary(_ summary: ResetCreditSummary) -> String {
        guard let first = summary.expiries.first else {
            return tr("到期未提供", "Expiry unavailable")
        }
        return tr(
            "最早 \(shortResetCreditExpiryText(first)) · \(resetCreditRemainingText(first))",
            "First \(shortResetCreditExpiryText(first)) · \(resetCreditRemainingText(first))"
        )
    }

    private func resetCreditsHelp(_ summary: ResetCreditSummary) -> String {
        let title = tr("重設券：\(summary.count) 張可用", "Reset credits: \(summary.count) available")
        guard !summary.expiries.isEmpty else {
            return title + "\n" + tr(
                "暫時未能取得每張券嘅到期時間。",
                "Per-credit expiry times are currently unavailable."
            )
        }

        let details = summary.expiries.enumerated().map { index, raw in
            tr(
                "第 \(index + 1) 張：\(fullResetCreditExpiryText(raw))，\(resetCreditRemainingText(raw))",
                "#\(index + 1): \(fullResetCreditExpiryText(raw)), \(resetCreditRemainingText(raw))"
            )
        }.joined(separator: "\n")
        return title + "\n" + details
    }

    private func shortResetCreditExpiryText(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else {
            return tr("到期時間無法讀取", "Expiry unreadable")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = selectedLanguage == .en ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func fullResetCreditExpiryText(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else {
            return tr("到期時間無法讀取", "Expiry unreadable")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = selectedLanguage == .en ? "MMM d, yyyy HH:mm" : "yyyy年M月d日 HH:mm"
        return tr("\(formatter.string(from: date)) 到期", "Expires \(formatter.string(from: date))")
    }

    private func resetCreditDetailDateText(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else {
            return tr("到期時間無法讀取", "Expiry unreadable")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = selectedLanguage == .en ? "MMM d, yyyy HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func resetCreditDetailDatePartText(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else {
            return tr("日期無法讀取", "Date unreadable")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = selectedLanguage == .en ? "MMM d, yyyy" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private func resetCreditDetailTimePartText(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else {
            return "--:--"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func resetCreditRemainingText(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else {
            return tr("剩餘時間未知", "Time left unknown")
        }

        let seconds = date.timeIntervalSince(Date())
        if seconds <= 0 {
            return tr("已過期", "Expired")
        }

        let days = Int(ceil(seconds / 86_400))
        if days >= 2 {
            return tr("剩 \(days) 日", "\(days)d left")
        }

        let hours = max(1, Int(ceil(seconds / 3_600)))
        if hours >= 24 {
            return tr("剩 1 日", "1d left")
        }
        return tr("剩 \(hours) 小時", "\(hours)h left")
    }

    private func resetCaption(_ reset: String?, windowID: String, profileID: String) -> String {
        let text = shortResetText(reset)
        guard text != "--" else { return text }

        let finalText: String
        if windowID == "5h" {
            finalText = clockResetText(from: text)
        } else {
            let key = "\(profileID):\(windowID)"
            finalText = expandedResetKeys.contains(key)
                ? relativeResetText(from: text)
                : weeklyResetText(from: text)
        }

        if resetScrambleActive {
            return scrambledResetText(finalText: finalText, windowID: windowID, profileID: profileID)
        }
        return finalText
    }

    private func scrambledResetText(finalText: String, windowID: String, profileID: String) -> String {
        if resetScrambleReturning {
            return risingResetText(to: finalText)
        }

        let step = max(0, 10 - resetScrambleSeed)
        let base = abs(profileID.unicodeScalars.reduce(step * 31) { $0 + Int($1.value) })
        if windowID == "5h" || finalText.contains(":") {
            return String(format: "%02d:%02d", min(step * 2, 23), min(step * 6, 59))
        }
        if finalText.contains("/") && step == 0 {
            return "00/00"
        }
        if !finalText.contains("/") {
            return fallingResetText(matching: finalText, step: step)
        }
        return String(format: "%02d/%02d", max(1, step), max(1, min(28, step * 3 + base % 4)))
    }

    private func risingResetText(to finalText: String) -> String {
        digitAnimatedResetText(finalText, progress: min(max(Double(resetScrambleSeed) / 10.0, 0), 1))
    }

    private func fallingResetText(matching finalText: String, step: Int) -> String {
        digitAnimatedResetText(finalText, progress: min(max(Double(step) / 10.0, 0), 1))
    }

    private func digitAnimatedResetText(_ text: String, progress: Double) -> String {
        String(text.map { character in
            guard let target = character.wholeNumberValue else {
                return character
            }
            let value = min(9, max(0, Int((Double(target) * progress).rounded())))
            return Character(String(value))
        })
    }

    private func replayPercent(_ percent: Int?) -> Int? {
        guard let percent else { return nil }
        guard quotaReplayActive else { return percent }
        let progress = resetScrambleReturning
            ? min(max(Double(resetScrambleSeed) / 10.0, 0), 1)
            : min(max(Double(max(0, 10 - resetScrambleSeed)) / 10.0, 0), 1)
        return min(max(Int((Double(percent) * progress).rounded()), 0), 100)
    }

    private func toggleResetExpansion(windowID: String, profileID: String) {
        guard windowID == "7d" else { return }
        let key = "\(profileID):\(windowID)"
        withAnimation(.spring(response: 0.20, dampingFraction: 0.82)) {
            if expandedResetKeys.contains(key) {
                expandedResetKeys.remove(key)
            } else {
                expandedResetKeys.insert(key)
            }
        }
    }

    private func toggleResetCreditExpansion(profileID: String) {
        withAnimation(.easeOut(duration: 0.14)) {
            if expandedResetCreditProfileIDs.contains(profileID) {
                expandedResetCreditProfileIDs.remove(profileID)
            } else {
                expandedResetCreditProfileIDs.insert(profileID)
            }
        }
    }

    private func weeklyResetText(from text: String) -> String {
        if let date = resetDate(from: text) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd"
            return formatter.string(from: date)
        }
        return text
    }

    private func clockResetText(from text: String?) -> String {
        guard let text,
              !text.isEmpty,
              text != "unknown",
              text != "none"
        else {
            return "--"
        }
        guard let date = resetDate(from: text) else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func fullResetHelp(_ reset: String?, windowID: String) -> String {
        guard let reset,
              !reset.isEmpty,
              reset != "unknown",
              reset != "none"
        else {
            return tr("重設時間未知", "Reset time unknown")
        }
        let absolute = fullResetDateText(from: reset)
        let countdown = relativeResetText(from: reset)
        let labels = quotaWindowLabels(for: windowID)
        if windowID == "5h" {
            return tr(
                "5H 重設時間\n\(absolute)\n\n倒數\n\(countdown)",
                "5H reset time\n\(absolute)\n\nCountdown\n\(countdown)"
            )
        }
        return tr(
            "\(labels.zh) 重設時間\n\(absolute)\n\n倒數\n\(countdown)",
            "\(labels.en) reset time\n\(absolute)\n\nCountdown\n\(countdown)"
        )
    }

    private func fullResetDateText(from text: String) -> String {
        guard let date = resetDate(from: text) else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = selectedLanguage == .en ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func relativeResetText(from text: String) -> String {
        guard let date = resetDate(from: text) else { return text }
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)H\(minutes)M"
        }
        return "\(max(minutes, 1))M"
    }

    private func resetDate(from text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.hasPrefix("@"), let epoch = TimeInterval(trimmedText.dropFirst()) {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }

        if text.contains("/") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let year = calendar.component(.year, from: now)
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            if let date = formatter.date(from: "\(year)/\(text)") {
                return date
            }
            formatter.dateFormat = "yyyy/MM/dd"
            return formatter.date(from: "\(year)/\(text)")
        }

        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let date = calendar.date(from: components) else { return nil }
        return date < now ? calendar.date(byAdding: .day, value: 1, to: date) : date
    }

    private func resetCreditExpiryDate(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let epoch = TimeInterval(trimmed) {
            let normalized = epoch > 10_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: normalized)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private func shouldPreservePreviousUsage(_ previous: CodexProfile) -> Bool {
        previous.quota != "unknown" && !cachedResetHasElapsed(previous.reset)
    }

    private func cachedResetHasElapsed(_ reset: String) -> Bool {
        guard !reset.isEmpty, reset != "unknown", reset != "none" else { return false }
        var sawReset = false
        var sawElapsed = false
        var sawCurrentOrUnknown = false

        for part in reset.components(separatedBy: " / ") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: " ") else { continue }
            sawReset = true
            let value = String(trimmed[trimmed.index(after: separator)...])
            guard let date = staleResetDate(from: value) else {
                sawCurrentOrUnknown = true
                continue
            }
            if date <= Date().addingTimeInterval(-20) {
                sawElapsed = true
            } else {
                sawCurrentOrUnknown = true
            }
        }

        return sawReset && sawElapsed && !sawCurrentOrUnknown
    }

    private func staleResetDate(from text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = calendar.component(.year, from: now)

        if trimmed.contains("/") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            if let date = formatter.date(from: "\(year)/\(trimmed)") {
                return date
            }
            formatter.dateFormat = "yyyy/MM/dd"
            return formatter.date(from: "\(year)/\(trimmed)")
        }

        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func quotaRemainingPercent(for profile: CodexProfile) -> Int? {
        if isExternalProvider(profile) {
            return 100
        }
        if profile.quota == "unlimited" {
            return 100
        }
        return quotaPercents(from: profile.quota).min()
    }

    private func isQuotaPoolCandidate(_ profile: CodexProfile) -> Bool {
        if isExternalProvider(profile) {
            return false
        }
        return isVisiblySignedIn(profile) && !isLoginNeeded(profile) && quotaPoolScore(for: profile) > 0
    }

    private func isQuotaDepleted(_ profile: CodexProfile) -> Bool {
        if isExternalProvider(profile) {
            return false
        }
        guard profile.quota != "unlimited", profile.quota != "unknown" else { return false }
        return (quotaRemainingPercent(for: profile) ?? 0) <= 0
    }

    private func quotaPoolScore(for profile: CodexProfile) -> Int {
        if isExternalProvider(profile) {
            return -1
        }
        if profile.quota == "unlimited" {
            return 10_000
        }
        guard isVisiblySignedIn(profile), !isLoginNeeded(profile) else {
            return -1
        }
        guard let percent = quotaRemainingPercent(for: profile) else {
            return -1
        }
        guard percent > 0 else {
            return 0
        }
        return quotaWindows(for: profile).contains(where: { $0.id == "5h" })
            ? 1_000 + percent
            : percent
    }

    private func bestQuotaPoolProfile(excluding excludedID: String? = nil) -> CodexProfile? {
        profiles
            .filter { profile in
                profile.id != excludedID && isQuotaPoolCandidate(profile)
            }
            .sorted { lhs, rhs in
                let leftScore = quotaPoolScore(for: lhs)
                let rightScore = quotaPoolScore(for: rhs)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .first
    }

    private func bestQuotaPoolProfileIncludingRequested() -> CodexProfile? {
        profiles
            .filter(isQuotaPoolCandidate)
            .sorted { lhs, rhs in
                let leftScore = quotaPoolScore(for: lhs)
                let rightScore = quotaPoolScore(for: rhs)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .first
    }

    private func quotaPoolRoute(for requestedID: String) -> QuotaPoolRouteDecision? {
        guard let requested = profiles.first(where: { $0.id == requestedID }) else {
            return nil
        }
        if isExternalProvider(requested) {
            return QuotaPoolRouteDecision(requested: requested, target: requested, didSwitch: false)
        }
        guard autoQuotaPool, isVisiblySignedIn(requested), !isLoginNeeded(requested) else {
            return QuotaPoolRouteDecision(requested: requested, target: requested, didSwitch: false)
        }
        guard let target = bestQuotaPoolProfileIncludingRequested() else {
            return QuotaPoolRouteDecision(requested: requested, target: requested, didSwitch: false)
        }
        guard target.id != requested.id else {
            return QuotaPoolRouteDecision(requested: requested, target: requested, didSwitch: false)
        }
        return QuotaPoolRouteDecision(requested: requested, target: target, didSwitch: true)
    }

    private func quotaAccent(for percent: Int?) -> Color {
        guard let percent else {
            return Color.gray
        }

        switch percent {
        case ...10:
            return Color(red: 0.88, green: 0.05, blue: 0.14)
        case ...20:
            return Color(red: 0.96, green: 0.18, blue: 0.18)
        case ...32:
            return Color(red: 1.00, green: 0.38, blue: 0.22)
        case ...44:
            return Color(red: 1.00, green: 0.57, blue: 0.16)
        case ...56:
            return Color(red: 0.96, green: 0.74, blue: 0.20)
        case ...68:
            return Color(red: 0.72, green: 0.84, blue: 0.28)
        case ...80:
            return Color(red: 0.42, green: 0.82, blue: 0.36)
        case ...92:
            return Color(red: 0.10, green: 0.82, blue: 0.60)
        default:
            return Color(red: 0.00, green: 0.90, blue: 0.78)
        }
    }

    private func quotaProgressBar(percent: Int?, accent: Color, compact: Bool, blocked: Bool = false) -> some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        } label: {
            GeometryReader { geometry in
                let animatedPercent = replayPercent(percent)
                let clamped = min(max(animatedPercent ?? 0, 0), 100)
                let fillWidth = geometry.size.width * CGFloat(clamped) / 100

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(((percent == 0 || blocked) ? Color(red: 1.00, green: 0.12, blue: 0.24) : Color.white).opacity((percent == 0 || blocked) ? 0.20 : 0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.78), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)

                    Text(animatedPercent.map { "\($0)%" } ?? "--")
                        .font(appFont(size: compact ? 12 : 13, weight: .heavy, monospaced: true))
                        .monospacedDigit()
                        .foregroundStyle(percent == 0 ? Color(red: 1.00, green: 0.12, blue: 0.20) : (percent == nil ? Color.white.opacity(0.48) : Color.white.opacity(0.94)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.trailing, scaled(7))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96, hoverScale: 1.025, glow: accent, glowOpacity: 0.20))
        .frame(height: scaled(compact ? 19 : 21))
        .overlay(
            Capsule()
                .stroke(accent.opacity(percent == nil ? 0.10 : 0.32), lineWidth: 1)
        )
        .clipShape(Capsule())
        .animation(.spring(response: 0.62, dampingFraction: 0.52, blendDuration: 0.08), value: quotaReplayActive)
        .animation(.linear(duration: 0.055), value: resetScrambleSeed)
        .animation(.spring(response: 0.42, dampingFraction: 0.70, blendDuration: 0.05), value: percent ?? -1)
    }

    private func quotaHelp(for profile: CodexProfile) -> String {
        if isExternalProvider(profile) {
            return tr("阿里 Coding Plan\nqwen3.7-plus\n經本機 bridge 接入", "Aliyun Coding Plan\nqwen3.7-plus\nConnected through local bridge")
        }
        let quotaText = profile.quota == "unknown" ? tr("用量未知", "Usage unknown") : profile.quota
        let resetText = profile.reset == "unknown" ? tr("重設時間未知", "Reset unknown") : profile.reset
        if let resetCredits = resetCreditSummary(for: profile) {
            return "\(quotaText)\n\(resetText)\n\(resetCreditsHelp(resetCredits))"
        }
        return "\(quotaText)\n\(resetText)"
    }

    private func quotaAccent(for profile: CodexProfile) -> Color {
        if isExternalProvider(profile) {
            return Color(red: 0.10, green: 0.86, blue: 0.74)
        }
        if profile.quota == "unlimited" {
            return Color(red: 0.04, green: 0.74, blue: 0.64)
        }
        return quotaAccent(for: quotaRemainingPercent(for: profile))
    }

    private func profileRowAccent(for profile: CodexProfile) -> Color {
        if isLoginNeeded(profile) {
            return Color(red: 1.00, green: 0.52, blue: 0.12)
        }
        if isWaitingForRecovery(profile) {
            return Color(red: 1.00, green: 0.18, blue: 0.20)
        }
        return profilePlanAccent(for: profile)
    }

    private func profilePlanAccent(for profile: CodexProfile) -> Color {
        if isExternalProvider(profile) {
            return Color(red: 0.10, green: 0.86, blue: 0.74)
        }
        let windows = quotaWindows(for: profile)
        if windows.contains(where: { $0.id == "5h" && $0.percent != nil }) {
            return Color(red: 1.00, green: 0.72, blue: 0.06)
        }
        if windows.contains(where: { $0.id == "7d" && $0.percent != nil }) {
            return Color(red: 0.18, green: 0.72, blue: 1.00)
        }
        if profile.quota != "unknown" {
            return Color(red: 0.45, green: 0.50, blue: 0.58)
        }
        return Color.gray
    }

    private func quotaPercents(from quota: String) -> [Int] {
        var values: [Int] = []
        var digits = ""

        for character in quota {
            if character.isNumber {
                digits.append(character)
            } else if character == "%" {
                if let value = Int(digits) {
                    values.append(value)
                }
                digits = ""
            } else {
                digits = ""
            }
        }

        return values
    }

    private func openButton(_ profile: CodexProfile) -> some View {
        let signedIn = isVisiblySignedIn(profile)
        let title = signedIn ? tr("打開", "Open") : tr("登入", "Log In")
        let hasQuota = (quotaRemainingPercent(for: profile) ?? 0) > 0
        let depleted = !isExternalProvider(profile) && profile.quota != "unknown" && !hasQuota
        let accent = depleted ? Color(red: 1.00, green: 0.12, blue: 0.20) : (signedIn ? Color(red: 0.12, green: 0.92, blue: 0.70) : Color.orange)

        return Button {
            openAccount(profile.id, displayName: profile.displayName)
        } label: {
            ZStack {
                Text(title)
                    .opacity(busyProfiles.contains(profile.id) ? 0 : 1)
                if busyProfiles.contains(profile.id) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(appFont(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .frame(height: scaled(30))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.90, hoverScale: 1.045, glow: accent, glowOpacity: 0.22))
        .foregroundStyle(depleted ? accent : .white.opacity(0.94))
        .background(
            Capsule()
                .fill(Color.black.opacity(0.30))
                .overlay(accent.opacity(depleted ? 0.17 : 0.13))
        )
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [accent.opacity(0.72), Color.white.opacity(0.16), accent.opacity(0.30)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: depleted ? 1.6 : 1.2
                )
        )
        .shadow(color: accent.opacity(depleted ? 0.26 : 0.18), radius: 9, x: 0, y: 3)
        .clipShape(Capsule())
        .modifier(HoverLiftGlow(glow: accent, scale: 1.055, opacity: 0.50, radius: 18, y: 5))
        .disabled(busyProfiles.contains(profile.id) || isClosingAllAccounts)
        .keyboardShortcut(profile.id == "account1" ? "1" : "2", modifiers: [.command])
    }

    private func closeButton(_ profile: CodexProfile) -> some View {
        HoverCloseCircleButton(
            side: scaled(30),
            iconSize: scaled(12),
            isBusy: busyProfiles.contains(profile.id),
            helpText: tr("關閉 \(profile.displayName)", "Close \(profile.displayName)")
        ) {
            closeAccount(profile)
        }
        .frame(width: scaled(38), height: scaled(40))
        .disabled(busyProfiles.contains(profile.id) || isClosingAllAccounts)
        .contentShape(Rectangle())
        .onHover { hovering in
            updateHoveredProfile(profile.id, hovering: hovering)
        }
    }

    private func profileMenu(_ profile: CodexProfile) -> some View {
        Button {
            withAnimation(.interactiveSpring(response: 0.20, dampingFraction: 0.78, blendDuration: 0.06)) {
                hoveredProfileID = profile.id
            }
            showProfilePopupMenu(for: profile)
        } label: {
            HStack(spacing: scaled(3)) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: scaled(14), weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.80))
            .frame(width: scaled(44), height: scaled(40))
            .contentShape(RoundedRectangle(cornerRadius: scaled(13), style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92, hoverScale: 1.04, glow: Color.white, glowOpacity: 0.18))
        .onHover { hovering in
            updateHoveredProfile(profile.id, hovering: hovering)
        }
        .help(tr("更多", "More"))
    }

    private func showProfilePopupMenu(for profile: CodexProfile) {
        NSApp.activate(ignoringOtherApps: true)

        let isOpenCodexLab = profile.id == "opencodex-lab"
        let menu = NSMenu()
        menu.addItem(CallbackMenuItem(title: tr("關閉視窗", "Close Window")) {
            closeAccount(profile)
        })
        menu.addItem(CallbackMenuItem(title: tr("改名...", "Rename...")) {
            renameProfile(profile)
        })
        menu.addItem(CallbackMenuItem(title: tr("自訂 Icon...", "Custom Icon...")) {
            chooseCustomIcon(for: profile)
        })
        menu.addItem(CallbackMenuItem(title: tr("喺 Finder 顯示", "Reveal Profile Folder")) {
            revealProfile(profile)
        })
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: tr("導出對話包...", "Export Conversation Package...")) {
            exportConversationPackage(from: profile)
        })
        menu.addItem(CallbackMenuItem(title: tr("導入對話包...", "Import Conversation Package...")) {
            importConversationPackage(defaultTarget: profile)
        })
        menu.addItem(.separator())

        let historyMode = profileHistoryMode(for: profile)
        let privateHistoryItem = CallbackMenuItem(
            title: tr("🔒 私人本機對話（只限此 Profile）", "🔒 Private local chats (this profile only)"),
            enabled: !isHistoryAnchor(profile) && historyMode != .privateOnly
        ) {
            separateHistory(profile)
        }
        privateHistoryItem.state = historyMode == .privateOnly ? .on : .off
        menu.addItem(privateHistoryItem)

        let sharedHistoryItem = CallbackMenuItem(
            title: tr("共享本機對話（其他 Profile 可見）", "Share local chats (visible to other profiles)"),
            enabled: historyMode != .shared
        ) {
            shareHistory(profile)
        }
        sharedHistoryItem.state = historyMode == .shared ? .on : .off
        menu.addItem(sharedHistoryItem)
        if isOpenCodexLab {
            menu.addItem(CallbackMenuItem(
                title: tr("只共享對話；登入、設定同代理路由保持獨立", "Shares chats only; sign-in, settings, and proxy routing stay isolated"),
                enabled: false
            ) {})
        }
        menu.addItem(CallbackMenuItem(
            title: tr("只隔離本機紀錄；唔會關閉 OpenAI 雲端處理", "Isolates local records only; OpenAI cloud processing stays on"),
            enabled: false
        ) {})
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: tr("刪除 Profile...", "Delete Profile..."), enabled: profile.id != "account1" && !isOpenCodexLab) {
            deleteProfile(profile)
        })

        let mouse = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: mouse.x, y: mouse.y), in: nil)
    }

    private func miniButton(_ title: String, action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            Text(title)
                .font(appFont(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.vertical, scaled(6))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.92, hoverScale: 1.035, glow: Color.white, glowOpacity: 0.15))
        .background(Color.white.opacity(0.10))
        .foregroundStyle(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: scaled(8), style: .continuous))
    }

    private func glassIconButton(systemName: String, label: String, danger: Bool = false, compact: Bool = false, accent customAccent: Color? = nil, isBusy: Bool = false, action: @escaping () -> Void) -> some View {
        let accent = customAccent ?? (danger ? Color(red: 1.00, green: 0.22, blue: 0.18) : Color.white)
        let side = scaled(compact ? 38 : 42)
        let radius = scaled(compact ? 13 : 14)

        return Button(action: action) {
            ZStack {
                Image(systemName: systemName)
                    .font(.system(size: scaled(compact ? 15 : 16), weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .opacity(isBusy ? 0.0 : 1.0)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(compact ? 0.72 : 0.80)
                        .tint(accent)
                }
            }
            .frame(width: side, height: side)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.86, hoverScale: 1.08, glow: accent, glowOpacity: 0.30))
        .foregroundStyle(danger ? accent.opacity(0.96) : accent.opacity(0.92))
        .background(.ultraThinMaterial)
        .background(accent.opacity(danger ? 0.13 : 0.10))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(danger ? accent.opacity(0.42) : accent.opacity(0.26), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .help(label)
    }

    private func closeAllIconButton(label: String, compact: Bool = false, action: @escaping () -> Void) -> some View {
        let accent = Color(red: 1.00, green: 0.18, blue: 0.14)
        let side = scaled(compact ? 38 : 42)
        let radius = scaled(compact ? 13 : 14)

        return Button(action: action) {
            ZStack {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: scaled(compact ? 14 : 15), weight: .semibold))
                    .offset(x: scaled(-1), y: scaled(-1))

                Image(systemName: "xmark")
                    .font(.system(size: scaled(compact ? 15 : 16), weight: .heavy))
                    .offset(x: scaled(compact ? 4 : 5), y: scaled(compact ? 4 : 5))
            }
            .frame(width: side, height: side)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.84, hoverScale: 1.09, glow: accent, glowOpacity: 0.34))
        .foregroundStyle(accent.opacity(0.96))
        .background(.ultraThinMaterial)
        .background(accent.opacity(0.16))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [accent.opacity(0.78), Color.white.opacity(0.16), accent.opacity(0.44)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .help(label)
    }

    private func sidebarToggle(_ title: String, isOn: Binding<Bool>, tint: Color) -> some View {
        HStack(spacing: scaled(10)) {
            Text(title)
                .font(appFont(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
            Spacer(minLength: scaled(8))
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(
                    LiquidSwitchStyle(
                        isOnColor: tint,
                        isOffColor: Color(red: 0.42, green: 0.46, blue: 0.52),
                        scale: layoutScale
                    )
                )
                .frame(width: scaled(54), height: scaled(30))
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isOn.wrappedValue)
    }

    private func runBackground(
        _ message: String?,
        queue: DispatchQueue = codexAccountsWorkQueue,
        work: @escaping () -> (Int32, String),
        completion: @escaping ((Int32, String)) -> Void
    ) {
        if let message {
            activeOperationCount += 1
            loadingMessage = message
        }

        queue.async {
            let result = work()
            DispatchQueue.main.async {
                if message != nil {
                    activeOperationCount = max(activeOperationCount - 1, 0)
                    if activeOperationCount == 0 {
                        loadingMessage = ""
                    }
                }
                completion(result)
            }
        }
    }

    private func showEphemeralLoading(_ message: String, duration: TimeInterval = 0.35) {
        activeOperationCount += 1
        loadingMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            activeOperationCount = max(activeOperationCount - 1, 0)
            if activeOperationCount == 0 {
                loadingMessage = ""
            }
        }
    }

    private func setProfileBusy(_ id: String, _ busy: Bool) {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
            if busy {
                busyProfiles.insert(id)
            } else {
                busyProfiles.remove(id)
            }
        }
    }

    private func refreshProfiles(
        showLoading: Bool = true,
        replayQuota: Bool = false,
        liveUsage: Bool = false,
        liveParallelism: Int? = nil,
        statusTimeout: TimeInterval? = nil,
        respectBackoff: Bool = false
    ) {
        guard !isRefreshing else {
            if showLoading {
                showEphemeralLoading(tr("正在更新用量...", "Updating usage..."), duration: 0.55)
            }
            return
        }
        withAnimation(.easeOut(duration: 0.10)) {
            isRefreshing = true
        }
        if replayQuota {
            startResetScramble()
            withAnimation(.easeOut(duration: 0.18)) {
                quotaReplayActive = true
            }
        }
        let displayNamesSnapshot = displayNames
        let previousProfilesSnapshot = profiles
        let hadProfiles = !profiles.isEmpty
        let loading = showLoading && hadProfiles ? tr("重新整理帳戶...", "Refreshing accounts...") : nil

        runBackground(loading) {
            let accountsResult = runCodexScript(scriptPath, ["list-accounts"], wait: true, timeout: 10)
            guard accountsResult.0 == 0 else {
                return accountsResult
            }

            let discoveredProfiles = parsedCodexProfiles(
                accountsOutput: accountsResult.1,
                statusOutput: "",
                displayNames: displayNamesSnapshot
            )
            let tokenIDs = collectLocalAuthTokenProfileIDs(in: discoveredProfiles)
            let previousByID = Dictionary(uniqueKeysWithValues: previousProfilesSnapshot.map { ($0.id, $0) })
            let resolvedProfiles = discoveredProfiles.map { profile -> CodexProfile in
                let hasLocalTokens = tokenIDs.contains(profile.id)
                let cachedProfile = profileWithCachedUsageFallback(
                    profileWithLocalAuthTokenFallback(profile, hasLocalTokens: hasLocalTokens),
                    hasLocalTokens: hasLocalTokens
                )
                guard let previous = previousByID[profile.id] else {
                    return CodexProfile(
                        id: cachedProfile.id,
                        displayName: cachedProfile.displayName,
                        home: cachedProfile.home,
                        authStatus: cachedProfile.authStatus == "unknown" ? "checking" : cachedProfile.authStatus,
                        authMode: "checking",
                        lastRefresh: cachedProfile.lastRefresh,
                        quota: cachedProfile.quota,
                        reset: cachedProfile.reset,
                        resetCredits: cachedProfile.resetCredits
                    )
                }
                let preservePreviousUsage = shouldPreservePreviousUsage(previous)
                return CodexProfile(
                    id: cachedProfile.id,
                    displayName: cachedProfile.displayName,
                    home: cachedProfile.home,
                    authStatus: mergedAuthStatus(previous: previous.authStatus, current: cachedProfile.authStatus),
                    authMode: cachedProfile.authMode == "unknown" || cachedProfile.authMode == "checking" ? previous.authMode : cachedProfile.authMode,
                    lastRefresh: previous.lastRefresh,
                    quota: preservePreviousUsage ? previous.quota : cachedProfile.quota,
                    reset: preservePreviousUsage ? previous.reset : cachedProfile.reset,
                    resetCredits: bestResetCredits(primary: cachedProfile.resetCredits, fallback: previous.resetCredits)
                )
            }

            return (
                0,
                [
                    accountsResult.1,
                    profilePayloadText(from: resolvedProfiles),
                    tokenIDs.sorted().joined(separator: "\t")
                ].joined(separator: profileRefreshPayloadSeparator)
            )
        } completion: { result in
            guard result.0 == 0 else {
                finishQuotaReplayImmediately()
                isRefreshing = false
                statusText = tr("載入帳戶失敗", "Could not load accounts.")
                return
            }
            let payloadParts = result.1.components(separatedBy: profileRefreshPayloadSeparator)
            let accountsOutput = payloadParts.first ?? ""
            if payloadParts.count > 1 {
                profiles = profilePayload(from: payloadParts[1])
            }
            if payloadParts.count > 2 {
                localAuthTokenProfileIDs = Set(payloadParts[2].split(separator: "\t").map(String.init))
            }
            statusText = tr("\(profiles.count) 個 profile 就緒", "\(profiles.count) profiles ready")
            refreshProfileStatuses(
                accountsOutput: accountsOutput,
                displayNamesSnapshot: displayNamesSnapshot,
                showLoading: showLoading && hadProfiles,
                replayQuota: replayQuota,
                liveUsage: liveUsage,
                liveParallelism: liveParallelism,
                statusTimeout: statusTimeout,
                respectBackoff: respectBackoff
            )
        }
    }

    private func refreshProfileStatuses(
        accountsOutput: String,
        displayNamesSnapshot: [String: String],
        showLoading: Bool,
        replayQuota: Bool,
        liveUsage: Bool,
        liveParallelism: Int?,
        statusTimeout: TimeInterval?,
        respectBackoff: Bool
    ) {
        let loading = showLoading ? tr("更新用量...", "Updating usage...") : nil
        let previousProfiles = profiles

        runBackground(loading) {
            var environment = ProcessInfo.processInfo.environment
            let resolvedParallelism = max(1, liveParallelism ?? (liveUsage ? liveUsageParallelism : 2))
            let resolvedTimeout = statusTimeout ?? (liveUsage ? liveUsageStatusTimeout : 8)
            environment["CODEX_USAGE_LIVE_LOOKUP"] = liveUsage ? "1" : "0"
            environment["CODEX_USAGE_RESPECT_BACKOFF"] = respectBackoff ? "1" : "0"
            environment["STATUS_PARALLELISM"] = "\(resolvedParallelism)"
            if liveUsage {
                environment["USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS"] = "3"
                environment["USAGE_DIRECT_TIMEOUT_SECONDS"] = "6"
                environment["TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS"] = "2"
                environment["TOKEN_REFRESH_TIMEOUT_SECONDS"] = "6"
                environment["APP_SERVER_USAGE_TIMEOUT_SECONDS"] = "5"
            }
            let statusResult = runCodexScript(scriptPath, ["list-accounts-status"], wait: true, timeout: resolvedTimeout, environment: environment)
            let profiles = parsedCodexProfiles(
                accountsOutput: accountsOutput,
                statusOutput: statusResult.0 == 0 ? statusResult.1 : "",
                displayNames: displayNamesSnapshot
            )
            let tokenIDs = collectLocalAuthTokenProfileIDs(in: profiles)
            let statusIDs = Set(statusResult.1.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return parts.first
            })
            let previousByID = Dictionary(uniqueKeysWithValues: previousProfiles.map { ($0.id, $0) })
            let payload = profiles.map {
                let hasLocalTokens = tokenIDs.contains($0.id)
                let resolvedProfile = profileWithCachedUsageFallback(
                    profileWithLocalAuthTokenFallback($0, hasLocalTokens: hasLocalTokens),
                    hasLocalTokens: hasLocalTokens
                )
                let profile = (!statusIDs.contains(resolvedProfile.id) && resolvedProfile.authStatus == "unknown" && resolvedProfile.quota == "unknown")
                    ? (previousByID[$0.id] ?? $0)
                    : resolvedProfile
                return [
                    profile.id, profile.displayName, profile.home, profile.authStatus, profile.authMode,
                    profile.lastRefresh, profile.quota, profile.reset, profile.resetCredits
                ].joined(separator: "\t")
            }.joined(separator: "\n")
            return (
                profiles.isEmpty ? statusResult.0 : 0,
                [
                    payload,
                    tokenIDs.sorted().joined(separator: "\t")
                ].joined(separator: profileRefreshPayloadSeparator)
            )
        } completion: { result in
            isRefreshing = false
            guard result.0 == 0 else {
                finishQuotaReplayImmediately()
                statusText = tr("用量更新失敗", "Usage update failed")
                return
            }
            let payloadParts = result.1.components(separatedBy: profileRefreshPayloadSeparator)
            let incomingProfiles = profilePayload(from: payloadParts.first ?? "")
            if payloadParts.count > 1 {
                localAuthTokenProfileIDs = Set(payloadParts[1].split(separator: "\t").map(String.init))
            }
            withAnimation(.easeInOut(duration: 0.24)) {
                profiles = stabilizedProfilesAfterRefresh(incomingProfiles, previousProfiles: previousProfiles)
            }
            if replayQuota {
                replayQuotaMeters()
            }
            statusText = tr("\(profiles.count) 個 profile 就緒", "\(profiles.count) profiles ready")
            attemptQuotaPoolFailoverIfNeeded()
            scheduleLiveUsageBackfillIfNeeded(profiles, triggeredByLiveUsage: liveUsage)
        }
    }

    private func replayQuotaMeters() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            startResetReturnFill()
        }
    }

    private func finishQuotaReplayImmediately() {
        resetScrambleRunID += 1
        withAnimation(.easeOut(duration: 0.16)) {
            quotaReplayActive = false
        }
        resetScrambleActive = false
        resetScrambleReturning = false
        resetScrambleSeed = 0
    }

    private func startResetReturnFill() {
        resetScrambleRunID += 1
        let runID = resetScrambleRunID
        resetScrambleActive = true
        resetScrambleReturning = true
        resetScrambleSeed = 0

        for index in 0...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.046) {
                guard resetScrambleRunID == runID else { return }
                resetScrambleSeed = index
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) {
            guard resetScrambleRunID == runID else { return }
            withAnimation(.spring(response: 0.62, dampingFraction: 0.70)) {
                quotaReplayActive = false
            }
            resetScrambleActive = false
            resetScrambleReturning = false
        }
    }

    private func startResetScramble() {
        resetScrambleRunID += 1
        let runID = resetScrambleRunID
        resetScrambleActive = true
        resetScrambleReturning = false
        resetScrambleSeed = 0
        for index in 0...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.055) {
                guard resetScrambleRunID == runID else { return }
                resetScrambleSeed = index
            }
        }
    }

    private func stabilizedProfilesAfterRefresh(_ incoming: [CodexProfile], previousProfiles: [CodexProfile]) -> [CodexProfile] {
        let previousByID = Dictionary(uniqueKeysWithValues: previousProfiles.map { ($0.id, $0) })

        return incoming.map { profile -> CodexProfile in
            let rawProfile = profile
            let hasLocalTokens = localAuthTokenProfileIDs.contains(rawProfile.id)
            let localProfile = profileWithCachedUsageFallback(
                profileWithLocalAuthTokenFallback(rawProfile, hasLocalTokens: hasLocalTokens),
                hasLocalTokens: hasLocalTokens
            )

            if localProfile.authStatus == "login_needed" || localProfile.authStatus == "auth_incomplete" || localProfile.authStatus == "auth_invalid" {
                return CodexProfile(
                    id: localProfile.id,
                    displayName: localProfile.displayName,
                    home: localProfile.home,
                    authStatus: localProfile.authStatus,
                    authMode: localProfile.authMode,
                    lastRefresh: localProfile.lastRefresh,
                    quota: localProfile.quota,
                    reset: localProfile.reset,
                    resetCredits: localProfile.resetCredits
                )
            }

            let profile = profileWithCachedUsageFallback(
                profileWithConservativeLocalAuthFallback(localProfile, hasLocalTokens: hasLocalTokens),
                hasLocalTokens: hasLocalTokens
            )
            let previous = previousByID[profile.id]

            if profile.authStatus == "unknown", let previous {
                let preservePreviousUsage = shouldPreservePreviousUsage(previous)
                return CodexProfile(
                    id: profile.id,
                    displayName: profile.displayName,
                    home: profile.home,
                    authStatus: mergedAuthStatus(previous: previous.authStatus, current: profile.authStatus),
                    authMode: previous.authMode,
                    lastRefresh: previous.lastRefresh,
                    quota: preservePreviousUsage ? previous.quota : profile.quota,
                    reset: preservePreviousUsage ? previous.reset : profile.reset,
                    resetCredits: bestResetCredits(primary: profile.resetCredits, fallback: previous.resetCredits)
                )
            }

            if profile.quota == "unknown", let previous, shouldPreservePreviousUsage(previous) {
                return CodexProfile(
                    id: profile.id,
                    displayName: profile.displayName,
                    home: profile.home,
                    authStatus: profile.authStatus,
                    authMode: profile.authMode,
                    lastRefresh: profile.lastRefresh,
                    quota: previous.quota,
                    reset: previous.reset,
                    resetCredits: bestResetCredits(primary: profile.resetCredits, fallback: previous.resetCredits)
                )
            }

            return profile
        }
    }

    private func profileWithLocalAuthTokenFallback(_ profile: CodexProfile, hasLocalTokens knownHasLocalTokens: Bool? = nil) -> CodexProfile {
        guard profile.authStatus == "unknown"
                || profile.authStatus == "checking"
                || profile.authStatus == "login_needed"
                || profile.authStatus == "auth_incomplete"
        else {
            return profile
        }

        guard profile.authStatus != "auth_invalid" else {
            return profile
        }

        let hasLocalTokens = knownHasLocalTokens ?? localAuthTokensExist(in: profile.home)
        guard hasLocalTokens else {
            let authURL = URL(fileURLWithPath: profile.home).appendingPathComponent("auth.json")
            let fallbackStatus = FileManager.default.fileExists(atPath: authURL.path) ? "auth_incomplete" : "login_needed"
            return CodexProfile(
                id: profile.id,
                displayName: profile.displayName,
                home: profile.home,
                authStatus: fallbackStatus,
                authMode: profile.authMode,
                lastRefresh: profile.lastRefresh,
                quota: profile.quota,
                reset: profile.reset,
                resetCredits: profile.resetCredits
            )
        }

        return CodexProfile(
            id: profile.id,
            displayName: profile.displayName,
            home: profile.home,
            authStatus: "signed_in_local",
            authMode: profile.authMode == "unknown" ? "checking" : profile.authMode,
            lastRefresh: profile.lastRefresh,
            quota: profile.quota,
            reset: profile.reset,
            resetCredits: profile.resetCredits
        )
    }

    private func profileWithConservativeLocalAuthFallback(_ profile: CodexProfile, hasLocalTokens knownHasLocalTokens: Bool? = nil) -> CodexProfile {
        guard profile.authStatus == "unknown",
              profile.quota != "unknown",
              (knownHasLocalTokens ?? localAuthTokensExist(in: profile.home))
        else {
            return profile
        }

        return CodexProfile(
            id: profile.id,
            displayName: profile.displayName,
            home: profile.home,
            authStatus: "signed_in_local",
            authMode: profile.authMode,
            lastRefresh: profile.lastRefresh,
            quota: profile.quota,
            reset: profile.reset,
            resetCredits: profile.resetCredits
        )
    }

    private func profileHasLocalAuthTokens(_ profile: CodexProfile) -> Bool {
        localAuthTokenProfileIDs.contains(profile.id)
    }

    private func profilePayload(from payload: String) -> [CodexProfile] {
        payload.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 8 else { return nil }
            return CodexProfile(
                id: parts[0],
                displayName: parts[1],
                home: parts[2],
                authStatus: parts[3],
                authMode: parts[4],
                lastRefresh: parts[5],
                quota: parts[6],
                reset: parts[7],
                resetCredits: parts.count > 8 ? parts[8] : "unknown"
            )
        }
    }

    private func createAccount() {
        let defaultName = nextDefaultAccountName()
        guard let name = promptForAccountName(
            title: tr("新增帳戶", "New Account"),
            message: tr("建立全新空白 profile；唔會自動同步舊對話。", "Create a new blank profile; old conversations will not sync automatically."),
            defaultName: defaultName
        ) else { return }
        runBackground(tr("建立帳戶...", "Creating account...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SHARED_SESSIONS"] = "0"
            environment["CODEX_SYNC_THREAD_HISTORY"] = "0"
            return runCodexScript(scriptPath, ["init-account", name], wait: true, timeout: 60, environment: environment)
        } completion: { result in
            guard result.0 == 0 else {
                alertMessage(tr("建立帳戶失敗", "Could Not Create Account"), result.1)
                return
            }
            displayNames[sanitizedProfileId(name)] = name
            UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
            refreshProfiles(showLoading: false)
            openAccount(name, displayName: name, syncBeforeLaunch: false)
        }
    }

    private func nextDefaultAccountName() -> String {
        "Account \(profiles.count + 1)"
    }

    private func sanitizedProfileId(_ rawName: String) -> String {
        let lower = rawName.lowercased()
        var result = ""
        var previousDash = false

        for scalar in lower.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isNumber = value >= 48 && value <= 57
            let isAllowedSymbol = scalar == "." || scalar == "_" || scalar == "-"

            if isLetter || isNumber || isAllowedSymbol {
                result.unicodeScalars.append(scalar)
                previousDash = scalar == "-"
            } else if !previousDash {
                result.append("-")
                previousDash = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func openAccount(_ name: String, displayName: String? = nil, syncBeforeLaunch: Bool = false) {
        let requestedName = displayName ?? name
        let route = quotaPoolRoute(for: name)
        let targetID = route?.target.id ?? name
        let targetName = route?.target.displayName ?? requestedName
        let targetProfile = route?.target ?? profiles.first(where: { $0.id == targetID })
        let sharesLocalHistory = targetProfile.map { profileHistoryMode(for: $0) == .shared } ?? true
        let launchCommand = syncBeforeLaunch ? "launch-account" : "launch-account-nosync"
        var launchArguments = [launchCommand, targetID]
        if !targetName.isEmpty {
            launchArguments.append(targetName)
        }
        let requestedID = sanitizedProfileId(name)
        let targetProfileID = sanitizedProfileId(targetID)
        let busyIDs = Set([requestedID, targetProfileID])
        guard !isClosingAllAccounts, busyProfiles.isDisjoint(with: busyIDs) else { return }
        startUsageSession()
        busyIDs.forEach { setProfileBusy($0, true) }
        let loadingText: String
        if syncBeforeLaunch {
            loadingText = tr("正在同步對話同記憶，再打開 \(targetName)...", "Syncing history and memory, then opening \(targetName)...")
        } else {
            loadingText = tr("正在打開 \(targetName)...", "Opening \(targetName)...")
        }
        runBackground(loadingText, queue: codexAccountsLaunchQueue) {
            if route?.didSwitch == true {
                _ = runCodexScript(scriptPath, ["close-account", name], wait: true, timeout: 12)
            }

            var launchEnvironment = ProcessInfo.processInfo.environment
            launchEnvironment["CODEX_PRELAUNCH_SYNC"] = syncBeforeLaunch ? "1" : "0"
            launchEnvironment["CODEX_SHARED_SESSIONS"] = sharesLocalHistory ? "1" : "0"
            launchEnvironment["CODEX_SYNC_THREAD_HISTORY"] = syncBeforeLaunch && sharesLocalHistory ? "1" : "0"
            if syncBeforeLaunch {
                launchEnvironment["CODEX_PRELAUNCH_SYNC_LOCK_MAX_WAITS"] = "8"
                launchEnvironment["CODEX_RSYNC_MAX_WAITS"] = "50"
                launchEnvironment["CODEX_RSYNC_WAIT_SECONDS"] = "0.08"
            }
            return runCodexScript(
                scriptPath,
                launchArguments,
                wait: true,
                timeout: 60,
                environment: launchEnvironment
            )
        } completion: { result in
            let releaseDelay: TimeInterval = result.0 == 0 ? 1.45 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) {
                busyIDs.forEach { setProfileBusy($0, false) }
            }
            quotaPoolFailoverInProgress = false
            if result.0 == 0 {
                activeQuotaPoolProfileID = targetID
            }
            let failureText: String
            if syncBeforeLaunch {
                failureText = tr("同步或打開失敗", "Sync or open failed")
            } else {
                failureText = tr("打開失敗", "Open failed")
            }
            statusText = result.0 == 0 ? tr("已打開 \(targetName)", "Opened \(targetName)") : failureText
            if result.0 != 0 {
                let detail = trimmedToolOutput(result.1, maxLength: 900)
                let fallback = tr("Codex 未能確認啟動。請稍後再試。", "Codex could not be verified as running. Please try again.")
                alertMessage(failureText, detail.isEmpty ? fallback : detail)
            }
        }
    }

    private func closeAccount(_ profile: CodexProfile) {
        guard !isClosingAllAccounts, !busyProfiles.contains(profile.id) else { return }
        setProfileBusy(profile.id, true)
        runBackground(tr("關閉 \(profile.displayName)...", "Closing \(profile.displayName)..."), queue: codexAccountsLaunchQueue) {
            runCodexScript(scriptPath, ["close-account", profile.id], wait: true, timeout: 25)
        } completion: { result in
            setProfileBusy(profile.id, false)
            if result.0 == 0, activeQuotaPoolProfileID == profile.id {
                activeQuotaPoolProfileID = nil
                quotaPoolFailoverInProgress = false
            }
            statusText = result.0 == 0
                ? tr("已關閉 \(profile.displayName)", "Closed \(profile.displayName)")
                : tr("關閉失敗", "Close failed")
            if result.0 != 0 {
                alertMessage(tr("關閉失敗", "Close failed"), trimmedToolOutput(result.1, maxLength: 900))
            }
        }
    }

    private func closeAllAccounts() {
        guard !isClosingAllAccounts else { return }
        isClosingAllAccounts = true
        runBackground(tr("關閉全部 Codex 視窗...", "Closing all Codex windows..."), queue: codexAccountsLaunchQueue) {
            runCodexScript(scriptPath, ["close-all-accounts"], wait: true, timeout: 35)
        } completion: { result in
            isClosingAllAccounts = false
            if result.0 == 0 {
                finishUsageSession()
                activeQuotaPoolProfileID = nil
                quotaPoolFailoverInProgress = false
            }
            statusText = result.0 == 0
                ? tr("已關閉全部 Codex 視窗", "Closed all Codex windows")
                : tr("關閉全部失敗", "Close all failed")
            if result.0 != 0 {
                alertMessage(tr("關閉全部失敗", "Close all failed"), trimmedToolOutput(result.1, maxLength: 900))
            }
        }
    }

    private func attemptQuotaPoolFailoverIfNeeded() {
        guard autoQuotaPool,
              !quotaPoolFailoverInProgress,
              activeOperationCount == 0,
              let activeID = activeQuotaPoolProfileID,
              let activeProfile = profiles.first(where: { $0.id == activeID }),
              isQuotaDepleted(activeProfile),
              bestQuotaPoolProfile(excluding: activeProfile.id) != nil
        else {
            return
        }

        quotaPoolFailoverInProgress = true
        statusText = tr(
            "\(activeProfile.displayName) quota 已用完",
            "\(activeProfile.displayName) quota is depleted"
        )
        openAccount(activeProfile.id, displayName: activeProfile.displayName)
    }

    private func syncMemories(silent: Bool = false) {
        guard !isSyncing else { return }
        isSyncing = true
        if silent {
            lastAutoSyncAt = Date()
        }
        let loading = silent ? nil : tr("同步對話同記憶...", "Syncing history and memory...")

        runBackground(loading) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SHARED_SESSIONS"] = "1"
            environment["CODEX_SYNC_THREAD_HISTORY"] = "1"
            if silent {
                environment["CODEX_FAST_SYNC_PLUGIN_PAYLOADS"] = "0"
                environment["CODEX_SYNC_PLUGIN_PAYLOADS"] = "0"
            }
            return runCodexScript(scriptPath, ["sync-history-once"], wait: true, timeout: silent ? 35 : 60, environment: environment)
        } completion: { result in
            isSyncing = false
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            if result.0 == 0 {
                let completedAt = Date()
                lastAutoSyncAt = completedAt
                lastHistorySyncTimestamp = completedAt.timeIntervalSince1970
                statusText = silent ? tr("已自動同步 \(time)", "Auto synced at \(time)") : tr("對話同記憶已同步", "History and memory synced")
            } else if !silent {
                statusText = tr("同步失敗", "Sync failed")
            }
        }
    }

    private func cleanupSidebarProjects() {
        guard !isCleaningSidebarState else { return }
        isCleaningSidebarState = true

        runBackground(tr("整理側欄...", "Cleaning sidebar...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SYNC_THREAD_HISTORY"] = "0"
            return runCodexScript(scriptPath, ["cleanup-empty-projects"], wait: true, timeout: 45, environment: environment)
        } completion: { result in
            isCleaningSidebarState = false
            statusText = result.0 == 0
                ? tr("側欄整理完成", "Sidebar cleaned")
                : tr("側欄整理失敗", "Sidebar cleanup failed")
        }
    }

    private func repairLargeHistoryPayloads() {
        guard !isRepairingHistoryPayloads else { return }
        isRepairingHistoryPayloads = true

        runBackground(tr("清理大型對話...", "Cleaning large chats...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH"] = "1"
            return runCodexScript(scriptPath, ["repair-account1"], wait: true, timeout: 1800, environment: environment)
        } completion: { result in
            isRepairingHistoryPayloads = false
            switch result.0 {
            case 0:
                statusText = tr("已清理大型對話", "Large chats cleaned")
            case 28:
                statusText = tr("空間不足，已安全停止清理", "Low disk space; cleanup stopped safely")
            case 75:
                statusText = tr("請先關閉 Codex，或已有清理程序運行中", "Close Codex first, or wait for the current cleanup")
            default:
                statusText = tr("清理大型對話失敗", "Large chat cleanup failed")
            }
        }
    }

    private func shareAll() {
        runBackground(tr("同步共享 Profile 對話...", "Syncing shared profile history...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SHARED_SESSIONS"] = "1"
            let linkResult = runCodexScript(scriptPath, ["link-all-history"], wait: true, timeout: 60, environment: environment)
            guard linkResult.0 == 0 else { return linkResult }
            environment["CODEX_SYNC_THREAD_HISTORY"] = "1"
            return runCodexScript(scriptPath, ["sync-history-once"], wait: true, timeout: 60, environment: environment)
        } completion: { result in
            statusText = result.0 == 0
                ? tr("已同步共享 Profile；私人 Profile 已略過", "Shared profiles synced; private profiles skipped")
                : tr("共享同步失敗", "Shared profile sync failed")
            refreshProfiles(showLoading: false)
        }
    }

    private func renameProfile(_ profile: CodexProfile) {
        guard let newName = promptForAccountName(title: tr("改名", "Rename Profile"), message: tr("輸入 \(profile.displayName) 嘅顯示名。", "Enter a display name for \(profile.displayName).")) else { return }
        displayNames[profile.id] = newName
        UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
        refreshProfiles(showLoading: false)
        statusText = tr("已改名 \(profile.id)", "Renamed \(profile.id)")
    }

    private func chooseCustomIcon(for profile: CodexProfile) {
        let panel = NSOpenPanel()
        panel.title = tr("選擇 \(profile.displayName) 嘅 Icon 圖片", "Choose an icon image for \(profile.displayName)")
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK,
              let sourceURL = panel.url,
              let image = NSImage(contentsOf: sourceURL),
              let pngData = squareIconPNGData(from: image, size: 512)
        else { return }

        let targetURL = customIconURL(for: profile.id)
        do {
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData.write(to: targetURL, options: .atomic)
            iconVersion += 1
            statusText = tr("已更新 \(profile.displayName) icon", "Updated \(profile.displayName) icon")
        } catch {
            alertMessage(tr("Icon 更新失敗", "Icon Update Failed"), error.localizedDescription)
        }
    }

    private func squareIconPNGData(from image: NSImage, size: CGFloat) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(source.width, source.height)
        let cropRect = CGRect(
            x: (source.width - side) / 2,
            y: (source.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = source.cropping(to: cropRect) else { return nil }

        let output = NSImage(size: NSSize(width: size, height: size))
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cropped, size: NSSize(width: size, height: size))
            .draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func revealProfile(_ profile: CodexProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.home)])
    }

    private func exportConversationPackage(from profile: CodexProfile) {
        runBackground(tr("讀取 \(profile.displayName) 可導出對話...", "Loading exportable conversations for \(profile.displayName)...")) {
            runCodexScript(scriptPath, ["list-exportable-threads", profile.id, "60"], wait: true, timeout: 45)
        } completion: { result in
            guard result.0 == 0 else {
                alertMessage(tr("讀取對話失敗", "Could Not Load Conversations"), result.1)
                return
            }
            let threads = parsedExportableThreads(result.1)
            guard !threads.isEmpty else {
                alertMessage(
                    tr("未搵到可導出對話", "No Exportable Conversations"),
                    tr("呢個 profile 暫時搵唔到有 rollout 檔案嘅本機對話。", "This profile does not currently have local conversations with rollout files.")
                )
                return
            }
            presentExportThreadPicker(profile: profile, threads: threads)
        }
    }

    private func presentExportThreadPicker(profile: CodexProfile, threads: [ExportableThread]) {
        let tableController = ExportThreadTableController(threads: threads)
        let summary = NSTextField(wrappingLabelWithString: tr(
            "已自動偵測到 \(threads.count) 條可導出對話。請剔選要傳送嘅對話；無剔選嘅對話唔會放入導出檔。",
            "Detected \(threads.count) exportable conversations. Tick only the conversations you want to send; unchecked conversations are not exported."
        ))
        summary.frame = NSRect(x: 0, y: 0, width: 700, height: 38)
        summary.font = NSFont.systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 3

        let rowHeight: CGFloat = 44
        let listWidth: CGFloat = 700
        let contentHeight = max(CGFloat(threads.count) * rowHeight, 300)
        let listContent = FlippedAccessoryView(frame: NSRect(x: 0, y: 0, width: listWidth, height: contentHeight))
        listContent.wantsLayer = true
        listContent.layer?.backgroundColor = NSColor.clear.cgColor

        for (index, thread) in threads.enumerated() {
            let y = CGFloat(index) * rowHeight
            let rowView = FlippedAccessoryView(frame: NSRect(x: 0, y: y, width: listWidth, height: rowHeight))
            rowView.wantsLayer = true
            rowView.layer?.backgroundColor = (index.isMultiple(of: 2) ? NSColor.controlBackgroundColor.withAlphaComponent(0.18) : NSColor.clear).cgColor

            let checkbox = NSButton(checkboxWithTitle: "", target: tableController, action: #selector(ExportThreadTableController.toggleSelection(_:)))
            checkbox.frame = NSRect(x: 8, y: 11, width: 22, height: 22)
            checkbox.tag = index
            checkbox.state = tableController.isSelected(thread) ? .on : .off
            rowView.addSubview(checkbox)

            let titleField = NSTextField(labelWithString: thread.title.isEmpty ? tr("未命名對話", "Untitled Conversation") : thread.title)
            titleField.frame = NSRect(x: 38, y: 5, width: 634, height: 18)
            titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            titleField.textColor = .labelColor
            titleField.lineBreakMode = .byTruncatingTail
            titleField.maximumNumberOfLines = 1
            titleField.toolTip = thread.title
            rowView.addSubview(titleField)

            let meta = "\(formattedExportThreadDate(thread.updatedAt))  ·  \(humanFileSize(thread.sizeBytes))  ·  \(thread.cwd)"
            let metaField = NSTextField(labelWithString: meta)
            metaField.frame = NSRect(x: 38, y: 24, width: 634, height: 15)
            metaField.font = NSFont.systemFont(ofSize: 10)
            metaField.textColor = .secondaryLabelColor
            metaField.lineBreakMode = .byTruncatingMiddle
            metaField.maximumNumberOfLines = 1
            metaField.toolTip = meta
            rowView.addSubview(metaField)

            listContent.addSubview(rowView)
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 46, width: listWidth, height: 300))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = listContent

        let generatedImages = NSButton(checkboxWithTitle: tr("包含已引用嘅生成圖片", "Include referenced generated images"), target: nil, action: nil)
        generatedImages.frame = NSRect(x: 0, y: 420, width: 460, height: 24)
        generatedImages.state = .off
        let localAssets = NSButton(checkboxWithTitle: tr("包含工作區入面被引用嘅檔案", "Include referenced workspace files"), target: nil, action: nil)
        localAssets.frame = NSRect(x: 0, y: 445, width: 460, height: 24)
        localAssets.state = .off

        let warning = NSTextField(wrappingLabelWithString: tr(
            "對話包會包含完整對話、工具輸出同壓縮記憶，可能有路徑、主機名、命令輸出甚至 secret。預設唔會包含 auth、cookies、Codex config 或整個工作區。",
            "The package includes the full conversation, tool outputs, and compacted context. It may contain paths, hostnames, command output, or secrets. Auth, cookies, Codex config, and full workspace snapshots are not included by default."
        ))
        warning.frame = NSRect(x: 0, y: 356, width: 700, height: 54)
        warning.font = NSFont.systemFont(ofSize: 12)
        warning.textColor = .secondaryLabelColor
        warning.maximumNumberOfLines = 4

        let fileWarning = NSTextField(wrappingLabelWithString: tr(
            "勾選檔案選項後，對方可以打開包入面嘅附件；只應分享俾可信隊友。",
            "If file options are enabled, the receiver can open the packaged attachments. Share only with trusted teammates."
        ))
        fileWarning.frame = NSRect(x: 0, y: 474, width: 700, height: 32)
        fileWarning.font = NSFont.systemFont(ofSize: 11)
        fileWarning.textColor = .secondaryLabelColor
        fileWarning.maximumNumberOfLines = 3

        let accessory = FlippedAccessoryView(frame: NSRect(x: 0, y: 0, width: 700, height: 510))
        accessory.addSubview(summary)
        accessory.addSubview(scroll)
        accessory.addSubview(warning)
        accessory.addSubview(generatedImages)
        accessory.addSubview(localAssets)
        accessory.addSubview(fileWarning)

        let alert = NSAlert()
        alert.messageText = tr("導出對話包", "Export Conversation Package")
        alert.informativeText = tr("選擇要傳送嘅對話；匯出後可以用 WhatsApp、Email 或其他方式傳俾另一部機導入。", "Choose the conversations to send. After export, you can send the package by WhatsApp, email, or another channel for import on another machine.")
        alert.accessoryView = accessory
        alert.addButton(withTitle: tr("選擇儲存位置", "Choose Save Location"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selectedThreads = tableController.selectedThreads()
        guard !selectedThreads.isEmpty else {
            alertMessage(
                tr("未選擇對話", "No Conversations Selected"),
                tr("請至少剔選一條對話先可以導出。", "Tick at least one conversation before exporting.")
            )
            return
        }

        var exportTargets: [(ExportableThread, URL)] = []
        if selectedThreads.count == 1, let thread = selectedThreads.first {
            let panel = NSSavePanel()
            panel.title = tr("儲存對話包", "Save Conversation Package")
            panel.nameFieldStringValue = safePackageFileName(title: thread.title, threadID: thread.id)
            if let packageType = UTType(filenameExtension: "codexshare") {
                panel.allowedContentTypes = [packageType]
            }
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let outputURL = panel.url else { return }
            exportTargets = [(thread, outputURL)]
        } else {
            let panel = NSOpenPanel()
            panel.title = tr("選擇儲存資料夾", "Choose Export Folder")
            panel.prompt = tr("選擇", "Choose")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let folderURL = panel.url else { return }
            var usedNames: Set<String> = []
            exportTargets = selectedThreads.map { thread in
                (thread, uniquePackageFileURL(directory: folderURL, thread: thread, usedNames: &usedNames))
            }
        }

        let includeGeneratedImages = generatedImages.state == .on
        let includeLocalAssets = localAssets.state == .on
        runBackground(tr("導出 \(exportTargets.count) 條對話...", "Exporting \(exportTargets.count) conversation(s)...")) {
            var outputLines: [String] = []
            var failureLines: [String] = []
            for (thread, outputURL) in exportTargets {
                var arguments = ["export-thread-package", profile.id, thread.id, outputURL.path]
                if includeGeneratedImages {
                    arguments.append("--include-generated-images")
                }
                if includeLocalAssets {
                    arguments.append("--include-local-assets")
                }
                let result = runCodexScript(scriptPath, arguments, wait: true, timeout: 600)
                if result.0 == 0 {
                    outputLines.append("exported=\(outputURL.path)")
                    outputLines.append(trimmedToolOutput(result.1, maxLength: 900))
                } else {
                    failureLines.append("\(thread.title): \(trimmedToolOutput(result.1, maxLength: 900))")
                }
            }
            if failureLines.isEmpty {
                return (0, outputLines.joined(separator: "\n"))
            }
            return (1, (outputLines + failureLines.map { "failed=\($0)" }).joined(separator: "\n"))
        } completion: { result in
            if result.0 == 0 {
                statusText = tr("已導出對話包", "Conversation package exported")
                let urls = exportTargets.map { $0.1 }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
                alertMessage(
                    tr("已導出對話包", "Export Complete"),
                    trimmedToolOutput(result.1, maxLength: 1600)
                )
            } else {
                alertMessage(tr("導出失敗", "Export Failed"), result.1)
            }
        }
    }

    private func importConversationPackage(defaultTarget profile: CodexProfile) {
        let panel = NSOpenPanel()
        panel.title = tr("選擇對話包", "Choose Conversation Package")
        if let packageType = UTType(filenameExtension: "codexshare") {
            panel.allowedContentTypes = [packageType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let packageURL = panel.url else { return }

        runBackground(tr("檢查對話包...", "Inspecting conversation package...")) {
            runCodexScript(scriptPath, ["inspect-thread-package", packageURL.path], wait: true, timeout: 60)
        } completion: { inspectResult in
            guard inspectResult.0 == 0 else {
                alertMessage(tr("讀取對話包失敗", "Could Not Inspect Package"), inspectResult.1)
                return
            }
            presentImportPackageConfirmation(packageURL: packageURL, defaultTarget: profile, preview: inspectResult.1)
        }
    }

    private func presentImportPackageConfirmation(packageURL: URL, defaultTarget profile: CodexProfile, preview: String) {
        let alert = NSAlert()
        alert.messageText = tr("導入對話包？", "Import Conversation Package?")
        alert.informativeText = tr(
            "建議導入到全部 profile，咁每個 Codex Account 打開都會見到同一條新對話。匯入會先備份目標 profile 嘅 SQLite/index/global state，並將呢條對話標記成最新。",
            "Importing into all profiles is recommended so every Codex Account can see the same new conversation. The import backs up each target profile's SQLite/index/global state first, then marks this conversation as the latest."
        )
        let previewField = NSTextField(wrappingLabelWithString: trimmedToolOutput(preview, maxLength: 1800))
        previewField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewField.textColor = .secondaryLabelColor
        previewField.maximumNumberOfLines = 14
        previewField.setFrameSize(NSSize(width: 560, height: 180))
        alert.accessoryView = previewField
        alert.addButton(withTitle: tr("導入全部 Profile", "Import All Profiles"))
        alert.addButton(withTitle: tr("只導入 \(profile.displayName)", "Only \(profile.displayName)"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let target: String
        if response == .alertFirstButtonReturn {
            target = "all"
        } else if response == .alertSecondButtonReturn {
            target = profile.id
        } else {
            return
        }

        runBackground(tr("導入對話包...", "Importing conversation package...")) {
            runCodexScript(scriptPath, ["import-thread-package", packageURL.path, target, "--mark-latest"], wait: true, timeout: 300)
        } completion: { result in
            if result.0 == 0 {
                statusText = tr("已導入對話包", "Conversation package imported")
                refreshProfiles(showLoading: false)
                alertMessage(tr("已導入對話包", "Import Complete"), trimmedToolOutput(result.1, maxLength: 1800))
            } else {
                alertMessage(tr("導入失敗", "Import Failed"), result.1)
            }
        }
    }

    private func trimmedToolOutput(_ output: String, maxLength: Int) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed.isEmpty ? tr("完成", "Done") : trimmed }
        return String(trimmed.prefix(maxLength)) + "\n..."
    }

    private func profileHistoryMode(for profile: CodexProfile) -> ProfileHistoryMode {
        if isHistoryAnchor(profile) {
            return .shared
        }

        let markerURL = URL(fileURLWithPath: profile.home)
            .appendingPathComponent(".codex-accounts-history-mode")
        if let marker = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if marker == "private" {
                return .privateOnly
            }
            if marker == "shared" {
                return .shared
            }
        }

        let sharedRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex-shared-history")
        let expectedPaths = [
            "session_index.jsonl": sharedRoot.appendingPathComponent("session_index.jsonl").path,
            "sessions": sharedRoot.appendingPathComponent("sessions").path,
            "shell_snapshots": sharedRoot.appendingPathComponent("shell_snapshots").path
        ]
        let fileManager = FileManager.default
        let allShared = expectedPaths.allSatisfy { item, expectedPath in
            let targetPath = URL(fileURLWithPath: profile.home).appendingPathComponent(item).path
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: targetPath) else {
                return false
            }
            let destinationURL: URL
            if destination.hasPrefix("/") {
                destinationURL = URL(fileURLWithPath: destination)
            } else {
                destinationURL = URL(fileURLWithPath: targetPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent(destination)
            }
            return destinationURL.resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: expectedPath).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return allShared ? .shared : .privateOnly
    }

    private func isHistoryAnchor(_ profile: CodexProfile) -> Bool {
        let anchorFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Codex Accounts/history-anchor-home")
        let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path
        let anchorPath = (try? String(contentsOf: anchorFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return URL(fileURLWithPath: profile.home).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: anchorPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func shareHistory(_ profile: CodexProfile) {
        guard profileHistoryMode(for: profile) != .shared,
              !busyProfiles.contains(profile.id)
        else { return }

        let alert = NSAlert()
        alert.messageText = tr(
            "同其他 Profile 共享 \(profile.displayName) 嘅本機對話？",
            "Share \(profile.displayName)'s local chats with other profiles?"
        )
        if profile.id == "opencodex-lab" {
            alert.informativeText = tr(
                "現有私人本機對話會合併入共享紀錄，其他 Profile 都可能見到，而且唔會自動拆返。OpenCodex 登入、設定、本機記憶同代理路由仍保持獨立。請先關閉呢個 Profile。",
                "Existing private local chats will be merged into shared history. Other profiles may see them, and this cannot be automatically undone. OpenCodex sign-in, settings, local memory, and proxy routing remain isolated. Close this profile first."
            )
        } else {
            alert.informativeText = tr(
                "現有私人本機對話會合併入共享紀錄，本機記憶之後亦會參與共享同步；其他 Profile 都可能見到，而且唔會自動拆返。請先關閉呢個 Profile。",
                "Existing private local chats will be merged into shared history, and local memories will join shared sync afterward. Other profiles may see them, and this cannot be automatically undone. Close this profile first."
            )
        }
        alert.addButton(withTitle: tr("共享本機對話", "Share Local Chats"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setProfileBusy(profile.id, true)
        runBackground(tr("共享 \(profile.displayName) 本機對話...", "Sharing \(profile.displayName) local chats..."), queue: codexAccountsLaunchQueue) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SHARED_SESSIONS"] = "1"
            return runCodexScript(scriptPath, ["link-history", profile.id], wait: true, timeout: 45, environment: environment)
        } completion: { result in
            setProfileBusy(profile.id, false)
            statusText = result.0 == 0
                ? tr("\(profile.displayName) 已改為共享本機對話", "\(profile.displayName) now shares local chats")
                : tr("共享失敗", "History share failed")
            if result.0 != 0 {
                alertMessage(tr("共享失敗", "History Share Failed"), trimmedToolOutput(result.1, maxLength: 900))
            }
            refreshProfiles(showLoading: false)
        }
    }

    private func separateHistory(_ profile: CodexProfile) {
        guard !isHistoryAnchor(profile),
              profileHistoryMode(for: profile) != .privateOnly,
              !busyProfiles.contains(profile.id)
        else { return }

        let alert = NSAlert()
        alert.messageText = tr(
            "將 \(profile.displayName) 設為私人本機對話？",
            "Make \(profile.displayName)'s local chats private?"
        )
        alert.informativeText = tr(
            "請先關閉呢個 Profile。之後佢唔會再見到其他 Profile 嘅本機對話，並會由空白私人側欄開始；先前同步到嘅本機記憶會先備份再重置。共享原檔唔會刪除。使用 OpenAI 模型時，內容仍會送到 OpenAI 處理，呢個唔係離線模式。",
            "Close this profile first. It will stop seeing other profiles' local chats and start with an empty private sidebar. Previously synced local memories are backed up, then reset. Shared source files are not deleted. Content is still sent to OpenAI when you use OpenAI models—this is not offline mode."
        )
        alert.addButton(withTitle: tr("設為私人", "Make Private"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setProfileBusy(profile.id, true)
        runBackground(tr("隔離 \(profile.displayName) 本機對話...", "Isolating \(profile.displayName) local chats..."), queue: codexAccountsLaunchQueue) {
            runCodexScript(scriptPath, ["separate-history", profile.id], wait: true, timeout: 45)
        } completion: { result in
            setProfileBusy(profile.id, false)
            statusText = result.0 == 0
                ? tr("\(profile.displayName) 已改為私人本機對話", "\(profile.displayName) now uses private local chats")
                : tr("私人模式設定失敗", "Could not enable private history")
            if result.0 != 0 {
                alertMessage(tr("私人模式設定失敗", "Could Not Enable Private History"), trimmedToolOutput(result.1, maxLength: 900))
            }
            refreshProfiles(showLoading: false)
        }
    }

    private func deleteProfile(_ profile: CodexProfile) {
        let alert = NSAlert()
        alert.messageText = tr("刪除 \(profile.displayName)？", "Delete \(profile.displayName)?")
        alert.informativeText = tr("會將本機登入資料同 app data 搬去 archive，唔係即刻永久刪除。Archive 位置：~/.codex-accounts-archive。", "This archives the profile's local login and app data so it disappears from this manager. The archive can be recovered from ~/.codex-accounts-archive.")
        alert.addButton(withTitle: tr("刪除 Profile", "Delete Profile"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runBackground(tr("刪除 \(profile.displayName)...", "Deleting \(profile.displayName)...")) {
            runCodexScript(scriptPath, ["delete-account", profile.id], wait: true, timeout: 45)
        } completion: { result in
            if result.0 == 0 {
                displayNames.removeValue(forKey: profile.id)
                UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
                refreshProfiles(showLoading: false)
                statusText = tr("已刪除 \(profile.displayName)", "Deleted \(profile.displayName)")
            } else {
                alertMessage(tr("刪除失敗", "Could Not Delete Profile"), result.1)
            }
        }
    }
}

// MARK: - 3.2 Workspace redesign
//
// Minimal, data-first layout. The one number that matters (quota left) is the largest thing on each row; status
// text only appears when something needs attention. Every action reuses the existing AccountsRootView logic, so only
// presentation, analytics and reminders are new. Kept in this file because those members are file-private.
//
// Analytics data sources (read-only):
// - <CODEX_HOME>/logs_2.sqlite, table logs: every Codex API response logs the x-codex-primary/secondary-used-percent,
//   -window-minutes and -reset-at headers with a timestamp, per profile (logs are never shared between profiles).
//   Codex prunes these logs after roughly ten days, so samples are copied into the app's own history file.
// - The same table's ts column gives activity: log rows closer than 5 minutes form one session.
// - Its thread_id column gives the conversations each profile actually ran.
// - The app's own quota refreshes are added as samples too.

private enum RDStatus {
    case ready, api, checking, noData, waiting, login, failed
}

private struct RDHoverFill: ViewModifier {
    let cornerRadius: CGFloat
    let base: Color
    let hover: Color
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering ? hover : base)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Whether focus is being moved with the keyboard. The system's blue focus ring is turned off for the whole
/// window; a quiet ring in the text colour is drawn instead, and only while Tab is in use, never after a click.
private final class RDKeyboardFocus: ObservableObject {
    static let shared = RDKeyboardFocus()
    @Published var active = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let wanted = event.type == .keyDown ? (event.keyCode == 48 ? true : self.active) : false
            if wanted != self.active { self.active = wanted }
            return event
        }
    }
}

private var rdReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

private struct RDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RDPressBody(configuration: configuration)
    }
}

private struct RDPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @ObservedObject private var keyboard = RDKeyboardFocus.shared

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !rdReduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .overlay {
                if isFocused && keyboard.active {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.55), lineWidth: 1.5)
                        .padding(-2)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Filled buttons brighten and pick up a soft glow under the pointer.
private struct RDHoverLift: ViewModifier {
    let tint: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let lit = hovering && isEnabled
        content
            .brightness(lit ? 0.07 : 0)
            .shadow(color: tint.opacity(lit ? 0.38 : 0), radius: 9, y: 3)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// Cards that can be picked rise slightly under the pointer.
private struct RDHoverScale: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !rdReduceMotion ? 1.018 : 1)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
    }
}

/// A slow breath for placeholders while something loads.
private struct RDPulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !rdReduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: 3.3 Themes, plans and pins
//
// A theme is a complete palette, designed twice: once for dark and once for light appearance. The appearance
// (system / dark / light) and the theme are chosen separately, so every theme works in both. Quota colours are
// shared by all themes so their meaning never changes: green is plenty left, red is nearly used up.

private func rdHex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}

private struct RDPalette {
    let isDark: Bool
    let canvas: Color       // main content background
    let sidebar: Color      // navigation column
    let surface: Color      // cards
    let raised: Color       // selected and hovered surfaces
    let inspector: Color    // right-hand detail column
    let text: Color
    let text2: Color
    let text3: Color
    let accent: Color       // primary actions, selection
    let accent2: Color      // secondary emphasis, charts
    let warm: Color         // third chart colour, highlights
    let onAccent: Color     // text and icons on the accent
    let ink: Color          // base for translucent fills and hairlines: white on dark, black on light

    var line: Color { ink.opacity(isDark ? 0.07 : 0.09) }
    /// Selected rows and navigation take a little of the theme's colour, so a theme is felt beyond its buttons.
    var selection: Color { accent.opacity(isDark ? 0.15 : 0.11) }
    var selectionLine: Color { accent.opacity(isDark ? 0.26 : 0.24) }
    var track: Color { ink.opacity(isDark ? 0.09 : 0.07) }
    var success: Color { isDark ? rdHex(0x34D399) : rdHex(0x15924F) }
    var amber: Color { isDark ? rdHex(0xF5A524) : rdHex(0xB06C0A) }
    var orange: Color { isDark ? rdHex(0xFF8A45) : rdHex(0xD0530C) }
    var danger: Color { isDark ? rdHex(0xFF9B8A) : rdHex(0xC2312A) }
    var ticket: Color { isDark ? rdHex(0xF5B14C) : rdHex(0xA8690B) }

    /// Remaining quota, 0% to 100%, as five stops: red, orange, amber, lime, green. Brighter on dark,
    /// deeper on light so a white label on the fill keeps its contrast.
    var levelStops: [UInt32] {
        isDark ? [0xFF4D5E, 0xFF8A3D, 0xFFC83D, 0xA3DE52, 0x2ED88A]
               : [0xDB2A40, 0xE8670F, 0xE0A008, 0x5FA51E, 0x16A05A]
    }

    private func levelRGB(_ percent: Int) -> (Double, Double, Double) {
        let stops = levelStops
        let position = Double(min(max(percent, 0), 100)) / 100 * Double(stops.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, stops.count - 1)
        let t = position - Double(lower)
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        let a = stops[lower], b = stops[upper]
        return (
            channel(a, 16) + (channel(b, 16) - channel(a, 16)) * t,
            channel(a, 8) + (channel(b, 8) - channel(a, 8)) * t,
            channel(a, 0) + (channel(b, 0) - channel(a, 0)) * t
        )
    }

    func level(_ percent: Int) -> Color {
        let rgb = levelRGB(percent)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// Label colour on a filled bar, from the fill's own brightness: near-black on light fills (amber, lime),
    /// white on deep ones (red, deep green).
    func onLevel(_ percent: Int) -> Color {
        let (r, g, b) = levelRGB(percent)
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.30 ? Color.black.opacity(0.80) : Color.white
    }
}

private struct RDTheme: Identifiable {
    let id: String
    let zh: String
    let en: String
    let moodZh: String
    let moodEn: String
    let glow: Double        // strength of the ambient colour behind the content; 0 for the neutral themes
    let dark: RDPalette
    let light: RDPalette

    func palette(dark isDark: Bool) -> RDPalette { isDark ? dark : light }

    // swiftlint:disable function_body_length
    static let all: [RDTheme] = {
        func dark(_ canvas: UInt32, _ sidebar: UInt32, _ surface: UInt32, _ raised: UInt32, _ inspector: UInt32,
                  _ text: UInt32, _ text2: UInt32, _ text3: UInt32,
                  _ accent: UInt32, _ accent2: UInt32, _ warm: UInt32, _ onAccent: UInt32) -> RDPalette {
            RDPalette(isDark: true, canvas: rdHex(canvas), sidebar: rdHex(sidebar), surface: rdHex(surface), raised: rdHex(raised),
                      inspector: rdHex(inspector), text: rdHex(text), text2: rdHex(text2), text3: rdHex(text3),
                      accent: rdHex(accent), accent2: rdHex(accent2), warm: rdHex(warm), onAccent: rdHex(onAccent), ink: .white)
        }
        func light(_ canvas: UInt32, _ sidebar: UInt32, _ surface: UInt32, _ raised: UInt32, _ inspector: UInt32,
                   _ text: UInt32, _ text2: UInt32, _ text3: UInt32,
                   _ accent: UInt32, _ accent2: UInt32, _ warm: UInt32, _ onAccent: UInt32 = 0xFFFFFF) -> RDPalette {
            RDPalette(isDark: false, canvas: rdHex(canvas), sidebar: rdHex(sidebar), surface: rdHex(surface), raised: rdHex(raised),
                      inspector: rdHex(inspector), text: rdHex(text), text2: rdHex(text2), text3: rdHex(text3),
                      accent: rdHex(accent), accent2: rdHex(accent2), warm: rdHex(warm), onAccent: rdHex(onAccent), ink: rdHex(0x10131A))
        }
        // Thirteen themes, each designed twice. Every text and accent colour is checked against the surfaces it
        // sits on (4.5:1 for text, 3:1 for chart colours); the light palettes were deepened until they passed.
        return [
            RDTheme(id: "violet", zh: "霓虹", en: "Neon",
                    moodZh: "電光紫配粉紅同青色", moodEn: "Electric violet and pink", glow: 1.0,
                    dark: dark(0x0F0E17, 0x14121F, 0x1A1828, 0x242036, 0x121019, 0xEEEDF5, 0xAAA6BF, 0x8B88A2, 0xA56DFF, 0xFF52B4, 0x55D2FF, 0x0E0B16),
                    light: light(0xF6F4FC, 0xEEEAF9, 0xFFFFFF, 0xE8E1FA, 0xFAF8FE, 0x1D1830, 0x554F66, 0x6A6582, 0x7438EE, 0xD12F8A, 0x0A86BD, 0xFFFFFF)),
            RDTheme(id: "graphite", zh: "石墨", en: "Graphite",
                    moodZh: "中性灰階，突出額度", moodEn: "Neutral greys", glow: 0.0,
                    dark: dark(0x111214, 0x16171A, 0x1C1D21, 0x26282D, 0x131416, 0xECEDEF, 0xA5A8AE, 0x878A91, 0xCDD5DE, 0x8A97A6, 0xF2F4F7, 0x111214),
                    light: light(0xF4F4F3, 0xEAEAE8, 0xFFFFFF, 0xE3E3E1, 0xF9F9F8, 0x1B1C1E, 0x4E5157, 0x64676D, 0x2A2D33, 0x5F6670, 0x8C939C, 0xFFFFFF)),
            RDTheme(id: "aurora", zh: "極光", en: "Aurora",
                    moodZh: "極地夜空，薄荷同冰川青", moodEn: "Polar mint and cyan", glow: 1.0,
                    dark: dark(0x08120F, 0x0B1814, 0x10201B, 0x172C25, 0x0A1512, 0xE6F4EF, 0x9DBDB2, 0x7F9D93, 0x2EE6A0, 0x2BD4E8, 0xC2F25E, 0x04120D),
                    light: light(0xF0F8F5, 0xE3F1EB, 0xFFFFFF, 0xD6EDE3, 0xF6FBF9, 0x0F2A22, 0x395A52, 0x586E63, 0x0B7E59, 0x0786A6, 0x5A9810, 0xFFFFFF)),
            RDTheme(id: "ocean", zh: "深海", en: "Ocean",
                    moodZh: "深海藍，天藍同水色", moodEn: "Navy, azure and aqua", glow: 1.0,
                    dark: dark(0x08101F, 0x0B1528, 0x101C33, 0x182841, 0x0A1324, 0xE7EEF9, 0x9DADC8, 0x7F8FAB, 0x4C9DFF, 0x2BDCEB, 0x8FA7FF, 0x061021),
                    light: light(0xF1F5FB, 0xE5ECF7, 0xFFFFFF, 0xDAE5F5, 0xF7F9FD, 0x0F1E36, 0x425468, 0x5C6883, 0x1D67D8, 0x0890A6, 0x4458CF, 0xFFFFFF)),
            RDTheme(id: "amber", zh: "日落", en: "Sunset",
                    moodZh: "黃昏橘子、珊瑚同金色", moodEn: "Tangerine and coral", glow: 1.0,
                    dark: dark(0x150D0B, 0x1C1210, 0x241815, 0x30211C, 0x170F0D, 0xF6ECE6, 0xC5ABA1, 0xA38B82, 0xFF9F2E, 0xFF5C5F, 0xFFD45C, 0x1A0D05),
                    light: light(0xFBF5EF, 0xF5EAE0, 0xFFFFFF, 0xF0E0D1, 0xFDF9F5, 0x2E1A10, 0x614D3D, 0x7D625B, 0xA85510, 0xC93545, 0xA87800, 0xFFFFFF)),
            RDTheme(id: "sakura", zh: "櫻花", en: "Sakura",
                    moodZh: "夜櫻同花瓣，粉紅配淡紫", moodEn: "Petal pink and lilac", glow: 1.0,
                    dark: dark(0x150D12, 0x1B1118, 0x241620, 0x301E2B, 0x170F14, 0xF7EAF1, 0xC7A7B9, 0xA5899B, 0xFF7EB6, 0xC792FF, 0xFFC2D9, 0x1A0811),
                    light: light(0xFDF4F7, 0xF9E8EF, 0xFFFFFF, 0xF4D9E5, 0xFEF8FA, 0x33121F, 0x644857, 0x81606D, 0xBA3872, 0x8650DA, 0xD06B96, 0xFFFFFF)),
            RDTheme(id: "forest", zh: "森林", en: "Forest",
                    moodZh: "苔蘚同松林，晨光蜜糖色", moodEn: "Moss, pine and honey", glow: 1.0,
                    dark: dark(0x0C110A, 0x10170E, 0x162014, 0x202C1C, 0x0E140C, 0xEBF2E6, 0xAABBA1, 0x8B9D83, 0x9BDB4D, 0x46B978, 0xF5B83D, 0x0B1405),
                    light: light(0xF4F7EF, 0xE9EFE1, 0xFFFFFF, 0xDEE8D1, 0xF8FAF5, 0x18240F, 0x455839, 0x5F6E57, 0x437919, 0x1F7044, 0xA4710A, 0xFFFFFF)),
            RDTheme(id: "midnight", zh: "午夜", en: "Midnight",
                    moodZh: "墨黑同鋼藍，金箔點綴", moodEn: "Ink, steel and gold", glow: 0.8,
                    dark: dark(0x07080D, 0x0B0D15, 0x10131E, 0x1A1E2D, 0x090B11, 0xF1EEE4, 0xADA99B, 0x8D8B81, 0xFFC53D, 0x8FA8E0, 0xFFE7A3, 0x120D00),
                    light: light(0xFAF8F2, 0xF1EDE1, 0xFFFFFF, 0xE9E2CF, 0xFCFBF7, 0x1C1A14, 0x555143, 0x6D695F, 0x906404, 0x3A53A0, 0xB08C1C, 0xFFFFFF)),
            RDTheme(id: "crimson", zh: "緋紅", en: "Crimson",
                    moodZh: "朱紅橙金，襯線稿", moodEn: "Vermilion and gold", glow: 1.0,
                    dark: dark(0x140A0B, 0x1B0F10, 0x241415, 0x321C1D, 0x170C0D, 0xF8EBE8, 0xC9A9A4, 0xA78A86, 0xFF5A4D, 0xFF9B3D, 0xFFD08A, 0x1C0503),
                    light: light(0xFCF4F2, 0xF7E8E4, 0xFFFFFF, 0xF3DAD4, 0xFEF9F8, 0x33110E, 0x644843, 0x81605D, 0xC8281E, 0xC25A06, 0xA8790A, 0xFFFFFF)),
            RDTheme(id: "mocha", zh: "摩卡", en: "Mocha",
                    moodZh: "咖啡奶泡，焦糖玫瑰", moodEn: "Coffee and caramel", glow: 0.8,
                    dark: dark(0x14100D, 0x1A1511, 0x221C17, 0x2E2620, 0x16120F, 0xF3EBE2, 0xBFAE9E, 0x9C8D7F, 0xE2A46B, 0xC98F8F, 0xF0DDB8, 0x1E1206),
                    light: light(0xF8F3EC, 0xEFE7DB, 0xFFFFFF, 0xE8DCCB, 0xFBF8F3, 0x2B1F16, 0x5A4C40, 0x72625C, 0x8F5A2B, 0xA24E57, 0x97761E, 0xFFFFFF)),
            RDTheme(id: "frost", zh: "霜雪", en: "Frost",
                    moodZh: "冰面藍灰，冰青紫藍", moodEn: "Blue-grey ice and cyan", glow: 0.9,
                    dark: dark(0x0C1114, 0x10171B, 0x161F24, 0x1F2B32, 0x0E1417, 0xE9F3F7, 0xA3B8C2, 0x8499A3, 0x7FDDF2, 0xA7B4FF, 0xE2F4FB, 0x06171C),
                    light: light(0xF3F8FA, 0xE6F0F4, 0xFFFFFF, 0xD8E8EE, 0xF8FBFC, 0x10242C, 0x3D575D, 0x5B6D77, 0x0E7791, 0x4A5BCB, 0x5B8799, 0xFFFFFF)),
            RDTheme(id: "cyber", zh: "電馭", en: "Cyber",
                    moodZh: "螢光青檸撞洋紅", moodEn: "Acid lime on black", glow: 1.0,
                    dark: dark(0x08090A, 0x0C0E10, 0x121518, 0x1B2024, 0x0A0B0D, 0xF0F5EC, 0xA8B3A6, 0x889387, 0xC8FF3D, 0xFF45C8, 0x3DE8FF, 0x0E1500),
                    light: light(0xF5F7F2, 0xEAEEE4, 0xFFFFFF, 0xDFE6D4, 0xFAFBF8, 0x151A10, 0x4B5443, 0x626B5E, 0x4D7800, 0xC2188F, 0x067F96, 0xFFFFFF)),
            RDTheme(id: "onyx", zh: "純黑", en: "Onyx",
                    moodZh: "OLED 全黑，一點紅", moodEn: "True black for OLED", glow: 0.0,
                    dark: dark(0x000000, 0x070708, 0x0E0E10, 0x1A1A1D, 0x040405, 0xF5F5F7, 0xA9A9B0, 0x86868D, 0xFFFFFF, 0xFF453A, 0xFFD60A, 0x000000),
                    light: light(0xFFFFFF, 0xF5F5F7, 0xFAFAFB, 0xE8E8ED, 0xFBFBFD, 0x0A0A0B, 0x545459, 0x6E6E74, 0x0A0A0B, 0xD70015, 0xB28700, 0xFFFFFF))
        ]
    }()
    // swiftlint:enable function_body_length

    static func theme(_ id: String) -> RDTheme {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

/// Plans an account can be tagged with by hand. Highest first; each has its own colour in every theme.
private enum RDTier: String, CaseIterable, Codable, Identifiable {
    case pro50, pro20, pro10, plus, free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro50: return "Pro 50x"
        case .pro20: return "Pro 20x"
        case .pro10: return "Pro 10x"
        case .plus: return "Plus"
        case .free: return "Free"
        }
    }

    /// For the inspector's row of five chips, where "Pro" is implied by the crown, bolt and sparkles.
    var shortTitle: String {
        switch self {
        case .pro50: return "50x"
        case .pro20: return "20x"
        case .pro10: return "10x"
        case .plus: return "Plus"
        case .free: return "Free"
        }
    }

    var symbol: String {
        switch self {
        case .pro50: return "crown.fill"
        case .pro20: return "bolt.fill"
        case .pro10: return "sparkles"
        case .plus: return "plus.circle.fill"
        case .free: return "leaf.fill"
        }
    }

    /// Gold for the top plan, then magenta, violet and sky blue; free accounts are a quiet slate.
    func color(dark: Bool) -> Color {
        switch self {
        case .pro50: return dark ? rdHex(0xF7C548) : rdHex(0xA67708)
        case .pro20: return dark ? rdHex(0xFF6FB5) : rdHex(0xC22E79)
        case .pro10: return dark ? rdHex(0xA987FF) : rdHex(0x6A40D6)
        case .plus: return dark ? rdHex(0x52C6F7) : rdHex(0x0A7DB0)
        case .free: return dark ? rdHex(0x9FB0C4) : rdHex(0x56657A)
        }
    }
}

/// The user's own background picture. It lives in Application Support, never inside the app or its source.
private enum RDBackdropStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Accounts/Appearance", isDirectory: true)
            .appendingPathComponent("backdrop.png")
    }

    static func load() -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Saves a copy no larger than 2400 px. A drawing on white paper becomes its lines on transparency; a picture
    /// that already has transparency, or a photo, is kept as it is.
    static func importPicture(from source: URL) -> Bool {
        guard let image = NSImage(contentsOf: source),
              let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let scale = min(1, 2400 / CGFloat(max(original.width, original.height)))
        let width = max(1, Int(CGFloat(original.width) * scale)), height = max(1, Int(CGFloat(original.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data else { return false }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let count = width * height

        var seeThrough = 0, paper = 0
        for index in 0..<count {
            let i = index * 4
            if pixels[i + 3] < 250 { seeThrough += 1 } else if min(pixels[i], pixels[i + 1], pixels[i + 2]) > 235 { paper += 1 }
        }
        if seeThrough * 50 < count, paper * 20 > count * 9 {
            // Mostly white and fully opaque: treat the white as paper. Faint paper noise goes, solid pen stays.
            let floor = 0.07, full = 0.62
            for index in 0..<count {
                let i = index * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let ink = 1 - min(r, g, b)
                let alpha = max(0, min(1, (ink - floor) / (full - floor)))
                guard alpha > 0 else {
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
                    continue
                }
                let amount = max(ink, 0.001)
                func lift(_ channel: Double) -> Double { min(1, max(0, (channel - (1 - amount)) / amount)) }
                pixels[i] = UInt8(lift(r) * alpha * 255)
                pixels[i + 1] = UInt8(lift(g) * alpha * 255)
                pixels[i + 2] = UInt8(lift(b) * alpha * 255)
                pixels[i + 3] = UInt8(alpha * 255)
            }
        }
        guard let result = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Command-line tools the helper script relies on. jq has shipped with macOS since version 15; python3 comes with
/// Apple's Command Line Tools. Without them quota and sync quietly do nothing, so the app says so instead.
private enum RDRequirements {
    static func missing() -> [String] {
        #if UI_PREVIEW
        if let forced = ProcessInfo.processInfo.environment["PREVIEW_MISSING_TOOLS"] {
            return forced.split(separator: ",").map(String.init)
        }
        #endif
        let files = FileManager.default
        var missing: [String] = []
        if !["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"].contains(where: files.isExecutableFile(atPath:)) {
            missing.append("jq")
        }
        var developerFolders = ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"]
        let select = Process()
        let output = Pipe()
        select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        select.arguments = ["-p"]
        select.standardOutput = output
        select.standardError = Pipe()
        if (try? select.run()) != nil {
            select.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let folder = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if select.terminationStatus == 0, !folder.isEmpty { developerFolders.append(folder) }
        }
        if !developerFolders.contains(where: { files.isExecutableFile(atPath: $0 + "/usr/bin/python3") }) {
            missing.append("python3")
        }
        return missing
    }
}

/// The strip you drag to resize the sidebar. AppKit rather than a SwiftUI gesture: it gets the real resize cursor
/// and takes the first click even when the app is in the background.
private struct RDResizeHandle: NSViewRepresentable {
    var tooltip: String
    var onHover: (Bool) -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onReset: () -> Void

    final class HandleView: NSView {
        var parent: RDResizeHandle?
        private var startX: CGFloat?
        private var moved = false

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { parent?.onHover(true) }
        override func mouseExited(with event: NSEvent) { parent?.onHover(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                parent?.onReset()
                return
            }
            startX = event.locationInWindow.x
            moved = false
            NSCursor.resizeLeftRight.push()   // Keeps the cursor when the pointer runs past the width limits.
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            moved = true
            parent?.onChanged(event.locationInWindow.x - startX)
        }
        override func mouseUp(with event: NSEvent) {
            guard let start = startX else { return }
            startX = nil
            NSCursor.pop()
            if moved { parent?.onEnded(event.locationInWindow.x - start) }
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.setAccessibilityRole(.splitter)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.parent = self
        view.toolTip = tooltip
        view.setAccessibilityLabel(tooltip)
    }
}

/// Whether the account list has scrolled, so a pinned group header only paints a background once it covers rows.
private struct RDListScrolledKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The account script writes the plan the usage API reports (free, plus, prolite, pro...) beside each
/// account's quota cache as `<id>.status.plan`. Only the plan name is stored there.
private enum RDPlanDetector {
    static func load(_ ids: [String]) -> [String: String] {
        var plans: [String: String] = [:]
        for id in ids {
            let url = codexUsageCacheFolder.appendingPathComponent("\(id).status.plan")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let plan = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !plan.isEmpty { plans[id] = plan }
        }
        return plans
    }

    /// The exact reset time of each quota window, as the script last saw it: profile -> window label -> time.
    static func exactResets(_ ids: [String]) -> [String: [String: TimeInterval]] {
        var result: [String: [String: TimeInterval]] = [:]
        for id in ids {
            let url = codexUsageCacheFolder.appendingPathComponent("\(id).status.resets")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var windows: [String: TimeInterval] = [:]
            for part in text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " / ") {
                let pieces = part.split(separator: " ")
                if pieces.count == 2, let time = TimeInterval(pieces[1]) { windows[String(pieces[0])] = time }
            }
            if !windows.isEmpty { result[id] = windows }
        }
        return result
    }

    /// Pro comes at $100, $200 and $500 a month. The API calls the $100 plan "prolite" and the $200 plan
    /// "pro"; any other Pro plan name is taken to be the $500 one.
    static func tier(forPlan plan: String) -> RDTier? {
        switch plan {
        case "free": return .free
        case "plus": return .plus
        case "prolite", "pro_lite", "pro-lite": return .pro10
        case "pro": return .pro20
        default: return plan.hasPrefix("pro") ? .pro50 : nil
        }
    }
}

/// Per-account choices that only this app knows about: the plan tag and the pin.
private struct RDAccountMeta: Codable, Equatable {
    var tier: RDTier?
    var pinnedAt: Double?   // pin order: smaller is higher

    var isEmpty: Bool { tier == nil && pinnedAt == nil }
}

private enum RDMetaStore {
    static let key = "rdAccountMeta.v1"

    static func load() -> [String: RDAccountMeta] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: RDAccountMeta].self, from: data) else { return [:] }
        return decoded
    }

    static func save(_ meta: [String: RDAccountMeta]) {
        let trimmed = meta.filter { !$0.value.isEmpty }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// One block of the account list.
private struct RDGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color?
    let profiles: [CodexProfile]
}

// MARK: Analytics engine

private struct RDQuotaSample: Codable, Hashable {
    let t: TimeInterval      // when it was observed
    let p: String            // profile id
    let w: Int               // window minutes: 300 = 5 hours, 10080 = 1 week, 43200 = 1 month
    let u: Double            // used percent
    let r: TimeInterval?     // reset at
}

private struct RDHistoryFile: Codable {
    var samples: [RDQuotaSample] = []
    var usage: [String: [String: Double]] = [:]     // day -> profile -> active seconds
    var threads: [String: [String: Int]] = [:]      // day -> profile -> conversations
    var lastLogTS: [String: Int64] = [:]            // profile -> last log row scanned for quota headers
}

private struct RDAccountInsight: Identifiable {
    let id: String
    let name: String
    let left: Int?
    let windowMinutes: Int?
    let used24h: Double?
    let used7d: Double?
    let perDay: Double?
    let resetAt: Date?
    let emptyAt: Date?
    let activeSeconds7d: Double
    let threads7d: Int
}

private struct RDDailyUsage: Identifiable {
    let id: String
    let day: Date
    let name: String
    let hours: Double
}

private struct RDChartPoint: Identifiable {
    let id: String
    let date: Date
    let left: Double
    let series: String
}

private struct RDAnalyticsSnapshot {
    let insights: [RDAccountInsight]
    let daily: [RDDailyUsage]
    let samplesByProfile: [String: [RDQuotaSample]]
    let scannedAt: Date
    let profilesWithLogs: Int
}

// MARK: Token analytics

/// Published standard API prices, US$ per 1M tokens (developers.openai.com/api/docs/pricing, read 2026-11-09).
/// The long prices apply above 272K input tokens in one request. Only used for an "API equivalent" estimate.
private struct RDModelRate {
    let input, cached, output, longInput, longCached, longOutput: Double
}

private let rdModelRates: [String: RDModelRate] = [
    "gpt-5.5": RDModelRate(input: 5, cached: 0.5, output: 30, longInput: 10, longCached: 1, longOutput: 45),
    "gpt-5.6-sol": RDModelRate(input: 4, cached: 0.4, output: 20, longInput: 8, longCached: 0.8, longOutput: 30),
    "gpt-5.6-terra": RDModelRate(input: 2, cached: 0.2, output: 12, longInput: 4, longCached: 0.4, longOutput: 18),
    "gpt-6-astra": RDModelRate(input: 10, cached: 1, output: 50, longInput: 20, longCached: 2, longOutput: 75),
    "gpt-6-sol": RDModelRate(input: 2, cached: 0.2, output: 10, longInput: 4, longCached: 0.4, longOutput: 15),
    "gpt-6-luna": RDModelRate(input: 0.1, cached: 0.01, output: 0.5, longInput: 0.2, longCached: 0.02, longOutput: 0.75),
    "gpt-6.1-sol": RDModelRate(input: 2, cached: 0.1, output: 10, longInput: 4, longCached: 0.2, longOutput: 15),
    "gpt-6.1-terra": RDModelRate(input: 1, cached: 0.05, output: 5, longInput: 2, longCached: 0.1, longOutput: 7.5)
]

/// Token use added up per conversation, hour, model and quota window. Numbers and ids only.
private struct RDTokenRow: Codable {
    var d: String           // local day
    var h: Int              // hour of the week, Monday 00:00 = 0
    var t: String           // conversation id
    var m: String           // model
    var e: String           // reasoning effort
    var q: Int64            // reset time of the quota window it used: this is what identifies the account
    var i: Double = 0       // fresh input
    var c: Double = 0       // cached input
    var x: Double = 0       // output, including reasoning
    var r: Double = 0       // reasoning output
    var u: Double = 0       // API equivalent, US$
    var n: Int = 0          // requests
    var s: Double = 0       // sum of each request's input size

    var total: Double { i + c + x }
}

private struct RDTokenCursor: Codable {
    var o: UInt64 = 0       // bytes read so far
    var i: Double = 0, c: Double = 0, x: Double = 0, r: Double = 0, t: Double = 0   // running totals at that point
    var m: String?, e: String?
}

private struct RDQuotaSpan: Codable {
    var lo: Double, hi: Double
    var tokens: Double = 0, usd: Double = 0
    var w: Int
}

private struct RDTokenLedger: Codable {
    var rows: [String: RDTokenRow] = [:]
    var cursors: [String: RDTokenCursor] = [:]
    var resetOwners: [String: [String]] = [:]   // reset time -> profiles seen with it; quota samples expire, this does not
    var threadOwners: [String: String] = [:]    // conversation -> the profile whose own logs show it running
    var spans: [String: RDQuotaSpan] = [:]      // reset time -> how far that window moved and what it took
}

private struct RDThreadFact {
    let id: String
    var tokens: Double
    var updated: TimeInterval
    let model: String
    let effort: String
    let isSubAgent: Bool
    let folder: String
    let title: String?
    var path: String?
    var pathSize: UInt64 = 0
}

private struct RDTurnFact {
    let thread: String
    let at: TimeInterval
    let seconds: Double
    let status: String
}

private struct RDTokenPool: Identifiable {
    let id: String
    let members: [String]
    let name: String
    let tokensPerPercent: Double?
    let usdPerFullWindow: Double?
    let windowMinutes: Int?
}

private struct RDTokenData {
    let rows: [(row: RDTokenRow, pool: String)]
    let threads: [String: RDThreadFact]
    let turns: [RDTurnFact]
    let threadPool: [String: String]
    let pools: [RDTokenPool]
}

private struct RDTokenTotals {
    var fresh = 0.0, cached = 0.0, output = 0.0, reasoning = 0.0, unsplit = 0.0, usd = 0.0, requestInput = 0.0
    var requests = 0

    var detailed: Double { fresh + cached + output }
    var total: Double { detailed + unsplit }

    mutating func add(_ row: RDTokenRow) {
        fresh += row.i
        cached += row.c
        output += row.x
        reasoning += row.r
        usd += row.u
        requests += row.n
        requestInput += row.s
    }
}

private struct RDTokenDayPoint: Identifiable {
    var id: String { "\(day)|\(kind)" }
    let day: String
    let date: Date
    let kind: String        // fresh, cached, output, unsplit
    let value: Double
}

private struct RDTokenShare: Identifiable {
    let id: String
    let label: String
    let detail: String?
    let tokens: Double
    let usd: Double
}

private struct RDAccountShare: Identifiable {
    let id: String          // pool id; empty when no account could be matched
    let name: String
    let totals: RDTokenTotals
    let pool: RDTokenPool?
}

private struct RDThreadShare: Identifiable {
    let id: String
    let fact: RDThreadFact
    let tokens: Double
}

private struct RDTokenReport {
    let totals: RDTokenTotals
    let previousTotal: Double?
    let days: [RDTokenDayPoint]
    let accounts: [RDAccountShare]
    let models: [RDTokenShare]
    let efforts: [RDTokenShare]
    let projects: [RDTokenShare]
    let top: [RDThreadShare]
    let heat: [Int: Double]
    let mainTokens: Double
    let subTokens: Double
    let mainCount: Int
    let subCount: Int
    let workSeconds: Double
    let turnsCompleted: Int
    let turnsFailed: Int
    let turnsInterrupted: Int
}

private enum RDTokenEngine {
    private static let lock = NSLock()
    private static let tokenNeedle = Array("\"type\":\"token_count\"".utf8)
    private static let contextNeedle = Array("\"type\":\"turn_context\"".utf8)
    // These markers sit at the start of a record, before any message text could begin.
    private static let headLength = 170
    private static let maxTokenLine = 64 * 1024
    private static let maxContextLine = 512 * 1024

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Accounts/Analytics", isDirectory: true)
            .appendingPathComponent("tokens-v1.json")
    }

    private static func load() -> RDTokenLedger {
        guard let data = try? Data(contentsOf: storeURL),
              let ledger = try? JSONDecoder().decode(RDTokenLedger.self, from: data) else { return RDTokenLedger() }
        return ledger
    }

    private static func save(_ ledger: RDTokenLedger) {
        let url = storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> Double {
        (dictionary[key] as? NSNumber)?.doubleValue ?? 0
    }

    /// Reads only what was added to a conversation's record since last time. Only token-count and turn-settings
    /// records are ever decoded, and only their numbers, model and effort are kept.
    @discardableResult
    private static func ingest(_ fact: RDThreadFact, path: String, into ledger: inout RDTokenLedger, dates: ISO8601DateFormatter) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var cursor = ledger.cursors[fact.id] ?? RDTokenCursor()
        if size < cursor.o {     // The file was rewritten: start this conversation again.
            ledger.rows = ledger.rows.filter { $0.value.t != fact.id }
            cursor = RDTokenCursor()
        }
        guard size > cursor.o else { return false }
        do { try handle.seek(toOffset: cursor.o) } catch { return false }

        func absorbContext(_ data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return }
            if let model = payload["model"] as? String { cursor.m = model }
            if let effort = payload["effort"] as? String { cursor.e = effort }
        }

        func absorbToken(_ data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let running = info["total_token_usage"] as? [String: Any] else { return }
            let total = number(running, "total_tokens")
            guard total > cursor.t else { return }     // The same reading is often sent more than once.
            let input = number(running, "input_tokens"), cached = number(running, "cached_input_tokens")
            let output = number(running, "output_tokens"), reasoning = number(running, "reasoning_output_tokens")
            let addedCached = max(0, cached - cursor.c)
            let addedFresh = max(0, max(0, input - cursor.i) - addedCached)
            let addedOutput = max(0, output - cursor.x)
            let addedReasoning = max(0, reasoning - cursor.r)
            let addedTotal = max(0, total - cursor.t)
            cursor.i = input; cursor.c = cached; cursor.x = output; cursor.r = reasoning; cursor.t = total

            guard let stamp = object["timestamp"] as? String, let date = dates.date(from: stamp) else { return }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
            let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            let slot = (((parts.weekday ?? 2) + 5) % 7) * 24 + (parts.hour ?? 0)

            let model = cursor.m ?? fact.model
            let effort = cursor.e ?? fact.effort
            let requestInput = (info["last_token_usage"] as? [String: Any]).map { number($0, "input_tokens") } ?? 0
            var usd = 0.0
            if let rate = rdModelRates[model] {
                let long = requestInput > 272_000
                usd = addedFresh * (long ? rate.longInput : rate.input)
                usd += addedCached * (long ? rate.longCached : rate.cached)
                usd += addedOutput * (long ? rate.longOutput : rate.output)
                usd /= 1_000_000
            }

            var resetKey: Int64 = 0
            var windowMinutes = 0
            var usedPercent: Double?
            if let limits = payload["rate_limits"] as? [String: Any] {
                for slotName in ["primary", "secondary"] {
                    guard let window = limits[slotName] as? [String: Any],
                          let reset = (window["resets_at"] as? NSNumber)?.int64Value,
                          let minutes = (window["window_minutes"] as? NSNumber)?.intValue,
                          minutes >= windowMinutes else { continue }
                    windowMinutes = minutes
                    resetKey = reset
                    usedPercent = (window["used_percent"] as? NSNumber)?.doubleValue
                }
            }

            let key = "\(fact.id)|\(day)|\(slot)|\(model)|\(effort)|\(resetKey)"
            var row = ledger.rows[key] ?? RDTokenRow(d: day, h: slot, t: fact.id, m: model, e: effort, q: resetKey)
            row.i += addedFresh
            row.c += addedCached
            row.x += addedOutput
            row.r += addedReasoning
            row.u += usd
            row.n += 1
            row.s += requestInput
            ledger.rows[key] = row

            if resetKey != 0, let usedPercent {
                let spanKey = String(resetKey)
                var span = ledger.spans[spanKey] ?? RDQuotaSpan(lo: usedPercent, hi: usedPercent, w: windowMinutes)
                span.lo = min(span.lo, usedPercent)
                span.hi = max(span.hi, usedPercent)
                span.tokens += addedTotal
                span.usd += usd
                ledger.spans[spanKey] = span
            }
        }

        func consider(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress, bytes.count > 20 else { return }
            let head = min(bytes.count, headLength)
            if bytes.count <= maxTokenLine, memmem(base, head, tokenNeedle, tokenNeedle.count) != nil {
                absorbToken(Data(bytes: base, count: bytes.count))
            } else if bytes.count <= maxContextLine, memmem(base, head, contextNeedle, contextNeedle.count) != nil {
                absorbContext(Data(bytes: base, count: bytes.count))
            }
        }

        var chunkStart = cursor.o
        var consumed = cursor.o
        var pending = Data()
        var skipping = false
        while true {
            let chunk: Data = autoreleasepool { (try? handle.read(upToCount: 4 << 20)) ?? Data() }
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var position = 0
                while position < buffer.count {
                    let start = base + position
                    let remaining = buffer.count - position
                    guard let newline = memchr(start, 10, remaining) else {
                        if !skipping {
                            if pending.count + remaining > maxContextLine {
                                skipping = true     // Too long to be a record we want; drop it unread.
                                pending.removeAll(keepingCapacity: true)
                            } else {
                                pending.append(start.assumingMemoryBound(to: UInt8.self), count: remaining)
                            }
                        }
                        position = buffer.count
                        break
                    }
                    let length = UnsafeRawPointer(newline) - start
                    if skipping {
                        skipping = false
                    } else if pending.isEmpty {
                        consider(UnsafeRawBufferPointer(start: start, count: length))
                    } else {
                        if pending.count + length <= maxContextLine {
                            pending.append(start.assumingMemoryBound(to: UInt8.self), count: length)
                            pending.withUnsafeBytes { consider($0) }
                        }
                        pending.removeAll(keepingCapacity: true)
                    }
                    position += length + 1
                    consumed = chunkStart + UInt64(position)
                }
            }
            chunkStart += UInt64(chunk.count)
        }
        cursor.o = consumed
        ledger.cursors[fact.id] = cursor
        return true
    }

    private static func readThreads(home: String, into threads: inout [String: RDThreadFact]) {
        let folder = home as NSString
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home) else { return }
        let states = names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
        guard let latest = states.last, let reader = RDSQLiteReader(path: folder.appendingPathComponent(latest)) else { return }
        var columns = Set<String>()
        reader.rows("PRAGMA table_info(threads)") { statement in
            if let name = RDSQLiteReader.text(statement, 1) { columns.insert(name) }
        }
        guard columns.contains("tokens_used") else { return }
        func pick(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        #if UI_PREVIEW
        let titleColumn = "NULL"    // Test renders never load conversation titles.
        #else
        let titleColumn = pick("title")
        #endif
        let sql = "SELECT id, tokens_used, updated_at, \(pick("model")), \(pick("reasoning_effort")), source, cwd, rollout_path, \(titleColumn) FROM threads"
        reader.rows(sql) { statement in
            guard let id = RDSQLiteReader.text(statement, 0) else { return }
            let tokens = Double(sqlite3_column_int64(statement, 1))
            let updated = TimeInterval(sqlite3_column_int64(statement, 2))
            // Profiles can hold different copies of one conversation's record; the longest is the most complete.
            let path = RDSQLiteReader.text(statement, 7)
            let size = path.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? NSNumber }?.uint64Value
            let usablePath = size == nil ? nil : path
            if var known = threads[id] {
                known.tokens = max(known.tokens, tokens)
                known.updated = max(known.updated, updated)
                if let size, size > known.pathSize {
                    known.path = usablePath
                    known.pathSize = size
                }
                threads[id] = known
                return
            }
            let cwd = RDSQLiteReader.text(statement, 6) ?? ""
            threads[id] = RDThreadFact(
                id: id,
                tokens: tokens,
                updated: updated,
                model: RDSQLiteReader.text(statement, 3) ?? "unknown",
                effort: RDSQLiteReader.text(statement, 4) ?? "—",
                isSubAgent: (RDSQLiteReader.text(statement, 5) ?? "").contains("subagent"),
                folder: cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent,
                title: RDSQLiteReader.text(statement, 8),
                path: usablePath,
                pathSize: size ?? 0
            )
        }
    }

    private static func readTurns(home: String, into turns: inout [String: RDTurnFact]) {
        guard let reader = RDSQLiteReader(path: (home as NSString).appendingPathComponent("thread_history_1.sqlite")) else { return }
        reader.rows("SELECT thread_id, turn_id, status, started_at, duration_ms FROM thread_turns") { statement in
            guard let thread = RDSQLiteReader.text(statement, 0), let turn = RDSQLiteReader.text(statement, 1) else { return }
            let key = "\(thread)|\(turn)"
            guard turns[key] == nil else { return }
            var started = Double(sqlite3_column_int64(statement, 3))
            if started > 100_000_000_000 { started /= 1000 }
            turns[key] = RDTurnFact(
                thread: thread,
                at: started,
                seconds: Double(sqlite3_column_int64(statement, 4)) / 1000,
                status: RDSQLiteReader.text(statement, 2) ?? ""
            )
        }
    }

    static func scan(profiles: [(id: String, name: String, home: String)]) -> RDTokenData {
        lock.lock()
        defer { lock.unlock() }
        var ledger = load()

        // A quota window's reset time is unique to one ChatGPT account, so it says who used the tokens. An unused
        // window has no fixed reset (it is always "now + window"), and times landing exactly on a minute came from
        // the app's own rounded text; either could match another account by chance, so both are skipped.
        for sample in RDAnalyticsEngine.load().samples {
            guard sample.u > 0, let reset = sample.r, Int64(reset) % 60 != 0 else { continue }
            let key = String(Int64(reset))
            var owners = ledger.resetOwners[key] ?? []
            if !owners.contains(sample.p) { owners.append(sample.p) }
            ledger.resetOwners[key] = owners
        }

        var threads: [String: RDThreadFact] = [:]
        var turnsByKey: [String: RDTurnFact] = [:]
        for profile in profiles {
            readThreads(home: profile.home, into: &threads)
            readTurns(home: profile.home, into: &turnsByKey)
            if let reader = RDSQLiteReader(path: (profile.home as NSString).appendingPathComponent("logs_2.sqlite")) {
                reader.rows("SELECT DISTINCT thread_id FROM logs WHERE thread_id IS NOT NULL AND thread_id <> ''") { statement in
                    guard let thread = RDSQLiteReader.text(statement, 0), ledger.threadOwners[thread] == nil else { return }
                    ledger.threadOwners[thread] = profile.id
                }
            }
        }

        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for fact in threads.values {
            guard let path = fact.path else { continue }
            autoreleasepool { _ = ingest(fact, path: path, into: &ledger, dates: dates) }
        }
        save(ledger)

        // Profiles seen with the same reset time are one ChatGPT account signed in more than once.
        var parent: [String: String] = [:]
        func find(_ value: String) -> String {
            var current = value
            while let next = parent[current], next != current { current = next }
            return current
        }
        var ownersByReset: [Int64: Set<String>] = [:]
        var clusters: [(lo: Int64, hi: Int64, owners: Set<String>)] = []
        for key in ledger.resetOwners.keys.compactMap({ Int64($0) }).sorted() {
            let owners = Set(ledger.resetOwners[String(key)] ?? [])
            if var last = clusters.last, key - last.hi <= 5 {
                last.hi = key
                last.owners.formUnion(owners)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append((key, key, owners))
            }
        }
        for cluster in clusters {
            for offset in (cluster.lo - 5)...(cluster.hi + 5) { ownersByReset[offset, default: []].formUnion(cluster.owners) }
            guard let first = cluster.owners.first else { continue }
            for owner in cluster.owners { parent[find(owner)] = find(first) }
        }

        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        var members: [String: [String]] = [:]
        for profile in profiles { members[find(profile.id), default: []].append(profile.id) }
        var poolOf: [String: String] = [:]
        for (_, group) in members {
            let id = group.sorted().joined(separator: "+")
            for profile in group { poolOf[profile] = id }
        }

        func pool(forReset reset: Int64) -> String {
            guard let owner = ownersByReset[reset]?.first else { return "" }
            return poolOf[owner] ?? ""
        }

        var tokensByThreadPool: [String: [String: Double]] = [:]
        var resolved: [(row: RDTokenRow, pool: String)] = []
        resolved.reserveCapacity(ledger.rows.count)
        for row in ledger.rows.values {
            let owner = pool(forReset: row.q)
            resolved.append((row, owner))
            if !owner.isEmpty { tokensByThreadPool[row.t, default: [:]][owner, default: 0] += row.total }
        }
        var threadPool: [String: String] = [:]
        for (thread, shares) in tokensByThreadPool {
            threadPool[thread] = shares.max { $0.value < $1.value }?.key
        }
        for (thread, profile) in ledger.threadOwners where threadPool[thread] == nil {
            threadPool[thread] = poolOf[profile]
        }

        // How much one percent of the long quota window buys, from windows that moved enough to measure.
        // One window reports reset times a few seconds apart, so neighbouring times are merged first.
        var windows: [(reset: Int64, last: Int64, span: RDQuotaSpan)] = []
        for key in ledger.spans.keys.compactMap({ Int64($0) }).sorted() {
            guard let span = ledger.spans[String(key)] else { continue }
            if var open = windows.last, key - open.last <= 5, open.span.w == span.w {
                open.last = key
                open.span.lo = min(open.span.lo, span.lo)
                open.span.hi = max(open.span.hi, span.hi)
                open.span.tokens += span.tokens
                open.span.usd += span.usd
                windows[windows.count - 1] = open
            } else {
                windows.append((key, key, span))
            }
        }
        // Records can be missing but never extra, so the window that shows the most per percent is closest to true.
        var conversion: [String: (tokens: Double, usd: Double, percent: Double, minutes: Int)] = [:]
        for (reset, _, span) in windows where span.hi - span.lo >= 30 {
            let owner = pool(forReset: reset)
            guard !owner.isEmpty else { continue }
            let percent = span.hi - span.lo
            if let best = conversion[owner], best.usd / best.percent >= span.usd / percent { continue }
            conversion[owner] = (span.tokens, span.usd, percent, span.w)
        }

        let order = profiles.map(\.id)
        var pools: [RDTokenPool] = []
        for (_, group) in members {
            let sorted = group.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            let id = group.sorted().joined(separator: "+")
            let entry = conversion[id]
            pools.append(RDTokenPool(
                id: id,
                members: sorted,
                name: sorted.map { names[$0] ?? $0 }.joined(separator: " · "),
                tokensPerPercent: entry.flatMap { $0.percent > 0 ? $0.tokens / $0.percent : nil },
                usdPerFullWindow: entry.flatMap { $0.percent > 0 ? $0.usd / $0.percent * 100 : nil },
                windowMinutes: entry?.minutes
            ))
        }

        return RDTokenData(
            rows: resolved,
            threads: threads,
            turns: Array(turnsByKey.values),
            threadPool: threadPool,
            pools: pools.sorted { $0.name < $1.name }
        )
    }

    /// One view of the data. `scope` is a pool id, or nil for every account; `days` of 0 means all time.
    /// Tokens with no per-request record are kept as "unsplit" on the conversation's last active day, so
    /// every total still adds up to what Codex counted.
    static func report(_ data: RDTokenData, scope: String?, days: Int) -> RDTokenReport {
        let now = Date()
        let start = days > 0 ? RDAnalyticsEngine.dayKey(now.addingTimeInterval(-Double(days - 1) * 86_400)) : ""
        let previousStart = days > 0 ? RDAnalyticsEngine.dayKey(now.addingTimeInterval(-Double(2 * days - 1) * 86_400)) : ""
        let startTime = days > 0 ? (RDAnalyticsEngine.dayDate(start)?.timeIntervalSince1970 ?? 0) : 0

        var totals = RDTokenTotals()
        var previous = 0.0
        var perDay: [String: RDTokenTotals] = [:]
        var perPool: [String: RDTokenTotals] = [:]
        var perModel: [String: (tokens: Double, usd: Double)] = [:]
        var perEffort: [String: (tokens: Double, usd: Double)] = [:]
        var perThread: [String: Double] = [:]
        var threadUSD: [String: Double] = [:]
        var heat: [Int: Double] = [:]
        var detailedAllTime: [String: Double] = [:]

        for (row, pool) in data.rows { detailedAllTime[row.t, default: 0] += row.total
            if row.d < start {
                if days > 0, row.d >= previousStart, scope == nil || pool == scope { previous += row.total }
                continue
            }
            perPool[pool, default: RDTokenTotals()].add(row)
            guard scope == nil || pool == scope else { continue }
            totals.add(row)
            perDay[row.d, default: RDTokenTotals()].add(row)
            perModel[row.m, default: (0, 0)].tokens += row.total
            perModel[row.m, default: (0, 0)].usd += row.u
            perEffort[row.e, default: (0, 0)].tokens += row.total
            perEffort[row.e, default: (0, 0)].usd += row.u
            perThread[row.t, default: 0] += row.total
            threadUSD[row.t, default: 0] += row.u
            heat[row.h, default: 0] += row.total
        }

        for fact in data.threads.values {
            let rest = fact.tokens - (detailedAllTime[fact.id] ?? 0)
            guard rest > 0, fact.updated > 0 else { continue }
            let pool = data.threadPool[fact.id] ?? ""
            let day = RDAnalyticsEngine.dayKey(Date(timeIntervalSince1970: fact.updated))
            if day < start {
                if days > 0, day >= previousStart, scope == nil || pool == scope { previous += rest }
                continue
            }
            perPool[pool, default: RDTokenTotals()].unsplit += rest
            guard scope == nil || pool == scope else { continue }
            totals.unsplit += rest
            perDay[day, default: RDTokenTotals()].unsplit += rest
            perModel[fact.model, default: (0, 0)].tokens += rest
            perEffort[fact.effort, default: (0, 0)].tokens += rest
            perThread[fact.id, default: 0] += rest
        }

        var dayPoints: [RDTokenDayPoint] = []
        let chartStart = days > 0 ? start : RDAnalyticsEngine.dayKey(now.addingTimeInterval(-89 * 86_400))
        for (day, value) in perDay where day >= chartStart {
            guard let date = RDAnalyticsEngine.dayDate(day) else { continue }
            for (kind, amount) in [("cached", value.cached), ("fresh", value.fresh), ("output", value.output), ("unsplit", value.unsplit), ("usd", value.usd)] where amount > 0 {
                dayPoints.append(RDTokenDayPoint(day: day, date: date, kind: kind, value: amount))
            }
        }

        var mainTokens = 0.0, subTokens = 0.0, mainCount = 0, subCount = 0
        var projectTokens: [String: (tokens: Double, usd: Double)] = [:]
        for (thread, tokens) in perThread {
            guard let fact = data.threads[thread] else { continue }
            if fact.isSubAgent { subTokens += tokens; subCount += 1 } else { mainTokens += tokens; mainCount += 1 }
            projectTokens[fact.folder, default: (0, 0)].tokens += tokens
            projectTokens[fact.folder, default: (0, 0)].usd += threadUSD[thread] ?? 0
        }

        var workSeconds = 0.0, completed = 0, failed = 0, interrupted = 0
        for turn in data.turns where turn.at >= startTime {
            guard scope == nil || (data.threadPool[turn.thread] ?? "") == scope else { continue }
            workSeconds += turn.seconds
            switch turn.status {
            case "completed": completed += 1
            case "failed": failed += 1
            case "interrupted": interrupted += 1
            default: break
            }
        }

        let poolsByID = Dictionary(uniqueKeysWithValues: data.pools.map { ($0.id, $0) })
        let accounts = perPool
            .map { RDAccountShare(id: $0.key, name: poolsByID[$0.key]?.name ?? "", totals: $0.value, pool: poolsByID[$0.key]) }
            .filter { $0.totals.total > 0 }
            .sorted { $0.totals.total > $1.totals.total }

        func shares(_ source: [String: (tokens: Double, usd: Double)], limit: Int) -> [RDTokenShare] {
            source.filter { $0.value.tokens > 0 }
                .sorted { $0.value.tokens > $1.value.tokens }
                .prefix(limit)
                .map { RDTokenShare(id: $0.key, label: $0.key, detail: nil, tokens: $0.value.tokens, usd: $0.value.usd) }
        }
        let top = perThread
            .compactMap { entry -> RDThreadShare? in data.threads[entry.key].map { RDThreadShare(id: entry.key, fact: $0, tokens: entry.value) } }
            .sorted { $0.tokens > $1.tokens }

        return RDTokenReport(
            totals: totals,
            previousTotal: days > 0 && previous > 0 ? previous : nil,
            days: dayPoints.sorted { $0.date < $1.date },
            accounts: accounts,
            models: shares(perModel, limit: 7),
            efforts: shares(perEffort, limit: 7),
            projects: shares(projectTokens, limit: 7),
            top: Array(top.prefix(8)),
            heat: heat,
            mainTokens: mainTokens,
            subTokens: subTokens,
            mainCount: mainCount,
            subCount: subCount,
            workSeconds: workSeconds,
            turnsCompleted: completed,
            turnsFailed: failed,
            turnsInterrupted: interrupted
        )
    }
}

private final class RDSQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 1500)
        db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    func rows(_ sql: String, bind: [Int64] = [], each: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            each(statement)
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}

private enum RDAnalyticsEngine {
    static let queue = DispatchQueue(label: "local.codex.accounts.analytics", qos: .utility)
    static let sessionGap: TimeInterval = 300
    private static let lock = NSLock()

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Accounts/Analytics", isDirectory: true)
            .appendingPathComponent("history-v1.json")
    }

    static func load() -> RDHistoryFile {
        guard let data = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(RDHistoryFile.self, from: data) else { return RDHistoryFile() }
        return file
    }

    static func save(_ file: RDHistoryFile) {
        let url = storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func dayDate(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

    private static let headerPattern = try? NSRegularExpression(
        pattern: "x-codex-(primary|secondary)-(used-percent|window-minutes|reset-at)\\\"?\\s*[:=]\\s*\\\"?([0-9.]+)"
    )

    private static func quotaHeaders(in body: String) -> [String: Double] {
        guard let regex = headerPattern else { return [:] }
        var values: [String: Double] = [:]
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        for match in regex.matches(in: body, range: range) {
            guard let slotRange = Range(match.range(at: 1), in: body),
                  let fieldRange = Range(match.range(at: 2), in: body),
                  let valueRange = Range(match.range(at: 3), in: body),
                  let value = Double(body[valueRange]) else { continue }
            let key = "\(body[slotRange]).\(body[fieldRange])"
            if values[key] == nil {
                values[key] = value
            }
        }
        return values
    }

    /// A reading whose reset time had already passed when it was taken is stale cache, not a real value.
    static func isStale(_ sample: RDQuotaSample) -> Bool {
        guard let reset = sample.r else { return false }
        return reset < sample.t - 60
    }

    /// Merges samples in time order (older log readings can arrive after newer app readings), keeps a sample
    /// only when the value moved or an hour passed, and drops stale or 35-day-old readings.
    static func merge(_ incoming: [RDQuotaSample], into file: inout RDHistoryFile) {
        guard !incoming.isEmpty else { return }
        let cutoff = Date().timeIntervalSince1970 - 35 * 86_400
        let all = (file.samples + incoming.filter { !isStale($0) && $0.u >= 0 && $0.u <= 100 })
            .filter { $0.t >= cutoff }
            .sorted { ($0.p, $0.w, $0.t) < ($1.p, $1.w, $1.t) }
        var kept: [RDQuotaSample] = []
        kept.reserveCapacity(all.count)
        for sample in all {
            if let last = kept.last, last.p == sample.p, last.w == sample.w {
                if sample.t == last.t { continue }
                if abs(sample.u - last.u) < 0.5 && sample.t - last.t < 3600 { continue }
            }
            kept.append(sample)
        }
        file.samples = kept
    }

    /// Records the app's own quota refresh for every profile.
    static func record(_ samples: [RDQuotaSample]) {
        guard !samples.isEmpty else { return }
        queue.async {
            lock.lock()
            defer { lock.unlock() }
            var file = load()
            merge(samples, into: &file)
            save(file)
        }
    }

    static func scan(profiles: [(id: String, name: String, home: String)], current: [String: (left: Int, minutes: Int, reset: Date?)]) -> RDAnalyticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var file = load()
        let now = Date()
        let activitySince = Int64(now.timeIntervalSince1970 - 14 * 86_400)
        var profilesWithLogs = 0

        for profile in profiles {
            guard let reader = RDSQLiteReader(path: (profile.home as NSString).appendingPathComponent("logs_2.sqlite")) else { continue }
            profilesWithLogs += 1

            // Quota headers logged with every API response.
            let since = file.lastLogTS[profile.id] ?? 0
            var newest = since
            var samples: [RDQuotaSample] = []
            reader.rows(
                "SELECT ts, feedback_log_body FROM logs WHERE ts > ? AND target = 'codex_http_client::client' AND feedback_log_body LIKE '%x-codex-primary-used-percent%' ORDER BY ts",
                bind: [since]
            ) { statement in
                let ts = sqlite3_column_int64(statement, 0)
                newest = max(newest, ts)
                guard let body = RDSQLiteReader.text(statement, 1) else { return }
                let headers = quotaHeaders(in: body)
                for slot in ["primary", "secondary"] {
                    guard let used = headers["\(slot).used-percent"],
                          let minutes = headers["\(slot).window-minutes"], minutes > 0 else { continue }
                    let reset = headers["\(slot).reset-at"].flatMap { $0 > 0 ? $0 : nil }
                    samples.append(RDQuotaSample(t: TimeInterval(ts), p: profile.id, w: Int(minutes), u: used, r: reset))
                }
            }
            merge(samples, into: &file)
            file.lastLogTS[profile.id] = newest

            // Activity: sessions split by 5-minute gaps, counted on the day they start; conversations per day.
            var seconds: [String: Double] = [:]
            var threads: [String: Set<String>] = [:]
            var sessionStart: TimeInterval?
            var previous: TimeInterval = 0
            reader.rows("SELECT ts, thread_id FROM logs WHERE ts > ? ORDER BY ts", bind: [activitySince]) { statement in
                let ts = TimeInterval(sqlite3_column_int64(statement, 0))
                if let thread = RDSQLiteReader.text(statement, 1), !thread.isEmpty {
                    threads[dayKey(Date(timeIntervalSince1970: ts)), default: []].insert(thread)
                }
                if let start = sessionStart, ts - previous <= sessionGap {
                    _ = start
                } else {
                    if let start = sessionStart {
                        seconds[dayKey(Date(timeIntervalSince1970: start)), default: 0] += previous - start + 60
                    }
                    sessionStart = ts
                }
                previous = ts
            }
            if let start = sessionStart {
                seconds[dayKey(Date(timeIntervalSince1970: start)), default: 0] += previous - start + 60
            }
            // Logs get pruned, so never let a day shrink once it has been counted.
            for (day, value) in seconds {
                file.usage[day, default: [:]][profile.id] = max(file.usage[day]?[profile.id] ?? 0, min(value, 86_400))
            }
            for (day, set) in threads {
                file.threads[day, default: [:]][profile.id] = max(file.threads[day]?[profile.id] ?? 0, set.count)
            }
        }

        // The app's current reading is the freshest sample of all.
        merge(current.map { id, value in
            RDQuotaSample(t: now.timeIntervalSince1970, p: id, w: value.minutes, u: Double(100 - value.left), r: value.reset?.timeIntervalSince1970)
        }, into: &file)

        let oldestDay = dayKey(now.addingTimeInterval(-60 * 86_400))
        file.usage = file.usage.filter { $0.key >= oldestDay }
        file.threads = file.threads.filter { $0.key >= oldestDay }
        save(file)

        let samplesByProfile = Dictionary(grouping: file.samples, by: { $0.p })
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        let weekAgo = dayKey(now.addingTimeInterval(-6 * 86_400))

        let insights: [RDAccountInsight] = profiles.map { profile in
            let samples = samplesByProfile[profile.id] ?? []
            let longMinutes = [10080, 43200].first { minutes in samples.contains { $0.w == minutes } }
                ?? current[profile.id]?.minutes
            let series = samples.filter { $0.w == longMinutes }.sorted { $0.t < $1.t }
            let used24h = used(series, since: now.addingTimeInterval(-86_400).timeIntervalSince1970)
            let used7d = used(series, since: now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970)
            var perDay: Double?
            if let used7d, let first = series.first(where: { $0.t >= now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 }) {
                let span = max(1, (now.timeIntervalSince1970 - first.t) / 86_400)
                perDay = used7d / span
            }
            let latest = series.last
            let left = current[profile.id]?.left ?? latest.map { Int((100 - $0.u).rounded()) }
            let resetAt = current[profile.id]?.reset ?? latest?.r.map { Date(timeIntervalSince1970: $0) }
            var emptyAt: Date?
            if let left, let perDay, perDay >= 0.5, left > 0 {
                emptyAt = now.addingTimeInterval(Double(left) / perDay * 86_400)
            }
            let active = file.usage.filter { $0.key >= weekAgo }.reduce(0.0) { $0 + ($1.value[profile.id] ?? 0) }
            let conversations = file.threads.filter { $0.key >= weekAgo }.reduce(0) { $0 + ($1.value[profile.id] ?? 0) }
            return RDAccountInsight(
                id: profile.id,
                name: profile.name,
                left: left,
                windowMinutes: longMinutes,
                used24h: used24h,
                used7d: used7d,
                perDay: perDay,
                resetAt: resetAt,
                emptyAt: emptyAt,
                activeSeconds7d: active,
                threads7d: conversations
            )
        }

        var daily: [RDDailyUsage] = []
        let fortnight = dayKey(now.addingTimeInterval(-13 * 86_400))
        for (day, perProfile) in file.usage where day >= fortnight {
            guard let date = dayDate(day) else { continue }
            for (profileID, value) in perProfile where value >= 60 {
                daily.append(RDDailyUsage(id: "\(day)|\(profileID)", day: date, name: names[profileID] ?? profileID, hours: value / 3600))
            }
        }

        return RDAnalyticsSnapshot(
            insights: insights,
            daily: daily.sorted { $0.day < $1.day },
            samplesByProfile: samplesByProfile,
            scannedAt: now,
            profilesWithLogs: profilesWithLogs
        )
    }

    /// Percent used since a time: rises are usage, a drop means a reset, after which usage starts again from zero.
    static func used(_ series: [RDQuotaSample], since: TimeInterval) -> Double? {
        let window = series.filter { $0.t >= since }
        guard !window.isEmpty else { return nil }
        var baseline = series.last(where: { $0.t < since }) ?? window[0]
        var total = 0.0
        for sample in window where sample.t > baseline.t {
            let delta = sample.u - baseline.u
            total += delta >= 0 ? delta : sample.u
            baseline = sample
        }
        return total
    }
}

extension AccountsRootView {
    // MARK: Palette

    /// Dark unless the appearance setting says light, or follows a light system.
    private var rdIsDark: Bool {
        switch rdAppearance {
        case "light": return false
        case "system": return rdSystemScheme == .dark
        default: return true
        }
    }
    private var rdTheme: RDTheme { RDTheme.theme(canonicalThemeID(appTheme)) }
    private var rdPalette: RDPalette { rdTheme.palette(dark: rdIsDark) }
    private var rdBackground: Color { rdPalette.canvas }
    private var rdSidebarFill: Color { rdPalette.sidebar }
    private var rdSurface: Color { rdPalette.surface }
    private var rdRaised: Color { rdPalette.raised }
    private var rdInspectorFill: Color { rdPalette.inspector }
    private var rdBackdropOn: Bool { rdBackdropStrength > 0.005 && rdBackdropPicture != nil }
    /// Panels let the drawing show through when it is on.
    private var rdInspectorPanel: Color { rdInspectorFill.opacity(rdLayered ? 0.55 : 1) }
    private var rdCardFill: Color { rdSurface.opacity(rdLayered ? 0.72 : 1) }
    private var rdInk: Color { rdPalette.ink }
    private var rdLine: Color { rdPalette.line }
    private var rdText: Color { rdPalette.text }
    private var rdText2: Color { rdPalette.text2 }
    private var rdText3: Color { rdPalette.text3 }
    private var rdAmber: Color { rdPalette.amber }
    private var rdOrange: Color { rdPalette.orange }
    private var rdDanger: Color { rdPalette.danger }
    private var rdTicket: Color { rdPalette.ticket }
    private var rdSuccess: Color { rdPalette.success }
    private var rdOnAccent: Color { rdPalette.onAccent }

    private func rdApplyAppearance() {
        switch rdAppearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "system": NSApp.appearance = nil
        default: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    private var rdSpring: Animation {
        rdReduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    /// Headings, names and anything read at a glance: SF Rounded, to match the numerals used everywhere.
    private func rdDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: scaled(size), weight: weight, design: .rounded)
    }

    /// The app's own language, so Chinese and Japanese text use that region's letterforms whatever the
    /// system's language order is.
    private var rdTypesettingLanguage: Locale.Language {
        switch selectedLanguage {
        case .zhHK: return Locale.Language(identifier: "zh-Hant-HK")
        case .zhHant: return Locale.Language(identifier: "zh-Hant-TW")
        case .zhCN: return Locale.Language(identifier: "zh-Hans-CN")
        case .en: return Locale.Language(identifier: "en")
        case .ja: return Locale.Language(identifier: "ja")
        }
    }

    private var rdLayered: Bool { rdBackdropOn || rdTheme.glow > 0 }

    /// Each theme's own light: its accent glows in from the top, its second colour from the far corner.
    @ViewBuilder
    private var rdAmbient: some View {
        let strength = rdTheme.glow * (rdIsDark ? 0.17 : 0.11)
        if strength > 0 {
            GeometryReader { geometry in
                let reach = max(geometry.size.width, geometry.size.height)
                ZStack {
                    RadialGradient(colors: [rdPalette.accent.opacity(strength), rdPalette.accent.opacity(0)],
                                   center: UnitPoint(x: 0.3, y: -0.08), startRadius: 0, endRadius: reach * 0.62)
                    RadialGradient(colors: [rdPalette.accent2.opacity(strength * 0.75), rdPalette.accent2.opacity(0)],
                                   center: UnitPoint(x: 1.05, y: 1.08), startRadius: 0, endRadius: reach * 0.55)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var rdVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var rdLogoImage: NSImage {
        NSImage(named: "AccountsLogo") ?? NSImage(named: "AppIcon") ?? NSImage()
    }

    private func rdNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Root

    /// A folder shown the short way, with the home folder written as "~".
    private func rdHomeRelative(_ path: String) -> String {
        // Both sides are resolved first, so a home reached through a symlink (such as /tmp) still shortens.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved == home { return "~" }
        return resolved.hasPrefix(home + "/") ? "~" + resolved.dropFirst(home.count) : (path as NSString).abbreviatingWithTildeInPath
    }

    private func rdChooseBackdrop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = tr("揀一張圖做背景", "Choose a background picture")
        guard panel.runModal() == .OK, let source = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = RDBackdropStore.importPicture(from: source)
            let picture = saved ? RDBackdropStore.load() : nil
            DispatchQueue.main.async {
                guard let picture else {
                    statusText = tr("呢張圖讀唔到，請試另一張", "That picture could not be read; try another")
                    return
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    rdBackdropPicture = picture
                    if rdBackdropStrength <= 0.005 { rdBackdropStrength = 0.2 }
                }
                statusText = tr("已設定背景圖片", "Background picture set")
            }
        }
    }

    private func rdRemoveBackdrop() {
        RDBackdropStore.remove()
        withAnimation(.easeInOut(duration: 0.35)) { rdBackdropPicture = nil }
        statusText = tr("已移除背景圖片", "Background picture removed")
    }

    private func rdCheckRequirements() {
        DispatchQueue.global(qos: .utility).async {
            let missing = RDRequirements.missing()
            DispatchQueue.main.async {
                withAnimation(rdSpring) { rdMissingTools = missing }
            }
        }
    }

    /// Shown on the Accounts page when a tool the helper needs is not on this Mac.
    private var rdRequirementsBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rdAmber)
                Text(tr("呢部 Mac 仲差少少工具", "This Mac is missing a tool or two"))
                    .font(rdDisplay(14, weight: .semibold))
                Spacer(minLength: 8)
                rdSecondaryButton(tr("再檢查", "Check Again"), icon: "arrow.clockwise") { rdCheckRequirements() }
            }
            if rdMissingTools.contains("python3") {
                HStack(alignment: .center, spacing: 12) {
                    Text(tr("Python 3：同步對話同匯出對話包要用。裝 Apple 嘅 Command Line Tools 就有（免費，幾分鐘）。", "Python 3: needed to sync conversations and export them. It comes with Apple's Command Line Tools (free, a few minutes)."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText2)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    rdPrimaryButton(tr("安裝…", "Install…")) {
                        let install = Process()
                        install.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                        install.arguments = ["--install"]
                        try? install.run()
                    }
                }
            }
            if rdMissingTools.contains("jq") {
                HStack(alignment: .center, spacing: 12) {
                    Text(tr("jq：顯示額度要用。macOS 15 或以上已經內置；macOS 14 可以用 Homebrew 裝：brew install jq", "jq: needed to show quota. macOS 15 and later include it; on macOS 14 install it with Homebrew: brew install jq"))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText2)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    rdSecondaryButton(tr("複製指令", "Copy Command"), icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install jq", forType: .string)
                        statusText = tr("已複製：brew install jq", "Copied: brew install jq")
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(rdAmber.opacity(rdIsDark ? 0.10 : 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rdAmber.opacity(0.35), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The drawing sits at the right, as it was composed, leaving the blank side under the sidebar and names.
    @ViewBuilder
    private var rdBackdrop: some View {
        if rdBackdropOn, let image = rdBackdropPicture {
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
                    .clipped()
            }
            .opacity(rdBackdropStrength * (rdIsDark ? 1 : 0.62))   // Orange on white reads stronger than on black.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    var redesignedWorkspace: some View {
        GeometryReader { geometry in
            let sidebarWidth = rdClampedSidebar(rdSidebarLive ?? rdSidebarWidth, window: geometry.size.width)
            HStack(spacing: 0) {
                rdSidebar(width: sidebarWidth)
                rdSidebarHandle(width: sidebarWidth, window: geometry.size.width)
                ZStack {
                    rdContent(width: max(geometry.size.width - sidebarWidth - 1, 0))
                        .id(rdSection)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 12)),
                            removal: .opacity
                        ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .background {
            ZStack {
                rdBackground
                rdAmbient
                rdBackdrop
            }
        }
        .foregroundStyle(rdText)
        .typesettingLanguage(rdTypesettingLanguage)
        .focusEffectDisabled()
        .overlay(alignment: .bottom) { rdToastView }
        .background(rdShortcutButtons)
        .onChange(of: isRefreshing) { _, refreshing in
            if !refreshing {
                rdLastRefreshAt = Date()
            }
        }
        .onChange(of: rdProfilesSignature) { _, _ in
            rdProfilesChanged()
        }
        .onChange(of: statusText) { _, text in
            rdShowToast(text)
        }
        .onAppear {
            rdMeta = RDMetaStore.load()
            rdApiPlans = RDPlanDetector.load(profiles.map(\.id))
            rdApplyAppearance()
            rdCheckRequirements()
        }
        .onChange(of: rdAppearance) { _, _ in
            rdApplyAppearance()
        }
        .onChange(of: keepAwake.mode) { _, mode in
            if mode != .off { rdKeepAwakeLastMode = mode.rawValue }
        }
        .animation(.easeInOut(duration: 0.35), value: appTheme)
        .animation(.easeInOut(duration: 0.35), value: rdAppearance)
    }

    @ViewBuilder
    private func rdContent(width: CGFloat) -> some View {
        switch rdSection {
        case "insights": rdInsightsPage
        case "conversations": rdConversationsPage
        case "tools": rdToolsPage
        case "models": rdModelsPage
        case "settings": rdSettingsPage
        default: rdAccountsPage(width: width)
        }
    }

    private func rdGo(_ section: String) {
        guard rdSection != section else { return }
        withAnimation(rdSpring) {
            rdSection = section
        }
    }

    private var rdSections: [(id: String, icon: String, title: String)] {
        [
            ("accounts", "person.2", tr("帳戶", "Accounts")),
            ("insights", "chart.xyaxis.line", tr("分析", "Insights")),
            ("conversations", "bubble.left.and.bubble.right", tr("對話與項目", "Chats & Projects")),
            ("tools", "wrench.and.screwdriver", tr("工作工具", "Tools")),
            ("models", "cpu", tr("模型與代理", "Models & Proxy")),
            ("settings", "gearshape", tr("設定", "Settings"))
        ]
    }

    /// ⌘1–⌘6 switch sections, ⌘F focuses search.
    private var rdShortcutButtons: some View {
        ZStack {
            ForEach(Array(rdSections.enumerated()), id: \.offset) { index, section in
                Button("") { rdGo(section.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
            }
            Button("") {
                rdGo("accounts")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { rdSearchFocused = true }
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Toast

    private func rdShowToast(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "就緒",
              !trimmed.contains("個 profile 就緒"), !trimmed.contains("profiles ready") else { return }
        withAnimation(rdSpring) {
            rdToast = trimmed
        }
        let shown = trimmed
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            guard rdToast == shown else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                rdToast = nil
            }
        }
    }

    @ViewBuilder
    private var rdToastView: some View {
        if let toast = rdToast {
            Text(toast)
                .font(appFont(size: 13, weight: .medium))
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(rdRaised))
                .overlay(Capsule().stroke(rdInk.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                .padding(.bottom, 18)
                .padding(.leading, CGFloat(rdSidebarLive ?? rdSidebarWidth) + 1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: Profile change tracking (history samples + reminders)

    private var rdProfilesSignature: String {
        profiles.map { "\($0.id)|\($0.quota)|\($0.reset)|\($0.resetCredits)|\($0.authStatus)" }.joined(separator: ";")
    }

    private func rdCurrentQuota(_ profile: CodexProfile, exact: [String: TimeInterval]? = nil) -> [RDQuotaSample] {
        let now = Date().timeIntervalSince1970
        return quotaWindows(for: profile).compactMap { window in
            guard let percent = window.percent else { return nil }
            let minutes: Int
            switch window.id {
            case "5h": minutes = 300
            case "7d": minutes = 10080
            case "30d": minutes = 43200
            default: return nil
            }
            let reset = window.reset.flatMap { resetDate(from: $0) }
            if let reset, reset.timeIntervalSince1970 < now - 60 { return nil }
            return RDQuotaSample(t: now, p: profile.id, w: minutes, u: Double(100 - percent), r: exact?[window.id] ?? reset?.timeIntervalSince1970)
        }
    }

    /// Called on every refresh, so accounts nobody is using still leave a record. Unchanged values are thinned out
    /// when they are merged, so this stays small.
    private func rdRecordQuota() {
        let tracked = profiles.filter { !isExternalProvider($0) }
        guard !tracked.isEmpty else { return }
        let exact = RDPlanDetector.exactResets(tracked.map(\.id))
        RDAnalyticsEngine.record(tracked.flatMap { rdCurrentQuota($0, exact: exact[$0.id]) })
    }

    private func rdProfilesChanged() {
        let previous = rdPreviousProfiles
        rdPreviousProfiles = profiles
        guard !profiles.isEmpty else { return }
        let plans = RDPlanDetector.load(profiles.map(\.id))
        if plans != rdApiPlans { withAnimation(rdSpring) { rdApiPlans = plans } }
        rdRecordQuota()
        if rdSection == "insights", rdAnalytics?.insights.isEmpty ?? true {
            rdRefreshAnalytics()
        }
        guard rdNotifyEnabled, !previous.isEmpty else { return }
        rdNotifyChanges(previous: previous)
    }

    private func rdNotifyChanges(previous: [CodexProfile]) {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for profile in profiles {
            if let old = before[profile.id], isWaitingForRecovery(old), !isWaitingForRecovery(profile), !isLoginNeeded(profile), profile.quota != "unknown" {
                rdPostNotification(
                    id: "reset-\(profile.id)-\(Int(Date().timeIntervalSince1970 / 3600))",
                    title: tr("\(profile.displayName) 嘅額度已經重設", "\(profile.displayName) has quota again"),
                    body: tr("可以用返。", "Ready to use.")
                )
            }
        }
        var notified = Set(UserDefaults.standard.stringArray(forKey: "rdNotifiedTicketKeys") ?? [])
        for profile in profiles {
            guard let summary = resetCreditSummary(for: profile) else { continue }
            for expiry in summary.expiries {
                guard let date = resetCreditExpiryDate(from: expiry) else { continue }
                let hours = date.timeIntervalSinceNow / 3600
                guard hours > 0, hours <= 48 else { continue }
                let key = "\(profile.id)|\(expiry)"
                guard !notified.contains(key) else { continue }
                notified.insert(key)
                rdPostNotification(
                    id: "ticket-\(key)",
                    title: tr("\(profile.displayName) 有重設券快到期", "A reset ticket for \(profile.displayName) expires soon"),
                    body: tr("\(fullResetCreditExpiryText(expiry))，記得喺之前用。", "\(fullResetCreditExpiryText(expiry)). Use it before then.")
                )
            }
        }
        UserDefaults.standard.set(Array(notified.suffix(200)), forKey: "rdNotifiedTicketKeys")
    }

    private func rdPostNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func rdSetNotifications(_ enabled: Bool) {
        guard enabled else {
            rdNotifyEnabled = false
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                rdNotifyEnabled = granted
                if !granted {
                    statusText = tr("macOS 未允許通知；可以喺系統設定 > 通知打開。", "Notifications are off for this app in System Settings > Notifications.")
                }
            }
        }
    }

    // MARK: Sidebar

    private static let rdSidebarDefault = 220.0

    /// 200 still fits the logo and name; the page beside it always keeps 720.
    private func rdClampedSidebar(_ width: Double, window: CGFloat) -> CGFloat {
        CGFloat(max(200, min(width, 340, Double(window) - 721)))
    }

    /// The small grip sitting on the sidebar's edge. It stays visible so the edge can be found; hovering only
    /// brightens its dots, and the line itself never changes.
    private func rdSidebarGrip(hot: Bool, dragging: Bool) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(dragging ? themePrimary : (hot ? rdText : rdText3))
                    .frame(width: 2.5, height: 2.5)
            }
        }
        .frame(width: 11, height: 36)
        .background(Capsule().fill(rdRaised))
        .overlay(Capsule().stroke(hot ? rdInk.opacity(0.22) : rdLine, lineWidth: 1))
        .shadow(color: .black.opacity(rdIsDark ? 0.35 : 0.12), radius: 3, y: 1)
        .scaleEffect(hot ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: hot)
        .animation(.easeOut(duration: 0.15), value: dragging)
        .allowsHitTesting(false)
    }

    /// The line between the sidebar and the page: drag to resize, double-click for the default width.
    private func rdSidebarHandle(width: CGFloat, window: CGFloat) -> some View {
        let dragging = rdSidebarLive != nil
        return Rectangle()
            .fill(rdLine)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay { rdSidebarGrip(hot: rdSidebarHandleHot || dragging, dragging: dragging) }
            .overlay {
                RDResizeHandle(
                    tooltip: tr("拖動調整闊度，撳兩下還原", "Drag to resize; double-click to reset"),
                    onHover: { rdSidebarHandleHot = $0 },
                    onChanged: { translation in
                        let base = rdSidebarDragBase ?? Double(width)
                        rdSidebarDragBase = base
                        rdSidebarLive = base + Double(translation)
                    },
                    onEnded: { translation in
                        let base = rdSidebarDragBase ?? Double(width)
                        rdSidebarWidth = Double(rdClampedSidebar(base + Double(translation), window: window))
                        rdSidebarLive = nil
                        rdSidebarDragBase = nil
                    },
                    onReset: {
                        withAnimation(rdSpring) { rdSidebarWidth = Self.rdSidebarDefault }
                    }
                )
                .frame(width: 11)
            }
            .zIndex(1)
    }

    private func rdSidebar(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 34)

            HStack(spacing: 10) {
                Image(nsImage: rdLogoImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                Text("Codex Accounts")
                    .font(rdDisplay(15, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(rdSections.filter { $0.id != "settings" }, id: \.id) { section in
                    rdNavItem(section.id, icon: section.icon, title: section.title, badge: section.id == "accounts" && !profiles.isEmpty ? "\(profiles.count)" : nil)
                }
            }

            Text(tr("這部 Mac", "This Mac"))
                .font(appFont(size: 11, weight: .semibold))
                .foregroundStyle(rdText3)
                .padding(.horizontal, 10)
                .padding(.top, 22)
                .padding(.bottom, 6)

            rdQuickRow(
                icon: "cup.and.saucer", title: tr("防睡眠", "Keep Awake"),
                detail: keepAwake.mode == .off ? nil : keepAwakeModeTitle,
                active: keepAwake.mode != .off, busy: keepAwake.isSwitching
            ) {
                // Turning it on returns to the mode used last (screen on, or lid closed).
                keepAwake.setMode(keepAwake.mode == .off ? (KeepAwakeMode(rawValue: rdKeepAwakeLastMode) ?? .display) : .off)
            }
            rdQuickRow(
                icon: "keyboard", title: tr("鍵盤清潔", "Keyboard"),
                detail: keyboardClean.isLocked ? tr("鍵盤已鎖定", "Keyboard locked") : nil,
                active: keyboardClean.isLocked, busy: keyboardClean.isSwitching
            ) {
                keyboardClean.toggle()
            }

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("今日使用", "Today"))
                    .font(appFont(size: 11))
                    .foregroundStyle(rdText3)
                Text(usageDurationText(currentUsageSeconds()))
                    .font(rdNumber(17))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            rdNavItem("settings", icon: "gearshape", title: tr("設定", "Settings"), trailing: rdVersion)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(rdSidebarFill)
    }

    private func rdNavItem(_ id: String, icon: String, title: String, badge: String? = nil, trailing: String? = nil) -> some View {
        let selected = rdSection == id
        return Button {
            rdGo(id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? themePrimary : rdText2)
                    .scaleEffect(selected && !rdReduceMotion ? 1.1 : 1)
                    .animation(.spring(response: 0.34, dampingFraction: 0.55), value: selected)
                Text(title)
                    .font(appFont(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? rdText : rdText2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(appFont(size: 11, weight: .medium))
                        .foregroundStyle(rdText3)
                        .monospacedDigit()
                }
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(appFont(size: 11))
                        .foregroundStyle(rdText3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(rdPalette.selection)
                        .matchedGeometryEffect(id: "rdNavSelection", in: rdNamespace)
                }
            }
            .modifier(RDHoverFill(cornerRadius: 8, base: .clear, hover: selected ? .clear : rdInk.opacity(0.04)))
        }
        .buttonStyle(RDPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A small switch whose position and colour are the state; no "on" or "off" wording.
    private func rdMiniSwitch(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? themePrimary : rdInk.opacity(0.16))
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? rdOnAccent : rdText2)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .shadow(color: themePrimary.opacity(isOn ? 0.45 : 0), radius: 5)
            .animation(rdSpring, value: isOn)
    }

    /// A sidebar shortcut: the name opens the Tools page, the switch turns the feature on or off in place.
    private func rdQuickRow(icon: String, title: String, detail: String?, active: Bool, busy: Bool, toggle: @escaping () -> Void) -> some View {
        #if UI_PREVIEW
        let active = active || ProcessInfo.processInfo.environment["PREVIEW_SWITCH_ON"] == title
        #endif
        return HStack(spacing: 6) {
            Button {
                rdGo("tools")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20)
                        .foregroundStyle(active ? themePrimary : rdText3)
                    Text(title)
                        .font(appFont(size: 13, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? rdText : rdText2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(RDPressStyle())
            Button(action: toggle) {
                rdMiniSwitch(isOn: active)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RDPressStyle())
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .help(detail ?? (active ? tr("撳一下關閉", "Click to turn off") : tr("撳一下開啟", "Click to turn on")))
            .accessibilityLabel(title)
            .accessibilityValue(active ? tr("開", "On") : tr("關", "Off"))
            .accessibilityAddTraits(.isToggle)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .modifier(RDHoverFill(cornerRadius: 8, base: .clear, hover: rdInk.opacity(0.04)))
    }

    // MARK: Building blocks

    private func rdPageHeader<Trailing: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(rdDisplay(24, weight: .bold))
                    .tracking(-0.2)
                if let subtitle {
                    Text(subtitle)
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 14)
    }

    private func rdPrimaryButton(_ title: String, icon: String? = nil, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .bold))
                }
                Text(title).font(appFont(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(rdOnAccent)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(themePrimary))
            .contentShape(Rectangle())
            .modifier(RDHoverLift(tint: themePrimary))
        }
        .buttonStyle(RDPressStyle())
        .disabled(busy)
    }

    private func rdSecondaryButton(_ title: String, icon: String? = nil, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(appFont(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(rdText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(rdInk.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
            .modifier(RDHoverFill(cornerRadius: 8, base: .clear, hover: rdInk.opacity(0.06)))
        }
        .buttonStyle(RDPressStyle())
        .disabled(busy)
    }

    private func rdIconButton(_ icon: String, help: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(rdText2)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .modifier(RDHoverFill(cornerRadius: 8, base: rdInk.opacity(0.05), hover: rdInk.opacity(0.10)))
        }
        .buttonStyle(RDPressStyle())
        .disabled(busy)
        .help(help)
        .accessibilityLabel(help)
    }

    private func rdCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(rdCardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rdLine, lineWidth: 1))
    }

    private func rdCardTitle(_ title: String, subtitle: String? = nil, icon: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(themePrimary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(themePrimary.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(rdDisplay(15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func rdSegmented<Value: Equatable>(_ options: [(Value, String)], selection: Value, key: String, disabled: Bool = false, onSelect: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.0 == selection
                Button {
                    withAnimation(rdSpring) { onSelect(option.0) }
                } label: {
                    Text(option.1)
                        .font(appFont(size: 12, weight: .semibold))
                        .hidden()       // Reserves the bold width, so choosing a segment never shifts the others.
                        .overlay {
                            Text(option.1)
                                .font(appFont(size: 12, weight: isOn ? .semibold : .regular))
                                .foregroundStyle(isOn ? rdOnAccent : rdText2)
                                .fixedSize()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(themePrimary)
                                    .matchedGeometryEffect(id: "rdSeg-\(key)", in: rdNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                        .modifier(RDHoverFill(cornerRadius: 6, base: .clear, hover: isOn ? .clear : rdInk.opacity(0.07)))
                }
                .buttonStyle(RDPressStyle())
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.06)))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func rdIconSegmented<Value: Equatable>(_ options: [(Value, String, String)], selection: Value, key: String, disabled: Bool = false, onSelect: @escaping (Value) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.0 == selection
                Button {
                    withAnimation(rdSpring) { onSelect(option.0) }
                } label: {
                    Image(systemName: option.2)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isOn ? rdOnAccent : rdText3)
                        .frame(width: 32, height: 24)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(themePrimary)
                                    .matchedGeometryEffect(id: "rdISeg-\(key)", in: rdNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(RDPressStyle())
                .help(option.1)
                .accessibilityLabel(option.1)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.06)))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var rdHistoryOptions: [(Bool, String, String)] {
        [(true, tr("共享本機對話", "Shared local chats"), "person.2.fill"), (false, tr("私人本機對話", "Private local chats"), "lock.fill")]
    }

    private func rdToggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(appFont(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(themePrimary)
        }
    }

    /// What is left, as a colour: green when there is plenty, through lime, amber and orange, to red near zero.
    private func rdLevelColor(_ percent: Int) -> Color {
        rdPalette.level(percent)
    }

    /// A level bar without a label (charts, secondary windows).
    private func rdBar(_ percent: Int, height: CGFloat = 8) -> some View {
        rdQuotaBar(percent, height: height, label: false)
    }

    /// The quota bar: thick, filled in the level colour, with the number printed inside. The number is drawn
    /// twice, once over the track and once clipped to the fill, so it stays readable where the fill ends.
    /// An empty bar's track turns faintly red so a used-up account reads at a glance.
    private func rdQuotaBar(_ percent: Int, height: CGFloat, label: Bool = true) -> some View {
        let clamped = min(max(percent, 0), 100)
        let palette = rdPalette
        let color = palette.level(clamped)
        let revealed = rdRevealed
        return GeometryReader { geometry in
            let full = geometry.size.width * CGFloat(clamped) / 100
            let fill = (clamped > 0 ? max(height, full) : 0) * (revealed ? 1 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(palette.canvas)   // Keeps the background drawing out of the bar.
                Capsule()
                    .fill(clamped == 0 ? palette.level(0).opacity(palette.isDark ? 0.20 : 0.14) : palette.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(palette.isDark ? 0.78 : 0.86), color], startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        Capsule().fill(LinearGradient(colors: [Color.white.opacity(palette.isDark ? 0.28 : 0.22), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
                    )
                    .frame(width: fill)
                    .shadow(color: color.opacity(palette.isDark ? 0.38 : 0.18), radius: palette.isDark ? 6 : 3)
                if label {
                    let text = Text("\(clamped)%")
                        .font(.system(size: max(9, height * 0.58), weight: .bold, design: .rounded))
                        .monospacedDigit()
                    text
                        .foregroundStyle(clamped == 0 ? palette.level(0) : palette.text)
                        .padding(.leading, height * 0.42)
                    text
                        .foregroundStyle(palette.onLevel(clamped))
                        .padding(.leading, height * 0.42)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .mask(alignment: .leading) { Rectangle().frame(width: fill) }
                }
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.7, dampingFraction: 0.85), value: clamped)
        .animation(.spring(response: 0.8, dampingFraction: 0.86), value: rdRevealed)
        .accessibilityElement()
        .accessibilityLabel(label ? tr("剩餘 \(clamped)%", "\(clamped)% left") : "")
        .accessibilityHidden(!label)
    }

    // MARK: Plans and pins

    /// A manual tag wins; otherwise the plan comes from the usage API, and an account whose only quota is a
    /// 30-day window is a free account.
    private func rdTier(_ profile: CodexProfile) -> RDTier? { rdMeta[profile.id]?.tier ?? rdDetectedTier(profile) }
    private func rdTierIsManual(_ profile: CodexProfile) -> Bool { rdMeta[profile.id]?.tier != nil }

    private func rdDetectedTier(_ profile: CodexProfile) -> RDTier? {
        guard !isExternalProvider(profile) else { return nil }
        if let plan = rdApiPlans[profile.id], let tier = RDPlanDetector.tier(forPlan: plan) { return tier }
        let windows = Set(quotaWindows(for: profile).filter { $0.percent != nil }.map(\.id))
        return windows == ["30d"] ? .free : nil
    }
    private func rdIsPinned(_ profile: CodexProfile) -> Bool { rdMeta[profile.id]?.pinnedAt != nil }
    private func rdTierColor(_ tier: RDTier) -> Color { tier.color(dark: rdIsDark) }

    private func rdUpdateMeta(_ id: String, _ change: (inout RDAccountMeta) -> Void) {
        var entry = rdMeta[id] ?? RDAccountMeta()
        change(&entry)
        withAnimation(rdSpring) {
            if entry.isEmpty { rdMeta.removeValue(forKey: id) } else { rdMeta[id] = entry }
        }
        RDMetaStore.save(rdMeta)
    }

    /// New pins go to the bottom of the pinned block; unpinning returns the account to its plan group.
    private func rdTogglePin(_ profile: CodexProfile) {
        let pinned = rdIsPinned(profile)
        let next = (rdMeta.values.compactMap(\.pinnedAt).max() ?? 0) + 1
        rdUpdateMeta(profile.id) { $0.pinnedAt = pinned ? nil : next }
        statusText = pinned ? tr("已取消置頂 \(profile.displayName)", "Unpinned \(profile.displayName)")
                            : tr("已置頂 \(profile.displayName)", "Pinned \(profile.displayName)")
    }

    private var rdPinnedOrder: [CodexProfile] {
        profiles.filter(rdIsPinned).sorted { (rdMeta[$0.id]?.pinnedAt ?? 0) < (rdMeta[$1.id]?.pinnedAt ?? 0) }
    }

    private func rdMovePin(_ profile: CodexProfile, by offset: Int) {
        let order = rdPinnedOrder
        guard let index = order.firstIndex(where: { $0.id == profile.id }) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        let mine = rdMeta[order[index].id]?.pinnedAt
        let theirs = rdMeta[order[target].id]?.pinnedAt
        rdUpdateMeta(order[index].id) { $0.pinnedAt = theirs }
        rdUpdateMeta(order[target].id) { $0.pinnedAt = mine }
    }

    /// nil, or the plan that was detected anyway, means "follow detection": nothing manual is stored.
    private func rdSetTier(_ profile: CodexProfile, _ tier: RDTier?) {
        let detected = rdDetectedTier(profile)
        let manual = tier == detected ? nil : tier
        rdUpdateMeta(profile.id) { $0.tier = manual }
        if let manual {
            statusText = tr("\(profile.displayName) 手動設為 \(manual.title)", "\(profile.displayName) set to \(manual.title)")
        } else {
            statusText = detected.map { tr("\(profile.displayName) 跟返自動偵測：\($0.title)", "\(profile.displayName) follows detection: \($0.title)") }
                ?? tr("\(profile.displayName) 冇方案", "\(profile.displayName) has no plan")
        }
    }

    /// Where the plan shown for this account came from, for the inspector.
    private func rdPlanSource(_ profile: CodexProfile) -> (icon: String, text: String) {
        let detected = rdDetectedTier(profile)
        if rdTierIsManual(profile) {
            return ("hand.point.up.left.fill", detected.map { tr("手動設定（偵測到 \($0.title)）", "Set by hand (detected \($0.title))") }
                ?? tr("手動設定", "Set by hand"))
        }
        if let plan = rdApiPlans[profile.id] {
            if let detected { return ("wand.and.stars", tr("自動偵測：帳戶方案 \(plan) → \(detected.title)", "Detected: account plan \(plan) → \(detected.title)")) }
            return ("questionmark.circle", tr("帳戶方案 \(plan)，未有對應分類", "Account plan \(plan) has no matching group"))
        }
        if detected == .free {
            return ("wand.and.stars", tr("自動偵測：只有 30 日額度，即免費帳戶", "Detected: only a 30-day quota, so a free account"))
        }
        return ("questionmark.circle", tr("未偵測到方案，下次成功刷新後會自動分類", "No plan detected yet; it is filled in after the next successful refresh"))
    }

    private func rdTierChip(_ tier: RDTier, compact: Bool = true) -> some View {
        let color = rdTierColor(tier)
        return HStack(spacing: 3) {
            Image(systemName: tier.symbol)
                .font(.system(size: compact ? 8.5 : 10, weight: .bold))
            Text(tier.title)
                .font(.system(size: compact ? 10.5 : 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3.5)
        .background(Capsule().fill(color.opacity(rdIsDark ? 0.15 : 0.11)))
        .overlay(Capsule().stroke(color.opacity(rdIsDark ? 0.32 : 0.28), lineWidth: 1))
        .fixedSize()
        .accessibilityLabel(tr("方案 \(tier.title)", "Plan \(tier.title)"))
    }

    @ViewBuilder
    private func rdPlanMenu(_ profile: CodexProfile) -> some View {
        let current = rdTier(profile)
        let manual = rdTierIsManual(profile)
        let detected = rdDetectedTier(profile)
        Menu(tr("方案", "Plan")) {
            Button {
                rdSetTier(profile, nil)
            } label: {
                let title = tr("自動偵測", "Detect Automatically") + (detected.map { "（\($0.title)）" } ?? "")
                if !manual { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            Divider()
            ForEach(RDTier.allCases) { tier in
                Button {
                    rdSetTier(profile, tier)
                } label: {
                    if manual && current == tier { Label(tier.title, systemImage: "checkmark") } else { Text(tier.title) }
                }
            }
        }
    }

    /// Plan chips in the inspector. The current plan is filled, whether detected or set by hand; clicking a
    /// hand-set plan again goes back to detection. A line underneath says where the plan came from.
    private func rdPlanPicker(_ profile: CodexProfile) -> some View {
        let current = rdTier(profile)
        let manual = rdTierIsManual(profile)
        let source = rdPlanSource(profile)
        return VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 3) {
            ForEach(RDTier.allCases) { tier in
                let isOn = current == tier
                let color = rdTierColor(tier)
                Button {
                    rdSetTier(profile, isOn && manual ? nil : tier)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: tier.symbol)
                            .font(.system(size: 8, weight: .bold))
                        Text(tier.shortTitle)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(.horizontal, 4)
                    .foregroundStyle(isOn ? (rdIsDark ? Color.black.opacity(0.82) : Color.white) : color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 25)
                    .background(Capsule().fill(isOn ? color : color.opacity(rdIsDark ? 0.10 : 0.08)))
                    .overlay(Capsule().stroke(color.opacity(isOn ? 0 : 0.30), lineWidth: 1))
                    .shadow(color: isOn ? color.opacity(rdIsDark ? 0.40 : 0.25) : .clear, radius: 6)
                    .contentShape(Capsule())
                }
                .buttonStyle(RDPressStyle())
                .help(isOn ? (manual ? tr("再撳一下改返自動偵測", "Click again to go back to detection") : tr("自動偵測到嘅方案", "Detected plan"))
                           : tr("手動設為 \(tier.title)", "Set to \(tier.title)"))
                .accessibilityLabel(tier.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
            HStack(spacing: 5) {
                Image(systemName: source.icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(manual ? themeWarm : themePrimary)
                Text(source.text)
                    .font(appFont(size: 11, weight: .medium))
                    .foregroundStyle(rdText2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if manual {
                    Button(tr("改返自動", "Use Detected")) { rdSetTier(profile, nil) }
                        .buttonStyle(.plain)
                        .font(appFont(size: 11, weight: .semibold))
                        .foregroundStyle(themePrimary)
                }
            }
            .padding(.horizontal, 2)
        }
        .animation(rdSpring, value: current)
        .animation(rdSpring, value: manual)
    }

    // MARK: Groups

    private func rdIsCollapsed(_ id: String) -> Bool {
        rdCollapsedGroups.split(separator: ",").contains(Substring(id))
    }

    private func rdToggleCollapsed(_ id: String) {
        var set = Set(rdCollapsedGroups.split(separator: ",").map(String.init))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(rdSpring) { rdCollapsedGroups = set.sorted().joined(separator: ",") }
    }

    /// Pinned accounts first, in their own order; then one block per plan (highest first), untagged accounts,
    /// and external APIs. Inside a block the usual order applies: usable first, most quota left first.
    private var rdGroups: [RDGroup] {
        let visible = rdVisibleProfiles
        let pinned = visible.filter(rdIsPinned).sorted { (rdMeta[$0.id]?.pinnedAt ?? 0) < (rdMeta[$1.id]?.pinnedAt ?? 0) }
        let rest = visible.filter { !rdIsPinned($0) }
        var groups: [RDGroup] = []
        if !pinned.isEmpty {
            groups.append(RDGroup(id: "pinned", title: tr("置頂", "Pinned"), icon: "pin.fill", tint: themePrimary, profiles: pinned))
        }
        guard rdGroupByTier else {
            if !rest.isEmpty {
                groups.append(RDGroup(id: "rest", title: pinned.isEmpty ? "" : tr("其他帳戶", "Other accounts"), icon: "person.2", tint: nil, profiles: rest))
            }
            return groups
        }
        for tier in RDTier.allCases {
            let items = rest.filter { rdTier($0) == tier && !isExternalProvider($0) }
            if !items.isEmpty {
                groups.append(RDGroup(id: tier.rawValue, title: tier.title, icon: tier.symbol, tint: rdTierColor(tier), profiles: items))
            }
        }
        let untagged = rest.filter { rdTier($0) == nil && !isExternalProvider($0) }
        if !untagged.isEmpty {
            groups.append(RDGroup(id: "untagged", title: tr("未分類", "No plan"), icon: "tag", tint: nil, profiles: untagged))
        }
        let api = rest.filter { isExternalProvider($0) }
        if !api.isEmpty {
            groups.append(RDGroup(id: "api", title: tr("外部 API", "External API"), icon: "network", tint: themeSecondary, profiles: api))
        }
        return groups
    }

    private func rdGroupHeader(_ group: RDGroup) -> some View {
        let collapsed = rdIsCollapsed(group.id)
        let lefts = group.profiles.compactMap { rdLongWindow($0)?.percent }
        let average = lefts.isEmpty ? nil : lefts.reduce(0, +) / lefts.count
        let tint = group.tint ?? rdText2
        return Button {
            rdToggleCollapsed(group.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(rdText3)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: group.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(group.id == "pinned" ? 45 : 0))
                Text(group.title)
                    .font(appFont(size: 13, weight: .bold))
                    .foregroundStyle(group.tint ?? rdText)
                Text("\(group.profiles.count)")
                    .font(rdNumber(11, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.14)))
                Rectangle()
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.leading, 4)
                if let average {
                    HStack(spacing: 6) {
                        Text(tr("平均", "avg"))
                            .font(appFont(size: 11))
                            .foregroundStyle(rdText3)
                        Text("\(average)%")
                            .font(rdNumber(12, weight: .bold))
                            .foregroundStyle(rdLevelColor(average))
                            .monospacedDigit()
                        rdBar(average, height: 6)
                            .frame(width: 54)
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? tr("展開", "Expand") : tr("收起", "Collapse"))
        .accessibilityLabel("\(group.title) \(group.profiles.count)")
    }

    private func rdBadge(_ profile: CodexProfile, size: CGFloat) -> some View {
        Image(nsImage: profileBadgeImage(for: profile))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).stroke(rdInk.opacity(0.10), lineWidth: 1))
            .accessibilityHidden(true)
    }

    // MARK: Account status and quota helpers

    private func rdStatus(_ profile: CodexProfile) -> RDStatus {
        if isExternalProvider(profile) { return .api }
        if isLoginNeeded(profile) { return .login }
        if rdFailedRefreshIDs.contains(profile.id) { return .failed }
        if isWaitingForRecovery(profile) { return .waiting }
        if profile.quota == "unknown" {
            return (profile.authStatus == "checking" || profile.authMode == "checking") ? .checking : .noData
        }
        return .ready
    }

    /// Only statuses that need attention get a line of text; a healthy account shows just its numbers.
    private func rdStatusNote(_ status: RDStatus, profile: CodexProfile) -> String? {
        switch status {
        case .ready: return nil
        case .api: return tr("外部 API", "External API")
        case .checking: return tr("讀取緊…", "Loading…")
        case .noData: return tr("未取得額度", "No quota data")
        case .waiting:
            if let window = quotaWindows(for: profile).first(where: { $0.percent == 0 }), let text = rdResetRelative(window.reset) {
                return tr("已用完 · \(text)", "Used up · \(text)")
            }
            return tr("已用完，等待重設", "Used up, waiting for reset")
        case .login: return tr("需要登入", "Login needed")
        case .failed: return tr("更新失敗，顯示上次資料", "Update failed · last data")
        }
    }

    private func rdStatusColor(_ status: RDStatus) -> Color {
        switch status {
        case .ready: return themePrimary
        case .api: return themeSecondary
        case .checking, .login, .noData: return rdText3
        case .waiting: return rdAmber
        case .failed: return rdOrange
        }
    }

    private func rdWindow(_ profile: CodexProfile, id: String) -> QuotaWindow? {
        quotaWindows(for: profile).first { $0.id == id && $0.percent != nil }
    }

    /// The long-period limit: 1 week for most plans, 1 month for accounts that only have a monthly limit.
    private func rdLongWindow(_ profile: CodexProfile) -> QuotaWindow? {
        rdWindow(profile, id: "7d") ?? rdWindow(profile, id: "30d")
    }

    private func rdWeekly(_ profile: CodexProfile) -> QuotaWindow? {
        rdLongWindow(profile) ?? rdWindow(profile, id: "5h")
    }

    private func rdRelative(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 60 { return tr("即將", "soon") }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return tr("\(minutes) 分鐘後", "in \(minutes) min")
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return tr("\(hours) 小時後", "in \(hours) h")
        }
        let days = Int(seconds / 86_400)
        return tr("\(days) 日後", "in \(days) d")
    }

    private func rdResetRelative(_ reset: String?) -> String? {
        guard let reset, reset != "unknown", reset != "none", !reset.isEmpty, let date = resetDate(from: reset) else { return nil }
        return tr("\(rdRelative(date))重設", "resets \(rdRelative(date))")
    }

    private func rdResetShort(_ reset: String?) -> String {
        guard let reset, reset != "unknown", reset != "none", !reset.isEmpty, let date = resetDate(from: reset) else { return "" }
        return rdRelative(date)
    }

    private func rdResetFull(_ reset: String?) -> String? {
        guard let reset, reset != "unknown", reset != "none", !reset.isEmpty, let date = resetDate(from: reset) else { return nil }
        return tr("\(fullResetDateText(from: reset)) 重設 · \(rdRelative(date))", "Resets \(fullResetDateText(from: reset)) · \(rdRelative(date))")
    }

    private func rdTicketDate(_ raw: String) -> String {
        guard let date = resetCreditExpiryDate(from: raw) else { return shortResetCreditExpiryText(raw) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = selectedLanguage == .en ? "MMM d HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func rdTicketExpiringSoon(_ profile: CodexProfile) -> Bool {
        guard let first = resetCreditSummary(for: profile)?.expiries.first, let date = resetCreditExpiryDate(from: first) else { return false }
        return date.timeIntervalSinceNow < 3 * 86_400
    }

    private func rdWindowName(_ id: String) -> String {
        switch id {
        case "5h": return tr("5 小時", "5 hours")
        case "7d": return tr("1 星期", "1 week")
        case "30d": return tr("1 個月", "1 month")
        default:
            let labels = quotaWindowLabels(for: id)
            return tr(labels.zh, labels.en)
        }
    }

    private func rdResetSoonness(_ profile: CodexProfile) -> TimeInterval {
        guard let reset = rdWeekly(profile)?.reset, let date = resetDate(from: reset) else { return .greatestFiniteMagnitude }
        return date.timeIntervalSinceNow
    }

    private func rdStatusRank(_ status: RDStatus) -> Int {
        switch status {
        case .ready: return 0
        case .api: return 1
        case .checking: return 2
        case .waiting: return 3
        case .noData: return 4
        case .failed: return 5
        case .login: return 6
        }
    }

    private var rdSortedProfiles: [CodexProfile] {
        profiles.sorted { lhs, rhs in
            let leftStatus = rdStatus(lhs)
            let rightStatus = rdStatus(rhs)
            if rdStatusRank(leftStatus) != rdStatusRank(rightStatus) {
                return rdStatusRank(leftStatus) < rdStatusRank(rightStatus)
            }
            if leftStatus == .waiting {
                return rdResetSoonness(lhs) < rdResetSoonness(rhs)
            }
            let leftWeekly = rdWindow(lhs, id: "7d") != nil
            let rightWeekly = rdWindow(rhs, id: "7d") != nil
            if leftWeekly != rightWeekly {
                return leftWeekly
            }
            let leftLeft = rdWeekly(lhs)?.percent ?? -1
            let rightLeft = rdWeekly(rhs)?.percent ?? -1
            if leftLeft != rightLeft {
                return leftLeft > rightLeft
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func rdMatchesFilter(_ profile: CodexProfile, filter: String) -> Bool {
        let status = rdStatus(profile)
        switch filter {
        case "available": return status == .ready || status == .api || status == .checking
        case "waiting": return status == .waiting
        case "login": return status == .login
        case "unconfirmed": return status == .failed || status == .noData
        default: return true
        }
    }

    private var rdVisibleProfiles: [CodexProfile] {
        let query = rdSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rdSortedProfiles.filter { profile in
            guard rdMatchesFilter(profile, filter: rdFilter) else { return false }
            guard !query.isEmpty else { return true }
            return profile.displayName.lowercased().contains(query)
                || profile.id.lowercased().contains(query)
                || profile.home.lowercased().contains(query)
        }
    }

    /// The account to use now: weekly-limit accounts first, most quota left, then whichever resets soonest.
    private var rdRecommended: CodexProfile? {
        profiles
            .filter { rdStatus($0) == .ready && (rdWeekly($0)?.percent ?? 0) > 0 }
            .sorted { lhs, rhs in
                let leftWeekly = rdWindow(lhs, id: "7d") != nil
                let rightWeekly = rdWindow(rhs, id: "7d") != nil
                if leftWeekly != rightWeekly { return leftWeekly }
                let leftLeft = rdWeekly(lhs)?.percent ?? 0
                let rightLeft = rdWeekly(rhs)?.percent ?? 0
                if leftLeft != rightLeft { return leftLeft > rightLeft }
                return rdResetSoonness(lhs) < rdResetSoonness(rhs)
            }
            .first
    }

    private var rdSelectedProfile: CodexProfile? {
        if let id = rdSelectedProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return rdRecommended ?? rdSortedProfiles.first
    }

    private func rdOpen(_ profile: CodexProfile) {
        if rdStatus(profile) == .failed {
            rdRefreshSingle(profile)
            return
        }
        openAccount(profile.id, displayName: profile.displayName)
    }

    private func rdPrimaryTitle(_ profile: CodexProfile) -> String {
        switch rdStatus(profile) {
        case .login: return tr("登入", "Log In")
        case .failed: return tr("重試", "Retry")
        default: return tr("打開", "Open")
        }
    }

    /// Refreshes one account's quota without touching the others; a failure keeps the previous data.
    private func rdRefreshSingle(_ profile: CodexProfile) {
        let id = profile.id
        guard !rdRefreshingIDs.contains(id) else { return }
        rdRefreshingIDs.insert(id)
        let names = displayNames
        let script = scriptPath
        runBackground(nil) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_USAGE_LIVE_LOOKUP"] = "1"
            environment["STATUS_PARALLELISM"] = "1"
            environment["USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS"] = "3"
            environment["USAGE_DIRECT_TIMEOUT_SECONDS"] = "8"
            environment["TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS"] = "2"
            environment["TOKEN_REFRESH_TIMEOUT_SECONDS"] = "6"
            environment["APP_SERVER_USAGE_TIMEOUT_SECONDS"] = "6"
            let accounts = runCodexScript(script, ["list-accounts"], wait: true, timeout: 10)
            guard accounts.0 == 0 else { return (accounts.0, "") }
            let status = runCodexScript(script, ["account-status", id], wait: true, timeout: 40, environment: environment)
            guard status.0 == 0 else { return (status.0, "") }
            let parsed = parsedCodexProfiles(accountsOutput: accounts.1, statusOutput: status.1, displayNames: names)
            guard let match = parsed.first(where: { $0.id == id }) else { return (1, "") }
            return (0, profilePayloadText(from: [profileWithCachedUsageFallback(match)]))
        } completion: { result in
            rdRefreshingIDs.remove(id)
            guard result.0 == 0,
                  let incoming = profilePayload(from: result.1).first,
                  incoming.quota != "unknown" || isExternalProvider(incoming) || incoming.authStatus == "login_needed"
            else {
                rdFailedRefreshIDs.insert(id)
                statusText = tr("\(profile.displayName) 更新失敗，保留上次資料", "\(profile.displayName) update failed; last data kept")
                return
            }
            rdFailedRefreshIDs.remove(id)
            let previous = profiles
            withAnimation(rdSpring) {
                profiles = stabilizedProfilesAfterRefresh(previous.map { $0.id == id ? incoming : $0 }, previousProfiles: previous)
            }
            statusText = tr("已更新 \(incoming.displayName)", "Updated \(incoming.displayName)")
        }
    }

    /// The black screen only ever starts from the confirmed branch here.
    private func rdConfirmScreenClean() {
        let alert = NSAlert()
        alert.messageText = tr("黑屏 15 秒？", "Black out the screen for 15 seconds?")
        alert.informativeText = tr(
            "所有螢幕會全黑，螢幕觸控會暫停，方便你抹螢幕。15 秒後自動回復，想提早結束可以撳 Esc。",
            "Every screen goes black and touch is paused so you can wipe the display. It comes back by itself after 15 seconds; press Esc to end early."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("開始黑屏", "Black Out"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        screenClean.start {
            statusText = tr("螢幕清潔完成", "Screen clean finished")
        }
    }

    private func rdConfirmCloseAll() {
        let alert = NSAlert()
        alert.messageText = tr("關閉全部 Codex 視窗？", "Close all Codex windows?")
        alert.informativeText = tr("進行中嘅工作可能會中斷。", "Work in progress may be interrupted.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("關閉全部", "Close All"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            closeAllAccounts()
        }
    }

    private var rdRefreshLabel: String? {
        if isRefreshing { return tr("更新緊…", "Updating…") }
        guard let last = rdLastRefreshAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: selectedLanguage.localeIdentifier)
        formatter.dateFormat = "HH:mm"
        return tr("\(formatter.string(from: last)) 更新", "updated \(formatter.string(from: last))")
    }

    // MARK: Accounts page

    private func rdAccountsPage(width: CGFloat) -> some View {
        let showInspector = width >= 980
        return VStack(spacing: 0) {
            rdPageHeader(tr("帳戶", "Accounts"), subtitle: rdRefreshLabel) {
                HStack(spacing: 8) {
                    rdSearchField
                    rdIconButton("arrow.clockwise", help: tr("更新全部額度（⌘R）", "Refresh all quota (⌘R)"), busy: isRefreshing) {
                        refreshProfiles(showLoading: false, replayQuota: false, liveUsage: true)
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    Menu {
                        Button(tr("打開 Profile 資料夾", "Open Profiles Folder")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-accounts"))
                        }
                        Divider()
                        Button(tr("關閉全部 Codex 視窗…", "Close All Codex Windows…")) { rdConfirmCloseAll() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(rdText2)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.05)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("更多", "More"))
                    Button {
                        createAccount()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(rdOnAccent)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(themePrimary))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RDPressStyle())
                    .keyboardShortcut("n", modifiers: [.command])
                    .help(tr("新增帳戶（⌘N）", "New account (⌘N)"))
                    .accessibilityLabel(tr("新增帳戶", "New account"))
                }
            }

            if !rdMissingTools.isEmpty {
                rdRequirementsBanner
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            HStack(spacing: 0) {
                rdAccountList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector, let selected = rdSelectedProfile {
                    Rectangle().fill(rdLine).frame(width: 1)
                    ZStack {
                        rdInspector(selected)
                            .id(selected.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 14)),
                                removal: .opacity
                            ))
                    }
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .background(rdInspectorPanel)
                    .clipped()
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(rdLine).frame(height: 1) }
        }
        .onAppear {
            rdRevealed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                rdRevealed = true
            }
        }
    }

    private var rdSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(rdText3)
            TextField(tr("搜尋", "Search"), text: $rdSearch)
                .textFieldStyle(.plain)
                .font(appFont(size: 13))
                .focused($rdSearchFocused)
            if !rdSearch.isEmpty {
                Button {
                    withAnimation(rdSpring) { rdSearch = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(rdText3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("清除搜尋", "Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: rdSearchFocused || !rdSearch.isEmpty ? 220 : 160, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.06)))
        .animation(rdSpring, value: rdSearchFocused)
    }

    private var rdAccountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rdFilter == "all", rdSearch.isEmpty, let pick = rdRecommended {
                rdRecommendationBar(pick)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                rdFilterBar
                Spacer(minLength: 8)
                Button {
                    withAnimation(rdSpring) { rdGroupByTier.toggle() }
                } label: {
                    Image(systemName: rdGroupByTier ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(rdGroupByTier ? themePrimary : rdText3)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                        .modifier(RDHoverFill(cornerRadius: 6, base: .clear, hover: rdInk.opacity(0.06)))
                }
                .buttonStyle(RDPressStyle())
                .help(rdGroupByTier ? tr("唔按方案分組", "Don't group by plan") : tr("按方案分組", "Group by plan"))
                Button {
                    withAnimation(rdSpring) { rdCompactRows.toggle() }
                } label: {
                    Image(systemName: rdCompactRows ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(rdText3)
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                        .modifier(RDHoverFill(cornerRadius: 6, base: .clear, hover: rdInk.opacity(0.06)))
                }
                .buttonStyle(RDPressStyle())
                .help(rdCompactRows ? tr("舒適間距", "Comfortable rows") : tr("緊湊間距", "Compact rows"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            rdColumnHeader
                .padding(.horizontal, 20)

            if profiles.isEmpty {
                rdSkeletonList
            } else if rdVisibleProfiles.isEmpty {
                rdEmptyState(tr("冇符合嘅帳戶", "No matching accounts"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(rdGroups) { group in
                            Section {
                                if !rdIsCollapsed(group.id) {
                                    ForEach(group.profiles) { profile in
                                        rdRow(profile)
                                            .id(rdRowKey(profile))
                                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                                    }
                                }
                            } header: {
                                if !group.title.isEmpty {
                                    rdGroupHeader(group)
                                        .background {
                                            GeometryReader { header in
                                                rdBackground.opacity(rdListScrolled && header.frame(in: .named("rdList")).minY <= 0.5 ? 1 : 0)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .animation(rdSpring, value: rdFilter)
                    .animation(rdSpring, value: rdSearch)
                    .animation(rdSpring, value: rdMeta)
                    .animation(rdSpring, value: rdGroupByTier)
                    .background {
                        GeometryReader { list in
                            Color.clear.preference(key: RDListScrolledKey.self, value: list.frame(in: .named("rdList")).minY < -0.5)
                        }
                    }
                }
                .coordinateSpace(name: "rdList")
                .onPreferenceChange(RDListScrolledKey.self) { rdListScrolled = $0 }
            }
        }
    }

    /// Placeholder rows in the shape of the list, shown while the accounts are first read.
    private var rdSkeletonList: some View {
        VStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { index in
                HStack(spacing: 11) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.08)).frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(rdInk.opacity(0.08)).frame(width: CGFloat(84 + (index * 37) % 76), height: 11)
                    Spacer(minLength: 16)
                    Capsule().fill(rdInk.opacity(0.06)).frame(width: 132, height: 22)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(rdInk.opacity(0.05)).frame(width: 44, height: 9)
                    Color.clear.frame(width: 150, height: 1)
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.06)).frame(width: 44, height: 30)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            Spacer(minLength: 0)
        }
        .modifier(RDPulse())
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel(tr("正在載入帳戶…", "Loading accounts…"))
    }

    private func rdEmptyState(_ title: String) -> some View {
        Text(title)
            .font(appFont(size: 13))
            .foregroundStyle(rdText3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rdRecommendationBar(_ profile: CodexProfile) -> some View {
        let weekly = rdWeekly(profile)
        let left = weekly?.percent ?? 0
        let reset = rdResetRelative(weekly?.reset)
        return HStack(spacing: 12) {
            Text(tr("建議", "Use now"))
                .font(appFont(size: 11, weight: .semibold))
                .foregroundStyle(themePrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(themePrimary.opacity(0.14)))
            rdBadge(profile, size: 26)
            Text(profile.displayName)
                .font(rdDisplay(15, weight: .semibold))
                .lineLimit(1)
            Text("\(left)%")
                .font(rdNumber(16))
                .foregroundStyle(rdLevelColor(left))
                .contentTransition(.numericText(value: Double(left)))
            if let reset {
                Text(reset)
                    .font(appFont(size: 12))
                    .foregroundStyle(rdText3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            rdPrimaryButton(tr("打開", "Open"), busy: busyProfiles.contains(profile.id)) {
                rdOpen(profile)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(themePrimary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(themePrimary.opacity(0.20), lineWidth: 1))
        .help(tr("剩餘最多；一樣多時揀最快重設嗰個，額度唔會浪費。", "Most quota left; on a tie, the one that resets first so nothing is wasted."))
    }

    private var rdFilterBar: some View {
        let all = profiles
        let options: [(String, String, String)] = [
            ("all", tr("全部", "All"), "square.grid.2x2"),
            ("available", tr("可用", "Available"), "checkmark.circle"),
            ("waiting", tr("等待重設", "Waiting for reset"), "hourglass"),
            ("login", tr("需要登入", "Login needed"), "person.crop.circle.badge.exclamationmark"),
            ("unconfirmed", tr("未確認", "Unconfirmed"), "questionmark.circle")
        ]
        return HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = rdFilter == option.0
                let count = all.filter { rdMatchesFilter($0, filter: option.0) }.count
                if option.0 == "all" || count > 0 || isOn {
                    Button {
                        withAnimation(rdSpring) { rdFilter = option.0 }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.2)
                                .font(.system(size: 11.5, weight: .semibold))
                            if isOn {
                                Text(option.1)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                            }
                            Text("\(count)").foregroundStyle(rdText3).monospacedDigit()
                        }
                        .font(appFont(size: 12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? rdText : rdText2)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(rdInk.opacity(0.11))
                                    .matchedGeometryEffect(id: "rdFilterSelection", in: rdNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RDPressStyle())
                    .help(option.1)
                    .accessibilityLabel("\(option.1) \(count)")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(rdInk.opacity(0.04)))
    }

    private var rdColumnHeader: some View {
        HStack(spacing: 16) {
            Text(tr("帳戶", "Account")).frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("每週 / 每月剩餘", "Weekly / monthly left")).frame(width: 196, alignment: .leading)
            Text(tr("5 小時", "5 hours")).frame(width: 84, alignment: .leading)
            Image(systemName: "ticket")
                .help(tr("重設券", "Reset tickets"))
                .frame(width: 56, alignment: .leading)
            Color.clear.frame(width: 44, height: 1)
        }
        .font(appFont(size: 11, weight: .medium))
        .foregroundStyle(rdText3)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// Everything a row draws. Lazy rows can keep what they first drew when only state outside the profile
    /// changes (a detected plan arriving, a pin), so the row is rebuilt whenever this key changes.
    private func rdRowKey(_ profile: CodexProfile) -> String {
        [profile.id, rdTier(profile)?.rawValue ?? "-", rdTierIsManual(profile) ? "m" : "a", rdIsPinned(profile) ? "p" : "-",
         profile.quota, profile.reset, profile.resetCredits, profile.authStatus, profile.authMode].joined(separator: "|")
    }

    private func rdRow(_ profile: CodexProfile) -> some View {
        let status = rdStatus(profile)
        let selected = rdSelectedProfile?.id == profile.id
        let compact = rdCompactRows
        let note = rdStatusNote(status, profile: profile)
        let pinned = rdIsPinned(profile)
        let hovering = rdHoverRowID == profile.id
        return HStack(spacing: 16) {
            HStack(spacing: 11) {
                rdBadge(profile, size: compact ? 24 : 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(rdDisplay(14, weight: .semibold))
                            .lineLimit(1)
                        if let tier = rdTier(profile) {
                            rdTierChip(tier)
                        }
                        Button {
                            rdTogglePin(profile)
                        } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                                .symbolEffect(.bounce, value: pinned)
                                .font(.system(size: 10.5, weight: .bold))
                                .rotationEffect(.degrees(45))
                                .foregroundStyle(pinned ? themePrimary : rdText3)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RDPressStyle())
                        .opacity(pinned || hovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: hovering)
                        .help(pinned ? tr("取消置頂", "Unpin") : tr("置頂", "Pin to top"))
                        .accessibilityLabel(pinned ? tr("取消置頂", "Unpin") : tr("置頂", "Pin to top"))
                    }
                    if let note {
                        Text(note)
                            .font(appFont(size: 12))
                            .foregroundStyle(status == .failed ? rdOrange : (status == .waiting ? rdAmber : rdText3))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rdLongCell(profile, status: status)
                .frame(width: 196, alignment: .leading)
            rdShortCell(profile)
                .frame(width: 84, alignment: .leading)
            rdTicketChip(profile)
                .frame(width: 56, alignment: .leading)
            rdRowAction(profile, highlighted: selected)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 10)
        .contentShape(Rectangle())
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rdPalette.selection.opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(rdPalette.selectionLine, lineWidth: 1))
                    .matchedGeometryEffect(id: "rdRowSelection", in: rdNamespace)
            }
        }
        .modifier(RDHoverFill(cornerRadius: 10, base: .clear, hover: selected ? .clear : rdInk.opacity(0.03)))
        .onHover { inside in
            if inside { rdHoverRowID = profile.id } else if rdHoverRowID == profile.id { rdHoverRowID = nil }
        }
        .onTapGesture(count: 2) {
            rdSelectedProfileID = profile.id
            rdOpen(profile)
        }
        .onTapGesture {
            withAnimation(rdSpring) {
                rdSelectedProfileID = profile.id
            }
        }
        .contextMenu {
            Button(rdPrimaryTitle(profile)) { rdOpen(profile) }
            Button(tr("只更新此帳戶", "Refresh This Account")) { rdRefreshSingle(profile) }
            Button(tr("關閉視窗", "Close Window")) { closeAccount(profile) }
            Divider()
            Button(pinned ? tr("取消置頂", "Unpin") : tr("置頂", "Pin to Top")) { rdTogglePin(profile) }
            if pinned {
                let order = rdPinnedOrder
                Button(tr("上移", "Move Up")) { rdMovePin(profile, by: -1) }
                    .disabled(order.first?.id == profile.id)
                Button(tr("下移", "Move Down")) { rdMovePin(profile, by: 1) }
                    .disabled(order.last?.id == profile.id)
            }
            if !isExternalProvider(profile) {
                rdPlanMenu(profile)
            }
            Divider()
            Button(tr("改名…", "Rename…")) { renameProfile(profile) }
            Button(tr("自訂 Icon…", "Custom Icon…")) { chooseCustomIcon(for: profile) }
            Button(tr("喺 Finder 顯示", "Reveal in Finder")) { revealProfile(profile) }
        }
        .accessibilityElement(children: .combine)
    }

    /// The headline number: quota left in the long window, big and colored by level.
    private func rdLongCell(_ profile: CodexProfile, status: RDStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let window = rdLongWindow(profile), let percent = window.percent {
                HStack(spacing: 8) {
                    rdQuotaBar(percent, height: rdCompactRows ? 18 : 22)
                        .frame(width: 132)
                    Text(window.id == "30d" ? rdWindowName("30d") : rdResetShort(window.reset))
                        .font(appFont(size: 11))
                        .foregroundStyle(rdText3)
                        .lineLimit(1)
                        .fixedSize()
                }
            } else {
                Text(status == .login ? tr("登入後顯示", "After login") : (status == .api ? tr("外部 API", "External API") : "—"))
                    .font(appFont(size: 12))
                    .foregroundStyle(rdText3)
            }
        }
    }

    private func rdShortCell(_ profile: CodexProfile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let window = rdWindow(profile, id: "5h"), let percent = window.percent {
                rdQuotaBar(percent, height: rdCompactRows ? 15 : 17)
                    .frame(width: 76)
            } else {
                Text("—")
                    .font(appFont(size: 12))
                    .foregroundStyle(rdText3)
                    .help(rdLongWindow(profile) != nil ? tr("呢個帳戶冇 5 小時限額", "No 5-hour limit on this account") : "")
            }
        }
    }

    private func rdTicketChip(_ profile: CodexProfile) -> some View {
        Group {
            if let summary = resetCreditSummary(for: profile) {
                let soon = rdTicketExpiringSoon(profile)
                HStack(spacing: 4) {
                    Image(systemName: soon ? "exclamationmark.triangle.fill" : "ticket")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("\(summary.count)")
                        .font(rdNumber(12.5))
                        .monospacedDigit()
                }
                .foregroundStyle(soon ? rdOrange : rdTicket)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill((soon ? rdOrange : rdTicket).opacity(0.12)))
                .help(summary.expiries.first.map { tr("最早 \(rdTicketDate($0)) 到期", "First expires \(rdTicketDate($0))") } ?? "")
            } else {
                Text("—")
                    .font(appFont(size: 12))
                    .foregroundStyle(rdText3)
            }
        }
    }

    private func rdPrimaryIcon(_ profile: CodexProfile) -> String {
        switch rdStatus(profile) {
        case .login: return "person.badge.key.fill"
        case .failed: return "arrow.clockwise"
        default: return "arrow.up.forward"
        }
    }

    private func rdRowAction(_ profile: CodexProfile, highlighted: Bool) -> some View {
        let status = rdStatus(profile)
        let filled = highlighted || status == .login
        let busy = busyProfiles.contains(profile.id) || rdRefreshingIDs.contains(profile.id)
        return Button {
            rdOpen(profile)
        } label: {
            ZStack {
                Image(systemName: rdPrimaryIcon(profile)).opacity(busy ? 0 : 1)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(filled ? rdOnAccent : rdText2)
            .frame(width: 40, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(filled ? themePrimary : rdInk.opacity(0.06)))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.18), value: filled)
        }
        .buttonStyle(RDPressStyle())
        .disabled(busy || isClosingAllAccounts)
        .help(rdPrimaryTitle(profile) + " " + profile.displayName)
        .accessibilityLabel(rdPrimaryTitle(profile) + " " + profile.displayName)
    }

    // MARK: Inspector

    private func rdGauge(_ percent: Int, size: CGFloat) -> some View {
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        return ZStack {
            Circle()
                .stroke(percent == 0 ? rdLevelColor(0).opacity(0.18) : rdPalette.track, lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction * (rdRevealed ? 1 : 0))
                .stroke(
                    AngularGradient(colors: [rdLevelColor(percent).opacity(0.75), rdLevelColor(percent)], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * Double(max(fraction, 0.01)))),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: rdLevelColor(percent).opacity(rdIsDark ? 0.35 : 0.15), radius: 8)
            VStack(spacing: 0) {
                Text("\(percent)%")
                    .font(rdNumber(30))
                    .foregroundStyle(rdLevelColor(percent))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent)))
                Text(tr("剩餘", "left"))
                    .font(appFont(size: 11))
                    .foregroundStyle(rdText3)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.9, dampingFraction: 0.85), value: rdRevealed)
        .animation(.spring(response: 0.7, dampingFraction: 0.85), value: percent)
    }

    private func rdInspector(_ profile: CodexProfile) -> some View {
        let status = rdStatus(profile)
        let long = rdLongWindow(profile)
        let others = quotaWindows(for: profile).filter { $0.percent != nil && $0.id != long?.id }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        rdBadge(profile, size: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName)
                                .font(rdDisplay(16, weight: .semibold))
                                .lineLimit(1)
                            if let note = rdStatusNote(status, profile: profile) {
                                Text(note)
                                    .font(appFont(size: 12))
                                    .foregroundStyle(status == .failed ? rdOrange : (status == .waiting ? rdAmber : rdText3))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button {
                            rdTogglePin(profile)
                        } label: {
                            Image(systemName: rdIsPinned(profile) ? "pin.fill" : "pin")
                                .symbolEffect(.bounce, value: rdIsPinned(profile))
                                .font(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(45))
                                .foregroundStyle(rdIsPinned(profile) ? themePrimary : rdText2)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                                .modifier(RDHoverFill(cornerRadius: 7, base: rdIsPinned(profile) ? themePrimary.opacity(0.14) : .clear, hover: rdInk.opacity(0.08)))
                        }
                        .buttonStyle(RDPressStyle())
                        .help(rdIsPinned(profile) ? tr("取消置頂", "Unpin") : tr("置頂", "Pin to top"))
                        .accessibilityLabel(rdIsPinned(profile) ? tr("取消置頂", "Unpin") : tr("置頂", "Pin to top"))
                        Button {
                            showProfilePopupMenu(for: profile)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(rdText2)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                                .modifier(RDHoverFill(cornerRadius: 7, base: .clear, hover: rdInk.opacity(0.08)))
                        }
                        .buttonStyle(RDPressStyle())
                        .accessibilityLabel(tr("更多操作", "More actions"))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                    if !isExternalProvider(profile) {
                        rdPlanPicker(profile)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)
                    }

                    if let long, let percent = long.percent {
                        VStack(spacing: 8) {
                            rdGauge(percent, size: 132)
                            Text(rdWindowName(long.id))
                                .font(appFont(size: 12, weight: .medium))
                                .foregroundStyle(rdText2)
                            if let reset = rdResetFull(long.reset) {
                                Text(reset)
                                    .font(appFont(size: 12))
                                    .foregroundStyle(rdText3)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    } else {
                        Text(status == .login ? tr("登入後先會顯示額度", "Log in to see quota") : tr("未有額度資料", "No quota data"))
                            .font(appFont(size: 13))
                            .foregroundStyle(rdText3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }

                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(others) { window in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(rdWindowName(window.id)).font(appFont(size: 12)).foregroundStyle(rdText2)
                                        Spacer()
                                        Text("\(window.percent ?? 0)%")
                                            .font(rdNumber(15))
                                            .monospacedDigit()
                                            .contentTransition(.numericText(value: Double(window.percent ?? 0)))
                                    }
                                    rdQuotaBar(window.percent ?? 0, height: 16, label: false)
                                    if let reset = rdResetFull(window.reset) {
                                        Text(reset).font(appFont(size: 11)).foregroundStyle(rdText3)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .overlay(alignment: .top) { Rectangle().fill(rdLine).frame(height: 1) }
                    }

                    if let summary = resetCreditSummary(for: profile) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "ticket").foregroundStyle(rdTicket)
                                Text("\(summary.count)").font(rdNumber(15)).foregroundStyle(rdTicket)
                                Text(tr("張重設券", "reset tickets")).font(appFont(size: 12)).foregroundStyle(rdText2)
                                Spacer()
                            }
                            ForEach(Array(summary.expiries.enumerated()), id: \.offset) { _, expiry in
                                HStack {
                                    Text(rdTicketDate(expiry))
                                    Spacer()
                                    Text(resetCreditRemainingText(expiry)).foregroundStyle(rdText3)
                                }
                                .font(appFont(size: 12))
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .overlay(alignment: .top) { Rectangle().fill(rdLine).frame(height: 1) }
                    }

                    if !isExternalProvider(profile) {
                        let mode = profileHistoryMode(for: profile)
                        let anchor = isHistoryAnchor(profile)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(tr("本機對話", "Local chats")).font(appFont(size: 12)).foregroundStyle(rdText2)
                                Spacer()
                                rdIconSegmented(
                                    rdHistoryOptions,
                                    selection: mode == .shared,
                                    key: "inspector-history",
                                    disabled: anchor
                                ) { shared in
                                    if shared, mode != .shared {
                                        shareHistory(profile)
                                    } else if !shared, mode != .privateOnly {
                                        separateHistory(profile)
                                    }
                                }
                            }
                            Button {
                                revealProfile(profile)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(rdHomeRelative(profile.home))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(appFont(size: 12))
                                .foregroundStyle(rdText3)
                            }
                            .buttonStyle(.plain)
                            .help(tr("喺 Finder 顯示", "Reveal in Finder"))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .overlay(alignment: .top) { Rectangle().fill(rdLine).frame(height: 1) }
                    }
                }
            }

            HStack(spacing: 8) {
                rdIconButton("arrow.clockwise", help: tr("只更新此帳戶", "Refresh this account"), busy: rdRefreshingIDs.contains(profile.id)) {
                    rdRefreshSingle(profile)
                }
                if profile.id != "account1", profile.id != "opencodex-lab" {
                    rdIconButton("trash", help: tr("刪除 Profile…", "Delete Profile…")) {
                        deleteProfile(profile)
                    }
                }
                Spacer(minLength: 4)
                rdPrimaryButton(rdPrimaryTitle(profile), busy: busyProfiles.contains(profile.id)) {
                    rdOpen(profile)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(rdLine).frame(height: 1) }
        }
    }

    // MARK: Insights page

    private func rdRefreshAnalytics(force: Bool = false) {
        if !force, let snapshot = rdAnalytics, !snapshot.insights.isEmpty, Date().timeIntervalSince(snapshot.scannedAt) < 300 { return }
        guard !rdAnalyticsLoading, !profiles.isEmpty else { return }
        rdAnalyticsLoading = true
        let inputs = profiles.filter { !isExternalProvider($0) }.map { (id: $0.id, name: $0.displayName, home: $0.home) }
        var current: [String: (left: Int, minutes: Int, reset: Date?)] = [:]
        for profile in profiles {
            guard let window = rdLongWindow(profile), let percent = window.percent else { continue }
            let reset = window.reset.flatMap { resetDate(from: $0) }
            if let reset, reset < Date().addingTimeInterval(-60) { continue }
            current[profile.id] = (percent, window.id == "30d" ? 43200 : 10080, reset)
        }
        RDAnalyticsEngine.queue.async {
            let snapshot = RDAnalyticsEngine.scan(profiles: inputs, current: current)
            DispatchQueue.main.async {
                rdAnalyticsLoading = false
                withAnimation(rdSpring) {
                    rdAnalytics = snapshot
                    if rdChartProfileID == nil {
                        rdChartProfileID = snapshot.insights
                            .filter { (snapshot.samplesByProfile[$0.id]?.count ?? 0) > 1 }
                            .max { ($0.activeSeconds7d) < ($1.activeSeconds7d) }?.id
                    }
                }
            }
            let tokenData = RDTokenEngine.scan(profiles: inputs)
            DispatchQueue.main.async {
                rdTokenData = tokenData
                rdUpdateTokenReport()
            }
        }
    }

    private func rdUpdateTokenReport() {
        guard let data = rdTokenData else { return }
        let known = data.pools.contains { $0.id == rdAnalysisScope }
        let report = RDTokenEngine.report(data, scope: known ? rdAnalysisScope : nil, days: rdAnalysisDays)
        let overall = known ? RDTokenEngine.report(data, scope: nil, days: rdAnalysisDays).totals.total : report.totals.total
        withAnimation(rdSpring) {
            rdTokenReport = report
            rdTokenOverallTotal = overall
        }
    }

    private func rdSetAnalysisScope(_ id: String) {
        rdAnalysisScope = id
        if let snapshot = rdAnalytics, let pool = rdTokenData?.pools.first(where: { $0.id == id }),
           let member = pool.members.first(where: { (snapshot.samplesByProfile[$0]?.count ?? 0) > 1 }) {
            rdChartProfileID = member
        }
        rdUpdateTokenReport()
    }

    private var rdInsightsPage: some View {
        VStack(spacing: 0) {
            rdPageHeader(tr("分析", "Insights"), subtitle: rdAnalytics.map { tr("\(DateFormatter.localizedString(from: $0.scannedAt, dateStyle: .none, timeStyle: .short)) 分析", "analysed \(DateFormatter.localizedString(from: $0.scannedAt, dateStyle: .none, timeStyle: .short))") }) {
                HStack(spacing: 8) {
                    rdAnalysisScopeMenu
                    rdSegmented([(7, tr("7 日", "7 days")), (30, tr("30 日", "30 days")), (0, tr("全部", "All"))], selection: rdAnalysisDays, key: "analysis-days") { days in
                        rdAnalysisDays = days
                        rdUpdateTokenReport()
                    }
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(rdText3)
                        .frame(width: 30, height: 30)
                        .help(tr(
                            "Token 數字嚟自 Codex 自己記低嘅用量，只讀數字、模型同項目資料夾，唔會讀對話內容。帳戶靠額度重設時間辨認，舊紀錄未必認得出。API 等值按官方標準價估算，唔係實際收費。",
                            "Token numbers come from Codex's own usage records: only numbers, models and project folders are read, never conversation text. Accounts are matched by quota reset time, so older records may stay unmatched. API equivalent is an estimate at published standard prices, not a bill."
                        ))
                    rdIconButton("arrow.clockwise", help: tr("重新分析", "Analyse again"), busy: rdAnalyticsLoading) {
                        rdRefreshAnalytics(force: true)
                    }
                }
            }
            if let snapshot = rdAnalytics {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        rdTokenSection(snapshot)
                        rdSectionLabel(tr("額度狀況", "Quota status"))
                        rdKPIStrip(snapshot)
                        rdAllAccountsQuotaCard(snapshot)
                        HStack(alignment: .top, spacing: 16) {
                            rdQuotaTrendCard(snapshot)
                            rdDailyUsageCard(snapshot)
                        }
                        rdInsightTable(snapshot)
                        EmptyView()
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 4)
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(tr("分析緊各帳戶紀錄…", "Reading account history…"))
                        .font(appFont(size: 13))
                        .foregroundStyle(rdText3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { rdRefreshAnalytics() }
    }

    // MARK: Token analysis

    private func rdTokens(_ value: Double) -> String {
        if value >= 100_000_000 {
            let n = value / 100_000_000
            return tr(String(format: n >= 100 ? "%.0f 億" : "%.1f 億", n), String(format: value >= 1e10 ? "%.0fB" : "%.1fB", value / 1e9))
        }
        if value >= 10_000 {
            let n = value / 10_000
            return tr(String(format: n >= 100 ? "%.0f 萬" : "%.1f 萬", n), String(format: value >= 1e6 ? "%.1fM" : "%.0fK", value >= 1e6 ? value / 1e6 : value / 1e3))
        }
        return String(Int(value))
    }

    private func rdMoney(_ value: Double) -> String {
        if value >= 10 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return "$" + (formatter.string(from: NSNumber(value: value)) ?? String(Int(value)))
        }
        return String(format: "$%.2f", value)
    }

    private func rdPercentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func rdSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(appFont(size: 13, weight: .semibold))
            .foregroundStyle(rdText2)
            .padding(.top, 6)
    }

    private func rdAnalysisCardTitle(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(rdDisplay(15, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(appFont(size: 12))
                    .foregroundStyle(rdText3)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rdAnalysisScopeMenu: some View {
        let pools = rdTokenData?.pools ?? []
        let current = pools.first { $0.id == rdAnalysisScope }?.name ?? tr("全部帳戶", "All accounts")
        return Menu {
            Button(tr("全部帳戶", "All accounts")) { rdSetAnalysisScope("") }
            Divider()
            ForEach(pools) { pool in
                Button(pool.name) { rdSetAnalysisScope(pool.id) }
            }
        } label: {
            Label(current, systemImage: "person.2")
                .font(appFont(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rdInk.opacity(0.06)))
        .disabled(pools.isEmpty)
        .accessibilityLabel(tr("分析範圍", "Analysis scope"))
    }

    @ViewBuilder
    private func rdTokenSection(_ snapshot: RDAnalyticsSnapshot) -> some View {
        if let report = rdTokenReport {
            if report.totals.total > 0 {
                rdTokenKPIs(report)
                rdTokenTrendCard(report)
                if rdTokenData?.pools.contains(where: { $0.id == rdAnalysisScope }) == true {
                    rdScopeConversionCard(report)
                } else {
                    rdTokenAccountsCard(report)
                }
                HStack(alignment: .top, spacing: 16) {
                    rdQuotaPlanCard(snapshot)
                    rdTokenTipsCard(report, snapshot)
                }
                HStack(alignment: .top, spacing: 16) {
                    rdMixCard(tr("模型", "Models"), rows: report.models, total: report.totals.total, showMoney: true)
                    rdMixCard(tr("推理級別", "Reasoning effort"), rows: report.efforts, total: report.totals.total, showMoney: true)
                    rdMixCard(tr("項目資料夾", "Project folders"), rows: report.projects, total: report.totals.total, showMoney: false)
                }
                HStack(alignment: .top, spacing: 16) {
                    rdHeatmapCard(report)
                    rdAgentSplitCard(report)
                }
                rdTopThreadsCard(report)
            } else {
                rdCard {
                    Text(tr("呢個帳戶喺呢段時間冇 token 紀錄。", "No token records for this account in this period."))
                        .font(appFont(size: 13))
                        .foregroundStyle(rdText3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(28)
                }
            }
        } else {
            rdCard {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tr("整理緊 token 紀錄，第一次會耐少少…", "Reading token records; the first time takes a little longer…"))
                        .font(appFont(size: 13))
                        .foregroundStyle(rdText3)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(28)
            }
        }
    }

    private func rdTokenKPIs(_ report: RDTokenReport) -> some View {
        let totals = report.totals
        // Older records mostly cannot be matched to an account, so the comparison only means something overall.
        let isOverall = rdTokenData?.pools.contains { $0.id == rdAnalysisScope } != true
        let change: String? = (isOverall ? report.previousTotal : nil).map { previous in
            let percent = Int(((totals.total - previous) / previous * 100).rounded())
            return tr("比上一段時間 \(percent >= 0 ? "+" : "")\(percent)%", "\(percent >= 0 ? "+" : "")\(percent)% vs previous")
        }
        let inputs = totals.cached + totals.fresh
        let cacheRate = inputs > 0 ? totals.cached / inputs : nil
        let coverage = totals.total > 0 ? totals.detailed / totals.total : 0
        let averageContext = totals.requests > 0 ? totals.requestInput / Double(totals.requests) : nil
        let turns = report.turnsCompleted + report.turnsFailed + report.turnsInterrupted
        let failedShare = turns > 0 ? Double(report.turnsFailed) / Double(turns) : 0
        return HStack(spacing: 12) {
            rdKPI(tr("Token 總量", "Total tokens"), value: rdTokens(totals.total), detail: change ?? tr("新輸入 \(rdTokens(totals.fresh)) · 輸出 \(rdTokens(totals.output))", "Fresh \(rdTokens(totals.fresh)) · Output \(rdTokens(totals.output))"))
            rdKPI(tr("API 等值（估算）", "API equivalent (est.)"), value: rdMoney(totals.usd), detail: tr("計咗 \(rdPercentText(coverage)) 用量", "Covers \(rdPercentText(coverage)) of use"), tint: themePrimary)
            rdKPI(tr("快取命中率", "Cache hit rate"), value: cacheRate.map(rdPercentText) ?? "—", detail: averageContext.map { tr("平均每次 \(rdTokens($0)) 上下文", "\(rdTokens($0)) context per request") })
            rdKPI(tr("AI 工作時間", "AI working time"), value: rdHours(report.workSeconds), detail: tr("\(turns) 個回合 · 失敗 \(rdPercentText(failedShare))", "\(turns) turns · \(rdPercentText(failedShare)) failed"))
            rdKPI(tr("對話", "Conversations"), value: "\(report.mainCount + report.subCount)", detail: tr("主對話 \(report.mainCount) · Sub-agent \(report.subCount)", "Main \(report.mainCount) · Sub-agent \(report.subCount)"))
        }
    }

    private func rdTokenTrendCard(_ report: RDTokenReport) -> some View {
        let kinds: [String]
        let names: [String]
        let colors: [Color]
        switch rdTokenChartMode {
        case "work":
            kinds = ["fresh", "output"]
            names = [tr("新輸入", "Fresh input"), tr("輸出", "Output")]
            colors = [themePrimary, rdAmber]
        case "usd":
            kinds = ["usd"]
            names = [tr("API 等值", "API equivalent")]
            colors = [themePrimary]
        default:
            kinds = ["cached", "fresh", "output", "unsplit"]
            names = [tr("快取輸入", "Cached input"), tr("新輸入", "Fresh input"), tr("輸出", "Output"), tr("未細分", "Not itemised")]
            colors = [themeSecondary.opacity(0.62), themePrimary, rdAmber, rdInk.opacity(0.18)]
        }
        let points = report.days.filter { kinds.contains($0.kind) }
        let isMoney = rdTokenChartMode == "usd"
        return rdCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    rdAnalysisCardTitle(tr("每日用量", "Daily use"), subtitle: rdTokenChartMode == "work" ? tr("唔計快取，最接近實際消耗。", "Without cache: closest to real consumption.") : nil)
                    Spacer()
                    rdSegmented([("all", tr("全部", "All")), ("work", tr("新輸入＋輸出", "Fresh + output")), ("usd", tr("API 等值", "API equivalent"))], selection: rdTokenChartMode, key: "token-chart") { mode in
                        withAnimation(rdSpring) { rdTokenChartMode = mode }
                    }
                }
                if points.isEmpty {
                    Text(tr("呢段時間未有細項紀錄。", "No itemised records in this period."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Chart(points) { point in
                        BarMark(x: .value("day", point.date, unit: .day), y: .value("value", point.value))
                            .foregroundStyle(by: .value("kind", names[kinds.firstIndex(of: point.kind) ?? 0]))
                            .cornerRadius(2)
                    }
                    .chartForegroundStyleScale(domain: names, range: colors)
                    .chartLegend(kinds.count > 1 ? .visible : .hidden)
                    .chartLegend(position: .top, alignment: .leading, spacing: 10)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(rdLine)
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(isMoney ? rdMoney(number) : rdTokens(number))
                                        .font(appFont(size: 11))
                                        .foregroundStyle(rdText3)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                                .font(appFont(size: 11))
                                .foregroundStyle(rdText3)
                        }
                    }
                    .frame(height: 200)
                }
            }
            .padding(16)
        }
    }

    private func rdAccountColumn(_ text: String, width: CGFloat, tint: Color? = nil) -> some View {
        Text(text)
            .font(appFont(size: 12))
            .monospacedDigit()
            .foregroundStyle(tint ?? rdText2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
            .frame(width: width, alignment: .trailing)
    }

    private func rdAllAccountsQuotaPoints(_ snapshot: RDAnalyticsSnapshot) -> (names: [String], points: [RDChartPoint]) {
        let since = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        var names: [String] = []
        var points: [RDChartPoint] = []
        for pool in rdTokenData?.pools ?? [] {
            let weekly = pool.members
                .map { id in (snapshot.samplesByProfile[id] ?? []).filter { $0.w == 10080 && $0.t >= since }.sorted { $0.t < $1.t } }
                .max { $0.count < $1.count } ?? []
            guard weekly.count > 1, weekly.contains(where: { $0.u > 0 }) else { continue }
            names.append(pool.name)
            for sample in weekly {
                points.append(RDChartPoint(id: "\(pool.id)|\(sample.t)", date: Date(timeIntervalSince1970: sample.t), left: max(0, 100 - sample.u), series: pool.name))
            }
        }
        return (names, points)
    }

    /// Every paid account's weekly quota on one chart, from the readings taken every minute.
    @ViewBuilder
    private func rdAllAccountsQuotaCard(_ snapshot: RDAnalyticsSnapshot) -> some View {
        let isOverall = rdTokenData?.pools.contains { $0.id == rdAnalysisScope } != true
        let data = rdAllAccountsQuotaPoints(snapshot)
        if isOverall, data.names.count > 1 {
            let palette: [Color] = [themePrimary, themeSecondary, rdAmber, rdSuccess, rdOrange, rdDanger]
            rdCard {
                VStack(alignment: .leading, spacing: 12) {
                    rdAnalysisCardTitle(tr("各帳戶每週額度", "Weekly quota by account"), subtitle: tr("近 7 日，App 開住時每分鐘更新。", "Last 7 days, refreshed every minute while the app is open."))
                    Chart(data.points) { point in
                        LineMark(x: .value("time", point.date), y: .value("left", point.left))
                            .foregroundStyle(by: .value("account", point.series))
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartForegroundStyleScale(domain: data.names, range: Array(palette.prefix(max(1, data.names.count))))
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { value in
                            AxisGridLine().foregroundStyle(rdLine)
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("\(Int(number))%").font(appFont(size: 10)).foregroundStyle(rdText3)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                                .foregroundStyle(rdText3)
                        }
                    }
                    .chartLegend(position: .top, alignment: .leading, spacing: 10)
                    .frame(height: 190)
                }
                .padding(16)
            }
        }
    }

    private func rdTokenAccountsCard(_ report: RDTokenReport) -> some View {
        let largest = report.accounts.map(\.totals.total).max() ?? 1
        return rdCard {
            VStack(alignment: .leading, spacing: 10) {
                rdAnalysisCardTitle(
                    tr("帳戶比較", "Accounts"),
                    subtitle: tr("撳一行睇嗰個帳戶。靠額度重設時間辨認；同一個 ChatGPT 帳戶登入幾次會算埋一齊。", "Click a row for that account. Matched by quota reset time; one ChatGPT account signed in several times counts together.")
                )
                HStack(spacing: 10) {
                    Text(tr("帳戶", "Account")).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Token").frame(width: 62, alignment: .trailing)
                    Text(tr("API 等值", "API equiv.")).frame(width: 62, alignment: .trailing)
                    Text(tr("快取", "Cache")).frame(width: 44, alignment: .trailing)
                    Text(tr("每 1% 額度", "Per 1%")).frame(width: 66, alignment: .trailing)
                    Text(tr("滿額值", "Full window"))
                        .frame(width: 66, alignment: .trailing)
                        .help(tr("一個額度週期用滿大約等於幾多 API 費用，用記錄最完整嗰個週期估算。", "Roughly what one full quota window is worth at API prices, estimated from the best-recorded window."))
                }
                .font(appFont(size: 11))
                .foregroundStyle(rdText3)
                ForEach(report.accounts) { account in
                    let inputs = account.totals.cached + account.totals.fresh
                    Button {
                        if !account.id.isEmpty { rdSetAnalysisScope(account.id) }
                    } label: {
                        VStack(spacing: 5) {
                            HStack(spacing: 10) {
                                Text(account.id.isEmpty ? tr("未能歸屬（舊紀錄）", "Unmatched (older records)") : account.name)
                                    .font(appFont(size: 13, weight: .medium))
                                    .foregroundStyle(account.id.isEmpty ? rdText3 : rdText)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                rdAccountColumn(rdTokens(account.totals.total), width: 62, tint: rdText)
                                rdAccountColumn(rdMoney(account.totals.usd), width: 62, tint: themePrimary)
                                rdAccountColumn(inputs > 0 ? rdPercentText(account.totals.cached / inputs) : "—", width: 44)
                                rdAccountColumn(account.pool?.tokensPerPercent.map(rdTokens) ?? "—", width: 66)
                                rdAccountColumn(account.pool?.usdPerFullWindow.map(rdMoney) ?? "—", width: 66)
                            }
                            GeometryReader { bar in
                                Capsule().fill(rdInk.opacity(0.06))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(account.id.isEmpty ? rdInk.opacity(0.22) : themePrimary)
                                            .frame(width: max(3, bar.size.width * CGFloat(account.totals.total / largest)))
                                    }
                            }
                            .frame(height: 4)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .modifier(RDHoverFill(cornerRadius: 8, base: .clear, hover: account.id.isEmpty ? .clear : rdInk.opacity(0.05)))
                        .padding(.horizontal, -8)
                    }
                    .buttonStyle(RDPressStyle())
                    .disabled(account.id.isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func rdWindowPhrase(_ minutes: Int?) -> String {
        switch minutes {
        case 43200: return tr("一個月", "month")
        case 300: return tr("5 小時", "5 hours")
        default: return tr("一星期", "week")
        }
    }

    private func rdScopeConversionCard(_ report: RDTokenReport) -> some View {
        let pool = rdTokenData?.pools.first { $0.id == rdAnalysisScope }
        let share = rdTokenOverallTotal > 0 ? report.totals.total / rdTokenOverallTotal : 0
        return HStack(spacing: 12) {
            rdKPI(tr("每 1% 額度約等於", "1% of quota is about"), value: pool?.tokensPerPercent.map(rdTokens) ?? "—", detail: tr("Token", "tokens"))
            rdKPI(tr("\(rdWindowPhrase(pool?.windowMinutes))額度用滿約值", "A full \(rdWindowPhrase(pool?.windowMinutes)) is worth"), value: pool?.usdPerFullWindow.map(rdMoney) ?? "—", detail: tr("API 等值，估算", "API equivalent, estimated"), tint: themePrimary)
            rdKPI(tr("佔全部用量", "Share of all use"), value: rdPercentText(share), detail: (pool?.members.count ?? 1) > 1 ? tr("\(pool?.members.count ?? 1) 個 Profile 共用同一額度", "\(pool?.members.count ?? 1) profiles share this quota") : nil)
        }
    }

    private struct RDPlanRow: Identifiable {
        let id: String
        let name: String
        let left: Int
        let reset: Date
        let leftover: Double?
    }

    /// Which paid quota will expire unused, soonest first. A pool signed in several times is listed once.
    private func rdPlanRows(_ snapshot: RDAnalyticsSnapshot) -> [RDPlanRow] {
        let now = Date()
        let pools = rdTokenData?.pools ?? []
        let scoped = pools.first { $0.id == rdAnalysisScope }
        var seen = Set<String>()
        var rows: [RDPlanRow] = []
        for insight in snapshot.insights {
            guard let left = insight.left, let reset = insight.resetAt, reset > now else { continue }
            if left >= 100, (insight.perDay ?? 0) < 0.5 { continue }     // Never used: nothing is being wasted.
            if let scoped, !scoped.members.contains(insight.id) { continue }
            let pool = pools.first { $0.members.contains(insight.id) }
            guard seen.insert(pool?.id ?? insight.id).inserted else { continue }
            let days = reset.timeIntervalSince(now) / 86_400
            let leftover = insight.perDay.map { max(0, Double(left) - $0 * days) }
            rows.append(RDPlanRow(id: insight.id, name: pool?.name ?? insight.name, left: left, reset: reset, leftover: leftover))
        }
        return rows.sorted { $0.reset < $1.reset }
    }

    private func rdQuotaPlanCard(_ snapshot: RDAnalyticsSnapshot) -> some View {
        let rows = Array(rdPlanRows(snapshot).prefix(6))
        return rdCard {
            VStack(alignment: .leading, spacing: 10) {
                rdAnalysisCardTitle(tr("重設前會唔會嘥額度", "Quota at risk before reset"), subtitle: tr("按最近用量推算，最快重設排先。", "Projected from recent use; soonest reset first."))
                if rows.isEmpty {
                    Text(tr("未有足夠額度紀錄。", "Not enough quota history yet."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                }
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .font(appFont(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(tr("剩 \(row.left)% · \(rdRelative(row.reset))重設", "\(row.left)% left · resets \(rdRelative(row.reset))"))
                                .font(appFont(size: 12))
                                .foregroundStyle(rdText3)
                        }
                        Spacer(minLength: 8)
                        if row.left == 0 {
                            Text(tr("已用完", "Used up"))
                                .font(appFont(size: 12, weight: .semibold))
                                .foregroundStyle(rdDanger)
                        } else if let leftover = row.leftover {
                            Text(leftover >= 5 ? tr("預計嘥 \(Int(leftover.rounded()))%", "~\(Int(leftover.rounded()))% unused") : tr("用得晒", "On pace"))
                                .font(appFont(size: 12, weight: .semibold))
                                .foregroundStyle(leftover >= 5 ? rdAmber : rdSuccess)
                        } else {
                            Text(tr("未夠數據", "No pace yet"))
                                .font(appFont(size: 12))
                                .foregroundStyle(rdText3)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rdTokenTips(_ report: RDTokenReport, _ snapshot: RDAnalyticsSnapshot) -> [(icon: String, text: String, tint: Color)] {
        var tips: [(icon: String, text: String, tint: Color)] = []
        let total = report.totals.total
        guard total > 0 else { return tips }
        if let waste = rdPlanRows(snapshot).first(where: { ($0.leftover ?? 0) >= 15 }) {
            tips.append(("hourglass", tr("\(waste.name) \(rdRelative(waste.reset))重設，預計會嘥 \(Int((waste.leftover ?? 0).rounded()))%，可以優先用佢。", "\(waste.name) resets \(rdRelative(waste.reset)) with about \(Int((waste.leftover ?? 0).rounded()))% unused. Use it first."), rdAmber))
        }
        let heavy = report.efforts.filter { ["xhigh", "ultra", "max"].contains($0.id) }.reduce(0) { $0 + $1.tokens }
        if heavy / total >= 0.5 {
            tips.append(("brain", tr("xhigh、ultra、max 佔咗 \(rdPercentText(heavy / total)) token。例行工作轉用 high 或 medium，額度會撐耐啲。", "xhigh, ultra and max make up \(rdPercentText(heavy / total)) of tokens. Using high or medium for routine work stretches your quota."), themePrimary))
        }
        if report.totals.requests > 0 {
            let average = report.totals.requestInput / Double(report.totals.requests)
            if average >= 200_000 {
                tips.append(("text.alignleft", tr("平均每次請求帶住 \(rdTokens(average)) 上下文，已經幾大。開新對話或者 compact 可以減少消耗。", "Each request carries \(rdTokens(average)) of context on average. A new conversation or a compact reduces it."), themeSecondary))
            }
        }
        let agentTotal = report.mainTokens + report.subTokens
        if agentTotal > 0, report.subTokens / agentTotal >= 0.4 {
            tips.append(("point.3.connected.trianglepath.dotted", tr("Sub-agent 用咗 \(rdPercentText(report.subTokens / agentTotal)) token。簡單嘅子任務揀細啲嘅模型會慳好多。", "Sub-agents used \(rdPercentText(report.subTokens / agentTotal)) of tokens. A smaller model for simple subtasks saves a lot."), themeSecondary))
        }
        if let top = report.top.first, top.tokens / total >= 0.2 {
            tips.append(("flame", tr("最大嗰個對話佔咗 \(rdPercentText(top.tokens / total))。太長嘅對話每次都要重新帶上下文。", "The largest conversation is \(rdPercentText(top.tokens / total)) of use. Very long conversations resend their context each time."), rdOrange))
        }
        let turns = report.turnsCompleted + report.turnsFailed + report.turnsInterrupted
        if turns >= 20, Double(report.turnsFailed) / Double(turns) >= 0.05 {
            tips.append(("exclamationmark.triangle", tr("\(rdPercentText(Double(report.turnsFailed) / Double(turns))) 回合失敗，呢啲回合嘅額度都算用咗。", "\(rdPercentText(Double(report.turnsFailed) / Double(turns))) of turns failed, and those still count against your quota."), rdDanger))
        }
        return tips
    }

    private func rdTokenTipsCard(_ report: RDTokenReport, _ snapshot: RDAnalyticsSnapshot) -> some View {
        let tips = Array(rdTokenTips(report, snapshot).prefix(4))
        return rdCard {
            VStack(alignment: .leading, spacing: 10) {
                rdAnalysisCardTitle(tr("建議", "Suggestions"))
                if tips.isEmpty {
                    Text(tr("呢段時間嘅用量冇明顯問題。", "Nothing stands out in this period."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                }
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: tip.icon)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(tip.tint)
                            .frame(width: 18, height: 18)
                        Text(tip.text)
                            .font(appFont(size: 12))
                            .foregroundStyle(rdText2)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rdMixCard(_ title: String, rows: [RDTokenShare], total: Double, showMoney: Bool) -> some View {
        rdCard {
            VStack(alignment: .leading, spacing: 9) {
                rdAnalysisCardTitle(title)
                ForEach(rows) { row in
                    let share = total > 0 ? row.tokens / total : 0
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.label)
                                .font(appFont(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if showMoney, row.usd >= 0.01 {
                                Text(rdMoney(row.usd))
                                    .font(appFont(size: 11))
                                    .foregroundStyle(themePrimary)
                            }
                            Text(rdPercentText(share))
                                .font(appFont(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(rdText2)
                                .contentTransition(.numericText())
                        }
                        GeometryReader { bar in
                            Capsule().fill(rdInk.opacity(0.06))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(themePrimary.opacity(0.8))
                                        .frame(width: max(2, bar.size.width * CGFloat(share)))
                                }
                        }
                        .frame(height: 4)
                    }
                    .help("\(row.label): \(rdTokens(row.tokens))")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rdHeatmapCard(_ report: RDTokenReport) -> some View {
        let largest = report.heat.values.max() ?? 1
        let days = [tr("一", "M"), tr("二", "T"), tr("三", "W"), tr("四", "T"), tr("五", "F"), tr("六", "S"), tr("日", "S")]
        let peak = report.heat.max { $0.value < $1.value }?.key
        let peakText = peak.map { slot in
            tr("最忙：星期\(days[slot / 24]) \(slot % 24):00", "Busiest: \(days[slot / 24]) \(slot % 24):00")
        }
        return rdCard {
            VStack(alignment: .leading, spacing: 10) {
                rdAnalysisCardTitle(tr("幾時用得最多", "When you use it most"), subtitle: peakText)
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 3) {
                            Text(days[day])
                                .font(appFont(size: 11))
                                .foregroundStyle(rdText3)
                                .frame(width: 16, alignment: .leading)
                            ForEach(0..<24, id: \.self) { hour in
                                let value = report.heat[day * 24 + hour] ?? 0
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(value > 0 ? themePrimary.opacity(0.18 + 0.82 * sqrt(value / largest)) : rdInk.opacity(0.05))
                                    .frame(height: 14)
                                    .help(value > 0 ? "\(hour):00 · \(rdTokens(value))" : "\(hour):00")
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 19, height: 1)
                        ForEach([0, 6, 12, 18], id: \.self) { hour in
                            Text("\(hour)")
                                .font(appFont(size: 10))
                                .foregroundStyle(rdText3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rdAgentSplitCard(_ report: RDTokenReport) -> some View {
        let total = report.mainTokens + report.subTokens
        let subShare = total > 0 ? report.subTokens / total : 0
        let conversations = report.mainCount + report.subCount
        let turns = report.turnsCompleted + report.turnsFailed + report.turnsInterrupted
        let stats: [(String, String)] = [
            (tr("平均每個對話", "Per conversation"), conversations > 0 ? rdTokens(total / Double(conversations)) : "—"),
            (tr("平均每個回合時間", "Per turn"), turns > 0 ? rdHours(report.workSeconds / Double(turns)) : "—"),
            (tr("中斷咗嘅回合", "Interrupted turns"), "\(report.turnsInterrupted)"),
            (tr("失敗嘅回合", "Failed turns"), "\(report.turnsFailed)")
        ]
        return rdCard {
            VStack(alignment: .leading, spacing: 12) {
                rdAnalysisCardTitle(tr("主對話同 Sub-agent", "Main and sub-agents"))
                GeometryReader { bar in
                    HStack(spacing: 2) {
                        Capsule().fill(themePrimary).frame(width: max(3, (bar.size.width - 2) * CGFloat(1 - subShare)))
                        Capsule().fill(themeSecondary)
                    }
                }
                .frame(height: 10)
                HStack {
                    Text(tr("主對話 \(rdPercentText(1 - subShare))", "Main \(rdPercentText(1 - subShare))")).foregroundStyle(themePrimary)
                    Spacer()
                    Text("Sub-agent \(rdPercentText(subShare))").foregroundStyle(themeSecondary)
                }
                .font(appFont(size: 12, weight: .medium))
                ForEach(stats, id: \.0) { stat in
                    HStack {
                        Text(stat.0).foregroundStyle(rdText3)
                        Spacer()
                        Text(stat.1).monospacedDigit().foregroundStyle(rdText)
                    }
                    .font(appFont(size: 12))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rdTopThreadsCard(_ report: RDTokenReport) -> some View {
        let total = report.totals.total
        return rdCard {
            VStack(alignment: .leading, spacing: 10) {
                rdAnalysisCardTitle(tr("最多 Token 嘅對話", "Largest conversations"))
                ForEach(Array(report.top.enumerated()), id: \.element.id) { index, thread in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(appFont(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(rdText3)
                            .frame(width: 18, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(thread.fact.title ?? thread.fact.folder)
                                .font(appFont(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text("\(thread.fact.folder) · \(thread.fact.model) · \(thread.fact.effort)\(thread.fact.isSubAgent ? " · Sub-agent" : "")")
                                .font(appFont(size: 11))
                                .foregroundStyle(rdText3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(rdTokens(thread.tokens))
                            .font(appFont(size: 13, weight: .semibold))
                            .monospacedDigit()
                        Text(total > 0 ? rdPercentText(thread.tokens / total) : "")
                            .font(appFont(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(rdText3)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rdKPI(_ title: String, value: String, detail: String? = nil, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(appFont(size: 12))
                .foregroundStyle(rdText3)
            Text(value)
                .font(rdNumber(24))
                .foregroundStyle(tint ?? rdText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(appFont(size: 12))
                    .foregroundStyle(rdText2)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(rdCardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rdLine, lineWidth: 1))
    }

    private func rdKPIStrip(_ snapshot: RDAnalyticsSnapshot) -> some View {
        let ready = profiles.filter { rdStatus($0) == .ready }
        let weekly = ready.compactMap { rdWindow($0, id: "7d")?.percent }
        let average = weekly.isEmpty ? nil : weekly.reduce(0, +) / weekly.count
        let nextReset = profiles
            .filter { rdStatus($0) == .waiting || (rdWeekly($0)?.percent ?? 100) <= 20 }
            .compactMap { profile -> (CodexProfile, Date)? in
                guard let reset = rdWeekly(profile)?.reset, let date = resetDate(from: reset) else { return nil }
                return (profile, date)
            }
            .min { $0.1 < $1.1 }
        let activeWeek = snapshot.insights.reduce(0) { $0 + $1.activeSeconds7d }
        let burning = snapshot.insights.filter { insight in
            guard let empty = insight.emptyAt else { return false }
            return empty < (insight.resetAt ?? .distantFuture)
        }
        return HStack(spacing: 12) {
            rdKPI(tr("可用帳戶", "Available"), value: "\(ready.count) / \(profiles.count)")
            rdKPI(tr("每週額度平均剩餘", "Avg weekly left"), value: average.map { "\($0)%" } ?? "—", tint: average.map { rdLevelColor($0) })
            rdKPI(
                tr("下一個重設", "Next reset"),
                value: nextReset.map { rdRelative($0.1) } ?? "—",
                detail: nextReset.map { $0.0.displayName }
            )
            rdKPI(tr("近 7 日使用", "Used in 7 days"), value: rdHours(activeWeek), detail: burning.isEmpty ? nil : tr("\(burning.count) 個帳戶會喺重設前用完", "\(burning.count) may run out before reset"))
        }
    }

    private func rdHours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        if hours >= 10 { return tr("\(Int(hours.rounded())) 小時", "\(Int(hours.rounded())) h") }
        if hours >= 1 { return tr(String(format: "%.1f 小時", hours), String(format: "%.1f h", hours)) }
        let minutes = Int((seconds / 60).rounded())
        return tr("\(minutes) 分鐘", "\(minutes) min")
    }

    private func rdTrendPoints(_ snapshot: RDAnalyticsSnapshot, profileID: String) -> [RDChartPoint] {
        let since = Date().addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        let samples = (snapshot.samplesByProfile[profileID] ?? []).filter { $0.t >= since }.sorted { $0.t < $1.t }
        return samples.compactMap { sample in
            let series: String
            switch sample.w {
            case 300: series = tr("5 小時", "5 hours")
            case 10080: series = tr("1 星期", "1 week")
            case 43200: series = tr("1 個月", "1 month")
            default: return nil
            }
            return RDChartPoint(id: "\(sample.t)|\(sample.w)", date: Date(timeIntervalSince1970: sample.t), left: max(0, 100 - sample.u), series: series)
        }
    }

    private func rdQuotaTrendCard(_ snapshot: RDAnalyticsSnapshot) -> some View {
        let candidates = snapshot.insights.filter { (snapshot.samplesByProfile[$0.id]?.count ?? 0) > 1 }
        let selectedID = rdChartProfileID ?? candidates.first?.id
        let selectedName = candidates.first { $0.id == selectedID }?.name ?? tr("揀帳戶", "Choose")
        let points = selectedID.map { rdTrendPoints(snapshot, profileID: $0) } ?? []
        let seriesNames = [tr("1 星期", "1 week"), tr("1 個月", "1 month"), tr("5 小時", "5 hours")]
        return rdCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(tr("額度變化", "Quota over time")).font(rdDisplay(15, weight: .semibold))
                    Text(tr("近 7 日", "7 days")).font(appFont(size: 12)).foregroundStyle(rdText3)
                    Spacer()
                    Menu {
                        ForEach(candidates) { insight in
                            Button(insight.name) {
                                withAnimation(rdSpring) { rdChartProfileID = insight.id }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedName)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .font(appFont(size: 12, weight: .medium))
                        .foregroundStyle(rdText2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if points.count > 1 {
                    Chart(points) { point in
                        LineMark(
                            x: .value(tr("時間", "Time"), point.date),
                            y: .value(tr("剩餘", "Left"), point.left)
                        )
                        .foregroundStyle(by: .value(tr("額度", "Window"), point.series))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartForegroundStyleScale(domain: seriesNames, range: [themePrimary, themeSecondary, rdText3])
                    .chartYScale(domain: 0...100)
                    .chartYAxis {
                        AxisMarks(values: [0, 50, 100]) { value in
                            AxisGridLine().foregroundStyle(rdInk.opacity(0.06))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text("\(Int(number))%").font(appFont(size: 10)).foregroundStyle(rdText3)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisGridLine().foregroundStyle(rdInk.opacity(0.04))
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                                .foregroundStyle(rdText3)
                        }
                    }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 190)
                    .id(selectedID)
                    .transition(.opacity)
                } else {
                    Text(tr("仲未有足夠紀錄；用多幾次 Codex 就會見到變化。", "Not enough history yet; it fills in as you use Codex."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .frame(maxWidth: .infinity, minHeight: 190)
                }
            }
            .padding(16)
        }
    }

    private func rdDailyUsageCard(_ snapshot: RDAnalyticsSnapshot) -> some View {
        let totals = Dictionary(grouping: snapshot.daily, by: { $0.name }).mapValues { $0.reduce(0) { $0 + $1.hours } }
        let top = totals.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let others = tr("其他", "Others")
        let rows: [RDDailyUsage] = snapshot.daily.map { item in
            top.contains(item.name) ? item : RDDailyUsage(id: item.id, day: item.day, name: others, hours: item.hours)
        }
        let domain = top + (rows.contains { $0.name == others } ? [others] : [])
        let palette: [Color] = [themePrimary, themeSecondary, themeWarm, Color(red: 0.55, green: 0.62, blue: 0.95), Color(red: 0.95, green: 0.55, blue: 0.70), rdText3]
        return rdCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(tr("每日使用時間", "Daily use")).font(rdDisplay(15, weight: .semibold))
                    Text(tr("近 14 日", "14 days")).font(appFont(size: 12)).foregroundStyle(rdText3)
                    Spacer()
                }
                if rows.isEmpty {
                    Text(tr("仲未有使用紀錄。", "No activity recorded yet."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    Chart(rows) { item in
                        BarMark(
                            x: .value(tr("日期", "Day"), item.day, unit: .day),
                            y: .value(tr("小時", "Hours"), item.hours)
                        )
                        .foregroundStyle(by: .value(tr("帳戶", "Account"), item.name))
                        .cornerRadius(3)
                    }
                    .chartForegroundStyleScale(domain: domain, range: Array(palette.prefix(max(domain.count, 1))))
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(rdInk.opacity(0.06))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(tr("\(Int(number))h", "\(Int(number))h")).font(appFont(size: 10)).foregroundStyle(rdText3)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                                .foregroundStyle(rdText3)
                        }
                    }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 190)
                }
            }
            .padding(16)
        }
    }

    private func rdForecast(_ insight: RDAccountInsight) -> (String, Color) {
        guard let left = insight.left else { return ("—", rdText3) }
        if left == 0 { return (tr("已用完", "Used up"), rdAmber) }
        guard let perDay = insight.perDay, perDay >= 0.5, let empty = insight.emptyAt else {
            return (tr("用得好少", "Barely used"), rdText3)
        }
        if let reset = insight.resetAt, empty >= reset {
            return (tr("夠用到重設", "Lasts to reset"), themePrimary)
        }
        return (tr("約 \(rdRelative(empty))用完", "Runs out \(rdRelative(empty))"), rdOrange)
    }

    private func rdPercentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 0.5 ? "0%" : "\(Int(value.rounded()))%"
    }

    private func rdInsightTable(_ snapshot: RDAnalyticsSnapshot) -> some View {
        let rows = snapshot.insights
            .filter { $0.left != nil || $0.activeSeconds7d > 0 }
            .sorted { ($0.activeSeconds7d, $0.used7d ?? 0) > ($1.activeSeconds7d, $1.used7d ?? 0) }
        return rdCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("帳戶分析", "Accounts")).font(rdDisplay(15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                HStack(spacing: 12) {
                    Text(tr("帳戶", "Account")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(tr("剩餘", "Left")).frame(width: 56, alignment: .trailing)
                    Text(tr("24 小時用咗", "Used 24h")).frame(width: 76, alignment: .trailing)
                    Text(tr("7 日用咗", "Used 7d")).frame(width: 66, alignment: .trailing)
                    Text(tr("每日平均", "Per day")).frame(width: 64, alignment: .trailing)
                    Text(tr("預計", "Forecast")).frame(width: 110, alignment: .leading)
                    Text(tr("使用時間", "Active")).frame(width: 70, alignment: .trailing)
                    Text(tr("對話", "Chats")).frame(width: 44, alignment: .trailing)
                }
                .font(appFont(size: 11, weight: .medium))
                .foregroundStyle(rdText3)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                ForEach(rows) { insight in
                    let forecast = rdForecast(insight)
                    HStack(spacing: 12) {
                        Text(insight.name).font(appFont(size: 13, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(insight.left.map { "\($0)%" } ?? "—")
                            .font(rdNumber(14))
                            .foregroundStyle(insight.left.map { $0 <= 20 ? rdOrange : rdText } ?? rdText3)
                            .frame(width: 56, alignment: .trailing)
                        Text(rdPercentText(insight.used24h)).frame(width: 76, alignment: .trailing)
                        Text(rdPercentText(insight.used7d)).frame(width: 66, alignment: .trailing)
                        Text(insight.perDay.map { rdPercentText($0) } ?? "—").frame(width: 64, alignment: .trailing)
                        Text(forecast.0).foregroundStyle(forecast.1).lineLimit(1).frame(width: 110, alignment: .leading)
                        Text(insight.activeSeconds7d > 0 ? rdHours(insight.activeSeconds7d) : "—").frame(width: 70, alignment: .trailing)
                        Text(insight.threads7d > 0 ? "\(insight.threads7d)" : "—").frame(width: 44, alignment: .trailing)
                    }
                    .font(appFont(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(rdText2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(rdLine).frame(height: 1) }
                }
            }
            .padding(.bottom, 6)
        }
    }

    // MARK: Chats & projects page

    private var rdConversationsPage: some View {
        let localProfiles = rdSortedProfiles.filter { !isExternalProvider($0) }
        let modes = Dictionary(uniqueKeysWithValues: localProfiles.map { ($0.id, profileHistoryMode(for: $0)) })
        let sharedCount = modes.values.filter { $0 == .shared }.count
        let target = rdSelectedProfile ?? localProfiles.first
        return VStack(spacing: 0) {
            rdPageHeader(
                tr("對話與項目", "Chats & Projects")
            ) {
                HStack(spacing: 12) {
                    Label("\(sharedCount)", systemImage: "person.2.fill")
                        .help(tr("共享本機對話", "Shared local chats"))
                    Label("\(localProfiles.count - sharedCount)", systemImage: "lock.fill")
                        .help(tr("私人本機對話", "Private local chats"))
                }
                .font(rdNumber(13))
                .foregroundStyle(rdText2)
                .padding(.trailing, 6)
                rdSecondaryButton(tr("立即同步", "Sync Now"), icon: "arrow.triangle.2.circlepath", busy: isSyncing) {
                    syncMemories()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rdCard {
                        ForEach(Array(localProfiles.enumerated()), id: \.element.id) { index, profile in
                            let mode = modes[profile.id] ?? .shared
                            let anchor = isHistoryAnchor(profile)
                            HStack(spacing: 12) {
                                rdBadge(profile, size: 24)
                                Text(profile.displayName).font(appFont(size: 13, weight: .medium)).lineLimit(1)
                                if anchor {
                                    Text(tr("主帳戶", "Main"))
                                        .font(appFont(size: 11, weight: .semibold))
                                        .foregroundStyle(rdText3)
                                }
                                Spacer(minLength: 8)
                                rdIconSegmented(
                                    rdHistoryOptions,
                                    selection: mode == .shared,
                                    key: "history-\(profile.id)",
                                    disabled: anchor
                                ) { shared in
                                    if shared, mode != .shared {
                                        shareHistory(profile)
                                    } else if !shared, mode != .privateOnly {
                                        separateHistory(profile)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(rdLine).frame(height: 1) }
                            }
                        }
                    }

                    Text(tr("共享會合併對話、項目同分類；登入、模型同代理路由仍然各自獨立。私人只隔離本機紀錄。", "Sharing merges chats, projects and folders; sign-in, models and proxy routes stay separate. Private only isolates local records."))
                        .font(appFont(size: 12))
                        .foregroundStyle(rdText3)
                        .fixedSize(horizontal: false, vertical: true)

                    rdCard {
                        VStack(alignment: .leading, spacing: 14) {
                            rdToggleRow(tr("每 10 分鐘自動同步", "Sync every 10 minutes"), subtitle: tr("上次 \(lastAutoSyncLabel)", "Last \(lastAutoSyncLabel)"), isOn: $autoSync)
                            Rectangle().fill(rdLine).frame(height: 1)
                            HStack(spacing: 8) {
                                rdSecondaryButton(tr("共享全部", "Share All"), icon: "person.3") { shareAll() }
                                rdSecondaryButton(tr("整理側欄", "Tidy Sidebar"), icon: "sidebar.left", busy: isCleaningSidebarState) { cleanupSidebarProjects() }
                                rdSecondaryButton(tr("修復大型對話", "Repair Large Chats"), icon: "bandage", busy: isRepairingHistoryPayloads) { repairLargeHistoryPayloads() }
                                Spacer(minLength: 0)
                                if let target {
                                    rdSecondaryButton(tr("匯入…", "Import…"), icon: "square.and.arrow.down") { importConversationPackage(defaultTarget: target) }
                                    rdSecondaryButton(tr("匯出…", "Export…"), icon: "square.and.arrow.up") { exportConversationPackage(from: target) }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Tools page

    private var rdToolsPage: some View {
        return VStack(spacing: 0) {
            rdPageHeader(tr("工作工具", "Tools")) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rdCard {
                        HStack(spacing: 16) {
                            rdCardTitle(tr("防睡眠", "Keep Awake"), subtitle: keepAwakeModeDescription, icon: "cup.and.saucer")
                            if keepAwake.isSwitching {
                                ProgressView().controlSize(.small)
                            }
                            rdSegmented(
                                [(KeepAwakeMode.off, tr("關閉", "Off")), (KeepAwakeMode.display, tr("保持開屏", "Screen on")), (KeepAwakeMode.clamshell, tr("合蓋運作", "Lid closed"))],
                                selection: keepAwake.mode,
                                key: "keep-awake",
                                disabled: keepAwake.isSwitching
                            ) { mode in
                                keepAwake.setMode(mode)
                            }
                        }
                        .padding(16)
                    }

                    rdCard {
                        HStack(spacing: 16) {
                            rdCardTitle(
                                tr("鍵盤清潔", "Keyboard Clean"),
                                subtitle: keyboardClean.isLocked ? tr("鍵盤已鎖定，抹完撳解除。", "Keyboard locked; unlock when done.") : tr("暫停鍵盤輸入，滑鼠照用。", "Pauses the keyboard; the mouse still works."),
                                icon: "keyboard"
                            )
                            if keyboardClean.isLocked {
                                rdSecondaryButton(tr("解除鎖定", "Unlock"), icon: "lock.open", busy: keyboardClean.isSwitching) { keyboardClean.toggle() }
                            } else {
                                rdPrimaryButton(tr("開始清潔", "Start"), icon: "sparkles", busy: keyboardClean.isSwitching) { keyboardClean.toggle() }
                            }
                        }
                        .padding(16)
                        Rectangle().fill(rdLine).frame(height: 1)
                        HStack(spacing: 16) {
                            rdCardTitle(
                                tr("螢幕清潔", "Screen Clean"),
                                subtitle: tr("黑屏 15 秒並暫停觸控，方便抹螢幕。", "Blacks out the screen for 15 seconds and pauses touch."),
                                icon: "display"
                            )
                            rdPrimaryButton(tr("開始清潔", "Start"), icon: "sparkles", busy: screenClean.isActive) { rdConfirmScreenClean() }
                        }
                        .padding(16)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Models & proxy page

    private var rdModelsPage: some View {
        VStack(spacing: 0) {
            rdPageHeader(tr("模型與代理", "Models & Proxy")) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rdCard {
                        ForEach(Array(rdSortedProfiles.enumerated()), id: \.element.id) { index, profile in
                            HStack(spacing: 10) {
                                rdBadge(profile, size: 22)
                                Text(profile.displayName).font(appFont(size: 13)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(isExternalProvider(profile) ? tr("外部 API", "External API") : tr("原生 Codex", "Native Codex"))
                                    .font(appFont(size: 12))
                                    .foregroundStyle(isExternalProvider(profile) ? themeSecondary : rdText3)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(rdLine).frame(height: 1) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Theme cards

    /// A theme as a small window: its sidebar, three accounts with quota bars in the shared level colours,
    /// and its accent button, drawn in the appearance currently in use.
    private func rdThemeCard(_ theme: RDTheme) -> some View {
        let palette = theme.palette(dark: rdIsDark)
        let isOn = rdTheme.id == theme.id
        return Button {
            withAnimation(.easeInOut(duration: 0.35)) { setTheme(theme.id) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Circle().fill(palette.accent).frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(palette.accent.opacity(0.85)).frame(width: 30, height: 6)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(palette.ink.opacity(0.16)).frame(width: 24, height: 5)
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(palette.ink.opacity(0.16)).frame(width: 28, height: 5)
                    }
                    .padding(9)
                    .frame(width: 52, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(palette.sidebar)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array([(92, palette.accent), (47, palette.accent2), (9, palette.warm)].enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(row.1).frame(width: 11, height: 11)
                                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(palette.text.opacity(0.75)).frame(width: 26, height: 4)
                                Spacer(minLength: 4)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(palette.track)
                                    Capsule().fill(palette.level(row.0)).frame(width: max(8, 64 * CGFloat(row.0) / 100))
                                }
                                .frame(width: 64, height: 8)
                            }
                        }
                        HStack {
                            Spacer()
                            Capsule().fill(palette.accent).frame(width: 34, height: 12)
                                .overlay(Capsule().fill(palette.onAccent.opacity(0.85)).frame(width: 14, height: 3))
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(palette.canvas)
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(palette.ink.opacity(0.10), lineWidth: 1))

                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(theme.zh, theme.en))
                            .font(appFont(size: 13, weight: .semibold))
                            .foregroundStyle(rdText)
                        Text(tr(theme.moodZh, theme.moodEn))
                            .font(appFont(size: 11))
                            .foregroundStyle(rdText3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: -4) {
                        ForEach(Array([palette.accent, palette.accent2, palette.warm].enumerated()), id: \.offset) { _, color in
                            Circle().fill(color).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(rdSurface, lineWidth: 1.5))
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(isOn ? rdRaised : rdInk.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(isOn ? themePrimary : rdLine, lineWidth: isOn ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(themePrimary, rdSurface)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .modifier(RDHoverScale())
        }
        .buttonStyle(RDPressStyle())
        .accessibilityLabel(tr(theme.zh, theme.en))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Settings page

    private var rdSettingsPage: some View {
        VStack(spacing: 0) {
            rdPageHeader(tr("設定", "Settings")) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rdCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tr("外觀", "Appearance")).font(rdDisplay(15, weight: .semibold))
                                    Text(tr("每個主題都有深色同淺色兩套", "Every theme has a dark and a light version"))
                                        .font(appFont(size: 12))
                                        .foregroundStyle(rdText3)
                                }
                                Spacer()
                                rdSegmented([("system", tr("跟隨系統", "System")), ("dark", tr("深色", "Dark")), ("light", tr("淺色", "Light"))], selection: rdAppearance, key: "appearance") { mode in
                                    rdAppearance = mode
                                    rdApplyAppearance()
                                }
                            }
                            Rectangle().fill(rdLine).frame(height: 1)
                            Text(tr("主題", "Theme")).font(rdDisplay(15, weight: .semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 260), spacing: 12)], spacing: 12) {
                                ForEach(RDTheme.all) { theme in
                                    rdThemeCard(theme)
                                }
                            }
                            Rectangle().fill(rdLine).frame(height: 1)
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tr("背景圖片", "Background picture")).font(appFont(size: 13, weight: .medium))
                                    Text(rdBackdropPicture == nil
                                         ? tr("揀一張自己嘅圖做背景；白底線稿會自動去走白色。圖片只會留喺呢部 Mac。", "Choose a picture of your own. A drawing on white paper loses its white. The picture stays on this Mac.")
                                         : tr("拉滑桿調濃淡，拉到最左就關閉。", "Drag to adjust; fully left turns it off."))
                                        .font(appFont(size: 12))
                                        .foregroundStyle(rdText3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 16)
                                if rdBackdropPicture != nil {
                                    Slider(value: $rdBackdropStrength, in: 0...0.6)
                                        .controlSize(.small)
                                        .tint(themePrimary)
                                        .frame(width: 150)
                                        .accessibilityLabel(tr("背景圖片濃度", "Background picture strength"))
                                    Text(rdBackdropStrength > 0.005 ? "\(Int((rdBackdropStrength * 100).rounded()))%" : tr("關", "Off"))
                                        .font(appFont(size: 12))
                                        .monospacedDigit()
                                        .foregroundStyle(rdText2)
                                        .frame(width: 34, alignment: .trailing)
                                    rdSecondaryButton(tr("移除", "Remove")) { rdRemoveBackdrop() }
                                }
                                rdSecondaryButton(rdBackdropPicture == nil ? tr("揀圖片…", "Choose…") : tr("更換…", "Change…"), icon: "photo") { rdChooseBackdrop() }
                            }
                            Rectangle().fill(rdLine).frame(height: 1)
                            HStack {
                                Text(tr("語言", "Language")).font(appFont(size: 13, weight: .medium))
                                Spacer()
                                rdSegmented(AppLanguage.allCases.map { ($0, $0.shortTitle) }, selection: selectedLanguage, key: "language") { item in
                                    setLanguage(item)
                                }
                            }
                        }
                        .padding(16)
                    }

                    rdCard {
                        VStack(alignment: .leading, spacing: 14) {
                            rdToggleRow(tr("自動更新額度", "Refresh quota automatically"), isOn: $autoRefresh)
                            Rectangle().fill(rdLine).frame(height: 1)
                            rdToggleRow(
                                tr("提醒", "Reminders"),
                                subtitle: tr("帳戶額度重設、重設券 48 小時內到期時通知你。", "Notifies you when an account's quota resets or a reset ticket expires within 48 hours."),
                                isOn: Binding(get: { rdNotifyEnabled }, set: { rdSetNotifications($0) })
                            )
                        }
                        .padding(16)
                    }

                    rdCard {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Codex Accounts \(rdVersion)").font(appFont(size: 13, weight: .medium))
                                if !updater.statusText.isEmpty {
                                    Text(updater.statusText).font(appFont(size: 12)).foregroundStyle(rdText3).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            if updater.updateAvailable {
                                rdPrimaryButton(tr("安裝更新", "Install Update"), busy: updater.isInstalling) { updater.installAvailableUpdate() }
                            }
                            rdSecondaryButton(tr("檢查更新", "Check for Updates"), busy: updater.isChecking) {
                                updater.checkForUpdates(presentNoUpdate: true, notifyIfAvailable: false)
                            }
                        }
                        .padding(16)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 4)
            }
        }
    }
}

private struct AppReleaseInfo {
    let tagName: String
    let version: String
    let assetURL: URL
    let htmlURL: URL?
}

private final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var availableRelease: AppReleaseInfo?
    @Published private(set) var statusText = ""

    private let owner = "siumiu1968"
    private let repo = "codex-accounts"
    private let assetName = "Codex-Accounts-macOS.zip"
    private let bundleIdentifier = "local.codex.accounts"

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var updateAvailable: Bool {
        guard let availableRelease else { return false }
        return Self.compareVersions(availableRelease.version, currentVersion) == .orderedDescending
    }

    func checkForUpdates(presentNoUpdate: Bool = false, notifyIfAvailable: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        statusText = localized("正在檢查更新...", "Checking for updates...")
        notifyChanged()

        fetchLatestRelease { release, errorMessage in
            guard let release else {
                self.finishCheck(
                    errorMessage: errorMessage ?? self.localized(
                        "GitHub 暫時無法連線。",
                        "GitHub is temporarily unavailable."
                    ),
                    presentNoUpdate: presentNoUpdate
                )
                return
            }

            DispatchQueue.main.async {
                self.isChecking = false
                self.availableRelease = release
                if self.updateAvailable {
                    self.statusText = self.localized("有新版本 \(release.tagName)", "Update available: \(release.tagName)")
                    if notifyIfAvailable {
                        self.presentUpdateAlert(release)
                    }
                } else {
                    self.statusText = self.localized("已是最新版本 \(self.currentVersion)", "Up to date: \(self.currentVersion)")
                    if presentNoUpdate {
                        alertMessage(self.localized("已是最新版本", "You're Up to Date"), self.statusText)
                    }
                }
                self.notifyChanged()
            }
        }
    }

    func installAvailableUpdate() {
        guard !isInstalling else { return }
        guard let release = availableRelease, updateAvailable else {
            checkForUpdates(presentNoUpdate: true, notifyIfAvailable: true)
            return
        }

        isInstalling = true
        statusText = localized("正在下載 \(release.tagName)...", "Downloading \(release.tagName)...")
        notifyChanged()

        var request = URLRequest(url: release.assetURL)
        request.setValue("Codex-Accounts/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            if let error {
                self.finishInstall(errorMessage: error.localizedDescription)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.finishInstall(errorMessage: "GitHub HTTP \(statusCode)")
                return
            }
            guard let temporaryURL else {
                self.finishInstall(errorMessage: self.localized("下載檔案不存在。", "Downloaded file is missing."))
                return
            }

            do {
                let zipURL = try self.persistDownloadedZip(temporaryURL, release: release)
                let validation = self.validateUpdateZip(zipURL, release: release)
                guard validation.ok else {
                    self.finishInstall(errorMessage: validation.message)
                    return
                }
                try self.launchInstallHelper(zipURL: zipURL, release: release)
                DispatchQueue.main.async {
                    self.statusText = self.localized("正在安裝 \(release.tagName)，App 會重新開啟...", "Installing \(release.tagName). The app will reopen...")
                    self.notifyChanged()
                    NSApp.terminate(nil)
                }
            } catch {
                self.finishInstall(errorMessage: error.localizedDescription)
            }
        }.resume()
    }

    private func fetchLatestRelease(completion: @escaping (AppReleaseInfo?, String?) -> Void) {
        fetchLatestReleaseFromAPI { release, apiError in
            if let release {
                completion(release, nil)
                return
            }

            self.fetchLatestReleaseFromWeb { release, webError in
                if let release {
                    completion(release, nil)
                    return
                }
                let details = [apiError, webError]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                completion(
                    nil,
                    details.isEmpty
                        ? self.localized("未能讀取 GitHub Release。", "Could not read the GitHub release.")
                        : details
                )
            }
        }
    }

    private func fetchLatestReleaseFromAPI(completion: @escaping (AppReleaseInfo?, String?) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Codex-Accounts/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(nil, "GitHub API: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, self.localized("GitHub API 冇回應。", "GitHub API returned no response."))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(nil, "GitHub API HTTP \(httpResponse.statusCode)")
                return
            }
            guard let data, let release = self.parseRelease(from: data) else {
                completion(nil, self.localized("GitHub API 回傳資料格式不正確。", "GitHub API returned an invalid release."))
                return
            }
            completion(release, nil)
        }.resume()
    }

    private func fetchLatestReleaseFromWeb(completion: @escaping (AppReleaseInfo?, String?) -> Void) {
        let url = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Codex-Accounts/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(nil, "GitHub Web: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, self.localized("GitHub 網頁冇回應。", "GitHub Web returned no response."))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(nil, "GitHub Web HTTP \(httpResponse.statusCode)")
                return
            }
            guard let htmlURL = httpResponse.url,
                  let tagName = self.releaseTag(from: htmlURL)
            else {
                completion(nil, self.localized("GitHub 網頁冇提供最新版本標籤。", "GitHub Web did not provide a release tag."))
                return
            }

            let assetURL = URL(string: "https://github.com")!
                .appendingPathComponent(self.owner)
                .appendingPathComponent(self.repo)
                .appendingPathComponent("releases")
                .appendingPathComponent("download")
                .appendingPathComponent(tagName)
                .appendingPathComponent(self.assetName)
            completion(
                AppReleaseInfo(
                    tagName: tagName,
                    version: Self.normalizedVersion(tagName),
                    assetURL: assetURL,
                    htmlURL: htmlURL
                ),
                nil
            )
        }.resume()
    }

    private func releaseTag(from url: URL) -> String? {
        let components = url.pathComponents
        guard let tagIndex = components.lastIndex(of: "tag"),
              components.indices.contains(tagIndex + 1)
        else {
            return nil
        }
        let tagName = components[tagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return tagName.isEmpty ? nil : tagName
    }

    private func parseRelease(from data: Data) -> AppReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else {
            return nil
        }
        let version = Self.normalizedVersion(tagName)
        let asset = assets.first { ($0["name"] as? String) == assetName }
        guard let assetURLText = asset?["browser_download_url"] as? String,
              let assetURL = URL(string: assetURLText)
        else {
            return nil
        }
        let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        return AppReleaseInfo(tagName: tagName, version: version, assetURL: assetURL, htmlURL: htmlURL)
    }

    private func finishCheck(errorMessage: String, presentNoUpdate: Bool) {
        DispatchQueue.main.async {
            self.isChecking = false
            self.statusText = self.localized("檢查更新失敗：\(errorMessage)", "Update check failed: \(errorMessage)")
            if presentNoUpdate {
                alertMessage(self.localized("檢查更新失敗", "Update Check Failed"), errorMessage)
            }
            self.notifyChanged()
        }
    }

    private func finishInstall(errorMessage: String) {
        DispatchQueue.main.async {
            self.isInstalling = false
            self.statusText = self.localized("更新失敗：\(errorMessage)", "Update failed: \(errorMessage)")
            alertMessage(self.localized("更新失敗", "Update Failed"), errorMessage)
            self.notifyChanged()
        }
    }

    private func persistDownloadedZip(_ temporaryURL: URL, release: AppReleaseInfo) throws -> URL {
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let updateDirectory = cacheDirectory.appendingPathComponent("Codex Accounts/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        let zipURL = updateDirectory.appendingPathComponent("Codex-Accounts-\(release.version).zip")
        try? FileManager.default.removeItem(at: zipURL)
        try FileManager.default.moveItem(at: temporaryURL, to: zipURL)
        return zipURL
    }

    private func validateUpdateZip(_ zipURL: URL, release: AppReleaseInfo) -> (ok: Bool, message: String) {
        let validationDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-accounts-validate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: validationDirectory) }

        let extract = runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipURL.path, validationDirectory.path],
            timeout: 60
        )
        guard extract.0 == 0 else {
            return (false, extract.1.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let appURL = findExtractedApp(in: validationDirectory) else {
            return (false, localized("更新檔入面搵唔到 Codex Accounts.app。", "The update archive does not contain Codex Accounts.app."))
        }
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              let foundBundleID = info["CFBundleIdentifier"] as? String,
              foundBundleID == bundleIdentifier,
              let foundVersion = info["CFBundleShortVersionString"] as? String
        else {
            return (false, localized("更新檔驗證失敗。", "The update archive failed validation."))
        }
        guard Self.compareVersions(foundVersion, currentVersion) == .orderedDescending,
              Self.compareVersions(foundVersion, release.version) != .orderedAscending
        else {
            return (false, localized("更新檔版本不正確。", "The update archive version is not valid."))
        }
        return (true, "")
    }

    private func findExtractedApp(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("Codex Accounts.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "Codex Accounts.app" {
                return url
            }
        }
        return nil
    }

    private func launchInstallHelper(zipURL: URL, release: AppReleaseInfo) throws {
        let helperDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-accounts-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        let helperURL = helperDirectory.appendingPathComponent("install-update.zsh")
        let targetPath = Bundle.main.bundleURL.path.hasSuffix(".app")
            ? Bundle.main.bundleURL.path
            : "/Applications/Codex Accounts.app"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/usr/bin/env zsh
        set -euo pipefail
        ZIP_PATH="$1"
        TARGET_PATH="$2"
        APP_PID="$3"
        LOG_DIR="$HOME/Library/Logs/Codex Accounts"
        /bin/mkdir -p "$LOG_DIR"
        LOG_FILE="$LOG_DIR/update-install.log"
        exec >> "$LOG_FILE" 2>&1
        echo "---- $(/bin/date '+%Y-%m-%d %H:%M:%S') installing update ----"
        echo "zip=$ZIP_PATH"
        echo "target=$TARGET_PATH"
        echo "waiting for pid=$APP_PID"
        WORK_DIR="$(/usr/bin/mktemp -d /tmp/codex-accounts-install.XXXXXX)"
        cleanup() { /bin/rm -rf "$WORK_DIR"; }
        trap cleanup EXIT
        while /bin/kill -0 "$APP_PID" 2>/dev/null; do
          /bin/sleep 0.2
        done
        /usr/bin/ditto -x -k "$ZIP_PATH" "$WORK_DIR"
        SOURCE_PATH="$WORK_DIR/Codex Accounts.app"
        if [[ ! -d "$SOURCE_PATH" ]]; then
          SOURCE_PATH="$(/usr/bin/find "$WORK_DIR" -maxdepth 3 -name 'Codex Accounts.app' -type d | /usr/bin/head -n 1)"
        fi
        if [[ -z "$SOURCE_PATH" || ! -d "$SOURCE_PATH" ]]; then
          echo "Codex Accounts.app not found in update archive"
          exit 12
        fi
        SOURCE_VERSION="$(/usr/bin/defaults read "$SOURCE_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
        echo "source=$SOURCE_PATH"
        echo "source_version=$SOURCE_VERSION"
        BACKUP_PATH="${TARGET_PATH}.previous-update"
        /bin/rm -rf "$BACKUP_PATH"
        if [[ -d "$TARGET_PATH" ]]; then
          /bin/mv "$TARGET_PATH" "$BACKUP_PATH"
        fi
        if ! /usr/bin/ditto "$SOURCE_PATH" "$TARGET_PATH"; then
          echo "ditto failed; restoring backup"
          /bin/rm -rf "$TARGET_PATH"
          if [[ -d "$BACKUP_PATH" ]]; then
            /bin/mv "$BACKUP_PATH" "$TARGET_PATH"
          fi
          exit 13
        fi
        /bin/rm -rf "$BACKUP_PATH"
        INSTALLED_VERSION="$(/usr/bin/defaults read "$TARGET_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
        echo "installed_version=$INSTALLED_VERSION"
        /usr/bin/open "$TARGET_PATH"
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helperURL.path, zipURL.path, targetPath, "\(pid)"]
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }
        try process.run()
    }

    private func presentUpdateAlert(_ release: AppReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = localized("有新版本 \(release.tagName)", "Update \(release.tagName) is available")
        alert.informativeText = localized(
            "目前版本：\(currentVersion)\n最新版本：\(release.version)\n\n可以直接下載並自動更新，唔需要打開 GitHub 網頁。",
            "Current version: \(currentVersion)\nLatest version: \(release.version)\n\nCodex Accounts can download and install it directly without opening GitHub."
        )
        alert.addButton(withTitle: localized("下載並更新", "Download and Install"))
        alert.addButton(withTitle: localized("稍後", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            installAvailableUpdate()
        }
    }

    private func localized(_ zh: String, _ en: String) -> String {
        localizedText(zh, en, language: UserDefaults.standard.string(forKey: "language"))
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .updateStateChanged, object: nil)
    }

    private static func normalizedVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalizedVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let right = normalizedVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return .orderedSame
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var syncProcess: Process?
    private var window: NSWindow!
    private var cachedAccounts: [Account] = []
    private var accountsCacheRefreshInFlight = false
    private var terminationCleanupInFlight = false
    private var quotaPollingActivity: NSObjectProtocol?

    private var scriptPath: String {
        if let bundled = Bundle.main.path(forResource: "codex_multi_account", ofType: "zsh") {
            return bundled
        }
        if let override = ProcessInfo.processInfo.environment["CODEX_ACCOUNTS_SCRIPT"], !override.isEmpty {
            return override
        }
        let cwdScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/codex_multi_account.zsh")
            .path
        if FileManager.default.fileExists(atPath: cwdScript) {
            return cwdScript
        }
        return "/Applications/Codex Accounts.app/Contents/Resources/codex_multi_account.zsh"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // App Nap would stretch the one-minute quota refresh once no window is showing. Idle sleep is still allowed.
        quotaPollingActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Refreshing account quota every minute")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Codex Accounts"
        statusItem.button?.toolTip = "Codex Accounts"
        buildMainMenu()
        buildWindow()
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: Notification.Name("CodexAccountsLanguageChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keepAwakeChanged), name: .keepAwakeStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardCleanChanged), name: .keyboardCleanStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateStateChanged), name: .updateStateChanged, object: nil)
        showAccountsWindow()
        refreshAccountsCacheAsync()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showAccountsWindow()
        }
        return true
    }

    private func appTr(_ zh: String, _ en: String) -> String {
        localizedText(zh, en, language: UserDefaults.standard.string(forKey: "language"))
    }

    @objc private func languageChanged() {
        window?.title = appTr("Codex 帳戶", "Codex Accounts")
        buildMainMenu()
        rebuildMenu()
    }

    @objc private func keepAwakeChanged() {
        buildMainMenu()
        rebuildMenu()
    }

    @objc private func keyboardCleanChanged() {
        rebuildMenu()
    }

    @objc private func updateStateChanged() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        statusItem.button?.title = appTr("Codex 帳戶", "Codex Accounts")
        statusItem.button?.toolTip = appTr("Codex 帳戶", "Codex Accounts")

        let accounts = cachedAccounts
        if accounts.isEmpty {
            menu.addItem(disabledMenuItem(accountsCacheRefreshInFlight ? appTr("正在載入帳戶...", "Loading accounts...") : appTr("冇帳戶", "No accounts found")))
        } else {
            for account in accounts {
                let item = NSMenuItem(title: appTr("打開 \(account.displayName)", "Open \(account.displayName)"), action: #selector(openAccountFromMenu(_:)), keyEquivalent: account.keyEquivalent)
                item.target = self
                item.representedObject = ["name": account.name, "displayName": account.displayName] as NSDictionary
                item.toolTip = account.home
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(keepAwakeModeMenuItem())
        let cleanTitle = KeyboardCleanController.shared.isLocked
            ? appTr("關閉清潔模式", "Turn Clean Mode Off")
            : appTr("開啟清潔模式", "Turn Clean Mode On")
        let cleanItem = menuItem(cleanTitle, action: #selector(toggleKeyboardClean), key: "")
        cleanItem.state = KeyboardCleanController.shared.isLocked ? .on : .off
        menu.addItem(cleanItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("新增帳戶...", "New Account..."), action: #selector(newAccount), key: "n"))
        menu.addItem(menuItem(appTr("帳戶列表", "List Accounts"), action: #selector(listAccounts), key: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("同步對話同記憶一次", "Sync History and Memory Once"), action: #selector(syncOnce), key: "s"))
        menu.addItem(menuItem(appTr("關閉全部 Codex 視窗", "Close All Codex Windows"), action: #selector(closeAllWindows), key: "w"))

        if syncProcess == nil {
            menu.addItem(menuItem(appTr("開始自動同步對話同記憶", "Start History and Memory Sync Loop"), action: #selector(startSyncLoop), key: ""))
        } else {
            menu.addItem(menuItem(appTr("停止自動同步對話同記憶", "Stop History and Memory Sync Loop"), action: #selector(stopSyncLoop), key: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("共享全部對話紀錄", "Share All History"), action: #selector(linkAllHistory), key: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("打開 Profile 資料夾", "Open Profiles Folder"), action: #selector(openProfilesFolder), key: "o"))
        menu.addItem(menuItem(appTr("打開 Script 資料夾", "Open Script Folder"), action: #selector(openScriptFolder), key: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("檢查更新...", "Check for Updates..."), action: #selector(checkForUpdates), key: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("結束", "Quit"), action: #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = appTr("Codex 帳戶", "Codex Accounts")
        let appMenu = NSMenu(title: appTr("Codex 帳戶", "Codex Accounts"))
        appMenu.addItem(menuItem(appTr("關於 Codex 帳戶", "About Codex Accounts"), action: #selector(showAbout), key: ""))
        appMenu.addItem(menuItem(appTr("檢查更新...", "Check for Updates..."), action: #selector(checkForUpdates), key: "u"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(keepAwakeModeMenuItem())
        appMenu.addItem(menuItem(appTr("切換清潔模式", "Toggle Clean Mode"), action: #selector(toggleKeyboardClean), key: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem(appTr("結束 Codex 帳戶", "Quit Codex Accounts"), action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editRootMenuItem = NSMenuItem()
        editRootMenuItem.title = appTr("編輯", "Edit")
        let editMenu = NSMenu(title: appTr("編輯", "Edit"))
        editMenu.addItem(makeEditMenuItem(appTr("還原", "Undo"), action: Selector(("undo:")), key: "z"))
        editMenu.addItem(makeEditMenuItem(appTr("重做", "Redo"), action: Selector(("redo:")), key: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(makeEditMenuItem(appTr("剪下", "Cut"), action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(makeEditMenuItem(appTr("複製", "Copy"), action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(makeEditMenuItem(appTr("貼上", "Paste"), action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(makeEditMenuItem(appTr("全選", "Select All"), action: #selector(NSText.selectAll(_:)), key: "a"))
        editRootMenuItem.submenu = editMenu
        mainMenu.addItem(editRootMenuItem)

        let accountMenuItem = NSMenuItem()
        accountMenuItem.title = appTr("帳戶", "Accounts")
        let accountMenu = NSMenu(title: appTr("帳戶", "Accounts"))
        accountMenuItem.submenu = accountMenu
        mainMenu.addItem(accountMenuItem)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.title = appTr("視窗", "Window")
        let windowMenu = NSMenu(title: appTr("視窗", "Window"))
        windowMenu.addItem(menuItem(appTr("顯示帳戶", "Show Accounts"), action: #selector(showAccountsWindow), key: "0"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        refreshMainAccountsMenu()
    }

    private func refreshMainAccountsMenu() {
        guard let accountMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == appTr("帳戶", "Accounts") })?.submenu else { return }
        accountMenu.removeAllItems()

        for account in cachedAccounts {
            let item = NSMenuItem(title: appTr("打開 \(account.displayName)", "Open \(account.displayName)"), action: #selector(openAccountFromMenu(_:)), keyEquivalent: account.keyEquivalent)
            item.target = self
            item.representedObject = ["name": account.name, "displayName": account.displayName] as NSDictionary
            accountMenu.addItem(item)
        }

        accountMenu.addItem(NSMenuItem.separator())
        accountMenu.addItem(menuItem(appTr("新增帳戶...", "New Account..."), action: #selector(newAccount), key: "n"))
        accountMenu.addItem(menuItem(appTr("同步對話同記憶一次", "Sync History and Memory Once"), action: #selector(syncOnce), key: "s"))
        accountMenu.addItem(menuItem(appTr("關閉全部 Codex 視窗", "Close All Codex Windows"), action: #selector(closeAllWindows), key: "w"))
        accountMenu.addItem(keepAwakeModeMenuItem())
        accountMenu.addItem(menuItem(appTr("切換清潔模式", "Toggle Clean Mode"), action: #selector(toggleKeyboardClean), key: ""))
        accountMenu.addItem(NSMenuItem.separator())
        accountMenu.addItem(menuItem(appTr("共享全部對話紀錄", "Share All History"), action: #selector(linkAllHistory), key: ""))
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appTr("Codex 帳戶", "Codex Accounts")
        window.center()
        window.minSize = NSSize(width: 1000, height: 640)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AccountsRootView(scriptPath: scriptPath))
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func keepAwakeModeMenuItem() -> NSMenuItem {
        let controller = KeepAwakeController.shared
        let currentTitle: String
        switch controller.mode {
        case .off: currentTitle = appTr("關閉", "Off")
        case .display: currentTitle = appTr("開屏", "Screen")
        case .clamshell: currentTitle = appTr("合蓋", "Lid")
        }

        let root = NSMenuItem(
            title: appTr("防睡眠模式：\(currentTitle)", "Keep Awake: \(currentTitle)"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: appTr("防睡眠模式", "Keep Awake Mode"))
        for mode in KeepAwakeMode.allCases {
            let title: String
            switch mode {
            case .off: title = appTr("關閉 — 跟隨 macOS", "Off — Follow macOS")
            case .display: title = appTr("開屏 — 防止熄屏及睡眠", "Screen — Prevent display and system sleep")
            case .clamshell: title = appTr("合蓋 — 繼續運行", "Lid — Keep running when closed")
            }
            let item = NSMenuItem(title: title, action: #selector(setKeepAwakeMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = controller.mode == mode ? .on : .off
            item.isEnabled = !controller.isSwitching
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    private func makeEditMenuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        if key == "Z" {
            item.keyEquivalent = "z"
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private struct Account {
        let name: String
        let displayName: String
        let home: String
        let keyEquivalent: String
    }

    private func loadAccounts() -> [Account] {
        cachedAccounts
    }

    private func loadAccountsFromScript() -> [Account] {
        let result = runScript(["list-accounts"], wait: true, timeout: 8)
        guard result.0 == 0 else { return [] }
        let displayNames = UserDefaults.standard.dictionary(forKey: "profileDisplayNames") as? [String: String] ?? [:]

        return result.1
            .split(separator: "\n")
            .enumerated()
            .compactMap { index, line in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count >= 2 else { return nil }
                let name = parts[0]
                let fallbackDisplay: String
                if name == "account1" {
                    fallbackDisplay = "Account 1"
                } else if name == "account2" {
                    fallbackDisplay = "Account 2"
                } else {
                    fallbackDisplay = name
                }
                let displayName = displayNames[name] ?? fallbackDisplay
                let key = index < 9 ? String(index + 1) : ""
                return Account(name: name, displayName: displayName, home: parts[1], keyEquivalent: key)
            }
    }

    private func refreshAccountsCacheAsync() {
        guard !accountsCacheRefreshInFlight else { return }
        accountsCacheRefreshInFlight = true
        rebuildMenu()
        refreshMainAccountsMenu()

        DispatchQueue.global(qos: .utility).async {
            let accounts = self.loadAccountsFromScript()
            DispatchQueue.main.async {
                self.cachedAccounts = accounts
                self.accountsCacheRefreshInFlight = false
                self.rebuildMenu()
                self.refreshMainAccountsMenu()
            }
        }
    }

    @discardableResult
    private func runScript(_ arguments: [String], wait: Bool = false, timeout: TimeInterval = 90) -> (Int32, String) {
        let processArguments = [scriptPath] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SHARED_SESSIONS"] = "1"
        let command = arguments.first ?? ""
        if ["launch-account", "sync-once", "sync-history-once", "sync-account", "sync-account-for-launch", "sync-loop", "sync-history-loop"].contains(command) {
            environment["CODEX_SYNC_THREAD_HISTORY"] = "1"
        } else if !["link-history", "link-all-history", "link-account2-history"].contains(command) {
            environment["CODEX_SYNC_THREAD_HISTORY"] = "0"
        }
        if command == "launch-account" {
            environment["CODEX_PRELAUNCH_SYNC"] = "1"
        }
        if wait {
            return runProcess(executable: "/bin/zsh", arguments: processArguments, environment: environment, timeout: timeout)
        }
        return runDetachedProcess(executable: "/bin/zsh", arguments: processArguments, environment: environment)
    }

    private func showMessage(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: appTr("好", "OK"))
        alert.runModal()
    }

    private func openAccount(_ name: String, displayName: String? = nil) {
        let routed = quotaPoolRouteForMenu(requestedName: name)
        var arguments = ["launch-account-nosync", routed.name]
        if !routed.displayName.isEmpty {
            arguments.append(routed.displayName)
        }
        runScript(arguments)
    }

    private func quotaPoolRouteForMenu(requestedName: String) -> Account {
        let accounts = loadAccounts()
        let requested = accounts.first { $0.name == requestedName }
            ?? Account(name: requestedName, displayName: requestedName, home: "", keyEquivalent: "")
        guard autoQuotaPoolMenuEnabled() else { return requested }

        let statusResult = runScript(["list-accounts-status"], wait: true)
        guard statusResult.0 == 0 else { return requested }

        let statusLines = statusResult.1.split(separator: "\n")
        let requestedIsExternal = statusLines.contains { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.count >= 5 && parts[0] == requestedName && parts[4] == "external"
        }
        if requestedIsExternal {
            return requested
        }

        let displayByName = Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, $0.displayName) })
        let candidates = statusLines
            .compactMap { line -> (name: String, displayName: String, score: Int)? in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count >= 5 else { return nil }
                let name = parts[0]
                let status = parts[1]
                let quota = parts[4]
                let score = quotaPoolMenuScore(status: status, quota: quota)
                guard score > 0 else { return nil }
                return (name, displayByName[name] ?? name, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        guard let best = candidates.first else { return requested }
        return Account(name: best.name, displayName: best.displayName, home: requested.home, keyEquivalent: requested.keyEquivalent)
    }

    private func autoQuotaPoolMenuEnabled() -> Bool {
        false
    }

    private func quotaPoolMenuScore(status: String, quota: String) -> Int {
        guard status == "signed_in_local" else { return -1 }
        if quota == "unlimited" { return 10_000 }
        guard quota != "unknown" else { return -1 }

        var values: [Int] = []
        var digits = ""
        for character in quota {
            if character.isNumber {
                digits.append(character)
            } else if character == "%" {
                if let value = Int(digits) {
                    values.append(value)
                }
                digits = ""
            } else {
                digits = ""
            }
        }
        guard let minimum = values.min(), minimum > 0 else { return 0 }
        return quota.localizedCaseInsensitiveContains("5h") ? 1_000 + minimum : minimum
    }

    @objc private func openAccountFromMenu(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? NSDictionary,
           let name = payload["name"] as? String {
            openAccount(name, displayName: payload["displayName"] as? String)
        } else if let name = sender.representedObject as? String {
            openAccount(name)
        }
    }

    @objc private func newAccount() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = appTr("新增帳戶", "New Codex Account")
        alert.informativeText = appTr("輸入 profile 名；會建立全新空白 profile，唔會自動同步舊對話。", "Enter a profile name. This creates a new blank profile without automatically syncing old conversations.")
        alert.addButton(withTitle: appTr("建立並打開", "Create and Open"))
        alert.addButton(withTitle: appTr("取消", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "account3"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let rawName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return }

        let initResult = runScript(["init-account", rawName], wait: true)
        if initResult.0 != 0 {
            showMessage(appTr("建立帳戶失敗", "Could Not Create Account"), initResult.1)
            return
        }
        rebuildMenu()
        refreshMainAccountsMenu()
        runScript(["launch-account-nosync", rawName, rawName])
    }

    @objc private func refreshWindow() {
        refreshAccountsCacheAsync()
    }

    @objc private func showAccountsWindow() {
        if window == nil {
            buildWindow()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        showMessage(appTr("Codex 帳戶", "Codex Accounts"), appTr("多帳戶登入，共用本機紀錄。", "Separate logins. Shared local history."))
    }

    @objc private func checkForUpdates() {
        UpdateController.shared.checkForUpdates(presentNoUpdate: true, notifyIfAvailable: true)
    }

    @objc private func listAccounts() {
        let result = runScript(["list-accounts"], wait: true)
        showMessage(appTr("Codex 帳戶", "Codex Accounts"), result.1.isEmpty ? appTr("冇帳戶輸出。", "No account output.") : result.1)
    }

    @objc private func syncOnce() {
        let result = runScript(["sync-once"], wait: true)
        showMessage(result.0 == 0 ? appTr("同步完成", "Sync Complete") : appTr("同步失敗", "Sync Failed"), result.1)
    }

    @objc private func closeAllWindows() {
        let result = runScript(["close-all-accounts"], wait: true)
        showMessage(
            result.0 == 0 ? appTr("已關閉全部 Codex 視窗", "Closed All Codex Windows") : appTr("關閉全部失敗", "Close All Failed"),
            result.1
        )
    }

    @objc private func startSyncLoop() {
        guard syncProcess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath, "sync-history-loop"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SYNC_THREAD_HISTORY"] = "1"
        process.environment = environment
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }

        do {
            try process.run()
            syncProcess = process
            rebuildMenu()
        } catch {
            showMessage(appTr("無法開始同步", "Could Not Start Sync"), error.localizedDescription)
        }
    }

    @objc private func stopSyncLoop() {
        syncProcess?.terminate()
        syncProcess = nil
        rebuildMenu()
    }

    @objc private func setKeepAwakeMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let mode = KeepAwakeMode(rawValue: rawValue)
        else { return }
        KeepAwakeController.shared.setMode(mode)
    }

    @objc private func toggleKeyboardClean() {
        KeyboardCleanController.shared.toggle()
    }

    @objc private func linkAllHistory() {
        let result = runScript(["link-all-history"], wait: true)
        showMessage(result.0 == 0 ? appTr("已共享對話紀錄", "History Sharing Enabled") : appTr("共享失敗", "History Sharing Failed"), result.1)
        refreshWindow()
    }

    @objc private func openProfilesFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-accounts"))
    }

    @objc private func openScriptFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath).deletingLastPathComponent())
    }

    @objc private func quit() {
        syncProcess?.terminate()
        KeyboardCleanController.shared.stop()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = KeepAwakeController.shared
        guard !terminationCleanupInFlight else { return .terminateLater }
        guard controller.isSwitching || controller.ownsSystemSleepOverride else {
            controller.stopKeepAwakeForTermination()
            return .terminateNow
        }

        terminationCleanupInFlight = true
        finishKeepAwakeTerminationCleanup(sender)
        return .terminateLater
    }

    private func finishKeepAwakeTerminationCleanup(_ sender: NSApplication) {
        let controller = KeepAwakeController.shared
        guard !controller.isSwitching else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.finishKeepAwakeTerminationCleanup(sender)
            }
            return
        }

        guard controller.ownsSystemSleepOverride else {
            controller.stopKeepAwakeForTermination()
            terminationCleanupInFlight = false
            sender.reply(toApplicationShouldTerminate: true)
            return
        }

        // Only restore pmset when Codex Accounts owns the override. An external
        // SleepDisabled setting must survive this app quitting.
        controller.setMode(.off) { success in
            if success {
                controller.stopKeepAwakeForTermination()
            }
            self.terminationCleanupInFlight = false
            sender.reply(toApplicationShouldTerminate: success)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncProcess?.terminate()
        KeyboardCleanController.shared.stop()
        KeepAwakeController.shared.stopKeepAwakeForTermination()
    }
}

#if UI_PREVIEW
// Test builds only: print token totals, to compare against an independent count. Numbers only.
if CommandLine.arguments.contains("--dump-token-report") {
    let root = NSHomeDirectory() + "/.codex-accounts"
    var homes: [(id: String, name: String, home: String)] = [(id: "account1", name: "Account 1", home: NSHomeDirectory() + "/.codex")]
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") && name != "opencodex-lab" {
        homes.append((id: name, name: name, home: root + "/" + name))
    }
    let started = Date()
    let data = RDTokenEngine.scan(profiles: homes)
    print("scan seconds:", Int(Date().timeIntervalSince(started)), "rows:", data.rows.count, "threads:", data.threads.count, "turns:", data.turns.count)
    for days in [7, 30, 0] {
        let r = RDTokenEngine.report(data, scope: nil, days: days)
        print("days \(days): total \(String(format: "%.2fB", r.totals.total / 1e9)) detailed \(String(format: "%.2fB", r.totals.detailed / 1e9)) usd \(Int(r.totals.usd)) main \(r.mainCount) sub \(r.subCount) prev \(String(format: "%.2fB", (r.previousTotal ?? 0) / 1e9)) work h \(Int(r.workSeconds / 3600)) turns \(r.turnsCompleted)/\(r.turnsFailed)/\(r.turnsInterrupted)")
        for a in r.accounts.prefix(6) { print("   \(a.id.isEmpty ? "(unmatched)" : a.id): \(String(format: "%.2fB", a.totals.total / 1e9)) usd \(Int(a.totals.usd)) per1% \(String(format: "%.2fB", (a.pool?.tokensPerPercent ?? 0) / 1e9)) full \(Int(a.pool?.usdPerFullWindow ?? 0))") }
    }
    let r30 = RDTokenEngine.report(data, scope: nil, days: 30)
    print("models:", r30.models.map { "\($0.id)=\(String(format: "%.1fB", $0.tokens / 1e9))" }.joined(separator: " "))
    print("efforts:", r30.efforts.map { "\($0.id)=\(String(format: "%.1fB", $0.tokens / 1e9))" }.joined(separator: " "))
    exit(0)
}

// Test builds only: rehearse the screen clean timing with invisible windows. "hang" freezes the main thread
// to prove the last-resort exit; "esc" ends early.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--test-screen-clean") {
    let mode = flagIndex + 1 < CommandLine.arguments.count ? CommandLine.arguments[flagIndex + 1] : "normal"
    let testApp = NSApplication.shared
    testApp.setActivationPolicy(.prohibited)
    let controller = ScreenCleanController.shared
    var finishCount = 0
    controller.start(seconds: 1) { finishCount += 1 }
    controller.start(seconds: 30) { finishCount += 100 }   // A second start while running must be ignored.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        print("during: active=\(controller.isActive) windows=\(controller.windowCount) screens=\(NSScreen.screens.count)")
        if mode == "hang" {
            print("hanging main thread"); fflush(stdout)
            sleep(30)
            print("FAIL: watchdog did not end the process"); exit(1)
        }
        if mode == "esc" { controller.finish() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
        let passed = !controller.isActive && controller.windowCount == 0 && finishCount == 1
        print("after: active=\(controller.isActive) windows=\(controller.windowCount) finishCount=\(finishCount)")
        print(passed ? "PASS" : "FAIL"); exit(passed ? 0 : 1)
    }
    testApp.run()
}

// Test builds only (swiftc -D UI_PREVIEW): render the main window off-screen to a PNG and exit.
// Usage: CodexAccountsPreview --render-preview out.png [width height delaySeconds]
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview"), flagIndex + 1 < CommandLine.arguments.count {
    let arguments = CommandLine.arguments
    let outputPath = arguments[flagIndex + 1]
    let width = flagIndex + 2 < arguments.count ? Double(arguments[flagIndex + 2]) ?? 1280 : 1280
    let height = flagIndex + 3 < arguments.count ? Double(arguments[flagIndex + 3]) ?? 800 : 800
    let delay = flagIndex + 4 < arguments.count ? Double(arguments[flagIndex + 4]) ?? 8 : 8
    let previewApp = NSApplication.shared
    previewApp.setActivationPolicy(.prohibited)
    let scriptPath = Bundle.main.path(forResource: "codex_multi_account", ofType: "zsh") ?? "/Applications/Codex Accounts.app/Contents/Resources/codex_multi_account.zsh"
    let hosting = NSHostingView(rootView: AccountsRootView(scriptPath: scriptPath))
    // PREVIEW_ONSCREEN=1 puts the (fully transparent) window on screen, so lazy lists update as they do in
    // the real app; off screen, rows can keep showing what they first drew.
    let onScreen = ProcessInfo.processInfo.environment["PREVIEW_ONSCREEN"] == "1"
    // Reports itself as key so synthetic mouse events reach SwiftUI gestures without activating the app.
    final class PreviewWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }
    let previewWindow = PreviewWindow(contentRect: NSRect(x: onScreen ? 0 : -4000, y: onScreen ? 0 : -4000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    previewWindow.contentView = hosting
    if onScreen {
        previewWindow.alphaValue = 0
        previewWindow.ignoresMouseEvents = true
        previewWindow.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }
    previewWindow.orderFrontRegardless()
    func capture() {
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: outputPath))
            }
        }
        exit(0)
    }
    // PREVIEW_TAB=<n> moves keyboard focus n times first, to check the keyboard-only focus ring.
    if let tabs = ProcessInfo.processInfo.environment["PREVIEW_TAB"].flatMap(Int.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, delay - 2)) {
            RDKeyboardFocus.shared.active = ProcessInfo.processInfo.environment["PREVIEW_TAB_MOUSE"] != "1"
            for _ in 0..<tabs { previewWindow.selectNextKeyView(nil) }
            print("first responder:", previewWindow.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
        }
    }
    // PREVIEW_SCROLL=<points> scrolls the tallest list first, to check what happens under pinned headers.
    func tallestScroller(in view: NSView) -> NSScrollView? {
        let found = view.subviews.compactMap { tallestScroller(in: $0) } + [view as? NSScrollView].compactMap { $0 }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    // PREVIEW_DRAG_SIDEBAR=<points> drags the sidebar's edge with mouse events, or "reset" double-clicks it.
    // The target comes from hit testing, as it does for a real click, so a view covering the handle fails here.
    func driveSidebar(_ command: String, then finish: @escaping () -> Void) {
        let start = CGFloat(UserDefaults.standard.object(forKey: "rdSidebarWidth") as? Double ?? 220) + 0.5
        let y = height / 2
        func point(_ x: CGFloat) -> NSPoint { hosting.superview!.convert(NSPoint(x: x, y: y), from: nil) }
        for x in [start - 4, start, start + 4] {
            let hit = hosting.hitTest(point(x))
            print("hit x=\(x):", hit.map { String(describing: type(of: $0)) } ?? "nil")
        }
        guard let target = hosting.hitTest(point(start)) else { return finish() }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: previewWindow.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        if command == "hover" {
            target.mouseEntered(with: event(.mouseMoved, start))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
            return
        }
        if command.hasPrefix("hold:") {   // Capture mid-drag, with the button still down.
            let amount = CGFloat(Double(command.dropFirst(5)) ?? 0)
            target.mouseDown(with: event(.leftMouseDown, start))
            target.mouseDragged(with: event(.leftMouseDragged, start + amount))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
            return
        }
        if command == "reset" {
            target.mouseDown(with: event(.leftMouseDown, start, clicks: 2))
            target.mouseUp(with: event(.leftMouseUp, start, clicks: 2))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { finish() }
            return
        }
        let amount = CGFloat(Double(command) ?? 0)
        target.mouseDown(with: event(.leftMouseDown, start))
        for step in 1...6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.08) {
                target.mouseDragged(with: event(.leftMouseDragged, start + amount * CGFloat(step) / 6))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { target.mouseUp(with: event(.leftMouseUp, start + amount)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { finish() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if let command = ProcessInfo.processInfo.environment["PREVIEW_DRAG_SIDEBAR"] {
            return driveSidebar(command) { capture() }
        }
        guard let amount = ProcessInfo.processInfo.environment["PREVIEW_SCROLL"].flatMap(Double.init),
              let scroller = tallestScroller(in: hosting) else { return capture() }
        scroller.contentView.scroll(to: NSPoint(x: 0, y: amount))
        scroller.reflectScrolledClipView(scroller.contentView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { capture() }
    }
    previewApp.run()
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
