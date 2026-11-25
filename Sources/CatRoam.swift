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

    var surfaces: [RoamSurface] { [floor] + windowTops }

    func surface(id: Int) -> RoamSurface? { surfaces.first { $0.id == id } }
}

// MARK: - Director

enum RoamPose: Equatable {
    case stand, walk, run, crouch, air, land, sit
    /// 扒着屏幕边偷看：只露脑袋和两只爪子
    case peek
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
    static let maxTrip: CGFloat = 90
    /// 闲置多久之后才自己出门（秒）
    static let idleBeforeWander: Double = 30
    /// 闲置这么久（人大概离开了）就不再出门，安心在座位上睡觉
    static let napAfter: Double = 600
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
        case .jump, .fall: return .air
        case .land: return .land
        case .sit: return .sit
        case .peek(let p): return p.t < p.start ? .crouch : .peek
        case .nap: return .curl
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
    /// 这一趟已经睡过了：一趟最多睡一觉
    private var nappedThisTrip = false
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
        let tripOver = tripTime > Self.maxTrip && !isNapping
        if !returning && (urgent || tripOver || (!tripForced && !world.wanderAllowed)) {
            beginReturn(world: world, run: urgent)
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

        switch activity {
        case .walk(let toX, let run):
            let speed = (run ? Self.runSpeed : Self.walkSpeed) * k
            let dx = toX - pos.x
            facing = dx >= 0 ? 1 : -1
            let step = min(abs(dx), speed * dt)
            pos.x += step * facing
            // 一个步态周期大约走 40 个画布点
            gaitPhase += step / (40 * k) * .pi * 2
            if abs(toX - pos.x) < 0.5 { activity = nil }
        case .crouch(let remaining, let jump):
            activity = remaining - dt <= 0 ? .jump(jump) : .crouch(remaining: remaining - dt, then: jump)
        case .jump(var j):
            j.t = min(1, j.t + dt / j.duration)
            pos = j.point(at: j.t)
            facing = j.to.x >= j.from.x ? 1 : -1
            if j.t >= 1 {
                pos = j.to
                if let surface = j.surface {
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
                if returning { planReturnStep(world: world, run: true) }
            } else {
                pos.y = newY
                activity = .fall(vy: newVy)
            }
        case nil:
            break
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
                planReturnStep(world: world, run: true)
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
        case .walk, .sit, .land, .crouch, .nap: return true
        case .jump, .fall, .peek: return false
        }
    }

    // MARK: Planning

    private mutating func startTrip(world: RoamWorld) {
        isHome = false
        returning = false
        tripTime = 0
        budget = 2 + Int(random() * 3)
        nappedThisTrip = false
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
        // 打盹：一趟最多一次；窗口顶上（高处）更想睡，闲得越久越困
        let onHighPlace = id != world.floor.id
        let napChance = (onHighPlace ? 0.35 : 0.16) * (world.keyIdle > 120 ? 1.7 : 1)
        if forcedHops == 0, forcedNap || (!nappedThisTrip && random() < napChance) {
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
        forcedHops = 0
        if roll < hopChance, !hops.isEmpty {
            let pool = onWindow && !windowHops.isEmpty ? windowHops : hops
            let pick = pool[Int(random() * Double(pool.count)) % pool.count]
            startHop(pick.1, from: here, to: pick.0, k: k, run: false)
            return
        }
        let other = random()
        if other < 0.27 {
            activity = .sit(remaining: 3 + CGFloat(random() * 5))
            return
        }
        // 在地上时偶尔躲到屏幕边外面偷看
        if other < 0.67, id == world.floor.id {
            if random() < 0.45 {
                surfaceID = nil
                activity = .peek(Peek(edge: .bottom, hold: 3.5 + CGFloat(random() * 2.5)))
            } else {
                let edge: RoamEdge = pos.x - world.floor.minX < world.floor.maxX - pos.x ? .left : .right
                let offX = edge == .left ? world.floor.minX - 60 * k : world.floor.maxX + 60 * k
                activity = .walk(toX: offX, run: false)
                pendingPeek = edge
            }
            return
        }
        // 沿着脚下这张桌子溜达
        let margin = 30 * k
        let x = here.minX + margin + CGFloat(random()) * max(1, here.width - margin * 2)
        activity = .walk(toX: x, run: false)
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
        budget = 0
        // 正在跳的那一下让它跳完，落地后再规划
        if case .jump = activity { return }
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
            activity = .walk(toX: left ? floor.minX + 120 * k : floor.maxX - 120 * k, run: returning)
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
        activity = nil
        surfaceID = nil
        pendingJump = nil
        pendingPeek = nil
        forcedNap = false
        forcedHops = 0
        cooldown = 60 + CGFloat(random() * 60)
        checkTimer = 5
    }
}
