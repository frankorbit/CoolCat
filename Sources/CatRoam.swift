import CoreGraphics
import Foundation

// MARK: - World

/// 小猫漫游时能落脚的水平面：屏幕底部，或某个窗口的上沿（屏幕坐标，y 向上）
struct RoamSurface: Equatable {
    /// 0 = 屏幕底部；其他 = 窗口号
    var id: Int
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat

    var width: CGFloat { maxX - minX }

    func contains(x: CGFloat, margin: CGFloat = 0) -> Bool {
        x >= minX + margin && x <= maxX - margin
    }
}

/// 能爬的窗框侧边：窗口顶太高跳不上去时，顺着侧边爬上去（屏幕坐标，y 向上）
struct RoamWall: Equatable {
    /// 侧边所在的 x
    var x: CGFloat
    /// 窗口在侧边的右边（这是窗口的左框）；false = 窗口在左边（右框）
    var windowOnRight: Bool
    /// 侧边露在外面的那段：从 minY 爬到 top（窗口上沿）
    var minY: CGFloat
    var top: CGFloat
    /// 爬到顶后站上去的那段窗口上沿
    var surfaceID: Int
}

/// 举牌提醒的目的地：agent 等你批准时，小猫跑到你正在看的窗口顶上（或它正下方的屏幕底边）坐着举牌
struct RoamSignTarget: Equatable {
    /// 坐在哪个面上：窗口上沿的 id，或者 0 = 屏幕底部
    var surfaceID: Int
    /// 坐在哪儿（屏幕 x）
    var x: CGFloat

    /// 你正在看的那扇窗口上方：挑它离中间最近的那段上沿（上沿的 id = 窗口号 × 8 + 段号 + 1），离两端留点地方；
    /// 窗口顶站不上去（贴着屏幕顶、被挡住）就在它正下方的屏幕底边
    static func over(windowID: Int, rect: CGRect, surfaces: [RoamSurface], floorX: ClosedRange<CGFloat>,
                     scale: CGFloat) -> RoamSignTarget {
        let margin = 40 * scale
        let segments = surfaces.filter { $0.id > 0 && ($0.id - 1) / 8 == windowID }
        let offCenter = { (seg: RoamSurface) in abs((seg.minX + seg.maxX) / 2 - rect.midX) }
        if let seg = segments.min(by: { offCenter($0) < offCenter($1) }) {
            return RoamSignTarget(surfaceID: seg.id, x: min(max(rect.midX, seg.minX + margin), seg.maxX - margin))
        }
        let floorSpot = min(max(rect.midX, floorX.lowerBound + margin), floorX.upperBound - margin)
        return RoamSignTarget(surfaceID: 0, x: floorSpot)
    }
}

/// 要踢飞的文件：躺在哪个面上、在哪儿。小猫跑过去站在它旁边，一脚踢飞
struct RoamKickTarget: Equatable {
    /// 文件躺在（或者正往下掉、马上要落在）哪个面上：窗口上沿的 id，或者 0 = 屏幕底部
    var surfaceID: Int
    /// 文件底边中点的 x（屏幕坐标）
    var x: CGFloat
    /// 文件图标的半宽（屏幕点）：小猫站在离它这么远再加一条腿长的地方
    var halfWidth: CGFloat
    /// 已经落稳了：小猫到了就能踢；还在掉的时候先跑过去等着
    var ready: Bool
}

/// 每帧喂给漫游逻辑的外部状态（全部由调用方采集，逻辑本身不碰 AppKit）
struct RoamWorld {
    /// 屏幕底部（Dock 上方）
    var floor: RoamSurface
    /// 可站的窗口上沿（已去掉被遮挡、太窄、贴着屏幕顶站不下的）
    var windowTops: [RoamSurface]
    /// 座位上小猫脚底的位置
    var seat: CGPoint
    /// 键盘所在的主窗口：下地时避开它
    var homeRect: CGRect
    /// 距离上次按键的秒数
    var keyIdle: Double
    /// 刚按过键：立刻回家
    var userActive: Bool
    /// 必须待在座位上：开会、吃东西、被摸、在跳舞……（手动出发也不出门，在外面立刻回来）
    var mustStayHome: Bool
    /// 可以自己出门：设置里开着、没有 agent 在等你
    var wanderAllowed = true
    /// agent 在等你（批准 / 回复）：刚出现的那一刻，在外面的小猫跑回来提醒你
    var needsAttention = false
    /// 屏幕点 / 画布点：所有速度、距离都跟着小猫尺寸缩放
    var scale: CGFloat = 1
    /// 可用区域顶部（菜单栏下沿）：侧边偷看时别探到菜单栏里
    var screenTop: CGFloat = 10_000
    /// 光标（屏幕坐标）；nil = 不在这块屏上，或者设置里关了「光标逗猫」
    var cursor: CGPoint?
    /// 光标速度（屏幕点/秒）
    var cursorSpeed: CGFloat = 0
    /// 能爬的窗框侧边
    var walls: [RoamWall] = []
    /// 举牌提醒：有值时小猫放下手头的事，跑过去坐下举牌，直到它变回 nil
    var signTarget: RoamSignTarget?
    /// 番茄钟陪你专注：有值时小猫去那儿蜷成一团睡，到点（变回 nil）才醒。
    /// 陪着的时候你打字很正常，不因此回家；只有开会（mustStayHome）叫得回去
    var focusSpot: RoamSignTarget?
    /// 积雪够厚的窗口上沿（在上面走久了会抖爪子，下来时甩身子）
    var snowySurfaces: Set<Int> = []
    /// 设置里允许把东西推下桌
    var knockAllowed = false
    /// 你让小猫踢飞的文件：有值时小猫放下手头的事跑过去踢，打字、开会都拦不住（是你刚叫它去的）
    var kickTarget: RoamKickTarget?

    var surfaces: [RoamSurface] { [floor] + windowTops }

    func surface(id: Int) -> RoamSurface? { surfaces.first { $0.id == id } }
}

// MARK: - Director

enum RoamPose: Equatable {
    case stand, walk, run, crouch, air, land, sit
    /// 扒着屏幕边偷看：只露脑袋和两只爪子
    case peek
    /// 压低身子慢慢挪近（盯上光标了）
    case stalk
    /// 蹲着扭屁股蓄力，马上要扑
    case wiggle
    /// 顺着窗框侧边往上爬
    case climb
    /// 坐着举牌（agent 等你批准）
    case sign
    /// 蜷成一团睡觉（趴下 → 蜷起来 → 醒来伸展）
    case curl
    /// 在雪里走久了：站住抬起一只前爪甩一甩
    case pawShake
    /// 从积雪的窗口下来：从头到尾巴甩一甩全身的雪
    case bodyShake
    /// 站着伸出前爪往前拨（把东西拨下桌）
    case knockTap
    /// 瞄准 → 往后蓄力 → 一脚踢出去（把文件踢飞）
    case kick
}

/// 屏幕的哪条边
enum RoamEdge: Equatable {
    case left, right, bottom
}

enum RoamEvent: Equatable {
    /// 跳下座位，开始溜达
    case leftSeat
    /// 跳回座位
    case arrivedHome
    /// 落地（跳下来或从窗口上掉下来）
    case landed
    /// 漫游时扑到了光标
    case caughtCursor
    /// 扑空
    case missedCursor
    /// 叼着 / 放着的小东西离开了小猫：推下去了，或者半路放弃丢下了（调用方接手让它往下掉）
    case releasedTrinket(kind: Int, at: CGPoint, vx: CGFloat)
    /// 一脚踢中了文件：往 dir 那边（+1 = 右）、仰角 angle（弧度，0 = 水平）踢出去
    case kickedFile(angle: CGFloat, dir: CGFloat)
    /// 文件落在了上不去的窗口顶上：让它掉到屏幕底边再踢
    case kickTargetUnreachable
}

/// 满屏漫游的纯逻辑：什么时候出门、走到哪、跳到哪、什么时候回家。坐标都是屏幕坐标（y 向上），位置是脚底中点。
struct RoamDirector {
    struct Jump: Equatable {
        var from: CGPoint
        var to: CGPoint
        var t: CGFloat = 0
        var duration: CGFloat
        /// 弧线比两端中较高的一端再高多少
        var apex: CGFloat
        /// 落在哪个面上；nil = 跳回座位
        var surface: Int?
        /// 跳过去抓住窗框侧边（落地后接着往上爬）
        var toWall = false

        /// 抛物线：两端连线再往上鼓一个弧，弧高 = apex + 高度差的一半（往上跳时能越过高的那一端）
        func point(at t: CGFloat) -> CGPoint {
            let arc = apex + abs(to.y - from.y) * 0.5
            return CGPoint(x: from.x + (to.x - from.x) * t,
                           y: from.y + (to.y - from.y) * t + arc * 4 * t * (1 - t))
        }
    }

    /// 偷看：（底边）先蹲下沉到屏幕外 → 慢慢探出脑袋 → 东张西望 → 缩回去
    struct Peek: Equatable {
        static let sinkTime: CGFloat = 0.45
        static let revealTime: CGFloat = 0.7
        static let hideTime: CGFloat = 0.45
        var edge: RoamEdge
        var t: CGFloat = 0
        var hold: CGFloat

        /// 底边偷看要先沉下去，侧边是直接从屏幕外探进来
        var start: CGFloat { edge == .bottom ? Self.sinkTime : 0 }
        var total: CGFloat { start + Self.revealTime + hold + Self.hideTime }

        /// 0...1 脑袋露出来多少（缓入缓出）
        var reveal: CGFloat {
            let local = t - start
            if local <= 0 { return 0 }
            if local < Self.revealTime { return ease(local / Self.revealTime) }
            let hideStart = Self.revealTime + hold
            if local < hideStart { return 1 }
            return 1 - ease(min(1, (local - hideStart) / Self.hideTime))
        }

        /// 底边偷看开始时整只猫往下沉的程度 0...1
        var sink: CGFloat { edge == .bottom ? min(1, t / Self.sinkTime) : 0 }

        private func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
    }

    /// 打盹：趴下慢慢蜷成一团 → 睡一会儿 → 舒展开醒来
    struct Nap: Equatable {
        static let settleTime: CGFloat = 1.8
        static let wakeTime: CGFloat = 1.2
        var t: CGFloat = 0
        /// 睡多久
        var hold: CGFloat
        /// 被吵醒时动作加快
        var speed: CGFloat = 1

        var total: CGFloat { Self.settleTime + hold + Self.wakeTime }
        private var wakeAt: CGFloat { Self.settleTime + hold }

        /// 0 = 刚趴下，1 = 完全蜷成一团
        var curl: CGFloat {
            if t < Self.settleTime { return ease(t / Self.settleTime) }
            if t < wakeAt { return 1 }
            return 1 - ease(min(1, (t - wakeAt) / Self.wakeTime))
        }

        /// 睡着了：闭眼、冒 Zzz
        var asleep: Bool { t > Self.settleTime * 0.6 && t < wakeAt + 0.15 }

        /// 马上醒：还在趴下就原路舒展回去，睡着的直接进入醒来阶段（curl 连续不跳变）
        mutating func wakeNow(startled: Bool) {
            let c = curl
            if t < wakeAt {
                hold = max(0, min(hold, t - Self.settleTime))
                t = wakeAt + Self.wakeTime * (1 - c)
            }
            if startled { speed = 2.2 }
        }

