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
    /// 蜷成一团睡觉（趴下 → 蜷起来 → 醒来伸展）
    case curl
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

    enum Activity: Equatable {
        case walk(toX: CGFloat, run: Bool)
        case peek(Peek)
        case nap(Nap)
        case crouch(remaining: CGFloat, then: Jump)
        case jump(Jump)
        /// 盯上光标：发现 → 潜伏 → 扭屁股；光标一甩就冲刺追
        case stalk(Stalk)
        /// 朝光标扑过去；飞行途中前爪碰到光标就算抓到
        case pounce(Pounce)
        /// 顺着窗框侧边往上爬，到顶翻上窗口
        case climb(Climb)
        case land(remaining: CGFloat)
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
    static let walkSpeed: CGFloat = 70
    static let runSpeed: CGFloat = 230
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

    /// 跳跃进度 0...1（腾空时身体前倾 → 后仰）
    var airProgress: CGFloat {
        if case .jump(let j) = activity { return j.t }
        if case .pounce(let p) = activity { return p.jump.t }
        return 0.5
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

    /// 跳台演示：出门直接跳上窗口，再在窗口之间连跳几下（设置里的「跳台」）
    mutating func hopNow() {
        goOutNow()
        forcedHops = 3
    }

    private var forcedPeek: RoamEdge?
    private var forcedNap = false
    private var forcedHops = 0
    /// 这一轮光标逗猫：扑了几次、玩了多久；玩够了歇一会儿
    private var playSession = false
    private var playPounces = 0
    private var playTime: CGFloat = 0
    private var playCooldown: CGFloat = 0
    /// 扑完落地后接着盯
    private var resumeStalk = false
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
        var events: [RoamEvent] = []
        let k = world.scale
        lastFloor = world.floor
        lastScale = k
        if isHome {
            pos = world.seat
            cooldown = max(0, cooldown - dt)
            checkTimer -= dt
            lastNeedsAttention = world.needsAttention
            guard !world.mustStayHome, !world.userActive, cooldown <= 0 else { forced = false; return events }
            let idleEnough = world.keyIdle > Self.idleBeforeWander && world.keyIdle < Self.napAfter
            if forced || (world.wanderAllowed && idleEnough && checkTimer <= 0 && random() < 0.3) {
                tripForced = forced
                forced = false
                startTrip(world: world)
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
        // 你一打字、或者有事要它待在座位上：跑回家
        let urgent = world.userActive || world.mustStayHome || attentionRaised
        // 睡着时不因为到点就叫醒，睡完这一觉再回家
        let tripOver = tripTime > Self.maxTrip && !isNapping && !playSession
        if !returning && (urgent || tripOver || (!tripForced && !world.wanderAllowed)) {
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
        if !returning { considerCursorPlay(world: world) }

        switch activity {
        case .walk(let toX, let run):
            let speed = (run ? Self.runSpeed : Self.walkSpeed) * k
            let dx = toX - pos.x
            facing = dx >= 0 ? 1 : -1
            let step = min(abs(dx), speed * dt)
            pos.x += step * facing
            // 一个步态周期：走路约 40 个画布点；飞奔一步跨得远（约 75），步频约 3 次/秒，和真猫差不多
            gaitPhase += step / ((run ? 75 : 40) * k) * .pi * 2
            if abs(toX - pos.x) < 0.5 {
                // 疯跑到地方：压低身子急刹一下（往家跑时不刹，直接接着跳）
                activity = run && !returning ? .land(remaining: 0.3) : nil
            }
        case .crouch(let remaining, let jump):
            activity = remaining - dt <= 0 ? .jump(jump) : .crouch(remaining: remaining - dt, then: jump)
        case .jump(var j):
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
                    activity = .land(remaining: 0.22)
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
                activity = .land(remaining: 0.25)
                events.append(.landed)
            } else {
                activity = .climb(climb)
            }
        case .stalk(var stalk):
            stepStalk(&stalk, dt: dt, world: world)
        case .pounce(var pounce):
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
                activity = .land(remaining: 0.3)
            } else {
                activity = .pounce(pounce)
            }
        case .land(let remaining):
            activity = remaining - dt <= 0 ? nil : .land(remaining: remaining - dt)
        case .sit(let remaining):
            activity = remaining - dt <= 0 ? nil : .sit(remaining: remaining - dt)
        case .peek(var p):
            p.t += dt
            if p.t >= p.total {
                finishPeek(p, world: world)
            } else {
                activity = .peek(p)
            }
        case .nap(var n):
            n.t += dt * n.speed
            // 醒了：伸个懒腰（落地那种压低身子的姿势）再接着溜达
            activity = n.t >= n.total ? .land(remaining: 0.45) : .nap(n)
        case .fall(let vy):
            let newVy = vy - Self.gravity * k * dt
            let newY = pos.y + newVy * dt
            // 落到脚下最高的那个面（窗口上沿或屏幕底）
            let below = world.surfaces
                .filter { $0.contains(x: pos.x) && $0.y <= pos.y + 0.5 && $0.y >= newY }
                .max { $0.y < $1.y }
            if let landing = below ?? (newY <= world.floor.y ? world.floor : nil) {
                pos.y = landing.y
                surfaceID = landing.id
                activity = .land(remaining: 0.28)
                events.append(.landed)
                if returning { planReturnStep(world: world, run: returningUrgently) }
            } else {
                pos.y = newY
                activity = .fall(vy: newVy)
            }
        case nil:
            break
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
            activity = .crouch(remaining: pendingAim, then: jump)
            pendingAim = 0.26
        } else if activity == nil {
            if returning {
                planReturnStep(world: world, run: returningUrgently)
            } else if budget <= 0 {
                beginReturn(world: world, run: false)
            } else {
                budget -= 1
                planActivity(world: world)
            }
        }
        return events
    }

    private func isGrounded(_ a: Activity) -> Bool {
        switch a {
        case .walk, .sit, .land, .crouch, .nap, .stalk: return true
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
            let step = min(abs(clamped - pos.x), speed * k * dt)
            pos.x += step * (clamped >= pos.x ? 1 : -1)
            gaitPhase += step / (stride * k) * .pi * 2
        }
        switch stalk.phase {
        case .notice:
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
                move(toward: cursor.x - facing * 160 * k, speed: Self.creepSpeed, stride: 26)
            }
        case .wiggle:
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
            move(toward: cursor.x - facing * 130 * k, speed: Self.runSpeed, stride: 75)
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
    private mutating func startClimb(_ wall: RoamWall, from here: RoamSurface, k: CGFloat) {
        let standX = wall.x + (wall.windowOnRight ? -16 : 16) * k
        let climb = Climb(wall: wall, y: max(wall.minY, here.y))
        if abs(standX - pos.x) > 1 {
            activity = .walk(toX: standX, run: false)
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
            activity = .crouch(remaining: 0.28, then: jump)
        } else {
            pos.x = climb.wall.x
            activity = .climb(climb)
        }
    }

    // MARK: Planning

    private mutating func startTrip(world: RoamWorld) {
        isHome = false
        returning = false
        returningUrgently = false
        tripTime = 0
        budget = 3 + Int(random() * 3)
        nappedThisTrip = false
        stepsThisTrip = 0
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
        if !landings.isEmpty, forcedHops > 0 || random() < 0.5 {
            let pick = landings[Int(random() * Double(landings.count)) % landings.count]
            activity = .crouch(remaining: 0.35, then: makeJump(from: seat, to: pick.at, surface: pick.id, k: k))
            return
        }
        // 从座位跳到主窗口旁边的地上（左边地方够就往左，否则往右）
        let floor = world.floor
        let leftX = world.homeRect.minX - 40 * k
        let rightX = world.homeRect.maxX + 40 * k
        let x = floor.contains(x: leftX, margin: 20 * k)
            ? leftX
            : (floor.contains(x: rightX, margin: 20 * k) ? rightX : world.seat.x)
        let to = CGPoint(x: x, y: floor.y)
        activity = .crouch(remaining: 0.3, then: makeJump(from: world.seat, to: to, surface: floor.id, k: k))
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
            activity = .crouch(remaining: aim, then: jump)
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
                    if seatLaunchX(from: target, world: world) != nil { return firstHop }
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
            activity = .crouch(remaining: run ? 0.12 : 0.25, then: makeJump(from: pos, to: seat, surface: nil, k: k))
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
                    activity = .crouch(remaining: run ? 0.12 : 0.25, then: jump)
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
            activity = .crouch(remaining: 0.12, then: makeJump(from: pos, to: to, surface: world.floor.id, k: k))
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

    private mutating func arriveHome() {
        isHome = true
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
        cooldown = 60 + CGFloat(random() * 60)
        checkTimer = 5
    }
}
