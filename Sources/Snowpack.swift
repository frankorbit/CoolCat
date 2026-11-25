import CoreGraphics
import Foundation

// MARK: - Snowpack

/// 窗口顶上的积雪：下雪的季节里，能站的窗口上沿慢慢积一层雪；小猫走过留下一串脚印，
/// 落地溅起雪沫，抖爪子、甩身子时雪块飞出去；窗口一拖动，上面的雪整块滑落。
///
/// 纯逻辑，不碰 AppKit（屏幕坐标，y 向上），由调用方每帧喂窗口位置和小猫的状态，便于单测。
struct Snowpack {
    /// 一扇窗口顶上的雪
    struct Cap: Equatable {
        /// 0…1：积了多厚
        var depth: CGFloat
        /// 上次看到时的窗口位置：挪了、改了大小，雪就滑下来
        var frame: CGRect
        /// 现在露在外面、能看到雪的那几段上沿（被前面的窗口挡住的部分不画）
        var segments: [RoamSurface]
        /// 多久没看到这扇窗口了（切到别的桌面、最小化）：太久就忘掉
        var unseen: CGFloat
    }

    /// 一个脚印：跟着窗口走，记录相对窗口左边的位置；雪慢慢把它填平（越来越小）
    struct Print: Equatable {
        var windowID: Int
        var dx: CGFloat
        var age: CGFloat
        var size: CGFloat
    }

    /// 飞出去的小雪块：落地溅起的、抖下来的、窗口拖动时滑落的
    struct Clump: Equatable {
        var pos: CGPoint
        var vel: CGVector
        var size: CGFloat
        var age: CGFloat
        var life: CGFloat
    }

    enum Shake {
        case paw, body
    }

    /// 真下雪时积满一层要多久（秒）
    static let growTime: CGFloat = 240
    /// 不下雪了多久化完
    static let meltTime: CGFloat = 90
    /// 预览时积得快、化得快
    static let previewGrowTime: CGFloat = 6
    static let previewMeltTime: CGFloat = 8
    /// 积到这么厚才算「踩得出脚印」「需要抖爪子」
    static let snowyDepth: CGFloat = 0.3
    /// 脚印多久被雪填平
    static let printLife: CGFloat = 40
    static let maxPrints = 90
    static let maxClumps = 160
    /// 窗口太久没出现就不记了
    static let forgetAfter: CGFloat = 600
    /// 雪块的重力（点/秒²）
    static let gravity: CGFloat = 900

    private(set) var caps: [Int: Cap] = [:]
    private(set) var prints: [Print] = []
    private(set) var clumps: [Clump] = []
    /// 0…1：爪子上沾了多少雪（在雪里走就沾上，抖一抖就掉）
    private(set) var pawSnow: CGFloat = 0
    /// 结构变了（窗口、段落、脚印增减）：画面要重建路径
    private(set) var revision = 0
    private var lastStep: Int?
    private var lastStepSurface: Int?
    private let random: () -> Double

    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    /// 窗口上沿的 id = 窗口号 × 8 + 段号 + 1；0 是屏幕底部
    static func windowID(of surfaceID: Int) -> Int? {
        surfaceID > 0 ? (surfaceID - 1) / 8 : nil
    }

    var isEmpty: Bool { caps.isEmpty && clumps.isEmpty }

    /// 有雪可画（积了一点就算）
    var hasVisibleSnow: Bool {
        caps.values.contains { $0.depth > 0.02 && !$0.segments.isEmpty } || !clumps.isEmpty
    }

    /// 雪厚到会踩出脚印的那些面（给漫游逻辑：在这些面上走久了会抖爪子）
    var snowySurfaces: Set<Int> {
        var out: Set<Int> = []
        for cap in caps.values where cap.depth >= Self.snowyDepth {
            for seg in cap.segments { out.insert(seg.id) }
        }
        return out
    }

    func depth(onSurface id: Int) -> CGFloat {
        guard let window = Self.windowID(of: id) else { return 0 }
        return caps[window]?.depth ?? 0
    }

    // MARK: Per Frame

