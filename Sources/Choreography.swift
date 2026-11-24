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
    /// 非 nil 时覆盖爪子目标（画布坐标）
    var leftPaw: CGPoint?
    var rightPaw: CGPoint?
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

    /// 进出舞蹈时按比例淡入；爪子不能"半覆盖"，过半才接管
    func scaled(by k: CGFloat) -> PoseOverlay {
        var p = self
        p.bodyShiftX *= k; p.bodyTilt *= k; p.squash *= k
        p.headOffsetY *= k; p.headTilt *= k; p.headYaw *= k; p.headPitch *= k
        p.earFold *= k; p.mouthOpen *= k; p.tailBoost *= k; p.eyeClosure *= k
        if k < 0.5 { p.leftPaw = nil; p.rightPaw = nil; p.pressedKey = nil }
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

    var isCalm: Bool {
        switch self {
        case .gentleSway, .dreamyCircle, .slowNod, .concertWave, .rocking: return true
        default: return false
        }
    }
}

/// 跟着节拍编舞：每 8 拍换一个舞步；能量低时动作收敛，高潮时更夸张。
struct DanceDirector {
    private(set) var move: DanceMove = .headBob
    private var moveStartBeat = 0
    private var rng = SystemRandomNumberGenerator()
    private let beatsPerMove = 8

