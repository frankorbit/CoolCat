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
    // 满屏漫游
    private var roam = RoamDirector()
    private var roamWindow: RoamWindow?
    private var roamSurfaces: [RoamSurface] = []
    private var lastSurfaceScan: CFTimeInterval = 0
    /// 窗口顶的积雪（下雪的季节里）
    private var snowpack = Snowpack()
    private var deskWindow: DeskOverlayWindow?
    /// 被推下桌（或从嘴里掉下来）的小东西
    private var trinkets = TrinketPhysics()
    /// 番茄钟：专注时小猫趴在你的窗口上陪你，到点举牌叫你休息
    private let focus = FocusCompanion()
    /// 踢飞文件：Finder 右键「CoolCat 小猫踢飞（移到废纸篓）」，小猫跑过去一脚把它踢出屏幕
    private let fileKick = FileKickCompanion()
    /// 小猫跑去别的屏幕踢文件时在哪块屏幕上（回到座位就清掉）；上一帧在哪块屏幕上活动
    private var awayScreen: NSScreen?
    private var lastRoamScreen: NSScreen?
    /// 这次抖雪已经把雪块甩出去了
    private var snowShakeSpawned = false
    private let ignoreKeysForRoaming = CommandLine.arguments.contains("--roam-ignore-keys")
    /// 上沿在扫描里暂时消失的时刻（宽限期用）
    private var surfaceGraceSince: [Int: CFTimeInterval] = [:]
    /// `--roam-log <文件>`：每半秒记一行漫游状态（调试多屏坐标用）
    private lazy var roamLogPath: String? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--roam-log"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }()
    private var lastRoamLog: CFTimeInterval = 0
    private var roamClockStart: CFTimeInterval = 0
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
        // `open -a CoolCat --args --roam-now`：启动后马上出门溜达（调试/演示用）
        // `--roam-peek`：出门后马上去底边偷看
        if CommandLine.arguments.contains("--roam-peek") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.roam.peekNow() }
        }
        // `--beat-log <文件>`：每 5 秒记一行锁拍统计（落拍率、抖动、偏移、输出设备）
        if let i = CommandLine.arguments.firstIndex(of: "--beat-log"), i + 1 < CommandLine.arguments.count {
            overlayWindow.catView.physics.beatLogPath = CommandLine.arguments[i + 1]
        }
        // `--sign-demo`：启动后假装 agent 等你批准 20 秒，看小猫跑去举牌
        if CommandLine.arguments.contains("--sign-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.signDemoUntil = CACurrentMediaTime() + 20
            }
        }
        // `--holiday-preview`：启动后预览 30 秒节日装扮（圣诞帽、小雪、圣诞礼物）
        if CommandLine.arguments.contains("--holiday-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.overlayWindow.catView.physics.previewHoliday()
            }
        }
        // `--roam-hop`：出门直接跳上窗口，在窗口之间连跳
        if CommandLine.arguments.contains("--roam-hop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.roam.hopNow() }
        }
        // `--roam-nap`：出门后马上找地方打个盹
        // `--roam-knock`：叼着东西出门，去窗口边上推下去
        if CommandLine.arguments.contains("--roam-knock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.roam.knockNow() }
        }
        if CommandLine.arguments.contains("--roam-nap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.roam.napNow() }
        }
        // `--focus-now`：启动后马上开始一个番茄（配合 `--focus-seconds 40` 几分钟看完一整轮）
        if CommandLine.arguments.contains("--focus-now") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.focus.startFocus(minutes: FocusTimer.choices[0])
            }
        }
        if CommandLine.arguments.contains("--roam-now") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.roam.goOutNow() }
        }
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
                // 踢之前按 Esc：不踢了，文件放回原处
                if key == .escape { self?.fileKick.cancel() }
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
        setupFocus()
        setupFileKick()

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
        focus.stopTicking()
        fileKick.stop()
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
            self.updateRoaming(dt: dt, now: now)
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

        menu.addItem(focusMenuItem())
        let kickItem = NSMenuItem(title: "👟 小猫踢飞文件（移到废纸篓）…", action: #selector(kickFileFromMenu),
                                  keyEquivalent: "")
        kickItem.target = self
        kickItem.toolTip = "选文件，小猫跑过去一脚踢飞，文件移到废纸篓（可以放回原处）。"
            + "也可以在 Finder 里右键文件 → 快速操作 / 服务 →「CoolCat 小猫踢飞（移到废纸篓）」"
        kickItem.isEnabled = !fileKick.isBusy
        menu.addItem(kickItem)

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
            roamWindow?.orderOut(nil)
        }
    }

    // MARK: - 满屏漫游

    /// 最近一次跳台扫描（设置里显示有几处能跳、为什么不能跳）
    private var roamScan = RoamScanReport()

    // MARK: 举牌提醒

    /// 这次等待已经送过牌、你也回应过了：不再反复跑过去（等 agent 不等了再重置）
    private var signEpisodeDone = false
    /// 你正在看的窗口（每 0.5 秒看一次）
    private var frontWindow: (id: Int, rect: CGRect)?
    private var lastFrontScan: CFTimeInterval = 0
    /// 设置里「举牌预览」：到这个时刻为止当作 agent 在等你
    private var signDemoUntil: CFTimeInterval = 0
    /// 牌子上的字
    private var signLines: [String] = []

    /// agent 等你批准、你 3 秒没打字（多半在看别的窗口）：小猫去你最前面的窗口顶上举牌；
    /// 窗口顶站不上去就在它正下方的屏幕底边举。每次等待只送一次，开会时不去
    private func updateSignTarget(screen: NSScreen, keyIdle: Double, now: CFTimeInterval) -> RoamSignTarget? {
        if let agent = agentSignTarget(screen: screen, keyIdle: keyIdle, now: now) { return agent }
        // 番茄钟到点：在你的窗口顶上举「第 N 个番茄完成」（agent 等你更要紧，排在前面）；开会时不去
        guard !overlayWindow.catView.physics.isInMeeting else {
            focus.cancelSign()
            return nil
        }
        guard let target = focus.reminderSign(surfaces: roamScan.surfaces, screen: screen, keyIdle: keyIdle, now: now,
                                              holding: roam.isHoldingSign) else { return nil }
        signLines = focus.signLines
        return target
    }

    private func agentSignTarget(screen: NSScreen, keyIdle: Double, now: CFTimeInterval) -> RoamSignTarget? {
        let physics = overlayWindow.catView.physics
        let demo = now < signDemoUntil
        let waiting = physics.agentNeedsYou || demo
        guard waiting else {
            signEpisodeDone = false
            frontWindow = nil
            return nil
        }
        // 送牌路上你打字了：你已经在回应了，这次等待不再送
        if roam.delivering && keyIdle < 0.4 && !demo { signEpisodeDone = true }
        guard CatSettings.shared.agentSign, !signEpisodeDone, !physics.isInMeeting,
              demo || keyIdle >= 3 || roam.delivering else { return nil }
        if now - lastFrontScan > 0.5 {
            let wasNone = frontWindow == nil && !roam.delivering
            lastFrontScan = now
            frontWindow = RoamSurfaceScanner.frontmostWindow(on: screen)
            // 刚开始送：现扫一遍跳台，路线用最新的窗口位置
            if wasNone { rescanRoamSurfaces(on: screen) }
        }
        guard let front = frontWindow else { return nil }
        if demo {
            signLines = ["Claude Code 等你批准", "举牌提醒预览"]
        } else if let line = physics.claudeLines.first(where: { $0.kind == .waiting }) {
            signLines = ["\(line.agent.displayName) \(line.detail)", line.project]
        }
        let k = CatSettings.shared.scale * CatRenderer.walkerArtScale
        let visible = screen.visibleFrame
        return RoamSignTarget.over(windowID: front.id, rect: front.rect, surfaces: roamScan.surfaces,
                                   floorX: visible.minX...visible.maxX, scale: k)
    }

    /// `--roam-log` 打开时往日志里追加一行（调试用）
    private func appendRoamLog(_ text: String) {
        guard let path = roamLogPath else { return }
        let line = text.hasSuffix("\n") ? text : text + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// 小猫「桌面」上的东西：窗口顶积雪、被推下桌的小东西。都画在同一层点击穿透的覆盖层上
    private func updateDesk(dt: CGFloat, screen: NSScreen) {
        updateSnow(dt: dt, screen: screen)
        let visible = screen.visibleFrame
        if !trinkets.isEmpty {
            let floor = RoamSurface(id: 0, minX: visible.minX, maxX: visible.maxX, y: visible.minY + 2)
            trinkets.update(dt: dt, surfaces: [floor] + roamSurfaces, walls: visible.minX...visible.maxX)
        }
        var sprites = trinkets.items.map {
            TrinketSprite(kind: $0.kind, pos: $0.pos, angle: $0.angle, opacity: TrinketPhysics.opacity(of: $0))
        }
        // 放在窗口顶上、正准备拨下去的那个
        if let placed = roam.placedTrinket, let kind = Trinket(rawValue: placed.kind) {
            sprites.append(TrinketSprite(kind: kind, pos: placed.at, angle: 0, opacity: 1))
        }
        let k = CatSettings.shared.scale * CatRenderer.walkerArtScale
        let floor = RoamSurface(id: 0, minX: visible.minX, maxX: visible.maxX, y: visible.minY + 2)
        fileKick.update(dt: dt, surfaces: roamSurfaces, floor: floor, screen: screen, scale: k)
        let files = fileKick.sprites(catX: roam.isHome ? nil : roam.pos.x, scale: k)
        let deskVisible = deskWindow?.isVisible == true
        guard snowpack.hasVisibleSnow || !sprites.isEmpty || !files.isEmpty || deskVisible else { return }
        if deskWindow == nil { deskWindow = DeskOverlayWindow() }
        deskWindow?.render(snowpack, trinkets: sprites, files: files, pointsPerUnit: k, on: screen)
    }

    /// 窗口顶积雪：下雪的季节（或节日预览）里慢慢积；小猫走过踩脚印、跑起来踢雪、抖爪子甩身子
    private func updateSnow(dt: CGFloat, screen: NSScreen) {
        let physics = overlayWindow.catView.physics
        let snowing = physics.activeHoliday.snow
        guard snowing || !snowpack.isEmpty else { return }
        // 真下雪的季节积得慢；预览时几秒就积起来；关掉节日装扮时很快化掉
        let realSeason = CatSettings.shared.holidayDecor && physics.holidaySeason.snow
        let grow = realSeason ? Snowpack.growTime : Snowpack.previewGrowTime
        let melt = CatSettings.shared.holidayDecor ? (realSeason ? Snowpack.meltTime : Snowpack.previewMeltTime) : 3
        snowpack.update(dt: dt, snowing: snowing, growTime: grow, meltTime: melt, surfaces: roamSurfaces,
                        frames: roamScan.frames, floorY: screen.visibleFrame.minY)
        guard !roam.isHome else { return }
        let pose = roam.pose
        let k = CatSettings.shared.scale * CatRenderer.walkerArtScale
        let walker = Snowpack.Walker(pos: roam.pos, surfaceID: roam.surfaceID,
                                     moving: [.walk, .run, .stalk].contains(pose), running: pose == .run,
                                     gaitPhase: roam.gaitPhase, facing: roam.facing)
        snowpack.track(walker, k: k)
        // 抖到一半（爪子甩出去 / 身子拧开）时把雪甩出去
        if pose == .pawShake || pose == .bodyShake {
            if !snowShakeSpawned && roam.shakeProgress > 0.3 {
                snowShakeSpawned = true
                snowpack.shakeOff(pose == .pawShake ? .paw : .body, at: roam.pos, facing: roam.facing, k: k)
            }
        } else {
            snowShakeSpawned = false
        }
    }

    private func rescanRoamSurfaces(on screen: NSScreen) {
        // 侧身小猫放大后站着约 150 画布点高
        let walkerK = CatSettings.shared.scale * CatRenderer.walkerArtScale
        let previous = roamScan
        roamScan = RoamSurfaceScanner.scan(on: screen, catHeight: 120 * walkerK, minWidth: 110 * walkerK)
        roamSurfaces = roamScan.surfaces + surfacesInGrace(previous: previous, now: CACurrentMediaTime())
    }

    /// 窗口还在、也没挪，只是这一次扫描里它的上沿没了（一闪而过的菜单、提示框挡了一下）：
    /// 先留着这段上沿 0.8 秒，免得站在上面的小猫和东西凭空掉下去。窗口真关了、挪了就立刻不算
    private func surfacesInGrace(previous: RoamScanReport, now: CFTimeInterval) -> [RoamSurface] {
        let present = Set(roamScan.surfaces.map(\.id))
        surfaceGraceSince = surfaceGraceSince.filter { !present.contains($0.key) }
        var kept: [RoamSurface] = []
        for old in roamSurfaces where !present.contains(old.id) {
            guard let window = Snowpack.windowID(of: old.id),
                  let frame = roamScan.frames[window], let before = previous.frames[window],
                  !Snowpack.moved(before, frame) else { continue }
            let since = surfaceGraceSince[old.id] ?? now
            guard now - since < 0.8 else { continue }
            surfaceGraceSince[old.id] = since
            kept.append(old)
        }
        return kept
    }

    /// 每帧：把屏幕上能落脚的面、座位位置、按键空闲时长喂给漫游逻辑，再摆好侧身小猫
    private func updateRoaming(dt: CGFloat, now: CFTimeInterval) {
        let settings = CatSettings.shared
        let physics = overlayWindow.catView.physics
        guard let homeScreen = overlayWindow.screen ?? NSScreen.main else { return }
        let (screen, holdKick) = roamScreen(home: homeScreen)
        let k = settings.scale
        let home = overlayWindow.frame
        let visible = screen.visibleFrame
        // 换了一块屏幕活动：马上重扫那块屏幕上的窗口
        if screen != lastRoamScreen {
            lastRoamScreen = screen
            lastSurfaceScan = 0
        }
        // 窗口上沿：在外面溜达时每秒扫一次，在家时 5 秒一次（出门那一刻用得上）；
        // 窗口顶有雪时 0.3 秒一次：窗口一拖，雪要马上滑下来，不能悬在半空
        let deskBusy = snowpack.hasVisibleSnow || !trinkets.isEmpty || roam.placedTrinket != nil || fileKick.hasFiles
        let scanEvery: CFTimeInterval = deskBusy ? 0.3 : (roam.isHome ? 5 : 1)
        if now - lastSurfaceScan > scanEvery {
            lastSurfaceScan = now
            rescanRoamSurfaces(on: screen)
        }
        let engine = InputEngine.shared
        // 启动后还没按过键：从启动那一刻算闲置，免得被当成「人早就走了」而一直不出门
        if roamClockStart == 0 { roamClockStart = now }
        // `--roam-ignore-keys`（调试用）：漫游逻辑当作一直没人打字，方便在打字时实机观察整段行为
        let keyIdle = ignoreKeysForRoaming ? 1000 : now - max(engine.lastKeyActivityTime, roamClockStart)
        let signTarget = updateSignTarget(screen: screen, keyIdle: keyIdle, now: now)
        let focusSpot = focus.focusSpot(surfaces: roamSurfaces, screen: screen, now: now)
        let floor = RoamSurface(id: 0, minX: visible.minX, maxX: visible.maxX, y: visible.minY + 2)
        // 文件在另一块屏幕上、小猫正在这块屏幕上溜达：先叫它回座位，再从座位跳过去
        // 好几个文件时从近到远：离小猫（在座位上就是座位）最近的先踢
        let catSpot = roam.isHome ? CGPoint(x: home.midX, y: home.minY) : roam.pos
        let kickTarget = holdKick ? nil : fileKick.kickTarget(surfaces: roamSurfaces, floor: floor,
                                                              scale: k * CatRenderer.walkerArtScale, from: catSpot)
        let world = RoamWorld(
            floor: floor,
            windowTops: roamSurfaces,
            seat: CGPoint(x: home.minX + CatPhysics.seatAnchor.x * k, y: home.maxY - CatPhysics.seatAnchor.y * k),
            homeRect: home,
            keyIdle: keyIdle,
            // 举牌预览期间不管打字：你可能正在别处打字，预览也要看得到
            // 到点举牌的路上也不管打字：番茄钟是你自己定的，到点就该叫你
            userActive: keyIdle < 0.4 && now >= signDemoUntil && !focus.signIgnoresTyping(now: now),
            // 送牌时只有开会才拦得住（听歌时也去：agent 等你比跟着歌摇更要紧）
            // 陪你专注时也一样：只有开会叫得回去（听歌时照样陪你，不回座位摇摆）
            // 踢文件是你刚叫它去的：开会、跳舞都拦不住
            mustStayHome: holdKick || (kickTarget != nil ? false
                : (signTarget != nil || focusSpot != nil ? physics.isInMeeting : physics.prefersStayingHome)),
            wanderAllowed: settings.roaming && !physics.agentNeedsYou && focus.timer.phase != .focusing,
            needsAttention: physics.agentNeedsYou,
            // 走路速度、跳跃距离跟着侧身小猫的体型放大
            scale: k * CatRenderer.walkerArtScale,
            screenTop: visible.maxY,
            // 光标逗猫：只看小猫这块屏幕上的光标；设置里关了就当没有
            cursor: settings.cursorPlay && screen.frame.contains(NSEvent.mouseLocation) ? NSEvent.mouseLocation : nil,
            cursorSpeed: hypot(engine.mouseVelocity.dx, engine.mouseVelocity.dy),
            walls: roamScan.walls,
            signTarget: signTarget,
            focusSpot: focusSpot,
            snowySurfaces: snowpack.snowySurfaces,
            knockAllowed: settings.knockThings,
            kickTarget: kickTarget
        )
        if let path = roamLogPath, now - lastRoamLog > 0.5 {
            lastRoamLog = now
            let format = "%.1f home=%d pose=%@ pos=(%.0f,%.0f) surf=%@ seat=(%.0f,%.0f) homeFrame=%@ visible=%@ "
                + "tops=%d win=%@ stay=%d idle=%.0f fp=%@ act=%@ why=%@ dlv=%d snow=%@ knk=%@ scan=%@\n"
            // 积雪：窗口数 / 最厚 / 脚印 / 雪块 / 爪子沾雪
            let snowState = String(format: "%d/%.2f/%d/%d/%.2f", snowpack.caps.count,
                                   snowpack.caps.values.map(\.depth).max() ?? 0, snowpack.prints.count,
                                   snowpack.clumps.count, snowpack.pawSnow)
            // 推东西：嘴里叼着 / 放在窗口顶上 / 掉下来的个数
            let holding = roam.carriedTrinket.map { "mouth\($0)" } ?? (roam.placedTrinket != nil ? "placed" : "-")
            let knockState = "\(holding)/\(trinkets.items.count)"
            let line = String(format: format,
                              now, roam.isHome ? 1 : 0, "\(roam.pose)", roam.pos.x, roam.pos.y, "\(roam.surfaceID.map(String.init) ?? "-")",
                              world.seat.x, world.seat.y, NSStringFromRect(home), NSStringFromRect(visible), roamSurfaces.count,
                              NSStringFromRect(roamWindow?.frame ?? .zero), world.mustStayHome ? 1 : 0, keyIdle, "\(roam.pendingForcedPeek.map { "\($0)" } ?? "-")", "\(roam.activity.map { "\($0)" } ?? "-")".prefix(40).description,
                              physics.stayHomeReason ?? "-", roam.delivering ? 1 : 0,
                              snowState, knockState, roamScan.summary)
            appendRoamLog(line)
        }
        for event in roam.update(dt: dt, world: world) {
            switch event {
            case .leftSeat: physics.catAway = true
            case .arrivedHome: physics.landBackInSeat()
            case .landed: snowpack.puff(at: roam.pos, surfaceID: roam.surfaceID)
            case .caughtCursor: physics.roamPlayResult(caught: true)
            case .missedCursor: physics.roamPlayResult(caught: false)
            case .releasedTrinket(let kind, let at, let vx):
                // 推下去的往外翻跟头；从嘴里掉下来的轻轻转一点
                let spin = vx == 0 ? CGFloat.random(in: -2...2) : vx / 14
                trinkets.release(Trinket(rawValue: kind) ?? .pen, at: at, vx: vx, spin: spin)
                appendRoamLog(String(format: "RELEASE vx=%.0f at=(%.0f,%.0f) surf=%@ tops=%@", vx, at.x, at.y,
                                     roam.surfaceID.map(String.init) ?? "-",
                                     roamSurfaces.map { "\($0.id):\(Int($0.minX))-\(Int($0.maxX))@\(Int($0.y))" }
                                        .joined(separator: ",")))
            case .kickedFile(let angle, let dir): fileKick.kicked(angle: angle, dir: dir)
            case .kickTargetUnreachable: fileKick.targetUnreachable()
            }
        }
        awayScreen = roam.isHome || screen == homeScreen ? nil : screen
        updateDesk(dt: dt, screen: screen)
        guard !roam.isHome else {
            if roamWindow?.isVisible == true { roamWindow?.orderOut(nil) }
            return
        }
        let window: RoamWindow
        if let existing = roamWindow {
            window = existing
        } else {
            window = RoamWindow()
            roamWindow = window
        }
        window.place(feet: roam.pos, scale: k,
                     anchor: roam.climbWallOnRight.map { CatRenderer.climbAnchor(wallOnRight: $0) } ?? CatRenderer.walkerFeet)
        window.walkerView.pose = CatRenderer.WalkerPose(
            pose: roam.pose, phase: roam.gaitPhase, facing: roam.facing, air: roam.airProgress,
            time: physics.time, blink: physics.time.truncatingRemainder(dividingBy: 4.1) < 0.13,
            peekEdge: roam.peekEdge, peekReveal: roam.peekReveal, sink: roam.sinkDepth,
            curl: roam.napCurl, asleep: roam.napAsleep, hunting: roam.isPlaying,
            santaHat: physics.activeHoliday.christmas, signLines: signLines,
            shake: roam.shakeProgress, pawSnow: snowpack.pawSnow, tap: roam.tapProgress,
            trinket: roam.carriedTrinket.flatMap(Trinket.init(rawValue:)),
            runBlend: roam.runBlend, moveBlend: roam.moveBlend,
            crouchProgress: roam.crouchProgress, landProgress: roam.landProgress,
            skidding: roam.isSkidding, turnScale: roam.turnScale,
            focusLeft: roam.isFocusNapping ? focus.fractionLeft : nil,
            kickTime: roam.kickPose?.t ?? 0, kickAngle: roam.kickPose?.angle ?? 0
        )
        // 屏幕边换算到画布坐标：走出屏幕、偷看时屏幕外的部分不画
        // 跨屏大跳的半空中（还在别的屏幕上）：不裁，整只猫飞过去
        let leapingAcross = roam.pose == .air && !screen.frame.contains(roam.pos)
        if let clip = roam.clipEdge, !leapingAcross {
            let K = k * CatRenderer.walkerArtScale
            let f = window.frame
            switch clip.edge {
            case .left, .right: window.walkerView.clip = (clip.edge, (clip.at - f.minX) / K)
            case .bottom: window.walkerView.clip = (.bottom, CatRenderer.walkerCanvas.height - (clip.at - f.minY) / K)
            }
        } else {
            window.walkerView.clip = nil
        }
        window.walkerView.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    // MARK: - 番茄钟

    // MARK: - 踢飞文件

    /// 这一帧小猫在哪块屏幕上活动：平时在座位那块；要踢的文件在别的屏幕上时去那块。
    /// 正在另一块屏幕上溜达时先不去（holdKick：叫它回座位，回来了再从座位跳过去）
    private func roamScreen(home: NSScreen) -> (screen: NSScreen, holdKick: Bool) {
        let here = roam.isHome ? nil : awayScreen
        guard fileKick.isBusy else { return (here ?? home, false) }
        let target = fileKick.targetScreen ?? home
        if roam.isHome { return (target, false) }
        let current = here ?? home
        return (current, current != target)
    }

    private func setupFileKick() {
        fileKick.onNotice = { [weak self] text in self?.overlayWindow.catView.physics.showNotice(text) }
        fileKick.canKick = { [weak self] in self?.isPetVisible ?? false }
        fileKick.start()
        // Finder 右键 → 服务 →「CoolCat 小猫踢飞（移到废纸篓）」（Info.plist 的 NSServices）
        NSApp.servicesProvider = fileKick
        NSUpdateDynamicServices()
        // `--kick-file <路径> [--kick-file <路径> …] [--kick-at x,y]`（调试用）：启动 2 秒后踢这些文件，
        // 相当于在光标（或 x,y，屏幕坐标）那儿右键了它们
        let arguments = CommandLine.arguments
        let urls = arguments.indices.filter { arguments[$0] == "--kick-file" && $0 + 1 < arguments.count }
            .map { URL(fileURLWithPath: arguments[$0 + 1]) }
        if !urls.isEmpty {
            let spot = arguments.firstIndex(of: "--kick-at").flatMap { index -> CGPoint? in
                guard index + 1 < arguments.count else { return nil }
                let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.fileKick.request(urls, at: spot ?? NSEvent.mouseLocation)
            }
        }
    }

    /// 菜单「踢飞文件…」：选文件，从屏幕顶上掉下来让小猫踢
    @objc private func kickFileFromMenu() {
        let panel = NSOpenPanel()
        panel.title = "选要让小猫踢飞的文件（会移到废纸篓）"
        panel.prompt = "让小猫踢"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.fileKick.request(panel.urls, at: nil)
        }
    }

    private func setupFocus() {
        focus.onEvent = { [weak self] event in
            guard let self else { return }
            let physics = self.overlayWindow.catView.physics
            switch event {
            case .focusDone:
                // 调试时几十秒一个番茄：不算亲密度
                if !self.focus.isDebug { physics.completedFocus() }
            case .restDone: physics.showNotice("☕ 休息好啦，再来一个番茄？")
            }
        }
        focus.onTick = { [weak self] in self?.refreshFocusStatus() }
        focus.startTicking()
    }

    /// 菜单栏：番茄钟开着时在小猫图标右边显示倒计时（休息时带个 ☕）
    private func refreshFocusStatus() {
        guard let item = statusItem, let button = item.button else { return }
        let timer = focus.timer
        guard timer.isRunning else {
            if item.length != NSStatusItem.squareLength {
                item.length = NSStatusItem.squareLength
                button.title = ""
                button.imagePosition = .imageOnly
                button.toolTip = "CoolCat 黑猫键盘桌宠"
            }
            return
        }
        item.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeft
        let resting = timer.phase == .resting
        let text = (resting ? " ☕ " : " ") + FocusTimer.clock(focus.remaining)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        button.toolTip = resting ? "休息中，到点小猫会叫你" : "专注中，小猫在你的窗口上陪你"
    }

    /// 菜单里的番茄钟：没开时选时长，专注 / 休息时显示还剩多久和能做的事
    private func focusMenuItem() -> NSMenuItem {
        let timer = focus.timer
        let left = Int((focus.remaining / 60).rounded(.up))
        let title: String
        switch timer.phase {
        case .idle: title = "🍅 番茄钟"
        case .focusing: title = "🍅 专注中 · 还剩 \(left) 分钟"
        case .resting: title = "☕ 休息中 · 还剩 \(left) 分钟"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }
        switch timer.phase {
        case .idle:
            for minutes in FocusTimer.choices {
                add("专注 \(minutes) 分钟", #selector(startFocusFromMenu(_:)), tag: minutes)
            }
        case .focusing:
            add("提前结束这个番茄", #selector(stopFocusFromMenu))
        case .resting:
            add("跳过休息，再专注 \(max(1, Int(timer.focusDuration / 60))) 分钟", #selector(skipFocusRestFromMenu))
            add("结束番茄钟", #selector(stopFocusFromMenu))
        }
        menu.addItem(.separator())
        let hint = timer.completedToday > 0
            ? "今天完成了 \(timer.completedToday) 个番茄"
            : "专注时小猫趴在你的窗口上陪你，到点举牌叫你休息"
        let hintItem = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        item.submenu = menu
        return item
    }

    @objc private func startFocusFromMenu(_ sender: NSMenuItem) {
        focus.startFocus(minutes: sender.tag > 0 ? sender.tag : FocusTimer.choices[0])
    }

    @objc private func skipFocusRestFromMenu() { focus.skipRest() }

    @objc private func stopFocusFromMenu() { focus.stop() }

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
            // 开着番茄钟时休息由番茄钟管，不再另外提醒久坐
            options.workBreak = settings.lifeWorkBreak && !self.focus.timer.isRunning
            let engine = InputEngine.shared
            let lastInput = max(engine.lastKeyActivityTime, max(engine.lastMouseMoveTime, engine.lastMouseClickTime))
            let battery = PowerSourceProbe.read()
            let events = self.lifeCompanion.update(date: Date(), clock: CACurrentMediaTime(), lastInput: lastInput,
                                                   battery: battery, options: options)
            if let day = self.lifeCompanion.coffeeDay {
                UserDefaults.standard.set(day, forKey: "CoolCat.LastCoffeeDay")
            }
            let physics = self.overlayWindow.catView.physics
            physics.setHoliday(HolidaySeason.on(Date()))
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

    func applyWindowBehavior() {
        overlayWindow.applyWindowLevelAndBehavior()
        roamWindow?.applyWindowLevelAndBehavior()
        deskWindow?.applyWindowLevelAndBehavior()
    }

    func audioSettingsChanged(resetPermission: Bool) {
        // 重新打开实时音频 = 用户想再试一次（可能刚在系统设置里授了权）
        if resetPermission { AudioSpectrumAnalyzer.shared.resetPermissionMemory() }
        applyAudioActivity(MusicMonitor.shared.activity)
    }

    func selectCoat(_ coat: CatCoatTheme) {
        let settings = CatSettings.shared
        // 选回经典猫：清掉新猫的选择
        PetLibrary.shared.select(nil)
        settings.coatTheme = coat
        // 换毛色时配上招牌瞳色（之后仍可单独改）
        settings.eyeTheme = coat.signatureEye
    }

    func resetPetPosition() { resetPosition() }
    func relaunch() { relaunchApp() }
    func openInputMonitoring() { openInputMonitoringSettings() }
    func install(_ agent: CodingAgent) { installHooks(for: agent) }
    func uninstall(_ agent: CodingAgent) { uninstallHooks(for: agent) }

    var roamPlatformStatus: String { roamScan.summary }

    func runDemo(_ demo: SettingsDemo) {
        switch demo {
        case .typing: runDemoBurst()
        case .life: runLifeDemo()
        case .meeting: runMeetingDemo()
        case .claude: runAgentDemo(.claude)
        case .codex: runAgentDemo(.codex)
        case .gift: physics.offerGift()
        case .holiday: physics.previewHoliday()
        case .sign: signDemoUntil = CACurrentMediaTime() + 20
        case .roam, .peek, .nap, .hop, .knock:
            // 正在做只能在座位上做的事：提示一下，不然点了像没反应
            if let reason = physics.stayHomeReason {
                physics.explainCannotRoam(reason)
                return
            }
            if demo == .peek {
                roam.peekNow(edge: [RoamEdge.bottom, .left, .right].randomElement())
            } else if demo == .nap {
                roam.napNow()
            } else if demo == .knock {
                // 先现扫一遍：没有够宽的窗口顶就说明原因
                if let screen = overlayWindow.screen ?? NSScreen.main { rescanRoamSurfaces(on: screen) }
                let k = CatSettings.shared.scale * CatRenderer.walkerArtScale
                guard roamScan.surfaces.contains(where: { $0.width >= 170 * k }) else {
                    physics.showNotice("😼 没有够宽的窗口顶可以推东西。" + roamScan.summary)
                    return
                }
                roam.knockNow()
            } else if demo == .hop {
                // 先现扫一遍：没有能跳的窗口就说明原因，不然点了像没反应
                if let screen = overlayWindow.screen ?? NSScreen.main { rescanRoamSurfaces(on: screen) }
                guard !roamScan.surfaces.isEmpty else {
                    physics.showNotice("🪟 " + roamScan.summary)
                    return
                }
                roam.hopNow()
            } else {
                roam.goOutNow()
            }
        }
    }
}
