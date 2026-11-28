import CoreGraphics
import Foundation

// MARK: - Cat Profile

/// 一只猫的「名片」：串门时发给同事，同事那边照着它画出一模一样的猫，头上顶着名字。
/// 毛色、瞳色、装扮都用设置里的原始值（两边是同一个 App，认得出来）
struct CatProfile: Codable, Equatable {
    /// 你给它取的名字（空 = 没取）
    var name: String
    /// 品种名（没取名字时顶在头上的就是它）
    var breed: String
    /// CatCoatTheme.rawValue
    var coat: String
    /// EyeColorTheme.rawValue
    var eye: String
    /// PetSpec.id（大橘、狸花这些）；经典 4 只为 nil
    var petID: String?
    /// CatAccessory.rawValue
    var accessory: String

    /// 名字最长几个字：顶在头上的小牌子放得下
    static let maxNameLength = 12

    /// 顶在头上的名字：取了就用名字，没取就用品种名。都是局域网里别人发来的，一样清理、截断
    var displayName: String {
        let trimmed = Self.cleanName(name)
        guard trimmed.isEmpty else { return trimmed }
        let kind = Self.cleanName(breed)
        return kind.isEmpty ? "同事的猫" : kind
    }

    /// 去掉换行、制表符这些控制字符和首尾空白，太长的截断
    static func cleanName(_ raw: String) -> String {
        let oneLine = String(raw.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(maxNameLength))
    }
}

// MARK: - Messages

/// 串门时两边来回发的消息。客人（guest）是出门的那只猫的主人，主人家（host）是被串门的那台电脑：
///
///     客人 → knock（我想来串门，这是我的名片）
///     主人家 → welcome（来吧）/ busy（家里已经有客人了、或者自家猫也出门了）
///     客人的猫走出自家屏幕 → enter（我出门了）→ 主人家屏幕边跳进来一只猫
///     客人家有急事 → recall（快回来）→ 主人家的客人猫跑出屏幕
///     客人猫离开主人家屏幕 → bye（它走了）→ 客人家的猫从屏幕边走回来
enum VisitMessage: Codable, Equatable {
    case knock(profile: CatProfile)
    case welcome
    case busy
    case enter
    case recall
    case bye

    /// 一条消息一行 JSON（以换行分隔，TCP 上按行拆）
    func encodedLine() -> Data? {
        guard var data = try? JSONEncoder().encode(self) else { return nil }
        data.append(0x0A)
        return data
    }

    /// 从收到的字节流里拆出完整的几行消息，剩下没收完的留在 buffer 里；解不开的行直接丢掉
    static func drain(_ buffer: inout Data) -> [VisitMessage] {
        var messages: [VisitMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONDecoder().decode(VisitMessage.self, from: Data(line)) {
                messages.append(message)
            }
        }
        // 一直没有换行、又特别长：不是我们的消息，清掉免得越攒越多
        if buffer.count > 64 * 1024 { buffer.removeAll() }
        return messages
    }
}

// MARK: - Bonjour

enum VisitService {
    /// 局域网里互相发现用的 Bonjour 服务类型（Info.plist 的 NSBonjourServices 里也要写）
    static let type = "_coolcat._tcp"
    /// TXT 记录里的键：这只猫顶在头上的名字、这次启动的编号（认出自己，不去串自己的门）
    static let nameKey = "name"
    static let idKey = "id"
}

// MARK: - Playdate

/// 客人来了，自家猫什么时候去陪它玩、玩多久、什么时候回座位「接着工作」。纯逻辑，时间由调用方传入：
/// - 客人一进门：放下手头的事去玩（18～26 秒）
/// - 玩着的时候你在打字：至少玩 8 秒，然后回座位
/// - 回座位后过 20～40 秒，客人还在就又惦记着去玩（15～22 秒），如此往复，直到客人走
/// - 不方便玩（开会、agent 等你、番茄钟、踢文件、自家猫出门了）：马上不玩，方便了也要等下一轮
struct PlaydateClock {
    enum Phase: Equatable {
        /// 没有客人
        case idle
        case playing(since: TimeInterval, until: TimeInterval)
        /// 回座位接着工作，到这个时刻又想去玩
        case working(nextPlay: TimeInterval)
    }

    private(set) var phase: Phase = .idle
    /// 至少玩这么久，你在打字也不马上回去
    static let minPlay: TimeInterval = 8
    static let firstPlay: ClosedRange<TimeInterval> = 18...26
    static let laterPlay: ClosedRange<TimeInterval> = 15...22
    static let workBetween: ClosedRange<TimeInterval> = 20...40
    private let random: () -> Double

    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }

    private func pick(_ range: ClosedRange<TimeInterval>) -> TimeInterval {
        range.lowerBound + random() * (range.upperBound - range.lowerBound)
    }

    /// 每帧喂一次：现在要不要去陪客人玩
    /// - Parameters:
    ///   - hasGuest: 屏幕上有客人猫（不算正要走的）
    ///   - canPlay: 现在方便玩
    ///   - userBusy: 你正在打字
    mutating func update(now: TimeInterval, hasGuest: Bool, canPlay: Bool, userBusy: Bool) -> Bool {
        guard hasGuest else {
            phase = .idle
            return false
        }
        switch phase {
        case .idle:
            // 客人刚进门：方便就马上去玩，不方便就等方便了再去
            if canPlay {
                phase = .playing(since: now, until: now + pick(Self.firstPlay))
            } else {
                phase = .working(nextPlay: now)
            }
        case .playing(let since, let until):
            let played = now - since
            if !canPlay || now >= until || (userBusy && played >= Self.minPlay) {
                phase = .working(nextPlay: now + pick(Self.workBetween))
            }
        case .working(let next):
            if canPlay && now >= next {
                phase = .playing(since: now, until: now + pick(Self.laterPlay))
            }
        }
        return isPlaying
    }
}

// MARK: - Greeting

/// 主人家的猫：在哪（在座位上、或者不在客人这块屏幕上时 cat 是 nil），是不是正在陪客人玩（客人们也把它当玩伴）
struct VisitHostCat {
    var cat: (pos: CGPoint, surfaceID: Int)?
    var playmate: RoamPlaymate?
}

enum VisitGreeting {
    /// 进门先去哪儿打招呼：自家猫在座位上就去座位窗口旁边的地上；在外面就去它旁边，站在客人进来的那一侧。
    /// 同一边进来的第二只、第三只往外再让一个身位
    static func spot(host: RoamWorld, hostCat: (pos: CGPoint, surfaceID: Int)?, from edge: RoamEdge,
                     queue: Int) -> RoamSignTarget {
        let unit = host.scale
        let side: CGFloat = edge == .left ? -1 : 1
        let extra = CGFloat(queue) * 85 * unit
        guard let hostCat, let surface = host.surface(id: hostCat.surfaceID) else {
            let floor = host.floor
            // 离座位窗口留出大半个猫身，不压在键盘上
            let gap = 110 * unit + extra
            let spot = side > 0 ? host.homeRect.maxX + gap : host.homeRect.minX - gap
            return RoamSignTarget(surfaceID: floor.id,
                                  x: min(max(spot, floor.minX + 60 * unit), floor.maxX - 60 * unit))
        }
        let spot = hostCat.pos.x + side * (90 * unit + extra)
        return RoamSignTarget(surfaceID: surface.id,
                              x: min(max(spot, surface.minX + 30 * unit), surface.maxX - 30 * unit))
    }
}
