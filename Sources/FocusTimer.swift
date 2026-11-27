import Foundation

// MARK: - Focus Timer

/// 番茄钟：专注 N 分钟 → 休息 5 分钟（每完成 4 个番茄长休息 15 分钟）→ 回到空闲，等你开始下一个。
///
/// 纯逻辑：时间由调用方传入。用墙上时间（秒）而不是单调时钟：合上盖子睡一觉，番茄钟照样往前走
struct FocusTimer: Equatable {
    enum Phase: Equatable {
        case idle
        case focusing
        case resting
    }

    enum Event: Equatable {
        /// 专注到点：今天第几个番茄、接下来休息几分钟
        case focusDone(count: Int, restMinutes: Int)
        /// 休息结束
        case restDone
    }

    /// 菜单里给的专注时长（分钟），第一个是默认
    static let choices = [25, 45, 15]
    static let longRestEvery = 4

    /// 休息时长（秒）：调试时可以改短
    var restDuration: TimeInterval = 5 * 60
    var longRestDuration: TimeInterval = 15 * 60

    private(set) var phase: Phase = .idle
    private(set) var startedAt: TimeInterval = 0
    private(set) var endsAt: TimeInterval = 0
    /// 这个番茄定的专注时长（秒）：「跳过休息」时照这个时长接着来
    private(set) var focusDuration: TimeInterval = 25 * 60
    /// 今天完成了几个（day 是 "yyyy-MM-dd"，换天清零）
    private(set) var completedToday: Int
    private(set) var day: String

    init(day: String, completedToday: Int = 0) {
        self.day = day
        self.completedToday = completedToday
    }

    var isRunning: Bool { phase != .idle }

    /// 开始专注（正在专注 / 休息时也可以直接重新开始）
    mutating func startFocus(duration: TimeInterval, now: TimeInterval) {
        phase = .focusing
        focusDuration = max(1, duration)
        startedAt = now
        endsAt = now + focusDuration
    }

    /// 休息时「跳过休息」：马上开始下一个同样长的番茄
    mutating func skipRest(now: TimeInterval) {
        guard phase == .resting else { return }
        startFocus(duration: focusDuration, now: now)
    }

    /// 提前结束：这个番茄不算完成
    mutating func stop() {
        phase = .idle
    }

    /// 这一段还剩几秒（空闲时 0）
    func remaining(now: TimeInterval) -> TimeInterval {
        phase == .idle ? 0 : max(0, endsAt - now)
    }

    /// 这一段还剩的比例：1 = 刚开始，0 = 到点
    func fractionLeft(now: TimeInterval) -> Double {
        let total = endsAt - startedAt
        guard phase != .idle, total > 0 else { return 0 }
        return max(0, min(1, (endsAt - now) / total))
    }

    /// 每秒喂一次时间：到点就进入下一段。合盖睡过了好几段时，一次补齐（先完成专注，再结束休息）
    mutating func update(now: TimeInterval, today: String) -> [Event] {
        if today != day {
            day = today
            completedToday = 0
        }
        var events: [Event] = []
        if phase == .focusing, now >= endsAt {
            completedToday += 1
            let long = completedToday % Self.longRestEvery == 0
            let rest = long ? longRestDuration : restDuration
            events.append(.focusDone(count: completedToday, restMinutes: max(1, Int((rest / 60).rounded()))))
            phase = .resting
            // 休息从专注到点那一刻算起，不从「这一秒才发现」算起
            startedAt = endsAt
            endsAt += rest
        }
        if phase == .resting, now >= endsAt {
            events.append(.restDone)
            phase = .idle
        }
        return events
    }

    /// 倒计时文字："24:59"，一小时以上 "1:05:00"
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
