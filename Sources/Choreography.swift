import CoreGraphics
import Foundation

/// 叠加在基础姿态上的偏移。导演只产出它，CatPhysics 负责把它揉进各个弹簧目标里。
struct PoseOverlay {
    var bodyShiftX: CGFloat = 0
    var bodyTilt: CGFloat = 0
    /// 正值 = 压扁（蹲），负值 = 拉长（伸）
    var squash: CGFloat = 0
    var headOffsetY: CGFloat = 0
    var headTilt: CGFloat = 0
    var headYaw: CGFloat = 0
    var headPitch: CGFloat = 0
    /// 非 nil 时覆盖爪子目标（画布坐标）；权重 0..1 表示从默认位置往这里拉多少，用于淡入淡出
    var leftPaw: CGPoint?
    var rightPaw: CGPoint?
    var leftPawWeight: CGFloat = 1
    var rightPawWeight: CGFloat = 1
    var earFold: CGFloat = 0
    /// 0..1 张嘴（唱歌 / 打哈欠）
    var mouthOpen: CGFloat = 0
    /// 尾巴摆幅倍数增量
    var tailBoost: CGFloat = 0
    /// 0..1 额外的闭眼程度（> 0.6 时画成弯弯的笑眼）
    var eyeClosure: CGFloat = 0
    /// 是否接管视线（转头看尾巴、东张西望）
    var overridesGaze = false
    /// 爪子按键时点亮的键
    var pressedKey: PhysicalKey?

    static let none = PoseOverlay()

    /// 进出舞蹈时按比例淡入；爪子按权重从默认位置平滑拉过去，不会突然跳
    func scaled(by k: CGFloat) -> PoseOverlay {
        var p = self
        p.bodyShiftX *= k; p.bodyTilt *= k; p.squash *= k
        p.headOffsetY *= k; p.headTilt *= k; p.headYaw *= k; p.headPitch *= k
        p.earFold *= k; p.mouthOpen *= k; p.tailBoost *= k; p.eyeClosure *= k
        p.leftPawWeight *= k; p.rightPawWeight *= k
        if k < 0.5 { p.pressedKey = nil }
        return p
    }

    /// 两个姿态之间插值（换舞步时交叉淡化）。只有一方有爪子覆盖时，用权重淡入/淡出
    static func blend(_ a: PoseOverlay, _ b: PoseOverlay, _ t: CGFloat) -> PoseOverlay {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        func mixPaw(_ pa: CGPoint?, _ wa: CGFloat, _ pb: CGPoint?, _ wb: CGFloat) -> (CGPoint?, CGFloat) {
            switch (pa, pb) {
            case let (a?, b?): return (CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y)), mix(wa, wb))
            case let (a?, nil): return (a, wa * (1 - t))
            case let (nil, b?): return (b, wb * t)
            default: return (nil, 1)
            }
        }
        var p = PoseOverlay()
        p.bodyShiftX = mix(a.bodyShiftX, b.bodyShiftX); p.bodyTilt = mix(a.bodyTilt, b.bodyTilt)
        p.squash = mix(a.squash, b.squash); p.headOffsetY = mix(a.headOffsetY, b.headOffsetY)
        p.headTilt = mix(a.headTilt, b.headTilt); p.headYaw = mix(a.headYaw, b.headYaw)
        p.headPitch = mix(a.headPitch, b.headPitch); p.earFold = mix(a.earFold, b.earFold)
        p.mouthOpen = mix(a.mouthOpen, b.mouthOpen); p.tailBoost = mix(a.tailBoost, b.tailBoost)
        p.eyeClosure = mix(a.eyeClosure, b.eyeClosure)
        (p.leftPaw, p.leftPawWeight) = mixPaw(a.leftPaw, a.leftPawWeight, b.leftPaw, b.leftPawWeight)
        (p.rightPaw, p.rightPawWeight) = mixPaw(a.rightPaw, a.rightPawWeight, b.rightPaw, b.rightPawWeight)
        p.pressedKey = t < 0.5 ? a.pressedKey : b.pressedKey
        return p
    }
}

