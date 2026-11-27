import AppKit
import QuartzCore

// MARK: - Focus Companion

/// 番茄钟的 App 这一侧：每秒推进计时（菜单栏倒计时、到点事件），每帧告诉漫游小猫去哪儿趴着陪你、到点去哪儿举牌。
/// 计时本身在纯逻辑 FocusTimer 里；这里只管读窗口位置、判断「你看到牌子了没有」、把今天的番茄数存起来
final class FocusCompanion {
    private(set) var timer: FocusTimer
    /// 到点、休息结束（举牌之外的反应：亲密度、提示气泡）
    var onEvent: ((FocusTimer.Event) -> Void)?
    /// 每秒一次、以及开始 / 结束时：刷新菜单栏倒计时
    var onTick: (() -> Void)?
    private var ticker: Timer?
    /// `--focus-seconds N`（调试用）：专注 N 秒、休息 N/2 秒，几分钟内看完一整轮
    private let debugSeconds: TimeInterval?

    /// 陪你专注时趴的地方：选定后不跟着你切窗口搬家，那段上沿没了（窗口关了、被挡住、挪走了）才重选
    private(set) var spot: RoamSignTarget?
    private var lastSpotScan: CFTimeInterval = 0

    /// 到点举牌：举到这个时刻为止
    private var signUntil: CFTimeInterval = 0
    /// 小猫举起牌子的时刻
    private var signHeldSince: CFTimeInterval?
    private var signWindow: (id: Int, rect: CGRect)?
    private var lastSignScan: CFTimeInterval = 0
    /// 牌子上的字
    private(set) var signLines: [String] = []

    /// 到点的牌子最多举多久
    static let signMaxTime: CFTimeInterval = 45
    /// 举起牌子后这么久之内打字不算「看到了」（你多半正打到一半）
    static let signGrace: CFTimeInterval = 4

    private enum Key {
        static let day = "CoolCat.Focus.Day"
        static let count = "CoolCat.Focus.Count"
    }

    init(arguments: [String] = CommandLine.arguments) {
        let defaults = UserDefaults.standard
        let today = Self.today
        let count = defaults.string(forKey: Key.day) == today ? defaults.integer(forKey: Key.count) : 0
        timer = FocusTimer(day: today, completedToday: count)
        if let flag = arguments.firstIndex(of: "--focus-seconds"), flag + 1 < arguments.count,
           let seconds = TimeInterval(arguments[flag + 1]), seconds > 0 {
            debugSeconds = seconds
            timer.restDuration = max(5, seconds / 2)
            timer.longRestDuration = max(5, seconds / 2)
        } else {
            debugSeconds = nil
        }
    }

    private static var today: String { LifeCompanion.dayKey(Date(), calendar: .current) }
    /// 侧身小猫画布单位到屏幕点的缩放（离窗口两端留多少地方）
    private static var walkerScale: CGFloat { CatSettings.shared.scale * CatRenderer.walkerArtScale }
    /// 墙上时间：合盖睡眠期间也在走
    private static var wallNow: TimeInterval { Date().timeIntervalSince1970 }

    func startTicking() {
        guard ticker == nil else { return }
        let newTicker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(newTicker, forMode: .common)
        ticker = newTicker
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Controls

    func startFocus(minutes: Int) {
        timer.startFocus(duration: debugSeconds ?? TimeInterval(minutes * 60), now: Self.wallNow)
        resetCompany()
        tick()
    }

    func skipRest() {
        timer.skipRest(now: Self.wallNow)
        resetCompany()
        tick()
    }

    func stop() {
        timer.stop()
        resetCompany()
        tick()
    }

    /// 调试模式（`--focus-seconds`）：不记今天的番茄数、不加亲密度
    var isDebug: Bool { debugSeconds != nil }

    private func resetCompany() {
        spot = nil
        signUntil = 0
        signHeldSince = nil
    }

    var remaining: TimeInterval { timer.remaining(now: Self.wallNow) }
    var fractionLeft: CGFloat { CGFloat(timer.fractionLeft(now: Self.wallNow)) }

    private func tick() {
        for event in timer.update(now: Self.wallNow, today: Self.today) {
            if case .focusDone(let count, let rest) = event {
                if !isDebug {
                    UserDefaults.standard.set(timer.day, forKey: Key.day)
                    UserDefaults.standard.set(timer.completedToday, forKey: Key.count)
                }
                spot = nil
                signUntil = CACurrentMediaTime() + Self.signMaxTime
                signHeldSince = nil
                signWindow = nil
                signLines = ["🍅 第 \(count) 个番茄完成", "起来活动 \(rest) 分钟吧"]
            }
            onEvent?(event)
        }
        onTick?()
    }

    // MARK: Per Frame

    /// 这一帧陪你专注的地方；不在专注时 nil。第一次 / 原来那段上沿没了时，挑你最前面的那扇窗口（半秒看一次）
    func focusSpot(surfaces: [RoamSurface], screen: NSScreen, now: CFTimeInterval) -> RoamSignTarget? {
        guard timer.phase == .focusing else {
            spot = nil
            return nil
        }
        if let current = spot, current.surfaceID == 0 || surfaces.contains(where: { $0.id == current.surfaceID }) {
            return current
        }
        guard now - lastSpotScan > 0.5 || spot == nil else { return spot }
        lastSpotScan = now
        let visible = screen.visibleFrame
        if let front = RoamSurfaceScanner.frontmostWindow(on: screen) {
            spot = RoamSignTarget.over(windowID: front.id, rect: front.rect, surfaces: surfaces,
                                       floorX: visible.minX...visible.maxX, scale: Self.walkerScale)
        } else {
            // 屏幕上一扇窗口都没有：在屏幕底边中间陪你
            spot = RoamSignTarget(surfaceID: 0, x: visible.midX)
        }
        return spot
    }

    /// 到点举牌：去你最前面的窗口顶上举「第 N 个番茄完成」。举满几秒后你一打字就算看到了，最多举 45 秒
    /// - Parameter holding: 小猫这会儿正举着牌子
    func reminderSign(surfaces: [RoamSurface], screen: NSScreen, keyIdle: Double, now: CFTimeInterval,
                      holding: Bool) -> RoamSignTarget? {
        guard now < signUntil else { return nil }
        if holding && signHeldSince == nil { signHeldSince = now }
        if let since = signHeldSince, now - since > Self.signGrace, keyIdle < 0.4 {
            signUntil = 0
            return nil
        }
        if signWindow == nil || now - lastSignScan > 0.5 {
            lastSignScan = now
            signWindow = RoamSurfaceScanner.frontmostWindow(on: screen) ?? signWindow
        }
        let visible = screen.visibleFrame
        guard let front = signWindow else { return RoamSignTarget(surfaceID: 0, x: visible.midX) }
        return RoamSignTarget.over(windowID: front.id, rect: front.rect, surfaces: surfaces,
                                   floorX: visible.minX...visible.maxX, scale: Self.walkerScale)
    }

    /// 到点举牌的路上、刚举起来那几秒：你在打字也照样去，不当作叫它回家
    func signIgnoresTyping(now: CFTimeInterval) -> Bool {
        now < signUntil && (signHeldSince.map { now - $0 < Self.signGrace } ?? true)
    }

    /// 开会了：这次不举了
    func cancelSign() {
        signUntil = 0
    }
}