        private func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
    }

    /// 把东西推下桌：去哪扇窗口、往哪边推（+1 = 从右边推下去）
    struct KnockGoal: Equatable {
        var surfaceID: Int
        var dir: CGFloat
    }

    /// 推东西的几个阶段：放下 → 盯着看 → 一下下拨 →（掉下去了）探头看它掉
    enum KnockPhase: Equatable {
        case setDown, stare, tap, watch
    }

    struct Knock: Equatable {
        var phase: KnockPhase
        var t: CGFloat = 0
        /// 盯着看多久
        var hold: CGFloat = 0
        /// 这一下已经碰到东西了
        var hit = false
        /// 碰完之后往前挪的距离（跟上被拨远的东西）
        var scoot: CGFloat = 0
    }

    /// 叼着的（surfaceID == nil）或者放在窗口顶上的小东西
    struct CarriedTrinket: Equatable {
        var kind: Int
        var surfaceID: Int?
        /// 放在面上时：离这段上沿左端多远（窗口挪动时跟着走）
        var dx: CGFloat = 0
        /// 现在在哪（放着时是它底边中点）
        var at: CGPoint
    }

    /// 东西放在嘴前方多远（画布单位，乘体型缩放）：前爪伸出去正好够到
    static let trinketReach: CGFloat = 58
    /// 一下拨多远
    static let tapPush: ClosedRange<CGFloat> = 9...13
    /// 一下拨爪的时长、爪子碰到东西的时刻
    static let tapDuration: CGFloat = 0.55
    static let tapContact: CGFloat = 0.24
    /// 一趟里顺手推东西的概率（叼着出门）
    static let knockChance = 0.15

    /// 抖雪：抬爪甩一甩（短），或者全身从头甩到尾（长一点）
    struct Shake: Equatable {
        var paw: Bool
        var t: CGFloat = 0
        var duration: CGFloat
    }

    /// 一脚踢飞文件：先瞄一眼 → 往后蓄力 → 踢出去（碰到文件的那一刻把它踢飞）→ 腿停在半空 → 收回来
    struct Kick: Equatable {
        static let aimEnd: CGFloat = 0.35
        static let windupEnd: CGFloat = 0.7
        static let strikeEnd: CGFloat = 0.8
        /// 爪子碰到文件的时刻
        static let contact: CGFloat = 0.76
        static let holdEnd: CGFloat = 1.15
        static let total: CGFloat = 1.5
        /// 踢出去的仰角（弧度）：随机，腿踢多高文件就往多高飞
        static let angles: ClosedRange<CGFloat> = 0.21...1.19
        var t: CGFloat = 0
        var angle: CGFloat
        var launched = false
    }

    /// 踢的时候脚底离文件近边多远（画布单位，乘体型缩放）：前腿往前一甩正好踢到
    static let kickReach: CGFloat = 40

    /// 在积雪的窗口顶上走了这么久就停下来抖抖爪子
    static let snowWalkBeforePawShake: CGFloat = 1.6
    /// 这一趟在雪里待了这么久，下到没雪的地方时甩一甩全身
    static let snowBeforeBodyShake: CGFloat = 2.5

    enum Activity: Equatable {
        case walk(toX: CGFloat, run: Bool)
        case peek(Peek)
        case nap(Nap)
        case crouch(t: CGFloat = 0, duration: CGFloat, then: Jump)
        case jump(Jump)
        /// 盯上光标：发现 → 潜伏 → 扭屁股；光标一甩就冲刺追
        case stalk(Stalk)
        /// 朝光标扑过去；飞行途中前爪碰到光标就算抓到
        case pounce(Pounce)
        /// 顺着窗框侧边往上爬，到顶翻上窗口
        case climb(Climb)
        /// 坐着举牌，直到 signTarget 没了
        case sign
        /// 抖掉爪子上 / 身上的雪
        case shake(Shake)
        /// 把叼来的东西放在窗口边上，一下下拨下去
        case knock(Knock)
        /// 把你让它踢的文件一脚踢飞
        case kick(Kick)
        case land(t: CGFloat = 0, duration: CGFloat, skidding: Bool = false)
        case sit(remaining: CGFloat)
        case fall(vy: CGFloat)
    }

    private(set) var isHome = true
    private(set) var pos: CGPoint = .zero
    /// 1 = 朝右，-1 = 朝左
    private(set) var facing: CGFloat = 1
    private(set) var gaitPhase: CGFloat = 0
    private(set) var surfaceID: Int?
    private(set) var activity: Activity?
    /// 平滑水平速度（未缩放画布单位/秒）
    private var currentSpeed: CGFloat = 0
    /// 0...1 平滑跑步强度、移动强度、转身缩放
    private(set) var runBlend: CGFloat = 0
    private(set) var moveBlend: CGFloat = 0
    private(set) var turnScale: CGFloat = 1
    /// 这次在积雪上连着走了多久（抖完爪子清零）
    private var snowWalk: CGFloat = 0
    /// 这一趟在雪里一共走了多久（甩完身子清零）
    private var snowTrip: CGFloat = 0
    private(set) var returning = false
    /// 这趟回家是急着跑回去的（你在打字、要开会……）；慢悠悠往回走时一有急事就改成飞奔
    private(set) var returningUrgently = false
    /// 这趟还能再玩几件事
    private(set) var budget = 0
    private var tripTime: CGFloat = 0
    private var cooldown: CGFloat = 25
    private var checkTimer: CGFloat = 0
    private var forced = false
    /// 这一趟是手动「出发」的：agent 本来就在等你时也不因此赶回家
    private var tripForced = false
    private var lastNeedsAttention = false
    private var random: () -> Double

    /// 漫游最长时间，到点自己回家
    static let maxTrip: CGFloat = 120
    /// 闲置多久之后才自己出门（秒）
    static let idleBeforeWander: Double = 30
    /// 闲置这么久（人大概离开了）就不再出门，安心在座位上睡觉
    static let napAfter: Double = 600
    /// 在地上溜达时突然狂奔的概率
    static let zoomiesChance = 0.25
    static let walkSpeed: CGFloat = 76
    static let runSpeed: CGFloat = 240
    static let gravity: CGFloat = 1800
    /// 一跳最远能跳多远、多高（画布点，乘 scale）
    static let maxJumpDX: CGFloat = 420
    static let maxJumpUp: CGFloat = 330

    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    var pose: RoamPose {
        switch activity {
        case .walk(_, let run): return run ? .run : .walk
        case .crouch: return .crouch
        case .jump, .fall, .pounce: return .air
        case .stalk(let s):
            switch s.phase {
            case .notice: return .stand
            case .creep: return .stalk
            case .wiggle: return .wiggle
            case .dash: return .run
            }
        case .land: return .land
        case .sit: return .sit
        case .peek(let p): return p.t < p.start ? .crouch : .peek
        case .nap: return .curl
        case .climb: return .climb
        case .sign: return .sign
        case .shake(let shake): return shake.paw ? .pawShake : .bodyShake
        case .knock(let knock):
            switch knock.phase {
            case .setDown, .watch: return .crouch
            case .stare: return .sit
            case .tap: return .knockTap
            }
        case .kick: return .kick
        case nil: return .stand
        }
    }

    /// 正在偷看的那条边
    var peekEdge: RoamEdge? {
        if case .peek(let p) = activity { return p.edge }
        return nil
    }

    /// 0...1 偷看时脑袋露出来多少
    var peekReveal: CGFloat {
        if case .peek(let p) = activity { return p.reveal }
        return 0
    }

    /// 0...1 底边偷看前往下沉的程度（画的时候整只猫往下挪、被屏幕底边裁掉）
    var sinkDepth: CGFloat {
        if case .peek(let p) = activity { return p.sink }
        return 0
    }

    /// 需要沿哪条屏幕边裁掉：屏幕外的部分一律不画（多屏时不会画到隔壁屏上）
    var clipEdge: (edge: RoamEdge, at: CGFloat)? {
        guard let f = lastFloor else { return nil }
        if case .peek(let p) = activity {
            switch p.edge {
            case .left: return (.left, f.minX)
            case .right: return (.right, f.maxX)
            case .bottom: return (.bottom, f.y)
            }
        }
        if pos.y < f.y - 0.5 { return (.bottom, f.y) }
        if pos.x < f.minX + 140 * lastScale { return (.left, f.minX) }
        if pos.x > f.maxX - 140 * lastScale { return (.right, f.maxX) }
        return nil
    }

    private var lastFloor: RoamSurface?
    private var lastScale: CGFloat = 1
    /// 走出屏幕侧边后要接的偷看
    private var pendingPeek: RoamEdge?

    /// 0...1 蜷成一团的程度
    var napCurl: CGFloat {
        if case .nap(let n) = activity { return n.curl }
        return 0
    }

    /// 正在睡（闭眼、冒 Zzz）
    var napAsleep: Bool {
        if case .nap(let n) = activity { return n.asleep }
        return false
    }

    var isNapping: Bool {
        if case .nap = activity { return true }
        return false
    }

    /// 拨爪的进度 0...1
    var tapProgress: CGFloat {
        if case .knock(let knock) = activity, knock.phase == .tap { return min(1, knock.t / Self.tapDuration) }
        return 0
    }

    /// 踢腿：开始了多久（秒）、往多高踢（弧度）；不在踢时 nil
    var kickPose: (t: CGFloat, angle: CGFloat)? {
        if case .kick(let kick) = activity { return (kick.t, kick.angle) }
        return nil
    }

    /// 嘴里叼着的东西
    var carriedTrinket: Int? {
        guard let trinket, trinket.surfaceID == nil else { return nil }
        return trinket.kind
    }

    /// 放在窗口顶上、正准备拨下去的东西
    var placedTrinket: (kind: Int, at: CGPoint)? {
        guard let trinket, trinket.surfaceID != nil else { return nil }
        return (trinket.kind, trinket.at)
    }

    /// 抖雪的进度 0...1
    var shakeProgress: CGFloat {
        if case .shake(let shake) = activity { return min(1, shake.t / shake.duration) }
        return 0
    }

    /// 跳跃进度 0...1（腾空时身体前倾 → 后仰）
    var airProgress: CGFloat {
        if case .jump(let j) = activity { return j.t }
        if case .pounce(let p) = activity { return p.jump.t }
        return 0.5
    }

    /// 蓄力下蹲进度 0...1
    var crouchProgress: CGFloat {
        if case .crouch(let t, let duration, _) = activity { return min(1, t / max(0.01, duration)) }
        return 0
    }

    /// 落地/急刹进度 0...1
    var landProgress: CGFloat {
        if case .land(let t, let duration, _) = activity { return min(1, t / max(0.01, duration)) }
        return 0
    }

    /// 是否处于急刹滑行
    var isSkidding: Bool {
        if case .land(_, _, let skidding) = activity { return skidding }
        return false
    }

    /// 立刻出门溜达一圈（设置里的演示按钮）
    mutating func goOutNow() {
        guard isHome else { return }
        forced = true
        cooldown = 0
        checkTimer = 0
    }

    /// 出门后的第一件事就是去偷看（设置里的「偷看一下」）
    mutating func peekNow(edge: RoamEdge? = nil) {
        goOutNow()
        forcedPeek = edge ?? .bottom
    }

