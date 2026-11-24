import Foundation
import CoreGraphics
import AppKit
import os

/// 跳舞锁拍诊断：只含相位误差、BPM、舞步等统计量，标为 public 便于 `log show` 查看
private let danceLog = Logger(subsystem: "ai.today.coolcat", category: "dance")

// MARK: - Themes & Settings

enum KeyboardTheme: String, CaseIterable {
    case classicMilk = "经典奶白暖黄 (原版)"
    case midnightHacker = "暗夜极客黑"
    case retroCream = "复古奶油灰"
}

enum CatCoatTheme: String, CaseIterable {
    case classicBlack = "经典小黑猫 (原版)"
    case siamese = "挖煤暹罗猫"
    case shorthair = "美短（银虎斑加白）"
    case orangeWhite = "橘白猫"
}

enum EyeColorTheme: String, CaseIterable {
    case neonChartreuse = "经典荧光黄绿 (原版)"
    case siameseBlue = "暹罗宝石蓝 (暹罗标配)"
    case warmAmber = "琥珀金瞳"
    case iceCyan = "冰晶浅蓝"
    case softAmber = "柔和琥珀"
    case referenceHazel = "淡金青绿"

    static func saved(_ raw: String) -> Self {
        raw == "淡金青绿（参考图）" ? .referenceHazel : (Self(rawValue: raw) ?? .neonChartreuse)
    }

    var primaryColor: NSColor {
        switch self {
        case .neonChartreuse: return NSColor(calibratedRed: 0.79, green: 0.95, blue: 0.25, alpha: 1.0) // #C9F240
        case .siameseBlue:    return NSColor(calibratedRed: 0.69, green: 0.855, blue: 0.95, alpha: 1.0) // #B0DAF2 通透浅淡冰蓝
        case .warmAmber:      return NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.22, alpha: 1.0)
        case .iceCyan:        return NSColor(calibratedRed: 0.45, green: 0.92, blue: 0.96, alpha: 1.0)
        case .referenceHazel: return NSColor(calibratedRed: 218.0/255, green: 178.0/255, blue: 87.0/255, alpha: 1)
        case .softAmber: return NSColor(calibratedRed: 217.0/255, green: 173.0/255, blue: 85.0/255, alpha: 1)
        }
    }

    var glowColor: NSColor {
        switch self {
        case .neonChartreuse: return NSColor(calibratedRed: 0.77, green: 0.95, blue: 0.24, alpha: 0.85)
        case .siameseBlue:    return NSColor(calibratedRed: 0.68, green: 0.85, blue: 0.95, alpha: 0.80)
        case .warmAmber:      return NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.20, alpha: 0.85)
        case .iceCyan:        return NSColor(calibratedRed: 0.42, green: 0.90, blue: 0.98, alpha: 0.85)
        case .referenceHazel: return NSColor(calibratedRed: 218.0/255, green: 178.0/255, blue: 87.0/255, alpha: 0.85)
        case .softAmber: return NSColor(calibratedRed: 217.0/255, green: 173.0/255, blue: 85.0/255, alpha: 0.85)
        }
    }
}

final class CatSettings {
    static let shared = CatSettings()

    var showKeyBadges: Bool {
        didSet { UserDefaults.standard.set(showKeyBadges, forKey: "CoolCat.ShowKeyBadges") }
    }
    var showMouseBadges: Bool {
        didSet { UserDefaults.standard.set(showMouseBadges, forKey: "CoolCat.ShowMouseBadges") }
    }
    var showKeyLegends: Bool {
        didSet { UserDefaults.standard.set(showKeyLegends, forKey: "CoolCat.ShowKeyLegends") }
    }
    var footEasterEgg: Bool {
        didSet { UserDefaults.standard.set(footEasterEgg, forKey: "CoolCat.FootEasterEgg") }
    }
    var petInteraction: Bool {
        didSet { UserDefaults.standard.set(petInteraction, forKey: "CoolCat.PetInteraction") }
    }
    var fullClickThrough: Bool {
        didSet { UserDefaults.standard.set(fullClickThrough, forKey: "CoolCat.FullClickThrough") }
    }
    var fullScreenOverlay: Bool {
        didSet { UserDefaults.standard.set(fullScreenOverlay, forKey: "CoolCat.FullScreenOverlay") }
    }
    var scale: CGFloat {
        didSet { UserDefaults.standard.set(Double(scale), forKey: "CoolCat.Scale") }
    }
    var coatTheme: CatCoatTheme {
        didSet { UserDefaults.standard.set(coatTheme.rawValue, forKey: "CoolCat.CoatTheme") }
    }
    var keyboardTheme: KeyboardTheme {
        didSet { UserDefaults.standard.set(keyboardTheme.rawValue, forKey: "CoolCat.KeyboardTheme") }
    }
    var eyeTheme: EyeColorTheme {
        didSet { UserDefaults.standard.set(eyeTheme.rawValue, forKey: "CoolCat.EyeTheme") }
    }
    /// 听歌时戴耳机 + 跟节拍摇头
    var musicHeadphones: Bool {
        didSet { UserDefaults.standard.set(musicHeadphones, forKey: "CoolCat.MusicHeadphones") }
    }
    /// 非音乐 App（浏览器视频、游戏等）出声时也戴耳机
    var headphonesForAnyAudio: Bool {
        didSet { UserDefaults.standard.set(headphonesForAnyAudio, forKey: "CoolCat.HeadphonesForAnyAudio") }
    }
    /// 切歌时头顶冒出歌名气泡
    var showTrackBubble: Bool {
        didSet { UserDefaults.standard.set(showTrackBubble, forKey: "CoolCat.ShowTrackBubble") }
    }
    /// 听歌时猫身后的竖直频谱墙
    var musicVisualizer: Bool {
        didSet { UserDefaults.standard.set(musicVisualizer, forKey: "CoolCat.MusicVisualizer") }
    }
    /// 频谱/节拍跟随真实音频（需要「录制系统音频」授权）；关掉则用模拟节拍
    var realAudioAnalysis: Bool {
        didSet { UserDefaults.standard.set(realAudioAnalysis, forKey: "CoolCat.RealAudioAnalysis") }
    }
    /// 听歌且没在打字时跳舞
    var musicDance: Bool {
        didSet { UserDefaults.standard.set(musicDance, forKey: "CoolCat.MusicDance") }
    }
    /// 空闲时随机小动作（打哈欠、伸懒腰、踩奶……）
    var idleAnimations: Bool {
        didSet { UserDefaults.standard.set(idleAnimations, forKey: "CoolCat.IdleAnimations") }
    }
    /// 光标在小猫身边晃时盯上、蓄力、出爪拍
    var cursorPlay: Bool {
        didSet { UserDefaults.standard.set(cursorPlay, forKey: "CoolCat.CursorPlay") }
    }
    /// 亲密度解锁的装扮
    var accessory: CatAccessory {
        didSet { UserDefaults.standard.set(accessory.rawValue, forKey: "CoolCat.Accessory") }
    }
    /// 生活陪伴：深夜睡帽、早晨咖啡、低电量/插电、久坐喝水
    var lifeNight: Bool {
        didSet { UserDefaults.standard.set(lifeNight, forKey: "CoolCat.LifeNight") }
    }
    var lifeMorning: Bool {
        didSet { UserDefaults.standard.set(lifeMorning, forKey: "CoolCat.LifeMorning") }
    }
    var lifeBattery: Bool {
        didSet { UserDefaults.standard.set(lifeBattery, forKey: "CoolCat.LifeBattery") }
    }
    var lifeWorkBreak: Bool {
        didSet { UserDefaults.standard.set(lifeWorkBreak, forKey: "CoolCat.LifeWorkBreak") }
    }
    /// 键盘习惯小反应：⌫ 冒汗 / ⌘S 盖章 / 截图比耶 / KPM 破纪录戴皇冠
    var keyHabitReactions: Bool {
        didSet { UserDefaults.standard.set(keyHabitReactions, forKey: "CoolCat.KeyHabitReactions") }
    }
    /// 开会时戴耳麦、开摄像头时整理仪容
    var meetingMode: Bool {
        didSet { UserDefaults.standard.set(meetingMode, forKey: "CoolCat.MeetingMode") }
    }
    /// 开麦时打字太猛，小猫"嘘"你
    var keyboardNoiseReminder: Bool {
        didSet { UserDefaults.standard.set(keyboardNoiseReminder, forKey: "CoolCat.KeyboardNoiseReminder") }
    }
    /// 是否展示 Claude Code 状态（hook 装没装由 ClaudeHookInstaller 判断）
    var claudeIntegration: Bool {
        didSet { UserDefaults.standard.set(claudeIntegration, forKey: "CoolCat.ClaudeIntegration") }
    }
    /// 是否展示 Codex 状态（与 Claude Code 共用气泡和动作）
    var codexIntegration: Bool {
        didSet { UserDefaults.standard.set(codexIntegration, forKey: "CoolCat.CodexIntegration") }
    }

    /// 打开了状态展示的助手
    var enabledAgents: Set<CodingAgent> {
        var agents: Set<CodingAgent> = []
        if claudeIntegration { agents.insert(.claude) }
        if codexIntegration { agents.insert(.codex) }
        return agents
    }

    func isIntegrationEnabled(_ agent: CodingAgent) -> Bool {
        agent == .codex ? codexIntegration : claudeIntegration
    }

    func setIntegration(_ agent: CodingAgent, enabled: Bool) {
        if agent == .codex { codexIntegration = enabled } else { claudeIntegration = enabled }
    }

    private init() {
        let d = UserDefaults.standard
        showKeyBadges = d.object(forKey: "CoolCat.ShowKeyBadges") as? Bool ?? true
        showMouseBadges = d.object(forKey: "CoolCat.ShowMouseBadges") as? Bool ?? true
        showKeyLegends = d.object(forKey: "CoolCat.ShowKeyLegends") as? Bool ?? true
        footEasterEgg = d.object(forKey: "CoolCat.FootEasterEgg") as? Bool ?? true
        petInteraction = d.object(forKey: "CoolCat.PetInteraction") as? Bool ?? true
        fullClickThrough = d.object(forKey: "CoolCat.FullClickThrough") as? Bool ?? false
        fullScreenOverlay = d.object(forKey: "CoolCat.FullScreenOverlay") as? Bool ?? true
        let savedScale = d.double(forKey: "CoolCat.Scale")
        scale = savedScale > 0.3 ? CGFloat(savedScale) : 1.0
        coatTheme = CatCoatTheme(rawValue: d.string(forKey: "CoolCat.CoatTheme") ?? "") ?? .classicBlack
        keyboardTheme = KeyboardTheme(rawValue: d.string(forKey: "CoolCat.KeyboardTheme") ?? "") ?? .classicMilk
        let savedEye = d.string(forKey: "CoolCat.EyeTheme") ?? ""
        eyeTheme = EyeColorTheme.saved(savedEye)
        musicHeadphones = d.object(forKey: "CoolCat.MusicHeadphones") as? Bool ?? true
        headphonesForAnyAudio = d.object(forKey: "CoolCat.HeadphonesForAnyAudio") as? Bool ?? true
        showTrackBubble = d.object(forKey: "CoolCat.ShowTrackBubble") as? Bool ?? true
        claudeIntegration = d.object(forKey: "CoolCat.ClaudeIntegration") as? Bool ?? true
        codexIntegration = d.object(forKey: "CoolCat.CodexIntegration") as? Bool ?? true
        meetingMode = d.object(forKey: "CoolCat.MeetingMode") as? Bool ?? true
        keyHabitReactions = d.object(forKey: "CoolCat.KeyHabitReactions") as? Bool ?? true
        lifeNight = d.object(forKey: "CoolCat.LifeNight") as? Bool ?? true
        cursorPlay = d.object(forKey: "CoolCat.CursorPlay") as? Bool ?? true
        accessory = CatAccessory(rawValue: d.string(forKey: "CoolCat.Accessory") ?? "") ?? .none
        lifeMorning = d.object(forKey: "CoolCat.LifeMorning") as? Bool ?? true
        lifeBattery = d.object(forKey: "CoolCat.LifeBattery") as? Bool ?? true
        lifeWorkBreak = d.object(forKey: "CoolCat.LifeWorkBreak") as? Bool ?? true
        musicVisualizer = d.object(forKey: "CoolCat.MusicVisualizer") as? Bool ?? true
        realAudioAnalysis = d.object(forKey: "CoolCat.RealAudioAnalysis") as? Bool ?? true
        musicDance = d.object(forKey: "CoolCat.MusicDance") as? Bool ?? true
        idleAnimations = d.object(forKey: "CoolCat.IdleAnimations") as? Bool ?? true
        keyboardNoiseReminder = d.object(forKey: "CoolCat.KeyboardNoiseReminder") as? Bool ?? true
    }
}