// MARK: - Dance

enum DanceMove: String, CaseIterable {
    case headBob = "点头"
    case sway = "左右摇摆"
    case raiseTheRoof = "举爪蹦迪"
    case bounce = "原地弹跳"
    case conductor = "指挥家"
    case shimmy = "抖肩"
    case headbang = "甩头"
    // 舒缓
    case gentleSway = "轻轻摇摆"
    case dreamyCircle = "梦游画圈"
    case slowNod = "慢慢点头"
    case concertWave = "演唱会挥手"
    case rocking = "摇椅"

    /// 冲击曲线的舞步比正弦曲线更接近阶跃，弹簧追上它要更久：在通用提前量之外再提前这么多秒，峰值才正好落在拍点上
    /// （用跳舞时的弹簧参数实测：通用 50ms + 额外 50ms → 峰值误差 0ms）
    var extraSpringLead: CGFloat { isCalm ? 0 : 0.05 }

    var isCalm: Bool {
        switch self {
        case .gentleSway, .dreamyCircle, .slowNod, .concertWave, .rocking: return true
        default: return false
        }
    }
}

/// 卡点曲线。正弦曲线在拍点那一刻速度为零、动作最软，看不出"哪一下是拍"；
/// 这里的曲线把大部分位移集中在拍点前很短的一段里，拍点上急停到位，之后慢慢回去——弹簧再带一点过冲，就是"卡点"的那一下。
/// local = 拍内进度 0..1（0 = 刚好在拍点上）
enum BeatShape {
    /// 冲击：拍点上为 1，之后慢慢回落到 0；下一拍前 attack 拍内加速冲回 1
    static func hit(_ local: CGFloat, attack: CGFloat = 0.14) -> CGFloat {
        let release = 1 - attack
        if local < release { return pow(1 - local / release, 2.2) }
        let t = (local - release) / attack
        return t * t
    }

    /// 两侧切换（偶数拍在 +1 一侧、奇数拍在 -1 一侧）：大部分时间停在一侧、微微回收，
    /// 下一拍前 attack 拍内加速甩到另一侧，拍点上到位
    static func swing(_ beatFloat: CGFloat, attack: CGFloat) -> CGFloat {
        let beat = beatFloat.rounded(.down)
        let local = beatFloat - beat
        let side: CGFloat = Int(beat).isMultiple(of: 2) ? 1 : -1
        let release = 1 - attack
        if local < release { return side * (1 - 0.12 * local / release) }
        let t = (local - release) / attack
        let from = side * 0.88
        return from + (-side - from) * t * t
    }

    /// 抬起再砸下：拍点后抬起（0 = 落着，1 = 抬到最高），停一会儿，下一拍前加速落下，拍点上砸到底
    static func liftSlam(_ local: CGFloat, attack: CGFloat = 0.16) -> CGFloat {
        let release = 1 - attack
        if local < 0.4 { let t = local / 0.4; return 1 - (1 - t) * (1 - t) }
        if local < release { return 1 }
        let t = (local - release) / attack
        return 1 - t * t
    }

    /// 两只爪子轮流：even = true 的那只在偶数拍上冲到位，另一只在奇数拍。返回这一只当前的冲击值
    static func alternatingHit(_ beatFloat: CGFloat, even: Bool, attack: CGFloat) -> CGFloat {
        let beat = beatFloat.rounded(.down)
        let local = beatFloat - beat
        let release = 1 - attack
        // 回落阶段属于刚过去的这一拍，冲刺阶段属于马上要到的下一拍
        let owner = local < release ? Int(beat) : Int(beat) + 1
        guard owner.isMultiple(of: 2) == even else { return 0 }
        return hit(local, attack: attack)
    }

    /// 小节里的重拍加重：第 1 拍最重，第 3 拍次之。downbeat = 小节第一拍的拍号余数；nil = 还不知道，不加重
    static func accent(beat: Int, downbeat: Int?) -> CGFloat {
        guard let downbeat else { return 1 }
        switch ((beat - downbeat) % 4 + 4) % 4 {
        case 0: return 1.2
        case 2: return 1.08
        default: return 0.95
        }
    }
}