    /// 出门后的第一件事就是找地方打个盹（设置里的「打个盹」）
    mutating func napNow() {
        goOutNow()
        forcedNap = true
    }

    /// 推东西演示：叼着东西出门，直接去窗口边上推（设置里的「推东西」）
    mutating func knockNow() {
        goOutNow()
        forcedKnock = true
    }

    /// 跳台演示：出门直接跳上窗口，再在窗口之间连跳几下（设置里的「跳台」）
    mutating func hopNow() {
        goOutNow()
        forcedHops = 3
    }

    private var forcedPeek: RoamEdge?
    private var forcedNap = false
    private var forcedKnock = false
    /// 叼着 / 放着的小东西，和要去推它的地方
    private(set) var trinket: CarriedTrinket?
    private var knockGoal: KnockGoal?
    /// 规划函数里产生的事件，update 结束时一起交出去
    private var pendingEvents: [RoamEvent] = []
    private var forcedHops = 0
    /// 这一轮光标逗猫：扑了几次、玩了多久；玩够了歇一会儿
    private var playSession = false
    private var playPounces = 0
    private var playTime: CGFloat = 0
    private var playCooldown: CGFloat = 0
    /// 扑完落地后接着盯
    private var resumeStalk = false
    /// 正在送牌（跑去举牌提醒的路上，或者正举着）
    private(set) var delivering = false
    var isHoldingSign: Bool { activity == .sign }
    /// 番茄钟：正在陪你专注（去趴着的路上，或者已经睡着了）
    private(set) var keepingCompany = false
    /// 陪你专注、已经蜷在那儿了（画番茄计时器用）
    var isFocusNapping: Bool { keepingCompany && isNapping && !delivering }
    /// 陪你专注时这一觉的长度：到点前一直续，不会自己醒
    static let focusNapHold: CGFloat = 600
    /// 正在去踢文件的路上，或者正在踢
    private(set) var kicking = false
    /// 走到窗框旁边后要开始的那次攀爬；跳上窗框侧边后接着爬的那次
    private var pendingClimb: Climb?
    private var wallJumpClimb: Climb?
    /// 这一趟已经睡过了：一趟最多睡一觉
    private var nappedThisTrip = false
    /// 这一趟已经安排了几件事（第一件多半是先走远一点）
    private var stepsThisTrip = 0
    /// 调试日志用
    var pendingForcedPeek: RoamEdge? { forcedPeek }

    mutating func update(dt: CGFloat, world: RoamWorld) -> [RoamEvent] {
        var events = step(dt: dt, world: world)
        events += pendingEvents
        pendingEvents.removeAll()
        return events
    }

    private mutating func step(dt: CGFloat, world input: RoamWorld) -> [RoamEvent] {
        var world = input
        // 陪你专注时你本来就在打字：不当作「快回来」；踢文件是你刚叫它去的，也不因为打字回来
        if world.focusSpot != nil || world.kickTarget != nil { world.userActive = false }
        var events: [RoamEvent] = []
        let k = world.scale
        lastFloor = world.floor
        lastScale = k
        if isHome {
            pos = world.seat
            cooldown = max(0, cooldown - dt)
            checkTimer -= dt
            lastNeedsAttention = world.needsAttention
            // 你让它踢文件：比什么都优先，不管冷却、不管漫游开没开，直接跳下座位
            if world.kickTarget != nil, !world.mustStayHome {
                tripForced = true
                startTrip(world: world, toFloor: true)
                kicking = true
                events.append(.leftSeat)
                return events
            }
            // 举牌提醒：不管冷却、不管漫游开没开（调用方已经判断过），直接跳下座位出发
            if world.signTarget != nil, !world.mustStayHome, !world.userActive {
                tripForced = true
                startTrip(world: world, toFloor: true)
                delivering = true
                events.append(.leftSeat)
                return events
            }
            // 番茄钟开始了：不管冷却，跳下座位去你的窗口上趴着
            if world.focusSpot != nil, !world.mustStayHome {
                tripForced = true
                startTrip(world: world, toFloor: true)
                keepingCompany = true
                events.append(.leftSeat)
                return events
            }
            guard !world.mustStayHome, !world.userActive, cooldown <= 0 else {
                forced = false
                forcedKnock = false
                return events
            }
            let idleEnough = world.keyIdle > Self.idleBeforeWander && world.keyIdle < Self.napAfter
            if forced || (world.wanderAllowed && idleEnough && checkTimer <= 0 && random() < 0.3) {
                tripForced = forced
                forced = false
                startTrip(world: world)
                considerKnockErrand(world: world)
                events.append(.leftSeat)
            } else if checkTimer <= 0 {
                checkTimer = 5
            }
            return events
        }

        tripTime += dt
        // agent 刚开始等你：跑回去提醒（手动出门时本来就在等的不算）
        let attentionRaised = world.needsAttention && !lastNeedsAttention
        lastNeedsAttention = world.needsAttention
        updateKick(world: world)
        updateFocus(world: world)
        updateDelivery(world: world)
        // 你一打字、或者有事要它待在座位上：跑回家（送牌的路上 agent 本来就在等你，不算叫它回来；
        // 陪你专注、去踢文件时 agent 等你，就地去举牌 / 踢完再说，不先跑回家）
        let urgent = world.userActive || world.mustStayHome
            || (attentionRaised && !delivering && !keepingCompany && !kicking)
        // 睡着时不因为到点就叫醒，睡完这一觉再回家；陪你专注时一直陪到番茄钟到点；踢文件时踢完再说
        let tripOver = tripTime > Self.maxTrip && !isNapping && !playSession && !delivering && !keepingCompany
            && !kicking
        if !returning && (urgent || tripOver || (!tripForced && !world.wanderAllowed && !delivering)) {
            beginReturn(world: world, run: urgent)
        } else if returning && urgent && !returningUrgently {
            // 正慢慢往回走时你开始打字：别闲逛了，立刻飞奔回去
            beginReturn(world: world, run: true)
        }

        // 站着的面被移走/关掉：跟着动，或者掉下去
        if let id = surfaceID, activity.map(isGrounded) ?? true {
            // 屏幕底部当作左右无限长：走出屏幕侧边（去偷看）不算踩空
            if id == world.floor.id {
                pos.y = world.floor.y
            } else if let s = world.surface(id: id), s.contains(x: pos.x, margin: -4), abs(s.y - pos.y) < 160 {
                pos.y = s.y
            } else {
                surfaceID = nil
                activity = .fall(vy: 0)
            }
        }

        playCooldown = max(0, playCooldown - dt)
        followPlacedTrinket(world: world)
        // 送牌、推东西、踢文件的路上、陪你专注时不被光标勾走
        if !returning && !delivering && knockGoal == nil && !keepingCompany && !kicking {
            considerCursorPlay(world: world)
        }

        switch activity {
        case .walk(let toX, let run):
            let dx = toX - pos.x
            let dist = abs(dx)
            let newFacing: CGFloat = dx >= 0 ? 1 : -1
            if newFacing != facing {
                currentSpeed *= 0.25
                facing = newFacing
            }
            let distCanvas = dist / max(0.01, k)
            let targetSpeed: CGFloat
            let accel: CGFloat
            let decel: CGFloat
            if run {
                targetSpeed = (!returning && distCanvas < 48)
                    ? max(Self.runSpeed * 0.45, Self.runSpeed * (distCanvas / 48))
                    : Self.runSpeed
                accel = 1100
                decel = 900
            } else {
                targetSpeed = distCanvas < 18
                    ? max(Self.walkSpeed * 0.35, Self.walkSpeed * (distCanvas / 18))
                    : Self.walkSpeed
                accel = 520
                decel = 480
            }
            if currentSpeed < targetSpeed {
                currentSpeed = min(targetSpeed, currentSpeed + accel * dt)
            } else {
                currentSpeed = max(targetSpeed, currentSpeed - decel * dt)
            }
            let step = min(dist, currentSpeed * k * dt)
            pos.x += step * facing
            // 飞奔步幅约 88 点（~2.7 次轻快大跳/秒），走路步幅约 44 点
            gaitPhase += step / ((run ? 88 : 44) * k) * .pi * 2
            if let id = surfaceID, world.snowySurfaces.contains(id) {
                snowWalk += dt
                snowTrip += dt
            }
            if abs(toX - pos.x) < 0.5 {
                // 疯跑到地方：压低身子带惯性急刹（往家跑时不刹，直接接着跳）。
                // 接下来要在这一点起跳、爬窗框、偷看、举牌、放东西、陪你专注或踢文件时原地刹住，不滑过头：
                // 滑过头会让起跳点对不上（跳的时候瞬移回去），举牌 / 推东西的目的地也永远到不了
                let mustStopHere = pendingJump != nil || pendingPeek != nil || pendingClimb != nil
                    || delivering || knockGoal != nil || keepingCompany || kicking
                activity = run && !returning ? .land(duration: mustStopHere ? 0.3 : 0.38, skidding: !mustStopHere) : nil
            }
        case .crouch(let t, let duration, let jump):
            let nt = t + dt
            activity = nt >= duration ? .jump(jump) : .crouch(t: nt, duration: duration, then: jump)
        case .jump(var j):
            currentSpeed *= exp(-18 * dt)
            j.t = min(1, j.t + dt / j.duration)
            pos = j.point(at: j.t)
            facing = j.to.x >= j.from.x ? 1 : -1
            if j.t >= 1 {
                pos = j.to
                if j.toWall {
                    // 抓住了窗框侧边：接着往上爬；半路上要回家了就直接松爪掉下来
                    if let climb = wallJumpClimb, !returning {
                        activity = .climb(climb)
                    } else {
                        surfaceID = nil
                        activity = .fall(vy: 0)
                    }
                    wallJumpClimb = nil
                } else if let surface = j.surface {
                    surfaceID = surface
                    activity = .land(duration: 0.24)
                    events.append(.landed)
                } else {
                    // 跳回座位
                    arriveHome()
                    events.append(.arrivedHome)
                    return events
                }
            } else {
                activity = .jump(j)
            }
        case .climb(var climb):
            currentSpeed *= exp(-18 * dt)
            // 窗口挪动了就跟着挪；关掉了就掉下来
            guard let wall = world.walls.first(where: { $0.surfaceID == climb.wall.surfaceID
                && $0.windowOnRight == climb.wall.windowOnRight && abs($0.x - climb.wall.x) < 40 }) else {
                surfaceID = nil
                activity = .fall(vy: 0)
                break
            }
            climb.wall = wall
            let step = Self.climbSpeed * k * dt
            climb.y += step
            // 一个攀爬周期约爬 48 点：每秒倒腾三四下，不像在原地刨
            gaitPhase += step / (48 * k) * .pi * 2
            facing = wall.windowOnRight ? 1 : -1
            pos = CGPoint(x: wall.x, y: min(climb.y, wall.top))
            if climb.y >= wall.top {
                // 爬到顶：翻上窗口，站在离角落一点点的地方
                pos = CGPoint(x: wall.x + (wall.windowOnRight ? 22 : -22) * k, y: wall.top)
                surfaceID = wall.surfaceID
                activity = .land(duration: 0.26)
                events.append(.landed)
            } else {
                activity = .climb(climb)
            }
        case .sign:
            currentSpeed *= exp(-18 * dt)
            // 你切到了别的窗口（目的地变了）：起身改去新的地方
            if let target = world.signTarget, target.surfaceID != surfaceID || abs(target.x - pos.x) > 80 * k {
                activity = nil
            }
        case .stalk(var stalk):
            stepStalk(&stalk, dt: dt, world: world)
        case .pounce(var pounce):
            currentSpeed *= exp(-18 * dt)
            pounce.jump.t = min(1, pounce.jump.t + dt / pounce.jump.duration)
            pos = pounce.jump.point(at: pounce.jump.t)
            // 前爪大约在脚前方 24、上方 62（画布点）：碰到光标就算抓到，一次扑只算一次
            if !pounce.caught, let cursor = world.cursor {
                let paw = CGPoint(x: pos.x + facing * 24 * k, y: pos.y + 62 * k)
                if hypot(cursor.x - paw.x, cursor.y - paw.y) < 42 * k {
                    pounce.caught = true
                    events.append(.caughtCursor)
                }
            }
            if pounce.jump.t >= 1 {
                pos = pounce.jump.to
                surfaceID = pounce.jump.surface
                if !pounce.caught { events.append(.missedCursor) }
                playPounces += 1
                resumeStalk = playSession
                activity = .land(duration: 0.30)
            } else {
                activity = .pounce(pounce)
            }
        case .shake(var shake):
            currentSpeed *= exp(-18 * dt)
            shake.t += dt
            activity = shake.t >= shake.duration ? nil : .shake(shake)
        case .knock(var knock):
            currentSpeed *= exp(-18 * dt)
            stepKnock(&knock, dt: dt, world: world)
        case .kick(var kick):
            currentSpeed *= exp(-18 * dt)
            stepKick(&kick, dt: dt, world: world, events: &events)
        case .land(let t, let duration, let skidding):
            if skidding {
                currentSpeed *= exp(-9.5 * dt)
                if let id = surfaceID, let here = world.surface(id: id) {
                    let nextX = pos.x + currentSpeed * k * dt * facing
                    pos.x = min(max(nextX, here.minX + 20 * k), here.maxX - 20 * k)
                }
            } else {
                currentSpeed *= exp(-18 * dt)
            }
            let nt = t + dt
            activity = nt >= duration ? nil : .land(t: nt, duration: duration, skidding: skidding)
        case .sit(let remaining):
            currentSpeed *= exp(-18 * dt)
            activity = remaining - dt <= 0 ? nil : .sit(remaining: remaining - dt)
        case .peek(var p):
            currentSpeed *= exp(-18 * dt)
            p.t += dt
            if p.t >= p.total {
                finishPeek(p, world: world)
            } else {
                activity = .peek(p)
            }
        case .nap(var n):
            currentSpeed *= exp(-18 * dt)
            n.t += dt * n.speed
            // 陪你专注：番茄钟没到点就一直睡，快醒时再续一觉
            if keepingCompany && !delivering && !kicking && n.asleep && n.t > Nap.settleTime + n.hold - 1 {
                n.hold += Self.focusNapHold
            }
            // 醒了：伸个懒腰（落地那种压低身子的姿势）再接着溜达
            activity = n.t >= n.total ? .land(duration: 0.45) : .nap(n)
        case .fall(let vy):
            currentSpeed *= exp(-18 * dt)
            let newVy = vy - Self.gravity * k * dt
            let newY = pos.y + newVy * dt
            // 落到脚下最高的那个面（窗口上沿或屏幕底）
            let below = world.surfaces
                .filter { $0.contains(x: pos.x) && $0.y <= pos.y + 0.5 && $0.y >= newY }
                .max { $0.y < $1.y }
            if let landing = below ?? (newY <= world.floor.y ? world.floor : nil) {
                pos.y = landing.y
                surfaceID = landing.id
                activity = .land(duration: 0.28)
                events.append(.landed)
                if returning { planReturnStep(world: world, run: returningUrgently) }
            } else {
                pos.y = newY
                activity = .fall(vy: newVy)
            }
        case nil:
            currentSpeed *= exp(-18 * dt)
        }

        if activity == nil, pendingJump == nil, pendingPeek == nil, pendingClimb == nil, !resumeStalk {
            considerShakingOffSnow(world: world)
        }
        if activity == nil, let climb = pendingClimb {
            pendingClimb = nil
            beginClimb(climb, world: world)
        }
        if activity == nil, resumeStalk {
            resumeStalk = false
            if !returning, playSession, playPounces < Self.maxPounces, cursorInterest(world: world) != nil {
                activity = .stalk(Stalk(phase: .notice, wiggleNeeded: 0.5 + CGFloat(random()) * 0.6))
            } else {
                endPlay()
            }
        }
        if activity == nil, let edge = pendingPeek {
            // 走出屏幕侧边了：在这条边的某个高度探头
            pendingPeek = nil
            startSidePeek(edge, world: world)
        } else if activity == nil, let jump = pendingJump {
            // 走到起跳点了：蹲一下再跳
            pendingJump = nil
            activity = .crouch(duration: pendingAim, then: jump)
            pendingAim = 0.26
        } else if activity == nil {
            if kicking && !returning {
                planKickStep(world: world, events: &events)
            } else if delivering && !returning {
                planDeliveryStep(world: world)
            } else if keepingCompany && !returning {
                planFocusStep(world: world)
            } else if knockGoal != nil && !returning {
                planKnockStep(world: world)
            } else if returning {
                planReturnStep(world: world, run: returningUrgently)
            } else if budget <= 0 {
                beginReturn(world: world, run: false)
            } else {
                budget -= 1
                planActivity(world: world)
            }
        }
        updateBlends(dt: dt)
        return events
    }