// MARK: - Spring Primitives

struct Spring1D {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat

    init(_ initial: CGFloat) {
        self.value = initial
        self.target = initial
    }

    mutating func step(dt: CGFloat, stiffness: CGFloat = 260, damping: CGFloat = 22) {
        let force = (target - value) * stiffness
        let damp = velocity * damping
        velocity += (force - damp) * dt
        value += velocity * dt
    }
}

struct Spring2D {
    var x: Spring1D
    var y: Spring1D

    init(_ pt: CGPoint) {
        self.x = Spring1D(pt.x)
        self.y = Spring1D(pt.y)
    }

    var point: CGPoint { CGPoint(x: x.value, y: y.value) }
    var target: CGPoint {
        get { CGPoint(x: x.target, y: y.target) }
        set { x.target = newValue.x; y.target = newValue.y }
    }

    mutating func step(dt: CGFloat, stiffness: CGFloat = 340, damping: CGFloat = 25) {
        x.step(dt: dt, stiffness: stiffness, damping: damping)
        y.step(dt: dt, stiffness: stiffness, damping: damping)
    }
}

// MARK: - Particles

struct FloatingKeycap {
    let id: Int
    let label: String
    var position: CGPoint
    var velocity: CGPoint
    var age: CGFloat = 0
    let lifetime: CGFloat = 1.25
    var rotation: CGFloat
}

struct PurrSparkle {
    var position: CGPoint
    var velocity: CGPoint
    var age: CGFloat = 0
    var lifetime: CGFloat = 0.9
    let isSleepZ: Bool
    /// 非 nil 时绘制为音符（♪ ♫ ♬），颜色取 noteHue
    var noteGlyph: String? = nil
    var noteHue: CGFloat = 0
    /// 彩带等需要下落的粒子
    var gravity: CGFloat = 0
    var spin: CGFloat = 0
}

struct ScriptedFrameInput {
    var now: CFTimeInterval
    var activeKeys: Set<PhysicalKey>
    var orderedKeys: [PhysicalKey]
    var mouseScreenPos: CGPoint
    var mouseVelocity: CGVector
    var leftMouseDown: Bool
    var rightMouseDown: Bool
    var lastMouseMoveTime: CFTimeInterval
    var lastMouseClickTime: CFTimeInterval
    var lastKeyActivityTime: CFTimeInterval
}

struct Toast {
    enum Style { case track, meeting, camera, habit, bond }
    static let duration: CGFloat = 4.5
    let text: String
    let style: Style
    var age: CGFloat = 0
}

// MARK: - Cat Physics & Procedural Animation State

final class CatPhysics {
    // Logical canvas dimensions
    static let canvasSize = CGSize(width: 360, height: 320)

    // Rest positions
    static let seatAnchor = CGPoint(x: 184, y: 226)
    static let leftPawRest = CGPoint(x: 164, y: 235)
    static let rightPawRest = CGPoint(x: 204, y: 235)
    static let hindFootRest = CGPoint(x: 214, y: 234)
    static let mouseBaseCenter = CGPoint(x: 78, y: 258)

    // Springs
    var leftPaw = Spring2D(leftPawRest)
    var rightPaw = Spring2D(rightPawRest)
    var hindFoot = Spring2D(hindFootRest)
    var hindFootActive = Spring1D(0) // 0 = tucked, 1 = kicking 3rd key

    var bodyShiftX = Spring1D(0)
    var bodyTilt = Spring1D(0)       // radians
    var bodySquash = Spring1D(1.0)
    var headTilt = Spring1D(0)       // radians (roll)
    var headYaw = Spring1D(0)        // -1 (turn left) ... +1 (turn right)
    var headPitch = Spring1D(0)      // -1 (look up)   ... +1 (look down)
    var headOffsetY = Spring1D(0)
    var earFold = Spring1D(0)        // 0 = alert, 1 = relaxed petting ears
    var earTwitch = Spring1D(0)

    var eyeGaze = Spring2D(.zero)    // normalized [-1..1, -1..1]
    var pupilScale = Spring1D(1.0)
    var huntIntensity = Spring1D(0)  // 0 = normal slit pupils, 1 = full hunting crouch + big round boba pupils!
    var mouseOffset = Spring2D(.zero)
    var mousePressLeft = Spring1D(0)
    var mousePressRight = Spring1D(0)

    // Paw mode flags (for crisp outline & posture rendering)
    private(set) var leftPawOnMouse = false
    private(set) var leftPawTyping = false
    private(set) var rightPawTyping = false

    // Keycap glow & press depths
    var keyGlow: [PhysicalKey: CGFloat] = [:]
    var floatingKeycaps: [FloatingKeycap] = []
    var sparkles: [PurrSparkle] = []
    private var nextBadgeID = 1
    private var badgeCascadeIndex = 0
    private var lastBadgeTime: CFTimeInterval = 0

    // Time & blink
    private(set) var time: CGFloat = 0
    private(set) var tailPhase: CGFloat = 0
    private var nextBlinkTime: CGFloat = 3.2
    private var blinkProgress: CGFloat = 0 // 0 = open, 1 = closed
    private var isBlinking = false
    private var blinkTimer: CGFloat = 0

    // Petting state
    private(set) var petHeadIntensity: CGFloat = 0  // 0..1 -> happy closed lime lines
    private(set) var petBodyIntensity: CGFloat = 0  // 0..1 -> blissful half-squint
    private(set) var totalPetSessions: Int = UserDefaults.standard.integer(forKey: "CoolCat.PetCount")
    private var petStrokeAccumulator: CGFloat = 0
    private var lastPetTime: CFTimeInterval = 0
    private var isCurrentlyPetting = false
    private var petCursorCanvasPos: CGPoint = .zero
    private var petSparkleCooldown: CGFloat = 0

    // Music / headphones state
    /// 0 = 没戴耳机, 1 = 戴好；弹簧带一点过冲，戴上时会"啪"地弹一下
    var headphonesOn = Spring1D(0)
    /// 是否在听歌（由 MusicMonitor 驱动）
    var isListening = false
    /// true = 音乐播放器；false = 其他声音（只戴耳机，不冒音符）
    var isListeningToMusicApp = false
    /// 节拍相位（弧度，每拍 2π）
    private(set) var beatPhase: CGFloat = 0
    private(set) var beatsPerMinute: CGFloat = 108
    /// 0..1 闭眼陶醉程度：听歌且一段时间没操作时上升
    private(set) var musicVibe: CGFloat = 0
    private var lastNoteBeat = -1
    /// 头顶的提示气泡（歌名 / 会议提醒）
    private(set) var toast: Toast?

    /// 每拍开头的冲击包络（0..1），用于点头、爪子打拍子
    var beatPulse: CGFloat {
        let local = beatPhase.truncatingRemainder(dividingBy: 2 * .pi) / (2 * .pi)
        return pow(max(0, 1 - local * 2.2), 2)
    }

    // 跳舞 & 空闲小动作（姿态由导演给出，这里叠加到弹簧目标上）
    private var dance = DanceDirector()
    private var idle = IdleDirector()
    /// 本帧的姿态叠加
    private(set) var overlay = PoseOverlay.none
    /// 0..1 跳舞程度（平滑进出）
    private(set) var danceAmount: CGFloat = 0
    private(set) var currentDanceMove: DanceMove?
    private(set) var currentIdleAction: IdleAction?
    /// 预览/调试：允许在没有真实空闲时长的情况下做空闲动作
    var debugAllowIdle = false
    /// 0..1 张嘴（唱歌 / 打哈欠 / 舔爪）
    var mouthOpen = Spring1D(0)
    /// 尾巴摆幅倍数
    private(set) var tailAmplitude: CGFloat = 1

    // 音频频谱
    private(set) var audio = AudioSpectrumSnapshot()
    /// 真实流逝时间（不被 1/25 秒钳制），节拍时钟和延迟队列用它
    private var audioClock: CGFloat = 0
    /// 按输出延迟回放用的快照历史（time, snapshot）
    private var audioHistory: [(time: CGFloat, snapshot: AudioSpectrumSnapshot)] = []
    private var lastAudioBeatSerial = 0
    /// 相位估计出现大跳变的起始时刻（用于迟滞）
    private var phaseJumpSince: CGFloat?
    /// 刚检测到真实鼓点的冲击（1 → 0）
    private(set) var beatKick: CGFloat = 0
    private var lastLiveBeatTime: CGFloat = -10
    /// 显示用的频段（真实音频或模拟），已平滑
    private(set) var spectrum = [CGFloat](repeating: 0, count: AudioSpectrumSnapshot.bandCount)
    /// 每个频段的峰值帽：跟到最高点，再缓慢下落
    private(set) var spectrumPeaks = [CGFloat](repeating: 0, count: AudioSpectrumSnapshot.bandCount)
    var spectrumVisibility = Spring1D(0)
    /// 0..1 当前音乐能量（响度）
    private(set) var musicEnergy: CGFloat = 0.6
    /// 0..1 歌曲能量感（舒缓 ↔ 激烈），决定舞步风格、弹簧软硬、尾巴和音符的节奏
    private(set) var musicArousal: CGFloat = 0.6
    /// 预览/调试：强制能量感
    var debugArousal: CGFloat?
    /// 0..1 节奏强度（鼓点网格有多清晰），强时多点头、不出舒缓摇晃
    private(set) var musicRhythm: CGFloat = 0.5
    /// 预览/调试：强制节奏强度
    var debugRhythm: CGFloat?
    /// 播放器此刻没出声（未防抖）：模拟节拍模式下用它让柱子立刻停下
    var outputSilentHint = false
    /// 安静持续的时间；超过 0.4 秒视为"没声音了"：柱子归零、停止跳舞和点头
    private var quietTime: CGFloat = 0
    private(set) var isAudioQuiet = false
    /// 节拍是否锁在真实鼓点上（否则是按 BPM 自由走）
    var isBeatLocked: Bool { time - lastLiveBeatTime < 3 }

    // 逗猫 & 喂食
    private var play = PlayDirector()
    private(set) var playStalk: CGFloat = 0
    private(set) var playWiggle: CGFloat = 0
    /// 出爪中：哪只爪、伸展程度（给渲染画速度线）
    var swatStreak: (paw: CGPoint, extension: CGFloat)? {
        guard let s = play.swat else { return nil }
        let paw = s.side == .left ? leftPaw.point : rightPaw.point
        return (paw, play.extension_)
    }
    private var lastCursorCanvas: CGPoint?
    /// 预览/调试：直接指定光标在画布上的位置
    var debugCursorCanvas: CGPoint?
    var debugPlayAvailable = false
    private(set) var feedLog = FeedLog(today: LifeCompanion.dayKey(Date(), calendar: .current))
    /// 非 nil = 正在吃小鱼干（已吃了几秒）
    private(set) var feedAge: CGFloat?
    /// 非 nil = 吃不下在摇头
    private(set) var feedRefuseAge: CGFloat?
    static let feedDuration: CGFloat = 4.2
    /// 已经啃掉几口（0...3）
    private(set) var fishBites = 0

    // 亲密度
    private(set) var bond = BondLog(today: LifeCompanion.dayKey(Date(), calendar: .current))
    /// 一起听歌累计秒数，每满 5 分钟记一次亲密度
    private var musicBondSeconds: CGFloat = 0
    /// 0..1 光标停在头上时主动蹭（Lv2 起）
    private(set) var nuzzle: CGFloat = 0
    private var nuzzleHold: CGFloat = 0
    private var nuzzleSide: CGFloat = 1
    /// 小猫送的礼物：推到键盘左上方的桌面上，光标碰一下就收下
    struct Gift {
        enum Kind: CaseIterable { case mouseToy, yarn, flower, feather }
        let kind: Kind
        var age: CGFloat = 0
        /// 非 nil = 已收下（收下后淡出的秒数）
        var acceptedAge: CGFloat?
    }
    private(set) var gift: Gift?
    static let giftRest = CGPoint(x: 96, y: 226)
    static let giftLifetime: CGFloat = 40
    /// 礼物离开爪子、滑到桌面停下的位置
    var giftPoint: CGPoint? {
        guard let g = gift else { return nil }
        let from = CGPoint(x: CatPhysics.seatAnchor.x + bodyShiftX.value - 24, y: 196)
        let t = min(1, g.age / 0.7)
        let e = 1 - pow(1 - t, 3)
        // 推出去时贴着桌面滑，末尾轻轻一顿
        return CGPoint(x: from.x + (CatPhysics.giftRest.x - from.x) * e,
                       y: from.y + (CatPhysics.giftRest.y - from.y) * e - sin(t * .pi) * 10)
    }
    /// 推礼物的那只爪子：0..1
    var giftPush: CGFloat {
        guard let g = gift, g.acceptedAge == nil else { return 0 }
        if g.age < 0.7 { return sin(min(1, g.age / 0.7) * .pi * 0.5) }
        return max(0, 1 - (g.age - 0.7) / 0.35)
    }
    private var giftCheckCooldown: CGFloat = 20
    /// 预览/调试：直接设置亲密度
    var debugBond: BondLog?
    var bondForDisplay: BondLog { debugBond ?? bond }