    /// - Parameters:
    ///   - snowing: 现在该不该积雪
    ///   - surfaces: 这次扫描到的能站的窗口上沿（已经去掉被挡住的部分）
    ///   - frames: 这块屏幕上所有窗口的位置（挪没挪、关没关）
    ///   - floorY: 屏幕底：雪块掉到这里就没了
    mutating func update(dt: CGFloat, snowing: Bool, growTime: CGFloat = growTime, meltTime: CGFloat = meltTime,
                         surfaces: [RoamSurface], frames: [Int: CGRect], floorY: CGFloat) {
        var byWindow: [Int: [RoamSurface]] = [:]
        for surface in surfaces {
            guard let id = Self.windowID(of: surface.id) else { continue }
            byWindow[id, default: []].append(surface)
        }
        reconcile(byWindow: byWindow, frames: frames, dt: dt)
        // 新出现的窗口：从零开始积
        if snowing {
            for (id, segments) in byWindow where caps[id] == nil {
                guard let frame = frames[id] else { continue }
                caps[id] = Cap(depth: 0, frame: frame, segments: segments, unseen: 0)
                revision += 1
            }
        }
        accumulate(dt: dt, snowing: snowing, growTime: growTime, meltTime: meltTime)
        // 脚印慢慢被填平
        let before = prints.count
        for i in prints.indices { prints[i].age += dt }
        prints.removeAll { $0.age >= Self.printLife || caps[$0.windowID] == nil }
        if prints.count != before { revision += 1 }
        pawSnow = max(0, pawSnow - dt / 45)
        stepClumps(dt: dt, floorY: floorY)
    }

    /// 已经记着的窗口：挪了、改了大小就滑落；看不到了（切桌面、最小化）就先藏着
    private mutating func reconcile(byWindow: [Int: [RoamSurface]], frames: [Int: CGRect], dt: CGFloat) {
        for (id, var cap) in caps {
            if let frame = frames[id] {
                if Self.moved(cap.frame, frame) {
                    // 没看着它挪（藏着的时候挪的）：不凭空掉雪块，悄悄清零
                    if cap.unseen == 0 { shed(cap) }
                    cap.depth = 0
                    cap.frame = frame
                    prints.removeAll { $0.windowID == id }
                    revision += 1
                }
                cap.unseen = 0
            } else {
                cap.unseen += dt
            }
            let segments = frames[id] == nil ? [] : (byWindow[id] ?? [])
            if segments != cap.segments {
                cap.segments = segments
                revision += 1
            }
            caps[id] = cap
        }
    }

    /// 积 / 化；化完了、或者太久没见到的窗口就忘掉
    private mutating func accumulate(dt: CGFloat, snowing: Bool, growTime: CGFloat, meltTime: CGFloat) {
        for (id, var cap) in caps {
            if snowing {
                if !cap.segments.isEmpty { cap.depth = min(1, cap.depth + dt / max(0.1, growTime)) }
            } else {
                cap.depth = max(0, cap.depth - dt / max(0.1, meltTime))
            }
            if (cap.depth <= 0 && !snowing) || cap.unseen > Self.forgetAfter {
                caps[id] = nil
                prints.removeAll { $0.windowID == id }
                revision += 1
            } else {
                caps[id] = cap
            }
        }
    }

    /// 这一帧小猫在干什么（踩脚印用）
    struct Walker {
        var pos: CGPoint
        var surfaceID: Int?
        /// 在走 / 跑 / 潜伏（站着、坐着不算）
        var moving: Bool
        var running: Bool
        /// 步态相位（弧度），每过半个周期落一步
        var gaitPhase: CGFloat
        var facing: CGFloat
    }

    /// 小猫在窗口顶上走：每落一步踩一个脚印，跑起来往后踢雪沫
    /// - Parameter k: 小猫的体型缩放
    mutating func track(_ cat: Walker, k: CGFloat) {
        let pos = cat.pos, facing = cat.facing, running = cat.running
        guard cat.moving, let surface = cat.surfaceID, let window = Self.windowID(of: surface),
              let cap = caps[window], cap.depth >= Self.snowyDepth * 0.6,
              let seg = cap.segments.first(where: { $0.id == surface }), seg.contains(x: pos.x, margin: 2) else {
            lastStep = nil
            return
        }
        let step = Int(floor(cat.gaitPhase / .pi))
        defer {
            lastStep = step
            lastStepSurface = surface
        }
        guard let last = lastStep, lastStepSurface == surface, step != last else { return }
        // 前后脚交替落在身体前后两侧
        let spread: CGFloat = (step % 2 == 0 ? 14 : -14) * k
        let x = min(max(pos.x + spread * facing, seg.minX + 2), seg.maxX - 2)
        prints.append(Print(windowID: window, dx: x - cap.frame.minX, age: 0,
                            size: (running ? 1.15 : 1) * (0.85 + CGFloat(random()) * 0.3)))
        if prints.count > Self.maxPrints { prints.removeFirst(prints.count - Self.maxPrints) }
        pawSnow = min(1, pawSnow + 0.06 * cap.depth)
        revision += 1
        if running {
            // 往后踢起一两块雪沫
            let top = seg.y + Self.capHeight(depth: cap.depth)
            for _ in 0..<2 {
                spawn(at: CGPoint(x: x, y: top), vx: -facing * CGFloat(60 + random() * 90),
                      vy: CGFloat(80 + random() * 120), size: CGFloat(1.2 + random() * 1.4), life: 0.9)
            }
        }
    }

