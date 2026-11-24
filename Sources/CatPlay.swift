import CoreGraphics
import Foundation

// MARK: - Cursor Play

enum PawSide: Equatable { case left, right }

enum PlayEvent: Equatable {
    /// 出爪那一刻光标还在原地：抓到了（streak = 连续抓到次数）
    case caught(streak: Int)
    /// 扑空
    case missed
}

/// 逗猫：光标在小猫身前/身侧慢慢晃 → 盯上 → 压低扭屁股蓄力 → 出爪拍。纯逻辑，便于单测。
struct PlayDirector {
    struct Swat {
        let side: PawSide
        let target: CGPoint
        var age: CGFloat = 0
        var judged = false
    }

    /// 0..1 盯梢 / 蓄力程度
    private(set) var stalk: CGFloat = 0
    private(set) var swat: Swat?
    private(set) var streak = 0
    private var cooldown: CGFloat = 0
    /// 已经扭了多久屁股；扭够了才出爪（真猫扑之前会扭上一阵子）
    private var wiggleTime: CGFloat = 0
    private var wiggleNeeded: CGFloat = 1.0

    /// 爪子最远够得着的距离（从肩膀算，画布坐标）
    static let reach: CGFloat = 105
    /// 出爪到最远所需时间；此刻判定抓没抓到
    static let strikeTime: CGFloat = 0.12
    static let swatDuration: CGFloat = 0.36
    /// 光标离出爪瞄准点多近算"抓到"
    static let catchRadius: CGFloat = 18

    /// 0..1 屁股扭动强度（蓄力满了、还没出爪时）
    var wiggle: CGFloat {
        guard swat == nil else { return 0 }
        return max(0, min(1, (stalk - 0.6) / 0.25))
    }

    /// 0..1 出爪伸展程度：0.12s 内伸到底，再用 0.24s 收回
    var extension_: CGFloat {
        guard let s = swat else { return 0 }
        if s.age < Self.strikeTime { return s.age / Self.strikeTime }
        return max(0, 1 - (s.age - Self.strikeTime) / (Self.swatDuration - Self.strikeTime))
    }

    /// - Parameters:
    ///   - cursor: 光标在画布上的位置（不在逗猫区时传 nil）
    ///   - speed: 光标速度（画布 px/s）；太快是"捕猎"，不是逗猫
    ///   - available: 小猫此刻有空（没打字、没跳舞、手里没东西……）
    ///   - shoulders: 左右肩膀位置
    mutating func update(dt: CGFloat, cursor: CGPoint?, speed: CGFloat, available: Bool,
                         shoulders: (left: CGPoint, right: CGPoint)) -> PlayEvent? {
        cooldown = max(0, cooldown - dt)
        var event: PlayEvent?

        // 进行中的出爪：到最远那一刻判定
        if var s = swat {
            s.age += dt
            if !s.judged && s.age >= Self.strikeTime {
                s.judged = true
                if let c = cursor, hypot(c.x - s.target.x, c.y - s.target.y) < Self.catchRadius {
                    streak += 1
                    event = .caught(streak: streak)
                    if streak >= 3 { streak = 0 }
                } else {
                    streak = 0
                    event = .missed
                }
            }
            if s.age >= Self.swatDuration {
                swat = nil
                cooldown = 0.5
                stalk = min(stalk, 0.6)       // 收爪后很快再蓄力
            } else {
                swat = s
            }
            return event
        }

        let engaged = available && cursor != nil && speed < 1400
        stalk = max(0, min(1, stalk + (engaged ? dt * 1.4 : -dt * 2)))
        wiggleTime = stalk >= 0.6 ? wiggleTime + dt : 0

        guard engaged, let c = cursor, stalk > 0.85, wiggleTime >= wiggleNeeded, cooldown <= 0 else { return nil }
        let dl = hypot(c.x - shoulders.left.x, c.y - shoulders.left.y)
        let dr = hypot(c.x - shoulders.right.x, c.y - shoulders.right.y)
        let side: PawSide = dl <= dr ? .left : .right
        guard min(dl, dr) <= Self.reach else { return nil }
        swat = Swat(side: side, target: c)
        wiggleTime = 0
        wiggleNeeded = CGFloat.random(in: 0.7...1.3)
        return nil
    }

    /// 出爪时爪子的目标点：肩膀 → 瞄准点，略微冲过头一点更有力
    func swatPawTarget(shoulder: CGPoint) -> CGPoint? {
        guard let s = swat else { return nil }
        let e = extension_ * 1.06
        return CGPoint(x: shoulder.x + (s.target.x - shoulder.x) * e, y: shoulder.y + (s.target.y - shoulder.y) * e)
    }
}

// MARK: - Feeding

/// 喂小鱼干：每天最多 6 条，超过就摇头。按天持久化计数。
struct FeedLog {
    static let dailyLimit = 6
    private(set) var day: String
    private(set) var count: Int

    init(defaults: UserDefaults = .standard, today: String) {
        let savedDay = defaults.string(forKey: "CoolCat.FeedDay")
        day = today
        count = savedDay == today ? defaults.integer(forKey: "CoolCat.FeedCount") : 0
    }

    var isFull: Bool { count >= Self.dailyLimit }

    /// 新的一天自动清零
    mutating func roll(to today: String) {
        if today != day { day = today; count = 0 }
    }

    mutating func recordMeal(defaults: UserDefaults = .standard) {
        count += 1
        defaults.set(day, forKey: "CoolCat.FeedDay")
        defaults.set(count, forKey: "CoolCat.FeedCount")
    }
}