    // 生活陪伴
    enum HeldProp { case coffee, milk, water }
    /// 0..1 戴睡帽（深夜）
    var nightCap = Spring1D(0)
    /// 帽尖的惯性：软弹簧追着头的歪斜/上下，差值就是帽尖"慢半拍"甩出去的量
    var capSway = Spring1D(0)
    var capBob = Spring1D(0)
    private(set) var isNightTime = false
    /// 0..1 低电量没精神
    private(set) var tiredness: CGFloat = 0
    private var tirednessTarget: CGFloat = 0
    /// 电量小图标（低电量时一直显示，插电后显示几秒）
    private(set) var batteryBadge: BatteryStatus?
    private var batteryBadgeUntil: CGFloat = 0
    private var latestBattery: BatteryStatus?
    private(set) var heldProp: HeldProp?
    private var propRemaining: CGFloat = 0
    private(set) var propAge: CGFloat = 0
    /// 本帧爪子是否真的拿着道具（打字/跳舞时会先放下）
    private(set) var isHoldingProp = false
    /// 预览/演示：强制深夜、强制电池状态
    var debugNight: Bool?
    var debugBattery: BatteryStatus?

    /// 正在抿一口（咖啡/水每 3.4 秒抿一次；奶瓶一直咕咚咕咚）
    var isSipping: Bool {
        guard let prop = heldProp else { return false }
        switch prop {
        case .milk: return propAge.truncatingRemainder(dividingBy: 1.6) < 1.1
        case .coffee, .water:
            let cycle = propAge.truncatingRemainder(dividingBy: 3.4)
            return cycle > 2.2 && cycle < 3.2
        }
    }

    // 键盘习惯
    private var habits = KeyHabitDetector()
    private var kpmSampleCooldown: CGFloat = 0
    /// > 0 时额头冒汗（狂按退格）
    private(set) var sweatTimer: CGFloat = 0
    static let sweatDuration: CGFloat = 2.8
    /// 非 nil 时在画"已保存"印章，值为已显示秒数
    private(set) var saveStampAge: CGFloat?
    static let saveStampDuration: CGFloat = 1.4
    /// > 0 时比耶（截图）
    private(set) var peaceTimer: CGFloat = 0
    static let peaceDuration: CGFloat = 2.2
    /// 截图闪光，0..1 衰减
    private(set) var cameraFlash: CGFloat = 0
    /// > 0 时头戴皇冠（KPM 破纪录）；crownPop 为戴上时的弹跳
    private(set) var crownTimer: CGFloat = 0
    var crownPop = Spring1D(0)

    // 会议模式
    private(set) var micActive = false
    private(set) var cameraActive = false
    /// 0..1 耳麦麦克风杆从下往上转到嘴边
    var boomMic = Spring1D(0)
    /// > 0 时爪子捂嘴"嘘"
    private(set) var shushTimer: CGFloat = 0
    private var shushCooldownUntil: CFTimeInterval = 0
    private var meetingKeyTimes: [CFTimeInterval] = []
    private var groomSparkleCooldown: CGFloat = 0
    /// > 0 时在整理仪容（舔爪子洗脸）
    private(set) var groomTimer: CGFloat = 0
    static let groomDuration: CGFloat = 3.2

    // Claude Code 联动状态
    private(set) var claudeStatus: ClaudeStatus = .idle
    /// 最近一次非 idle 的状态：气泡淡出过程中继续显示它的文字
    private(set) var claudeBubbleStatus: ClaudeStatus = .idle
    /// 逐会话明细（项目名 / 动作 / 耗时）。只在非空时更新，气泡淡出时保留最后一份文字
    var claudeLines: [ClaudeSessionLine] = [] {
        didSet { if claudeLines.isEmpty && claudeStatus.isActive == false { claudeLines = oldValue } }
    }
    /// 0..1 气泡显隐（弹簧，弹出时有一点过冲）
    var claudeBubble = Spring1D(0)
    private(set) var claudeStatusAge: CGFloat = 0
    /// 1 → 0：任务完成后的庆祝余韵（闭眼笑）
    private(set) var celebration: CGFloat = 0

    // Sleepy idle state
    private(set) var sleepiness: CGFloat = 0 // 0 = awake, 1 = napping
    private var sleepZCooldown: CGFloat = 0

    // Recent key memory so fast single taps linger visibly (~140ms)
    private var recentLeftKey: (key: PhysicalKey, time: CFTimeInterval)?
    private var recentRightKey: (key: PhysicalKey, time: CFTimeInterval)?
    private var lastTypedPoint: CGPoint?

    // Computed eye closure (0 = wide open, 0.55 = half squint, 1 = fully closed)
    var effectiveEyeClosure: CGFloat {
        let petClose = max(petHeadIntensity * 1.0, petBodyIntensity * 0.62)
        let sleepClose = sleepiness * 0.92
        let lifeClose = max(isHoldingProp && isSipping ? 0.85 : 0, tiredness * 0.45)
        return min(1.0, max(blinkProgress, max(petClose, max(sleepClose, max(overlay.eyeClosure, lifeClose)))))
    }

    /// True when eyes should draw the signature glowing lime horizontal closed-eye lines
    var isHappyClosedEyes: Bool {
        if case .waiting = claudeStatus { return petHeadIntensity > 0.45 }
        if let age = feedAge, age > 0.9 { return true }       // 吧唧吧唧啃，眯眼享受
        return petHeadIntensity > 0.45 || musicVibe > 0.6 || celebration > 0.35 || groomTimer > 0.3
            || peaceTimer > 0.3 || overlay.eyeClosure > 0.6 || nuzzle > 0.5
    }

    var isBlissfulSquint: Bool {
        petBodyIntensity > 0.35 && !isHappyClosedEyes
    }

    // MARK: - Input Hooks

    func triggerKeyDown(_ key: PhysicalKey, at timestamp: CFTimeInterval? = nil) {
        let now = timestamp ?? CACurrentMediaTime()
        let vk = key.visualKey
        keyGlow[vk] = 1.0

        let pt = KeyboardLayout.canvasPoint(for: vk)
        lastTypedPoint = pt

        // Snap memory to the appropriate paw with lively bounce velocity
        let active = InputEngine.shared.activeKeys
        let leftHeld = active.contains { $0.prefersLeftPaw }
        let rightHeld = active.contains { !$0.prefersLeftPaw }

        if key.prefersLeftPaw {
            recentLeftKey = (vk, now)
            leftPaw.y.velocity -= 180
        } else if !rightHeld || !leftHeld {
            recentRightKey = (vk, now)
            rightPaw.y.velocity -= 180
        } else {
            recentRightKey = (vk, now)
            rightPaw.y.velocity -= 180
        }

        // Expressive micro-reactions
        bodySquash.velocity -= 1.3
        earTwitch.velocity += (key.prefersLeftPaw ? -3.8 : 3.8)
        headTilt.velocity += (key.prefersLeftPaw ? -1.4 : 1.4)
        pupilScale.target = 1.16

        // Wake up immediately
        sleepiness = 0
        checkKeyboardNoise(now: now)
        if let habit = habits.keyDown(key, held: InputEngine.shared.activeKeys.union([key]), now: now) {
            react(to: habit)
        }

        // Spawn floating keycap badge
        if CatSettings.shared.showKeyBadges {
            spawnFloatingKeycap(label: key.badgeLabel, near: pt, now: now)
        }
    }

    func triggerMouseClick(button: Int, isDown: Bool) {
        sleepiness = 0
        if isDown {
            let now = CACurrentMediaTime()
            if button == 0 {
                mousePressLeft.target = 1.0
                leftPaw.y.velocity += 130
            } else {
                mousePressRight.target = 1.0
                leftPaw.y.velocity += 110
            }
            pupilScale.target = 1.12
            earTwitch.velocity -= 2.2
            if CatSettings.shared.showMouseBadges {
                let label = button == 0 ? "左键" : (button == 1 ? "右键" : "中键")
                let pt = CGPoint(
                    x: CatPhysics.mouseBaseCenter.x + mouseOffset.point.x,
                    y: CatPhysics.mouseBaseCenter.y + mouseOffset.point.y - 6
                )
                spawnFloatingKeycap(label: label, near: pt, now: now)
            }
        } else {
            if button == 0 { mousePressLeft.target = 0 }
            else { mousePressRight.target = 0 }
        }
    }

    /// Called by the overlay window when cursor strokes across the cat's head or body.
    func registerPetStroke(canvasPoint: CGPoint, delta: CGFloat, isHead: Bool, at timestamp: CFTimeInterval? = nil) {
        guard CatSettings.shared.petInteraction else { return }
        let now = timestamp ?? CACurrentMediaTime()
        lastPetTime = now
        petCursorCanvasPos = canvasPoint
        sleepiness = 0

        let energy = min(delta / 26.0, 0.35)
        if isHead {
            petHeadIntensity = min(1.0, petHeadIntensity + energy + 0.08)
            petBodyIntensity = max(petBodyIntensity, petHeadIntensity * 0.6)
        } else {
            petBodyIntensity = min(1.0, petBodyIntensity + energy + 0.07)
        }

        petStrokeAccumulator += delta
        if !isCurrentlyPetting && petStrokeAccumulator > 45 {
            isCurrentlyPetting = true
            totalPetSessions += 1
            UserDefaults.standard.set(totalPetSessions, forKey: "CoolCat.PetCount")
            addBond(.pet)
        }

        // Gentle nuzzle toward cursor
        let dx = (canvasPoint.x - CatPhysics.seatAnchor.x) / 60.0
        headTilt.target = max(-0.18, min(0.18, dx * 0.16))
        headOffsetY.velocity += 18
    }

    private var claudeStatusIsWaiting: Bool {
        if case .waiting = claudeStatus { return true }
        return false
    }

    // MARK: - Claude Code Hooks

    func updateClaude(_ status: ClaudeStatus) {
        guard status != claudeStatus else { return }
        // working 内部换工具不算"新状态"，不重置气泡动画
        let sameKind: Bool = {
            switch (status, claudeStatus) {
            case (.working, .working), (.waiting, .waiting): return true
            default: return false
            }
        }()
        claudeStatus = status
        if status.isActive {
            claudeBubbleStatus = status
            sleepiness = 0
        }
        if !sameKind { claudeStatusAge = 0 }
        switch status {
        case .done:
            addBond(.claude)
            celebration = 1
            bodySquash.velocity -= 2.6
            headOffsetY.velocity -= 140
            spawnConfetti()
        case .waiting:
            earTwitch.velocity += 7
            pupilScale.target = 1.22
        default:
            break
        }
    }

    // MARK: - Cursor Play

    private func reactToPlay(_ event: PlayEvent) {
        switch event {
        case .caught(let streak):
            addBond(.catchToy, bonus: streak >= 3 ? 2 : 0)
            guard let target = play.swat?.target else { return }
            sparkles.append(PurrSparkle(position: target, velocity: CGPoint(x: 0, y: -30), isSleepZ: false))
            if streak >= 3 {
                toast = Toast(text: "🐾 抓到啦！连抓三下", style: .habit)
                celebration = max(celebration, 0.6)
                spawnHeart()
            }
        case .missed:
            earTwitch.velocity += 4
        }
    }

    // MARK: - Bond

    private static var todayKey: String { LifeCompanion.dayKey(Date(), calendar: .current) }

    /// 记一次互动；升级时撒花、提示、自动换上新解锁的装扮
    private func addBond(_ source: BondSource, bonus: Int = 0) {
        guard debugBond == nil else { return }
        let gain = bond.record(source, today: Self.todayKey, bonus: bonus)
        guard let up = gain.levelUp else { return }
        var text = "💞 亲密度升级：Lv\(up.level) \(up.title)"
        if let unlock = up.unlock {
            text += " · 解锁\(unlock.title)"
            CatSettings.shared.accessory = unlock
        }
        toast = Toast(text: text, style: .bond)
        celebration = 1
        spawnConfetti()
        spawnHeart()
    }

