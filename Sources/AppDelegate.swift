import Foundation
import AppKit
import IOKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlayWindow: OverlayWindow!
    private var renderTimer: Timer?
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var lastClaudeLinesUpdate: CFTimeInterval = 0
    private var lifeCompanion = LifeCompanion(lastCoffeeDay: UserDefaults.standard.string(forKey: "CoolCat.LastCoffeeDay"))
    private var lifeTimer: Timer?
    private var isPetVisible = true
    private var settingsController: SettingsWindowController?
    private var availableUpdateVersion: String?
    private var availableUpdateURL: URL?
    private var availableAssetURL: URL?
    private var isUpdating = false
    private var isHandingOverToNewerCopy = false

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if resolveDuplicateRunningCopies() { return }

        overlayWindow = OverlayWindow()
        overlayWindow.orderFrontRegardless()
        // `open -a CoolCat --args --open-settings`：启动后直接打开设置面板
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openSettings() }
        }

        let catView = overlayWindow.catView
        catView.onRequestPermission = { [weak self] in
            self?.openInputMonitoringSettings()
        }
        catView.onRightClickMenu = { [weak self] event in
            guard let self else { return }
            let menu = self.buildMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: self.overlayWindow.catView)
        }

        // Wire dual-layer InputEngine -> CatPhysics
        let engine = InputEngine.shared
        engine.onKeyDown = { [weak self] key in
            DispatchQueue.main.async {
                self?.overlayWindow.catView.physics.triggerKeyDown(key)
                // 只认在终端/IDE 里、且没按修饰键的按键：在 Slack 里按回车、⌘1 切标签、⌘⇧3 截图都不算回应 Claude
                guard Self.frontmostIsClaudeHost(), !Self.commandModifierHeld() else { return }
                let now = CACurrentMediaTime()
                let tracker = ClaudeActivityTracker.shared
                switch key {
                case .arrowUp, .arrowDown:
                    // 用方向键挑选项后再回车，就不知道选的是"是"还是"否"了
                    tracker.noteSelectionNavigation(at: now)
                case .enter, .k1, .k2:
                    tracker.acknowledgeWaiting(userActionAt: now, response: .approve)
                case .escape, .k3:
                    tracker.acknowledgeWaiting(userActionAt: now, response: .reject)
                    // IDE 里 Esc 常用来关补全/退插入模式，只在终端和 Claude App 里当作打断
                    if key == .escape && Self.frontmostIsTerminal() { tracker.userPressedEscape(at: now) }
                default:
                    break
                }
            }
        }
        engine.onMouseClick = { [weak self] button, isDown in
            DispatchQueue.main.async {
                self?.overlayWindow.catView.physics.triggerMouseClick(button: button, isDown: isDown)
                // 只有能"点按钮批准"的宿主（Claude App、VS Code 类编辑器的 Claude 面板）才把点击当作回应
                if isDown && button == 0 && Self.frontmostHasClickablePrompt() {
                    ClaudeActivityTracker.shared.acknowledgeWaiting(userActionAt: CACurrentMediaTime(), response: .approve)
                }
            }
        }
        engine.start()
        // 系统只有在 App 申请过一次后，才会把它列进「输入监控」；首次启动主动申请（只弹系统框，不跳设置）
        if !engine.hasInputMonitoringPermission && !UserDefaults.standard.bool(forKey: "CoolCat.DidRequestInputMonitoring") {
            UserDefaults.standard.set(true, forKey: "CoolCat.DidRequestInputMonitoring")
            CGRequestListenEventAccess()
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // 听歌检测 -> 戴耳机 / 歌名气泡
        let music = MusicMonitor.shared
        music.onActivityChange = { [weak self] activity in
            self?.applyAudioActivity(activity)
        }
        music.onTrackChange = { [weak self] track in
            self?.overlayWindow.catView.physics.showTrack(title: track.title, artist: track.artist)
        }
        music.start()

        // 实时音频只收到静音时提示一次去哪里开权限
        AudioSpectrumAnalyzer.shared.onStateChange = { [weak self] state in
            guard state == .silentNoPermission else { return }
            self?.overlayWindow.catView.physics.showNotice("🎧 没拿到音频，先用模拟节拍跳；可在「录屏与系统录音」里允许")
        }

        // Claude Code hook 事件 -> 小猫状态；App 换了位置就顺手把 hook 路径修好
        ClaudeActivityTracker.shared.start()
        for agent in CodingAgent.allCases { AgentHookInstaller.installer(for: agent).repairIfOutdated() }
        suggestAgentIntegrationIfNeeded()

        // 麦克风/摄像头占用 -> 耳麦、嘘、洗脸
        let meeting = MeetingMonitor.shared
        meeting.onChange = { [weak self] state in
            self?.overlayWindow.catView.physics.setMeeting(mic: state.micActive, micApp: state.micApp, camera: state.cameraActive)
        }
        meeting.start()

        setupStatusItem()
        if isAutoStartEnabled() {
            // Keep LaunchAgent path updated if user moved CoolCat.app into /Applications
            _ = setAutoStartEnabled(true)
        }
        // 改名前开过开机自启：旧启动项已在迁移时删掉，这里用新路径重建
        if UserDefaults.standard.bool(forKey: LegacyMigration.autoStartPendingKey) {
            UserDefaults.standard.removeObject(forKey: LegacyMigration.autoStartPendingKey)
            _ = setAutoStartEnabled(true)
        }
        startRenderLoop()
        startLifeCompanion()

        if Self.updateChecksEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.checkForUpdates(manual: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting during launch because a newer copy is running: leave its stats alone.
        if isHandingOverToNewerCopy { return }
        renderTimer?.invalidate()
        InputEngine.shared.flushStats()
        InputEngine.shared.stop()
        MusicMonitor.shared.stop()
        lifeTimer?.invalidate()
        AudioSpectrumAnalyzer.shared.setWanted(false)
        ClaudeActivityTracker.shared.stop()
        MeetingMonitor.shared.stop()
    }

    private func applyAudioActivity(_ activity: AudioActivity) {
        let physics = overlayWindow.catView.physics
        switch activity {
        case .silent:
            physics.setListening(false, musicApp: false)
        case .music:
            physics.setListening(true, musicApp: true)
        case .otherAudio:
            physics.setListening(CatSettings.shared.headphonesForAnyAudio, musicApp: false)
        }
        updateAudioAnalyzer()
    }

    /// 只在音乐播放器出声时才开系统音频 tap：停播、关开关都立刻停掉
    private func updateAudioAnalyzer() {
        let settings = CatSettings.shared
        let isMusic: Bool = {
            if case .music = MusicMonitor.shared.activity { return true }
            return false
        }()
        let wanted = isMusic && settings.musicHeadphones && settings.realAudioAnalysis
            && (settings.musicVisualizer || settings.musicDance)
        // 第一次要读音频前先说明一下，紧接着系统会弹授权框
        if wanted && !UserDefaults.standard.bool(forKey: "CoolCat.AudioCaptureExplained") {
            UserDefaults.standard.set(true, forKey: "CoolCat.AudioCaptureExplained")
            overlayWindow.catView.physics.showNotice("🎧 想跟着你的歌跳舞，系统会问能否读取播放的声音")
        }
        AudioSpectrumAnalyzer.shared.setWanted(wanted)
    }

    // MARK: - One CoolCat at a time (newest copy wins)

    /// Users often download a new CoolCat.app while an older copy is still running (or is started
    /// by the login item from another folder). That old process kept running and kept announcing
    /// "new version available" even though they had already updated. Keep only the newest copy:
    /// quit older ones, or hand over to an already-running newer one. Returns true if THIS process quits.
    private func resolveDuplicateRunningCopies() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myURL = Bundle.main.bundleURL.standardizedFileURL
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if others.isEmpty { return false }

        for other in others {
            guard let otherURL = other.bundleURL?.standardizedFileURL, otherURL != myURL,
                  let otherVersion = Self.shortVersion(ofAppAt: otherURL) else { continue }
            if isVersion(otherVersion, newerThan: currentAppVersion) {
                isHandingOverToNewerCopy = true
                _ = other.activate(options: [])
                NSApp.terminate(nil)
                return true
            }
        }
        for other in others {
            // Same path (replaced in place by an update) or an older/equal copy elsewhere.
            if !other.terminate() { _ = other.forceTerminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if !other.isTerminated { _ = other.forceTerminate() }
            }
        }
        return false
    }

    /// Reads CFBundleShortVersionString straight from disk (Bundle(url:) may return cached info).
    private static func shortVersion(ofAppAt url: URL) -> String? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// A newer CoolCat.app that is already on disk (e.g. downloaded to ~/Downloads but never
    /// launched because LaunchServices just re-activated this running copy).
    private func newestDownloadedCopy() -> (url: URL, version: String)? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let myURL = Bundle.main.bundleURL.standardizedFileURL
        var best: (url: URL, version: String)?
        let appURLs: [URL]
        if #available(macOS 12.0, *) {
            appURLs = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        } else {
            appURLs = (LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        }
        for url in appURLs {
            let std = url.standardizedFileURL
            guard std != myURL, !std.path.contains("/.Trash/"),
                  let v = Self.shortVersion(ofAppAt: std),
                  isVersion(v, newerThan: best?.version ?? currentAppVersion) else { continue }
            best = (std, v)
        }
        return best
    }

    private func switchToDownloadedCopy(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - 60 FPS Render Loop

    private func startRenderLoop() {
        lastFrameTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.isPetVisible else { return }
            let now = CACurrentMediaTime()
            let dt = CGFloat(now - self.lastFrameTime)
            self.lastFrameTime = now

            let view = self.overlayWindow.catView
            let agents = CatSettings.shared.enabledAgents
            if !agents.isEmpty {
                let tracker = ClaudeActivityTracker.shared
                view.physics.updateClaude(tracker.status(now: now, agents: agents))
                // 明细每秒刷新 4 次就够（耗时按秒显示），不必每帧排序拼字符串
                if now - self.lastClaudeLinesUpdate >= 0.25 {
                    self.lastClaudeLinesUpdate = now
                    view.physics.claudeLines = tracker.lines(now: now, agents: agents)
                }
            } else {
                view.physics.updateClaude(.idle)
            }
            view.physics.outputSilentHint = MusicMonitor.shared.isMomentarilySilent
            view.physics.updateAudio(AudioSpectrumAnalyzer.shared.snapshot())
            view.physics.step(dt: dt, windowFrameInScreen: self.overlayWindow.frame)
            view.updateHoverAndClickThrough()
            view.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    // MARK: - Menu Bar Icon & Menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeMenuBarCatIcon()
            button.toolTip = "CoolCat 黑猫键盘桌宠"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let engine = InputEngine.shared
        let settings = CatSettings.shared
        let physics = overlayWindow.catView.physics

        // Status header
        let statusPrefix = engine.status.needsAttention ? "⚠️" : "🟢"
        let statusItem = NSMenuItem(title: "\(statusPrefix) \(engine.status.rawValue)", action: engine.status.needsAttention ? #selector(openInputMonitoringSettings) : nil, keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)

        if engine.status == .needsPermission {
            let grantItem = NSMenuItem(title: "🔑 前往系统设置开启「输入监控」...", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
            grantItem.target = self
            menu.addItem(grantItem)
        }

        // Live stats
        let statsTitle = "⌨️ 今日击键 \(engine.totalKeystrokesToday)  ·  KPM \(engine.currentKPM)  ·  摸猫 \(physics.totalPetSessions) 次"
        let statsItem = NSMenuItem(title: statsTitle, action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(.separator())

        // 常用操作留在菜单里，其余开关都在「设置…」面板
        let visItem = NSMenuItem(title: isPetVisible ? "隐藏小猫" : "显示小猫", action: #selector(toggleVisibility), keyEquivalent: "")
        visItem.target = self
        menu.addItem(visItem)

        let fed = physics.feedLog
        let feedItem = NSMenuItem(title: "🐟 喂小鱼干（今天 \(fed.count)/\(FeedLog.dailyLimit)）", action: #selector(feedCat), keyEquivalent: "")
        feedItem.target = self
        menu.addItem(feedItem)

        let bond = physics.bond
        let bondText = bond.nextLevel.map { "💞 Lv\(bond.level.level) \(bond.level.title) · \(bond.points)/\($0.threshold)" }
            ?? "💞 Lv\(bond.level.level) \(bond.level.title) · 满级"
        let bondItem = NSMenuItem(title: bondText, action: nil, keyEquivalent: "")
        bondItem.isEnabled = false
        menu.addItem(bondItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let resetPosItem = NSMenuItem(title: "重置位置到右下角", action: #selector(resetPosition), keyEquivalent: "")
        resetPosItem.target = self
        menu.addItem(resetPosItem)

        menu.addItem(.separator())

        if !Self.updateChecksEnabled {
            // CoolCat 暂无自己的发布地址：不检查更新，只显示版本号
            let versionItem = NSMenuItem(title: "CoolCat v\(currentAppVersion)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
        } else if let ver = availableUpdateVersion {
            let title = isUpdating ? "⏳ 正在下载更新 \(ver)..." : "🆕 发现新版本 \(ver) — 点击自动更新"
            let updateItem = NSMenuItem(title: title, action: #selector(openUpdateDownload), keyEquivalent: "")
            updateItem.target = self
            updateItem.isEnabled = !isUpdating
            menu.addItem(updateItem)
        } else {
            let checkItem = NSMenuItem(title: "检查更新 (当前 v\(currentAppVersion))", action: #selector(manualCheckForUpdates), keyEquivalent: "")
            checkItem.target = self
            menu.addItem(checkItem)
        }

        let quitItem = NSMenuItem(title: "退出 CoolCat", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func openInputMonitoringSettings() {
        if InputEngine.shared.status == .needsRestart {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "已授权，键盘监听启动失败"
            alert.informativeText = "请重启 CoolCat，让系统重新建立键盘监听。\n当前程序位置：\(Bundle.main.bundlePath)"
            alert.addButton(withTitle: "重启 CoolCat")
            alert.addButton(withTitle: "打开输入监控")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                relaunchApp()
                return
            }
            if response != .alertSecondButtonReturn { return }
        }
        InputEngine.shared.requestPermissionsAndOpenSettings()
    }

    @objc private func openSettings() {
        if settingsController == nil { settingsController = SettingsWindowController(host: self) }
        settingsController?.present()
    }

    @objc private func feedCat() { overlayWindow.catView.physics.feed() }

    @objc private func toggleVisibility() {
        isPetVisible.toggle()
        if isPetVisible {
            overlayWindow.orderFrontRegardless()
        } else {
            overlayWindow.orderOut(nil)
        }
    }

    // MARK: - Launch at Login (macOS LaunchAgent — works reliably for signed & ad-hoc builds)

    private var launchAgentURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("ai.today.coolcat.plist")
    }

    private func isAutoStartEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @discardableResult
    private func setAutoStartEnabled(_ enable: Bool) -> Bool {
        let fm = FileManager.default
        let url = launchAgentURL
        if enable {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let appPath = Bundle.main.bundlePath
                let plist: [String: Any] = [
                    "Label": "ai.today.coolcat",
                    "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                    "RunAtLoad": true,
                    "KeepAlive": false
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        } else {
            do {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - 生活陪伴

    /// 每 5 秒看一眼时间、电量、键鼠活动，把该触发的事件交给小猫
    private func startLifeCompanion() {
        let tick = { [weak self] in
            guard let self else { return }
            let settings = CatSettings.shared
            var options = LifeCompanion.Options()
            options.night = settings.lifeNight
            options.morning = settings.lifeMorning
            options.battery = settings.lifeBattery
            options.workBreak = settings.lifeWorkBreak
            let engine = InputEngine.shared
            let lastInput = max(engine.lastKeyActivityTime, max(engine.lastMouseMoveTime, engine.lastMouseClickTime))
            let battery = PowerSourceProbe.read()
            let events = self.lifeCompanion.update(date: Date(), clock: CACurrentMediaTime(), lastInput: lastInput,
                                                   battery: battery, options: options)
            if let day = self.lifeCompanion.coffeeDay {
                UserDefaults.standard.set(day, forKey: "CoolCat.LastCoffeeDay")
            }
            let physics = self.overlayWindow.catView.physics
            physics.setLife(isNight: self.lifeCompanion.isNight, battery: battery,
                            tiredness: CGFloat(self.lifeCompanion.tiredness))
            for event in events { physics.react(life: event) }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        lifeTimer = timer
        tick()
    }

    /// 不改真实状态，直接驱动 physics 演示一遍（约 30 秒）
    @objc private func runLifeDemo() {
        let physics = overlayWindow.catView.physics
        let steps: [(TimeInterval, () -> Void)] = [
            (0, { physics.debugNight = true; physics.react(life: .nightReminder("🌙 已经 23:30 了，早点休息吧")) }),
            (6, { physics.debugNight = nil; physics.react(life: .morningCoffee) }),
            (13, { physics.offerProp(.coffee, duration: 0.01)
                   physics.debugBattery = BatteryStatus(percent: 9, onAC: false)
                   physics.react(life: .lowBattery(9)) }),
            (19, { physics.debugBattery = BatteryStatus(percent: 9, onAC: true); physics.react(life: .pluggedIn) }),
            (26, { physics.debugBattery = nil; physics.react(life: .workBreak(minutes: 50)) })
        ]
        for (delay, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    // MARK: - 会议模式

    /// 不碰真实设备，直接驱动 physics 演示一遍
    @objc private func runMeetingDemo() {
        let physics = overlayWindow.catView.physics
        physics.setMeeting(mic: false, micApp: nil, camera: false)
        physics.setMeeting(mic: false, micApp: nil, camera: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            physics.setMeeting(mic: true, micApp: "腾讯会议", camera: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            for i in 0..<10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                    physics.triggerKeyDown([.j, .k, .l, .f, .d][i % 5])
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            // 恢复时读最新状态：演示期间可能真的开了会
            let live = MeetingMonitor.shared.state
            physics.setMeeting(mic: live.micActive, micApp: live.micApp, camera: live.cameraActive)
        }
    }

    // MARK: - Claude Code 联动

    /// 这台机器装了 Claude Code（有 ~/.claude）但还没连接时，启动后提示一次去哪里开
    /// 这台机器装了 Claude Code / Codex（有配置目录）但还没连接时，启动后各提示一次去哪里开
    private func suggestAgentIntegrationIfNeeded() {
        var delay: TimeInterval = 3
        for agent in CodingAgent.allCases {
            let installer = AgentHookInstaller.installer(for: agent)
            // 沿用旧 key，老用户不会被再提示一次 Claude Code
            let key = agent == .claude ? "CoolCat.SuggestedClaudeIntegration" : "CoolCat.SuggestedCodexIntegration"
            guard !UserDefaults.standard.bool(forKey: key), installer.isAgentPresent,
                  installer.state() == .notInstalled else { continue }
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.overlayWindow.catView.physics.showNotice("🤖 发现 \(agent.displayName)：右键我 →「设置…」→ \(agent.displayName) → 连接")
            }
            delay += 6
        }
    }

    // 可能运行 Claude Code 的宿主 App（bundle ID 小写子串）
    private static let claudeHostTokens = [
        "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby",
        "vscode", "todesktop", "cursor", "windsurf", "zed", "jetbrains", "xcode", "anthropic", "claude",
        "openai", "codex", "chatgpt"
    ]

    private static let terminalTokens = [
        "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "anthropic", "claude"
    ]
    private static let clickablePromptTokens = ["anthropic", "claude", "vscode", "todesktop", "cursor", "windsurf", "zed",
                                                "openai", "codex", "chatgpt"]

    private static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
    }

    private static func frontmostIsTerminal() -> Bool {
        guard let id = frontmostBundleID() else { return false }
        return terminalTokens.contains { id.contains($0) }
    }

    private static func frontmostHasClickablePrompt() -> Bool {
        guard let id = frontmostBundleID() else { return false }
        return clickablePromptTokens.contains { id.contains($0) }
    }

    private static func commandModifierHeld() -> Bool {
        let modifiers: Set<PhysicalKey> = [.leftCommand, .rightCommand, .leftControl, .rightControl, .leftOption, .rightOption]
        return !InputEngine.shared.activeKeys.isDisjoint(with: modifiers)
    }

    private static func frontmostIsClaudeHost() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() else { return false }
        return claudeHostTokens.contains { id.contains($0) }
    }

    private func installHooks(for agent: CodingAgent) {
        let installer = AgentHookInstaller.installer(for: agent)
        let confirm = NSAlert()
        confirm.messageText = "连接 \(agent.displayName)"
        var info = """
        CoolCat 会在 \(installer.displayPath) 里加入 \(installer.events.count) 个 hook（\(installer.events.joined(separator: "、"))）。

        • 只把事件名、工具名、项目文件夹名发给小猫，不读取你的提示词和代码
        • 原文件会备份为 \((installer.displayPath as NSString).lastPathComponent).coolcat-backup
        """
        switch agent {
        case .claude:
            info += "\n• 已打开的 Claude Code 会话需要重启（或执行 /hooks）后生效"
        case .codex:
            info += "\n• Codex 要求先信任新 hook：在 Codex 桌面 App「设置 → Hooks → needs review」（CLI 输入 /hooks）里信任标题为「CoolCat 桌面小猫」的条目后才会生效"
        }
        confirm.informativeText = info
        confirm.addButton(withTitle: "连接")
        confirm.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try installer.install()
            CatSettings.shared.setIntegration(agent, enabled: true)
            switch agent {
            case .claude:
                showInfoAlert("已连接 Claude Code 🎉", "新开的 Claude Code 会话里，小猫会跟着思考、等你批准、完成任务做出反应。")
            case .codex:
                showInfoAlert("已写入 Codex hook，还差一步 🔑",
                              "打开 Codex「设置 → Hooks」，点「needs review」，把标题为「CoolCat 桌面小猫」的 8 条 hook 标记为信任（CLI 里输入 /hooks）。\n信任之后，小猫会跟着 Codex 干活、等你批准、完成任务做出反应；设置面板里看到「已收到事件」就说明通了。")
            }
        } catch {
            showInfoAlert("连接失败", error.localizedDescription)
        }
    }

    private func uninstallHooks(for agent: CodingAgent) {
        let installer = AgentHookInstaller.installer(for: agent)
        do {
            try installer.uninstall()
            showInfoAlert("已断开 \(agent.displayName)", "CoolCat 的 hook 已从 \(installer.displayPath) 移除，其他配置未改动。")
        } catch {
            showInfoAlert("断开失败", error.localizedDescription)
        }
    }

    /// 不依赖 hook，直接给 tracker 喂一串假事件，方便预览动画
    private func runAgentDemo(_ agent: CodingAgent) {
        let tracker = ClaudeActivityTracker.shared
        let session = "coolcat-demo"
        let project = agent == .codex ? "Codex 演示" : "Claude 演示"
        let steps: [(TimeInterval, String, String?, String?)] = [
            (0.0, "UserPromptSubmit", nil, nil),
            (2.0, "PreToolUse", "Read", nil),
            (4.0, "PreToolUse", agent == .codex ? "apply_patch" : "Edit", nil),
            (6.5, agent == .codex ? "PermissionRequest" : "Notification", agent == .codex ? "Bash" : nil, "permission_prompt"),
            (10.0, "PostToolUse", "Bash", nil),
            (11.5, "Stop", nil, nil),
            (16.0, "SessionEnd", nil, nil)
        ]
        for (delay, event, tool, type) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                tracker.apply(event: event, session: session, tool: tool, notificationType: type, project: project,
                              agent: agent, now: CACurrentMediaTime())
            }
        }
    }

    private func showInfoAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func resetPosition() {
        overlayWindow.resetPosition()
    }

    @objc private func runDemoBurst() {
        let keys: [PhysicalKey] = [.w, .a, .s, .d, .f, .j, .o, .e, .space, .leftShift]
        for (idx, k) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.13) { [weak self] in
                self?.overlayWindow.catView.physics.triggerKeyDown(k)
            }
        }
    }

    @objc private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Auto Update Checker & In-App Self-Updater

    /// 更新检查开关。下面的地址是上游 KuroCat 的发布站，CoolCat 有自己的发布地址后再打开并替换
    private static let updateChecksEnabled = false
    private static let updatePageURLString = "https://kurocat-download.app.workbuddy.host/?sharecode=JVAABIVZ7L"
    private static let updateVersionJSONURLString = "https://kurocat-download.app.workbuddy.host/version.json?sharecode=JVAABIVZ7L"
    private static let defaultMacAssetURLString = "https://kurocat-download.app.workbuddy.host/downloads/KuroCat-macOS-universal.zip?sharecode=JVAABIVZ7L"

    @objc private func manualCheckForUpdates() {
        checkForUpdates(manual: true)
    }

    @objc private func openUpdateDownload() {
        performInAppUpdate()
    }

    private func parseUpdateInfo(from data: Data) -> (tag: String, pageURL: URL?, assetURL: URL?)? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tagName = json["tag_name"] as? String, !tagName.isEmpty {
            let pageStr = (json["html_url"] as? String) ?? Self.updatePageURLString
            let assets = json["assets"] as? [String: Any]
            let macStr = (assets?["macos"] as? String) ?? Self.defaultMacAssetURLString
            return (tagName, URL(string: pageStr), URL(string: macStr))
        }
        if let html = String(data: data, encoding: .utf8) {
            let patterns = [
                #"v(\d+\.\d+\.\d+)\s*已发布"#,
                #"版本\s*v(\d+\.\d+\.\d+)"#
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let r = Range(match.range(at: 1), in: html) {
                    return ("v" + String(html[r]), URL(string: Self.updatePageURLString), URL(string: Self.defaultMacAssetURLString))
                }
            }
        }
        return nil
    }

    private func fetchUpdateEndpoint(_ urlString: String, completion: @escaping ((tag: String, pageURL: URL?, assetURL: URL?)?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("CoolCat/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil, let data, let parsed = self.parseUpdateInfo(from: data) else {
                completion(nil)
                return
            }
            completion(parsed)
        }.resume()
    }

    private func checkForUpdates(manual: Bool) {
        fetchUpdateEndpoint(Self.updateVersionJSONURLString) { [weak self] primary in
            guard let self else { return }
            if let info = primary {
                DispatchQueue.main.async { self.handleUpdateResult(info, manual: manual) }
                return
            }
            self.fetchUpdateEndpoint(Self.updatePageURLString) { [weak self] fallback in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let info = fallback {
                        self.handleUpdateResult(info, manual: manual)
                    } else if manual {
                        self.showInfoAlert(title: "检查更新失败", message: "无法连接到更新服务器，请稍后重试或检查网络连接。")
                    }
                }
            }
        }
    }

    private func handleUpdateResult(_ info: (tag: String, pageURL: URL?, assetURL: URL?), manual: Bool) {
        if isVersion(info.tag, newerThan: currentAppVersion),
           let local = newestDownloadedCopy(), !isVersion(info.tag, newerThan: local.version) {
            // The user already downloaded the latest version; they are just still running the old copy.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "你已经下载了新版本 v\(local.version)"
            alert.informativeText = "但现在运行的还是旧版 v\(currentAppVersion)：\n\(Bundle.main.bundlePath)\n\n新版本位置：\n\(local.url.path)\n\n点击「切换到新版本」会关闭旧版并打开新版。建议把新版拖进「应用程序」文件夹并删除旧版。"
            alert.addButton(withTitle: "切换到新版本")
            alert.addButton(withTitle: "稍后再说")
            if alert.runModal() == .alertFirstButtonReturn {
                switchToDownloadedCopy(local.url)
            }
            return
        }
        if isVersion(info.tag, newerThan: currentAppVersion) {
            availableUpdateVersion = info.tag
            availableUpdateURL = info.pageURL
            availableAssetURL = info.assetURL
            promptUpdateAvailable(latestTag: info.tag)
        } else if manual {
            showInfoAlert(title: "已是最新版本", message: "当前版本 v\(currentAppVersion) 已是最新版本。")
        }
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        func parse(_ v: String) -> [Int] {
            let trimmed = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            return trimmed.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = parse(lhs)
        let b = parse(rhs)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    private func promptUpdateAvailable(latestTag: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现 CoolCat 新版本 \(latestTag)"
        alert.informativeText = "当前版本：v\(currentAppVersion)\n最新版本：\(latestTag)\n当前运行位置：\(Bundle.main.bundlePath)\n\n点击「立即更新」将在后台自动下载安装包并重启应用。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "稍后再说")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            performInAppUpdate()
        } else if resp == .alertSecondButtonReturn {
            let fallback = URL(string: Self.updatePageURLString)!
            NSWorkspace.shared.open(availableUpdateURL ?? fallback)
        }
    }

    private func performInAppUpdate() {
        guard !isUpdating else { return }
        guard let assetURL = availableAssetURL ?? URL(string: Self.defaultMacAssetURLString) else { return }
        isUpdating = true

        var req = URLRequest(url: assetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue("CoolCat/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.downloadTask(with: req) { [weak self] tempURL, response, error in
            guard let self else { return }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let tempURL, httpStatus == 200 || httpStatus == 0 else {
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.handleUpdateDownloadFailure()
                }
                return
            }

            let fm = FileManager.default
            let workDir = fm.temporaryDirectory.appendingPathComponent("CoolCatUpdate-\(UUID().uuidString)")
            let zipURL = workDir.appendingPathComponent("CoolCat-macOS-universal.zip")
            let extractDir = workDir.appendingPathComponent("extracted")
            do {
                try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
                try fm.copyItem(at: tempURL, to: zipURL)
                let attrs = try fm.attributesOfItem(atPath: zipURL.path)
                let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
                guard fileSize > 50_000 else {
                    throw NSError(domain: "CoolCatUpdate", code: 1)
                }

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zipURL.path, extractDir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    throw NSError(domain: "CoolCatUpdate", code: 2)
                }

                let newAppURL = extractDir.appendingPathComponent("CoolCat.app")
                guard fm.fileExists(atPath: newAppURL.appendingPathComponent("Contents/MacOS/CoolCat").path) else {
                    throw NSError(domain: "CoolCatUpdate", code: 3)
                }

                let currentAppURL = Bundle.main.bundleURL
                let parentWritable = fm.isWritableFile(atPath: currentAppURL.deletingLastPathComponent().path)

                DispatchQueue.main.async {
                    self.installDownloadedApp(newAppURL: newAppURL, currentAppURL: currentAppURL, workDir: workDir, needsAdmin: !parentWritable)
                }
            } catch {
                try? fm.removeItem(at: workDir)
                DispatchQueue.main.async {
                    self.isUpdating = false
                    self.handleUpdateDownloadFailure()
                }
            }
        }.resume()
    }

    private func installDownloadedApp(newAppURL: URL, currentAppURL: URL, workDir: URL, needsAdmin: Bool) {
        func shQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let dst = shQuote(currentAppURL.path)
        let src = shQuote(newAppURL.path)
        let tmp = shQuote(workDir.path)

        if needsAdmin {
            let cmd = "rm -rf \(dst).bak && mv \(dst) \(dst).bak && cp -R \(src) \(dst) && rm -rf \(dst).bak \(tmp)"
            let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
            do {
                try osa.run()
                osa.waitUntilExit()
                if osa.terminationStatus == 0 {
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    relaunch.arguments = ["-n", currentAppURL.path]
                    try? relaunch.run()
                    NSApp.terminate(nil)
                    return
                }
            } catch {}
            try? FileManager.default.removeItem(at: workDir)
            isUpdating = false
            handleUpdateDownloadFailure()
            return
        }

        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(dst).bak
        if mv \(dst) \(dst).bak && cp -R \(src) \(dst); then
            rm -rf \(dst).bak
            open -n \(dst)
        else
            mv \(dst).bak \(dst) 2>/dev/null
        fi
        rm -rf \(tmp)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        do {
            try proc.run()
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            isUpdating = false
            handleUpdateDownloadFailure()
        }
    }

    private func handleUpdateDownloadFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "自动更新失败"
        alert.informativeText = "下载或替换安装包时出错，是否打开下载页手动下载？"
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let fallback = URL(string: Self.updatePageURLString)!
            NSWorkspace.shared.open(availableUpdateURL ?? fallback)
        }
    }

    private func showInfoAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Crisp Vector Menu Bar Cat Silhouette Icon

    private func makeMenuBarCatIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)

            // Cute cat head silhouette with ears
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 3.0, y: 8.5))
            path.addLine(to: CGPoint(x: 3.5, y: 2.5))
            path.addLine(to: CGPoint(x: 7.2, y: 6.0))
            path.addQuadCurve(to: CGPoint(x: 10.8, y: 6.0), control: CGPoint(x: 9.0, y: 5.5))
            path.addLine(to: CGPoint(x: 14.5, y: 2.5))
            path.addLine(to: CGPoint(x: 15.0, y: 8.5))
            path.addCurve(to: CGPoint(x: 9.0, y: 15.5), control1: CGPoint(x: 16.0, y: 12.8), control2: CGPoint(x: 13.0, y: 15.5))
            path.addCurve(to: CGPoint(x: 3.0, y: 8.5), control1: CGPoint(x: 5.0, y: 15.5), control2: CGPoint(x: 2.0, y: 12.8))
            path.closeSubpath()

            // Punch out cute cat eyes
            path.addEllipse(in: CGRect(x: 5.4, y: 8.8, width: 2.4, height: 2.2))
            path.addEllipse(in: CGRect(x: 10.2, y: 8.8, width: 2.4, height: 2.2))

            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Settings Host

extension AppDelegate: SettingsHost {
    var physics: CatPhysics { overlayWindow.catView.physics }

    var petVisible: Bool {
        get { isPetVisible }
        set { if newValue != isPetVisible { toggleVisibility() } }
    }

    var autoStartEnabled: Bool {
        get { isAutoStartEnabled() }
        set { setAutoStartEnabled(newValue) }
    }

    func applyScale(_ scale: CGFloat) { overlayWindow.applyScale(scale) }

    func applyWindowBehavior() { overlayWindow.applyWindowLevelAndBehavior() }

    func audioSettingsChanged(resetPermission: Bool) {
        // 重新打开实时音频 = 用户想再试一次（可能刚在系统设置里授了权）
        if resetPermission { AudioSpectrumAnalyzer.shared.resetPermissionMemory() }
        applyAudioActivity(MusicMonitor.shared.activity)
    }

    func selectCoat(_ coat: CatCoatTheme) {
        let settings = CatSettings.shared
        settings.coatTheme = coat
        // 换毛色时配上招牌瞳色（之后仍可单独改）
        switch coat {
        case .classicBlack: settings.eyeTheme = .neonChartreuse
        case .siamese: settings.eyeTheme = .siameseBlue
        case .shorthair, .orangeWhite: settings.eyeTheme = .softAmber
        }
    }

    func resetPetPosition() { resetPosition() }
    func relaunch() { relaunchApp() }
    func openInputMonitoring() { openInputMonitoringSettings() }
    func install(_ agent: CodingAgent) { installHooks(for: agent) }
    func uninstall(_ agent: CodingAgent) { uninstallHooks(for: agent) }

    func runDemo(_ demo: SettingsDemo) {
        switch demo {
        case .typing: runDemoBurst()
        case .life: runLifeDemo()
        case .meeting: runMeetingDemo()
        case .claude: runAgentDemo(.claude)
        case .codex: runAgentDemo(.codex)
        case .gift: physics.offerGift()
        }
    }
}