    private mutating func updateBlends(dt: CGFloat) {
        let currentPose = pose
        let targetRun: CGFloat = currentPose == .run ? min(1, max(0.35, currentSpeed / Self.runSpeed)) : 0
        let isMovingPose = currentPose == .walk || currentPose == .run || currentPose == .stalk
        let targetMove: CGFloat = (isMovingPose && currentSpeed > 2) ? min(1, currentSpeed / (Self.walkSpeed * 0.6)) : 0
        runBlend += (targetRun - runBlend) * min(1, 1 - exp(-11 * dt))
        moveBlend += (targetMove - moveBlend) * min(1, 1 - exp(-12 * dt))
        let turnStep = 16 * dt
        if turnScale < facing {
            turnScale = min(facing, turnScale + turnStep)
        } else if turnScale > facing {
            turnScale = max(facing, turnScale - turnStep)
        }
    }

    /// 一件事做完、下一件还没开始：在雪里走久了就站住抖抖爪子；从积雪的窗口下来就甩甩全身。
    /// 急着回家、送牌、逗猫时不抖
    private mutating func considerShakingOffSnow(world: RoamWorld) {
        guard !returningUrgently, !delivering, !playSession, let id = surfaceID else { return }
        if world.snowySurfaces.contains(id) {
            guard snowWalk >= Self.snowWalkBeforePawShake else { return }
            snowWalk = 0
            if random() < 0.65 { activity = .shake(Shake(paw: true, duration: 0.9)) }
        } else if snowTrip >= Self.snowBeforeBodyShake {
            snowTrip = 0
            snowWalk = 0
            activity = .shake(Shake(paw: false, duration: 1.1))
        }
    }

    private func isGrounded(_ a: Activity) -> Bool {
        switch a {
        case .walk, .sit, .land, .crouch, .nap, .stalk, .sign, .shake, .knock, .kick: return true
        case .jump, .fall, .peek, .pounce, .climb: return false
        }
    }

    // MARK: Cursor Play

    /// 漫游时的光标逗猫（键盘前那套的漫游版）：慢慢晃 → 盯上 → 潜伏挪近 → 扭屁股 → 扑；甩得快就冲刺追
    struct Stalk: Equatable {
        enum Phase: Equatable {
            /// 停下来盯着看
            case notice
            /// 压低身子慢慢挪近
            case creep
            /// 蹲着扭屁股蓄力
            case wiggle
            /// 光标甩远了：飞奔去追
            case dash
        }
        var phase: Phase
        var t: CGFloat = 0
        /// 扭够这么久才扑（真猫扑之前会扭上一阵子）
        var wiggleNeeded: CGFloat
    }

    struct Pounce: Equatable {
        var jump: Jump
        var caught = false
    }

    /// 光标在这个水平距离内才会被注意到（画布点，乘 scale）
    static let playNotice: CGFloat = 420
    /// 扑击距离：离光标这么远时开始扭屁股
    static let pounceNear: CGFloat = 70
    static let pounceFar: CGFloat = 240
    static let creepSpeed: CGFloat = 34
    /// 光标比这个快算"甩"：去追；比 30 慢算没在动
    static let flickSpeed: CGFloat = 900
    /// 一轮最多扑几次、玩多久；之后歇一会儿
    static let maxPounces = 3
    static let maxPlayTime: CGFloat = 25

    var isPlaying: Bool { playSession }

    /// 光标在不在逗猫范围里：返回它相对脚下这张桌子的水平距离和高度
    /// - Parameter chasing: 正在追（光标被甩远了）：不限水平距离，追不上靠 6 秒上限兜底
    private func cursorInterest(world: RoamWorld,
                                chasing: Bool = false) -> (dx: CGFloat, height: CGFloat, here: RoamSurface)? {
        guard let cursor = world.cursor, let id = surfaceID, let here = world.surface(id: id) else { return nil }
        let k = world.scale
        let dx = cursor.x - pos.x
        let height = cursor.y - here.y
        guard chasing || abs(dx) < Self.playNotice * k * 1.6,
              height > -60 * k, height < Self.maxJumpUp * k else { return nil }
        return (dx, height, here)
    }

    /// 溜达、坐着、刚落地发呆时，光标在附近晃动：开始一轮逗猫
    private mutating func considerCursorPlay(world: RoamWorld) {
        guard !playSession, playCooldown <= 0 else { return }
        switch activity {
        case nil, .sit: break
        case .walk(_, let run) where !run: break
        default: return
        }
        guard world.cursorSpeed > 30, world.cursorSpeed < 1500, let interest = cursorInterest(world: world),
              abs(interest.dx) < Self.playNotice * world.scale else { return }
        // 半路被光标吸引：原本要去偷看、要去起跳的计划作废
        pendingPeek = nil
        pendingJump = nil
        playSession = true
        playPounces = 0
        playTime = 0
        activity = .stalk(Stalk(phase: .notice, wiggleNeeded: 0.7 + CGFloat(random()) * 0.6))
    }

    private mutating func endPlay() {
        guard playSession else { return }
        playSession = false
        // 玩够了歇久一点，被打断的很快又能玩
        playCooldown = playPounces >= Self.maxPounces || playTime >= Self.maxPlayTime ? 15 : 5
    }