    /// 今天第一次有人理它：打招呼
    private func greetIfFirstVisit() {
        bond.roll(to: Self.todayKey)
        guard !bond.hasVisitedToday, debugBond == nil else { return }
        let firstEver = bond.points == 0
        let days = bond.daysKnown()
        addBond(.visit)
        // 升级提示优先，不覆盖
        if case .bond = toast?.style, toast?.age ?? 99 < 0.1 { return }
        toast = Toast(text: firstEver ? "喵～ 初次见面，请多关照" : "喵～ 你来啦（认识第 \(days) 天）", style: .bond)
        spawnHeart()
        headOffsetY.velocity -= 90
    }

    /// 送礼物：Lv3 起每天一次，挑小猫闲着、你也没在忙的时候
    private func considerGift(dt: CGFloat, idleSeconds: CFTimeInterval, free: Bool) {
        if var g = gift {
            g.age += dt
            if let a = g.acceptedAge {
                g.acceptedAge = a + dt
                gift = a + dt > 0.6 ? nil : g
            } else {
                gift = g.age > CatPhysics.giftLifetime ? nil : g
            }
            return
        }
        giftCheckCooldown -= dt
        guard giftCheckCooldown <= 0 else { return }
        giftCheckCooldown = 15
        let b = bondForDisplay
        guard b.level.level >= 3, !b.hasGiftedToday || debugBond != nil, free,
              idleSeconds > 8, idleSeconds < 40, Double.random(in: 0...1) < 0.35 else { return }
        offerGift()
    }

    /// 直接送一个礼物（菜单演示/预览也用）
    func offerGift(kind: Gift.Kind? = nil) {
        guard gift == nil else { return }
        gift = Gift(kind: kind ?? Gift.Kind.allCases.randomElement() ?? .mouseToy)
        if debugBond == nil { bond.markGiftOffered(today: Self.todayKey) }
        sleepiness = 0
        toast = Toast(text: "🎁 小猫叼来一个礼物，用光标碰碰它", style: .bond)
    }

    /// 光标碰到礼物：收下
    private func acceptGiftIfTouched(cursor: CGPoint?) {
        guard let c = cursor, let p = giftPoint, var g = gift, g.acceptedAge == nil, g.age > 0.7,
              hypot(c.x - p.x, c.y - p.y) < 22 else { return }
        g.acceptedAge = 0
        gift = g
        addBond(.gift)
        toast = Toast(text: "💝 收到啦！小猫超得意", style: .bond)
        celebration = max(celebration, 0.7)
        spawnHeart()
        for _ in 0..<6 {
            sparkles.append(PurrSparkle(
                position: p, velocity: CGPoint(x: CGFloat.random(in: -50...50), y: CGFloat.random(in: -70 ... -30)),
                lifetime: 1.0, isSleepZ: false, noteGlyph: "♥", noteHue: 0.96, gravity: 120
            ))
        }
    }

    // MARK: - Feeding

    /// 喂一条小鱼干；今天吃满 6 条就摇头
    func feed() {
        feedLog.roll(to: LifeCompanion.dayKey(Date(), calendar: .current))
        guard feedAge == nil, feedRefuseAge == nil else { return }
        sleepiness = 0
        if feedLog.isFull {
            feedRefuseAge = 0
            toast = Toast(text: "吃不下啦，肚子圆滚滚～ 🐟×\(FeedLog.dailyLimit)", style: .habit)
        } else {
            feedAge = 0
            fishBites = 0
            toast = Toast(text: "🐟 小鱼干来啦！", style: .habit)
        }
    }

    /// 小鱼干此刻的位置：从上方掉下来，落进捧在胸前的两只爪子里
    var fishPoint: CGPoint? {
        guard let age = feedAge else { return nil }
        let hold = CGPoint(x: CatPhysics.seatAnchor.x + bodyShiftX.value + 1, y: mouthCanvasPoint.y + 20)
        let fall: CGFloat = 0.55
        guard age < fall else { return hold }
        // easeOutBack：落下时轻轻弹一下
        let t = age / fall, c: CGFloat = 1.6
        let e = 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
        return CGPoint(x: hold.x, y: 24 + (hold.y - 24) * e)
    }

    private func updateFeeding(dt: CGFloat) {
        if var age = feedAge {
            let before = age
            age += dt
            // 三口：每口掉一点碎渣
            for biteTime: CGFloat in [1.4, 2.1, 2.8] where before < biteTime && age >= biteTime {
                fishBites += 1
                let m = mouthCanvasPoint
                for _ in 0..<5 {
                    sparkles.append(PurrSparkle(
                        position: CGPoint(x: m.x + CGFloat.random(in: -8...8), y: m.y + 14),
                        velocity: CGPoint(x: CGFloat.random(in: -40...40), y: CGFloat.random(in: -60 ... -20)),
                        lifetime: 0.8, isSleepZ: false, noteGlyph: "•", noteHue: 0.09, gravity: 260,
                        spin: CGFloat.random(in: -6...6)
                    ))
                }
            }
            if before < 3.5 && age >= 3.5 { spawnHeart() }
            if age >= CatPhysics.feedDuration {
                feedAge = nil
                feedLog.recordMeal()
                toast = Toast(text: "嗝～ 今天第 \(feedLog.count) 条小鱼干", style: .habit)
                addBond(.feed)
            } else {
                feedAge = age
            }
        }
        if let refuse = feedRefuseAge {
            feedRefuseAge = refuse + dt >= 1.4 ? nil : refuse + dt
        }
    }

    // MARK: - Life Companion

    /// 每隔几秒由 AppDelegate 喂入：是否深夜、电池状态、没精神程度
    func setLife(isNight: Bool, battery: BatteryStatus?, tiredness: CGFloat) {
        isNightTime = isNight
        latestBattery = battery
        tirednessTarget = CatSettings.shared.lifeBattery ? tiredness : 0
    }

    func react(life event: LifeEvent) {
        sleepiness = 0
        switch event {
        case .nightReminder(let text):
            toast = Toast(text: text, style: .habit)
        case .morningCoffee:
            toast = Toast(text: "☀️ 早上好！先来杯咖啡", style: .habit)
            offerProp(.coffee, duration: 150)
        case .lowBattery(let percent):
            toast = Toast(text: "🪫 电量只剩 \(percent)%，该充电啦", style: .habit)
        case .pluggedIn:
            toast = Toast(text: "⚡ 充上电啦，咕咚咕咚", style: .habit)
            offerProp(.milk, duration: 6)
            batteryBadgeUntil = time + 6
            // 闪电从身体两侧往上飘，别糊在脸上
            for i in 0..<4 {
                let side: CGFloat = i % 2 == 0 ? -1 : 1
                sparkles.append(PurrSparkle(
                    position: CGPoint(x: CatPhysics.seatAnchor.x + side * CGFloat.random(in: 58...78), y: CGFloat.random(in: 150...200)),
                    velocity: CGPoint(x: CGFloat.random(in: -6...6), y: -26),
                    lifetime: 1.4, isSleepZ: false, noteGlyph: "⚡", noteHue: 0.14
                ))
            }
        case .workBreak(let minutes):
            toast = Toast(text: "💧 已经连续忙了 \(minutes) 分钟，喝口水、站起来动动", style: .habit)
            offerProp(.water, duration: 10)
        }
    }

    func offerProp(_ prop: HeldProp, duration: CGFloat) {
        heldProp = prop
        propRemaining = duration
        propAge = 0
    }

    // MARK: - Key Habit Reactions

    func react(to habit: KeyHabitEvent) {
        guard CatSettings.shared.keyHabitReactions else { return }
        sleepiness = 0
        switch habit {
        case .backspaceStorm:
            sweatTimer = CatPhysics.sweatDuration
            earTwitch.velocity -= 5
        case .save:
            saveStampAge = 0
            headOffsetY.velocity += 70 // 认真点个头
        case .screenshot:
            peaceTimer = CatPhysics.peaceDuration
            cameraFlash = 1
            toast = Toast(text: "📸 咔嚓！", style: .habit)
        case .recordBurstStarted:
            crownTimer = 30
            crownPop.value = 0
            crownPop.velocity = 0
        case .newKPMRecord(let kpm):
            crownTimer = max(crownTimer, 12)
            toast = Toast(text: "👑 新纪录 \(kpm) KPM！", style: .habit)
        }
    }

    // MARK: - Meeting Hooks

    func setMeeting(mic: Bool, micApp: String?, camera: Bool) {
        let micTurnedOn = mic && !micActive
        let cameraTurnedOn = camera && !cameraActive
        micActive = mic
        cameraActive = camera
        if !mic { meetingKeyTimes.removeAll() }
        guard CatSettings.shared.meetingMode else { return }
        if cameraTurnedOn {
            // 镜头一开先洗把脸，洗完再"营业"
            groomTimer = CatPhysics.groomDuration
            sleepiness = 0
        } else if micTurnedOn {
            toast = Toast(text: "🎙 " + (micApp.map { "\($0) 开麦中" } ?? "麦克风开着"), style: .meeting)
        }
    }

    /// 开麦时 2.5s 内连按 9 下以上就提醒一次键盘声，90s 冷却
    private func checkKeyboardNoise(now: CFTimeInterval) {
        let settings = CatSettings.shared
        guard micActive, settings.meetingMode, settings.keyboardNoiseReminder else { return }
        meetingKeyTimes.append(now)
        meetingKeyTimes.removeAll { now - $0 > 2.5 }
        guard meetingKeyTimes.count >= 9, now >= shushCooldownUntil else { return }
        meetingKeyTimes.removeAll()
        shushCooldownUntil = now + 90
        shushTimer = 2.4
        toast = Toast(text: "🤫 开着麦呢，键盘声有点大", style: .meeting)
    }

    /// 嘴巴在画布上的位置（跟随头部的位移/转动），用于捂嘴、洗脸
    var mouthCanvasPoint: CGPoint {
        CGPoint(
            x: CatPhysics.seatAnchor.x + bodyShiftX.value + bodyTilt.value * 36 + headYaw.value * 9,
            y: 126 + headOffsetY.value + headPitch.value * 4.8 + 15
        )
    }

    /// 头顶的提示气泡（权限说明等）
    func showNotice(_ text: String) {
        toast = Toast(text: text, style: .habit)
    }

    /// 舞步相位提前量（秒），抵消跳舞时弹簧的跟随延迟；由端到端测量标定
    static let danceSpringLead: CGFloat = 0.05
    /// 头部转动/俯仰弹簧更"肉"，比身体多滞后约 0.1 拍，再额外提前一点（由逐通道实测标定）
    static let danceHeadExtraLead: CGFloat = 0.05

    // MARK: - Audio Spectrum

    /// 每帧由 AppDelegate 喂入分析器快照。真实鼓点到来时把节拍相位"吸"到整拍上，舞步就踩在点上
    ///
    /// tap 拿到的是"刚送进声卡"的声音，用户听到还要再晚一个输出延迟（蓝牙 ~0.2s、AirPlay ~2s），
    /// 所以快照先进历史队列，按延迟取出来再用：频谱和舞步都对齐到耳朵听到的时刻
    func updateAudio(_ snapshot: AudioSpectrumSnapshot) {
        guard snapshot.isLive else {
            audio = snapshot
            audioHistory.removeAll()
            return
        }
        audioHistory.append((audioClock, snapshot))
        let delay = CGFloat(max(0, min(2.5, snapshot.outputLatency)))
        // 取"延迟之前"最新的一份；队列只保留到这之前的最后一份
        var delayed = audioHistory[0].snapshot
        var keepFrom = 0
        for (i, entry) in audioHistory.enumerated() where entry.time <= audioClock - delay {
            delayed = entry.snapshot
            keepFrom = i
        }
        if keepFrom > 0 { audioHistory.removeFirst(keepFrom) }
        audio = delayed

        // 1) 速度：平滑跟随分析器（分析器侧已做连续性先验 + 迟滞，不会在 2:3 间来回跳）
        if let bpm = delayed.bpm {
            beatsPerMinute += (bpm - beatsPerMinute) * 0.05
            beatsPerMinute = max(60, min(200, beatsPerMinute))
        }
        // 2) 相位：每帧向梳状相位估计平滑靠拢，靠拢速度随置信度。
        //    梳状估计综合了最近 ~4 秒所有起音，强拍主导，单个切分/十六分音符起音拽不动它
        if let since = delayed.secondsSinceBeat, delayed.beatConfidence > 0.15 {
            let target = CGFloat(since) * beatsPerMinute / 60                  // 拍内进度 0..1
            let beats = beatPhase / (2 * .pi)
            var error = target - (beats - beats.rounded(.down))
            if error > 0.5 { error -= 1 } else if error < -0.5 { error += 1 }
            // 大跳变（超过 1/4 拍，多半是估计短暂落到了反拍）要持续 1.2 秒才跟；小偏差立即平滑修正
            var follow = true
            if abs(error) > 0.25 {
                if phaseJumpSince == nil { phaseJumpSince = time }
                follow = time - (phaseJumpSince ?? time) > 1.2
            } else {
                phaseJumpSince = nil
            }
            if follow {
                let gain = 0.06 * min(1, delayed.beatConfidence / 0.5)
                beatPhase += error * gain * 2 * .pi
            }
            lastLiveBeatTime = time
        }
        // 3) 单个起音只用来闪一下（墙、舞步重音），并统计它是否落在猫的拍子网格上（诊断用）
        guard delayed.beatSerial != lastAudioBeatSerial else { return }
        lastAudioBeatSerial = delayed.beatSerial
        let beats = beatPhase / (2 * .pi)
        let lagBeats = CGFloat(delayed.analysisDelay) * beatsPerMinute / 60
        let gridError = ((beats - lagBeats).rounded() + lagBeats) - beats
        recordLockSample(error: gridError)
        // 只有落在拍上的起音才给重音；反拍/切分起音不让猫在两拍之间多做一下
        if abs(gridError) < 0.15 { beatKick = max(beatKick, 1 - abs(gridError) / 0.15) }
    }

