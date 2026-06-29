import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
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
    let reset: String?
}

private struct QuotaPoolRouteDecision {
    let requested: CodexProfile
    let target: CodexProfile
    let didSwitch: Bool
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
    let group = DispatchGroup()
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
        outputPipe.fileHandleForReading.readabilityHandler = nil
        return (127, error.localizedDescription)
    }

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        group.leave()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        process.terminate()
        if group.wait(timeout: .now() + 1.5) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = group.wait(timeout: .now() + 1.0)
        }
    }

    let processExited = !process.isRunning
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

private func runCodexScript(_ scriptPath: String, _ arguments: [String], wait: Bool = false, timeout: TimeInterval = 90) -> (Int32, String) {
    let processArguments = [scriptPath] + arguments
    if wait {
        return runProcess(executable: "/bin/zsh", arguments: processArguments, timeout: timeout)
    }
    return runDetachedProcess(executable: "/bin/zsh", arguments: processArguments)
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
}

private func profileWithCachedUsageFallback(_ profile: CodexProfile) -> CodexProfile {
    let quota = profile.quota.trimmingCharacters(in: .whitespacesAndNewlines)
    guard profile.authStatus != "login_needed" else {
        return profile
    }
    guard quota.isEmpty || quota == "unknown",
          let cachedUsage = cachedUsage(for: profile.id)
    else {
        return profile
    }

    return CodexProfile(
        id: profile.id,
        displayName: profile.displayName,
        home: profile.home,
        authStatus: profile.authStatus,
        authMode: profile.authMode,
        lastRefresh: profile.lastRefresh,
        quota: cachedUsage.quota,
        reset: cachedUsage.reset
    )
}

