import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit
import SwiftUI
import UniformTypeIdentifiers

private let codexAccountsWorkQueue = DispatchQueue(label: "local.codex.accounts.work", qos: .utility)
private let profileRefreshPayloadSeparator = "\u{1E}"

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
            ("喺呢部 Mac", "在這台 Mac"),
            ("喺 Finder 顯示", "在 Finder 顯示"),
            ("喺長任務期間", "在長任務期間"),
            ("而家", "現在"),
            ("咁樣", "這樣"),
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
    var output = Data()
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
        lock.lock()
        output.append(data)
        lock.unlock()
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
            output.append(remaining)
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

    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    color.opacity(active ? (pulse ? 1.0 : 0.26) : 0.98),
                    lineWidth: lineWidth
                )
                .shadow(
                    color: color.opacity(active ? (pulse ? 0.82 : 0.12) : 0.34),
                    radius: active ? (pulse ? 18 : 8) : 8,
                    x: 0,
                    y: 0
                )

            if active {
                RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                    .stroke(color.opacity(pulse ? 0.78 : 0.0), lineWidth: max(lineWidth * 0.34, 1))
                    .scaleEffect(pulse ? 1.18 : 1.02)
            }
        }
        .onAppear {
            configurePulse()
        }
        .onChange(of: active) { _, _ in
            configurePulse()
        }
    }

    private func configurePulse() {
        if active {
            pulse = false
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.54).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        } else {
            pulse = false
        }
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
            authMode: externalProfile.authMode == "unknown" ? "chatgpt" : externalProfile.authMode,
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

private func cachedUsage(for profileID: String) -> (quota: String, reset: String, resetCredits: String)? {
    let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Accounts/.usage-cache-v8")
        .appendingPathComponent("\(profileID).status")

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
    guard isPrimaryCodexHome(home) else { return nil }

    let configURL = URL(fileURLWithPath: home).appendingPathComponent("config.toml")
    guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
        return nil
    }

    let topLevel = topLevelTomlText(config)
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