/// 跟着节拍编舞：每 8 拍换一个舞步；能量低时动作收敛，高潮时更夸张。
///
/// 时序约定（beatPhase = k·2π 就是第 k 拍）：每个舞步的"重音"——最低点、摆到最远、爪子落桌、举到最高、
/// 指挥落点——都落在整拍上；拍与拍之间是过渡。两拍/四拍一循环的舞步，重音落在其中的某几拍上。
struct DanceDirector {
    private(set) var move: DanceMove = .headBob
    private var moveStartBeat = 0
    /// 换舞步时的上一个舞步及切换时的相位，用 1 拍交叉淡化（重音在整拍上，正好是切换点，硬切会跳）
    private var previous: (move: DanceMove, phase: CGFloat)?
    private var rng = SystemRandomNumberGenerator()
    private let beatsPerMove = 8

    /// - Parameters:
    ///   - beatPhase: 累计节拍相位（每拍 2π），已含弹簧提前量
    ///   - headLead: 头部转动/俯仰额外提前的相位（这两个弹簧比身体更"肉"）
    ///   - energy: 0..1 音乐能量（响度）
    ///   - kick: 0..1 刚检测到、且落在拍上的鼓点冲击，衰减中
    ///   - seatX: 当前坐姿锚点 x（含身体位移）
    ///   - arousal: 0..1 歌曲能量感（舒缓 ↔ 激烈），决定从哪组舞步里挑
    ///   - rhythm: 0..1 节奏强度（鼓点网格有多清晰）
    ///   - downbeat: 小节第一拍的拍号余数（0..3）；nil = 还没认出来。换舞步对齐到小节开头，重拍加重
    ///   - steady: 速度稳不稳。速度乱跳时只跳平滑的舒缓舞步（连拍子都没有，有节奏的舞步只会乱点头）
    ///   - snap: 0..1 相位准不准决定的动作软硬（见 evaluate）。准 → 冲击曲线卡点；不准 → 平滑曲线，误差不显眼
    mutating func pose(beatPhase: CGFloat, headLead: CGFloat = 0, energy: CGFloat, kick: CGFloat, seatX: CGFloat,
                       arousal: CGFloat = 0.6, rhythm: CGFloat = 0.5, downbeat: Int? = nil,
                       bpm: CGFloat = 120, steady: Bool = true, snap: CGFloat = 1) -> PoseOverlay {
        let beat = Int(beatPhase / (2 * .pi))
        // 认出小节后只在小节第一拍换舞步（像真人跳舞一样跟着乐句走）；没认出来就照旧每 8 拍换
        let barStart = downbeat.map { ((beat - $0) % 4 + 4) % 4 == 0 } ?? true
        // 情绪明显变了（安静段落 ↔ 副歌），不用等满 8 拍就换一组舞步
        let strongBeat = Self.isStrongBeat(rhythm: rhythm, arousal: arousal)
        let moodMismatch = steady
            ? (arousal < 0.3 && !move.isCalm && !strongBeat)
                || ((arousal > 0.7 || strongBeat) && (move.isCalm || (strongBeat && move == .sway)))
            : !move.isCalm
        // 相位校正可能让拍号回退一格，不当作"重新开始"；明显回退（切歌重置）才换舞步。
        // 拍子丢了要马上收成柔和舞步，不等小节开头
        if (beat - moveStartBeat >= beatsPerMove && barStart) || beat < moveStartBeat - 1
            || (moodMismatch && (!steady || (beat != moveStartBeat && barStart))) {
            previous = (move, beatPhase)
            moveStartBeat = beat
            move = nextMove(energy: energy, arousal: arousal, rhythm: rhythm, steady: steady)
        }
        func full(_ m: DanceMove) -> PoseOverlay {
            // 额外提前量只给冲击曲线；软的正弦曲线用通用提前量就够了
            let phase = beatPhase + m.extraSpringLead * snap * bpm / 60 * 2 * .pi
            var p = Self.evaluate(m, beatPhase: phase, energy: energy, kick: kick, seatX: seatX, downbeat: downbeat, snap: snap)
            if headLead != 0 {
                let head = Self.evaluate(m, beatPhase: phase + headLead, energy: energy, kick: kick, seatX: seatX,
                                         downbeat: downbeat, snap: snap)
                p.headYaw = head.headYaw
                p.headPitch = head.headPitch
            }
            return p
        }
        var result = full(move)
        if let prev = previous {
            let t = (beatPhase - prev.phase) / (2 * .pi)               // 切换后过了几拍
            if t >= 1 || t < 0 {
                previous = nil
            } else {
                let eased = t * t * (3 - 2 * t)
                result = PoseOverlay.blend(full(prev.move), result, eased)
            }
        }
        return result
    }