    // MARK: - Beat Lock Diagnostics

    private var lockErrors: [CGFloat] = []
    private var lockWindowStart: CGFloat = 0

    /// 每 5 秒汇总一次：收到多少鼓点、多少落在猫的整拍附近（|误差| < 0.1 拍）、平均误差毫秒数
    private func recordLockSample(error: CGFloat) {
        lockErrors.append(error)
        guard time - lockWindowStart >= 5 else { return }
        defer { lockErrors.removeAll(); lockWindowStart = time }
        let onGrid = lockErrors.filter { abs($0) < 0.3 }
        let locked = onGrid.filter { abs($0) < 0.1 }.count
        let msPerBeat = 60_000 / max(1, beatsPerMinute)
        let meanMs = onGrid.isEmpty ? 0 : onGrid.map { abs($0) }.reduce(0, +) / CGFloat(onGrid.count) * msPerBeat
        let signedMs = onGrid.isEmpty ? 0 : onGrid.reduce(0, +) / CGFloat(onGrid.count) * msPerBeat
        let line = String(format: "lock 5s: beats=%d onGrid=%d locked=%d mean|err|=%.0fms bias=%+.0fms bpm=%.1f move=%@ arousal=%.2f rhythm=%.2f dance=%.2f",
                          lockErrors.count, onGrid.count, locked, meanMs, signedMs, beatsPerMinute,
                          currentDanceMove?.rawValue ?? "-", musicArousal, musicRhythm, danceAmount)
        danceLog.notice("\(line, privacy: .public)")
    }

    // MARK: - Debug / Preview

    func debugForceDance(_ move: DanceMove) {
        dance.force(move, atBeat: Int(beatPhase / (2 * .pi)))
    }

    func debugForceIdle(_ action: IdleAction, age: CGFloat) {
        debugAllowIdle = true
        idle.force(action, age: age)
    }

    // MARK: - Music Hooks

    func setListening(_ listening: Bool, musicApp: Bool) {
        isListening = listening
        isListeningToMusicApp = listening && musicApp
        if listening { sleepiness = 0 }
    }

    /// 切歌：弹歌名气泡，并按歌名哈希出一个稳定的 BPM，不同的歌点头速度不同
    func showTrack(title: String, artist: String?) {
        var hash: UInt64 = 1469598103934665603
        for b in title.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        // 有真实音频时以分析结果为准，别用歌名哈希覆盖（会让刚锁好的拍子跑掉几秒）
        if !(audio.isLive && isBeatLocked) { beatsPerMinute = 92 + CGFloat(hash % 37) } // 92...128
        guard CatSettings.shared.showTrackBubble else { return }
        let text = artist.map { "\(title) - \($0)" } ?? title
        toast = Toast(text: "♪ " + text, style: .track)
    }

    private func spawnFloatingKeycap(label: String, near pt: CGPoint, now: CFTimeInterval) {
        if now - lastBadgeTime < 0.38 {
            badgeCascadeIndex = (badgeCascadeIndex + 1) % 6
        } else {
            badgeCascadeIndex = 0
        }
        lastBadgeTime = now

        // Spread fast bursts gracefully so they stay readable like "F O J F E A"
        let spreadOffsets: [CGFloat] = [-10, 14, -22, 26, 2, 36]
        let dx = spreadOffsets[badgeCascadeIndex] + CGFloat.random(in: -3...3)
        let startX = max(55, min(315, pt.x + dx * 0.45))
        let startY = pt.y - 26 - CGFloat(badgeCascadeIndex % 2) * 8

        let badge = FloatingKeycap(
            id: nextBadgeID,
            label: label,
            position: CGPoint(x: startX, y: startY),
            velocity: CGPoint(x: dx * 0.65, y: -36 - CGFloat.random(in: 0...14)),
            rotation: CGFloat.random(in: -0.07...0.07)
        )
        nextBadgeID += 1
        floatingKeycaps.append(badge)
        if floatingKeycaps.count > 16 {
            floatingKeycaps.removeFirst(floatingKeycaps.count - 16)
        }
    }

    // MARK: - 60 FPS Simulation Step