    private mutating func stepStalk(_ stalk: inout Stalk, dt: CGFloat, world: RoamWorld) {
        let k = world.scale
        let chasing = stalk.phase == .dash || world.cursorSpeed > Self.flickSpeed
        guard playSession, let interest = cursorInterest(world: world, chasing: chasing), let cursor = world.cursor,
              playTime < Self.maxPlayTime else {
            endPlay()
            activity = nil
            return
        }
        playTime += dt
        stalk.t += dt
        let here = interest.here
        let dist = abs(interest.dx)
        facing = interest.dx >= 0 ? 1 : -1
        let flicked = world.cursorSpeed > Self.flickSpeed
        let inRange = dist <= Self.pounceFar * k
        /// 沿脚下这张桌子往 goal 挪 speed 的距离，步态按 stride 走
        func move(toward goal: CGFloat, speed: CGFloat, stride: CGFloat) {
            let clamped = min(max(goal, here.minX + 20 * k), here.maxX - 20 * k)
            let accel: CGFloat = speed > Self.walkSpeed ? 1100 : 420
            if currentSpeed < speed {
                currentSpeed = min(speed, currentSpeed + accel * dt)
            } else {
                currentSpeed = max(speed, currentSpeed - 900 * dt)
            }
            let step = min(abs(clamped - pos.x), currentSpeed * k * dt)
            pos.x += step * (clamped >= pos.x ? 1 : -1)
            gaitPhase += step / (stride * k) * .pi * 2
        }
        switch stalk.phase {
        case .notice:
            currentSpeed *= exp(-18 * dt)
            if stalk.t >= 0.4 {
                stalk.phase = flicked ? .dash : (inRange ? .wiggle : .creep)
                stalk.t = 0
            }
        case .creep:
            if flicked {
                stalk.phase = .dash
                stalk.t = 0
            } else if inRange {
                stalk.phase = .wiggle
                stalk.t = 0
            } else {
                move(toward: cursor.x - facing * 160 * k, speed: Self.creepSpeed, stride: 28)
            }
        case .wiggle:
            currentSpeed *= exp(-18 * dt)
            if flicked {
                stalk.phase = .dash
                stalk.t = 0
            } else if dist > Self.pounceFar * k * 1.2 {
                stalk.phase = .creep
                stalk.t = 0
            } else if stalk.t >= stalk.wiggleNeeded {
                startPounce(at: cursor, from: here, k: k)
                return
            }
        case .dash:
            move(toward: cursor.x - facing * 130 * k, speed: Self.runSpeed, stride: 88)
            if !flicked && inRange && stalk.t > 0.3 {
                // 追上了：短短扭一下就扑
                stalk.phase = .wiggle
                stalk.t = 0
                stalk.wiggleNeeded = 0.35
            } else if stalk.t > 6 {
                endPlay()
                activity = nil
                return
            }
        }
        activity = .stalk(stalk)
    }

    /// 朝光标扑：落在光标正下方稍远一点的位置；光标在半空就跳到差不多的高度去够
    private mutating func startPounce(at cursor: CGPoint, from here: RoamSurface, k: CGFloat) {
        // 前爪比脚高约 55、靠前约 24：弧线顶点让前爪正好够到光标
        let reachUp = max(0, cursor.y - here.y - 55 * k)
        // 光标在半空：弧线最高点在起跳和落点正中间，所以落点放到光标后面，让最高点正好在光标下方；
        // 光标贴着桌面：直接扑到它身上
        let rawX = reachUp > 30 * k ? 2 * (cursor.x - facing * 24 * k) - pos.x : cursor.x + facing * 12 * k
        let toX = min(max(rawX, here.minX + 20 * k), here.maxX - 20 * k)
        let apex = min(Self.maxJumpUp * k, max(28 * k, reachUp + 10 * k))
        let dist = abs(toX - pos.x)
        let duration = min(0.75, max(0.35, 0.28 + dist / (1100 * k) + apex / (1800 * k)))
        let jump = Jump(from: pos, to: CGPoint(x: toX, y: here.y), duration: duration, apex: apex, surface: here.id)
        activity = .pounce(Pounce(jump: jump))
    }

    // MARK: Climbing

    /// 顺着窗框侧边往上爬
    struct Climb: Equatable {
        var wall: RoamWall
        /// 现在爬到的高度（脚的位置）
        var y: CGFloat
    }

    /// 爬的速度（画布点/秒，乘 scale）
    static let climbSpeed: CGFloat = 170

    /// 正在爬：窗口在小猫的右边（true）还是左边；不在爬时 nil（画的时候把小猫转 90 度）
    var climbWallOnRight: Bool? {
        if case .climb(let c) = activity { return c.wall.windowOnRight }
        return nil
    }

    /// 地上能爬的窗框：窗口顶太高、跳不上去的才爬；侧边下端要够得着（贴地，或者跳一下能抓住）。挑最近的
    private func climbTarget(from here: RoamSurface, world: RoamWorld) -> RoamWall? {
        let k = world.scale
        let candidates = world.walls.filter { wall in
            let start = max(wall.minY, here.y)
            return start - here.y <= Self.maxJumpUp * k * 0.8 && wall.top - here.y > Self.maxJumpUp * k * 0.9
        }
        return candidates.min { abs($0.x - pos.x) < abs($1.x - pos.x) }
    }

    /// 先走到窗框旁边（窗口外侧）
    private mutating func startClimb(_ wall: RoamWall, from here: RoamSurface, k: CGFloat, run: Bool = false) {
        let standX = wall.x + (wall.windowOnRight ? -16 : 16) * k
        let climb = Climb(wall: wall, y: max(wall.minY, here.y))
        if abs(standX - pos.x) > 1 {
            activity = .walk(toX: standX, run: run)
            pendingClimb = climb
        } else {
            activity = nil
            pendingClimb = climb
        }
    }

    /// 走到窗框旁边了：侧边贴地就直接爬；悬在半空就先蹲一下跳上去抓住
    private mutating func beginClimb(_ climb: Climb, world: RoamWorld) {
        let k = world.scale
        facing = climb.wall.windowOnRight ? 1 : -1
        if climb.y > pos.y + 8 * k {
            var jump = makeJump(from: pos, to: CGPoint(x: climb.wall.x, y: climb.y), surface: nil, k: k)
            jump.toWall = true
            wallJumpClimb = climb
            activity = .crouch(duration: 0.28, then: jump)
        } else {
            pos.x = climb.wall.x
            activity = .climb(climb)
        }
    }

    // MARK: Sign Delivery

    /// 举牌提醒开始 / 结束：开始时放下手头的事（正在跳、在掉、在扑的让它落地）；结束时放下牌子回家
    private mutating func updateDelivery(world: RoamWorld) {
        if world.signTarget != nil, !delivering, !world.userActive, !world.mustStayHome {
            releaseTrinket()
            delivering = true
            returning = false
            returningUrgently = false
            endPlay()
            pendingPeek = nil
            pendingJump = nil
            pendingClimb = nil
            resumeStalk = false
            switch activity {
            case .jump, .fall, .pounce, .crouch, .climb:
                break                                   // 让这一下做完，落地后再规划
            case .kick:
                break                                   // 正在踢文件：踢完再去
            case .nap(var nap):
                nap.wakeNow(startled: true)             // 一激灵醒来再去
                activity = .nap(nap)
            case .peek(var peek):
                let hideAt = peek.start + Peek.revealTime
                peek.hold = min(peek.hold, max(0, peek.t - hideAt))
                activity = .peek(peek)
            default:
                activity = nil
            }
        } else if world.signTarget == nil, delivering {
            // 你批准了（或者 agent 不等了）：放下牌子回家
            delivering = false
            if activity == .sign { activity = .land(duration: 0.3) }
            // 陪你专注时举完牌：回去接着趴着；去踢文件的路上：接着去踢
            if !returning && !keepingCompany && !kicking { beginReturn(world: world, run: false) }
        }
    }

    // MARK: Focus Company

    /// 番茄钟开始 / 到点。开始时放下手头的事（叼着的东西掉下来、不玩了），去你的窗口上趴着；
    /// 到点时醒过来慢慢回家（到点举牌由送牌接手：同一帧里 signTarget 会把它叫过去）
    private mutating func updateFocus(world: RoamWorld) {
        if world.focusSpot != nil, !keepingCompany {
            keepingCompany = true
            tripForced = true
            releaseTrinket()
            knockGoal = nil
            endPlay()
            pendingPeek = nil
            pendingJump = nil
            pendingClimb = nil
            resumeStalk = false
            // 正往家走（不是开会叫回去的）：掉头去陪你
            if returning && !world.mustStayHome {
                returning = false
                returningUrgently = false
            }
            switch activity {
            case .jump, .fall, .pounce, .crouch, .climb:
                break                                   // 让这一下做完，落地后再去
            case .nap(var nap):
                nap.wakeNow(startled: false)            // 在别处睡着呢：醒过来换个地方接着睡
                activity = .nap(nap)
            case .peek(var peek):
                let hideAt = peek.start + Peek.revealTime
                peek.hold = min(peek.hold, max(0, peek.t - hideAt))
                activity = .peek(peek)
            case .sign, .kick:
                break                                   // 正举着牌、正在踢文件：做完再去
            default:
                if !returning { activity = nil }
            }
        } else if world.focusSpot == nil, keepingCompany {
            keepingCompany = false
            if !delivering && !returning && !kicking { beginReturn(world: world, run: false) }
        }
    }

    /// 陪你专注的下一步：到了就蜷成一团睡；在别处就按跳台 / 爬窗 / 下地的顺序赶过去。
    /// 窗口顶上不去：在它正下方的屏幕底边睡
    private mutating func planFocusStep(world: RoamWorld) {
        guard let spot = world.focusSpot else { return }
        if travelStep(to: spot, world: world, belowIsFine: true) == .arrived {
            nappedThisTrip = true
            activity = .nap(Nap(hold: Self.focusNapHold))
        }
    }

    // MARK: Kick File

    /// 你让它踢文件 / 不踢了。开始时放下手头的事（叼着的东西掉下来、不玩了、睡着的醒过来、举着的牌放下），
    /// 掉头去踢；文件没了（你按 Esc 取消了）就回家。正常踢完由 stepKick 收尾
    private mutating func updateKick(world: RoamWorld) {
        if world.kickTarget != nil, !kicking {
            kicking = true
            tripForced = true
            releaseTrinket()
            knockGoal = nil
            endPlay()
            pendingPeek = nil
            pendingJump = nil
            pendingClimb = nil
            resumeStalk = false
            if returning {
                returning = false
                returningUrgently = false
            }
            switch activity {
            case .jump, .fall, .pounce, .crouch, .climb:
                break                                   // 让这一下做完，落地后再去
            case .nap(var nap):
                nap.wakeNow(startled: true)             // 一激灵醒来就去
                activity = .nap(nap)
            case .peek(var peek):
                let hideAt = peek.start + Peek.revealTime
                peek.hold = min(peek.hold, max(0, peek.t - hideAt))
                activity = .peek(peek)
            default:
                activity = nil                          // 举着的牌也先放下：踢完再回去举
            }
        } else if world.kickTarget == nil, kicking {
            if case .kick = activity { return }         // 已经踢出去了：把这一脚做完
            kicking = false
            if !delivering && !keepingCompany && !returning { beginReturn(world: world, run: false) }
        }
    }

    /// 站在文件哪一边踢：从哪边过来就往前踢（助跑一脚）；那一边站不下（文件贴着窗口边）就绕到另一边
    private func kickSide(_ target: RoamKickTarget, on surface: RoamSurface?,
                          scale: CGFloat) -> (dir: CGFloat, standX: CGFloat) {
        let reach = Self.kickReach * scale + target.halfWidth
        var dir: CGFloat = pos.x <= target.x ? 1 : -1
        if let surface {
            let fits = { (side: CGFloat) -> Bool in
                let standX = target.x - side * reach
                return standX >= surface.minX + 30 * scale && standX <= surface.maxX - 30 * scale
            }
            if !fits(dir) && fits(-dir) { dir = -dir }
        }
        return (dir, target.x - dir * reach)
    }