    /// 纯函数：某个舞步在某个相位的姿态
    /// - Parameter snap: 0..1 动作有多"硬"。1 = 冲击曲线卡点；0 = 平滑的正弦曲线。
    ///   相位抖动大时用软的：踩在拍附近、但不把误差放大
    static func evaluate(_ move: DanceMove, beatPhase phi: CGFloat, energy: CGFloat, kick: CGFloat, seatX: CGFloat,
                         downbeat: Int? = nil, snap: CGFloat = 1) -> PoseOverlay {
        let beatFloat = phi / (2 * .pi)
        let beatIndex = Int(beatFloat.rounded(.down))
        let local = beatFloat - beatFloat.rounded(.down)            // 0..1 拍内进度
        let snap = max(0, min(1, snap))
        /// soft → hard 按 snap 插值
        func blend(_ soft: CGFloat, _ hard: CGFloat) -> CGFloat { soft + (hard - soft) * snap }
        // 重拍加重：回落阶段算刚过去的那一拍，冲刺阶段算马上要到的那一拍
        let accent = BeatShape.accent(beat: local < 0.86 ? beatIndex : beatIndex + 1, downbeat: downbeat)
        // 拍点冲击：拍点上为 1（最低/最远），之后回落，下一拍前加速冲回来。
        // 冲刺很短，弹簧追不满（实测只到正弦曲线振幅的 77%），乘 1.3 补回原来的幅度
        let softDip = (1 + cos(local * 2 * .pi)) / 2
        let dip = blend(softDip, BeatShape.hit(local) * 1.3) * accent + kick * 0.2
        let e = 0.55 + energy * 0.65
        // 两侧切换：偶数拍在 +1、奇数拍在 -1，拍点前甩过去（软的时候是两拍一个来回的余弦）
        let softSwing = cos(phi * 0.5)
        let swing = blend(softSwing, BeatShape.swing(beatFloat, attack: 0.3))
        let shoulderY: CGFloat = 178
        let restY: CGFloat = 235

        var p = PoseOverlay()
        p.eyeClosure = 0.85
        switch move {
        case .headBob:
            p.headOffsetY = dip * 8 * e
            p.headPitch = dip * 0.25 * e
            p.headTilt = swing * 0.1 * e
            // 两只爪子轮流：拍后抬起、拍上砸回桌面（左爪砸在奇数拍，右爪砸在偶数拍）
            let lift = BeatShape.liftSlam(local)
            // 整个拍间抬起的都是下一拍要砸下的那只
            let leftTurn = !(beatIndex + 1).isMultiple(of: 2)
            let half = sin(phi * 0.5)                                 // 软：两拍一个来回的半正弦
            p.leftPaw = CGPoint(x: CatPhysics.leftPawRest.x, y: restY - 7 * blend(max(0, -half), leftTurn ? lift : 0))
            p.rightPaw = CGPoint(x: CatPhysics.rightPawRest.x, y: restY - 7 * blend(max(0, half), leftTurn ? 0 : lift))
            p.tailBoost = 0.4
        case .sway:
            // 摇摆要有律动感：甩过去的时间长一些（半拍），不像点头那样硬
            let swing = blend(softSwing, BeatShape.swing(beatFloat, attack: 0.5))
            p.bodyShiftX = swing * 11 * e
            p.bodyTilt = swing * 0.09 * e
            p.headTilt = -swing * 0.12 * e
            p.headOffsetY = dip * 2.5
            p.tailBoost = 0.8
        case .raiseTheRoof:
            // 两只爪子轮流往上顶：偶数拍左爪冲到最高，奇数拍右爪；拍点前加速顶上去、拍点上到顶
            // 爪子要从桌面举过头顶（约 110pt），冲刺给 0.35 拍，路程太长时弹簧跟不上
            let leftUp = blend(pow(max(0, softSwing), 1.5),
                               BeatShape.alternatingHit(beatFloat, even: true, attack: 0.35) * min(1.1, accent))
            let rightUp = blend(pow(max(0, -softSwing), 1.5),
                                BeatShape.alternatingHit(beatFloat, even: false, attack: 0.35) * min(1.1, accent))
            let topY = shoulderY - 44 * e
            p.leftPaw = CGPoint(x: CatPhysics.leftPawRest.x + (seatX - 38 - CatPhysics.leftPawRest.x) * leftUp,
                                y: restY + (topY - restY) * leftUp)
            p.rightPaw = CGPoint(x: CatPhysics.rightPawRest.x + (seatX + 40 - CatPhysics.rightPawRest.x) * rightUp,
                                 y: restY + (topY - restY) * rightUp)
            p.headOffsetY = dip * 3
            p.headTilt = -swing * 0.1 * e
            p.mouthOpen = dip * 0.8
            p.eyeClosure = 0.7
            p.tailBoost = 1.0
        case .bounce:
            p.squash = dip * 0.13 * e
            p.headOffsetY = dip * 11 * e
            p.earFold = dip * 0.4
            // 拍间弹起、拍上砸下
            let lift = blend(1 - softDip, BeatShape.liftSlam(local))
            p.leftPaw = CGPoint(x: CatPhysics.leftPawRest.x - 2, y: restY - lift * 10)
            p.rightPaw = CGPoint(x: CatPhysics.rightPawRest.x + 2, y: restY - lift * 10)
            p.tailBoost = 1.2
        case .conductor:
            // 右爪画 8 字指挥：每拍的最低点（指挥的"落点"）正好在整拍上，头跟着爪子转
            let arc = phi * 0.5 + .pi / 4
            // 竖直方向用冲击曲线：拍点上"啪"地落到最低，之后慢慢提起
            p.rightPaw = CGPoint(x: seatX + 36 + cos(arc) * 14,
                                 y: blend(150 + cos(phi) * 10, 140 + BeatShape.hit(local, attack: 0.2) * 20))
            p.headYaw = cos(arc) * 0.3
            p.headTilt = sin(arc) * 0.08
            p.headOffsetY = dip * 2
            p.mouthOpen = dip * 0.5
            p.tailBoost = 0.5
        case .shimmy:
            // 每拍抖一个来回（整拍和半拍各到一侧）：4Hz 的半拍抖动弹簧跟不上，幅度会被吃掉一半
            // 方一点的来回：两端停得久、中间过得快，抖得更利落
            let shake = blend(cos(phi), tanh(2.2 * cos(phi)) / tanh(2.2))
            p.bodyShiftX = shake * 8 * e
            p.bodyTilt = shake * 0.05 * e
            p.headTilt = -shake * 0.06
            p.earFold = (0.08 + shake * 0.17) * e
            p.headOffsetY = dip * 2
            p.tailBoost = 1.4
        // ---- 舒缓舞步：平滑、两拍/四拍一循环，摆到最远处落在整拍上 ----
        case .gentleSway:
            let slow = cos(phi * 0.25)                               // 四拍一个来回，第 0、2 拍摆到最远
            let calm = 0.8 + energy * 0.4
            p.bodyShiftX = slow * 7 * calm
            p.bodyTilt = slow * 0.05 * calm
            p.headTilt = -slow * 0.1 * calm
            p.earFold = 0.2
            p.eyeClosure = 0.95
            p.tailBoost = 0.3
        case .dreamyCircle:
            let a = phi * 0.25
            p.headYaw = cos(a) * 0.28
            p.headPitch = sin(a) * 0.18
            p.headTilt = cos(a) * 0.07
            p.bodyShiftX = cos(a) * 3
            p.earFold = 0.15
            p.eyeClosure = 0.95
            p.tailBoost = 0.2
        case .slowNod:
            let nod = (1 - cos(phi * 0.5)) / 2                       // 两拍点一次，奇数拍点到最低
            p.headOffsetY = nod * 4.5
            p.headPitch = nod * 0.28
            p.headTilt = sin(phi * 0.25) * 0.05
            p.earFold = 0.15 + nod * 0.1
            p.eyeClosure = 0.9
            p.tailBoost = 0.1
        case .concertWave:
            // 像在演唱会举着荧光棒，慢慢左右挥，第 1、3 拍挥到最远
            let wave = sin(phi * 0.25)
            p.rightPaw = CGPoint(x: seatX + 32 + wave * 16, y: 148 + abs(wave) * 6)
            p.headTilt = wave * 0.08
            p.headYaw = wave * 0.15
            p.bodyShiftX = wave * 3
            p.earFold = 0.1
            p.eyeClosure = 0.9
            p.tailBoost = 0.3
        case .rocking:
            let rock = cos(phi * 0.5)                                // 两拍一个来回，像摇椅；整拍摇到最远
            let breathe = (1 - cos(phi * 0.25)) / 2
            p.bodyTilt = rock * 0.07
            p.bodyShiftX = rock * 4
            p.headTilt = -rock * 0.05
            p.squash = breathe * 0.03
            p.earFold = 0.2
            p.eyeClosure = 0.95
            p.tailBoost = 0.2
        case .headbang:
            p.headOffsetY = dip * 14 * e
            p.headPitch = dip * 1.0 * e
            p.headTilt = swing * 0.12 * e
            p.earFold = 0.3 + dip * 0.35
            p.squash = dip * 0.06
            p.eyeClosure = 1
            p.tailBoost = 1.6
        }
        return p
    }