    /// 落在积雪的窗口顶上：溅起一圈雪沫
    mutating func puff(at pos: CGPoint, surfaceID: Int?) {
        guard let surface = surfaceID, depth(onSurface: surface) >= Self.snowyDepth * 0.6 else { return }
        let top = pos.y + Self.capHeight(depth: depth(onSurface: surface))
        for i in 0..<10 {
            let side: CGFloat = i % 2 == 0 ? 1 : -1
            spawn(at: CGPoint(x: pos.x + side * CGFloat(random() * 12), y: top),
                  vx: side * CGFloat(50 + random() * 110), vy: CGFloat(90 + random() * 140),
                  size: CGFloat(1.3 + random() * 1.8), life: 1.1)
        }
        pawSnow = min(1, pawSnow + 0.15)
    }

    /// 抖爪子：爪子前面甩出几粒雪；甩身子：全身往四周飞雪
    mutating func shakeOff(_ kind: Shake, at pos: CGPoint, facing: CGFloat, k: CGFloat) {
        switch kind {
        case .paw:
            let paw = CGPoint(x: pos.x + facing * 24 * k, y: pos.y + 14 * k)
            let amount = 3 + Int(pawSnow * 6)
            for _ in 0..<amount {
                spawn(at: paw, vx: facing * CGFloat(40 + random() * 100) + CGFloat(random() - 0.5) * 60,
                      vy: CGFloat(40 + random() * 110), size: CGFloat(1.1 + random() * 1.2), life: 1)
            }
            pawSnow *= 0.3
        case .body:
            let center = CGPoint(x: pos.x, y: pos.y + 45 * k)
            for i in 0..<22 {
                let angle = CGFloat(i) / 22 * 2 * .pi + CGFloat(random()) * 0.3
                let speed = CGFloat(110 + random() * 130)
                spawn(at: CGPoint(x: center.x + cos(angle) * 24 * k, y: center.y + sin(angle) * 14 * k),
                      vx: cos(angle) * speed, vy: max(20, sin(angle) * speed + 90),
                      size: CGFloat(1.2 + random() * 1.6), life: 1.2)
            }
            pawSnow = 0
        }
    }

    // MARK: Geometry

    /// 雪层厚度（点）：薄薄一层到厚厚一层
    static func capHeight(depth: CGFloat) -> CGFloat {
        depth <= 0.02 ? 0 : 2.5 + depth * 9
    }

    /// 雪带底边压进窗口上沿多少点：盖住窗口边框，不留缝
    static let capOverlap: CGFloat = 2

    /// 窗口挪动、改大小超过一点点才算（扫描坐标有半点的抖动）
    static func moved(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 1.5 || abs(a.minY - b.minY) > 1.5
            || abs(a.width - b.width) > 1.5 || abs(a.height - b.height) > 1.5
    }

    // MARK: Private

    /// 窗口挪走了：雪按厚度碎成一串雪块掉下去
    private mutating func shed(_ cap: Cap) {
        guard cap.depth > 0.05 else { return }
        let top = Self.capHeight(depth: cap.depth)
        for seg in cap.segments {
            let count = min(26, Int(seg.width / 16 * cap.depth) + 2)
            for _ in 0..<count {
                let x = seg.minX + CGFloat(random()) * seg.width
                spawn(at: CGPoint(x: x, y: seg.y + CGFloat(random()) * top), vx: CGFloat(random() - 0.5) * 50,
                      vy: CGFloat(random() * 60), size: CGFloat(1.6 + random() * 2.2 * cap.depth), life: 2.2)
            }
        }
    }

    private mutating func spawn(at pos: CGPoint, vx: CGFloat, vy: CGFloat, size: CGFloat, life: CGFloat) {
        guard clumps.count < Self.maxClumps else { return }
        clumps.append(Clump(pos: pos, vel: CGVector(dx: vx, dy: vy), size: size, age: 0, life: life))
    }

    private mutating func stepClumps(dt: CGFloat, floorY: CGFloat) {
        guard !clumps.isEmpty else { return }
        for i in clumps.indices {
            clumps[i].vel.dy -= Self.gravity * dt
            // 空气阻力：横着飞的很快慢下来
            clumps[i].vel.dx *= max(0, 1 - dt * 1.8)
            clumps[i].pos.x += clumps[i].vel.dx * dt
            clumps[i].pos.y += clumps[i].vel.dy * dt
            clumps[i].age += dt
        }
        clumps.removeAll { $0.age >= $0.life || $0.pos.y < floorY }
    }
}

