import AppKit
import CoreGraphics
import Darwin
import SwiftUI

struct CodexProfile: Identifiable {
    let id: String
    let displayName: String
    let home: String
    let authStatus: String
    let authMode: String
    let lastRefresh: String
    let quota: String
    let reset: String
}

private struct QuotaWindow: Identifiable {
    let id: String
    let labelZH: String
    let labelEN: String
    let percent: Int?
}

private func runCodexScript(_ scriptPath: String, _ arguments: [String], wait: Bool = false) -> (Int32, String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [scriptPath] + arguments
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        if wait {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        return (0, "")
    } catch {
        return (1, error.localizedDescription)
    }
}

private func promptForAccountName(title: String, message: String, defaultName: String? = nil) -> String? {
    let language = UserDefaults.standard.string(forKey: "language") ?? "zh"
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: language == "zh" ? "繼續" : "Continue")
    alert.addButton(withTitle: language == "zh" ? "取消" : "Cancel")

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
    let language = UserDefaults.standard.string(forKey: "language") ?? "zh"
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: language == "zh" ? "好" : "OK")
    alert.runModal()
}

extension Notification.Name {
    static let keepAwakeStateChanged = Notification.Name("CodexAccountsKeepAwakeStateChanged")
}

final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()

    @Published private(set) var isAwake = false

    private var caffeinateProcess: Process?
    private var jiggleTimer: Timer?
    private let pidFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Accounts/keep-awake.pid")

    private init() {
        recoverExistingCaffeinate()
    }

    func setAwake(_ enabled: Bool) {
        enabled ? start() : stop()
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
        process.arguments = ["-dims"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            caffeinateProcess = process
            writePid(process.processIdentifier)
            startMouseJiggle()
            updateState(true)
        } catch {
            updateState(false)
            let language = UserDefaults.standard.string(forKey: "language") ?? "zh"
            alertMessage(language == "zh" ? "防睡眠啟動失敗" : "Keep Awake Failed", error.localizedDescription)
        }
    }

    func stop() {
        stopMouseJiggle()
        caffeinateProcess?.terminate()
        terminateSavedCaffeinate()
        caffeinateProcess = nil
        removePidFile()
        updateState(false)
    }

    private func recoverExistingCaffeinate() {
        guard let pid = readPid(), isRunningCaffeinate(pid) else {
            removePidFile()
            return
        }
        isAwake = true
        startMouseJiggle()
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

    private func isRunningCaffeinate(_ pid: Int32) -> Bool {
        guard Darwin.kill(pid, 0) == 0 else { return false }
        guard let command = processCommand(pid) else { return false }
        return command.contains("/usr/bin/caffeinate") || command.contains("caffeinate -dims")
    }

    private func processCommand(_ pid: Int32) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func updateState(_ newValue: Bool) {
        DispatchQueue.main.async {
            self.isAwake = newValue
            NotificationCenter.default.post(name: .keepAwakeStateChanged, object: nil)
        }
    }

    private func startMouseJiggle() {
        stopMouseJiggle()

        DispatchQueue.main.async {
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
    @State private var profiles: [CodexProfile] = []
    @State private var statusText = "就緒"
    @AppStorage("autoRefresh") private var autoRefresh = true
    @AppStorage("autoSync") private var autoSync = true
    @AppStorage("language") private var language = "zh"
    @State private var displayNames: [String: String] = UserDefaults.standard.dictionary(forKey: "profileDisplayNames") as? [String: String] ?? [:]
    @State private var lastAutoSync = ""
    @State private var layoutScale: CGFloat = 1

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            appBackground

            VStack(spacing: 0) {
                Color.clear.frame(height: 26)

                HStack(spacing: 0) {
                    sidebar
                    mainPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateLayoutScale(for: geometry.size) }
                    .onChange(of: geometry.size) { _, newSize in
                        updateLayoutScale(for: newSize)
                    }
            }
        )
        .onAppear(perform: refreshProfiles)
        .onChange(of: language) { _, _ in
            NotificationCenter.default.post(name: Notification.Name("CodexAccountsLanguageChanged"), object: nil)
        }
        .onReceive(timer) { _ in
            if autoRefresh {
                refreshProfiles()
            }
            if autoSync {
                syncMemories(silent: true)
            }
        }
    }

    private func tr(_ zh: String, _ en: String) -> String {
        language == "zh" ? zh : en
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        (value * layoutScale).rounded()
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

    private var appBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.10).opacity(0.30),
                    Color(red: 0.13, green: 0.09, blue: 0.09).opacity(0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.04)
            RadialGradient(colors: [Color.cyan.opacity(0.10), Color.clear], center: .topLeading, startRadius: 40, endRadius: 420)
            RadialGradient(colors: [Color.blue.opacity(0.08), Color.clear], center: .topTrailing, startRadius: 80, endRadius: 520)
            RadialGradient(colors: [Color.orange.opacity(0.07), Color.clear], center: .bottomTrailing, startRadius: 60, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: scaled(14)) {
            header

            ScrollView {
                profilesList
                    .padding(.bottom, scaled(44))
            }
            .scrollIndicators(.visible)
        }
        .padding(.top, scaled(32))
        .padding(.bottom, 0)
        .padding(.leading, scaled(34))
        .padding(.trailing, scaled(34))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.06)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.025),
                        Color.black.opacity(0.02)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            ZStack {
                RoundedRectangle(cornerRadius: scaled(23), style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background(Color.black.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: scaled(23), style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )

                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: scaled(76), height: scaled(76))
                    .clipShape(RoundedRectangle(cornerRadius: scaled(18), style: .continuous))
            }
            .frame(width: scaled(94), height: scaled(94))
            .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)

            VStack(alignment: .leading, spacing: scaled(8)) {
                Text(tr("Codex 帳戶", "Codex Accounts"))
                    .font(.system(size: scaled(28), weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(tr("多帳戶登入，共用本機紀錄。", "Separate logins. Shared local history."))
                    .font(.system(size: scaled(13), weight: .regular))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineSpacing(scaled(3))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            sidebarSettings

            Spacer(minLength: 0)
        }
        .padding(.top, scaled(36))
        .padding(.bottom, scaled(22))
        .padding(.leading, scaled(32))
        .padding(.trailing, scaled(30))
        .frame(width: scaled(300), alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.09)
                LinearGradient(
                    colors: [
                        Color(red: 0.035, green: 0.055, blue: 0.08).opacity(0.22),
                        Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(colors: [Color.cyan.opacity(0.16), Color.clear], center: .topLeading, startRadius: 20, endRadius: 260)
            }
        )
    }

    private var sidebarSettings: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            VStack(alignment: .leading, spacing: scaled(8)) {
                Text(tr("語言", "Language"))
                    .font(.system(size: scaled(12), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))

                Picker("", selection: $language) {
                    Text("中文").tag("zh")
                    Text("EN").tag("en")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: scaled(112))
            }

            Divider().background(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: scaled(10)) {
                Text(tr("自動化", "Automation"))
                    .font(.system(size: scaled(12), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))

                sidebarToggle(tr("每分鐘重新整理", "Refresh every minute"), isOn: $autoRefresh)
                sidebarToggle(tr("每分鐘同步記憶", "Sync memories every minute"), isOn: $autoSync)

                HStack(spacing: scaled(8)) {
                    miniButton(tr("立即同步", "Sync now")) { syncMemories() }
                    miniButton(tr("共享全部", "Share all")) { shareAll() }
                }

                Text(tr("上次同步：\(lastAutoSyncLabel)", "Last sync: \(lastAutoSyncLabel)"))
                    .font(.system(size: scaled(10)))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Divider().background(Color.white.opacity(0.12))

            HStack(spacing: scaled(10)) {
                VStack(alignment: .leading, spacing: scaled(3)) {
                    Text(tr("防睡眠", "Keep Awake"))
                        .font(.system(size: scaled(12), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                    Text(keepAwake.isAwake ? tr("已開", "On") : tr("已關", "Off"))
                        .font(.system(size: scaled(12), weight: .semibold))
                        .foregroundStyle(keepAwake.isAwake ? Color.green : Color.white.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: scaled(8))

                Toggle("", isOn: Binding(
                    get: { keepAwake.isAwake },
                    set: { keepAwake.setAwake($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: scaled(48))
            }

            Divider().background(Color.white.opacity(0.12))

            Text(statusText)
                .font(.system(size: scaled(10), weight: .medium))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(scaled(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(16), style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: scaled(18)) {
            VStack(alignment: .leading, spacing: scaled(6)) {
                Text(tr("帳戶", "Profiles"))
                    .font(.system(size: scaled(28), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(tr("選擇要開邊個 Codex 登入視窗。登入狀態每分鐘更新。", "Choose an account window. Login state refreshes every minute."))
                    .font(.system(size: scaled(14)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: scaled(12)) {
                glassIconButton(systemName: "plus", label: tr("新增帳戶", "New Account")) {
                    createAccount()
                }

                glassIconButton(systemName: "arrow.clockwise", label: tr("重新整理", "Refresh")) {
                    refreshProfiles()
                }

                glassIconButton(systemName: "folder", label: tr("Profile 資料夾", "Profiles Folder")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex-accounts"))
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: scaled(66), alignment: .center)
    }

    private var profilesList: some View {
        LazyVStack(spacing: scaled(8)) {
            ForEach(profiles) { profile in
                profileRow(profile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func profileRow(_ profile: CodexProfile) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let veryCompact = width < 620
            let compactStatus = width < 760
            let rowSpacing = scaled(veryCompact ? 7 : 10)
            let titleMinWidth = scaled(veryCompact ? 54 : 90)
            let quotaWidth = scaled(width < 640 ? 154 : (width < 920 ? 178 : 218))
            let statusWidth = scaled(compactStatus ? 86 : 96)
            let menuWidth = scaled(veryCompact ? 32 : 38)

            HStack(spacing: rowSpacing) {
                profileBadge(profile)
                    .layoutPriority(20)

                profileTitleBlock(profile, showsPath: true)
                    .frame(minWidth: titleMinWidth, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                Spacer(minLength: scaled(4))

                quotaMeter(profile, compact: veryCompact)
                    .frame(width: quotaWidth, alignment: .trailing)
                    .layoutPriority(30)

                authBadge(profile, compact: compactStatus)
                    .frame(width: statusWidth)
                    .layoutPriority(20)

                openButton(profile)
                    .frame(width: scaled(64))
                    .layoutPriority(20)

                closeButton(profile)
                    .frame(width: scaled(30))
                    .layoutPriority(20)

                profileMenu(profile)
                    .frame(width: menuWidth)
                    .layoutPriority(20)
            }
            .padding(.horizontal, scaled(14))
            .padding(.vertical, scaled(8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, minHeight: scaled(58), idealHeight: scaled(58), maxHeight: scaled(58), alignment: .leading)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.07))
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.07), Color.white.opacity(0.015)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            quotaAccent(for: profile).opacity(profile.quota == "unknown" ? 0.10 : 0.34),
                            Color.white.opacity(0.10)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func profileBadge(_ profile: CodexProfile) -> some View {
        Image(nsImage: profileBadgeImage(for: profile))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
        .frame(width: scaled(38), height: scaled(38))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 6)
        .clipShape(RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
    }

    private func profileBadgeImage(for profile: CodexProfile) -> NSImage {
        let resourceName = "ProfileIcon-\(profileBadgeLetter(for: profile) ?? "Default")"
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png", subdirectory: "ProfileLetterIcons"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon") ?? NSImage()
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
                .font(.system(size: scaled(15), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)

            if showsPath {
                Text(profile.home)
                    .font(.system(size: scaled(11), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(true)
            }
        }
    }

    private func authBadge(_ profile: CodexProfile, compact: Bool = false) -> some View {
        let signedIn = profile.authStatus == "signed_in_local"
        let title = signedIn
            ? tr("已登入", "Signed in")
            : (compact ? tr("要登入", "Login") : tr("要登入", "Login needed"))
        let color = signedIn ? Color.green : Color.orange

        return Text(title)
            .font(.system(size: scaled(12), weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(6))
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
    }

    private func quotaMeter(_ profile: CodexProfile, compact: Bool) -> some View {
        let accent = quotaAccent(for: profile)
        let windows = quotaWindows(for: profile)

        return VStack(spacing: scaled(5)) {
            ForEach(windows) { window in
                quotaMeterLine(window, accent: quotaAccent(for: window.percent), compact: compact)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, scaled(compact ? 8 : 10))
        .padding(.vertical, scaled(7))
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(13), style: .continuous)
                .stroke(accent.opacity(profile.quota == "unknown" ? 0.16 : 0.58), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(13), style: .continuous))
        .shadow(color: accent.opacity(profile.quota == "unknown" ? 0 : 0.12), radius: 8, x: 0, y: 3)
        .help(quotaHelp(for: profile))
    }

    private func quotaMeterLine(_ window: QuotaWindow, accent: Color, compact: Bool) -> some View {
        HStack(spacing: scaled(compact ? 5 : 7)) {
            Text(tr(window.labelZH, window.labelEN))
                .font(.system(size: scaled(compact ? 9 : 10), weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: scaled(compact ? 18 : 22), alignment: .leading)
                .lineLimit(1)

            quotaProgressBar(percent: window.percent, accent: accent, compact: compact)
                .frame(maxWidth: .infinity)

            Text(window.percent.map { "\($0)%" } ?? "--")
                .font(.system(size: scaled(compact ? 12 : 13), weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent.opacity(window.percent == nil ? 0.56 : 0.95))
                .frame(width: scaled(compact ? 42 : 48), alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
        }
    }

    private func quotaWindows(for profile: CodexProfile) -> [QuotaWindow] {
        if profile.quota == "unlimited" {
            return [
                QuotaWindow(id: "5h", labelZH: "5時", labelEN: "5h", percent: 100),
                QuotaWindow(id: "7d", labelZH: "週", labelEN: "7d", percent: 100)
            ]
        }

        guard profile.quota != "unknown" else {
            return [
                QuotaWindow(id: "5h", labelZH: "5時", labelEN: "5h", percent: nil),
                QuotaWindow(id: "7d", labelZH: "週", labelEN: "7d", percent: nil)
            ]
        }

        var parsed: [QuotaWindow] = []
        for part in profile.quota.split(separator: "/") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let percent = quotaPercents(from: text).first
            if text.lowercased().hasPrefix("5h") {
                parsed.append(QuotaWindow(id: "5h", labelZH: "5時", labelEN: "5h", percent: percent))
            } else if text.lowercased().hasPrefix("7d") {
                parsed.append(QuotaWindow(id: "7d", labelZH: "週", labelEN: "7d", percent: percent))
            }
        }

        let ids = Set(parsed.map(\.id))
        if !ids.contains("5h") {
            parsed.insert(QuotaWindow(id: "5h", labelZH: "5時", labelEN: "5h", percent: nil), at: 0)
        }
        if !ids.contains("7d") {
            parsed.append(QuotaWindow(id: "7d", labelZH: "週", labelEN: "7d", percent: nil))
        }

        return parsed.sorted { $0.id < $1.id }
    }

    private func quotaRemainingPercent(for profile: CodexProfile) -> Int? {
        if profile.quota == "unlimited" {
            return 100
        }
        return quotaPercents(from: profile.quota).min()
    }

    private func quotaAccent(for percent: Int?) -> Color {
        guard let percent else {
            return Color.gray
        }

        switch percent {
        case ...15:
            return Color(red: 0.88, green: 0.10, blue: 0.18)
        case ...45:
            return Color(red: 1.00, green: 0.40, blue: 0.34)
        case ...75:
            return Color(red: 0.62, green: 0.86, blue: 0.38)
        default:
            return Color(red: 0.04, green: 0.74, blue: 0.64)
        }
    }

    private func quotaProgressBar(percent: Int?, accent: Color, compact: Bool) -> some View {
        GeometryReader { geometry in
            let clamped = min(max(percent ?? 0, 0), 100)
            let fillWidth = geometry.size.width * CGFloat(clamped) / 100

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.66), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
            }
        }
        .frame(height: scaled(compact ? 8 : 9))
        .clipShape(Capsule())
    }

    private func quotaHelp(for profile: CodexProfile) -> String {
        let quotaText = profile.quota == "unknown" ? tr("用量未知", "Usage unknown") : profile.quota
        let resetText = profile.reset == "unknown" ? tr("重設時間未知", "Reset unknown") : profile.reset
        return "\(quotaText)\n\(resetText)"
    }

    private func quotaAccent(for profile: CodexProfile) -> Color {
        if profile.quota == "unlimited" {
            return Color(red: 0.04, green: 0.74, blue: 0.64)
        }
        return quotaAccent(for: quotaRemainingPercent(for: profile))
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
        let signedIn = profile.authStatus == "signed_in_local"
        let title = signedIn ? tr("打開", "Open") : tr("登入", "Log In")
        let accent = signedIn ? Color.cyan : Color.orange

        return Button {
            openAccount(profile.id, displayName: profile.displayName)
        } label: {
            Text(title)
                .font(.system(size: scaled(13), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .frame(maxWidth: .infinity)
                .frame(height: scaled(30))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.92))
        .background(
            Capsule()
                .fill(Color.black.opacity(0.34))
                .overlay(accent.opacity(0.10))
        )
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [accent.opacity(0.72), Color.white.opacity(0.16), accent.opacity(0.30)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: accent.opacity(0.16), radius: 8, x: 0, y: 3)
        .clipShape(Capsule())
        .keyboardShortcut(profile.id == "account1" ? "1" : "2", modifiers: [.command])
    }

    private func closeButton(_ profile: CodexProfile) -> some View {
        Button {
            closeAccount(profile)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: scaled(12), weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: scaled(30), height: scaled(30))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.72))
        .background(Color.white.opacity(0.08))
        .clipShape(Circle())
        .help(tr("關閉 \(profile.displayName)", "Close \(profile.displayName)"))
    }

    private func profileMenu(_ profile: CodexProfile) -> some View {
        Menu {
            Button(tr("關閉視窗", "Close Window")) { closeAccount(profile) }
            Button(tr("改名...", "Rename...")) { renameProfile(profile) }
            Button(tr("喺 Finder 顯示", "Reveal Profile Folder")) { revealProfile(profile) }
            Button(tr("共享對話紀錄", "Share History")) { shareHistory(profile) }
            Divider()
            Button(tr("刪除 Profile...", "Delete Profile..."), role: .destructive) { deleteProfile(profile) }
                .disabled(profile.id == "account1")
        } label: {
            HStack(spacing: scaled(3)) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: scaled(14), weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: scaled(8), weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.80))
            .frame(width: scaled(38), height: scaled(30))
            .contentShape(RoundedRectangle(cornerRadius: scaled(10), style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(tr("更多", "More"))
    }

    private func miniButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: scaled(11), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.vertical, scaled(6))
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.10))
        .foregroundStyle(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: scaled(8), style: .continuous))
    }

    private func glassIconButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: scaled(16), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: scaled(42), height: scaled(42))
                .contentShape(RoundedRectangle(cornerRadius: scaled(14), style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(14), style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(14), style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 6)
        .help(label)
    }

    private func sidebarToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: scaled(10)) {
            Text(title)
                .font(.system(size: scaled(12), weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: scaled(8))
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: scaled(48))
        }
    }

    private func refreshProfiles() {
        let accountsResult = runCodexScript(scriptPath, ["list-accounts"], wait: true)
        let statusResult = runCodexScript(scriptPath, ["list-accounts-status"], wait: true)
        guard accountsResult.0 == 0 else {
            statusText = tr("載入帳戶失敗", "Could not load accounts.")
            return
        }

        var statusByName: [String: [String]] = [:]
        if statusResult.0 == 0 {
            for line in statusResult.1.split(separator: "\n") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let name = parts.first {
                    statusByName[name] = parts
                }
            }
        }

        profiles = accountsResult.1
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
                return CodexProfile(
                    id: name,
                    displayName: display,
                    home: parts[1],
                    authStatus: status.count > 1 ? status[1] : "unknown",
                    authMode: status.count > 2 ? status[2] : "unknown",
                    lastRefresh: status.count > 3 ? status[3] : "unknown",
                    quota: status.count > 4 ? status[4] : "unknown",
                    reset: status.count > 5 ? status[5] : "unknown"
                )
            }
        statusText = tr("\(profiles.count) 個 profile 就緒", "\(profiles.count) profiles ready")
    }

    private func createAccount() {
        let defaultName = nextDefaultAccountName()
        guard let name = promptForAccountName(
            title: tr("新增帳戶", "New Account"),
            message: tr("可以直接用預設名，或者輸入你想要嘅 profile 名。", "Use the default name, or enter your own profile name."),
            defaultName: defaultName
        ) else { return }
        let result = runCodexScript(scriptPath, ["init-account", name], wait: true)
        guard result.0 == 0 else {
            alertMessage(tr("建立帳戶失敗", "Could Not Create Account"), result.1)
            return
        }
        displayNames[sanitizedProfileId(name)] = name
        UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
        refreshProfiles()
        openAccount(name, displayName: name)
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

    private func openAccount(_ name: String, displayName: String? = nil) {
        var arguments = ["launch-account", name]
        if let displayName, !displayName.isEmpty {
            arguments.append(displayName)
        }
        _ = runCodexScript(scriptPath, arguments)
        statusText = tr("已打開 \(displayName ?? name)", "Opened \(displayName ?? name)")
    }

    private func closeAccount(_ profile: CodexProfile) {
        let result = runCodexScript(scriptPath, ["close-account", profile.id], wait: true)
        statusText = result.0 == 0
            ? tr("已關閉 \(profile.displayName)", "Closed \(profile.displayName)")
            : tr("關閉失敗", "Close failed")
    }

    private func syncMemories(silent: Bool = false) {
        let result = runCodexScript(scriptPath, ["sync-once"], wait: true)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        if result.0 == 0 {
            lastAutoSync = time
            statusText = silent ? tr("已自動同步 \(time)", "Auto synced at \(time)") : tr("記憶已同步", "Memories synced")
        } else if !silent {
            statusText = tr("同步失敗", "Sync failed")
        }
    }

    private func shareAll() {
        let result = runCodexScript(scriptPath, ["link-all-history"], wait: true)
        statusText = result.0 == 0 ? tr("已同全部 profile 共享對話紀錄", "History shared with all profiles") : tr("共享失敗", "History share failed")
        refreshProfiles()
    }

    private func renameProfile(_ profile: CodexProfile) {
        guard let newName = promptForAccountName(title: tr("改名", "Rename Profile"), message: tr("輸入 \(profile.displayName) 嘅顯示名。", "Enter a display name for \(profile.displayName).")) else { return }
        displayNames[profile.id] = newName
        UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
        refreshProfiles()
        statusText = tr("已改名 \(profile.id)", "Renamed \(profile.id)")
    }

    private func revealProfile(_ profile: CodexProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.home)])
    }

    private func shareHistory(_ profile: CodexProfile) {
        let result = runCodexScript(scriptPath, ["link-history", profile.id], wait: true)
        statusText = result.0 == 0 ? tr("已同 \(profile.displayName) 共享對話紀錄", "History shared with \(profile.displayName)") : tr("共享失敗", "History share failed")
        refreshProfiles()
    }

    private func deleteProfile(_ profile: CodexProfile) {
        let alert = NSAlert()
        alert.messageText = tr("刪除 \(profile.displayName)？", "Delete \(profile.displayName)?")
        alert.informativeText = tr("會將本機登入資料同 app data 搬去 archive，唔係即刻永久刪除。Archive 位置：~/.codex-accounts-archive。", "This archives the profile's local login and app data so it disappears from this manager. The archive can be recovered from ~/.codex-accounts-archive.")
        alert.addButton(withTitle: tr("刪除 Profile", "Delete Profile"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = runCodexScript(scriptPath, ["delete-account", profile.id], wait: true)
        if result.0 == 0 {
            displayNames.removeValue(forKey: profile.id)
            UserDefaults.standard.set(displayNames, forKey: "profileDisplayNames")
            refreshProfiles()
            statusText = tr("已刪除 \(profile.displayName)", "Deleted \(profile.displayName)")
        } else {
            alertMessage(tr("刪除失敗", "Could Not Delete Profile"), result.1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var syncProcess: Process?
    private var window: NSWindow!

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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func appTr(_ zh: String, _ en: String) -> String {
        (UserDefaults.standard.string(forKey: "language") ?? "zh") == "zh" ? zh : en
    }

    @objc private func languageChanged() {
        window?.title = appTr("Codex 帳戶", "Codex Accounts")
        buildMainMenu()
        rebuildMenu()
    }

    @objc private func keepAwakeChanged() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        statusItem.button?.title = appTr("Codex 帳戶", "Codex Accounts")
        statusItem.button?.toolTip = appTr("Codex 帳戶", "Codex Accounts")

        let accounts = loadAccounts()
        if accounts.isEmpty {
            menu.addItem(disabledMenuItem(appTr("冇帳戶", "No accounts found")))
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
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("新增帳戶...", "New Account..."), action: #selector(newAccount), key: "n"))
        menu.addItem(menuItem(appTr("帳戶列表", "List Accounts"), action: #selector(listAccounts), key: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("同步記憶一次", "Sync Memories Once"), action: #selector(syncOnce), key: "s"))

        if syncProcess == nil {
            menu.addItem(menuItem(appTr("開始自動同步記憶", "Start Memory Sync Loop"), action: #selector(startSyncLoop), key: ""))
        } else {
            menu.addItem(menuItem(appTr("停止自動同步記憶", "Stop Memory Sync Loop"), action: #selector(stopSyncLoop), key: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("共享全部對話紀錄", "Share All History"), action: #selector(linkAllHistory), key: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(appTr("打開 Profile 資料夾", "Open Profiles Folder"), action: #selector(openProfilesFolder), key: "o"))
        menu.addItem(menuItem(appTr("打開 Script 資料夾", "Open Script Folder"), action: #selector(openScriptFolder), key: ""))
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
        appMenu.addItem(menuItem(appTr("切換防睡眠", "Toggle Keep Awake"), action: #selector(toggleKeepAwake), key: "k"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem(appTr("結束 Codex 帳戶", "Quit Codex Accounts"), action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

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

        for account in loadAccounts() {
            let item = NSMenuItem(title: appTr("打開 \(account.displayName)", "Open \(account.displayName)"), action: #selector(openAccountFromMenu(_:)), keyEquivalent: account.keyEquivalent)
            item.target = self
            item.representedObject = ["name": account.name, "displayName": account.displayName] as NSDictionary
            accountMenu.addItem(item)
        }

        accountMenu.addItem(NSMenuItem.separator())
        accountMenu.addItem(menuItem(appTr("新增帳戶...", "New Account..."), action: #selector(newAccount), key: "n"))
        accountMenu.addItem(menuItem(appTr("同步記憶一次", "Sync Memories Once"), action: #selector(syncOnce), key: "s"))
        accountMenu.addItem(menuItem(appTr("切換防睡眠", "Toggle Keep Awake"), action: #selector(toggleKeepAwake), key: "k"))
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
        window.contentView = NSHostingView(rootView: AccountsRootView(scriptPath: scriptPath))
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
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
        let result = runScript(["list-accounts"], wait: true)
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

    @discardableResult
    private func runScript(_ arguments: [String], wait: Bool = false) -> (Int32, String) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath] + arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            if wait {
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            }
            return (0, "")
        } catch {
            return (1, error.localizedDescription)
        }
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
        var arguments = ["launch-account", name]
        if let displayName, !displayName.isEmpty {
            arguments.append(displayName)
        }
        runScript(arguments)
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
        alert.informativeText = appTr("輸入 profile 名。", "Enter a profile name.")
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
        runScript(["launch-account", rawName, rawName])
    }

    @objc private func refreshWindow() {
        rebuildMenu()
        refreshMainAccountsMenu()
    }

    @objc private func showAccountsWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        showMessage(appTr("Codex 帳戶", "Codex Accounts"), appTr("多帳戶登入，共用本機紀錄。", "Separate logins. Shared local history."))
    }

    @objc private func listAccounts() {
        let result = runScript(["list-accounts"], wait: true)
        showMessage(appTr("Codex 帳戶", "Codex Accounts"), result.1.isEmpty ? appTr("冇帳戶輸出。", "No account output.") : result.1)
    }

    @objc private func syncOnce() {
        let result = runScript(["sync-once"], wait: true)
        showMessage(result.0 == 0 ? appTr("同步完成", "Sync Complete") : appTr("同步失敗", "Sync Failed"), result.1)
    }

    @objc private func startSyncLoop() {
        guard syncProcess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath, "sync-loop"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

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

    @objc private func toggleKeepAwake() {
        KeepAwakeController.shared.toggle()
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
        KeepAwakeController.shared.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncProcess?.terminate()
        KeepAwakeController.shared.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