    /// 高能量时才会出甩头；不重复上一个舞步
    /// 舒缓歌只挑舒缓舞步，激烈的只挑蹦迪舞步，中间的混着来；甩头只给真正的高潮
    /// "强节奏"= 鼓点网格清晰，且不是慢抒情（规整弹奏的慢歌节奏也很"清晰"，但应该跳舒缓舞步）
    static func isStrongBeat(rhythm: CGFloat, arousal: CGFloat) -> Bool {
        rhythm > 0.5 && arousal >= 0.35
    }

    /// 节奏强（鼓点清晰）时：只用蹦迪舞步，点头权重最高且可以连着来，左右摇摆压低；
    /// 节奏弱时才按能量感在舒缓/蹦迪之间选
    private mutating func nextMove(energy: CGFloat, arousal: CGFloat, rhythm: CGFloat, steady: Bool = true) -> DanceMove {
        let strongBeat = Self.isStrongBeat(rhythm: rhythm, arousal: arousal)
        var weights: [(DanceMove, Double)] = []
        for candidate in DanceMove.allCases {
            if candidate == .headbang && (energy < 0.7 || arousal < 0.65) { continue }
            if !steady {
                // 还在找拍子：只跳平滑的舒缓舞步；歌比较嗨时偏向两拍一循环的摇椅和慢点头，不至于显得太困
                guard candidate.isCalm else { continue }
                let lively = arousal > 0.5 && (candidate == .rocking || candidate == .slowNod)
                let w: Double = candidate == move ? 0 : (lively ? 2.5 : 1)
                if w > 0 { weights.append((candidate, w)) }
                continue
            }
            if strongBeat {
                // 强鼓点下身体左右晃（不论幅度）都显得软，只留点头/弹跳/甩头/举爪/指挥/抖肩
                guard !candidate.isCalm, candidate != .sway else { continue }
            } else if arousal < 0.38 {
                guard candidate.isCalm else { continue }
            } else if arousal > 0.62 {
                guard !candidate.isCalm else { continue }
            }
            var w: Double
            switch candidate {
            case .headBob: w = strongBeat ? 5 : 2
            case .bounce: w = strongBeat ? 2.5 : 1.5
            case .headbang: w = 2
            case .raiseTheRoof: w = 1.5
            case .conductor: w = 1
            case .shimmy: w = 1
            case .sway: w = 1.2
            default: w = 1
            }
            // 不重复上一个舞步；点头在强节奏下允许连着来（权重减半）
            if candidate == move { w = (candidate == .headBob && strongBeat) ? w * 0.5 : 0 }
            if w > 0 { weights.append((candidate, w)) }
        }
        let total = weights.reduce(0) { $0 + $1.1 }
        guard total > 0 else {
            if !steady { return move == .rocking ? .gentleSway : .rocking }
            return arousal < 0.5 && !strongBeat ? .gentleSway : .headBob
        }
        var pick = Double.random(in: 0..<total, using: &rng)
        for (candidate, w) in weights {
            if pick < w { return candidate }
            pick -= w
        }
        return weights.last?.0 ?? .headBob
    }