    func step(dt rawDt: CGFloat, windowFrameInScreen: CGRect, scripted: ScriptedFrameInput? = nil) {
        let dt = min(rawDt, 1.0 / 25.0)
        // 节拍和输出延迟队列用真实流逝时间：卡顿时不丢相位（只防极端长卡顿）
        let clockDt = min(rawDt, 0.5)
        audioClock += clockDt
        time += dt

        let engine = InputEngine.shared
        if scripted == nil {
            engine.pollMouse(dt: dt)
        }

        let now = scripted?.now ?? CACurrentMediaTime()
        let activeKeys = scripted?.activeKeys ?? engine.activeKeys
        let orderedKeys = scripted?.orderedKeys ?? engine.pressedOrder
        let curMouseVel = scripted?.mouseVelocity ?? engine.mouseVelocity
        let curMouseLoc = scripted?.mouseScreenPos ?? engine.lastMouseLocation
        let curLeftMouse = scripted?.leftMouseDown ?? engine.leftMouseDown
        let curRightMouse = scripted?.rightMouseDown ?? engine.rightMouseDown
        let curLastMouseMove = scripted?.lastMouseMoveTime ?? engine.lastMouseMoveTime
        let curLastMouseClick = scripted?.lastMouseClickTime ?? engine.lastMouseClickTime
        let curLastKeyTime = scripted?.lastKeyActivityTime ?? engine.lastKeyActivityTime

        // 1. Decay petting intensity gracefully when hand stops moving
        if now - lastPetTime > 0.28 {
            petHeadIntensity = max(0, petHeadIntensity - dt * 1.4)
            petBodyIntensity = max(0, petBodyIntensity - dt * 1.2)
            if petHeadIntensity < 0.05 && petBodyIntensity < 0.05 {
                isCurrentlyPetting = false
                petStrokeAccumulator = 0
            }
        } else if (petHeadIntensity > 0.55 || petBodyIntensity > 0.55) {
            petSparkleCooldown -= dt
            if petSparkleCooldown <= 0 {
                petSparkleCooldown = 0.42
                let sx = CatPhysics.seatAnchor.x + CGFloat.random(in: -44...44)
                let sy = 88 + CGFloat.random(in: -14...18)
                sparkles.append(PurrSparkle(
                    position: CGPoint(x: sx, y: sy),
                    velocity: CGPoint(x: CGFloat.random(in: -10...10), y: -24),
                    isSleepZ: false
                ))
            }
        }

        // 2. Sleepy idle detection
        let lastAnyActivity = max(curLastKeyTime, max(curLastMouseMove, lastPetTime))
        let idleSeconds = lastAnyActivity > 0 ? (now - lastAnyActivity) : 0
        let vibingToMusic = isListening && headphonesOn.value > 0.5
        // Claude 在干活时小猫陪着盯，不睡
        if activeKeys.isEmpty && idleSeconds > 45 && !vibingToMusic && !claudeStatus.isActive {
            let targetSleep = min(1.0, CGFloat((idleSeconds - 45) / 35.0))
            sleepiness += (targetSleep - sleepiness) * dt * 1.5
            if sleepiness > 0.8 {
                sleepZCooldown -= dt
                if sleepZCooldown <= 0 {
                    sleepZCooldown = 2.6
                    sparkles.append(PurrSparkle(
                        position: CGPoint(x: CatPhysics.seatAnchor.x + 42, y: 100),
                        velocity: CGPoint(x: 12, y: -18),
                        isSleepZ: true
                    ))
                }
            }
        } else {
            sleepiness = max(0, sleepiness - dt * 5.0)
        }

        // 2b. Fast Mouse Movement -> Hunting / Stalking Mode (dilated round boba pupils + low crouch!)
        let mouseSpeed = hypot(curMouseVel.dx, curMouseVel.dy)
        if mouseSpeed > 1500 && petHeadIntensity < 0.25 && petBodyIntensity < 0.25 {
            // Only rapid mouse shaking/flicking triggers hunting dilation (ignore casual movement)
            let boost = min(1.0, (mouseSpeed - 1500) / 1800.0)
            huntIntensity.target = min(1.0, huntIntensity.target + (0.40 + boost * 1.25) * dt)
            sleepiness = 0
        } else {
            // Calm down quickly once cursor stops darting
            huntIntensity.target = max(0.0, huntIntensity.target - dt * 1.15)
        }
        huntIntensity.step(dt: dt, stiffness: 85, damping: 16)
        let hunt = max(0, min(1, huntIntensity.value))

        // 2c. 听歌：戴/摘耳机、节拍、陶醉闭眼、音符粒子
        let wantMusic = isListening && CatSettings.shared.musicHeadphones
        let wantHeadset = micActive && CatSettings.shared.meetingMode
        headphonesOn.target = (wantMusic || wantHeadset) ? 1 : 0
        headphonesOn.step(dt: dt, stiffness: 170, damping: 13)
        boomMic.target = wantHeadset ? 1 : 0
        boomMic.step(dt: dt, stiffness: 150, damping: 14)
        // 只有听歌才跟拍子动；开会只戴耳麦不摇头
        let music = wantMusic ? max(0, min(1, headphonesOn.value)) : 0
        if wantMusic {
            beatPhase += clockDt * beatsPerMinute / 60 * 2 * .pi
            // 2.5s 没碰键鼠就闭眼陶醉；一动就睁眼。捕猎/摸头时让位给原有表情
            let idleForVibe = now - max(curLastKeyTime, curLastMouseMove) > 2.5
            let vibeTarget: CGFloat = (idleForVibe && hunt < 0.2) ? 1 : 0
            musicVibe += (vibeTarget - musicVibe) * min(1, dt * (vibeTarget > musicVibe ? 1.2 : 6))
            spawnMusicNotesIfNeeded()
        } else {
            musicVibe = max(0, musicVibe - dt * 4)
            lastNoteBeat = -1
        }
        // 2g. 频谱：真实音频优先，否则按节拍合成
        beatKick = max(0, beatKick - dt * 5)
        spectrumVisibility.target = (wantMusic && CatSettings.shared.musicVisualizer) ? 1 : 0
        spectrumVisibility.step(dt: dt, stiffness: 90, damping: 14)
        // 真实音频在跑：完全以它为准，安静就是安静（不再退回模拟节拍）
        let liveAudio = audio.isLive
        let quietNow = liveAudio ? audio.level < 0.03 : outputSilentHint
        quietTime = quietNow ? quietTime + dt : 0
        isAudioQuiet = quietTime > 0.4
        musicEnergy += ((liveAudio ? audio.level : (isAudioQuiet ? 0 : 0.6)) - musicEnergy) * min(1, dt * 4)
        let arousalTarget = debugArousal ?? (liveAudio ? audio.arousal : 0.6)
        musicArousal += (arousalTarget - musicArousal) * min(1, dt / 3)
        let rhythmTarget = debugRhythm ?? (liveAudio ? audio.rhythmStrength : 0.6)
        // 分析器侧已平滑 2 秒，这里只再平滑 1 秒：强节奏歌开头几秒就能认出来
        musicRhythm += (rhythmTarget - musicRhythm) * min(1, dt / 1)
        if spectrumVisibility.value > 0.01 || spectrumVisibility.target > 0 {
            for i in 0..<spectrum.count {
                let target: CGFloat
                if liveAudio {
                    target = audio.bands[i]
                } else if isAudioQuiet {
                    target = 0
                } else {
                    // 模拟：低频跟拍子跳，中高频缓慢起伏
                    let f = CGFloat(i) / CGFloat(spectrum.count)
                    let wobble = 0.5 + 0.5 * sin(time * (1.3 + f * 4.1) + CGFloat(i) * 1.7)
                    target = (0.18 + wobble * 0.35) * (1 - f * 0.35) + beatPulse * (1 - f) * 0.55
                }
                spectrum[i] += (min(1, target) - spectrum[i]) * min(1, dt * (target > spectrum[i] ? 22 : 9))
                spectrumPeaks[i] = max(spectrum[i], spectrumPeaks[i] - dt * 0.55)
            }
        }

        // 2h. 跳舞：听歌、2.5s 没碰键鼠、没有更重要的表演时
        let userIdleShort = now - max(curLastKeyTime, curLastMouseMove) > 2.5
        let busyElsewhere = shushTimer > 0 || groomTimer > 0 || peaceTimer > 0 || claudeStatusIsWaiting
            || petHeadIntensity > 0.3 || petBodyIntensity > 0.3
        let canDance = wantMusic && CatSettings.shared.musicDance && music > 0.5 && userIdleShort && !isAudioQuiet
            && feedAge == nil
            && hunt < 0.2 && !busyElsewhere && activeKeys.isEmpty
        danceAmount += ((canDance ? 1 : 0) - danceAmount) * min(1, dt * (canDance ? 1.5 : 6))
        var frameOverlay = PoseOverlay.none
        if danceAmount > 0.01 {
            let seatX = CatPhysics.seatAnchor.x + bodyShiftX.value
            // 弹簧追目标有几十毫秒滞后，姿态按"提前一点"的相位算，动作才落在拍点上
            let lead = CatPhysics.danceSpringLead * beatsPerMinute / 60 * 2 * .pi
            let headLead = CatPhysics.danceHeadExtraLead * beatsPerMinute / 60 * 2 * .pi
            frameOverlay = dance.pose(beatPhase: beatPhase + lead, headLead: headLead, energy: musicEnergy,
                                      kick: beatKick, seatX: seatX, arousal: musicArousal, rhythm: musicRhythm)
                .scaled(by: danceAmount)
            currentDanceMove = dance.move
        } else {
            currentDanceMove = nil
        }

        // 2i. 空闲小动作：不听歌、Claude 不需要你、5 秒以上没操作、还没犯困
        let idleFor = lastAnyActivity > 0 ? now - lastAnyActivity : CFTimeInterval(time)
        let idleAllowed = debugAllowIdle || (CatSettings.shared.idleAnimations && !wantMusic && !busyElsewhere
            && !claudeStatus.isActive && idleFor > 5 && sleepiness < 0.2 && hunt < 0.1 && activeKeys.isEmpty
            && !micActive)
        let idleResult = idle.update(dt: dt, allowed: idleAllowed, seatX: CatPhysics.seatAnchor.x + bodyShiftX.value,
                                     preferYawn: (debugNight ?? isNightTime) && CatSettings.shared.lifeNight)
        currentIdleAction = idle.action
        if idle.action != nil { frameOverlay = idleResult.overlay }
        if idleResult.started == .slowBlink { spawnHeart() }
        overlay = frameOverlay
        var chew: CGFloat = 0
        if let age = feedAge {
            if age > 0.9 && age < 3.4 { chew = 0.3 + 0.3 * sin(age * 2 * .pi * 4.5) }   // 吧唧吧唧
            else if age >= 3.4 { chew = 0.15 }                                            // 舔嘴
        }
        mouthOpen.target = max(overlay.mouthOpen, max(isHoldingProp && isSipping ? 0.25 : 0, chew))
        mouthOpen.step(dt: dt, stiffness: 300, damping: 22)
        tailAmplitude += (1 + overlay.tailBoost - tailAmplitude) * min(1, dt * 6)
        if let key = overlay.pressedKey { keyGlow[key] = max(keyGlow[key] ?? 0, 0.9) }

        // 2j. 生活陪伴：睡帽、没精神、手持道具计时、电量小图标
        let night = debugNight ?? isNightTime
        nightCap.target = (night && CatSettings.shared.lifeNight) ? 1 : 0
        nightCap.step(dt: dt, stiffness: 200, damping: 13)
        capSway.target = headTilt.value
        capSway.step(dt: dt, stiffness: 45, damping: 4.5)
        capBob.target = headOffsetY.value
        capBob.step(dt: dt, stiffness: 60, damping: 5)
        let tiredTarget = debugBattery.map { $0.onAC ? 0 : ($0.percent <= 10 ? 1 : ($0.percent <= 20 ? 0.6 : 0)) } ?? tirednessTarget
        tiredness += (tiredTarget - tiredness) * min(1, dt * 1.5)
        if heldProp != nil {
            propRemaining -= dt
            propAge += dt
            if propRemaining <= 0 { heldProp = nil }
        }
        let shownBattery = debugBattery ?? latestBattery
        batteryBadge = (tiredness > 0.1 || time < batteryBadgeUntil) ? shownBattery : nil

        // 2k. 喂食 + 逗猫
        updateFeeding(dt: dt)
        var cursorCanvasNow: CGPoint? = debugCursorCanvas
        if cursorCanvasNow == nil, windowFrameInScreen.width > 1 {
            let k = windowFrameInScreen.width / CatPhysics.canvasSize.width
            cursorCanvasNow = CGPoint(x: (curMouseLoc.x - windowFrameInScreen.minX) / k,
                                      y: (windowFrameInScreen.maxY - curMouseLoc.y) / k)
        }
        let cursorSpeed = zip2(cursorCanvasNow, lastCursorCanvas).map { hypot($0.x - $1.x, $0.y - $1.y) / max(dt, 1e-3) } ?? 0
        lastCursorCanvas = cursorCanvasNow
        // 逗猫区：画布内、不在头/身体/键盘（那是摸猫和拖动的地方）
        var playCursor: CGPoint?
        if let c = cursorCanvasNow, c.x >= 0, c.y >= 0,
           c.x <= CatPhysics.canvasSize.width, c.y <= CatPhysics.canvasSize.height,
           CatRenderer.hitTest(point: c, physics: self, showPermissionPill: false) == .none {
            playCursor = c
        }
        let typingRecent = !activeKeys.isEmpty || now - curLastKeyTime < 1.0
        let playAvailable = debugPlayAvailable || (CatSettings.shared.cursorPlay && !typingRecent && danceAmount < 0.3
            && !claudeStatusIsWaiting && heldProp == nil && shushTimer == 0 && groomTimer == 0 && peaceTimer == 0
            && feedAge == nil && feedRefuseAge == nil && petHeadIntensity < 0.2 && sleepiness < 0.4 && hunt < 0.5)
        let seatXNow = CatPhysics.seatAnchor.x + bodyShiftX.value
        let shoulders = (left: CGPoint(x: seatXNow - 20, y: 182), right: CGPoint(x: seatXNow + 20, y: 182))
        if let playEvent = play.update(dt: dt, cursor: playCursor, speed: cursorSpeed, available: playAvailable,
                                       shoulders: shoulders) {
            reactToPlay(playEvent)
        }
        playStalk = play.stalk
        playWiggle = play.wiggle

        // 2l. 亲密度：打招呼、一起听歌、蹭光标、送礼物
        if scripted == nil && idleSeconds < 1 { greetIfFirstVisit() }
        if isListening && headphonesOn.value > 0.5 && !isAudioQuiet {
            musicBondSeconds += dt
            if musicBondSeconds >= 300 { musicBondSeconds = 0; addBond(.music) }
        }
        let bondLevel = bondForDisplay.level.level
        var onHead = false
        if let c = cursorCanvasNow, CatRenderer.hitTest(point: c, physics: self, showPermissionPill: false) == .head {
            onHead = true
            nuzzleSide = c.x < CatPhysics.seatAnchor.x + bodyShiftX.value ? -1 : 1
        }
        // 光标停在头上不动（不是在摸）超过 0.8 秒：主动蹭过去
        let nuzzleOK = bondLevel >= 2 && onHead && cursorSpeed < 40 && now - lastPetTime > 0.5
            && sleepiness < 0.5 && feedAge == nil && danceAmount < 0.3 && !typingRecent
        nuzzleHold = nuzzleOK ? nuzzleHold + dt : 0
        let nuzzleTarget: CGFloat = nuzzleHold > 0.8 ? 1 : 0
        nuzzle += (nuzzleTarget - nuzzle) * min(1, dt * (nuzzleTarget > nuzzle ? 3 : 5))
        if nuzzle > 0.6 {
            petSparkleCooldown -= dt
            if petSparkleCooldown <= 0 {
                petSparkleCooldown = 0.7
                spawnHeart()
            }
        }
        // 不复用 playAvailable：关掉逗猫也照样会送礼物
        let giftFree = !typingRecent && danceAmount < 0.3 && heldProp == nil && feedAge == nil && feedRefuseAge == nil
            && sleepiness < 0.2 && !claudeStatus.isActive && playStalk < 0.1 && play.swat == nil
            && shushTimer == 0 && groomTimer == 0 && peaceTimer == 0
        considerGift(dt: dt, idleSeconds: idleSeconds, free: giftFree)
        acceptGiftIfTouched(cursor: cursorCanvasNow)

        // 2f. 键盘习惯：计时衰减 + 定期采样 KPM 判断破纪录
        sweatTimer = max(0, sweatTimer - dt)
        peaceTimer = max(0, peaceTimer - dt)
        cameraFlash = max(0, cameraFlash - dt * 3.2)
        crownTimer = max(0, crownTimer - dt)
        if let age = saveStampAge {
            saveStampAge = age + dt > CatPhysics.saveStampDuration ? nil : age + dt
        }
        crownPop.target = crownTimer > 0 ? 1 : 0
        crownPop.step(dt: dt, stiffness: 210, damping: 12)
        if scripted == nil {
            kpmSampleCooldown -= dt
            if kpmSampleCooldown <= 0 {
                kpmSampleCooldown = 0.25
                if let habit = habits.sampleKPM(engine.currentKPM) { react(to: habit) }
            }
        }

        // 2e. 会议：嘘 / 洗脸计时
        shushTimer = max(0, shushTimer - dt)
        if groomTimer > 0 {
            groomTimer -= dt
            // 洗脸冒小星星：黑猫的爪子和脸同色，靠粒子让动作看得出来
            groomSparkleCooldown -= dt
            if groomSparkleCooldown <= 0 {
                groomSparkleCooldown = 0.3
                let m = mouthCanvasPoint
                sparkles.append(PurrSparkle(
                    position: CGPoint(x: m.x + 22 + CGFloat.random(in: -10...14), y: m.y - 18 + CGFloat.random(in: -10...8)),
                    velocity: CGPoint(x: CGFloat.random(in: -8...12), y: -22),
                    isSleepZ: false
                ))
            }
            if groomTimer <= 0 {
                groomTimer = 0
                toast = Toast(text: "✨ 洗好脸了，营业中", style: .camera)
            }
        }

        // 2d. Claude Code：气泡显隐、庆祝衰减
        claudeStatusAge += dt
        claudeBubble.target = claudeStatus.isActive ? 1 : 0
        claudeBubble.step(dt: dt, stiffness: 240, damping: 15)
        celebration = max(0, celebration - dt / 2.4)
        var claudeWaiting = false
        if case .waiting = claudeStatus { claudeWaiting = true }
        var claudeWorking = false
        if case .working = claudeStatus { claudeWorking = true }
        let userIdleForClaude = now - max(curLastKeyTime, curLastMouseMove) > 2.0

        if var current = toast {
            current.age += dt
            toast = current.age > Toast.duration ? nil : current
        }

        // 3. Determine limb targets (Left Paw, Right Paw, 3rd-Key Hind Foot!)
        let tapHoldWindow: CFTimeInterval = 0.14
        let mouseRecent = (now - curLastMouseMove < 2.2) || curLeftMouse || curRightMouse
        let mouseActivelyUsed = (now - curLastMouseMove < 0.75) || curLeftMouse || curRightMouse

        // Partition active keys
        var leftCandidates: [PhysicalKey] = []
        var rightCandidates: [PhysicalKey] = []
        for k in orderedKeys {
            if k.prefersLeftPaw { leftCandidates.append(k) }
            else { rightCandidates.append(k) }
        }

        var leftKey: PhysicalKey? = leftCandidates.last
        var rightKey: PhysicalKey? = rightCandidates.last
        var footKey: PhysicalKey? = nil

        // If 2+ keys are pressed on the same side, let the free paw help —
        // UNLESS viewer-left paw (cat's right hand) is actively driving the mouse!
        if leftKey == nil && rightCandidates.count >= 2 && !mouseActivelyUsed {
            let sorted = rightCandidates.sorted {
                KeyboardLayout.canvasPoint(for: $0).x < KeyboardLayout.canvasPoint(for: $1).x
            }
            leftKey = sorted.first
            rightKey = sorted.last
        } else if rightKey == nil && leftCandidates.count >= 2 {
            let sorted = leftCandidates.sorted {
                KeyboardLayout.canvasPoint(for: $0).x < KeyboardLayout.canvasPoint(for: $1).x
            }
            leftKey = sorted.first
            rightKey = sorted.last
        }

        // 3+ simultaneous keys (or 2+ keys while other hand is busy on the mouse!) -> HIND FOOT EASTER EGG!!
        if CatSettings.shared.footEasterEgg {
            if orderedKeys.count >= 3 {
                footKey = orderedKeys.first { $0 != leftKey && $0 != rightKey }
            } else if mouseActivelyUsed && leftKey == nil && rightCandidates.count >= 2 {
                footKey = rightCandidates.first { $0 != rightKey }
            }
        }

        // Keep quick taps visible for a tiny snappy window
        if leftKey == nil, let rec = recentLeftKey, now - rec.time < tapHoldWindow {
            leftKey = rec.key
        }
        if rightKey == nil, let rec = recentRightKey, now - rec.time < tapHoldWindow {
            rightKey = rec.key
        }

        // Subtle mini-mouse movement driven by global cursor velocity
        let targetMouseDx = max(-5.5, min(5.5, curMouseVel.dx * 0.0045))
        let targetMouseDy = max(-4.5, min(4.5, -curMouseVel.dy * 0.0045))
        mouseOffset.target = CGPoint(x: targetMouseDx, y: targetMouseDy)
        mouseOffset.step(dt: dt, stiffness: 120, damping: 16)
        mousePressLeft.step(dt: dt, stiffness: 400, damping: 24)
        mousePressRight.step(dt: dt, stiffness: 400, damping: 24)

        let liveMouseCenter = CGPoint(
            x: CatPhysics.mouseBaseCenter.x + mouseOffset.point.x,
            y: CatPhysics.mouseBaseCenter.y + mouseOffset.point.y
        )

        // Left paw target
        if let lk = leftKey {
            leftPaw.target = KeyboardLayout.canvasPoint(for: lk)
            leftPawTyping = true
            leftPawOnMouse = false
        } else if mouseRecent && sleepiness < 0.3 {
            leftPaw.target = CGPoint(x: liveMouseCenter.x + 2, y: liveMouseCenter.y - 3)
            leftPawTyping = false
            leftPawOnMouse = true
        } else {
            leftPaw.target = CatPhysics.leftPawRest
            leftPawTyping = false
            leftPawOnMouse = false
        }

        // Right paw target
        if let rk = rightKey {
            rightPaw.target = KeyboardLayout.canvasPoint(for: rk)
            rightPawTyping = true
        } else {
            if claudeWaiting {
                // Claude 等你批准：举起爪子在头边挥手
                rightPaw.target = CGPoint(x: CatPhysics.rightPawRest.x + 36 + sin(time * 9) * 5,
                                          y: 146 + sin(time * 9 + 1.2) * 6)
            } else {
                // 听歌时空闲的爪子跟着拍子轻敲桌面
                rightPaw.target = CGPoint(x: CatPhysics.rightPawRest.x,
                                          y: CatPhysics.rightPawRest.y
                                            - (1 - cos(beatPhase)) / 2 * 3.5 * music * (isAudioQuiet ? 0 : 1))
            }
            rightPawTyping = false
        }

        isHoldingProp = false
        // 优先级：喂食（你主动点的）> 捂嘴 > 洗脸 > 比耶 > 手持道具 > 逗猫出爪 > 舞步/空闲动作
        if let fish = fishPoint, let age = feedAge, age > 0.15 {
            // 两只爪子捧着小鱼干
            leftPaw.target = CGPoint(x: fish.x - 9, y: fish.y + 7)
            rightPaw.target = CGPoint(x: fish.x + 9, y: fish.y + 7)
            leftPawOnMouse = false
            leftPawTyping = false
            rightPawTyping = false
        } else if shushTimer > 0 {
            let m = mouthCanvasPoint
            rightPaw.target = CGPoint(x: m.x + 3, y: m.y - 4)
            rightPawTyping = false
        } else if groomTimer > 0 {
            let m = mouthCanvasPoint
            rightPaw.target = CGPoint(x: m.x + 20 + sin(time * 7) * 4, y: m.y - 10 + cos(time * 7) * 5)
            rightPawTyping = false
        } else if peaceTimer > 0 {
            // 截图比耶：举爪停在脸旁边
            rightPaw.target = CGPoint(x: CatPhysics.rightPawRest.x + 32, y: 140)
            rightPawTyping = false
        } else if heldProp != nil && rightKey == nil && danceAmount < 0.3 {
            // 端着咖啡/奶瓶/水杯：平时捧在胸前，抿一口时送到嘴边
            let m = mouthCanvasPoint
            rightPaw.target = isSipping ? CGPoint(x: m.x + 9, y: m.y + 7)
                                        : CGPoint(x: CatPhysics.seatAnchor.x + bodyShiftX.value + 16, y: 184)
            rightPawTyping = false
            isHoldingProp = true
        } else if play.swat != nil {
            // 逗猫：出爪拍光标
            let side = play.swat?.side ?? .left
            let shoulder = side == .left ? shoulders.left : shoulders.right
            if let target = play.swatPawTarget(shoulder: shoulder) {
                if side == .left {
                    leftPaw.target = target
                    leftPawOnMouse = false
                    leftPawTyping = false
                } else {
                    rightPaw.target = target
                    rightPawTyping = false
                }
            }
        } else if giftPush > 0.02, let g = giftPoint {
            // 送礼物：左爪把礼物推到桌面上
            let w = giftPush
            let rest = leftPaw.target
            leftPaw.target = CGPoint(x: rest.x + (g.x + 8 - rest.x) * w, y: rest.y + (g.y - 4 - rest.y) * w)
            leftPawOnMouse = false
            leftPawTyping = false
        } else {
            // 舞步 / 空闲动作的爪子（打字中的爪子不抢）
            // 按权重从默认位置拉过去：开始跳舞、换舞步时爪子平滑过渡，不会"嗖"地跳过去
            if let paw = overlay.rightPaw, rightKey == nil {
                let w = max(0, min(1, overlay.rightPawWeight))
                rightPaw.target = CGPoint(x: rightPaw.target.x + (paw.x - rightPaw.target.x) * w,
                                          y: rightPaw.target.y + (paw.y - rightPaw.target.y) * w)
                if w > 0.5 { rightPawTyping = false }
            }
            if let paw = overlay.leftPaw, leftKey == nil {
                let w = max(0, min(1, overlay.leftPawWeight))
                leftPaw.target = CGPoint(x: leftPaw.target.x + (paw.x - leftPaw.target.x) * w,
                                         y: leftPaw.target.y + (paw.y - leftPaw.target.y) * w)
                if w > 0.5 {
                    leftPawOnMouse = false
                    leftPawTyping = false
                }
            }
        }

        // Hind foot target (3rd simultaneous key!)
        if let fk = footKey {
            hindFoot.target = KeyboardLayout.canvasPoint(for: fk)
            hindFootActive.target = 1.0
        } else {
            hindFoot.target = CatPhysics.hindFootRest
            hindFootActive.target = 0.0
        }

        leftPaw.step(dt: dt, stiffness: 360, damping: 24)
        rightPaw.step(dt: dt, stiffness: 360, damping: 24)
        hindFoot.step(dt: dt, stiffness: 320, damping: 22)
        hindFootActive.step(dt: dt, stiffness: 260, damping: 22)

        // 4. Expressive body lean, squash, head & ears
        var targetShiftX: CGFloat = 0
        var targetBodyTilt: CGFloat = 0
        if leftPawOnMouse && !rightPawTyping {
            targetShiftX = -10
            targetBodyTilt = -0.075
        } else if leftPawOnMouse && rightPawTyping {
            targetShiftX = -3
            targetBodyTilt = (rightPaw.point.x - 196) * 0.0008
        } else if leftPawTyping || rightPawTyping {
            let avgX = ((leftPawTyping ? leftPaw.point.x : 184) + (rightPawTyping ? rightPaw.point.x : 184)) * 0.5
            targetShiftX = (avgX - 184) * 0.14
            targetBodyTilt = (avgX - 184) * 0.0011
        }
        bodyShiftX.target = max(-16, min(16, targetShiftX))
        bodyTilt.target = max(-0.12, min(0.12, targetBodyTilt))
        // Coiled low hunting crouch when chasing a fast-moving mouse!
        bodySquash.target = 1.0 - hunt * 0.11
        bodyShiftX.target += overlay.bodyShiftX
        // 逗猫蓄力：扭屁股（高频小幅左右晃）
        bodyShiftX.target += sin(time * 24) * 2.4 * playWiggle
        bodyTilt.target += sin(time * 24) * 0.025 * playWiggle
        bodyTilt.target += overlay.bodyTilt
        bodySquash.target -= overlay.squash
        bodySquash.target -= 0.14 * playStalk // 盯上：压低身子

        headOffsetY.target = (leftPawTyping || rightPawTyping) ? 3.5 : (sleepiness * 5.0 + hunt * 10.5)
        // 听歌点头：每拍向下顿一下（打字时幅度减半，保证不影响看键盘）
        let typingNow = leftPawTyping || rightPawTyping
        // 跳舞时由舞步接管头部上下动作
        headOffsetY.target += beatPulse * music * (typingNow ? 1.6 : 3.4) * (1 - hunt) * (1 - danceAmount)
            * (isAudioQuiet ? 0 : 1)
        headOffsetY.target += overlay.headOffsetY
        headOffsetY.target += tiredness * 3.5 // 没精神：脑袋往下耷拉
        headOffsetY.target += 10 * playStalk
        headOffsetY.target -= 3 * nuzzle // 蹭：脑袋往上顶
        if let age = feedAge, age > 0.5, age < 3.6 { headOffsetY.target += 4 } // 低头啃
        if claudeWaiting && !typingNow {
            // 着急地小跳
            headOffsetY.target -= abs(sin(time * 6)) * 4.5
        }
        earFold.target = max(petHeadIntensity * 0.7, petBodyIntensity * 0.45) + sleepiness * 0.25 - hunt * 0.18
            - (claudeWaiting ? 0.2 : 0)
            + (sweatTimer > 0 ? 0.4 : 0) // 冒汗时耳朵往后背
            + overlay.earFold
            + tiredness * 0.3 // 没精神：耳朵耷拉
            - 0.22 * playStalk // 盯上：耳朵朝前
            + 0.5 * nuzzle     // 蹭的时候耳朵放松
        earTwitch.target = 0

        // 跳舞时弹簧更硬，才跟得上 2Hz 左右的节拍
        // 激烈时弹簧更硬才跟得上节拍；舒缓时保持柔软，动作才"慢悠悠"
        let groove = danceAmount * (0.3 + 0.7 * musicArousal)
        bodyShiftX.step(dt: dt, stiffness: 140 + groove * 260, damping: 18 + groove * 8)
        bodyTilt.step(dt: dt, stiffness: 140 + groove * 260, damping: 18 + groove * 8)
        bodySquash.step(dt: dt, stiffness: 280 + groove * 220, damping: 18 + groove * 6)
        headOffsetY.step(dt: dt, stiffness: 180 + groove * 240, damping: 19 + groove * 6)
        earFold.step(dt: dt, stiffness: 120, damping: 16)
        earTwitch.step(dt: dt, stiffness: 320, damping: 16)

        // 5. 2.5D Head Turning (Yaw + Pitch) + Eye Tracking!
        // Head smoothly turns in pseudo-3D toward the mouse cursor (or subtly nods down toward keys while typing).
        let typingRecently = !activeKeys.isEmpty || (now - curLastKeyTime < 0.65)
        let mouseMovedRecently = (now - curLastMouseMove < 1.2)
        let eyeOriginCanvas = CGPoint(x: CatPhysics.seatAnchor.x + bodyShiftX.value, y: 124 + headOffsetY.value)

        // Compute normalized vector from cat head to real macOS screen cursor
        let scale = max(0.2, windowFrameInScreen.width / CatPhysics.canvasSize.width)
        let headScreenX = windowFrameInScreen.minX + eyeOriginCanvas.x * scale
        let headScreenY = windowFrameInScreen.maxY - eyeOriginCanvas.y * scale
        let cursor = curMouseLoc
        let curDx = (cursor.x - headScreenX) / 290.0
        let curDy = -(cursor.y - headScreenY) / 260.0
        let curMag = hypot(curDx, curDy)
        let clampedCur = min(1.0, curMag)
        let cursorNX = curMag > 0.001 ? (curDx / curMag) * clampedCur : 0
        let cursorNY = curMag > 0.001 ? (curDy / curMag) * clampedCur : 0

        var lookTargetX: CGFloat
        var lookTargetY: CGFloat
        if typingRecently && !mouseMovedRecently, let keyPt = lastTypedPoint {
            let kdx = max(-0.85, min(0.85, (keyPt.x - eyeOriginCanvas.x) / 95.0))
            let kdy = max(-0.3, min(0.92, (keyPt.y - eyeOriginCanvas.y) / 125.0))
            lookTargetX = kdx
            lookTargetY = kdy
        } else if typingRecently && mouseMovedRecently, let keyPt = lastTypedPoint {
            // Blend mouse & typing naturally when gaming with mouse + keyboard!
            let kdx = max(-0.85, min(0.85, (keyPt.x - eyeOriginCanvas.x) / 95.0))
            lookTargetX = cursorNX * 0.72 + kdx * 0.28
            lookTargetY = cursorNY * 0.72 + 0.25
        } else {
            lookTargetX = cursorNX
            lookTargetY = cursorNY
        }

        // Claude 联动的视线：等你时盯着你（正前方），干活时抬头看右上角的思考气泡
        if shushTimer > 0 {
            // 嘘的时候盯着你
            lookTargetX = 0
            lookTargetY = 0.05
        } else if hunt < 0.3 && userIdleForClaude {
            if claudeWaiting {
                lookTargetX = 0
                lookTargetY = 0.05
            } else if claudeWorking {
                // 偶尔低头看一眼键盘，像在等结果
                let glance = sin(time * 0.7) > 0.75
                lookTargetX = glance ? 0.1 : 0.42
                lookTargetY = glance ? 0.5 : -0.62
            }
        }

        // 空闲动作接管视线（东张西望、看尾巴、打哈欠抬头）
        if overlay.overridesGaze {
            lookTargetX = overlay.headYaw
            lookTargetY = overlay.headPitch
        }

        // Head turns smoothly in 2.5D (yaw & pitch) — locks on faster during hunting mode!
        if sleepiness > 0.45 {
            headYaw.target = 0
            headPitch.target = 0.45 * sleepiness
        } else {
            let extraYaw = overlay.overridesGaze ? 0 : overlay.headYaw
            let extraPitch = overlay.overridesGaze ? 0 : overlay.headPitch
            headYaw.target = max(-1.0, min(1.0, lookTargetX + extraYaw))
            headPitch.target = max(-1.0, min(1.0, lookTargetY + extraPitch - (isHoldingProp && isSipping ? 0.18 : 0)))
            if let age = feedAge {
                // 先抬头看鱼掉下来，接住后低头啃
                headYaw.target = 0
                headPitch.target = age < 0.5 ? -0.5 : 0.45
            }
            if let refuse = feedRefuseAge {
                // 吃不下：摇头
                let env = sin(min(1, refuse / 1.4) * .pi)
                headYaw.target = sin(refuse * 16) * 0.5 * env
                headPitch.target = 0.1
            }
        }
        let headStiff: CGFloat = 88 + hunt * 75 + groove * 140 + playStalk * 80
        let headDamp: CGFloat = 14.5 + hunt * 4.5 + groove * 5
        headYaw.step(dt: dt, stiffness: headStiff, damping: headDamp)
        headPitch.step(dt: dt, stiffness: headStiff, damping: headDamp)

        // Subtle natural head roll coupled to head turning (curious tilt / locked-on hunt!)
        if now - lastPetTime > 0.28 {
            headTilt.target = bodyTilt.target * 0.45 + headYaw.value * (0.11 + hunt * 0.05) - headYaw.value * headPitch.value * 0.04
            // 两拍一个来回的左右摇摆
            headTilt.target += sin(beatPhase * 0.5) * 0.075 * music * (1 - hunt) * (1 - danceAmount) * (isAudioQuiet ? 0 : 1)
            headTilt.target += overlay.headTilt
            // 洗脸时脑袋歪向爪子一侧，跟着蹭
            if groomTimer > 0 { headTilt.target += 0.16 + sin(time * 7) * 0.04 }
            // 蹭光标：脑袋歪向光标一侧，来回蹭
            headTilt.target += nuzzle * nuzzleSide * (0.07 + sin(time * 3.2) * 0.045)
        }
        headTilt.step(dt: dt, stiffness: 130 + groove * 150, damping: 16 + groove * 4)

        // Eyes lead slightly ahead of the 2.5D head turn
        eyeGaze.target = CGPoint(x: lookTargetX * 0.88, y: lookTargetY * 0.85)
        eyeGaze.step(dt: dt, stiffness: 210 + hunt * 80, damping: 21)

        // Pupil dilation
        if hindFootActive.value > 0.3 {
            pupilScale.target = 1.24
        } else if claudeWaiting {
            pupilScale.target = 1.22
        } else if playStalk > 0.3 {
            pupilScale.target = 1 + 0.38 * playStalk   // 盯上光标：瞳孔放大
        } else if now - curLastKeyTime > 0.45 && now - curLastMouseClick > 0.45 {
            pupilScale.target = 1.0
        }
        pupilScale.step(dt: dt, stiffness: 150, damping: 18)

        // 6. Blinking (cats lock eyes without blinking during hunting mode!)
        if isBlinking {
            blinkTimer += dt
            let blinkDuration: CGFloat = 0.14
            if blinkTimer >= blinkDuration {
                isBlinking = false
                blinkProgress = 0
                nextBlinkTime = time + CGFloat.random(in: 2.6...5.6)
            } else {
                let p = blinkTimer / blinkDuration
                blinkProgress = sin(p * .pi)
            }
        } else if time >= nextBlinkTime && sleepiness < 0.5 && petHeadIntensity < 0.3 && hunt < 0.35 {
            isBlinking = true
            blinkTimer = 0
        }

        // 7. Tail wag speed reacts organically to energy / petting / hunting tension!
        let kpmBoost = min(2.4, CGFloat(engine.currentKPM) / 160.0)
        let petBoost = max(petHeadIntensity, petBodyIntensity) * 1.4
        let huntBoost = hunt * 2.8
        var tailSpeed: CGFloat = 1.85 + kpmBoost + petBoost + huntBoost - sleepiness * 1.1 + celebration * 3.5
            - tiredness * 0.8 + playStalk * 4 // 蓄力时尾巴尖抽得飞快
        // 听歌时尾巴摆动速度向节拍靠拢（每拍半个周期）
        // 舒缓的歌尾巴摆得更慢（约半速）
        let beatTailSpeed = beatsPerMinute / 60 * .pi * (0.45 + 0.55 * musicArousal)
        tailSpeed += (beatTailSpeed - tailSpeed) * music * 0.7
        tailPhase += dt * tailSpeed

        // 8. Update per-keycap glows
        let visualActive = Set(activeKeys.map { $0.visualKey })
        for (k, v) in keyGlow {
            if visualActive.contains(k) {
                keyGlow[k] = 1.0
            } else {
                let next = v - dt * 4.5
                if next <= 0.01 { keyGlow.removeValue(forKey: k) }
                else { keyGlow[k] = next }
            }
        }
        for vk in visualActive {
            keyGlow[vk] = 1.0
        }

        // 9. Update floating keycaps
        for i in floatingKeycaps.indices.reversed() {
            floatingKeycaps[i].age += dt
            floatingKeycaps[i].position.x += floatingKeycaps[i].velocity.x * dt
            floatingKeycaps[i].position.y += floatingKeycaps[i].velocity.y * dt
            floatingKeycaps[i].velocity.x *= (1.0 - dt * 2.4)
            floatingKeycaps[i].velocity.y *= (1.0 - dt * 1.6)
            if floatingKeycaps[i].age >= floatingKeycaps[i].lifetime {
                floatingKeycaps.remove(at: i)
            }
        }

        // 10. Update purr / sleep particles
        for i in sparkles.indices.reversed() {
            sparkles[i].age += dt
            sparkles[i].position.x += sparkles[i].velocity.x * dt
            sparkles[i].position.y += sparkles[i].velocity.y * dt
            sparkles[i].velocity.y += sparkles[i].gravity * dt
            if sparkles[i].noteGlyph != nil && sparkles[i].gravity == 0 {
                // 音符左右飘
                sparkles[i].position.x += sin(sparkles[i].age * 5 + sparkles[i].noteHue * 6) * 14 * dt
            }
            if sparkles[i].age >= sparkles[i].lifetime {
                sparkles.remove(at: i)
            }
        }
    }

