import Foundation
import IOKit.ps

// MARK: - Power Source

struct BatteryStatus: Equatable {
    /// 0...100
    var percent: Int
    /// 接着电源（不一定在充：满电时也是 true）
    var onAC: Bool
}

/// 读取内置电池状态（公开 IOKit API，无需权限）。台式机没有电池时返回 nil。
enum PowerSourceProbe {
    static func read() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return BatteryStatus(percent: Int((Double(current) / Double(max) * 100).rounded()),
                                 onAC: state == kIOPSACPowerValue)
        }
        return nil
    }
}

// MARK: - Life Companion

enum LifeEvent: Equatable {
    /// 深夜提醒睡觉（文案已带时间）
    case nightReminder(String)
    /// 今天第一次在早上开工
    case morningCoffee
    /// 电量跌破 20% / 10%
    case lowBattery(Int)
    /// 刚插上电源
    case pluggedIn
    /// 连续工作了这么多分钟
    case workBreak(minutes: Int)
}

/// "生活陪伴"的纯逻辑：每隔几秒喂一次当前时间、最近一次键鼠操作、电池状态，返回该触发的事件。
/// 不依赖 UI，便于单测；时间全部由调用方传入。
struct LifeCompanion {
    struct Options {
        var night = true
        var morning = true
        var battery = true
        var workBreak = true
    }

    /// 连续工作多久提醒一次、提醒后多久再提醒、歇多久算休息过
    var workLimit: TimeInterval = 50 * 60
    var workRepeat: TimeInterval = 25 * 60
    var breakGap: TimeInterval = 5 * 60

    private(set) var isNight = false
    private(set) var battery: BatteryStatus?

    private var remindedNightStages: Set<String> = []
    private var lastCoffeeDay: String?
    private var lowBatteryAlerted: Set<Int> = []
    private var sessionStart: TimeInterval?
    private var lastWorkReminder: TimeInterval?
    private var previousInput: TimeInterval?

    init(lastCoffeeDay: String? = nil) {
        self.lastCoffeeDay = lastCoffeeDay
    }

    /// 今天已经喝过早晨咖啡的日期（"yyyy-MM-dd"），由调用方持久化
    var coffeeDay: String? { lastCoffeeDay }

    /// - Parameters:
    ///   - date: 墙上时间（判断深夜/早晨）
    ///   - clock: 单调时钟秒数（判断连续工作）
    ///   - lastInput: 最近一次键鼠操作的单调时钟秒数（0 表示还没有）
    ///   - battery: 当前电池状态，台式机为 nil
    mutating func update(date: Date, clock: TimeInterval, lastInput: TimeInterval,
                         battery newBattery: BatteryStatus?, options: Options,
                         calendar: Calendar = .current) -> [LifeEvent] {
        var events: [LifeEvent] = []
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let activeNow = lastInput > 0 && clock - lastInput < 60

        // 深夜：23 点后、1 点后各提醒一次（只在人还在用电脑时）
        isNight = hour >= 23 || hour < 5
        if options.night, isNight, activeNow {
            // 以"这一晚开始的日期"区分不同的夜晚：凌晨算前一天
            let nightDate = hour < 5 ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
            let night = Self.dayKey(nightDate, calendar: calendar)
            let stage = hour >= 23 ? "23" : "1"
            let key = night + "@" + stage
            if !remindedNightStages.contains(key) {
                remindedNightStages.insert(key)
                let time = String(format: "%02d:%02d", hour, minute)
                events.append(.nightReminder(stage == "23" ? "🌙 已经 \(time) 了，早点休息吧" : "🌙 都 \(time) 了，真的该睡啦"))
            }
        }

        // 早晨：今天第一次在 6–10 点开工，端一杯咖啡
        if options.morning, (6..<10).contains(hour), activeNow {
            let today = Self.dayKey(date, calendar: calendar)
            if lastCoffeeDay != today {
                lastCoffeeDay = today
                events.append(.morningCoffee)
            }
        }

        // 电量：跌破 20%、10% 各提醒一次；插上电源时喝奶（启动时就插着电不算）
        if let current = newBattery {
            if let old = battery, !old.onAC, current.onAC, options.battery {
                events.append(.pluggedIn)
            }
            if current.onAC {
                lowBatteryAlerted.removeAll()
            } else if options.battery {
                for threshold in [20, 10] where current.percent <= threshold && !lowBatteryAlerted.contains(threshold) {
                    lowBatteryAlerted.insert(threshold)
                    // 同时跌破两档时只提醒更低的那一档
                    if threshold == 20 && current.percent <= 10 { continue }
                    events.append(.lowBattery(current.percent))
                }
            }
        }
        battery = newBattery

        // 久坐：歇满 5 分钟算休息过；连续工作 50 分钟提醒，之后每 25 分钟再提醒
        if lastInput > 0 {
            if let previous = previousInput, lastInput - previous >= breakGap {
                sessionStart = lastInput
                lastWorkReminder = nil
            }
            if sessionStart == nil { sessionStart = lastInput }
            previousInput = lastInput
        }
        if clock - (previousInput ?? clock) >= breakGap {
            sessionStart = nil
            lastWorkReminder = nil
        }
        if options.workBreak, activeNow, let start = sessionStart, clock - start >= workLimit {
            let due = lastWorkReminder.map { clock - $0 >= workRepeat } ?? true
            if due {
                lastWorkReminder = clock
                events.append(.workBreak(minutes: Int((clock - start) / 60)))
            }
        }
        return events
    }

    /// 电量低到让猫没精神的程度：0 正常，0.6（≤20%），1（≤10%）
    var tiredness: Double {
        guard let b = battery, !b.onAC else { return 0 }
        if b.percent <= 10 { return 1 }
        if b.percent <= 20 { return 0.6 }
        return 0
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
