import Foundation

// MARK: - Accessory

/// 亲密度解锁的装扮。rawValue 用于持久化，别改。
enum CatAccessory: String, CaseIterable {
    case none
    case bell
    case scarf
    case bow
    case shades

    var title: String {
        switch self {
        case .none: return "不戴"
        case .bell: return "🔔 铃铛项圈"
        case .scarf: return "🧣 毛线围巾"
        case .bow: return "🎀 蝴蝶结"
        case .shades: return "🕶️ 墨镜"
        }
    }
}

// MARK: - Bond

/// 亲密度来源：每种来源单独计每日上限，防止靠某一种互动刷分
enum BondSource: String, CaseIterable {
    /// 今天第一次见面
    case visit
    /// 摸摸（一次完整的抚摸）
    case pet
    /// 逗猫抓到光标
    case catchToy
    /// 喂了一条小鱼干
    case feed
    /// 一起听歌（每 5 分钟）
    case music
    /// 陪着 Claude Code 干完一件活
    case claude
    /// 收下小猫送的礼物
    case gift
    /// 陪你专注完成一个番茄
    case focus

    /// 每次得分
    var award: Int {
        switch self {
        case .visit: return 5
        case .pet: return 3
        case .catchToy: return 1
        case .feed: return 5
        case .music: return 1
        case .claude: return 1
        case .gift: return 3
        case .focus: return 3
        }
    }

    /// 每天这种来源最多得多少分
    var dailyCap: Int {
        switch self {
        case .visit: return 5
        case .pet: return 30
        case .catchToy: return 20
        case .feed: return 30
        case .music: return 12
        case .claude: return 10
        case .gift: return 3
        case .focus: return 12
        }
    }
}

struct BondLevel: Equatable {
    let level: Int
    let title: String
    /// 达到这一级需要的累计分数
    let threshold: Int
    /// 这一级解锁的装扮
    let unlock: CatAccessory?
}

/// 一次得分的结果
struct BondGain: Equatable {
    let points: Int
    /// 非 nil = 这次升级了
    let levelUp: BondLevel?
}

/// 亲密度与成长：只增不减（不理它也不会变冷淡），按天、按来源封顶。纯逻辑 + UserDefaults 持久化，便于单测。
struct BondLog {
    static let levels: [BondLevel] = [
        BondLevel(level: 1, title: "初次见面", threshold: 0, unlock: nil),
        BondLevel(level: 2, title: "熟悉起来", threshold: 60, unlock: .bell),
        BondLevel(level: 3, title: "好朋友", threshold: 180, unlock: .scarf),
        BondLevel(level: 4, title: "亲密伙伴", threshold: 400, unlock: .bow),
        BondLevel(level: 5, title: "黏人精", threshold: 800, unlock: .shades)
    ]

    private enum Key {
        static let points = "CoolCat.Bond.Points"
        static let firstDay = "CoolCat.Bond.FirstDay"
        static let day = "CoolCat.Bond.Day"
        static let today = "CoolCat.Bond.TodayBySource"
        static let pets = "CoolCat.Bond.Pets"
        static let catches = "CoolCat.Bond.Catches"
        static let fish = "CoolCat.Bond.Fish"
        static let giftDay = "CoolCat.Bond.GiftDay"
    }

    private(set) var points: Int
    /// 第一次见面的日期 "yyyy-MM-dd"
    private(set) var firstDay: String
    private(set) var day: String
    /// 今天各来源已得的分
    private(set) var todayBySource: [String: Int]
    private(set) var pets: Int
    private(set) var catches: Int
    private(set) var fish: Int
    /// 最近一次送礼物的日期（一天最多送一次）
    private(set) var giftDay: String?

    private let store: UserDefaults

    init(store: UserDefaults = .standard, today: String) {
        self.store = store
        points = store.integer(forKey: Key.points)
        firstDay = store.string(forKey: Key.firstDay) ?? today
        let savedDay = store.string(forKey: Key.day)
        day = today
        todayBySource = savedDay == today ? (store.dictionary(forKey: Key.today) as? [String: Int] ?? [:]) : [:]
        pets = store.integer(forKey: Key.pets)
        catches = store.integer(forKey: Key.catches)
        fish = store.integer(forKey: Key.fish)
        giftDay = store.string(forKey: Key.giftDay)
        if store.string(forKey: Key.firstDay) == nil { store.set(firstDay, forKey: Key.firstDay) }
    }

    // MARK: Queries

    var level: BondLevel {
        Self.levels.last { points >= $0.threshold } ?? Self.levels[0]
    }

    var nextLevel: BondLevel? {
        Self.levels.first { $0.threshold > points }
    }

    func isUnlocked(_ accessory: CatAccessory) -> Bool {
        guard accessory != .none else { return true }
        guard let need = Self.levels.first(where: { $0.unlock == accessory }) else { return false }
        return level.level >= need.level
    }

    /// 今天是否已经打过招呼
    var hasVisitedToday: Bool { (todayBySource[BondSource.visit.rawValue] ?? 0) > 0 }

    var hasGiftedToday: Bool { giftDay == day }

    /// 认识第几天（第一天 = 1）
    func daysKnown(calendar: Calendar = .current) -> Int {
        guard let from = Self.date(firstDay, calendar: calendar),
              let to = Self.date(day, calendar: calendar) else { return 1 }
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return max(1, days + 1)
    }

    // MARK: Mutations

    /// 新的一天：清空每日上限
    mutating func roll(to today: String) {
        guard today != day else { return }
        day = today
        todayBySource = [:]
        save()
    }

    /// 记一次互动。统计数一直累加；分数受每日上限约束。
    /// - Parameter bonus: 额外加分（例如连抓三下），同样计入该来源的每日上限
    @discardableResult
    mutating func record(_ source: BondSource, today: String, bonus: Int = 0) -> BondGain {
        roll(to: today)
        switch source {
        case .pet: pets += 1
        case .catchToy: catches += 1
        case .feed: fish += 1
        case .gift: giftDay = today
        case .visit, .music, .claude, .focus: break
        }
        let used = todayBySource[source.rawValue] ?? 0
        let gained = max(0, min(source.award + bonus, source.dailyCap - used))
        let before = level
        points += gained
        todayBySource[source.rawValue] = used + gained
        save()
        let after = level
        return BondGain(points: gained, levelUp: after.level > before.level ? after : nil)
    }

    /// 标记今天已经送过礼物（礼物没被收下也算送过）
    mutating func markGiftOffered(today: String) {
        roll(to: today)
        giftDay = today
        save()
    }

    private func save() {
        store.set(points, forKey: Key.points)
        store.set(firstDay, forKey: Key.firstDay)
        store.set(day, forKey: Key.day)
        store.set(todayBySource, forKey: Key.today)
        store.set(pets, forKey: Key.pets)
        store.set(catches, forKey: Key.catches)
        store.set(fish, forKey: Key.fish)
        store.set(giftDay, forKey: Key.giftDay)
    }

    private static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