    /// 预览/测试用：直接指定舞步
    mutating func force(_ move: DanceMove, atBeat beat: Int) {
        self.move = move
        moveStartBeat = beat
        previous = nil
    }
}

// MARK: - Idle

enum IdleAction: String, CaseIterable {
    case yawn = "打哈欠"
    case stretch = "伸懒腰"
    case lookAround = "东张西望"
    case knead = "踩奶"
    case lickPaw = "舔爪子"
    case lookAtTail = "看尾巴"
    case slowBlink = "慢眨眼（猫咪的爱）"
    case patMouse = "拍拍小老鼠"

    var duration: CGFloat {
        switch self {
        case .yawn: return 2.4
        case .stretch: return 2.8
        case .lookAround: return 3.4
        case .knead: return 3.6
        case .lickPaw: return 2.8
        case .lookAtTail: return 2.6
        case .slowBlink: return 2.2
        case .patMouse: return 2.2
        }
    }
}

/// 空闲时每隔 7~15 秒随机做一个小动作，避免干坐着。
struct IdleDirector {
    private(set) var action: IdleAction?
    private(set) var age: CGFloat = 0
    private var cooldown: CGFloat = 6
    private var last: IdleAction?
    private var rng = SystemRandomNumberGenerator()

    /// 返回本帧要叠加的姿态；`allowed` 为 false 时立刻收手并重新计时
    /// - preferYawn: 深夜时更爱打哈欠
    mutating func update(dt: CGFloat, allowed: Bool, seatX: CGFloat, preferYawn: Bool = false) -> (overlay: PoseOverlay, started: IdleAction?) {
        guard allowed else {
            action = nil
            cooldown = max(cooldown, 4)
            return (.none, nil)
        }
        var started: IdleAction?
        if let current = action {
            age += dt
            if age >= current.duration {
                action = nil
                last = current
                cooldown = CGFloat.random(in: 7...15, using: &rng)
            }
        } else {
            cooldown -= dt
            if cooldown <= 0 {
                let pool = IdleAction.allCases.filter { $0 != last }
                if preferYawn && last != .yawn && Double.random(in: 0..<1, using: &rng) < 0.45 {
                    action = .yawn
                } else {
                    action = pool.randomElement(using: &rng)
                }
                age = 0
                started = action
            }
        }
        guard let current = action else { return (.none, started) }
        return (overlay(for: current, age: age, seatX: seatX), started)
    }