// MARK: - Paths

extension Snowpack {
    /// 积雪层：每段上沿一条白色雪带。底边压住窗口上沿一点（不留缝），两端从窗口圆角上耷拉下来，
    /// 顶上一个个圆鼓包（同一扇窗口每次起伏都一样）
    /// - Parameter origin: 画布原点在屏幕上的位置（返回的路径在画布坐标里，y 向上）
    func capPath(origin: CGPoint) -> CGPath {
        capOutline(origin: origin, shade: false)
    }

    /// 雪带底部的阴影（淡蓝灰）：让一层雪看起来有厚度
    func capShadePath(origin: CGPoint) -> CGPath {
        capOutline(origin: origin, shade: true)
    }

    private func capOutline(origin: CGPoint, shade: Bool) -> CGPath {
        let path = CGMutablePath()
        for (id, cap) in caps where cap.depth > 0.02 {
            let full = Self.capHeight(depth: cap.depth)
            for seg in cap.segments where seg.width > 12 {
                let minX = seg.minX - origin.x, maxX = seg.maxX - origin.x
                let base = seg.y - origin.y - Self.capOverlap
                // 阴影只占雪带下面四成
                let h = shade ? full * 0.4 + Self.capOverlap : full + Self.capOverlap
                let drape = min(full * 0.6 + 2, 6)
                let end = min(full * 1.3 + 4, seg.width / 4)
                // 左端：从圆角外侧耷拉下来，再鼓上去
                path.move(to: CGPoint(x: minX + 1, y: base - drape))
                path.addCurve(to: CGPoint(x: minX + end, y: base + h * 0.9),
                              control1: CGPoint(x: minX - 1.5, y: base + h * 0.5),
                              control2: CGPoint(x: minX + end * 0.35, y: base + h * 1.05))
                // 顶上的鼓包：每 16–24 点一个
                var x = minX + end
                let seed = CGFloat(id % 97)
                var i = 0
                while x < maxX - end - 1 {
                    let width = 16 + 8 * (0.5 + 0.5 * sin(CGFloat(i) * 1.7 + seed))
                    let next = min(maxX - end, x + width)
                    let bump = 0.75 + 0.25 * sin((x + seg.minX) * 0.05 + seed)
                    path.addQuadCurve(to: CGPoint(x: next, y: base + h * 0.9),
                                      control: CGPoint(x: (x + next) / 2, y: base + h * (0.9 + 0.32 * bump)))
                    x = next
                    i += 1
                }
                // 右端
                path.addCurve(to: CGPoint(x: maxX - 1, y: base - drape),
                              control1: CGPoint(x: maxX - end * 0.35, y: base + h * 1.05),
                              control2: CGPoint(x: maxX + 1.5, y: base + h * 0.5))
                // 底边：贴着窗口上沿，中间稍微往下压一点
                path.addQuadCurve(to: CGPoint(x: minX + 1, y: base - drape),
                                  control: CGPoint(x: (minX + maxX) / 2, y: base - 0.5))
                path.closeSubpath()
            }
        }
        return path
    }

    /// 脚印：雪面上一个个浅浅的小坑，越来越浅（被新雪填平）
    func printPath(origin: CGPoint) -> CGPath {
        let path = CGMutablePath()
        for print in prints {
            guard let cap = caps[print.windowID], cap.depth > 0.15 else { continue }
            let x = cap.frame.minX + print.dx
            guard let seg = cap.segments.first(where: { $0.contains(x: x, margin: 3) }) else { continue }
            let h = Self.capHeight(depth: cap.depth)
            let fill = pow(max(0, 1 - print.age / Self.printLife), 0.7)
            let w = 6.5 * print.size * fill, ph = 2.4 * print.size * fill
            guard w > 0.8 else { continue }
            let center = CGPoint(x: x - origin.x, y: seg.y - origin.y + h * 0.6)
            path.addEllipse(in: CGRect(x: center.x - w / 2, y: center.y - ph / 2, width: w, height: ph))
        }
        return path
    }

    /// 飞着的雪块：一个个小圆，快消失时缩小
    func clumpPath(origin: CGPoint) -> CGPath {
        let path = CGMutablePath()
        for clump in clumps {
            let r = clump.size * min(1, (clump.life - clump.age) / 0.35 + 0.2)
            guard r > 0.3 else { continue }
            let center = CGPoint(x: clump.pos.x - origin.x, y: clump.pos.y - origin.y)
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        return path
    }
}