    /// 踢文件的下一步：赶到文件旁边；文件还在往下掉就等它落稳；到了就转过身起脚
    private mutating func planKickStep(world: RoamWorld, events: inout [RoamEvent]) {
        guard let target = world.kickTarget else {
            kicking = false
            return
        }
        let side = kickSide(target, on: world.surface(id: target.surfaceID), scale: world.scale)
        switch travelStep(to: RoamSignTarget(surfaceID: target.surfaceID, x: side.standX), world: world,
                          belowIsFine: false) {
        case .moving:
            break
        case .unreachable:
            // 上不去那扇窗口：让文件掉下来，在地上踢
            events.append(.kickTargetUnreachable)
            activity = .sit(remaining: 0.3)
        case .arrived:
            guard target.ready else {
                activity = .sit(remaining: 0.2)
                return
            }
            facing = side.dir
            let range = Kick.angles
            activity = .kick(Kick(angle: range.lowerBound + CGFloat(random()) * (range.upperBound - range.lowerBound)))
        }
    }

    /// 一脚踢出去：爪子碰到文件的那一刻交出 .kickedFile。碰到之前文件掉走了（窗口挪了）就重新去追
    private mutating func stepKick(_ kick: inout Kick, dt: CGFloat, world: RoamWorld, events: inout [RoamEvent]) {
        kick.t += dt
        if !kick.launched {
            let scale = world.scale
            guard let target = world.kickTarget, target.ready, target.surfaceID == surfaceID,
                  abs(abs(target.x - pos.x) - (Self.kickReach * scale + target.halfWidth)) < 24 * scale,
                  (target.x - pos.x) * facing > 0 else {
                activity = nil
                return
            }
            if kick.t >= Kick.contact {
                kick.launched = true
                events.append(.kickedFile(angle: kick.angle, dir: facing))
            }
        }
        guard kick.t < Kick.total else {
            // 踢完了：站着看它飞走一会儿，再回家（或者接着去举牌、回去陪你专注）
            kicking = false
            budget = 0
            activity = .sit(remaining: 0.9)
            return
        }
        activity = .kick(kick)
    }

    /// 送牌的下一步：到了就坐下举牌；在别处就按跳台 / 爬窗 / 下地的顺序赶过去
    private mutating func planDeliveryStep(world: RoamWorld) {
        guard let target = world.signTarget else { return }
        // 窗口顶上不去：在它正下方的屏幕底边举牌
        if travelStep(to: target, world: world, belowIsFine: true) == .arrived {
            activity = .sign
        }
    }

    private enum TravelStep {
        case moving, arrived, unreachable
    }

    /// 赶往 target 的下一步：在脚下这张桌子上就走过去；在别处就按跳台 / 爬窗 / 下地的顺序赶过去。
    /// 到了返回 .arrived（到了做什么由调用方决定）。上不去那扇窗口时：belowIsFine 就去它正下方的屏幕底边，否则 .unreachable
    private mutating func travelStep(to target: RoamSignTarget, world: RoamWorld, belowIsFine: Bool) -> TravelStep {
        let k = world.scale
        guard let id = surfaceID, let here = world.surface(id: id) else {
            activity = .fall(vy: 0)
            return .moving
        }
        let floor = world.floor
        /// 在脚下这张桌子上走到 x
        func goTo(_ x: CGFloat) -> TravelStep {
            let spot = min(max(x, here.minX + 30 * k), here.maxX - 30 * k)
            guard abs(spot - pos.x) > 3 * k else { return .arrived }
            activity = .walk(toX: spot, run: true)
            return .moving
        }
        /// 从窗口顶跳到地上，落在离目标近的那一侧
        func dropToFloor() -> TravelStep {
            let downX = min(max(pos.x + (target.x > pos.x ? 60 : -60) * k, floor.minX + 20 * k), floor.maxX - 20 * k)
            activity = .crouch(duration: 0.12, then: makeJump(from: pos, to: CGPoint(x: downX, y: floor.y),
                                                              surface: floor.id, k: k))
            return .moving
        }
        func below() -> TravelStep {
            guard belowIsFine else { return .unreachable }
            return id == floor.id ? goTo(target.x) : dropToFloor()
        }
        if id == target.surfaceID { return goTo(target.x) }
        if target.surfaceID == floor.id { return id == floor.id ? goTo(target.x) : dropToFloor() }
        // 那扇窗口没了
        guard let goal = world.surface(id: target.surfaceID) else { return below() }
        if startRoute(to: goal, from: here, world: world) { return .moving }
        // 从这扇窗口过不去：先下到地上，地上可能有窗框能爬
        return id == floor.id ? below() : dropToFloor()
    }

    /// 往那扇窗口去的第一步：直接跳过去；在地上就找窗框爬；在窗口上就在窗口之间跳过去。出发了返回 true
    private mutating func startRoute(to goal: RoamSurface, from here: RoamSurface, world: RoamWorld) -> Bool {
        let k = world.scale
        if let hop = hopPlan(from: here, at: pos.x, to: goal, k: k, jitter: 0.5) {
            startHop(hop, from: here, to: goal, k: k, run: true)
            return true
        }
        if here.id == world.floor.id {
            let reachable = world.walls.filter {
                $0.surfaceID == goal.id && max($0.minY, here.y) - here.y <= Self.maxJumpUp * k * 0.8
            }
            guard let wall = reachable.min(by: { abs($0.x - pos.x) < abs($1.x - pos.x) }) else { return false }
            startClimb(wall, from: here, k: k, run: true)
            return true
        }
        guard let (next, hop) = nextHop(from: here, at: pos.x, world: world, isGoal: { $0.id == goal.id }) else {
            return false
        }
        startHop(hop, from: here, to: next, k: k, run: true)
        return true
    }

    /// 从地上（座位旁）能不能到那段窗口上沿：直接跳上去、顺着窗框爬、或者在窗口之间跳过去
    private func reachable(_ target: RoamSurface, world: RoamWorld) -> Bool {
        let k = world.scale
        let floor = world.floor
        let x = world.seat.x
        if hopPlan(from: floor, at: x, to: target, k: k, jitter: 0.5) != nil { return true }
        if world.walls.contains(where: { $0.surfaceID == target.id && $0.minY - floor.y <= Self.maxJumpUp * k * 0.8 }) {
            return true
        }
        return nextHop(from: floor, at: x, world: world, isGoal: { $0.id == target.id }) != nil
    }

    // MARK: Knock Things Off

    /// 出门时偶尔叼走你桌上的一样小东西，打算找扇窗口把它推下去
    private mutating func considerKnockErrand(world: RoamWorld) {
        let force = forcedKnock
        forcedKnock = false
        guard force || world.knockAllowed else { return }
        guard force || random() < Self.knockChance, let goal = pickKnockGoal(world: world) else { return }
        knockGoal = goal
        trinket = CarriedTrinket(kind: Int(random() * 5) % 5, surfaceID: nil, at: world.seat)
        budget = max(budget, 2)
    }

    /// 挑一扇够宽的窗口，随便往哪边推
    private func pickKnockGoal(world: RoamWorld) -> KnockGoal? {
        let k = world.scale
        let need = (Self.trinketReach + Self.tapPush.upperBound * 3 + 70) * k
        // 只挑够宽、而且到得了的窗口（太高又没窗框可爬的不去）
        let options = world.windowTops.filter { $0.width >= need && reachable($0, world: world) }
        guard !options.isEmpty else { return nil }
        let pick = options[Int(random() * Double(options.count)) % options.count]
        return KnockGoal(surfaceID: pick.id, dir: random() < 0.5 ? -1 : 1)
    }

    /// 坐在哪儿放东西：东西放下时离边还有三四下的距离
    private func knockSpot(_ goal: KnockGoal, on surface: RoamSurface, k: CGFloat) -> CGFloat {
        let edge = goal.dir > 0 ? surface.maxX : surface.minX
        return edge - goal.dir * (Self.trinketReach + 38) * k
    }

    private mutating func planKnockStep(world: RoamWorld) {
        guard let goal = knockGoal, let surface = world.surface(id: goal.surfaceID) else {
            // 那扇窗口没了：东西丢下，接着溜达
            releaseTrinket()
            return
        }
        let target = RoamSignTarget(surfaceID: goal.surfaceID, x: knockSpot(goal, on: surface, k: world.scale))
        switch travelStep(to: target, world: world, belowIsFine: false) {
        case .moving:
            break
        case .unreachable:
            releaseTrinket()
        case .arrived:
            facing = goal.dir
            activity = .knock(Knock(phase: .setDown))
        }
    }

    private mutating func stepKnock(_ knock: inout Knock, dt: CGFloat, world: RoamWorld) {
        knock.t += dt
        let k = world.scale
        guard let goal = knockGoal, surfaceID == goal.surfaceID, let surface = world.surface(id: goal.surfaceID) else {
            releaseTrinket()
            activity = nil
            return
        }
        facing = goal.dir
        switch knock.phase {
        case .setDown:
            // 低头把嘴里的东西放在面前
            if knock.t >= 0.3 { putDownTrinket(on: surface, k: k) }
            if knock.t >= 0.55 { knock = Knock(phase: .stare, hold: 1.2 + CGFloat(random()) * 0.9) }
        case .stare:
            if knock.t >= knock.hold { knock = Knock(phase: .tap) }
        case .tap:
            stepTap(&knock, dt: dt, surface: surface, k: k)
            knock = followUpTap(knock)
        case .watch:
            // 探头看它掉下去
            if knock.t >= 1.5 {
                knockGoal = nil
                activity = nil
                return
            }
        }
        activity = .knock(knock)
    }

    /// 拨完一下之后：推下去了就探头看；没推下去多半接着拨，偶尔停下来再盯一会儿（像在想「推不推呢」）
    private mutating func followUpTap(_ knock: Knock) -> Knock {
        if trinket == nil { return Knock(phase: .watch) }
        guard knock.t >= Self.tapDuration else { return knock }
        return random() < 0.35 ? Knock(phase: .stare, hold: 0.5 + CGFloat(random()) * 0.5) : Knock(phase: .tap)
    }

    /// 嘴里的东西放到面前的窗口顶上（已经放下了就什么都不做）
    private mutating func putDownTrinket(on surface: RoamSurface, k: CGFloat) {
        guard var item = trinket, item.surfaceID == nil else { return }
        let x = pos.x + facing * Self.trinketReach * k
        item.surfaceID = surface.id
        item.dx = x - surface.minX
        item.at = CGPoint(x: x, y: surface.y)
        trinket = item
    }