    /// 预览/测试用：直接指定动作和进度
    mutating func force(_ action: IdleAction, age: CGFloat) {
        self.action = action
        self.age = age
    }

    func overlay(for action: IdleAction, age: CGFloat, seatX: CGFloat) -> PoseOverlay {
        let t = age / action.duration                    // 0..1
        let env = sin(min(1, max(0, t)) * .pi)           // 进出平滑包络
        var p = PoseOverlay()
        switch action {
        case .yawn:
            // 先抬头张大嘴，最后咂一下嘴
            let open = max(0, sin(min(1, t * 1.25) * .pi))
            p.mouthOpen = open
            p.headPitch = -0.45 * open
            p.headOffsetY = -3 * open
            p.squash = -0.04 * open
            p.earFold = 0.35 * open
            p.eyeClosure = 0.9 * open
            p.overridesGaze = true
        case .stretch:
            // 前爪往前推到键盘远端，身体压低，眯眼享受
            p.leftPaw = CGPoint(x: seatX - 34, y: 264)
            p.rightPaw = CGPoint(x: seatX + 32, y: 266)
            p.squash = 0.08 * env
            p.headOffsetY = 9 * env
            p.headPitch = 0.3 * env
            p.eyeClosure = 0.95 * env
            p.earFold = 0.25 * env
            p.tailBoost = -0.5 * env
            p.overridesGaze = true
        case .lookAround:
            p.headYaw = sin(t * 2 * .pi) * 0.85
            p.headPitch = -0.15 + cos(t * 2 * .pi) * 0.1
            p.earFold = -0.15 * env
            p.overridesGaze = true
        case .knead:
            // 左右爪轮流往下踩键盘（踩奶），踩到的键会亮
            let step = Int(t * 10)
            let leftDown = step % 2 == 0
            let pressDepth = sin((t * 10).truncatingRemainder(dividingBy: 1) * .pi)
            // 猫面朝键盘：画面左侧的爪子（猫的右手）踩键盘右手区，反之亦然
            let viewerLeftKeys: [PhysicalKey] = [.j, .h, .k, .j, .h]
            let viewerRightKeys: [PhysicalKey] = [.f, .d, .g, .f, .d]
            let leftKey = viewerLeftKeys[(step / 2) % viewerLeftKeys.count]
            let rightKey = viewerRightKeys[(step / 2) % viewerRightKeys.count]
            let leftPt = KeyboardLayout.canvasPoint(for: leftKey)
            let rightPt = KeyboardLayout.canvasPoint(for: rightKey)
            // 抬起的爪子离键 7pt，踩下的贴着键
            p.leftPaw = CGPoint(x: leftPt.x, y: leftPt.y - (leftDown ? 7 * (1 - pressDepth) : 7))
            p.rightPaw = CGPoint(x: rightPt.x, y: rightPt.y - (leftDown ? 7 : 7 * (1 - pressDepth)))
            if pressDepth > 0.7 { p.pressedKey = leftDown ? leftKey : rightKey }
            p.eyeClosure = 0.6 * env
            p.headOffsetY = 3 * env
            p.tailBoost = 0.3
        case .lickPaw:
            p.rightPaw = CGPoint(x: seatX + 18 + sin(age * 9) * 3, y: 136 + cos(age * 9) * 4)
            p.headTilt = 0.16 * env
            p.headPitch = 0.25 * env
            p.mouthOpen = max(0, sin(age * 9)) * 0.35 * env
            p.eyeClosure = 0.95 * env
        case .lookAtTail:
            p.headYaw = 0.9 * env
            p.headPitch = 0.45 * env
            p.headTilt = 0.12 * env
            p.tailBoost = 1.6 * env
            p.earFold = -0.2 * env
            p.overridesGaze = true
        case .slowBlink:
            // 慢慢闭眼再睁开：猫咪表达信任
            p.eyeClosure = env
            p.headTilt = 0.08 * env
            p.earFold = 0.2 * env
            p.overridesGaze = true
        case .patMouse:
            // 左爪拍两下小老鼠
            let tap = max(0, sin(t * 4 * .pi))
            p.leftPaw = CGPoint(x: CatPhysics.mouseBaseCenter.x + 2, y: CatPhysics.mouseBaseCenter.y - 3 - tap * 10)
            p.headYaw = -0.6 * env
            p.headPitch = 0.55 * env
            p.overridesGaze = true
        }
        return p
    }
}