    /// - Parameters:
    ///   - beatPhase: 累计节拍相位（每拍 2π）
    ///   - energy: 0..1 音乐能量（响度）
    ///   - kick: 0..1 刚检测到真实鼓点的冲击，衰减中
    ///   - seat: 当前坐姿锚点 x（含身体位移）
    ///   - arousal: 0..1 歌曲能量感（舒缓 ↔ 激烈），决定从哪组舞步里挑
    mutating func pose(beatPhase: CGFloat, energy: CGFloat, kick: CGFloat, seatX: CGFloat,
                       arousal: CGFloat = 0.6) -> PoseOverlay {
        let beat = Int(beatPhase / (2 * .pi))
        // 情绪明显变了（安静段落 ↔ 副歌），不用等满 8 拍就换一组舞步
        let moodMismatch = (arousal < 0.3 && !move.isCalm) || (arousal > 0.7 && move.isCalm)
        // 相位校正可能让拍号回退一格，不当作"重新开始"；明显回退（切歌重置）才换舞步
        if beat - moveStartBeat >= beatsPerMove || beat < moveStartBeat - 1 || (moodMismatch && beat != moveStartBeat) {
            moveStartBeat = beat
            move = nextMove(energy: energy, arousal: arousal)
        }
        let local = (beatPhase / (2 * .pi)) - CGFloat(beat)        // 0..1 拍内进度
        let pulse = pow(max(0, 1 - local * 2.4), 2) + kick * 0.35  // 每拍开头的冲击
        // 连续的"拍点下沉"：拍点最低、拍间回弹。比尖脉冲更适合驱动弹簧，幅度不会被抹平
        let dip = (1 + cos(local * 2 * .pi)) / 2 + kick * 0.2
        let e = 0.55 + energy * 0.65
        let even = beat % 2 == 0
        let swing = sin(beatPhase * 0.5)                             // 两拍一个来回
        let shoulderY: CGFloat = 178
        let restY: CGFloat = 235

        var p = PoseOverlay()
        p.eyeClosure = 0.85
        switch move {
        case .headBob:
            p.headOffsetY = dip * 8 * e
            p.headPitch = dip * 0.25 * e
            p.headTilt = swing * 0.1 * e
            p.rightPaw = CGPoint(x: CatPhysics.rightPawRest.x, y: restY - (even ? dip * 7 : 0))
            p.leftPaw = CGPoint(x: CatPhysics.leftPawRest.x, y: restY - (even ? 0 : dip * 7))
            p.tailBoost = 0.4
        case .sway:
            p.bodyShiftX = swing * 11 * e
            p.bodyTilt = swing * 0.09 * e
            p.headTilt = -swing * 0.12 * e
            p.headOffsetY = pulse * 2.5
            p.tailBoost = 0.8
        case .raiseTheRoof:
            // 两只爪子轮流往上顶，嘴巴跟着拍子张合"唱歌"
            let lift = 0.6 + pulse * 0.4
            let up = CGPoint(x: 0, y: shoulderY - 44 * lift * e)
            p.leftPaw = even ? CGPoint(x: seatX - 38, y: up.y) : CGPoint(x: CatPhysics.leftPawRest.x, y: restY)
            p.rightPaw = even ? CGPoint(x: CatPhysics.rightPawRest.x, y: restY) : CGPoint(x: seatX + 40, y: up.y)
            p.headOffsetY = pulse * 3
            p.headTilt = (even ? -1 : 1) * 0.1 * e
            p.mouthOpen = pulse * 0.9
            p.eyeClosure = 0.7
            p.tailBoost = 1.0
        case .bounce:
            p.squash = dip * 0.13 * e
            p.headOffsetY = dip * 11 * e
            p.earFold = dip * 0.4
            p.leftPaw = CGPoint(x: CatPhysics.leftPawRest.x - 2, y: restY - (1 - dip) * 10)
            p.rightPaw = CGPoint(x: CatPhysics.rightPawRest.x + 2, y: restY - (1 - dip) * 10)
            p.tailBoost = 1.2
        case .conductor:
            // 右爪画 8 字指挥，头跟着爪子转
            let figure = CGPoint(x: seatX + 36 + cos(beatPhase * 0.5) * 14, y: 150 + sin(beatPhase) * 10)
            p.rightPaw = figure
            p.headYaw = cos(beatPhase * 0.5) * 0.3
            p.headTilt = sin(beatPhase * 0.5) * 0.08
            p.headOffsetY = pulse * 2
            p.mouthOpen = pulse * 0.5
            p.tailBoost = 0.5
        case .shimmy:
            let fast = sin(beatPhase * 2) // 半拍一抖
            p.bodyShiftX = fast * 8 * e
            p.bodyTilt = fast * 0.05 * e
            p.headTilt = -fast * 0.06
            p.earFold = (fast > 0 ? 0.25 : -0.1) * e
            p.headOffsetY = pulse * 2
            p.tailBoost = 1.4
        // ---- 舒缓舞步：全部用平滑正弦、四拍或两拍一个周期，不跟鼓点冲击 ----
        case .gentleSway:
            let slow = sin(beatPhase * 0.25)                         // 四拍一个来回
            let calm = 0.8 + energy * 0.4
            p.bodyShiftX = slow * 7 * calm
            p.bodyTilt = slow * 0.05 * calm
            p.headTilt = -slow * 0.1 * calm
            p.earFold = 0.2
            p.eyeClosure = 0.95
            p.tailBoost = 0.3
        case .dreamyCircle:
            let a = beatPhase * 0.25
            p.headYaw = cos(a) * 0.28
            p.headPitch = sin(a) * 0.18
            p.headTilt = cos(a) * 0.07
            p.bodyShiftX = cos(a) * 3
            p.earFold = 0.15
            p.eyeClosure = 0.95
            p.tailBoost = 0.2
        case .slowNod:
            let nod = (1 - cos(beatPhase * 0.5)) / 2                 // 两拍点一次，进出都很柔
            p.headOffsetY = nod * 4.5
            p.headPitch = nod * 0.28
            p.headTilt = sin(beatPhase * 0.25) * 0.05
            p.earFold = 0.15 + nod * 0.1
            p.eyeClosure = 0.9
            p.tailBoost = 0.1
        case .concertWave:
            // 像在演唱会举着荧光棒，慢慢左右挥
            let wave = sin(beatPhase * 0.25)
            p.rightPaw = CGPoint(x: seatX + 32 + wave * 16, y: 148 + abs(wave) * 6)
            p.headTilt = wave * 0.08
            p.headYaw = wave * 0.15
            p.bodyShiftX = wave * 3
            p.earFold = 0.1
            p.eyeClosure = 0.9
            p.tailBoost = 0.3
        case .rocking:
            let rock = sin(beatPhase * 0.5)                          // 两拍一个来回，像摇椅
            let breathe = (1 - cos(beatPhase * 0.25)) / 2
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
    private mutating func nextMove(energy: CGFloat, arousal: CGFloat) -> DanceMove {
        let pool = DanceMove.allCases.filter { candidate in
            guard candidate != move else { return false }
            if candidate == .headbang && (energy < 0.7 || arousal < 0.7) { return false }
            if arousal < 0.38 { return candidate.isCalm }
            if arousal > 0.62 { return !candidate.isCalm }
            return true
        }
        return pool.randomElement(using: &rng) ?? (arousal < 0.5 ? .gentleSway : .headBob)
    }

    /// 预览/测试用：直接指定舞步
    mutating func force(_ move: DanceMove, atBeat beat: Int) {
        self.move = move
        moveStartBeat = beat
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
    mutating func update(dt: CGFloat, allowed: Bool, seatX: CGFloat) -> (overlay: PoseOverlay, started: IdleAction?) {
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
                action = pool.randomElement(using: &rng)
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