final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    @Published private(set) var isAwake = false
    @Published private(set) var isSwitching = false

    private var caffeinateProcess: Process?
    private var jiggleTimer: Timer?
    private var clamshellTimer: Timer?
    private var stateMonitorTimer: Timer?
    private var stateRefreshInFlight = false
    private var lastStateRefreshAt = Date.distantPast
    private var storedBrightnessBeforeLidClose: Float?
    private var dimmedForClosedLid = false
    private let pidFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Accounts/keep-awake.pid")

    private init() {
        recoverExistingCaffeinate()
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

                if let pid = self.readPid(), self.isRunningCaffeinate(pid) {
                    self.startMouseJiggle()
                    self.startClamshellMonitor()
                    self.updateState(true)
                    return
                }

                if let pid = self.matchingCaffeinatePIDs().first {
                    self.writePid(pid)
                    self.startMouseJiggle()
                    self.startClamshellMonitor()
                    self.updateState(true)
                    return
                }

                self.stopMouseJiggle()
                self.stopClamshellMonitor(restoreBrightness: true)
                self.removePidFile()
                self.updateState(false)
            }
        }
    }

    func setAwake(_ enabled: Bool) {
        DispatchQueue.main.async {
            guard !self.isSwitching else { return }
            if self.isAwake == enabled {
                self.updateState(enabled)
                return
            }
            self.isSwitching = true
            enabled ? self.start() : self.stop()
            self.finishSwitchingAfterDelay()
        }
    }

    func toggle() {
        setAwake(!isAwake)
    }

    func start() {
        if caffeinateProcess?.isRunning == true {
            updateState(true)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-i", "-m", "-s"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            caffeinateProcess = process
            writePid(process.processIdentifier)
            startMouseJiggle()
            startClamshellMonitor()
            updateState(true)
        } catch {
            updateState(false)
            let language = UserDefaults.standard.string(forKey: "language")
            alertMessage(localizedText("防睡眠啟動失敗", "Keep Awake Failed", language: language), error.localizedDescription)
        }
    }

    func stop() {
        stopMouseJiggle()
        stopClamshellMonitor(restoreBrightness: true)
        let runningProcess = caffeinateProcess
        let savedPID = readPid()
        caffeinateProcess = nil
        removePidFile()
        updateState(false)

        DispatchQueue.global(qos: .utility).async {
            runningProcess?.terminate()
            if let savedPID, self.isRunningCaffeinate(savedPID) {
                Darwin.kill(savedPID, SIGTERM)
            }
            self.terminateMatchingCaffeinateProcesses()
        }
    }

    private func recoverExistingCaffeinate() {
        refreshState(force: true)
    }

    private func startStateMonitor() {
        DispatchQueue.main.async {
            self.stateMonitorTimer?.invalidate()
            self.stateMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                self.refreshState()
            }
        }
    }

    private func writePid(_ pid: Int32) {
        do {
            try FileManager.default.createDirectory(
                at: pidFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "\(pid)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
        } catch {
            // The switch still works without pid persistence; stale cleanup is best-effort.
        }
    }

    private func readPid() -> Int32? {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func terminateSavedCaffeinate() {
        guard let pid = readPid(), isRunningCaffeinate(pid) else { return }
        Darwin.kill(pid, SIGTERM)
    }

    private func terminateMatchingCaffeinateProcesses() {
        for pid in matchingCaffeinatePIDs() {
            Darwin.kill(pid, SIGTERM)
        }
    }

    private func matchingCaffeinatePIDs() -> [Int32] {
        let result = runProcess(
            executable: "/bin/ps",
            arguments: ["axww", "-o", "pid=", "-o", "command="],
            timeout: 3
        )
        guard result.0 == 0 else { return [] }

        return result.1.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let spaceIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            let pidText = String(trimmed[..<spaceIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let command = String(trimmed[spaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isManagedCaffeinateCommand(command) else { return nil }
            return Int32(pidText)
        }
    }

    private func isRunningCaffeinate(_ pid: Int32) -> Bool {
        guard Darwin.kill(pid, 0) == 0 else { return false }
        guard let command = processCommand(pid) else { return false }
        return isManagedCaffeinateCommand(command.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isManagedCaffeinateCommand(_ command: String) -> Bool {
        command == "/usr/bin/caffeinate -dims"
            || command == "caffeinate -dims"
            || command == "/usr/bin/caffeinate -d -i -m -s"
            || command == "caffeinate -d -i -m -s"
    }

    private func processCommand(_ pid: Int32) -> String? {
        let result = runProcess(
            executable: "/bin/ps",
            arguments: ["-p", "\(pid)", "-o", "command="],
            timeout: 3
        )
        guard result.0 == 0 else { return nil }
        return result.1
    }

    private func updateState(_ newValue: Bool) {
        DispatchQueue.main.async {
            guard self.isAwake != newValue else { return }
            self.isAwake = newValue
            NotificationCenter.default.post(name: .keepAwakeStateChanged, object: nil)
        }
    }

    private func finishSwitchingAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) {
            self.isSwitching = false
            NotificationCenter.default.post(name: .keepAwakeStateChanged, object: nil)
            self.refreshState(force: true)
        }
    }

    private func finishStateRefresh() {
        DispatchQueue.main.async {
            self.stateRefreshInFlight = false
        }
    }

    private func startMouseJiggle() {
        DispatchQueue.main.async {
            if self.jiggleTimer?.isValid == true {
                return
            }
            self.jiggleTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { _ in
                self.jiggleMouse()
            }
        }
    }

    private func stopMouseJiggle() {
        DispatchQueue.main.async {
            self.jiggleTimer?.invalidate()
            self.jiggleTimer = nil
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
        guard isAwake else {
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

    private func jiggleMouse() {
        guard let current = CGEvent(source: nil) else { return }
        let point = current.location
        moveMouse(to: CGPoint(x: point.x + 1, y: point.y))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.moveMouse(to: point)
        }
    }

    private func moveMouse(to point: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}

struct AccountsRootView: View {
    let scriptPath: String

    @StateObject private var keepAwake = KeepAwakeController.shared
    @StateObject private var keyboardClean = KeyboardCleanController.shared
    @StateObject private var updater = UpdateController.shared
    @State private var profiles: [CodexProfile] = []
    @State private var statusText = "就緒"
    @AppStorage("autoRefresh") private var autoRefresh = true
    @AppStorage("autoSync") private var autoSync = true
    @AppStorage("autoQuotaPool") private var autoQuotaPool = false
    @AppStorage("language") private var language = "zh"
    @State private var displayNames: [String: String] = UserDefaults.standard.dictionary(forKey: "profileDisplayNames") as? [String: String] ?? [:]
    @State private var lastAutoSync = ""
    @State private var launchedAt = Date()
    @State private var lastAutoSyncAt = Date.distantPast
    @State private var lastSidebarCleanupAt = Date.distantPast
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
    @State private var codexUsageSessionStart: Date?
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
    @AppStorage("codexUsageDayKey") private var codexUsageDayKey = ""
    @AppStorage("codexUsageSecondsToday") private var codexUsageSecondsToday = 0.0
    @AppStorage("appTheme") private var appTheme = "graphite"
    @Namespace private var languageNamespace

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let autoQuotaLiveRefreshInterval: TimeInterval = 900
    private let resetCreditLiveBackfillInterval: TimeInterval = 90
    private let autoSyncStartupDelay: TimeInterval = 90
    private let autoSyncInterval: TimeInterval = 600
    private let sidebarCleanupStartupDelay: TimeInterval = 15
    private let sidebarCleanupInterval: TimeInterval = 60

    var body: some View {
        ZStack {
            appBackground

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    sidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                mainPane
            }
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
        .frame(minWidth: 860, minHeight: 560)
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
            let normalizedLanguage = AppLanguage.normalized(language).rawValue
            if normalizedLanguage != language {
                language = normalizedLanguage
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                refreshProfiles(showLoading: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                lastSidebarCleanupAt = Date()
                cleanupSidebarProjectsSilently()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                keepAwake.refreshState(force: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                updater.checkForUpdates(presentNoUpdate: false, notifyIfAvailable: false)
            }
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
            runPeriodicMaintenance()
            keepAwake.refreshState()
            usageTicker = Date()
            normalizeUsageDay()
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
        lastAutoSync.isEmpty ? tr("未同步", "Not yet") : lastAutoSync
    }

    private var currentDayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func normalizeUsageDay() {
        let today = currentDayKey
        guard codexUsageDayKey != today else { return }
        codexUsageDayKey = today
        codexUsageSecondsToday = 0
        codexUsageSessionStart = nil
    }

    private func startUsageSession() {
        normalizeUsageDay()
        guard codexUsageSessionStart == nil else { return }
        codexUsageSessionStart = Date()
        usageTicker = Date()
    }

    private func finishUsageSession() {
        normalizeUsageDay()
        guard let start = codexUsageSessionStart else { return }
        codexUsageSecondsToday += max(Date().timeIntervalSince(start), 0)
        codexUsageSessionStart = nil
        usageTicker = Date()
    }

    private func currentUsageSeconds() -> TimeInterval {
        normalizeUsageDay()
        let liveSeconds = codexUsageSessionStart.map { max(Date().timeIntervalSince($0), 0) } ?? 0
        _ = usageTicker
        return codexUsageSecondsToday + liveSeconds
    }

    private func usageDurationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)H\(String(format: "%02d", minutes))M"
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
                primary: Color(red: 0.22, green: 0.74, blue: 1.00),
                secondary: Color(red: 0.00, green: 0.92, blue: 0.78),
                warm: Color(red: 0.82, green: 0.20, blue: 0.12)
            ),
            AppThemeOption(
                id: "aurora",
                zhTitle: tr("極光", "Aurora"),
                primary: Color(red: 0.02, green: 0.78, blue: 0.72),
                secondary: Color(red: 0.22, green: 0.95, blue: 0.48),
                warm: Color(red: 0.18, green: 0.50, blue: 1.00)
            ),
            AppThemeOption(
                id: "amber",
                zhTitle: tr("琥珀", "Amber"),
                primary: Color(red: 1.00, green: 0.58, blue: 0.16),
                secondary: Color(red: 1.00, green: 0.76, blue: 0.20),
                warm: Color(red: 0.88, green: 0.22, blue: 0.10)
            ),
            AppThemeOption(
                id: "violet",
                zhTitle: tr("紫晶", "Violet"),
                primary: Color(red: 0.62, green: 0.42, blue: 1.00),
                secondary: Color(red: 0.30, green: 0.84, blue: 1.00),
                warm: Color(red: 0.94, green: 0.30, blue: 0.64)
            ),
            AppThemeOption(
                id: "ocean",
                zhTitle: tr("深海", "Ocean"),
                primary: Color(red: 0.05, green: 0.70, blue: 1.00),
                secondary: Color(red: 0.00, green: 0.84, blue: 0.70),
                warm: Color(red: 1.00, green: 0.45, blue: 0.28)
            ),
            AppThemeOption(
                id: "sage",
                zhTitle: tr("苔原", "Sage"),
                primary: Color(red: 0.44, green: 0.82, blue: 0.52),
                secondary: Color(red: 0.86, green: 0.76, blue: 0.36),
                warm: Color(red: 0.95, green: 0.44, blue: 0.22)
            ),
            AppThemeOption(
                id: "rose",
                zhTitle: tr("玫瑰", "Rose"),
                primary: Color(red: 1.00, green: 0.42, blue: 0.62),
                secondary: Color(red: 0.56, green: 0.64, blue: 1.00),
                warm: Color(red: 1.00, green: 0.64, blue: 0.42)
            ),
            AppThemeOption(
                id: "indigo",
                zhTitle: tr("靛藍", "Indigo"),
                primary: Color(red: 0.35, green: 0.50, blue: 1.00),
                secondary: Color(red: 0.00, green: 0.82, blue: 0.95),
                warm: Color(red: 0.96, green: 0.42, blue: 0.88)
            ),
            AppThemeOption(
                id: "slate",
                zhTitle: tr("鋼灰", "Slate"),
                primary: Color(red: 0.55, green: 0.72, blue: 0.82),
                secondary: Color(red: 0.34, green: 0.92, blue: 0.82),
                warm: Color(red: 0.94, green: 0.68, blue: 0.36)
            ),
            AppThemeOption(
                id: "copper",
                zhTitle: tr("銅綠", "Copper"),
                primary: Color(red: 0.96, green: 0.46, blue: 0.22),
                secondary: Color(red: 0.16, green: 0.76, blue: 0.64),
                warm: Color(red: 0.98, green: 0.72, blue: 0.34)
            ),
            AppThemeOption(
                id: "glacier",
                zhTitle: tr("冰川", "Glacier"),
                primary: Color(red: 0.52, green: 0.82, blue: 1.00),
                secondary: Color(red: 0.56, green: 0.96, blue: 0.82),
                warm: Color(red: 0.74, green: 0.58, blue: 1.00)
            ),
            AppThemeOption(
                id: "ember",
                zhTitle: tr("星火", "Ember"),
                primary: Color(red: 1.00, green: 0.32, blue: 0.22),
                secondary: Color(red: 0.92, green: 0.64, blue: 0.18),
                warm: Color(red: 0.50, green: 0.66, blue: 1.00)
            )
        ]
    }

    private var selectedThemeOption: AppThemeOption {
        themeOptions.first(where: { $0.id == appTheme }) ?? themeOptions[0]
    }

    private var themePrimary: Color {
        selectedThemeOption.primary
    }

    private var themeSecondary: Color {
        selectedThemeOption.secondary
    }

    private var themeWarm: Color {
        selectedThemeOption.warm
    }

    private var themeBackgroundColors: [Color] {
        switch appTheme {
        case "aurora":
            return [
                Color(red: 0.00, green: 0.16, blue: 0.19).opacity(0.68),
                Color(red: 0.00, green: 0.30, blue: 0.25).opacity(0.50),
                Color(red: 0.03, green: 0.12, blue: 0.22).opacity(0.58)
            ]
        case "amber":
            return [
                Color(red: 0.30, green: 0.12, blue: 0.04).opacity(0.72),
                Color(red: 0.52, green: 0.24, blue: 0.06).opacity(0.56),
                Color(red: 0.16, green: 0.07, blue: 0.04).opacity(0.62)
            ]
        case "violet":
            return [
                Color(red: 0.16, green: 0.07, blue: 0.28).opacity(0.72),
                Color(red: 0.26, green: 0.12, blue: 0.42).opacity(0.54),
                Color(red: 0.05, green: 0.10, blue: 0.24).opacity(0.58)
            ]
        case "ocean":
            return [
                Color(red: 0.02, green: 0.08, blue: 0.16).opacity(0.72),
                Color(red: 0.00, green: 0.20, blue: 0.28).opacity(0.56),
                Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.62)
            ]
        case "sage":
            return [
                Color(red: 0.03, green: 0.15, blue: 0.10).opacity(0.72),
                Color(red: 0.14, green: 0.25, blue: 0.12).opacity(0.54),
                Color(red: 0.07, green: 0.09, blue: 0.07).opacity(0.64)
            ]
        case "rose":
            return [
                Color(red: 0.24, green: 0.05, blue: 0.13).opacity(0.72),
                Color(red: 0.36, green: 0.12, blue: 0.28).opacity(0.52),
                Color(red: 0.05, green: 0.08, blue: 0.20).opacity(0.58)
            ]
        case "indigo":
            return [
                Color(red: 0.04, green: 0.05, blue: 0.23).opacity(0.74),
                Color(red: 0.10, green: 0.14, blue: 0.38).opacity(0.56),
                Color(red: 0.02, green: 0.12, blue: 0.20).opacity(0.60)
            ]
        case "slate":
            return [
                Color(red: 0.06, green: 0.09, blue: 0.12).opacity(0.74),
                Color(red: 0.12, green: 0.18, blue: 0.22).opacity(0.54),
                Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.62)
            ]
        case "copper":
            return [
                Color(red: 0.20, green: 0.09, blue: 0.05).opacity(0.72),
                Color(red: 0.08, green: 0.22, blue: 0.18).opacity(0.52),
                Color(red: 0.22, green: 0.15, blue: 0.06).opacity(0.58)
            ]
        case "glacier":
            return [
                Color(red: 0.03, green: 0.12, blue: 0.18).opacity(0.70),
                Color(red: 0.08, green: 0.24, blue: 0.30).opacity(0.50),
                Color(red: 0.13, green: 0.10, blue: 0.24).opacity(0.54)
            ]
        case "ember":
            return [
                Color(red: 0.18, green: 0.05, blue: 0.04).opacity(0.74),
                Color(red: 0.30, green: 0.14, blue: 0.06).opacity(0.54),
                Color(red: 0.06, green: 0.07, blue: 0.15).opacity(0.62)
            ]
        default:
            return [
                Color(red: 0.03, green: 0.06, blue: 0.09).opacity(0.70),
                Color(red: 0.07, green: 0.11, blue: 0.14).opacity(0.52),
                Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.62)
            ]
        }
    }

    private var themeMainTint: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.00, green: 0.45, blue: 0.38)
        case "amber": return Color(red: 0.58, green: 0.26, blue: 0.08)
        case "violet": return Color(red: 0.38, green: 0.18, blue: 0.58)
        case "ocean": return Color(red: 0.00, green: 0.28, blue: 0.38)
        case "sage": return Color(red: 0.16, green: 0.34, blue: 0.18)
        case "rose": return Color(red: 0.44, green: 0.14, blue: 0.28)
        case "indigo": return Color(red: 0.18, green: 0.22, blue: 0.56)
        case "slate": return Color(red: 0.18, green: 0.26, blue: 0.32)
        case "copper": return Color(red: 0.42, green: 0.22, blue: 0.12)
        case "glacier": return Color(red: 0.14, green: 0.34, blue: 0.42)
        case "ember": return Color(red: 0.48, green: 0.16, blue: 0.12)
        default: return Color(red: 0.06, green: 0.18, blue: 0.24)
        }
    }

    private var themeSidebarTint: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.00, green: 0.34, blue: 0.29)
        case "amber": return Color(red: 0.38, green: 0.15, blue: 0.05)
        case "violet": return Color(red: 0.24, green: 0.10, blue: 0.38)
        case "ocean": return Color(red: 0.02, green: 0.14, blue: 0.24)
        case "sage": return Color(red: 0.10, green: 0.24, blue: 0.13)
        case "rose": return Color(red: 0.28, green: 0.08, blue: 0.18)
        case "indigo": return Color(red: 0.10, green: 0.12, blue: 0.36)
        case "slate": return Color(red: 0.12, green: 0.18, blue: 0.23)
        case "copper": return Color(red: 0.26, green: 0.12, blue: 0.07)
        case "glacier": return Color(red: 0.08, green: 0.22, blue: 0.28)
        case "ember": return Color(red: 0.30, green: 0.08, blue: 0.07)
        default: return Color(red: 0.04, green: 0.11, blue: 0.16)
        }
    }

    private var themeRowTint: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.00, green: 0.62, blue: 0.48)
        case "amber": return Color(red: 0.92, green: 0.40, blue: 0.10)
        case "violet": return Color(red: 0.56, green: 0.25, blue: 0.88)
        case "ocean": return Color(red: 0.00, green: 0.52, blue: 0.72)
        case "sage": return Color(red: 0.34, green: 0.62, blue: 0.34)
        case "rose": return Color(red: 0.80, green: 0.24, blue: 0.46)
        case "indigo": return Color(red: 0.30, green: 0.40, blue: 0.86)
        case "slate": return Color(red: 0.34, green: 0.48, blue: 0.56)
        case "copper": return Color(red: 0.72, green: 0.34, blue: 0.18)
        case "glacier": return Color(red: 0.32, green: 0.66, blue: 0.82)
        case "ember": return Color(red: 0.78, green: 0.24, blue: 0.16)
        default: return Color(red: 0.08, green: 0.34, blue: 0.46)
        }
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

        if !isCleaningSidebarState,
           now.timeIntervalSince(launchedAt) >= sidebarCleanupStartupDelay,
           now.timeIntervalSince(lastSidebarCleanupAt) >= sidebarCleanupInterval {
            lastSidebarCleanupAt = now
            cleanupSidebarProjectsSilently()
        }

        if autoSync,
           !isSyncing,
           now.timeIntervalSince(launchedAt) >= autoSyncStartupDelay,
           now.timeIntervalSince(lastAutoSyncAt) >= autoSyncInterval {
            lastAutoSyncAt = now
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
            liveParallelism: shouldUseLiveQuota ? 1 : 2,
            statusTimeout: shouldUseLiveQuota ? 18 : 8
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
                liveParallelism: 1,
                statusTimeout: 20
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
            RadialGradient(colors: [themePrimary.opacity(0.24), Color.clear], center: .topTrailing, startRadius: 70, endRadius: 560)
            RadialGradient(colors: [themeSecondary.opacity(0.17), Color.clear], center: .topLeading, startRadius: 50, endRadius: 430)
            RadialGradient(colors: [themeWarm.opacity(0.18), Color.clear], center: .bottomLeading, startRadius: 70, endRadius: 520)
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
                introPoint("5.circle.fill", tr("立即同步會同步本機記憶；共享全部會令所有 profile 共用同一份本機對話紀錄。普通打開唔會自動共享。", "Sync now syncs local memories; Share all links every profile to one local chat history. Normal opens do not share history automatically."))
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
            .padding(.top, scaled(62))
            .padding(.bottom, scaled(22))
            .padding(.leading, scaled(28))
            .padding(.trailing, scaled(24))
            .frame(width: scaled(272), alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .scrollClipDisabled(false)
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
        let menuWidth = scaled(146)
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
        .frame(width: scaled(146), alignment: .topLeading)
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
            .frame(width: scaled(134), height: scaled(40), alignment: .leading)
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
                subtitle: tr("同步：\(lastAutoSyncLabel)", "Sync: \(lastAutoSyncLabel)"),
                accent: Color(red: 0.28, green: 0.70, blue: 1.00),
                expanded: $sidebarAutomationExpanded
            ) {
                HStack(spacing: scaled(6)) {
                    Text(tr("功能說明", "Help"))
                        .font(appFont(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                    syncInfoIcon
                    Spacer(minLength: 0)
                }

                sidebarToggle(tr("每分鐘重新整理", "Auto refresh"), isOn: $autoRefresh, tint: Color(red: 0.20, green: 0.64, blue: 1.00))
                sidebarToggle(tr("每分鐘同步對話同記憶", "Auto sync"), isOn: $autoSync, tint: Color(red: 0.20, green: 0.64, blue: 1.00))

                HStack(spacing: scaled(8)) {
                    miniButton(tr("立即同步", "Sync now")) { syncMemories() }
                    miniButton(tr("共享全部", "Share all")) { shareAll() }
                }
            }

            sidebarDisclosureSection(
                title: tr("系統工具", "System Tools"),
                systemName: "switch.2",
                subtitle: systemToolsSummary,
                accent: keepAwake.isAwake || keyboardClean.isLocked ? Color(red: 0.00, green: 0.88, blue: 0.68) : Color.white.opacity(0.62),
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
        let awake = keepAwake.isAwake ? tr("防睡眠開", "Awake on") : tr("防睡眠關", "Awake off")
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
            "防止 Mac 自動睡眠。打開後合蓋會盡量保持任務運行，內置屏幕亮度會降到 0；開蓋或關閉功能會恢復亮度。",
            "Prevents Mac sleep. When enabled, closing the lid keeps tasks running where macOS allows it and dims the built-in display to 0; opening the lid or turning this off restores brightness."
        )
    }

    private var keepAwakePanel: some View {
        HStack(spacing: scaled(10)) {
            VStack(alignment: .leading, spacing: scaled(3)) {
                HStack(spacing: scaled(5)) {
                    Text(tr("防睡眠", "Keep Awake"))
                        .font(appFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                    keepAwakeInfoIcon
                }
                Text(keepAwake.isAwake ? tr("已開", "On") : tr("已關", "Off"))
                    .font(appFont(size: 12, weight: .semibold))
                    .foregroundStyle(keepAwake.isAwake ? Color(red: 0.00, green: 0.95, blue: 0.48) : Color.white.opacity(0.46))
                    .lineLimit(1)
            }

            Spacer(minLength: scaled(8))

            keepAwakeGlassButton
        }
    }

    private var keepAwakeGlassButton: some View {
        let active = keepAwake.isAwake
        let accent = active ? Color(red: 0.00, green: 0.95, blue: 0.48) : Color(red: 0.52, green: 0.58, blue: 0.66)

        return Button {
            keepAwake.toggle()
        } label: {
            HStack(spacing: scaled(6)) {
                if keepAwake.isSwitching {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: scaled(14), height: scaled(14))
                } else {
                    Image(systemName: active ? "sun.max.fill" : "moon.zzz.fill")
                        .font(.system(size: scaled(12), weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                    Text(active ? "ON" : "OFF")
                        .font(appFont(size: 10, weight: .heavy, monospaced: true))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.82))
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
                            colors: [Color.white.opacity(0.30), accent.opacity(active ? 0.58 : 0.38), Color.black.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.90, hoverScale: 1.04, glow: accent, glowOpacity: 0.18))
        .disabled(keepAwake.isSwitching)
        .opacity(keepAwake.isSwitching ? 0.72 : 1)
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

        return VStack(alignment: .leading, spacing: scaled(6)) {
            HStack {
                Text(tr("今日使用", "Today"))
                    .font(appFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                Text(label)
                    .font(appFont(size: 11, weight: .semibold, monospaced: true))
                    .foregroundStyle(Color(red: 0.32, green: 0.86, blue: 1.00))
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
                                    Color(red: 0.20, green: 0.78, blue: 1.00),
                                    Color(red: 0.00, green: 0.90, blue: 0.72),
                                    Color(red: 1.00, green: 0.72, blue: 0.20)
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
        }
    }

    private var themeSelector: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: scaled(6)), count: 4)

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

            LazyVGrid(columns: columns, spacing: scaled(6)) {
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
            ZStack {
                RoundedRectangle(cornerRadius: scaled(9), style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [option.primary, option.secondary, option.warm],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(Color.black.opacity(selected ? 0.0 : 0.10))

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: scaled(10), weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: scaled(26))
            .overlay(
                RoundedRectangle(cornerRadius: scaled(9), style: .continuous)
                    .stroke(selected ? Color.white.opacity(0.74) : Color.white.opacity(0.14), lineWidth: selected ? 1.4 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: scaled(9), style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: scaled(9), style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.88, hoverScale: 1.08, glow: option.primary, glowOpacity: selected ? 0.28 : 0.18))
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
            "立即同步：同步本機記憶檔案。\n\n共享全部：將所有 profile 連到同一份本機對話紀錄；普通打開 profile 唔會自動共享。",
            "Sync now: syncs local memories and conversation history.\n\nShare all: links every profile to the same local chat history; normal profile opens do not auto-share."
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
                refreshProfiles(showLoading: true, replayQuota: true, liveUsage: true)
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
            : (expired ? tr("登入過期", "Expired") : (compact ? tr("要登入", "Login") : tr("要登入", "Login needed"))))
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

    private func externalProviderStatus(_ profile: CodexProfile, compact: Bool) -> some View {
        let accent = Color(red: 0.10, green: 0.86, blue: 0.74)
        let model = profile.reset.hasPrefix("aliyun:")
            ? String(profile.reset.dropFirst("aliyun:".count))
            : "qwen3.7-plus"

        return HStack(alignment: .center, spacing: scaled(compact ? 8 : 10)) {
            apiStatusPill(title: tr("外部 API", "External API"), accent: accent, compact: compact)
            apiStatusPill(title: "Coding Plan", accent: accent.opacity(0.82), compact: compact)
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
        .help(tr("外部 API profile 不使用 OpenAI quota。", "External API profiles do not use OpenAI quota."))
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
        menu.addItem(CallbackMenuItem(title: tr("共享對話紀錄", "Share History")) {
            shareHistory(profile)
        })
        menu.addItem(CallbackMenuItem(title: tr("分開對話紀錄", "Separate History")) {
            separateHistory(profile)
        })
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: tr("刪除 Profile...", "Delete Profile..."), enabled: profile.id != "account1") {
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
        work: @escaping () -> (Int32, String),
        completion: @escaping ((Int32, String)) -> Void
    ) {
        if let message {
            activeOperationCount += 1
            loadingMessage = message
        }

        codexAccountsWorkQueue.async {
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
        statusTimeout: TimeInterval? = nil
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
                statusTimeout: statusTimeout
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
        statusTimeout: TimeInterval?
    ) {
        let loading = showLoading ? tr("更新用量...", "Updating usage...") : nil
        let previousProfiles = profiles

        runBackground(loading) {
            var environment = ProcessInfo.processInfo.environment
            let resolvedParallelism = max(1, liveParallelism ?? 2)
            let resolvedTimeout = statusTimeout ?? (liveUsage ? (resolvedParallelism <= 1 ? 20 : 18) : 8)
            environment["CODEX_USAGE_LIVE_LOOKUP"] = liveUsage ? "1" : "0"
            environment["STATUS_PARALLELISM"] = "\(resolvedParallelism)"
            if liveUsage {
                environment["USAGE_DIRECT_CONNECT_TIMEOUT_SECONDS"] = "1"
                environment["USAGE_DIRECT_TIMEOUT_SECONDS"] = "2"
                environment["TOKEN_REFRESH_CONNECT_TIMEOUT_SECONDS"] = "1"
                environment["TOKEN_REFRESH_TIMEOUT_SECONDS"] = "3"
                environment["APP_SERVER_USAGE_TIMEOUT_SECONDS"] = "3"
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
            runCodexScript(scriptPath, ["init-account", name], wait: true, timeout: 60)
        } completion: { result in
            guard result.0 == 0 else {
                alertMessage(tr("建立帳戶失敗", "Could Not Create Account"), result.1)
                return
            }
            displayNames[sanitizedProfileId(name)] = name
            UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
            refreshProfiles(showLoading: false)
            openAccount(name, displayName: name)
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
        var launchArguments = ["launch-account-nosync", targetID]
        if !targetName.isEmpty {
            launchArguments.append(targetName)
        }
        let requestedID = sanitizedProfileId(name)
        let targetProfileID = sanitizedProfileId(targetID)
        let busyIDs = Set([requestedID, targetProfileID])
        startUsageSession()
        busyIDs.forEach { setProfileBusy($0, true) }
        let loadingText: String
        if syncBeforeLaunch {
            loadingText = tr("正在同步對話同記憶，再打開 \(targetName)...", "Syncing history and memory, then opening \(targetName)...")
        } else {
            loadingText = tr("正在打開 \(targetName)...", "Opening \(targetName)...")
        }
        runBackground(loadingText) {
            if syncBeforeLaunch {
                var syncEnvironment = ProcessInfo.processInfo.environment
                syncEnvironment["CODEX_PRELAUNCH_SYNC_LOCK_MAX_WAITS"] = "8"
                syncEnvironment["CODEX_RSYNC_MAX_WAITS"] = "50"
                syncEnvironment["CODEX_RSYNC_WAIT_SECONDS"] = "0.08"
                syncEnvironment["CODEX_SYNC_THREAD_HISTORY"] = "1"
                let syncResult = runCodexScript(
                    scriptPath,
                    ["sync-account-for-launch", targetID],
                    wait: true,
                    timeout: 24,
                    environment: syncEnvironment
                )
                guard syncResult.0 == 0 else { return syncResult }
            }

            if route?.didSwitch == true {
                _ = runCodexScript(scriptPath, ["close-account", name], wait: true, timeout: 12)
            }

            var launchEnvironment = ProcessInfo.processInfo.environment
            launchEnvironment["CODEX_PRELAUNCH_SYNC"] = "0"
            launchEnvironment["CODEX_SHARED_SESSIONS"] = "1"
            launchEnvironment["CODEX_SYNC_THREAD_HISTORY"] = "0"
            return runCodexScript(
                scriptPath,
                launchArguments,
                wait: true,
                timeout: 28,
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
        }
    }

    private func closeAccount(_ profile: CodexProfile) {
        setProfileBusy(profile.id, true)
        runBackground(tr("關閉 \(profile.displayName)...", "Closing \(profile.displayName)...")) {
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
        }
    }

    private func closeAllAccounts() {
        runBackground(tr("關閉全部 Codex 視窗...", "Closing all Codex windows...")) {
            runCodexScript(scriptPath, ["close-all-accounts"], wait: true, timeout: 35)
        } completion: { result in
            if result.0 == 0 {
                finishUsageSession()
                activeQuotaPoolProfileID = nil
                quotaPoolFailoverInProgress = false
            }
            statusText = result.0 == 0
                ? tr("已關閉全部 Codex 視窗", "Closed all Codex windows")
                : tr("關閉全部失敗", "Close all failed")
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
            lastAutoSyncAt = Date()
            if result.0 == 0 {
                lastAutoSync = time
                statusText = silent ? tr("已自動同步 \(time)", "Auto synced at \(time)") : tr("對話同記憶已同步", "History and memory synced")
            } else if !silent {
                statusText = tr("同步失敗", "Sync failed")
            }
        }
    }

    private func cleanupSidebarProjectsSilently() {
        guard !isCleaningSidebarState else { return }
        isCleaningSidebarState = true

        runBackground(nil) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SYNC_THREAD_HISTORY"] = "0"
            return runCodexScript(scriptPath, ["cleanup-empty-projects"], wait: true, timeout: 45, environment: environment)
        } completion: { _ in
            isCleaningSidebarState = false
        }
    }

    private func repairLargeHistoryPayloads() {
        guard !isRepairingHistoryPayloads else { return }
        isRepairingHistoryPayloads = true

        runBackground(tr("清理大型對話...", "Cleaning large chats...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_REPAIR_COMPACTED_IMAGES_ON_LAUNCH"] = "1"
            return runCodexScript(scriptPath, ["repair-account1"], wait: true, timeout: 120, environment: environment)
        } completion: { result in
            isRepairingHistoryPayloads = false
            statusText = result.0 == 0
                ? tr("已清理大型對話", "Large chats cleaned")
                : tr("清理大型對話失敗", "Large chat cleanup failed")
        }
    }

    private func shareAll() {
        runBackground(tr("共享對話紀錄...", "Sharing history...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SHARED_SESSIONS"] = "1"
            return runCodexScript(scriptPath, ["link-all-history"], wait: true, timeout: 60, environment: environment)
        } completion: { result in
            statusText = result.0 == 0 ? tr("已同全部 profile 共享對話紀錄", "History shared with all profiles") : tr("共享失敗", "History share failed")
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

    private func shareHistory(_ profile: CodexProfile) {
        runBackground(tr("共享 \(profile.displayName) 對話紀錄...", "Sharing \(profile.displayName) history...")) {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_SHARED_SESSIONS"] = "1"
            return runCodexScript(scriptPath, ["link-history", profile.id], wait: true, timeout: 45, environment: environment)
        } completion: { result in
            statusText = result.0 == 0 ? tr("已同 \(profile.displayName) 共享對話紀錄", "History shared with \(profile.displayName)") : tr("共享失敗", "History share failed")
            refreshProfiles(showLoading: false)
        }
    }

    private func separateHistory(_ profile: CodexProfile) {
        runBackground(tr("分開 \(profile.displayName) 對話紀錄...", "Separating \(profile.displayName) history...")) {
            runCodexScript(scriptPath, ["separate-history", profile.id], wait: true, timeout: 45)
        } completion: { result in
            statusText = result.0 == 0 ? tr("已分開 \(profile.displayName) 對話紀錄", "Separated \(profile.displayName) history") : tr("分開紀錄失敗", "History separation failed")
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

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("Codex-Accounts/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                self.finishCheck(errorMessage: error.localizedDescription, presentNoUpdate: presentNoUpdate)
                return
            }

            guard let data,
                  let release = self.parseRelease(from: data)
            else {
                self.finishCheck(errorMessage: self.localized("未能讀取 GitHub Release。", "Could not read the GitHub release."), presentNoUpdate: presentNoUpdate)
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
        }.resume()
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

        URLSession.shared.downloadTask(with: request) { temporaryURL, _, error in
            if let error {
                self.finishInstall(errorMessage: error.localizedDescription)
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
    private var sidebarPruneProcess: Process?
    private var window: NSWindow!
    private var cachedAccounts: [Account] = []
    private var accountsCacheRefreshInFlight = false

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
        startSidebarPruneLoop()
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
        let awakeTitle = KeepAwakeController.shared.isAwake
            ? appTr("關閉防睡眠", "Turn Keep Awake Off")
            : appTr("開啟防睡眠", "Turn Keep Awake On")
        let awakeItem = menuItem(awakeTitle, action: #selector(toggleKeepAwake), key: "k")
        awakeItem.state = KeepAwakeController.shared.isAwake ? .on : .off
        menu.addItem(awakeItem)
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
        appMenu.addItem(menuItem(appTr("切換防睡眠", "Toggle Keep Awake"), action: #selector(toggleKeepAwake), key: "k"))
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
        accountMenu.addItem(menuItem(appTr("切換防睡眠", "Toggle Keep Awake"), action: #selector(toggleKeepAwake), key: "k"))
        accountMenu.addItem(menuItem(appTr("切換清潔模式", "Toggle Clean Mode"), action: #selector(toggleKeyboardClean), key: ""))
        accountMenu.addItem(NSMenuItem.separator())
        accountMenu.addItem(menuItem(appTr("共享全部對話紀錄", "Share All History"), action: #selector(linkAllHistory), key: ""))
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appTr("Codex 帳戶", "Codex Accounts")
        window.center()
        window.minSize = NSSize(width: 860, height: 560)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
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
        if ["sync-once", "sync-history-once", "sync-account", "sync-account-for-launch", "sync-loop", "sync-history-loop"].contains(command) {
            environment["CODEX_SYNC_THREAD_HISTORY"] = "1"
        } else if !["link-history", "link-all-history", "link-account2-history"].contains(command) {
            environment["CODEX_SYNC_THREAD_HISTORY"] = "0"
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

    private func startSidebarPruneLoop() {
        guard sidebarPruneProcess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath, "prune-loop"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_DELETE_STALE_THREAD_ROWS"] = "0"
        environment["CODEX_SIDEBAR_PRUNE_INTERVAL_SECONDS"] = "5"
        process.environment = environment
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.sidebarPruneProcess = nil
            }
        }

        do {
            try process.run()
            sidebarPruneProcess = process
        } catch {
            sidebarPruneProcess = nil
        }
    }

    @objc private func toggleKeepAwake() {
        KeepAwakeController.shared.toggle()
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
        sidebarPruneProcess?.terminate()
        KeyboardCleanController.shared.stop()
        KeepAwakeController.shared.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncProcess?.terminate()
        sidebarPruneProcess?.terminate()
        KeyboardCleanController.shared.stop()
        KeepAwakeController.shared.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
