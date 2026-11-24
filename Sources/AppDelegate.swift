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
        ClaudeHookInstaller.repairIfOutdated()
        suggestClaudeIntegrationIfNeeded()

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
            if CatSettings.shared.claudeIntegration {
                let tracker = ClaudeActivityTracker.shared
                view.physics.updateClaude(tracker.status(now: now))
                // 明细每秒刷新 4 次就够（耗时按秒显示），不必每帧排序拼字符串
                if now - self.lastClaudeLinesUpdate >= 0.25 {
                    self.lastClaudeLinesUpdate = now
                    view.physics.claudeLines = tracker.lines(now: now)
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

        // Visibility & Interactive modes
        let visItem = NSMenuItem(title: isPetVisible ? "隐藏小黑猫" : "显示小黑猫", action: #selector(toggleVisibility), keyEquivalent: "")
        visItem.target = self
        menu.addItem(visItem)

        let clickThroughItem = NSMenuItem(title: "完全鼠标穿透 (按住 ⌥Option 可临时右键/拖动)", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThroughItem.target = self
        clickThroughItem.state = settings.fullClickThrough ? .on : .off
        menu.addItem(clickThroughItem)

        let fullscreenItem = NSMenuItem(title: "全屏游戏/应用置顶显示", action: #selector(toggleFullScreenOverlay), keyEquivalent: "")
        fullscreenItem.target = self
        fullscreenItem.state = settings.fullScreenOverlay ? .on : .off
        menu.addItem(fullscreenItem)

        let autoStartItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStartItem.target = self
        autoStartItem.state = isAutoStartEnabled() ? .on : .off
        menu.addItem(autoStartItem)

        menu.addItem(.separator())

        // Features
        let badgesItem = NSMenuItem(title: "显示按键气泡 ([S] [W] [⇧])", action: #selector(toggleKeyBadges), keyEquivalent: "")
        badgesItem.target = self
        badgesItem.state = settings.showKeyBadges ? .on : .off
        menu.addItem(badgesItem)

        let mouseBadgesItem = NSMenuItem(title: "显示鼠标点击气泡 ([左键] [右键])", action: #selector(toggleMouseBadges), keyEquivalent: "")
        mouseBadgesItem.target = self
        mouseBadgesItem.state = settings.showMouseBadges ? .on : .off
        menu.addItem(mouseBadgesItem)

        let legendsItem = NSMenuItem(title: "显示键盘字符", action: #selector(toggleKeyLegends), keyEquivalent: "")
        legendsItem.target = self
        legendsItem.state = settings.showKeyLegends ? .on : .off
        menu.addItem(legendsItem)

        let footItem = NSMenuItem(title: "3键同时按「用脚按」彩蛋 🐾", action: #selector(toggleFootEgg), keyEquivalent: "")
        footItem.target = self
        footItem.state = settings.footEasterEgg ? .on : .off
        menu.addItem(footItem)

        let petItem = NSMenuItem(title: "摸头/摸背闭眼互动", action: #selector(togglePetInteraction), keyEquivalent: "")
        petItem.target = self
        petItem.state = settings.petInteraction ? .on : .off
        menu.addItem(petItem)

        let habitItem = NSMenuItem(title: "键盘习惯小反应（⌫冒汗 / ⌘S盖章 / 截图比耶 / KPM皇冠）", action: #selector(toggleKeyHabits), keyEquivalent: "")
        habitItem.target = self
        habitItem.state = settings.keyHabitReactions ? .on : .off
        menu.addItem(habitItem)

        menu.addItem(buildLifeMenuItem())

        let idleItem = NSMenuItem(title: "空闲时的小动作（打哈欠 / 伸懒腰 / 踩奶 / 慢眨眼……）", action: #selector(toggleIdleAnimations), keyEquivalent: "")
        idleItem.target = self
        idleItem.state = settings.idleAnimations ? .on : .off
        menu.addItem(idleItem)

        let musicMenu = NSMenu()
        let headphonesItem = NSMenuItem(title: "听歌时戴耳机摇头 🎧", action: #selector(toggleMusicHeadphones), keyEquivalent: "")
        headphonesItem.target = self
        headphonesItem.state = settings.musicHeadphones ? .on : .off
        musicMenu.addItem(headphonesItem)
        let anyAudioItem = NSMenuItem(title: "看视频/玩游戏有声音时也戴", action: #selector(toggleHeadphonesForAnyAudio), keyEquivalent: "")
        anyAudioItem.target = self
        anyAudioItem.state = settings.headphonesForAnyAudio ? .on : .off
        musicMenu.addItem(anyAudioItem)
        let bubbleItem = NSMenuItem(title: "切歌时显示歌名气泡", action: #selector(toggleTrackBubble), keyEquivalent: "")
        bubbleItem.target = self
        bubbleItem.state = settings.showTrackBubble ? .on : .off
        musicMenu.addItem(bubbleItem)
        musicMenu.addItem(.separator())
        let haloItem = NSMenuItem(title: "猫身后的频谱墙 🎛", action: #selector(toggleMusicVisualizer), keyEquivalent: "")
        haloItem.target = self
        haloItem.state = settings.musicVisualizer ? .on : .off
        musicMenu.addItem(haloItem)
        let danceItem = NSMenuItem(title: "没在打字时跟着节奏跳舞 💃", action: #selector(toggleMusicDance), keyEquivalent: "")
        danceItem.target = self
        danceItem.state = settings.musicDance ? .on : .off
        musicMenu.addItem(danceItem)
        let realItem = NSMenuItem(title: "跟随真实音频节拍（需「录制系统音频」授权）", action: #selector(toggleRealAudio), keyEquivalent: "")
        realItem.target = self
        realItem.state = settings.realAudioAnalysis ? .on : .off
        musicMenu.addItem(realItem)
        let analyzerText: String
        switch AudioSpectrumAnalyzer.shared.state {
        case .off: analyzerText = settings.realAudioAnalysis ? "实时音频：等音乐响起时启动" : "实时音频：已关闭，使用模拟节拍"
        case .starting: analyzerText = "实时音频：启动中…"
        case .running:
            let bpm = AudioSpectrumAnalyzer.shared.snapshot().bpm.map { "，约 \(Int($0)) BPM" } ?? ""
            analyzerText = "实时音频：分析中\(bpm)"
        case .silentNoPermission: analyzerText = "⚠️ 实时音频：只收到静音。在「隐私与安全性 → 录屏与系统录音」允许 CoolCat 后，重新勾选上一项"
        case .unsupported: analyzerText = "实时音频：需要 macOS 14.2+，当前使用模拟节拍"
        case .failed(let reason): analyzerText = "实时音频启动失败：\(reason)"
        }
        let analyzerItem = NSMenuItem(title: analyzerText, action: nil, keyEquivalent: "")
        analyzerItem.isEnabled = false
        musicMenu.addItem(analyzerItem)
        let nowItem: NSMenuItem
        switch MusicMonitor.shared.activity {
        case .music(let app): nowItem = NSMenuItem(title: "正在听：\(app)", action: nil, keyEquivalent: "")
        case .otherAudio: nowItem = NSMenuItem(title: "检测到其他 App 在出声", action: nil, keyEquivalent: "")
        case .silent: nowItem = NSMenuItem(title: "当前没有声音", action: nil, keyEquivalent: "")
        }
        nowItem.isEnabled = false
        musicMenu.addItem(.separator())
        musicMenu.addItem(nowItem)
        let musicParent = NSMenuItem(title: "音乐 🎵", action: nil, keyEquivalent: "")
        musicParent.submenu = musicMenu
        menu.addItem(musicParent)

        menu.addItem(buildMeetingMenuItem())
        menu.addItem(buildClaudeMenuItem())

        menu.addItem(.separator())

        // Scale submenu
        let scaleMenu = NSMenu()
        let scales: [(String, CGFloat)] = [
            ("迷你 (0.65x)", 0.65),
            ("偏小 (0.85x)", 0.85),
            ("标准 (1.0x)", 1.0),
            ("偏大 (1.25x)", 1.25),
            ("超大 (1.5x)", 1.5)
        ]
        for (title, val) in scales {
            let item = NSMenuItem(title: title, action: #selector(selectScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(val))
            item.state = abs(settings.scale - val) < 0.05 ? .on : .off
            scaleMenu.addItem(item)
        }
        let scaleParent = NSMenuItem(title: "尺寸大小", action: nil, keyEquivalent: "")
        scaleParent.submenu = scaleMenu
        menu.addItem(scaleParent)

        // Cat coat submenu: original skins plus approved shorthair and orange-white.
        let coatMenu = NSMenu()
        for coat in CatCoatTheme.allCases {
            let item = NSMenuItem(title: coat.rawValue, action: #selector(selectCoatTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = coat.rawValue
            item.state = settings.coatTheme == coat ? .on : .off
            coatMenu.addItem(item)
        }
        let coatParent = NSMenuItem(title: "猫咪皮肤 🐱", action: nil, keyEquivalent: "")
        coatParent.submenu = coatMenu
        menu.addItem(coatParent)

        // Keyboard Theme submenu
        let kbMenu = NSMenu()
        for theme in KeyboardTheme.allCases {
            let item = NSMenuItem(title: theme.rawValue, action: #selector(selectKeyboardTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = theme.rawValue
            item.state = settings.keyboardTheme == theme ? .on : .off
            kbMenu.addItem(item)
        }
        let kbParent = NSMenuItem(title: "键盘配色", action: nil, keyEquivalent: "")
        kbParent.submenu = kbMenu
        menu.addItem(kbParent)

        // Eye Color submenu
        let eyeMenu = NSMenu()
        for eye in EyeColorTheme.allCases {
            let item = NSMenuItem(title: eye.rawValue, action: #selector(selectEyeTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = eye.rawValue
            item.state = settings.eyeTheme == eye ? .on : .off
            eyeMenu.addItem(item)
        }
        let eyeParent = NSMenuItem(title: "瞳色切换", action: nil, keyEquivalent: "")
        eyeParent.submenu = eyeMenu
        menu.addItem(eyeParent)

        menu.addItem(.separator())

        let demoItem = NSMenuItem(title: "🎬 演示打字 + 摸猫动画", action: #selector(runDemoBurst), keyEquivalent: "")
        demoItem.target = self
        menu.addItem(demoItem)

        let resetPosItem = NSMenuItem(title: "重置位置到右下角", action: #selector(resetPosition), keyEquivalent: "")
        resetPosItem.target = self
        menu.addItem(resetPosItem)

        let relaunchItem = NSMenuItem(title: "重启 CoolCat (授权后刷新)", action: #selector(relaunchApp), keyEquivalent: "")
        relaunchItem.target = self
        menu.addItem(relaunchItem)

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

        menu.addItem(.separator())

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

    @objc private func toggleVisibility() {
        isPetVisible.toggle()
        if isPetVisible {
            overlayWindow.orderFrontRegardless()
        } else {
            overlayWindow.orderOut(nil)
        }
    }

    @objc private func toggleClickThrough() {
        CatSettings.shared.fullClickThrough.toggle()
    }

    @objc private func toggleFullScreenOverlay() {
        CatSettings.shared.fullScreenOverlay.toggle()
        overlayWindow.applyWindowLevelAndBehavior()
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

    @objc private func toggleAutoStart() {
        _ = setAutoStartEnabled(!isAutoStartEnabled())
    }

    @objc private func toggleKeyBadges() {
        CatSettings.shared.showKeyBadges.toggle()
    }

    @objc private func toggleMouseBadges() {
        CatSettings.shared.showMouseBadges.toggle()
    }

    @objc private func toggleKeyLegends() {
        CatSettings.shared.showKeyLegends.toggle()
    }

    @objc private func toggleFootEgg() {
        CatSettings.shared.footEasterEgg.toggle()
    }

    @objc private func togglePetInteraction() {
        CatSettings.shared.petInteraction.toggle()
    }

    @objc private func toggleKeyHabits() {
        CatSettings.shared.keyHabitReactions.toggle()
    }

    @objc private func toggleMusicHeadphones() {
        CatSettings.shared.musicHeadphones.toggle()
    }

    @objc private func toggleHeadphonesForAnyAudio() {
        CatSettings.shared.headphonesForAnyAudio.toggle()
        applyAudioActivity(MusicMonitor.shared.activity)
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

    private func buildLifeMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        let settings = CatSettings.shared
        func toggle(_ title: String, _ on: Bool, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
            sub.addItem(item)
        }
        toggle("🌙 深夜戴睡帽、提醒早点睡", settings.lifeNight, #selector(toggleLifeNight))
        toggle("☀️ 早上第一次开工端咖啡", settings.lifeMorning, #selector(toggleLifeMorning))
        toggle("🪫 低电量没精神 / ⚡ 插电喝奶", settings.lifeBattery, #selector(toggleLifeBattery))
        toggle("💧 连续工作 50 分钟提醒喝水", settings.lifeWorkBreak, #selector(toggleLifeWorkBreak))
        sub.addItem(.separator())
        let demo = NSMenuItem(title: "🎬 演示：睡帽 → 咖啡 → 没电 → 插电 → 喝水", action: #selector(runLifeDemo), keyEquivalent: "")
        demo.target = self
        sub.addItem(demo)
        let parent = NSMenuItem(title: "生活陪伴 🌙", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    @objc private func toggleLifeNight() { CatSettings.shared.lifeNight.toggle() }
    @objc private func toggleLifeMorning() { CatSettings.shared.lifeMorning.toggle() }
    @objc private func toggleLifeBattery() { CatSettings.shared.lifeBattery.toggle() }
    @objc private func toggleLifeWorkBreak() { CatSettings.shared.lifeWorkBreak.toggle() }

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

    private func buildMeetingMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        let state = MeetingMonitor.shared.state
        var parts: [String] = []
        if state.micActive { parts.append("🎙 " + (state.micApp ?? "麦克风") + " 在用") }
        if state.cameraActive { parts.append("📷 摄像头开着") }
        let statusItem = NSMenuItem(title: parts.isEmpty ? "当前没有在开会" : parts.joined(separator: " · "), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        sub.addItem(statusItem)
        sub.addItem(.separator())

        let modeItem = NSMenuItem(title: "开麦戴耳麦、开摄像头先洗脸", action: #selector(toggleMeetingMode), keyEquivalent: "")
        modeItem.target = self
        modeItem.state = CatSettings.shared.meetingMode ? .on : .off
        sub.addItem(modeItem)
        let noiseItem = NSMenuItem(title: "开麦时打字太猛提醒「嘘」🤫", action: #selector(toggleKeyboardNoiseReminder), keyEquivalent: "")
        noiseItem.target = self
        noiseItem.state = CatSettings.shared.keyboardNoiseReminder ? .on : .off
        sub.addItem(noiseItem)
        sub.addItem(.separator())
        let demoItem = NSMenuItem(title: "🎬 演示：开摄像头 → 开麦 → 打字太吵", action: #selector(runMeetingDemo), keyEquivalent: "")
        demoItem.target = self
        sub.addItem(demoItem)

        let parent = NSMenuItem(title: "会议模式 🎙", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    @objc private func toggleMeetingMode() {
        CatSettings.shared.meetingMode.toggle()
    }

    @objc private func toggleKeyboardNoiseReminder() {
        CatSettings.shared.keyboardNoiseReminder.toggle()
    }

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
    private func suggestClaudeIntegrationIfNeeded() {
        let key = "CoolCat.SuggestedClaudeIntegration"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        guard FileManager.default.fileExists(atPath: claudeDir), ClaudeHookInstaller.state() == .notInstalled else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.overlayWindow.catView.physics.showNotice("🤖 发现 Claude Code：右键我 →「Claude Code 联动」→ 连接")
        }
    }

    // 可能运行 Claude Code 的宿主 App（bundle ID 小写子串）
    private static let claudeHostTokens = [
        "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby",
        "vscode", "todesktop", "cursor", "windsurf", "zed", "jetbrains", "xcode", "anthropic", "claude"
    ]

    private static let terminalTokens = [
        "terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "anthropic", "claude"
    ]
    private static let clickablePromptTokens = ["anthropic", "claude", "vscode", "todesktop", "cursor", "windsurf", "zed"]

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

    private func buildClaudeMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        let state = ClaudeHookInstaller.state()

        let statusText: String
        switch state {
        case .notInstalled: statusText = "未连接 Claude Code"
        case .outdated: statusText = "⚠️ hook 指向旧的 CoolCat 位置，需要重新连接"
        case .installed: statusText = "已连接 Claude Code"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        sub.addItem(statusItem)
        // 逐会话列出：项目 · 动作 · 耗时
        let now = CACurrentMediaTime()
        let lines = ClaudeActivityTracker.shared.lines(now: now)
        if state == .installed && lines.isEmpty {
            let idleItem = NSMenuItem(title: "    所有会话都空闲", action: nil, keyEquivalent: "")
            idleItem.isEnabled = false
            sub.addItem(idleItem)
        }
        for line in lines {
            let elapsed = line.elapsed.map { " · " + ClaudeActivityTracker.formatElapsed($0) } ?? ""
            let item = NSMenuItem(title: "    \(line.project) · \(line.detail)\(elapsed)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
        }
        sub.addItem(.separator())

        let enabledItem = NSMenuItem(title: "显示 Claude 状态气泡与动作", action: #selector(toggleClaudeIntegration), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = CatSettings.shared.claudeIntegration ? .on : .off
        sub.addItem(enabledItem)

        let installTitle = state == .notInstalled ? "连接 Claude Code（写入 ~/.claude/settings.json）..." : "重新连接 Claude Code"
        let installItem = NSMenuItem(title: installTitle, action: #selector(installClaudeHooks), keyEquivalent: "")
        installItem.target = self
        sub.addItem(installItem)
        if state != .notInstalled {
            let uninstallItem = NSMenuItem(title: "断开 Claude Code（移除 hook）", action: #selector(uninstallClaudeHooks), keyEquivalent: "")
            uninstallItem.target = self
            sub.addItem(uninstallItem)
        }
        sub.addItem(.separator())
        let demoItem = NSMenuItem(title: "🎬 演示：思考 → 等批准 → 搞定", action: #selector(runClaudeDemo), keyEquivalent: "")
        demoItem.target = self
        sub.addItem(demoItem)

        let parent = NSMenuItem(title: "Claude Code 联动 🤖", action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    @objc private func toggleClaudeIntegration() {
        CatSettings.shared.claudeIntegration.toggle()
    }

    @objc private func installClaudeHooks() {
        let confirm = NSAlert()
        confirm.messageText = "连接 Claude Code"
        confirm.informativeText = """
        CoolCat 会在 ~/.claude/settings.json 里加入 7 个 hook（会话开始/结束、提交提示词、调用工具前后、通知、完成）。

        • 只把事件名、工具名、项目文件夹名发给小猫，不读取你的提示词和代码
        • 原文件会备份为 settings.json.coolcat-backup
        • 已打开的 Claude Code 会话需要重启（或执行 /hooks）后生效
        """
        confirm.addButton(withTitle: "连接")
        confirm.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHookInstaller.install()
            CatSettings.shared.claudeIntegration = true
            showInfoAlert("已连接 Claude Code 🎉", "新开的 Claude Code 会话里，小猫会跟着思考、等你批准、完成任务做出反应。")
        } catch {
            showInfoAlert("连接失败", error.localizedDescription)
        }
    }

    @objc private func uninstallClaudeHooks() {
        do {
            try ClaudeHookInstaller.uninstall()
            showInfoAlert("已断开 Claude Code", "CoolCat 的 hook 已从 ~/.claude/settings.json 移除，其他配置未改动。")
        } catch {
            showInfoAlert("断开失败", error.localizedDescription)
        }
    }

    /// 不依赖 hook，直接给 tracker 喂一串假事件，方便预览动画
    @objc private func runClaudeDemo() {
        let tracker = ClaudeActivityTracker.shared
        let session = "coolcat-demo"
        let steps: [(TimeInterval, String, String?, String?)] = [
            (0.0, "UserPromptSubmit", nil, nil),
            (2.0, "PreToolUse", "Read", nil),
            (4.0, "PreToolUse", "Edit", nil),
            (6.5, "Notification", nil, "permission_prompt"),
            (10.0, "PostToolUse", "Bash", nil),
            (11.5, "Stop", nil, nil),
            (16.0, "SessionEnd", nil, nil)
        ]
        for (delay, event, tool, type) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                tracker.apply(event: event, session: session, tool: tool, notificationType: type, now: CACurrentMediaTime())
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

    @objc private func toggleTrackBubble() {
        CatSettings.shared.showTrackBubble.toggle()
    }

    @objc private func toggleMusicVisualizer() {
        CatSettings.shared.musicVisualizer.toggle()
        updateAudioAnalyzer()
    }

    @objc private func toggleMusicDance() {
        CatSettings.shared.musicDance.toggle()
        updateAudioAnalyzer()
    }

    @objc private func toggleRealAudio() {
        CatSettings.shared.realAudioAnalysis.toggle()
        // 重新打开 = 用户想再试一次（可能刚在系统设置里授了权）
        if CatSettings.shared.realAudioAnalysis { AudioSpectrumAnalyzer.shared.resetPermissionMemory() }
        updateAudioAnalyzer()
    }

    @objc private func toggleIdleAnimations() {
        CatSettings.shared.idleAnimations.toggle()
    }

    @objc private func selectScale(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        overlayWindow.applyScale(CGFloat(num.doubleValue))
    }

    @objc private func selectCoatTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let coat = CatCoatTheme(rawValue: raw) else { return }
        CatSettings.shared.coatTheme = coat
        // Auto-pair signature eye color (still freely overridable via 瞳色切换!)
        switch coat {
        case .classicBlack:
            CatSettings.shared.eyeTheme = .neonChartreuse
        case .siamese:
            CatSettings.shared.eyeTheme = .siameseBlue
        case .shorthair, .orangeWhite:
            CatSettings.shared.eyeTheme = .softAmber
        }
    }

    @objc private func selectKeyboardTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = KeyboardTheme(rawValue: raw) else { return }
        CatSettings.shared.keyboardTheme = theme
    }

    @objc private func selectEyeTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = EyeColorTheme(rawValue: raw) else { return }
        CatSettings.shared.eyeTheme = theme
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