    // MARK: - Music Notes

    /// 每两拍从耳机罩附近冒一个音符；只有音乐播放器才冒（视频/游戏只戴耳机）
    private func spawnMusicNotesIfNeeded() {
        guard !isAudioQuiet else { return }
        guard isListeningToMusicApp, headphonesOn.value > 0.8 else { return }
        let beatIndex = Int(beatPhase / (2 * .pi))
        // 相位校正可能让拍号短暂回退一格，只在拍号前进时才冒音符
        // 舒缓的歌四拍冒一个音符，激烈的两拍一个
        let every = musicArousal < 0.4 ? 4 : 2
        guard beatIndex > lastNoteBeat, beatIndex % every == 0 else { return }
        lastNoteBeat = beatIndex
        let glyphs = ["♪", "♫", "♬", "♩"]
        let fromLeft = (beatIndex / every) % 2 == 0
        let headX = CatPhysics.seatAnchor.x + bodyShiftX.value
        sparkles.append(PurrSparkle(
            position: CGPoint(x: headX + (fromLeft ? -50 : 42), y: 112 + headOffsetY.value),
            velocity: CGPoint(x: fromLeft ? -9 : 9, y: -30),
            lifetime: 1.8,
            isSleepZ: false,
            noteGlyph: glyphs[Int.random(in: 0..<glyphs.count)],
            noteHue: CGFloat.random(in: 0...1)
        ))
        if sparkles.count > 24 { sparkles.removeFirst(sparkles.count - 24) }
    }