    /// 一下拨爪：碰到的那一刻把东西往边上推一段，推过了边就掉下去；之后往前挪一点跟上
    private mutating func stepTap(_ knock: inout Knock, dt: CGFloat, surface: RoamSurface, k: CGFloat) {
        guard var item = trinket, item.surfaceID != nil else { return }
        if !knock.hit && knock.t >= Self.tapContact {
            knock.hit = true
            let range = Self.tapPush
            let push = (range.lowerBound + CGFloat(random()) * (range.upperBound - range.lowerBound)) * k
            item.dx += facing * push
            item.at.x = surface.minX + item.dx
            let edge = facing > 0 ? surface.maxX : surface.minX
            if facing * (item.at.x - edge) > 0 {
                // 推过了边：掉下去
                pendingEvents.append(.releasedTrinket(kind: item.kind, at: CGPoint(x: item.at.x, y: surface.y),
                                                      vx: facing * CGFloat(70 + random() * 60)))
                trinket = nil
                return
            }
            trinket = item
            knock.scoot = push
        }
        // 碰完往前挪，挪到和东西保持原来的距离（别走出窗口）
        if knock.scoot > 0 {
            let stepX = min(knock.scoot, Self.walkSpeed * 0.6 * k * dt)
            let limit = facing > 0 ? surface.maxX - 30 * k : surface.minX + 30 * k
            pos.x = facing > 0 ? min(pos.x + stepX, limit) : max(pos.x - stepX, limit)
            knock.scoot -= stepX
        }
    }

    /// 放着的东西跟着窗口走；窗口没了就掉下去
    private mutating func followPlacedTrinket(world: RoamWorld) {
        guard var item = trinket, let id = item.surfaceID else { return }
        guard let surface = world.surface(id: id) else {
            releaseTrinket()
            return
        }
        item.at = CGPoint(x: surface.minX + item.dx, y: surface.y)
        trinket = item
    }

    /// 东西离开小猫：从嘴里掉下来，或者留在窗口顶上（调用方接手让它往下掉 / 躺着）
    private mutating func releaseTrinket() {
        knockGoal = nil
        guard let item = trinket else { return }
        trinket = nil
        let k = lastScale
        // 嘴大约在脚前方 46、上方 62（3/4 视角小猫画布单位）
        let at = item.surfaceID == nil ? CGPoint(x: pos.x + facing * 46 * k, y: pos.y + 62 * k) : item.at
        pendingEvents.append(.releasedTrinket(kind: item.kind, at: at, vx: 0))
    }

    // MARK: Planning

    /// - Parameter toFloor: 一定先跳到地上（送牌时不随机跳上旁边的窗口，路线交给送牌规划）
    private mutating func startTrip(world: RoamWorld, toFloor: Bool = false) {
        isHome = false
        returning = false
        returningUrgently = false
        tripTime = 0
        budget = 3 + Int(random() * 3)
        nappedThisTrip = false
        stepsThisTrip = 0
        currentSpeed = 0
        runBlend = 0
        moveBlend = 0
        pos = world.seat
        surfaceID = nil
        let k = world.scale
        // 旁边有够得着的窗口：一半的时候直接从座位跳上去（像从这张桌子跳到那张桌子）
        let seat = world.seat
        let landings = world.windowTops.compactMap { top -> (id: Int, at: CGPoint)? in
            guard top.width > 90 * k, top.y - seat.y <= Self.maxJumpUp * k * 0.8 else { return nil }
            let landX = min(max(seat.x, top.minX + 40 * k), top.maxX - 40 * k)
            // 落点在键盘窗口后面（被挡住）的不算；几乎原地不动的也不算
            guard abs(landX - seat.x) <= Self.maxJumpDX * k * 0.7,
                  abs(landX - seat.x) > 50 * k || abs(top.y - seat.y) > 60 * k,
                  !world.homeRect.contains(CGPoint(x: landX, y: top.y + 20 * k)) else { return nil }
            return (top.id, CGPoint(x: landX, y: top.y))
        }
        if !toFloor, !landings.isEmpty, forcedHops > 0 || random() < 0.5 {
            let pick = landings[Int(random() * Double(landings.count)) % landings.count]
            let jump = makeJump(from: seat, to: pick.at, surface: pick.id, k: k)
            facing = jump.to.x >= jump.from.x ? 1 : -1
            turnScale = facing
            activity = .crouch(duration: 0.35, then: jump)
            return
        }
        let floor = world.floor
        // 座位在别的屏幕上（去另一块屏幕踢文件）：一个大跳跳过去，落在这块屏幕靠座位那边的边上
        if !floor.contains(x: world.seat.x) {
            let edgeX = world.seat.x > floor.maxX ? floor.maxX - 70 * k : floor.minX + 70 * k
            let leap = makeLeap(from: world.seat, to: CGPoint(x: edgeX, y: floor.y), surface: floor.id, k: k)
            facing = leap.to.x >= leap.from.x ? 1 : -1
            turnScale = facing
            activity = .crouch(duration: 0.30, then: leap)
            return
        }
        // 从座位跳到主窗口旁边的地上（左边地方够就往左，否则往右）
        let leftX = world.homeRect.minX - 40 * k
        let rightX = world.homeRect.maxX + 40 * k
        let x = floor.contains(x: leftX, margin: 20 * k)
            ? leftX
            : (floor.contains(x: rightX, margin: 20 * k) ? rightX : world.seat.x)
        let to = CGPoint(x: x, y: floor.y)
        let jump = makeJump(from: world.seat, to: to, surface: floor.id, k: k)
        facing = jump.to.x >= jump.from.x ? 1 : -1
        turnScale = facing
        activity = .crouch(duration: 0.30, then: jump)
    }

    private mutating func planActivity(world: RoamWorld) {
        let k = world.scale
        guard let id = surfaceID, let here = world.surface(id: id) else {
            activity = .fall(vy: 0)
            return
        }
        stepsThisTrip += 1
        let roll = random()
        if let edge = forcedPeek, id == world.floor.id {
            // 演示：直接去偷看
            forcedPeek = nil
            if edge == .bottom {
                surfaceID = nil
                activity = .peek(Peek(edge: .bottom, hold: 5))
            } else {
                activity = .walk(toX: edge == .left ? world.floor.minX - 60 * k : world.floor.maxX + 60 * k, run: false)
                pendingPeek = edge
            }
            return
        }
        // 刚跳下座位：多半先走远一段再说，不然总在键盘边上打转
        let free = forcedHops == 0 && !forcedNap
        if free, stepsThisTrip == 1, id == world.floor.id, random() < 0.7 {
            activity = .walk(toX: exploreTarget(on: here, k: k), run: random() < Self.zoomiesChance)
            return
        }
        // 打盹：一趟最多一次，先溜达过再睡；窗口顶上（高处）更想睡，闲得越久越困
        let onHighPlace = id != world.floor.id
        let napChance = (onHighPlace ? 0.35 : 0.16) * (world.keyIdle > 120 ? 1.7 : 1)
        if forcedHops == 0, forcedNap || (!nappedThisTrip && stepsThisTrip > 1 && random() < napChance) {
            let hold: CGFloat = forcedNap ? 12 : 15 + CGFloat(random()) * (world.keyIdle > 120 ? 35 : 20)
            forcedNap = false
            nappedThisTrip = true
            activity = .nap(Nap(hold: hold))
            return
        }
        // 能跳过去的其他面：窗口顶就是一张张桌子，地面是最大的那张
        let hops = world.surfaces.compactMap { target -> (RoamSurface, Hop)? in
            guard target.id != id, target.width > 90 * k,
                  let hop = hopPlan(from: here, at: pos.x, to: target, k: k, jitter: CGFloat(random())) else {
                return nil
            }
            return (target, hop)
        }
        let onWindow = id != world.floor.id
        let windowHops = hops.filter { $0.0.id != world.floor.id }
        // 在窗口顶上：多半接着跳去别的窗口（桌子之间跳来跳去）；在地上：偶尔跳上窗口
        let hopChance = onWindow ? (windowHops.isEmpty ? 0.3 : 0.6) : 0.35
        if forcedHops > 0, !windowHops.isEmpty {
            forcedHops -= 1
            budget = max(budget, 1)
            let pick = windowHops[Int(random() * Double(windowHops.count)) % windowHops.count]
            startHop(pick.1, from: here, to: pick.0, k: k, run: false)
            return
        }
        // 窗口顶太高跳不上去：在地上时找一条窗框侧边爬上去（演示时一定爬）
        if id == world.floor.id, let wall = climbTarget(from: here, world: world),
           forcedHops > 0 || random() < 0.3 {
            startClimb(wall, from: here, k: k)
            return
        }
        forcedHops = 0
        if roll < hopChance, !hops.isEmpty {
            let pool = onWindow && !windowHops.isEmpty ? windowHops : hops
            let pick = pool[Int(random() * Double(pool.count)) % pool.count]
            startHop(pick.1, from: here, to: pick.0, k: k, run: false)
            return
        }
        let other = random()
        if other < 0.22 {
            activity = .sit(remaining: 3 + CGFloat(random() * 5))
            return
        }
        // 在地上时偶尔躲到屏幕边外面偷看
        if other < 0.52, id == world.floor.id {
            if random() < 0.45 {
                surfaceID = nil
                activity = .peek(Peek(edge: .bottom, hold: 3.5 + CGFloat(random() * 2.5)))
            } else {
                // 左右随机挑一边：远的那边就一路走过去，顺便逛遍整个屏幕
                let edge: RoamEdge = random() < 0.5 ? .left : .right
                let offX = edge == .left ? world.floor.minX - 60 * k : world.floor.maxX + 60 * k
                activity = .walk(toX: offX, run: false)
                pendingPeek = edge
            }
            return
        }
        // 沿着脚下这张桌子溜达；在地上偶尔突然发疯狂奔一段（猫的 zoomies）
        activity = .walk(toX: exploreTarget(on: here, k: k), run: id == world.floor.id && random() < Self.zoomiesChance)
    }

    /// 溜达的目的地：离当前位置至少桌面宽度的三成，空间大的那一侧更容易被选中（往没去过的地方走）
    private func exploreTarget(on here: RoamSurface, k: CGFloat) -> CGFloat {
        let margin = 30 * k
        let lo = here.minX + margin, hi = here.maxX - margin
        guard hi > lo else { return pos.x }
        let minDist = (hi - lo) * 0.3
        let leftRoom = max(0, pos.x - minDist - lo)
        let rightRoom = max(0, hi - (pos.x + minDist))
        guard leftRoom + rightRoom > 1 else { return lo + CGFloat(random()) * (hi - lo) }
        let pick = CGFloat(random()) * (leftRoom + rightRoom)
        return pick < leftRoom ? lo + pick : pos.x + minDist + (pick - leftRoom)
    }

    // MARK: Hopping

    /// 从一张桌子跳到另一张：在哪起跳、落在哪
    struct Hop: Equatable {
        var launchX: CGFloat
        var landX: CGFloat
    }

    /// 能不能从 here（站在 x 附近）跳到 target。
    /// 上下叠着的两张桌子在重叠的那段里起跳；左右分开的要走到桌边，跨过缝隙落到对面桌边。
    /// - Parameter jitter: 0...1，落点离桌边多远（让每次跳的落点不一样）
    func hopPlan(from here: RoamSurface, at x: CGFloat, to target: RoamSurface, k: CGFloat, jitter: CGFloat) -> Hop? {
        let up = target.y - here.y
        guard up <= Self.maxJumpUp * k else { return nil }
        let lo = max(here.minX, target.minX), hi = min(here.maxX, target.maxX)
        if hi - lo >= 50 * k {
            // 同一高度又左右重叠：其实是同一张桌子，不用跳
            guard abs(up) > 30 * k else { return nil }
            let launch = min(max(x, lo + 20 * k), hi - 20 * k)
            let land = min(max(launch + (jitter * 2 - 1) * 90 * k, target.minX + 30 * k), target.maxX - 30 * k)
            return Hop(launchX: launch, landX: land)
        }
        let toRight = target.minX + target.maxX > here.minX + here.maxX
        let launch = toRight ? here.maxX - 14 * k : here.minX + 14 * k
        let inset = (30 + jitter * 70) * k
        let land = toRight
            ? min(target.minX + inset, target.maxX - 20 * k)
            : max(target.maxX - inset, target.minX + 20 * k)
        guard abs(land - launch) <= Self.maxJumpDX * k else { return nil }
        return Hop(launchX: launch, landX: land)
    }