private func cachedUsage(for profileID: String) -> (quota: String, reset: String)? {
    let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Accounts/.usage-cache-v5")
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

    return (parts[0], parts[1].isEmpty ? "unknown" : parts[1])
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

private func promptForRemoteUserCredentials() -> (username: String, password: String)? {
    let language = UserDefaults.standard.string(forKey: "language") ?? "zh"
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = language == "zh" ? "新增手機登入帳號" : "New Mobile Login"
    alert.informativeText = language == "zh"
        ? "喺呢部 Mac 建立一個 username/password。手機要用同一組資料登入先可以控制 Codex。"
        : "Create a username/password on this Mac. The Android app must sign in with the same credentials before it can control Codex."
    alert.addButton(withTitle: language == "zh" ? "建立" : "Create")
    alert.addButton(withTitle: language == "zh" ? "取消" : "Cancel")

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 300, height: 62)

    let usernameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
    usernameField.placeholderString = "username"
    let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
    passwordField.placeholderString = language == "zh" ? "密碼，至少 10 個字元" : "Password, at least 10 characters"

    stack.addArrangedSubview(usernameField)
    stack.addArrangedSubview(passwordField)
    alert.accessoryView = stack

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = passwordField.stringValue
    guard !username.isEmpty, password.count >= 10 else {
        alertMessage(
            language == "zh" ? "帳號資料不完整" : "Invalid Login",
            language == "zh" ? "Username 唔可以留空，密碼至少要 10 個字元。" : "Username cannot be empty and password must be at least 10 characters."
        )
        return nil
    }
    return (username, password)
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

    private var caffeinateProcess: Process?
    private var jiggleTimer: Timer?
    private var clamshellTimer: Timer?
    private var stateMonitorTimer: Timer?
    private var storedBrightnessBeforeLidClose: Float?
    private var dimmedForClosedLid = false
    private let pidFileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Codex Quota Pool/keep-awake.pid")

    private init() {
        recoverExistingCaffeinate()
        startStateMonitor()
    }

    func refreshState() {
        DispatchQueue.global(qos: .utility).async {
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
            let language = UserDefaults.standard.string(forKey: "language") ?? "zh"
            alertMessage(language == "zh" ? "防睡眠啟動失敗" : "Keep Awake Failed", error.localizedDescription)
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
        refreshState()
    }

    private func startStateMonitor() {
        DispatchQueue.main.async {
            self.stateMonitorTimer?.invalidate()
            self.stateMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
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
    @State private var profiles: [CodexProfile] = []
    @State private var statusText = "就緒"
    @AppStorage("autoRefresh") private var autoRefresh = true
    @AppStorage("autoSync") private var autoSync = true
    @AppStorage("autoQuotaPool") private var autoQuotaPool = true
    @AppStorage("language") private var language = "zh"
    @State private var displayNames: [String: String] = UserDefaults.standard.dictionary(forKey: "profileDisplayNames") as? [String: String] ?? [:]
    @State private var lastAutoSync = ""
    @State private var layoutScale: CGFloat = 1
    @State private var visibleContentSize: CGSize = .zero
    @State private var activeOperationCount = 0
    @State private var loadingMessage = ""
    @State private var isRefreshing = false
    @State private var isSyncing = false
    @State private var hasEntered = false
    @State private var showKeepAwakeHelp = false
    @State private var showSyncHelp = false
    @State private var busyProfiles: Set<String> = []
    @State private var expandedResetKeys: Set<String> = []
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showIntro = false
    @State private var iconVersion = 0
    @State private var pendingSectionScroll: String?
    @State private var quotaReplayActive = false
    @State private var resetScrambleActive = false
    @State private var resetScrambleSeed = 0
    @State private var codexUsageSessionStart: Date?
    @State private var usageTicker = Date()
    @State private var remoteBridgeProcess: Process?
    @State private var remoteBridgeRunning = false
    @State private var remoteBridgeUsersCount = 0
    @State private var remoteBridgeStatus = ""
    @State private var remoteBridgeLastOutput = ""
    @State private var activeQuotaPoolProfileID: String?
    @State private var quotaPoolFailoverInProgress = false
    @AppStorage("codexUsageDayKey") private var codexUsageDayKey = ""
    @AppStorage("codexUsageSecondsToday") private var codexUsageSecondsToday = 0.0
    @AppStorage("appTheme") private var appTheme = "graphite"

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
        }
        .frame(minWidth: 860, minHeight: 560)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: sidebarCollapsed)
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
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                hasEntered = true
            }
            if !hasSeenIntro {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    showIntro = true
                    hasSeenIntro = true
                }
            }
            keepAwake.refreshState()
            refreshRemoteBridgeState()
            refreshProfiles(showLoading: true)
        }
        .sheet(isPresented: $showIntro) {
            introView
        }
        .onChange(of: language) { _, _ in
            NotificationCenter.default.post(name: Notification.Name("CodexAccountsLanguageChanged"), object: nil)
        }
        .onReceive(timer) { _ in
            if autoRefresh {
                refreshProfiles(showLoading: false)
            }
            if autoSync {
                syncMemories(silent: true)
            }
            keepAwake.refreshState()
            refreshRemoteBridgeState()
            usageTicker = Date()
            normalizeUsageDay()
        }
    }

    private func tr(_ zh: String, _ en: String) -> String {
        language == "zh" ? zh : en
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        (value * layoutScale).rounded()
    }

    private var profileHoverPadding: CGFloat {
        scaled(12)
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
        switch appTheme {
        case "aurora": return tr("極光", "Aurora")
        case "amber": return tr("琥珀", "Amber")
        case "violet": return tr("紫晶", "Violet")
        default: return tr("石墨", "Graphite")
        }
    }

    private var themePrimary: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.02, green: 0.78, blue: 0.72)
        case "amber": return Color(red: 1.00, green: 0.58, blue: 0.16)
        case "violet": return Color(red: 0.62, green: 0.42, blue: 1.00)
        default: return Color(red: 0.22, green: 0.74, blue: 1.00)
        }
    }

    private var themeSecondary: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.22, green: 0.95, blue: 0.48)
        case "amber": return Color(red: 1.00, green: 0.76, blue: 0.20)
        case "violet": return Color(red: 0.30, green: 0.84, blue: 1.00)
        default: return Color(red: 0.00, green: 0.92, blue: 0.78)
        }
    }

    private var themeWarm: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.18, green: 0.50, blue: 1.00)
        case "amber": return Color(red: 0.88, green: 0.22, blue: 0.10)
        case "violet": return Color(red: 0.94, green: 0.30, blue: 0.64)
        default: return Color(red: 0.82, green: 0.20, blue: 0.12)
        }
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
        default: return Color(red: 0.06, green: 0.18, blue: 0.24)
        }
    }

    private var themeSidebarTint: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.00, green: 0.34, blue: 0.29)
        case "amber": return Color(red: 0.38, green: 0.15, blue: 0.05)
        case "violet": return Color(red: 0.24, green: 0.10, blue: 0.38)
        default: return Color(red: 0.04, green: 0.11, blue: 0.16)
        }
    }

    private var themeRowTint: Color {
        switch appTheme {
        case "aurora": return Color(red: 0.00, green: 0.62, blue: 0.48)
        case "amber": return Color(red: 0.92, green: 0.40, blue: 0.10)
        case "violet": return Color(red: 0.56, green: 0.25, blue: 0.88)
        default: return Color(red: 0.08, green: 0.34, blue: 0.46)
        }
    }

    private var activeProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { !isLoginNeeded($0) && !isWaitingForRecovery($0) })
    }

    private var loginProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { isLoginNeeded($0) })
    }

    private var waitingProfiles: [CodexProfile] {
        sortedProfileList(profiles.filter { !isLoginNeeded($0) && isWaitingForRecovery($0) })
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

    private func isWaitingForRecovery(_ profile: CodexProfile) -> Bool {
        quotaWindows(for: profile).contains { $0.id == "7d" && $0.percent == 0 }
    }

    private func isSignedIn(_ profile: CodexProfile) -> Bool {
        profile.authStatus == "signed_in_local"
    }

    private func isLoginNeeded(_ profile: CodexProfile) -> Bool {
        profile.authStatus == "login_needed" || profile.authStatus == "auth_incomplete"
    }

    private func isVisiblySignedIn(_ profile: CodexProfile) -> Bool {
        isSignedIn(profile) || (!isLoginNeeded(profile) && profile.quota != "unknown")
    }

    private func mergedAuthStatus(previous: String, current: String) -> String {
        if current == "signed_in_local" {
            return current
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
                    Text(tr("多帳戶登入，共用本機 Codex 紀錄。", "Separate logins with shared local Codex history."))
                        .font(appFont(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: scaled(11)) {
                introPoint("1.circle.fill", tr("撳右上角 + 新增 profile，逐個登入唔同 GPT 帳戶。", "Use + to add profiles, then log each one into a different GPT account."))
                introPoint("2.circle.fill", tr("切換帳戶前，先撳右上角紅色關閉全部，再打開你要用嗰個 profile。", "Before switching accounts, press the red close-all button, then open the profile you want."))
                introPoint("3.circle.fill", tr("卡片中間會顯示 5H / 1W / 1M 用量；紅色代表等待恢復。", "The card shows 5H / 1W / 1M usage; red means it is waiting for reset."))
                introPoint("4.circle.fill", tr("頂部三段掣可以快速跳去：已登入、未登入、等待恢復。", "The segmented control jumps to Signed in, Login needed, and Waiting sections."))
                introPoint("5.circle.fill", tr("立即同步會同步本機記憶；共享全部會令所有 profile 共用同一份本機對話紀錄。", "Sync now syncs local memories; Share all links every profile to one local chat history."))
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
                    Text(tr("Codex Quota Pool", "Codex Quota Pool"))
                        .font(appFont(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(tr("多帳戶登入，共用本機紀錄。", "Separate logins. Shared local history."))
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
        HStack(spacing: scaled(3)) {
            languageButton("中文", flag: "🇭🇰", tag: "zh", accent: Color(red: 0.08, green: 0.55, blue: 1.00))
            languageButton("EN", flag: "🇺🇸", tag: "en", accent: Color(red: 0.56, green: 0.42, blue: 1.00))
        }
        .padding(scaled(4))
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.045))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageButton(_ title: String, flag: String, tag: String, accent: Color) -> some View {
        let selected = language == tag

        return Button {
            guard language != tag else { return }
            showEphemeralLoading(language == "zh" ? "Switching language..." : "切換語言...", duration: 0.34)
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                language = tag
            }
        } label: {
            HStack(spacing: scaled(4)) {
                Text(flag)
                    .font(.system(size: scaled(11)))
                Text(title)
                    .font(appFont(size: 11, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: scaled(54), height: scaled(28))
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.90, hoverScale: 1.045, glow: accent, glowOpacity: 0.26))
        .foregroundStyle(selected ? .white : .white.opacity(0.68))
        .background(selected ? accent : Color.white.opacity(0.06))
        .clipShape(Capsule())
        .shadow(color: selected ? accent.opacity(0.22) : .clear, radius: 8, x: 0, y: 4)
    }

    private var sidebarSettings: some View {
        VStack(alignment: .leading, spacing: scaled(9)) {
            VStack(alignment: .leading, spacing: scaled(8)) {
                HStack(spacing: scaled(6)) {
                    Text(tr("自動化", "Automation"))
                        .font(appFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.66))
                    syncInfoIcon
                    Spacer(minLength: 0)
                }

                sidebarToggle(tr("每分鐘重新整理", "Auto refresh"), isOn: $autoRefresh, tint: Color(red: 0.20, green: 0.64, blue: 1.00))
                sidebarToggle(tr("每分鐘同步記憶", "Auto sync"), isOn: $autoSync, tint: Color(red: 0.20, green: 0.64, blue: 1.00))
                sidebarToggle(tr("自動換 quota", "Auto quota switch"), isOn: $autoQuotaPool, tint: Color(red: 0.00, green: 0.88, blue: 0.72))

                HStack(spacing: scaled(8)) {
                    miniButton(tr("立即同步", "Sync now")) { syncMemories() }
                    miniButton(tr("共享全部", "Share all")) { shareAll() }
                }

                Text(tr("上次同步：\(lastAutoSyncLabel)", "Last sync: \(lastAutoSyncLabel)"))
                    .font(appFont(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Divider().background(Color.white.opacity(0.12))

            remoteBridgePanel

            Divider().background(Color.white.opacity(0.12))

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
                        .foregroundStyle(keepAwake.isAwake ? Color(red: 0.00, green: 0.95, blue: 0.48) : Color(red: 1.00, green: 0.16, blue: 0.20))
                        .lineLimit(1)
                }

                Spacer(minLength: scaled(8))

                keepAwakeGlassButton
            }

            Divider().background(Color.white.opacity(0.12))

            dailyUsagePanel

            Divider().background(Color.white.opacity(0.12))

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

    private var keepAwakeHelpText: String {
        tr(
            "防止 Mac 自動睡眠。打開後合蓋會盡量保持任務運行，內置屏幕亮度會降到 0；開蓋或關閉功能會恢復亮度。",
            "Prevents Mac sleep. When enabled, closing the lid keeps tasks running where macOS allows it and dims the built-in display to 0; opening the lid or turning this off restores brightness."
        )
    }

    private var remoteBridgePanel: some View {
        let running = remoteBridgeRunning
        let accent = running ? Color(red: 0.00, green: 0.92, blue: 0.70) : Color(red: 1.00, green: 0.58, blue: 0.16)
        let stateText = running ? tr("已啟動", "Running") : tr("未啟動", "Stopped")
        let userText = tr("\(remoteBridgeUsersCount) 個手機帳號", "\(remoteBridgeUsersCount) mobile users")

        return VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(6)) {
                Text(tr("手機遠端", "Mobile Remote"))
                    .font(appFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                Spacer(minLength: scaled(8))
                HStack(spacing: scaled(4)) {
                    Circle()
                        .fill(accent)
                        .frame(width: scaled(7), height: scaled(7))
                    Text(stateText)
                        .font(appFont(size: 10, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: scaled(3)) {
                Text(userText)
                    .font(appFont(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)

                Text(remoteBridgeURLLabel)
                    .font(appFont(size: 10, weight: .medium, monospaced: true))
                    .foregroundStyle(Color(red: 0.32, green: 0.86, blue: 1.00).opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: scaled(8)) {
                miniButton(running ? tr("停止 Bridge", "Stop Bridge") : tr("啟動 Bridge", "Start Bridge")) {
                    running ? stopRemoteBridge() : startRemoteBridge()
                }
                miniButton(tr("新增登入", "Add Login")) {
                    createRemoteBridgeUser()
                }
            }

            if !remoteBridgeStatus.isEmpty {
                Text(remoteBridgeStatus)
                    .font(appFont(size: 10))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var keepAwakeGlassButton: some View {
        let active = keepAwake.isAwake
        let accent = active ? Color(red: 0.00, green: 0.95, blue: 0.48) : Color(red: 1.00, green: 0.16, blue: 0.20)

        return Button {
            keepAwake.toggle()
        } label: {
            HStack(spacing: scaled(6)) {
                Image(systemName: active ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: scaled(12), weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(active ? "ON" : "OFF")
                    .font(appFont(size: 10, weight: .heavy, monospaced: true))
                    .monospacedDigit()
            }
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.82))
            .frame(width: scaled(62), height: scaled(30))
            .background(.ultraThinMaterial)
            .background(
                LinearGradient(
                    colors: [accent.opacity(active ? 0.34 : 0.22), Color.white.opacity(0.040)],
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
        .help(keepAwakeHelpText)
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

            Menu {
                Button(tr("石墨玻璃", "Graphite Glass")) { setTheme("graphite") }
                Button(tr("極光玻璃", "Aurora Glass")) { setTheme("aurora") }
                Button(tr("琥珀玻璃", "Amber Glass")) { setTheme("amber") }
                Button(tr("紫晶玻璃", "Violet Glass")) { setTheme("violet") }
            } label: {
                HStack(spacing: scaled(6)) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [themePrimary, themeSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: scaled(9), height: scaled(9))
                    Text(tr("主題：\(themeTitle)", "Theme: \(themeTitle)"))
                        .font(appFont(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: scaled(8), weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.66))
                .padding(.horizontal, scaled(8))
                .padding(.vertical, scaled(5))
                .background(.ultraThinMaterial)
                .background(themePrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: scaled(8), style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(PressScaleButtonStyle(scale: 0.92, hoverScale: 1.035, glow: themePrimary, glowOpacity: 0.16))
        }
    }

    private func setTheme(_ theme: String) {
        showEphemeralLoading(tr("切換主題...", "Switching theme..."), duration: 0.30)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            appTheme = theme
        }
    }

    private var syncHelpText: String {
        tr(
            "立即同步：同步本機記憶檔案。\n\n共享全部：將所有 profile 連到同一份本機對話紀錄。",
            "Sync now: syncs local memory files.\n\nShare all: links every profile to the same local chat history."
        )
    }

    private var syncInfoIcon: some View {
        infoIcon(isPresented: $showSyncHelp, text: syncHelpText, width: 260)
    }

    private var keepAwakeInfoIcon: some View {
        infoIcon(isPresented: $showKeepAwakeHelp, text: keepAwakeHelpText, width: 238)
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
            let titleWidth = scaled(compact ? 170 : 300)

            ZStack {
                sectionJumpControls(compact: compact)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, scaled(compact ? 174 : 216))

                HStack(alignment: .center, spacing: scaled(compact ? 10 : 14)) {
                    sidebarToggleButton

                    headerTitle
                        .frame(width: titleWidth, alignment: .leading)
                        .layoutPriority(1)

                    Spacer(minLength: scaled(12))

                    headerActions(compact: compact)
                        .layoutPriority(5)
                }
                .padding(.trailing, profileRightAlignmentInset)
            }
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
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func headerActions(compact: Bool) -> some View {
        HStack(spacing: scaled(compact ? 8 : 12)) {
            glassIconButton(systemName: "plus", label: tr("新增帳戶", "New Account"), compact: compact, accent: Color(red: 0.34, green: 0.78, blue: 1.00)) {
                createAccount()
            }

            glassIconButton(systemName: "arrow.clockwise", label: tr("重新整理", "Refresh"), compact: compact, accent: Color(red: 0.24, green: 0.95, blue: 0.78)) {
                refreshProfiles(showLoading: true, replayQuota: true)
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
                .font(.system(size: scaled(compact ? 14 : 16), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: scaled(compact ? 38 : 48), height: scaled(34))
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
        LazyVStack(spacing: scaled(7)) {
            sectionHeader(
                id: "section-active",
                systemName: "checkmark.circle.fill",
                title: tr("已登入", "Signed in"),
                accent: Color(red: 0.16, green: 0.92, blue: 0.62)
            )
            .padding(.top, scaled(2))

            ForEach(activeProfiles) { profile in
                profileRow(profile)
            }

            sectionHeader(
                id: "section-login",
                systemName: "person.crop.circle.badge.exclamationmark",
                title: tr("未登入", "Login needed"),
                accent: Color(red: 1.00, green: 0.55, blue: 0.12)
            )
            .padding(.top, scaled(activeProfiles.isEmpty ? 3 : 9))

            ForEach(loginProfiles) { profile in
                profileRow(profile)
            }

            sectionHeader(
                id: "section-waiting",
                systemName: "clock.arrow.circlepath",
                title: tr("等待恢復", "Waiting for Reset"),
                accent: Color(red: 1.00, green: 0.74, blue: 0.20)
            )
            .padding(.top, scaled(loginProfiles.isEmpty ? 3 : 9))

            ForEach(waitingProfiles) { profile in
                profileRow(profile)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.leading, profileHoverPadding)
        .padding(.trailing, profileHoverPadding)
        .padding(.top, 4)
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

    private func profileRow(_ profile: CodexProfile) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let veryCompact = width < 620
            let compactQuota = width < 920
            let rowSpacing = scaled(veryCompact ? 4 : 10)
            let titleMinWidth = scaled(veryCompact ? 28 : 88)
            let quotaWidth = scaled(width < 640 ? 230 : (width < 920 ? 276 : 330))
            let openWidth = scaled(veryCompact ? 56 : 64)
            let closeWidth = scaled(veryCompact ? 28 : 30)
            let menuWidth = scaled(veryCompact ? 26 : 30)
            let rowHeight = geometry.size.height

            HStack(spacing: rowSpacing) {
                profileBadge(profile)
                    .layoutPriority(20)

                profileTitleBlock(profile, showsPath: true)
                    .frame(minWidth: titleMinWidth, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                Spacer(minLength: scaled(4))

                quotaMeter(profile, compact: compactQuota)
                    .frame(width: quotaWidth, alignment: .trailing)
                    .layoutPriority(30)

                openButton(profile)
                    .frame(width: openWidth)
                    .layoutPriority(20)

                closeButton(profile)
                    .frame(width: closeWidth)
                    .layoutPriority(20)

                profileMenu(profile)
                    .frame(width: menuWidth)
                    .layoutPriority(20)
            }
            .padding(.horizontal, scaled(veryCompact ? 10 : 14))
            .frame(width: geometry.size.width, height: rowHeight, alignment: .center)
        }
        .frame(maxWidth: .infinity, minHeight: scaled(64), idealHeight: scaled(64), maxHeight: scaled(64), alignment: .leading)
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
        .shadow(color: profileRowAccent(for: profile).opacity(profile.quota == "unknown" ? 0.08 : 0.14), radius: 10, x: 0, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .modifier(HoverLiftGlow(glow: profileRowAccent(for: profile), scale: 1.006, opacity: 0.28, radius: 16, y: 3))
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: profile.quota)
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
        _ = iconVersion
        if let customImage = NSImage(contentsOf: customIconURL(for: profile.id)) {
            return customImage
        }
        let resourceName = "ProfileIcon-\(profileBadgeLetter(for: profile) ?? "Default")"
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png", subdirectory: "ProfileLetterIcons"),
           let image = NSImage(contentsOf: url) {
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
        let signedIn = isSignedIn(profile)
        let title = signedIn
            ? tr("已登入", "Signed in")
            : (compact ? tr("要登入", "Login") : tr("要登入", "Login needed"))
        let color = signedIn ? Color(red: 0.32, green: 0.96, blue: 0.46) : Color.orange

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

    private func quotaMeter(_ profile: CodexProfile, compact: Bool) -> some View {
        let rows = quotaRows(for: quotaWindows(for: profile))
        let weeklyZero = rows.contains { $0.id == "7d" && $0.percent == 0 }
        let weeklyReset = rows.first { $0.id == "7d" }?.reset

        return VStack(spacing: scaled(5)) {
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
        .frame(maxWidth: .infinity, minHeight: scaled(44), alignment: .center)
    }

    private func quotaMeterLine(_ window: QuotaWindow, profile: CodexProfile, accent: Color, compact: Bool, blockedByWeeklyZero: Bool = false, forcedReset: String? = nil) -> some View {
        let resetText = blockedByWeeklyZero
            ? clockResetText(from: forcedReset)
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
        default: return 2
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

    private func resetCaption(_ reset: String?, windowID: String, profileID: String) -> String {
        let text = shortResetText(reset)
        guard text != "--" else { return text }
        if resetScrambleActive {
            return scrambledResetText(windowID: windowID, profileID: profileID)
        }

        if windowID == "5h" {
            return clockResetText(from: text)
        }

        let key = "\(profileID):\(windowID)"
        if expandedResetKeys.contains(key) {
            return relativeResetText(from: text)
        }
        return weeklyResetText(from: text)
    }

    private func scrambledResetText(windowID: String, profileID: String) -> String {
        let step = max(0, 10 - resetScrambleSeed)
        let base = abs(profileID.unicodeScalars.reduce(step * 31) { $0 + Int($1.value) })
        if windowID == "5h" {
            return String(format: "%02d:%02d", min(step * 2, 23), min(step * 6, 59))
        }
        if step == 0 {
            return "00/00"
        }
        return String(format: "%02d/%02d", max(1, step), max(1, min(28, step * 3 + base % 4)))
    }

    private func replayPercent(_ percent: Int?) -> Int? {
        guard let percent else { return nil }
        guard quotaReplayActive else { return percent }
        let step = max(0, 10 - resetScrambleSeed)
        return min(max(Int((Double(percent) * Double(step) / 10.0).rounded()), 0), 100)
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
        formatter.locale = Locale(identifier: language == "zh" ? "zh_Hant_HK" : "en_US_POSIX")
        formatter.dateFormat = language == "zh" ? "M月d日 HH:mm" : "MMM d, HH:mm"
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

    private func quotaRemainingPercent(for profile: CodexProfile) -> Int? {
        if profile.quota == "unlimited" {
            return 100
        }
        return quotaPercents(from: profile.quota).min()
    }

    private func isQuotaPoolCandidate(_ profile: CodexProfile) -> Bool {
        isVisiblySignedIn(profile) && !isLoginNeeded(profile) && quotaPoolScore(for: profile) > 0
    }

    private func isQuotaDepleted(_ profile: CodexProfile) -> Bool {
        guard profile.quota != "unlimited", profile.quota != "unknown" else { return false }
        return (quotaRemainingPercent(for: profile) ?? 0) <= 0
    }

    private func quotaPoolScore(for profile: CodexProfile) -> Int {
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

    private func quotaPoolRoute(for requestedID: String) -> QuotaPoolRouteDecision? {
        guard let requested = profiles.first(where: { $0.id == requestedID }) else {
            return nil
        }
        guard autoQuotaPool,
              isVisiblySignedIn(requested),
              isQuotaDepleted(requested),
              let target = bestQuotaPoolProfile(excluding: requested.id)
        else {
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
        let depleted = profile.quota != "unknown" && !hasQuota
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
    }

    private func profileMenu(_ profile: CodexProfile) -> some View {
        Menu {
            Button(tr("關閉視窗", "Close Window")) { closeAccount(profile) }
            Button(tr("改名...", "Rename...")) { renameProfile(profile) }
            Button(tr("自訂 Icon...", "Custom Icon...")) { chooseCustomIcon(for: profile) }
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
        .buttonStyle(PressScaleButtonStyle(scale: 0.86, hoverScale: 1.08, glow: Color.white, glowOpacity: 0.18))
        .help(tr("更多", "More"))
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

    private func glassIconButton(systemName: String, label: String, danger: Bool = false, compact: Bool = false, accent customAccent: Color? = nil, action: @escaping () -> Void) -> some View {
        let accent = customAccent ?? (danger ? Color(red: 1.00, green: 0.22, blue: 0.18) : Color.white)
        let side = scaled(compact ? 36 : 42)
        let radius = scaled(compact ? 12 : 14)

        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: scaled(compact ? 15 : 16), weight: .semibold))
                .symbolRenderingMode(.hierarchical)
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
        let side = scaled(compact ? 36 : 42)
        let radius = scaled(compact ? 12 : 14)

        return Button(action: action) {
            ZStack {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: scaled(compact ? 14 : 15), weight: .semibold))
                    .offset(x: scaled(-1), y: scaled(-1))

                Image(systemName: "xmark")
                    .font(.system(size: scaled(compact ? 15 : 16), weight: .heavy))
                    .offset(x: scaled(5), y: scaled(5))
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
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(tint)
                .frame(width: scaled(48), height: scaled(30))
        }
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

        DispatchQueue.global(qos: .userInitiated).async {
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

    private var remoteBridgePort: Int {
        47621
    }

    private var remoteBridgeURLLabel: String {
        "http://\(localIPAddress()):\(remoteBridgePort)"
    }

    private var remoteBridgeScriptPath: String {
        if let bundled = Bundle.main.path(forResource: "codex_remote_bridge", ofType: "py") {
            return bundled
        }
        let sibling = URL(fileURLWithPath: scriptPath)
            .deletingLastPathComponent()
            .appendingPathComponent("codex_remote_bridge.py")
            .path
        if FileManager.default.fileExists(atPath: sibling) {
            return sibling
        }
        return "/Applications/Codex Quota Pool.app/Contents/Resources/codex_remote_bridge.py"
    }

    private var remoteBridgeStartScriptPath: String {
        if let bundled = Bundle.main.path(forResource: "start_mac_bridge", ofType: "zsh") {
            return bundled
        }
        let sibling = URL(fileURLWithPath: scriptPath)
            .deletingLastPathComponent()
            .appendingPathComponent("start_mac_bridge.zsh")
            .path
        if FileManager.default.fileExists(atPath: sibling) {
            return sibling
        }
        return "/Applications/Codex Quota Pool.app/Contents/Resources/start_mac_bridge.zsh"
    }

    private var remoteBridgePIDFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Codex Quota Pool", isDirectory: true)
            .appendingPathComponent("remote-bridge.pid")
    }

    private func runRemoteBridgeUtility(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 12) -> (Int32, String) {
        runProcess(
            executable: "/usr/bin/python3",
            arguments: [remoteBridgeScriptPath, "--script", scriptPath] + arguments,
            input: input,
            timeout: timeout
        )
    }

    private func startRemoteBridge() {
        refreshRemoteBridgeState()
        guard !remoteBridgeRunning else {
            remoteBridgeStatus = tr("Bridge 已經運行緊", "Bridge is already running")
            return
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [remoteBridgeStartScriptPath]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_ACCOUNTS_SCRIPT"] = scriptPath
        environment["CODEX_REMOTE_BRIDGE"] = remoteBridgeScriptPath
        environment["CODEX_REMOTE_PORT"] = "\(remoteBridgePort)"
        environment["CODEX_REMOTE_PID_FILE"] = remoteBridgePIDFileURL.path
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            DispatchQueue.main.async {
                remoteBridgeLastOutput += text
                let lines = remoteBridgeLastOutput
                    .split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let last = lines.last {
                    remoteBridgeStatus = last
                }
            }
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if let current = remoteBridgeProcess, current === process {
                    remoteBridgeProcess = nil
                }
                refreshRemoteBridgeState()
            }
        }

        do {
            try process.run()
            remoteBridgeProcess = process
            remoteBridgeRunning = true
            remoteBridgeStatus = tr("Bridge 啟動中...", "Bridge starting...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                refreshRemoteBridgeState()
            }
        } catch {
            remoteBridgeStatus = error.localizedDescription
            alertMessage(tr("Bridge 啟動失敗", "Bridge Start Failed"), error.localizedDescription)
        }
    }

    private func stopRemoteBridge() {
        remoteBridgeProcess?.terminate()
        remoteBridgeProcess = nil
        if let pid = readRemoteBridgePID(), isProcessRunning(pid: pid) {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
        removeRemoteBridgePIDIfStale()
        remoteBridgeRunning = false
        remoteBridgeStatus = tr("Bridge 已停止", "Bridge stopped")
    }

    private func createRemoteBridgeUser() {
        guard let credentials = promptForRemoteUserCredentials() else { return }
        let payload: [String: String] = [
            "username": credentials.username,
            "password": credentials.password
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            alertMessage(tr("帳號建立失敗", "Could Not Create Login"), tr("無法建立登入 payload。", "Could not create login payload."))
            return
        }

        runBackground(tr("建立手機登入帳號...", "Creating mobile login...")) {
            runRemoteBridgeUtility(["--create-user-stdin"], input: data)
        } completion: { result in
            guard result.0 == 0 else {
                alertMessage(tr("帳號建立失敗", "Could Not Create Login"), result.1)
                refreshRemoteBridgeState()
                return
            }
            remoteBridgeStatus = tr("已建立手機登入帳號 \(credentials.username)", "Created mobile login \(credentials.username)")
            refreshRemoteBridgeState()
        }
    }

    private func refreshRemoteBridgeState() {
        let processRunning = remoteBridgeProcess?.isRunning == true
        let pidRunning = readRemoteBridgePID().map { isProcessRunning(pid: $0) } ?? false
        remoteBridgeRunning = processRunning || pidRunning
        if !remoteBridgeRunning {
            removeRemoteBridgePIDIfStale()
        }

        DispatchQueue.global(qos: .utility).async {
            let result = runRemoteBridgeUtility(["--list-users"], timeout: 8)
            DispatchQueue.main.async {
                guard result.0 == 0,
                      let data = result.1.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let users = json["users"] as? [Any]
                else {
                    remoteBridgeUsersCount = 0
                    if !result.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        remoteBridgeStatus = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return
                }
                remoteBridgeUsersCount = users.count
            }
        }
    }

    private func readRemoteBridgePID() -> Int32? {
        guard let text = try? String(contentsOf: remoteBridgePIDFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else {
            return nil
        }
        return pid
    }

    private func isProcessRunning(pid: Int32) -> Bool {
        Darwin.kill(pid_t(pid), 0) == 0
    }

    private func removeRemoteBridgePIDIfStale() {
        guard let pid = readRemoteBridgePID(), !isProcessRunning(pid: pid) else { return }
        try? FileManager.default.removeItem(at: remoteBridgePIDFileURL)
    }

    private func localIPAddress() -> String {
        let addresses = Host.current().addresses
        if let address = addresses.first(where: { candidate in
            candidate.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
                && !candidate.hasPrefix("127.")
                && !candidate.hasPrefix("169.254.")
        }) {
            return address
        }
        return "127.0.0.1"
    }

    private func refreshProfiles(showLoading: Bool = true, replayQuota: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if replayQuota {
            startResetScramble()
            withAnimation(.easeOut(duration: 0.18)) {
                quotaReplayActive = true
            }
        }
        let displayNamesSnapshot = displayNames
        let hadProfiles = !profiles.isEmpty
        let loading = showLoading && hadProfiles ? tr("重新整理帳戶...", "Refreshing accounts...") : nil

        runBackground(loading) {
            let accountsResult = runCodexScript(scriptPath, ["list-accounts"], wait: true)
            return accountsResult
        } completion: { result in
            guard result.0 == 0 else {
                isRefreshing = false
                statusText = tr("載入帳戶失敗", "Could not load accounts.")
                return
            }
            let discoveredProfiles = parsedCodexProfiles(
                accountsOutput: result.1,
                statusOutput: "",
                displayNames: displayNamesSnapshot
            )
            let previousByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            profiles = discoveredProfiles.map { profile in
                let cachedProfile = profileWithCachedUsageFallback(profileWithLocalAuthTokenFallback(profile))
                guard let previous = previousByID[profile.id] else {
                    return CodexProfile(
                        id: cachedProfile.id,
                        displayName: cachedProfile.displayName,
                        home: cachedProfile.home,
                        authStatus: cachedProfile.authStatus == "unknown" ? "checking" : cachedProfile.authStatus,
                        authMode: "checking",
                        lastRefresh: cachedProfile.lastRefresh,
                        quota: cachedProfile.quota,
                        reset: cachedProfile.reset
                    )
                }
                return CodexProfile(
                    id: cachedProfile.id,
                    displayName: cachedProfile.displayName,
                    home: cachedProfile.home,
                    authStatus: mergedAuthStatus(previous: previous.authStatus, current: cachedProfile.authStatus),
                    authMode: cachedProfile.authMode == "unknown" || cachedProfile.authMode == "checking" ? previous.authMode : cachedProfile.authMode,
                    lastRefresh: previous.lastRefresh,
                    quota: previous.quota == "unknown" ? cachedProfile.quota : previous.quota,
                    reset: previous.reset == "unknown" ? cachedProfile.reset : previous.reset
                )
            }
            statusText = tr("\(profiles.count) 個 profile 就緒", "\(profiles.count) profiles ready")
            refreshProfileStatuses(
                accountsOutput: result.1,
                displayNamesSnapshot: displayNamesSnapshot,
                showLoading: showLoading && hadProfiles,
                replayQuota: replayQuota
            )
        }
    }

    private func refreshProfileStatuses(
        accountsOutput: String,
        displayNamesSnapshot: [String: String],
        showLoading: Bool,
        replayQuota: Bool
    ) {
        let loading = showLoading ? tr("更新用量...", "Updating usage...") : nil
        let previousProfiles = profiles

        runBackground(loading) {
            let statusResult = runCodexScript(scriptPath, ["list-accounts-status"], wait: true)
            let profiles = parsedCodexProfiles(
                accountsOutput: accountsOutput,
                statusOutput: statusResult.0 == 0 ? statusResult.1 : "",
                displayNames: displayNamesSnapshot
            )
            let statusIDs = Set(statusResult.1.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return parts.first
            })
            let previousByID = Dictionary(uniqueKeysWithValues: previousProfiles.map { ($0.id, $0) })
            let payload = profiles.map {
                let resolvedProfile = profileWithCachedUsageFallback(profileWithLocalAuthTokenFallback($0))
                let profile = (!statusIDs.contains(resolvedProfile.id) && resolvedProfile.authStatus == "unknown" && resolvedProfile.quota == "unknown")
                    ? (previousByID[$0.id] ?? $0)
                    : resolvedProfile
                return [
                    profile.id, profile.displayName, profile.home, profile.authStatus, profile.authMode,
                    profile.lastRefresh, profile.quota, profile.reset
                ].joined(separator: "\t")
            }.joined(separator: "\n")
            return (profiles.isEmpty ? statusResult.0 : 0, payload)
        } completion: { result in
            isRefreshing = false
            guard result.0 == 0 else {
                statusText = tr("用量更新失敗", "Usage update failed")
                return
            }
            let incomingProfiles = profilePayload(from: result.1)
            withAnimation(.easeInOut(duration: 0.24)) {
                profiles = stabilizedProfilesAfterRefresh(incomingProfiles, previousProfiles: previousProfiles)
            }
            if replayQuota {
                replayQuotaMeters()
            }
            statusText = tr("\(profiles.count) 個 profile 就緒", "\(profiles.count) profiles ready")
            attemptQuotaPoolFailoverIfNeeded()
        }
    }

    private func replayQuotaMeters() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.70)) {
                quotaReplayActive = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                resetScrambleActive = false
            }
        }
    }

    private func startResetScramble() {
        resetScrambleActive = true
        resetScrambleSeed = 0
        for index in 0...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.055) {
                resetScrambleSeed = index
            }
        }
    }

    private func stabilizedProfilesAfterRefresh(_ incoming: [CodexProfile], previousProfiles: [CodexProfile]) -> [CodexProfile] {
        let previousByID = Dictionary(uniqueKeysWithValues: previousProfiles.map { ($0.id, $0) })

        return incoming.map { profile -> CodexProfile in
            let rawProfile = profile
            let localProfile = profileWithCachedUsageFallback(profileWithLocalAuthTokenFallback(rawProfile))

            if localProfile.authStatus == "login_needed" || localProfile.authStatus == "auth_incomplete" {
                return CodexProfile(
                    id: localProfile.id,
                    displayName: localProfile.displayName,
                    home: localProfile.home,
                    authStatus: localProfile.authStatus,
                    authMode: localProfile.authMode,
                    lastRefresh: localProfile.lastRefresh,
                    quota: localProfile.quota,
                    reset: localProfile.reset
                )
            }

            let profile = profileWithCachedUsageFallback(profileWithConservativeLocalAuthFallback(localProfile))
            let previous = previousByID[profile.id]

            if profile.authStatus == "unknown", let previous {
                return CodexProfile(
                    id: profile.id,
                    displayName: profile.displayName,
                    home: profile.home,
                    authStatus: mergedAuthStatus(previous: previous.authStatus, current: profile.authStatus),
                    authMode: previous.authMode,
                    lastRefresh: previous.lastRefresh,
                    quota: previous.quota,
                    reset: previous.reset
                )
            }

            return profile
        }
    }

    private func profileWithLocalAuthTokenFallback(_ profile: CodexProfile) -> CodexProfile {
        guard profile.authStatus == "unknown"
                || profile.authStatus == "checking"
                || profile.authStatus == "login_needed"
                || profile.authStatus == "auth_incomplete"
        else {
            return profile
        }

        guard profileHasLocalAuthTokens(profile) else {
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
                reset: profile.reset
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
            reset: profile.reset
        )
    }

    private func profileWithConservativeLocalAuthFallback(_ profile: CodexProfile) -> CodexProfile {
        guard profile.authStatus == "unknown",
              profile.quota != "unknown",
              profileHasLocalAuthTokens(profile)
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
            reset: profile.reset
        )
    }

    private func profileHasLocalAuthTokens(_ profile: CodexProfile) -> Bool {
        let authURL = URL(fileURLWithPath: profile.home).appendingPathComponent("auth.json")
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
                reset: parts[7]
            )
        }
    }

    private func createAccount() {
        let defaultName = nextDefaultAccountName()
        guard let name = promptForAccountName(
            title: tr("新增帳戶", "New Account"),
            message: tr("可以直接用預設名，或者輸入你想要嘅 profile 名。", "Use the default name, or enter your own profile name."),
            defaultName: defaultName
        ) else { return }
        runBackground(tr("建立帳戶...", "Creating account...")) {
            runCodexScript(scriptPath, ["init-account", name], wait: true)
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

    private func openAccount(_ name: String, displayName: String? = nil) {
        let requestedName = displayName ?? name
        let route = quotaPoolRoute(for: name)
        let targetID = route?.target.id ?? name
        let targetName = route?.target.displayName ?? requestedName
        var arguments = ["launch-account", targetID]
        if !targetName.isEmpty {
            arguments.append(targetName)
        }
        let requestedID = sanitizedProfileId(name)
        let targetProfileID = sanitizedProfileId(targetID)
        let busyIDs = Set([requestedID, targetProfileID])
        startUsageSession()
        busyIDs.forEach { setProfileBusy($0, true) }
        let loadingText = route?.didSwitch == true
            ? tr("\(requestedName) quota 已用完，正在轉用 \(targetName)...", "\(requestedName) quota is depleted, switching to \(targetName)...")
            : tr("正在同步對話紀錄，再打開 \(targetName)...", "Syncing chat history, then opening \(targetName)...")
        runBackground(loadingText) {
            let syncResult = runCodexScript(scriptPath, ["sync-once"], wait: true)
            guard syncResult.0 == 0 else { return syncResult }
            let shareResult = runCodexScript(scriptPath, ["link-all-history"], wait: true)
            guard shareResult.0 == 0 else { return shareResult }
            if route?.didSwitch == true {
                _ = runCodexScript(scriptPath, ["close-account", name], wait: true)
            }
            return runCodexScript(scriptPath, arguments, wait: true)
        } completion: { result in
            let releaseDelay: TimeInterval = result.0 == 0 ? 1.45 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) {
                busyIDs.forEach { setProfileBusy($0, false) }
            }
            quotaPoolFailoverInProgress = false
            if result.0 == 0 {
                activeQuotaPoolProfileID = targetID
            }
            statusText = result.0 == 0
                ? (route?.didSwitch == true
                    ? tr("已由 \(requestedName) 自動轉用 \(targetName)", "Auto switched from \(requestedName) to \(targetName)")
                    : tr("已打開 \(targetName)", "Opened \(targetName)"))
                : tr("同步或打開失敗", "Sync or open failed")
        }
    }

    private func closeAccount(_ profile: CodexProfile) {
        setProfileBusy(profile.id, true)
        runBackground(tr("關閉 \(profile.displayName)...", "Closing \(profile.displayName)...")) {
            runCodexScript(scriptPath, ["close-account", profile.id], wait: true)
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
            runCodexScript(scriptPath, ["close-all-accounts"], wait: true)
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
            "\(activeProfile.displayName) quota 已用完，準備自動換 quota",
            "\(activeProfile.displayName) quota is depleted, preparing auto switch"
        )
        openAccount(activeProfile.id, displayName: activeProfile.displayName)
    }

    private func syncMemories(silent: Bool = false) {
        guard !isSyncing else { return }
        isSyncing = true
        let loading = silent ? nil : tr("同步記憶...", "Syncing memories...")

        runBackground(loading) {
            runCodexScript(scriptPath, ["sync-once"], wait: true)
        } completion: { result in
            isSyncing = false
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            if result.0 == 0 {
                lastAutoSync = time
                statusText = silent ? tr("已自動同步 \(time)", "Auto synced at \(time)") : tr("記憶已同步", "Memories synced")
            } else if !silent {
                statusText = tr("同步失敗", "Sync failed")
            }
        }
    }

    private func shareAll() {
        runBackground(tr("共享對話紀錄...", "Sharing history...")) {
            runCodexScript(scriptPath, ["link-all-history"], wait: true)
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

    private func shareHistory(_ profile: CodexProfile) {
        runBackground(tr("共享 \(profile.displayName) 對話紀錄...", "Sharing \(profile.displayName) history...")) {
            runCodexScript(scriptPath, ["link-history", profile.id], wait: true)
        } completion: { result in
            statusText = result.0 == 0 ? tr("已同 \(profile.displayName) 共享對話紀錄", "History shared with \(profile.displayName)") : tr("共享失敗", "History share failed")
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
            runCodexScript(scriptPath, ["delete-account", profile.id], wait: true)
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
        return "/Applications/Codex Quota Pool.app/Contents/Resources/codex_multi_account.zsh"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Quota Pool"
        statusItem.button?.toolTip = "Codex Quota Pool"
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
        window?.title = appTr("Codex Quota Pool", "Codex Quota Pool")
        buildMainMenu()
        rebuildMenu()
    }

    @objc private func keepAwakeChanged() {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        statusItem.button?.title = appTr("Quota Pool", "Quota Pool")
        statusItem.button?.toolTip = appTr("Codex Quota Pool", "Codex Quota Pool")

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
        menu.addItem(menuItem(appTr("關閉全部 Codex 視窗", "Close All Codex Windows"), action: #selector(closeAllWindows), key: "w"))

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
        appMenuItem.title = appTr("Codex Quota Pool", "Codex Quota Pool")
        let appMenu = NSMenu(title: appTr("Codex Quota Pool", "Codex Quota Pool"))
        appMenu.addItem(menuItem(appTr("關於 Codex Quota Pool", "About Codex Quota Pool"), action: #selector(showAbout), key: ""))
        appMenu.addItem(menuItem(appTr("切換防睡眠", "Toggle Keep Awake"), action: #selector(toggleKeepAwake), key: "k"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(menuItem(appTr("結束 Codex Quota Pool", "Quit Codex Quota Pool"), action: #selector(quit), key: "q"))
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

        for account in loadAccounts() {
            let item = NSMenuItem(title: appTr("打開 \(account.displayName)", "Open \(account.displayName)"), action: #selector(openAccountFromMenu(_:)), keyEquivalent: account.keyEquivalent)
            item.target = self
            item.representedObject = ["name": account.name, "displayName": account.displayName] as NSDictionary
            accountMenu.addItem(item)
        }

        accountMenu.addItem(NSMenuItem.separator())
        accountMenu.addItem(menuItem(appTr("新增帳戶...", "New Account..."), action: #selector(newAccount), key: "n"))
        accountMenu.addItem(menuItem(appTr("同步記憶一次", "Sync Memories Once"), action: #selector(syncOnce), key: "s"))
        accountMenu.addItem(menuItem(appTr("關閉全部 Codex 視窗", "Close All Codex Windows"), action: #selector(closeAllWindows), key: "w"))
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
        window.title = appTr("Codex Quota Pool", "Codex Quota Pool")
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
        let processArguments = [scriptPath] + arguments
        if wait {
            return runProcess(executable: "/bin/zsh", arguments: processArguments, timeout: 90)
        }
        return runDetachedProcess(executable: "/bin/zsh", arguments: processArguments)
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
        showMessage(appTr("Codex Quota Pool", "Codex Quota Pool"), appTr("多帳戶登入，自動換可用 quota。", "Separate logins with automatic quota routing."))
    }

    @objc private func listAccounts() {
        let result = runScript(["list-accounts"], wait: true)
        showMessage(appTr("Codex Quota Pool", "Codex Quota Pool"), result.1.isEmpty ? appTr("冇帳戶輸出。", "No account output.") : result.1)
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
        process.arguments = [scriptPath, "sync-loop"]
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