    // MARK: - Hearts

    /// 慢眨眼时冒一颗小爱心
    private func spawnHeart() {
        let headX = CatPhysics.seatAnchor.x + bodyShiftX.value
        sparkles.append(PurrSparkle(
            position: CGPoint(x: headX + 30, y: 82 + headOffsetY.value),
            velocity: CGPoint(x: 6, y: -24),
            lifetime: 1.8,
            isSleepZ: false,
            noteGlyph: "♥",
            noteHue: 0.96
        ))
    }

    // MARK: - Confetti

    /// 任务完成：从头顶炸出一把彩带
    private func spawnConfetti() {
        let glyphs = ["●", "■", "▲", "✦", "♥"]
        let headX = CatPhysics.seatAnchor.x + bodyShiftX.value
        for _ in 0..<22 {
            let angle = CGFloat.random(in: (-CGFloat.pi * 0.92)...(-CGFloat.pi * 0.08))
            let speed = CGFloat.random(in: 90...170)
            sparkles.append(PurrSparkle(
                position: CGPoint(x: headX + CGFloat.random(in: -12...12), y: 78),
                velocity: CGPoint(x: cos(angle) * speed, y: sin(angle) * speed),
                lifetime: CGFloat.random(in: 1.3...2.0),
                isSleepZ: false,
                noteGlyph: glyphs[Int.random(in: 0..<glyphs.count)],
                noteHue: CGFloat.random(in: 0...1),
                gravity: 210,
                spin: CGFloat.random(in: -8...8)
            ))
        }
        if sparkles.count > 48 { sparkles.removeFirst(sparkles.count - 48) }
    }
}

/// 两个可选值都有时打包成元组
private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