    /// 先走到起跳点（桌边），蹲下瞄准再跳。跨大缝之前多蹲一会儿
    private mutating func startHop(_ hop: Hop, from here: RoamSurface, to target: RoamSurface, k: CGFloat, run: Bool) {
        let jump = makeJump(from: CGPoint(x: hop.launchX, y: here.y), to: CGPoint(x: hop.landX, y: target.y),
                            surface: target.id, k: k)
        let aim: CGFloat = run ? 0.12 : (abs(hop.landX - hop.launchX) > 150 * k ? 0.55 : 0.28)
        if abs(hop.launchX - pos.x) > 1 {
            activity = .walk(toX: hop.launchX, run: run)
            pendingJump = jump
            pendingAim = aim
        } else {
            activity = .crouch(duration: aim, then: jump)
        }
    }

    /// 站在 surface 上能不能一跳回到座位；能的话在哪起跳
    private func seatLaunchX(from surface: RoamSurface, world: RoamWorld) -> CGFloat? {
        let k = world.scale
        let seat = world.seat
        let launch = min(max(seat.x, surface.minX + 20 * k), surface.maxX - 20 * k)
        guard abs(seat.x - launch) <= Self.maxJumpDX * k * 0.6,
              seat.y - surface.y <= Self.maxJumpUp * k else { return nil }
        return launch
    }

    /// 回家路线：只踩窗口顶，最多跳几下能到一个够得着座位的窗口。返回第一跳；找不到返回 nil（那就先下地）
    private func nextHopHome(from here: RoamSurface, at x: CGFloat, world: RoamWorld) -> (RoamSurface, Hop)? {
        nextHop(from: here, at: x, world: world) { seatLaunchX(from: $0, world: world) != nil }
    }

    /// 只踩窗口顶，最多跳 4 下到达满足 isGoal 的那张桌子：返回第一跳
    private func nextHop(from here: RoamSurface, at x: CGFloat, world: RoamWorld,
                         isGoal: (RoamSurface) -> Bool) -> (RoamSurface, Hop)? {
        let k = world.scale
        let tops = world.windowTops.filter { $0.width > 90 * k }
        // 广度优先：(当前面, 落脚 x, 第一跳)
        var frontier: [(RoamSurface, CGFloat, (RoamSurface, Hop)?)] = [(here, x, nil)]
        var seen: Set<Int> = [here.id]
        for _ in 0..<4 {
            var next: [(RoamSurface, CGFloat, (RoamSurface, Hop)?)] = []
            for (surface, at, first) in frontier {
                for target in tops where !seen.contains(target.id) {
                    guard let hop = hopPlan(from: surface, at: at, to: target, k: k, jitter: 0.5) else { continue }
                    let firstHop = first ?? (target, hop)
                    if isGoal(target) { return firstHop }
                    seen.insert(target.id)
                    next.append((target, hop.landX, firstHop))
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return nil
    }

    /// 走到起跳点之后要接的那一跳
    private var pendingJump: Jump?
    /// 起跳前蹲多久（瞄准）
    private var pendingAim: CGFloat = 0.26

    private mutating func beginReturn(world: RoamWorld, run: Bool) {
        releaseTrinket()
        delivering = false
        if activity == .sign { activity = nil }
        returning = true
        returningUrgently = returningUrgently || run
        budget = 0
        // 正在跳的那一下让它跳完，落地后再规划
        if case .jump = activity { return }
        if case .pounce = activity { return }
        endPlay()
        pendingClimb = nil
        if case .climb = activity {
            // 爬到一半要回家：松爪跳下来
            surfaceID = nil
            activity = .fall(vy: 0)
            return
        }
        if case .fall = activity { return }
        if case .nap(var n) = activity {
            // 在睡觉：醒过来（被吵醒的话一激灵），醒透了再回家
            n.wakeNow(startled: run)
            activity = .nap(n)
            return
        }
        if case .peek(var p) = activity {
            // 正在偷看：别再看了，马上缩回去，缩回来之后再回家
            let hideAt = p.start + Peek.revealTime
            p.hold = min(p.hold, max(0, p.t - hideAt))
            activity = .peek(p)
            return
        }
        pendingJump = nil
        pendingPeek = nil
        planReturnStep(world: world, run: run)
    }

    // MARK: Peek

    private mutating func startSidePeek(_ edge: RoamEdge, world: RoamWorld) {
        let k = world.scale
        let floor = world.floor
        // 探头的高度：地面以上、菜单栏以下的随便一个位置
        let room = max(0, world.screenTop - floor.y - 260 * k)
        let y = floor.y + 70 * k + CGFloat(random()) * min(room, 360 * k)
        pos = CGPoint(x: edge == .left ? floor.minX : floor.maxX, y: y)
        facing = edge == .left ? 1 : -1
        turnScale = facing
        surfaceID = nil
        activity = .peek(Peek(edge: edge, hold: 3.5 + CGFloat(random() * 2.5)))
    }

    /// 偷看完：底边 → 从下面跳回地面；侧边 → 从那条边走回屏幕里
    private mutating func finishPeek(_ p: Peek, world: RoamWorld) {
        let k = world.scale
        let floor = world.floor
        switch p.edge {
        case .bottom:
            let x = min(max(pos.x, floor.minX + 30 * k), floor.maxX - 30 * k)
            let from = CGPoint(x: x, y: floor.y - 70 * k)
            activity = .jump(Jump(from: from, to: CGPoint(x: x, y: floor.y), duration: 0.42, apex: 26 * k,
                                  surface: floor.id))
            pos = from
        case .left, .right:
            let left = p.edge == .left
            pos = CGPoint(x: left ? floor.minX - 50 * k : floor.maxX + 50 * k, y: floor.y)
            surfaceID = floor.id
            facing = left ? 1 : -1
            turnScale = facing
            activity = .walk(toX: left ? floor.minX + 120 * k : floor.maxX - 120 * k, run: returningUrgently)
        }
    }

    /// 回家的下一步：够得着座位就直接跳回去；否则先跳到地上，再走到座位旁边起跳
    private mutating func planReturnStep(world: RoamWorld, run: Bool) {
        let k = world.scale
        pendingJump = nil
        let seat = world.seat
        let dx = abs(seat.x - pos.x)
        let up = seat.y - pos.y
        // 在地上走到座位旁边了，哪怕座位很高也一个大跳跳回去（不然会原地踏步）
        let onFloorNearSeat = surfaceID == world.floor.id && dx <= Self.maxJumpDX * k * 0.45
        if dx <= Self.maxJumpDX * k * 0.6 && (up <= Self.maxJumpUp * k || onFloorNearSeat) {
            activity = .crouch(duration: run ? 0.12 : 0.25, then: makeJump(from: pos, to: seat, surface: nil, k: k))
            return
        }
        if let id = surfaceID, id != world.floor.id, let here = world.surface(id: id) {
            // 在窗口顶上：这张桌子够得着座位就走到桌边跳回去；不然顺着别的窗口一路跳回去
            if let launch = seatLaunchX(from: here, world: world) {
                let jump = makeJump(from: CGPoint(x: launch, y: here.y), to: seat, surface: nil, k: k)
                if abs(launch - pos.x) > 1 {
                    activity = .walk(toX: launch, run: run)
                    pendingJump = jump
                    pendingAim = run ? 0.12 : 0.25
                } else {
                    activity = .crouch(duration: run ? 0.12 : 0.25, then: jump)
                }
                return
            }
            if let (target, hop) = nextHopHome(from: here, at: pos.x, world: world) {
                startHop(hop, from: here, to: target, k: k, run: run)
                return
            }
        }
        if surfaceID != world.floor.id {
            // 先跳到地上
            let floor = world.floor
            let downX = min(max(pos.x + (seat.x > pos.x ? 60 : -60) * k, floor.minX + 20 * k), floor.maxX - 20 * k)
            let to = CGPoint(x: downX, y: floor.y)
            activity = .crouch(duration: 0.12, then: makeJump(from: pos, to: to, surface: world.floor.id, k: k))
            return
        }
        // 座位在别的屏幕上：跑到这块屏幕靠座位那边的边上，一个大跳跳回去
        if !world.floor.contains(x: seat.x) {
            let floor = world.floor
            let edgeX = seat.x > floor.maxX ? floor.maxX - 40 * k : floor.minX + 40 * k
            let leap = makeLeap(from: CGPoint(x: edgeX, y: floor.y), to: seat, surface: nil, k: k)
            if abs(edgeX - pos.x) > 3 * k {
                activity = .walk(toX: edgeX, run: true)
                pendingJump = leap
                pendingAim = 0.2
            } else {
                activity = .crouch(duration: 0.2, then: leap)
            }
            return
        }
        // 在地上：走到座位水平距离够得着的地方
        let approach = seat.x + (pos.x < seat.x ? -1 : 1) * min(dx, Self.maxJumpDX * k * 0.4)
        activity = .walk(toX: approach, run: run)
    }

    private func makeJump(from: CGPoint, to: CGPoint, surface: Int?, k: CGFloat) -> Jump {
        let dist = hypot(to.x - from.x, to.y - from.y)
        let duration = min(0.85, max(0.38, 0.3 + dist / (900 * k)))
        return Jump(from: from, to: to, duration: duration, apex: (28 + min(60, dist * 0.12)) * k, surface: surface)
    }

    /// 跨屏的大跳：比平常的跳慢一点、弧线高一点，看得清是飞过去的
    private func makeLeap(from: CGPoint, to destination: CGPoint, surface: Int?, k scale: CGFloat) -> Jump {
        let dist = hypot(destination.x - from.x, destination.y - from.y)
        let duration = min(1.4, max(0.6, 0.35 + dist / (1600 * scale)))
        return Jump(from: from, to: destination, duration: duration, apex: (90 + min(160, dist * 0.08)) * scale,
                    surface: surface)
    }

    private mutating func arriveHome() {
        releaseTrinket()
        isHome = true
        currentSpeed = 0
        runBlend = 0
        moveBlend = 0
        snowWalk = 0
        snowTrip = 0
        returning = false
        returningUrgently = false
        activity = nil
        surfaceID = nil
        pendingJump = nil
        pendingPeek = nil
        forcedNap = false
        forcedHops = 0
        playSession = false
        resumeStalk = false
        pendingClimb = nil
        wallJumpClimb = nil
        delivering = false
        // 开会被叫回来的：会开完了，在家里重新看一眼番茄钟还在不在
        keepingCompany = false
        kicking = false
        cooldown = 60 + CGFloat(random() * 60)
        checkTimer = 5
    }
}
