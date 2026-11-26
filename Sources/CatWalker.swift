import AppKit
import CoreGraphics

/// 满屏漫游时的侧身小猫：站、走、跑、蹲、腾空、落地、坐。配色沿用当前选中的猫（经典 4 只 + PetSpec）。
/// 画在独立的小画布上（翻转坐标，y 向下），脚底中点固定在 walkerFeet。
extension CatRenderer {
    static let walkerCanvas = CGSize(width: 190, height: 190)
    static let walkerFeet = CGPoint(x: 95, y: 180)
    /// 侧身小猫在屏幕上放大多少倍：让它和坐在键盘前的大头小猫一样大（画布坐标照旧）
    static let walkerArtScale: CGFloat = 1.25

    struct WalkerPose {
        var pose: RoamPose
        /// 步态相位（弧度）
        var phase: CGFloat
        /// 1 = 朝右，-1 = 朝左
        var facing: CGFloat
        /// 跳跃进度 0...1
        var air: CGFloat
        var time: CGFloat
        var blink: Bool
        /// 偷看：扒着哪条屏幕边、脑袋露出来多少
        var peekEdge: RoamEdge? = nil
        var peekReveal: CGFloat = 0
        /// 底边偷看前往下沉的程度 0...1
        var sink: CGFloat = 0
        /// 打盹：0 = 刚趴下，1 = 完全蜷成一团
        var curl: CGFloat = 0
        /// 睡着了：闭眼、呼吸起伏、冒 Zzz
        var asleep = false
        /// 盯上光标：瞳孔放大成圆圆的大黑眼
        var hunting = false
        /// 圣诞季：戴圣诞帽
        var santaHat = false
        /// 举牌提醒：牌子上的字（第一行粗体，第二行小字）
        var signLines: [String] = []
        /// 抖雪的进度 0...1（抖爪子 / 甩身子）
        var shake: CGFloat = 0
        /// 0...1：爪子上沾的雪（爪子发白）
        var pawSnow: CGFloat = 0
        /// 拨爪（把东西拨下桌）的进度 0...1
        var tap: CGFloat = 0
        /// 嘴里叼着的东西
        var trinket: Trinket?
        /// 平滑跑动融合 0...1、移动融合 0...1、蹲跳进度 0...1、落地/急刹进度 0...1、急刹滑行、转身缩放 (-1...1)
        var runBlend: CGFloat? = nil
        var moveBlend: CGFloat? = nil
        var crouchProgress: CGFloat? = nil
        var landProgress: CGFloat? = nil
        var skidding: Bool = false
        var turnScale: CGFloat? = nil
    }

    /// 侧身小猫的配色：从主画面的取色工具里推出来，保证和坐着时是同一只猫
    struct WalkerPalette {
        var body: NSColor
        /// 肚皮（虎斑、双色）
        var belly: NSColor?
        /// 背上和头顶的色块（双色）
        var back: NSColor?
        /// 背上的条纹（虎斑）
        var stripe: NSColor?
        /// 三花的黑色块
        var calico: NSColor?
        /// 重点色的脸（暹罗、布偶）
        var mask: NSColor?
        var legs: NSColor
        var paws: NSColor
        var ears: NSColor
        var tail: NSColor
        var outline: NSColor
        var eye: NSColor
        var earInner: NSColor?
        var cute: Bool
    }

    static func walkerPalette(coat: CatCoatTheme, eyeTheme: EyeColorTheme) -> WalkerPalette {
        let eye = pet?.eyeColor ?? eyeTheme.primaryColor
        let cute = isCute(coat)
        let inner = cute ? HexColor.mix(rgb(0xF4ABAE), earTailColor(coat), 0.22) : nil
        switch coat {
        case .siamese:
            return WalkerPalette(body: siameseCream, belly: nil, back: nil, stripe: nil, calico: nil, mask: siamesePoint,
                                 legs: siamesePoint, paws: siamesePoint, ears: siamesePoint, tail: siamesePoint,
                                 outline: siameseOutline, eye: eye, earInner: siameseInnerEar, cute: false)
        case .shorthair:
            let belly = coatRGB(0xF2EEE4)
            return WalkerPalette(body: bodyColor(coat), belly: belly, back: nil, stripe: coatRGB(0x363536, 0.8), calico: nil,
                                 mask: nil, legs: bodyColor(coat), paws: belly, ears: earTailColor(coat), tail: earTailColor(coat),
                                 outline: cuteOutline(coat), eye: eye, earInner: inner, cute: cute)
        case .orangeWhite:
            let patch = limbColor(coat)
            let white = bodyColor(coat)
            let legs = pet?.whiteLegs == true ? white : patch
            return WalkerPalette(body: white, belly: nil, back: patch, stripe: coatRGB(0xA57543, 0.55),
                                 calico: pet?.tricolor == true ? pet?.accentColor : nil, mask: nil,
                                 legs: legs, paws: pawColor(coat), ears: earTailColor(coat), tail: earTailColor(coat),
                                 outline: cuteOutline(coat), eye: eye, earInner: inner, cute: cute)
        case .classicBlack:
            if pet != nil {
                return WalkerPalette(body: bodyColor(coat), belly: nil, back: nil, stripe: nil, calico: nil, mask: nil,
                                     legs: bodyColor(coat), paws: pawColor(coat), ears: earTailColor(coat), tail: earTailColor(coat),
                                     outline: cuteOutline(coat), eye: eye, earInner: inner, cute: cute)
            }
            return WalkerPalette(body: catBlack, belly: nil, back: nil, stripe: nil, calico: nil, mask: nil,
                                 legs: catBlack, paws: catBlack, ears: catBlack, tail: catBlack,
                                 outline: contourMint.withAlphaComponent(0.55), eye: eye, earInner: nil, cute: false)
        }
    }

    // MARK: Draw

    /// 爬窗框时的画布锚点（窗框上爪子贴着的那一点）：小猫转 90 度后横着占画布，锚点挪到靠窗框的那一侧
    static func climbAnchor(wallOnRight: Bool) -> CGPoint {
        CGPoint(x: wallOnRight ? 182 : 8, y: 92)
    }

    static func drawWalker(in ctx: CGContext, pose: WalkerPose) {
        let settings = CatSettings.shared
        let coat = settings.coatTheme
        refreshActivePet(coat: coat)
        let pal = walkerPalette(coat: coat, eyeTheme: settings.eyeTheme)
        if pose.pose == .climb {
            // 爬窗框：把走路的侧身小猫转 90 度，头朝上、爪子贴着窗框（facing > 0 = 窗框在右边）
            let wallRight = pose.facing > 0
            let anchor = climbAnchor(wallOnRight: wallRight)
            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            if wallRight {
                ctx.rotate(by: -.pi / 2)
            } else {
                ctx.rotate(by: .pi / 2)
                ctx.scaleBy(x: -1, y: 1)
            }
            ctx.translateBy(x: -walkerFeet.x, y: -walkerFeet.y)
            var climbing = pose
            climbing.facing = 1
            drawMovingWalker(in: ctx, pose: climbing, pal: pal)
            ctx.restoreGState()
            return
        }
        if pose.pose == .peek, let edge = pose.peekEdge {
            drawPeek(in: ctx, edge: edge, reveal: pose.peekReveal, pose: pose, pal: pal)
            return
        }
        ctx.saveGState()
        // 底边偷看前：整只猫往下沉，屏幕底边以下不画
        if pose.sink > 0 {
            ctx.clip(to: CGRect(x: 0, y: 0, width: walkerCanvas.width, height: walkerFeet.y))
            ctx.translateBy(x: 0, y: pose.sink * 110)
        }
        switch pose.pose {
        case .sit:
            if pose.facing < 0 {
                ctx.translateBy(x: walkerCanvas.width, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            drawGroundShadow(in: ctx, centerX: walkerFeet.x - 4, feetY: walkerFeet.y, width: 64, airLift: 0,
                             alpha: 0.14 * max(0, 1 - pose.sink))
            drawSittingWalker(in: ctx, pose: pose, pal: pal)
        case .sign:
            if pose.facing < 0 {
                ctx.translateBy(x: walkerCanvas.width, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            drawGroundShadow(in: ctx, centerX: walkerFeet.x - 4, feetY: walkerFeet.y, width: 64, airLift: 0,
                             alpha: 0.14 * max(0, 1 - pose.sink))
            drawSittingWalker(in: ctx, pose: pose, pal: pal)
            drawSignStick(in: ctx, pose: pose, pal: pal)
        case .curl:
            if pose.facing < 0 {
                ctx.translateBy(x: walkerCanvas.width, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            drawGroundShadow(in: ctx, centerX: walkerFeet.x - 8, feetY: walkerFeet.y, width: 78, airLift: 0,
                             alpha: 0.14 * max(0, 1 - pose.sink))
            drawCurledWalker(in: ctx, pose: pose, pal: pal)
        default:
            // 平滑转身：绕脚底中心水平缩放过渡，永不为 0
            let rawTurn = pose.turnScale ?? pose.facing
            let sign: CGFloat = rawTurn >= 0 ? 1 : -1
            let mag = max(0.22, min(1, abs(rawTurn)))
            ctx.translateBy(x: walkerFeet.x, y: -(1 - mag) * 4)
            ctx.scaleBy(x: sign * mag, y: 1)
            ctx.translateBy(x: -walkerFeet.x, y: 0)
            drawMovingWalker(in: ctx, pose: pose, pal: pal)
        }
        ctx.restoreGState()
        // 牌子上的字不跟着朝向翻转
        if pose.pose == .sign {
            drawSignBoard(in: ctx, pose: pose)
        }
        // Zzz 不跟着朝向翻转（字母不能镜像）
        if pose.pose == .curl && pose.asleep {
            let head = curledHeadCenter(curl: pose.curl)
            let x = pose.facing < 0 ? walkerCanvas.width - head.x : head.x
            // 从头顶前上方飘出来，躲开耳朵
            drawSleepZs(in: ctx, from: CGPoint(x: x + pose.facing * 18, y: head.y - 44), facing: pose.facing, time: pose.time)
        }
    }

    /// 地面接触影：腾空时变窄变淡，增加跃动纵深感
    private static func drawGroundShadow(in ctx: CGContext, centerX: CGFloat, feetY: CGFloat, width: CGFloat,
                                         airLift: CGFloat, alpha: CGFloat) {
        guard alpha > 0.005 else { return }
        let w = width * max(0.45, 1 - airLift * 0.016)
        let h: CGFloat = 9.5 * max(0.55, 1 - airLift * 0.02)
        let a = alpha * max(0.35, 1 - airLift * 0.035)
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: a).cgColor)
        ctx.fillEllipse(in: CGRect(x: centerX - w / 2, y: feetY - h * 0.55, width: w, height: h))
        ctx.restoreGState()
    }

    private static func drawMovingWalker(in ctx: CGContext, pose: WalkerPose, pal: WalkerPalette) {
        let feet = walkerFeet
        let ground = feet.y
        let widthK = CGFloat(pet?.shape.bodyWidth ?? 1).squareRoot()
        let bodyLen: CGFloat = 27.5 * widthK
        let baseH: CGFloat = 22.0
        let baseLift: CGFloat = 38.0
        let p = pose.phase
        let t = pose.time

        let rBlend = max(0, min(1, pose.runBlend ?? (pose.pose == .run ? 1 : 0)))
        let mBlend = max(0, min(1, pose.moveBlend ?? ([.walk, .run, .stalk].contains(pose.pose) ? 1 : 0)))
        let cProg = max(0, min(1, pose.crouchProgress ?? (pose.pose == .crouch ? 1 : 0)))
        let lProg = max(0, min(1, pose.landProgress ?? (pose.pose == .land ? 0.35 : 0)))

        let cycle = p / (2 * .pi)
        let u = cycle - floor(cycle)

        var lift = baseLift
        var tilt: CGFloat = 0
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var arch: CGFloat = 0
        var airLift: CGFloat = 0
        var earPin: CGFloat = 0

        let walkLift = baseLift + abs(sin(p)) * 2.6 * mBlend
        let walkTilt = sin(p * 2) * 0.03 * mBlend
        let walkSX = 1 - cos(p * 2) * 0.02 * mBlend
        let walkSY = 1 + cos(p * 2) * 0.025 * mBlend

        let runAir = pow(max(0, sin(2 * .pi * u + 0.08)), 1.15) * 13.5
        let stretchWave = cos(2 * .pi * (u - 0.22))
        let runSX = 1 + 0.11 * stretchWave
        let runSY = 1 - 0.075 * stretchWave
        let runTilt = -0.14 * cos(2 * .pi * (u - 0.02))
        let runArch = max(0, -stretchWave) * 5.5
        let runLift = 37.5 + runAir - max(0, -stretchWave) * 3.5
        switch pose.pose {
        case .stand, .sit, .peek, .curl, .sign:
            let breath = sin(t * 2.2)
            lift = baseLift + breath * 0.6
            scaleY = 1 + breath * 0.02
            scaleX = 1 - breath * 0.015
        case .walk, .run:
            lift = walkLift + (runLift - walkLift) * rBlend
            tilt = walkTilt + (runTilt - walkTilt) * rBlend
            scaleX = walkSX + (runSX - walkSX) * rBlend
            scaleY = walkSY + (runSY - walkSY) * rBlend
            arch = runArch * rBlend
            airLift = runAir * rBlend
            earPin = (0.26 + 0.06 * stretchWave) * rBlend
        case .crouch:
            let e = cProg * cProg * (3 - 2 * cProg)
            lift = baseLift - 9.0 * e
            scaleX = 1 + 0.11 * e
            scaleY = 1 - 0.15 * e
            tilt = 0.06 * e
        case .air:
            tilt = (pose.air - 0.45) * 0.62
            scaleX = 1.12
            scaleY = 0.90
            lift = 42.0
            earPin = 0.18
        case .land:
            if pose.skidding {
                let e = sin(.pi * pow(lProg, 0.75))
                tilt = -0.18 * e
                lift = baseLift - 6.5 * e
                scaleX = 1 + 0.08 * e
                scaleY = 1 - 0.10 * e
                earPin = 0.22 * e
            } else {
                let sq = sin(.pi * min(1, lProg * 1.45)) * (1 - lProg * 0.55)
                lift = baseLift - 7.5 * sq
                scaleX = 1 + 0.12 * sq
                scaleY = 1 - 0.13 * sq
            }
        case .stalk:
            lift = 29.0 + sin(p * 2) * 0.7
            scaleX = 1.07
            scaleY = 0.93
            tilt = 0.05
            earPin = 0.22
        case .wiggle:
            lift = 28.0
            scaleX = 1.04
            scaleY = 0.95
            tilt = 0.09
            earPin = 0.24
        case .climb:
            lift = 28.0 + sin(p * 2) * 1.1
            scaleX = 1.08
            scaleY = 0.94
        case .pawShake:
            tilt = -0.04 * sin(.pi * pose.shake)
        case .bodyShake:
            let env = sin(.pi * pose.shake)
            tilt = sin(t * 34) * 0.07 * env
            lift += abs(sin(t * 34)) * 1.6 * env
        case .knockTap:
            tilt = 0.05 * sin(.pi * pose.tap)
        }
        if pose.pose != .air && pose.pose != .climb {
            drawGroundShadow(in: ctx, centerX: feet.x - 4, feetY: ground, width: 64 * widthK * scaleX,
                             airLift: airLift, alpha: 0.15 * max(0, 1 - pose.sink))
        }
        drawRunEffects(in: ctx, feet: feet, centerY: ground - lift, u: u, runBlend: rBlend,
                       skidding: pose.skidding, landProgress: lProg, isClimb: pose.pose == .climb)

        let bodyH = baseH * scaleY
        let halfLen = bodyLen * scaleX
        let center = CGPoint(x: feet.x - 4, y: ground - lift)

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: tilt)

        // 圆润饱满 Q 版豆豆躯干：软曲线脊柱 + 圆胸 + 圆屁股
        let torso: CGPath
        if arch > 0.1 {
            let spine = CGMutablePath()
            spine.move(to: CGPoint(x: -halfLen, y: 0))
            spine.addCurve(to: CGPoint(x: halfLen, y: 0),
                           control1: CGPoint(x: -halfLen, y: -bodyH * 1.32 - arch),
                           control2: CGPoint(x: halfLen, y: -bodyH * 1.32 - arch))
            spine.addCurve(to: CGPoint(x: -halfLen, y: 0),
                           control1: CGPoint(x: halfLen, y: bodyH * 1.28 - arch * 0.65),
                           control2: CGPoint(x: -halfLen, y: bodyH * 1.28 - arch * 0.65))
            spine.closeSubpath()
            torso = spine
        } else {
            torso = CGPath(roundedRect: CGRect(x: -halfLen, y: -bodyH, width: halfLen * 2, height: bodyH * 2),
                           cornerWidth: bodyH, cornerHeight: bodyH, transform: nil)
        }
        let spread = rBlend * stretchWave * 2.5
        let chestRect = CGRect(x: halfLen * 0.24 + spread, y: -bodyH * 0.94, width: halfLen * 0.92, height: bodyH * 1.88)
        let chest = CGPath(ellipseIn: chestRect, transform: nil)
        let wiggleX = pose.pose == .wiggle ? sin(t * 16) * 3.5 : 0
        let wiggleUp: CGFloat = pose.pose == .wiggle ? 6.5 : 0
        let haunchRect = CGRect(x: -halfLen * 1.06 - spread + wiggleX, y: -bodyH * 0.90 - arch * 0.4 - wiggleUp,
                                width: halfLen * 1.02, height: bodyH * 1.94)
        let haunch = CGPath(ellipseIn: haunchRect, transform: nil)
        let bodyParts = [torso, chest, haunch]

        // 关节藏在身体内部，保证接缝自然融合
        let shoulder = CGPoint(x: chestRect.midX + 1.5, y: chestRect.midY + 3)
        let hip = CGPoint(x: haunchRect.midX + 1.5, y: haunchRect.midY + 2)
        let groundY = lift / max(0.6, cos(tilt))
        let limb = CGFloat(pet?.shape.limbWidth ?? 1).squareRoot()

        /// 4 拍不滑步步态：支撑期脚掌贴地从 +amp 线性后推到 -amp，摆动期自然抬起前摆
        func walkStep(_ joint: CGPoint, phaseOffset: CGFloat, front: Bool, strideAmp: CGFloat,
                      liftH: CGFloat) -> (end: CGPoint, fold: CGFloat) {
            let cyc = (p + phaseOffset) / (2 * .pi)
            let c = cyc - floor(cyc)
            let baseX = joint.x + (front ? 2 : -1)
            if c < 0.60 {
                let s = c / 0.60
                let dx = strideAmp * (1 - 2 * s)
                return (CGPoint(x: baseX + dx, y: groundY), 0)
            } else {
                let s = (c - 0.60) / 0.40
                let dx = -strideAmp + 2 * strideAmp * (0.5 - 0.5 * cos(.pi * s))
                let liftY = sin(.pi * s) * liftH
                return (CGPoint(x: baseX + dx, y: groundY - liftY), sin(.pi * s) * 0.45)
            }
        }

        /// 轻快跃动飞奔腿：前腿往前探再蹬后，后腿往后踢再收回肚子底下，前后分区绝不打结交叉
        func runStep(_ joint: CGPoint, front: Bool, near: Bool) -> (end: CGPoint, fold: CGFloat) {
            let vRaw = u + (near ? 0 : 0.06)
            let v = vRaw - floor(vRaw)
            if front {
                let dx: CGFloat
                let liftY: CGFloat
                let fold: CGFloat
                if v < 0.48 {
                    let s = v / 0.48
                    dx = 5 + 12 * sin(.pi * min(1, s * 0.72))
                    liftY = sin(.pi * s) * 14
                    fold = sin(.pi * s) * 0.35
                } else if v < 0.84 {
                    let s = (v - 0.48) / 0.36
                    dx = 13 - 16 * s
                    liftY = 0
                    fold = 0
                } else {
                    let s = (v - 0.84) / 0.16
                    dx = -3 + 8 * s
                    liftY = sin(.pi * 0.5 * s) * 8
                    fold = 0.5 * s
                }
                return (CGPoint(x: joint.x + dx, y: groundY - liftY), fold)
            } else {
                let dx: CGFloat
                let liftY: CGFloat
                let fold: CGFloat
                if v < 0.14 {
                    let s = v / 0.14
                    dx = -8 - 9 * s
                    liftY = s * 6
                    fold = 0.1 * s
                } else if v < 0.52 {
                    let s = (v - 0.14) / 0.38
                    dx = -17 + 7 * s
                    liftY = 6 + sin(.pi * s) * 10
                    fold = 0.25 * sin(.pi * s)
                } else if v < 0.68 {
                    let s = (v - 0.52) / 0.16
                    dx = -10 + 15 * s
                    liftY = 6 * (1 - s)
                    fold = 0.55 * (1 - s)
                } else {
                    let s = (v - 0.68) / 0.32
                    dx = 5 - 13 * s
                    liftY = 0
                    fold = 0
                }
                return (CGPoint(x: joint.x + dx, y: groundY - liftY), fold)
            }
        }

        func legEndAndFold(_ joint: CGPoint, offset: CGFloat, front: Bool, near: Bool) -> (end: CGPoint, fold: CGFloat) {
            switch pose.pose {
            case .air:
                let dx: CGFloat = front ? (near ? 14 : 10) : (near ? -14 : -10)
                return (CGPoint(x: joint.x + dx, y: groundY - 6), 0.15)
            case .land where pose.skidding:
                let dx: CGFloat = front ? (near ? 15 : 11) : (near ? 7 : 4)
                return (CGPoint(x: joint.x + dx, y: groundY), front ? 0 : 0.2)
            case .climb:
                let c = sin(p + offset)
                if front {
                    let reach = 0.5 + 0.5 * c
                    let lift = max(0, cos(p + offset)) * 5
                    return (CGPoint(x: joint.x + 10 + reach * 28, y: groundY - lift), 0)
                }
                return (CGPoint(x: joint.x - 2 + c * 9, y: groundY), 0.8)
            case .stalk:
                let phaseOff: CGFloat = front ? (near ? 0 : .pi) : (near ? 1.5 * .pi : 0.5 * .pi)
                return walkStep(joint, phaseOffset: phaseOff, front: front, strideAmp: 5.5, liftH: 3.0)
            case .walk, .run:
                let phaseOff: CGFloat = front ? (near ? 0 : .pi) : (near ? 1.5 * .pi : 0.5 * .pi)
                let w = walkStep(joint, phaseOffset: phaseOff, front: front, strideAmp: 9.5 * mBlend, liftH: 7.5 * mBlend)
                if rBlend < 0.01 { return w }
                let r = runStep(joint, front: front, near: near)
                let ex = w.end.x + (r.end.x - w.end.x) * rBlend
                let ey = w.end.y + (r.end.y - w.end.y) * rBlend
                return (CGPoint(x: ex, y: ey), w.fold + (r.fold - w.fold) * rBlend)
            case .knockTap where front && near:
                let reach = sin(.pi * pose.tap)
                let raise = max(0, sin(.pi * min(1, pose.tap * 2)))
                return (CGPoint(x: joint.x + 5 + 32 * reach, y: groundY - 9 * raise), 0.5 * raise)
            case .pawShake where front && near:
                let env = sin(.pi * min(1, pose.shake * 1.15))
                let flick = sin(t * 42) * env
                return (CGPoint(x: joint.x + 9 + flick * 4, y: groundY - 20 * env + cos(t * 42) * 2 * env), 0.75 * env)
            default:
                let dx: CGFloat = front ? (near ? 3.5 : 0.5) : (near ? -1.5 : -4.5)
                return (CGPoint(x: joint.x + dx, y: groundY), 0)
            }
        }

        /// Q 版圆润小短腿 + 无接缝小面包爪
        func leg(_ joint: CGPoint, _ end: CGPoint, front: Bool, fold: CGFloat = 0) -> (limb: CGPath, paw: CGPath) {
            let mid = CGPoint(x: (joint.x + end.x) / 2, y: (joint.y + end.y) / 2)
            let bend: CGFloat = front ? 2.5 + 8 * fold : -6 - 7 * fold
            let control = CGPoint(x: mid.x + bend, y: mid.y)
            let w0 = (front ? 14.5 : 16.5) * limb, w1 = 10.2 * limb
            let path = taperedLimb(from: joint, control: control, to: CGPoint(x: end.x, y: end.y - 3.2),
                                   startWidth: w0, endWidth: w1)
            let pw = 13.0 * limb
            let paw = CGPath(ellipseIn: CGRect(x: end.x - pw * 0.40, y: end.y - 7.5, width: pw, height: 8.2), transform: nil)
            return (path, paw)
        }

        func fillLeg(_ l: (limb: CGPath, paw: CGPath), far: Bool) {
            let shade: CGFloat = far ? 0.16 : 0
            ctx.setFillColor(HexColor.mix(pal.legs, .black, shade).cgColor)
            ctx.addPath(l.limb); ctx.fillPath()
            let paws = pose.pawSnow > 0.01 ? HexColor.mix(pal.paws, .white, pose.pawSnow * 0.75) : pal.paws
            ctx.setFillColor(HexColor.mix(paws, .black, shade).cgColor)
            ctx.addPath(l.paw); ctx.fillPath()
        }

        func makeLeg(_ joint: CGPoint, top: CGPoint, offset: CGFloat, front: Bool, near: Bool) -> (limb: CGPath, paw: CGPath) {
            let target = legEndAndFold(joint, offset: offset, front: front, near: near)
            return leg(top, target.end, front: front, fold: target.fold)
        }
        let farFront = makeLeg(CGPoint(x: shoulder.x - 4, y: shoulder.y), top: CGPoint(x: shoulder.x - 4, y: shoulder.y - 2),
                               offset: .pi, front: true, near: false)
        let farHind = makeLeg(CGPoint(x: hip.x + 4, y: hip.y), top: CGPoint(x: hip.x + 4, y: hip.y - 2),
                              offset: 0, front: false, near: false)
        for l in [farFront, farHind] {
            fillLeg(l, far: true)
            strokeOuterOutline(in: ctx, [l.limb, l.paw], color: pal.outline, width: 1.4, alsoOutside: bodyParts)
        }

        // 流动 S 形小尾巴：走路翘起轻摆，跑步往后拉出柔和波浪，俯身狩猎时尾尖抽动
        let hunting = pose.pose == .stalk || pose.pose == .wiggle
        let shakeEnv = pose.pose == .bodyShake ? sin(.pi * pose.shake) : 0
        let sway = hunting ? sin(t * 18) * 6.5
            : sin(t * 3.0 + p * 0.45) * 5.5 + sin(t * 34 - 1.2) * 8.5 * shakeEnv
        let tailRoot = CGPoint(x: -halfLen * 0.90 + wiggleX, y: -bodyH * 0.28 - wiggleUp)
        let tailUp: CGFloat = pose.pose == .air ? 0.45 : (hunting ? 0.25 : (pose.pose == .climb ? 0.1 : 1))
        let w1 = sin(p - 0.5) * 6.0
        let w2 = sin(p - 1.6) * 8.0
        let standTip = CGPoint(x: -halfLen - 17 + sway * 0.35, y: -bodyH - 27 * tailUp + sway * 0.3)
        let standC1 = CGPoint(x: tailRoot.x - 16, y: tailRoot.y + 4)
        let standC2 = CGPoint(x: standTip.x - 9 + sway, y: standTip.y + 14)
        let runTip = CGPoint(x: -halfLen - 34, y: -bodyH * 0.72 + w2)
        let runC1 = CGPoint(x: tailRoot.x - 13, y: tailRoot.y - 5 - w1 * 0.5)
        let runC2 = CGPoint(x: runTip.x + 15, y: runTip.y - w2 * 0.65)
        func lerpPt(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
        }
        let tail = CGMutablePath()
        tail.move(to: tailRoot)
        tail.addCurve(to: lerpPt(standTip, runTip, rBlend),
                      control1: lerpPt(standC1, runC1, rBlend),
                      control2: lerpPt(standC2, runC2, rBlend))
        let tailW = 9.0 * CGFloat(pet?.shape.tailWidth ?? 1)
        let tailShape = tail.copy(strokingWithWidth: tailW, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.setFillColor(pal.tail.cgColor)
        ctx.addPath(tailShape); ctx.fillPath()

        // 近侧两条腿：先画，身体盖住腿的上端，接缝融进身体
        let nearHind = makeLeg(hip, top: hip, offset: .pi, front: false, near: true)
        let nearFront = makeLeg(shoulder, top: shoulder, offset: 0, front: true, near: true)
        fillLeg(nearHind, far: false)
        fillLeg(nearFront, far: false)

        // 身体（三块合起来填色，花纹裁在里面）
        let body = CGMutablePath()
        for part in bodyParts { body.addPath(part) }
        ctx.setFillColor(pal.body.cgColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        if let back = pal.back {
            // 双色：背上一大块，胸口和肚皮留白
            ctx.setFillColor(back.cgColor)
            ctx.fillEllipse(in: CGRect(x: -halfLen * 1.25, y: -bodyH * 1.6, width: halfLen * 2.0, height: bodyH * 2.15))
        }
        if let calico = pal.calico {
            ctx.setFillColor(calico.cgColor)
            ctx.fillEllipse(in: CGRect(x: -halfLen * 0.2, y: -bodyH * 1.3, width: halfLen * 0.8, height: bodyH * 1.2))
        }
        if let belly = pal.belly {
            ctx.setFillColor(belly.cgColor)
            ctx.fillEllipse(in: CGRect(x: -halfLen * 0.75, y: bodyH * 0.15, width: halfLen * 1.9, height: bodyH * 1.4))
        }
        if let stripe = pal.stripe {
            ctx.setStrokeColor(stripe.cgColor)
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            for i in 0..<4 {
                let x = -halfLen * 0.55 + CGFloat(i) * halfLen * 0.36
                ctx.move(to: CGPoint(x: x - 2, y: -bodyH - 1))
                ctx.addQuadCurve(to: CGPoint(x: x + 3, y: -bodyH * 0.15), control: CGPoint(x: x + 4, y: -bodyH * 0.7))
            }
            ctx.strokePath()
        }
        if pet?.shape.wavyCoat == true {
            ctx.setStrokeColor(pal.outline.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1.1)
            for (x, y) in [(-0.5, -0.3), (-0.1, 0.1), (0.3, -0.4), (0.45, 0.25), (-0.4, 0.35)] as [(CGFloat, CGFloat)] {
                let c = CGPoint(x: x * halfLen, y: y * bodyH)
                ctx.move(to: CGPoint(x: c.x - 5, y: c.y))
                ctx.addQuadCurve(to: c, control: CGPoint(x: c.x - 2.5, y: c.y - 2.6))
                ctx.addQuadCurve(to: CGPoint(x: c.x + 5, y: c.y), control: CGPoint(x: c.x + 2.5, y: c.y + 2.6))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
        // 只描身体 + 近侧腿合起来的外轮廓：腿和身体之间没有接缝线
        strokeOuterOutline(in: ctx, bodyParts + [tailShape, nearHind.limb, nearHind.paw, nearFront.limb, nearFront.paw],
                           color: pal.outline, width: 1.5)
        // 爪子上的两道趾缝
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.9)
        for l in [nearHind, nearFront] {
            let r = l.paw.boundingBox
            for dx: CGFloat in [0.38, 0.62] {
                ctx.move(to: CGPoint(x: r.minX + r.width * dx + 1, y: r.maxY - 0.5))
                ctx.addLine(to: CGPoint(x: r.minX + r.width * dx + 1, y: r.maxY - 3.5))
            }
        }
        ctx.strokePath()

        // 头：Q 版 3/4 大头，跑步时稳稳平视、略微压低并伴随微弱弹性滞后
        let nod = (pose.pose == .walk ? -sin(p * 2) * 1.1 * mBlend : 0) + rBlend * (-sin(2 * .pi * u) * 1.8)
        let headCenter: CGPoint
        if hunting || pose.pose == .climb {
            headCenter = CGPoint(x: halfLen * 0.72 + 12, y: -bodyH - 8)
        } else {
            let baseHead = CGPoint(x: halfLen * 0.68 + 8, y: -bodyH - 16 + nod)
            let runHead = CGPoint(x: halfLen * 0.74 + 10, y: -bodyH - 13 - arch * 0.25 + nod)
            headCenter = lerpPt(baseHead, runHead, rBlend)
        }
        let bodyCTM = ctx.ctm
        ctx.saveGState()
        ctx.translateBy(x: headCenter.x, y: headCenter.y)
        let headCounter = (rBlend > 0.05 || hunting || pose.skidding) ? -tilt * 0.72 : 0
        ctx.rotate(by: headCounter + sin(t * 34 + 0.7) * 0.28 * shakeEnv)
        drawWalkerHead(in: ctx, center: .zero, pose: pose, pal: pal, lookDown: pose.pose == .crouch,
                       earPin: earPin, squint: pose.skidding,
                       fuse: bodyParts, fuseCTM: bodyCTM)
        ctx.restoreGState()
        if shakeEnv > 0.05 {
            drawShakeLines(in: ctx, head: headCenter, body: CGSize(width: halfLen, height: bodyH), env: shakeEnv,
                           color: pal.outline)
        }
        ctx.restoreGState()
    }

    /// 奔跑烟尘、速度微风线与急刹滑行小烟团
    private static func drawRunEffects(in ctx: CGContext, feet: CGPoint, centerY: CGFloat, u: CGFloat,
                                       runBlend: CGFloat, skidding: Bool, landProgress: CGFloat, isClimb: Bool) {
        guard !isClimb else { return }
        ctx.saveGState()
        if runBlend > 0.35 {
            let alpha = min(1, (runBlend - 0.35) / 0.65)
            for i in 0..<3 {
                let local = (u + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let a = sin(local * .pi) * 0.55 * alpha
                guard a > 0.03 else { continue }
                let x = feet.x - 26 - local * 28
                let y = feet.y - 4 - local * 10 - CGFloat(i % 2) * 3
                let r = 3.2 + local * 3.8
                ctx.setFillColor(NSColor(calibratedWhite: 0.99, alpha: a).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r * 0.85, width: r * 2, height: r * 1.7))
                ctx.setStrokeColor(rgb(0xB8C0CE, a * 0.45).cgColor)
                ctx.setLineWidth(0.9)
                ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r * 0.85, width: r * 2, height: r * 1.7))
            }
            if runBlend > 0.60 {
                let wAlpha = min(1, (runBlend - 0.60) / 0.40) * 0.42
                ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: wAlpha).cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                for (dy, len, phaseOff) in [(-34.0, 22.0, 0.0), (-14.0, 17.0, 0.4)] as [(CGFloat, CGFloat, CGFloat)] {
                    let s = (u + phaseOff).truncatingRemainder(dividingBy: 1)
                    let x0 = feet.x - 42 - s * 16
                    let y0 = centerY + dy
                    ctx.move(to: CGPoint(x: x0, y: y0))
                    ctx.addLine(to: CGPoint(x: x0 - len, y: y0))
                }
                ctx.strokePath()
            }
        }
        if skidding && landProgress > 0.02 {
            let fade = sin(.pi * min(1, landProgress))
            for i in 0..<4 {
                let fi = CGFloat(i)
                let x = feet.x + 20 + fi * 6 + landProgress * (8 + fi * 3)
                let y = feet.y - 3 - fi * 3.5 - landProgress * 6
                let r = (3.5 + fi * 0.8) * (0.7 + landProgress * 0.7)
                ctx.setFillColor(NSColor(calibratedWhite: 0.99, alpha: 0.65 * fade).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r * 0.85, width: r * 2, height: r * 1.7))
                ctx.setStrokeColor(rgb(0xB8C0CE, 0.35 * fade).cgColor)
                ctx.setLineWidth(0.9)
                ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r * 0.85, width: r * 2, height: r * 1.7))
            }
        }
        ctx.restoreGState()
    }

    /// 甩身子的漫画速度线：头两侧、背上几道短弧，表示甩得很快
    /// - Parameter body: 半身长 × 身体半高（身体坐标）
    private static func drawShakeLines(in ctx: CGContext, head: CGPoint, body: CGSize, env: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.6 * env).cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        func arc(_ center: CGPoint, _ radius: CGFloat, _ angles: ClosedRange<CGFloat>) {
            ctx.addArc(center: center, radius: radius, startAngle: angles.lowerBound, endAngle: angles.upperBound,
                       clockwise: false)
            ctx.strokePath()
        }
        arc(head, 36, -0.5...0.2)                 // 头前面
        arc(head, 43, -0.4...0.1)
        arc(head, 38, (.pi + 0.45)...(.pi + 0.95))  // 头后上方
        arc(CGPoint(x: -body.width * 0.3, y: 0), body.height + 11, (-.pi * 0.74)...(-.pi * 0.54))   // 背上
        ctx.restoreGState()
    }

    /// 3/4 视角 Q 版大头：圆润饱满无凸出嘴筒，看得见两只大眼睛、粉鼻子、ω 嘴与两只耳朵
    /// - Parameters:
    ///   - fuse: 头要和哪些身体部件融为一体（在 fuseCTM 那个坐标系下）：头的轮廓线不画在它们上面
    private static func drawWalkerHead(in ctx: CGContext, center: CGPoint, pose: WalkerPose, pal: WalkerPalette, lookDown: Bool,
                                       earPin: CGFloat = 0, squint: Bool = false,
                                       fuse: [CGPath] = [], fuseCTM: CGAffineTransform = .identity) {
        let hs = CGFloat(pet?.shape.headSize ?? 1)
        let r: CGFloat = 30.5 * hs * CGFloat(pet?.shape.headWidth ?? 1).squareRoot()
        let faceX = r * 0.28
        let earSize = CGFloat(pet?.shape.earSize ?? 1)
        let flare = CGFloat(pet?.shape.earFlare ?? 0)
        let earStyle = pet?.shape.earStyle ?? .pointed
        let folded = earStyle == .folded
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: lookDown ? 0.22 : 0)
        var toLocal = fuseCTM.concatenating(ctx.ctm.inverted())
        let fuseLocal = fuse.compactMap { $0.copy(using: &toLocal) }

        /// 3/4 视角两只耳朵：远侧在前右微透视、近侧在后左，跑步时顺势向后压低 (earPin)
        func ear(far: Bool) -> CGPath {
            let len = r * 0.88 * earSize * (folded ? 0.48 : (earStyle == .round ? 0.78 : 1))
            let baseAng: CGFloat = far ? (0.28 + flare * 0.55) : (-0.28 - flare * 0.65)
            let ang = baseAng - earPin * (far ? 0.85 : 0.95) + (folded ? (far ? 0.55 : -0.55) : 0)
            let sw = earSize.squareRoot() * (far ? 0.86 : 1.0)
            let b1 = far ? CGPoint(x: r * 0.06, y: -r * 0.76) : CGPoint(x: -r * 0.80, y: -r * 0.42)
            let b2 = far ? CGPoint(x: b1.x + r * 0.62 * sw, y: -r * 0.54) : CGPoint(x: b1.x + r * 0.66 * sw, y: -r * 0.82)
            let mid = CGPoint(x: (b1.x + b2.x) / 2, y: (b1.y + b2.y) / 2)
            let tip = CGPoint(x: mid.x + sin(ang) * len, y: mid.y - cos(ang) * len)
            let path = CGMutablePath()
            path.move(to: b1)
            let roundness: CGFloat = earStyle == .round ? 5 : 2
            path.addQuadCurve(to: tip, control: CGPoint(x: (b1.x + tip.x) / 2 - roundness, y: (b1.y + tip.y) / 2))
            path.addQuadCurve(to: b2, control: CGPoint(x: (b2.x + tip.x) / 2 + roundness + 1, y: (b2.y + tip.y) / 2))
            path.closeSubpath()
            let color = far ? HexColor.mix(pal.ears, .black, 0.14) : pal.ears
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path); ctx.fillPath()
            if let inner = pal.earInner, !folded {
                let i1 = CGPoint(x: b1.x + (tip.x - b1.x) * 0.22 + 2, y: b1.y + (tip.y - b1.y) * 0.22)
                let i2 = CGPoint(x: b2.x + (tip.x - b2.x) * 0.22 - 2, y: b2.y + (tip.y - b2.y) * 0.22)
                let it = CGPoint(x: mid.x + (tip.x - mid.x) * 0.78, y: mid.y + (tip.y - mid.y) * 0.78)
                ctx.setFillColor((far ? HexColor.mix(inner, .black, 0.10) : inner).cgColor)
                ctx.move(to: i1); ctx.addLine(to: it); ctx.addLine(to: i2); ctx.closePath(); ctx.fillPath()
            }
            return path
        }
        let farEar = ear(far: true)
        let nearEar = ear(far: false)

        // 脑袋：圆润饱满微扁椭圆（德文微楔形下巴），去掉突兀侧脸嘴筒
        let skull: CGPath
        if pet?.shape.headShape == .wedge {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: -r * 0.90))
            p.addCurve(to: CGPoint(x: r * 1.06, y: -r * 0.08),
                       control1: CGPoint(x: r * 0.62, y: -r * 0.90), control2: CGPoint(x: r * 1.06, y: -r * 0.56))
            p.addCurve(to: CGPoint(x: faceX * 0.25, y: r * 0.94),
                       control1: CGPoint(x: r * 1.04, y: r * 0.45), control2: CGPoint(x: r * 0.56, y: r * 0.94))
            p.addCurve(to: CGPoint(x: -r * 1.04, y: -r * 0.08),
                       control1: CGPoint(x: -r * 0.52, y: r * 0.94), control2: CGPoint(x: -r * 1.04, y: r * 0.45))
            p.addCurve(to: CGPoint(x: 0, y: -r * 0.90),
                       control1: CGPoint(x: -r * 1.04, y: -r * 0.56), control2: CGPoint(x: -r * 0.62, y: -r * 0.90))
            p.closeSubpath()
            skull = p
        } else {
            skull = CGPath(ellipseIn: CGRect(x: -r * 1.06, y: -r * 0.94, width: r * 2.12, height: r * 1.88), transform: nil)
        }
        ctx.setFillColor(pal.body.cgColor)
        ctx.addPath(skull); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(skull); ctx.clip()
        if let back = pal.back {
            ctx.setFillColor(back.cgColor)
            ctx.fill(CGRect(x: -r * 1.2, y: -r * 1.2, width: r * 2.4, height: r * 2.4))
            ctx.setFillColor(pal.body.cgColor)
            if pet?.whiteFace == true {
                let m = CGMutablePath()
                m.move(to: CGPoint(x: faceX, y: -r * 0.92))
                m.addLine(to: CGPoint(x: faceX + r * 0.14, y: -r * 0.30))
                m.addQuadCurve(to: CGPoint(x: r * 1.15, y: r * 0.46), control: CGPoint(x: faceX + r * 0.52, y: -r * 0.04))
                m.addLine(to: CGPoint(x: r * 1.15, y: r * 1.15)); m.addLine(to: CGPoint(x: -r * 1.15, y: r * 1.15))
                m.addLine(to: CGPoint(x: -r * 1.15, y: r * 0.46))
                m.addQuadCurve(to: CGPoint(x: faceX - r * 0.14, y: -r * 0.30), control: CGPoint(x: faceX - r * 0.58, y: -r * 0.04))
                m.closeSubpath()
                ctx.addPath(m); ctx.fillPath()
            } else {
                ctx.fillEllipse(in: CGRect(x: faceX - r * 0.56, y: r * 0.04, width: r * 1.12, height: r * 0.88))
                ctx.fill(CGRect(x: faceX - r * 0.07, y: -r * 0.88, width: r * 0.14, height: r * 1.0))
            }
        }
        if let calico = pal.calico {
            ctx.setFillColor(calico.cgColor)
            ctx.fillEllipse(in: CGRect(x: -r * 1.15, y: -r * 1.1, width: r * 1.05, height: r * 1.1))
        }
        if let mask = pal.mask {
            let cols = [mask.cgColor, mask.withAlphaComponent(0.78).cgColor, mask.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.44, 1]) {
                let c = CGPoint(x: faceX, y: r * 0.10)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 0.96, options: [])
            }
        }
        if let stripe = pal.stripe, pal.back == nil {
            ctx.setStrokeColor(stripe.cgColor); ctx.setLineWidth(2.2); ctx.setLineCap(.round)
            for dx in [-0.26, 0, 0.26] as [CGFloat] {
                let x = faceX + dx * r
                ctx.move(to: CGPoint(x: x, y: -r * 0.90)); ctx.addLine(to: CGPoint(x: x - dx * 0.12 * r, y: -r * 0.56))
            }
            for dy in [0.10, 0.24] as [CGFloat] {
                ctx.move(to: CGPoint(x: -r * 0.86, y: r * dy))
                ctx.addLine(to: CGPoint(x: -r * 0.52, y: r * (dy + 0.04)))
            }
            ctx.strokePath()
        }
        if let belly = pal.belly {
            ctx.setFillColor(belly.cgColor)
            ctx.fillEllipse(in: CGRect(x: faceX - r * 0.46, y: r * 0.08, width: r * 0.92, height: r * 0.78))
        }
        ctx.restoreGState()
        strokeOuterOutline(in: ctx, [skull, nearEar], color: pal.outline, width: 1.45, alsoOutside: fuseLocal)
        strokeOuterOutline(in: ctx, [farEar], color: pal.outline, width: 1.35, alsoOutside: [skull, nearEar] + fuseLocal)

        // 两只眼睛（3/4 视角）：近侧大圆眼 + 远侧微透视，支持鸳鸯眼、眨眼、急刹眯眼 ^ ^
        let es = CGFloat(pet?.shape.eyeScale ?? 1)
        let f = r / 20
        let eyes: [(c: CGPoint, rx: CGFloat, ry: CGFloat, near: Bool)] = [
            (CGPoint(x: faceX - r * 0.37, y: -r * 0.02), r * 0.215 * es, r * 0.245 * es, true),
            (CGPoint(x: faceX + r * 0.31, y: -r * 0.03), r * 0.182 * es, r * 0.232 * es, false)
        ]
        let closedEye = pose.blink || pose.pose == .land || (pose.pose == .curl && (pose.asleep || pose.curl > 0.35))
        let dilated = pose.hunting || pose.pose == .stalk || pose.pose == .wiggle
        for e in eyes {
            if squint {
                ctx.setStrokeColor((pal.cute ? HexColor.mix(pal.body, .black, 0.65) : pal.eye).cgColor)
                ctx.setLineWidth(1.8); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: e.c.x - e.rx * 0.85, y: e.c.y + e.ry * 0.2))
                ctx.addQuadCurve(to: CGPoint(x: e.c.x + e.rx * 0.85, y: e.c.y + e.ry * 0.2),
                                 control: CGPoint(x: e.c.x, y: e.c.y - e.ry * 0.85))
                ctx.strokePath()
                continue
            }
            if closedEye {
                ctx.setStrokeColor((pal.cute ? HexColor.mix(pal.body, .black, 0.6) : pal.eye).cgColor)
                ctx.setLineWidth(1.6); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: e.c.x - e.rx * 0.88, y: e.c.y + 1))
                ctx.addQuadCurve(to: CGPoint(x: e.c.x + e.rx * 0.88, y: e.c.y + 1),
                                 control: CGPoint(x: e.c.x, y: e.c.y + e.ry * 0.55))
                ctx.strokePath()
                continue
            }
            let eyeColor = (e.near ? pet?.secondEyeColor : nil) ?? pal.eye
            ctx.setFillColor(eyeColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: e.c.x - e.rx, y: e.c.y - e.ry, width: e.rx * 2, height: e.ry * 2))
            ctx.setFillColor(catBlack.cgColor)
            let pw = dilated ? e.rx * 1.32 : (pal.cute ? e.rx * 1.18 : e.rx * 0.62)
            let ph = dilated ? e.ry * 1.48 : (pal.cute ? e.ry * 1.36 : e.ry * 1.56)
            let px = e.c.x + e.rx * 0.14
            ctx.fillEllipse(in: CGRect(x: px - pw * 0.5, y: e.c.y - ph * 0.5, width: pw, height: ph))
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: px - e.rx * 0.42, y: e.c.y - e.ry * 0.55, width: e.rx * 0.55, height: e.rx * 0.55))
            if pal.cute || dilated {
                ctx.fillEllipse(in: CGRect(x: px + e.rx * 0.14, y: e.c.y + e.ry * 0.18, width: e.rx * 0.25, height: e.rx * 0.25))
            }
        }
        // 小粉鼻 + ω 微笑嘴 + 双颊腮红 + 左右胡须
        let nose = CGPoint(x: faceX, y: r * 0.23)
        ctx.setFillColor(rgb(pal.cute || pal.mask != nil ? 0xE9808F : 0x3A2A2C).cgColor)
        ctx.move(to: CGPoint(x: nose.x - r * 0.085, y: nose.y - r * 0.045))
        ctx.addLine(to: CGPoint(x: nose.x + r * 0.075, y: nose.y - r * 0.045))
        ctx.addLine(to: CGPoint(x: nose.x, y: nose.y + r * 0.06))
        ctx.closePath(); ctx.fillPath()
        let muzzleBase = pal.belly ?? pal.body
        let lineColor = HexColor.luminance(muzzleBase) < 0.3
            ? HexColor.mix(pal.body, .white, 0.52)
            : pal.outline.withAlphaComponent(0.85)
        ctx.setStrokeColor(lineColor.cgColor); ctx.setLineWidth(1.1); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: nose.x - r * 0.15, y: r * 0.36))
        ctx.addQuadCurve(to: CGPoint(x: nose.x, y: r * 0.29), control: CGPoint(x: nose.x - r * 0.075, y: r * 0.42))
        ctx.addQuadCurve(to: CGPoint(x: nose.x + r * 0.11, y: r * 0.36), control: CGPoint(x: nose.x + r * 0.055, y: r * 0.42))
        ctx.strokePath()
        if pal.cute {
            ctx.setFillColor(rgb(0xF58C9E, 0.32).cgColor)
            ctx.fillEllipse(in: CGRect(x: faceX - r * 0.58, y: r * 0.19, width: 7.2 * f, height: 4.0 * f))
            ctx.fillEllipse(in: CGRect(x: faceX + r * 0.30, y: r * 0.19, width: 5.5 * f, height: 3.6 * f))
        }
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.9)
        let curly = pet?.shape.curlyWhiskers == true
        let sweep = earPin * 3.5
        for dy: CGFloat in [0.24, 0.36] {
            let l0 = CGPoint(x: faceX - r * 0.32, y: r * dy)
            let l1 = CGPoint(x: faceX - r * 1.08 - sweep, y: r * (dy + (dy - 0.30) * 0.8))
            ctx.move(to: l0); ctx.addQuadCurve(to: l1, control: CGPoint(x: (l0.x + l1.x) / 2, y: l0.y + (curly ? -3.5 : -1)))
            let r0 = CGPoint(x: faceX + r * 0.28, y: r * dy)
            let r1 = CGPoint(x: faceX + r * 0.92 - sweep, y: r * (dy + (dy - 0.30) * 0.8))
            ctx.move(to: r0); ctx.addQuadCurve(to: r1, control: CGPoint(x: (r0.x + r1.x) / 2, y: r0.y + (curly ? -3.5 : -1)))
        }
        ctx.strokePath()

        // 装扮：项圈/围巾（带飘动围巾尾）、蝴蝶结在近侧耳根、墨镜盖住 3/4 双眼
        let rBlend = max(0, min(1, pose.runBlend ?? (pose.pose == .run ? 1 : 0)))
        switch CatSettings.shared.accessory {
        case .bell, .scarf:
            let scarf = CatSettings.shared.accessory == .scarf
            if scarf {
                let flutter = sin(pose.time * (5 + rBlend * 8)) * (2 + rBlend * 4)
                let tailEnd = CGPoint(x: -r * 0.95 - rBlend * 14, y: r * 1.18 - rBlend * 7 + flutter)
                ctx.setStrokeColor(rgb(0xD94848).cgColor)
                ctx.setLineWidth(6.5); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: -r * 0.35, y: r * 0.80))
                ctx.addQuadCurve(to: tailEnd, control: CGPoint(x: -r * 0.65, y: r * 1.02))
                ctx.strokePath()
                ctx.setStrokeColor(rgb(0xF6EBDD).cgColor)
                ctx.setLineWidth(2.0)
                ctx.move(to: CGPoint(x: tailEnd.x + 5, y: tailEnd.y - 2.5))
                ctx.addLine(to: CGPoint(x: tailEnd.x + 7.5, y: tailEnd.y + 1.5))
                ctx.strokePath()
            }
            ctx.setStrokeColor(rgb(scarf ? 0xD94848 : 0xC0394B).cgColor)
            ctx.setLineWidth(scarf ? 6.2 : 3.2); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: -r * 0.56, y: r * 0.72))
            ctx.addQuadCurve(to: CGPoint(x: r * 0.60, y: r * 0.78), control: CGPoint(x: faceX * 0.4, y: r * 1.04))
            ctx.strokePath()
            if !scarf {
                let sway = sin(pose.time * 7) * 1.8 * rBlend
                ctx.setFillColor(rgb(0xF2B630).cgColor)
                ctx.fillEllipse(in: CGRect(x: faceX * 0.55 - 3 - sway, y: r * 0.88, width: 6.2, height: 6.2))
            }
        case .bow:
            ctx.setFillColor(rgb(0xF27BA5).cgColor)
            let b = CGPoint(x: -r * 0.42, y: -r * 0.68)
            ctx.fillEllipse(in: CGRect(x: b.x - 7, y: b.y - 3.5, width: 7, height: 7))
            ctx.fillEllipse(in: CGRect(x: b.x, y: b.y - 3.5, width: 7, height: 7))
            ctx.setFillColor(rgb(0xC94C7C).cgColor)
            ctx.fillEllipse(in: CGRect(x: b.x - 2, y: b.y - 2, width: 4, height: 4))
        case .shades:
            ctx.setStrokeColor(rgb(0x15161A).cgColor); ctx.setLineWidth(1.6)
            ctx.move(to: CGPoint(x: eyes[0].c.x - eyes[0].rx, y: eyes[0].c.y - eyes[0].ry * 0.3))
            ctx.addLine(to: CGPoint(x: -r * 0.75, y: -r * 0.18))
            ctx.strokePath()
            for e in eyes {
                let w = e.rx * 2.55, h = e.ry * 1.95
                let rect = CGRect(x: e.c.x - w * 0.5, y: e.c.y - h * 0.45, width: w, height: h)
                let lens = CGPath(roundedRect: rect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
                ctx.setFillColor(rgb(0x15161A).cgColor)
                ctx.addPath(lens); ctx.fillPath()
                ctx.saveGState()
                ctx.addPath(lens); ctx.clip()
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.24).cgColor)
                let g = CGMutablePath()
                g.move(to: CGPoint(x: rect.minX + w * 0.15, y: rect.maxY))
                g.addLine(to: CGPoint(x: rect.minX + w * 0.46, y: rect.minY))
                g.addLine(to: CGPoint(x: rect.minX + w * 0.64, y: rect.minY))
                g.addLine(to: CGPoint(x: rect.minX + w * 0.33, y: rect.maxY))
                g.closeSubpath()
                ctx.addPath(g); ctx.fillPath()
                ctx.restoreGState()
                ctx.setStrokeColor(pal.outline.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1.0)
                ctx.addPath(lens); ctx.strokePath()
            }
            ctx.setStrokeColor(rgb(0x15161A).cgColor); ctx.setLineWidth(1.8)
            ctx.move(to: CGPoint(x: eyes[0].c.x + eyes[0].rx * 0.9, y: eyes[0].c.y - eyes[0].ry * 0.2))
            ctx.addLine(to: CGPoint(x: eyes[1].c.x - eyes[1].rx * 0.9, y: eyes[1].c.y - eyes[1].ry * 0.2))
            ctx.strokePath()
        case .none:
            break
        }
        // 圣诞季：斜扣一顶圣诞帽（跑步时微向后仰）
        if pose.santaHat {
            ctx.saveGState()
            ctx.rotate(by: -earPin * 0.35)
            drawSideSantaHat(in: ctx, r: r, time: pose.time)
            ctx.restoreGState()
        }
        // 叼着的东西：横咬在 3/4 嘴边
        if let trinket = pose.trinket {
            ctx.saveGState()
            ctx.translateBy(x: faceX + r * 0.24, y: r * 0.46)
            ctx.rotate(by: 0.08)
            drawTrinket(trinket, in: ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: Peek

    /// 扒着屏幕边偷看：正脸大头 + 两只扒边的爪子，身体在屏幕外。锚点（walkerFeet）就是屏幕边上的那一点
    private static func drawPeek(in ctx: CGContext, edge: RoamEdge, reveal: CGFloat, pose: WalkerPose, pal: WalkerPalette) {
        let a = walkerFeet
        let hs = CGFloat(pet?.shape.headSize ?? 1)
        let r: CGFloat = 30 * hs * CGFloat(pet?.shape.headWidth ?? 1).squareRoot()
        let t = pose.time
        ctx.saveGState()
        // 屏幕外的部分不画
        switch edge {
        case .bottom: ctx.clip(to: CGRect(x: 0, y: 0, width: walkerCanvas.width, height: a.y))
        case .right: ctx.clip(to: CGRect(x: 0, y: 0, width: a.x, height: walkerCanvas.height))
        case .left: ctx.clip(to: CGRect(x: a.x, y: 0, width: walkerCanvas.width - a.x, height: walkerCanvas.height))
        }

        var head: CGPoint
        var tilt: CGFloat
        var look: CGPoint
        var paws: [(CGPoint, CGSize)]
        switch edge {
        case .bottom:
            // 从底边冒出来：脑袋露出大半，左右张望
            head = CGPoint(x: a.x + sin(t * 0.6) * 4, y: a.y + r * 0.95 - reveal * r * 1.6)
            tilt = sin(t * 0.8) * 0.12
            look = CGPoint(x: sin(t * 0.7) * 0.8, y: -0.2)
            let pawY = a.y - 3 + (1 - reveal) * r * 0.9
            paws = [(CGPoint(x: a.x - r * 0.8, y: pawY), CGSize(width: r * 0.62, height: r * 0.4)),
                    (CGPoint(x: a.x + r * 0.8, y: pawY), CGSize(width: r * 0.62, height: r * 0.4))]
        case .left, .right:
            // 从侧边探进来：脑袋歪着，眼睛往屏幕里看
            let inward: CGFloat = edge == .right ? -1 : 1
            // 完全探出时也只露七成脑袋
            head = CGPoint(x: a.x - inward * (r * 0.95 - reveal * r * 1.35), y: a.y - 70 + sin(t * 0.9) * 2)
            tilt = -inward * 0.32 + sin(t * 0.8) * 0.06
            look = CGPoint(x: inward * 0.9, y: sin(t * 0.6) * 0.3)
            // 爪子整只露在屏幕里，贴着屏幕边扒住
            let pawX = a.x + inward * (reveal * r * 0.24 - r * 0.06)
            paws = [(CGPoint(x: pawX, y: head.y - r * 0.55), CGSize(width: r * 0.4, height: r * 0.6)),
                    (CGPoint(x: pawX, y: head.y + r * 0.78), CGSize(width: r * 0.4, height: r * 0.6))]
        }
        drawFrontHead(in: ctx, center: head, r: r, tilt: tilt, look: look, blink: pose.blink, pal: pal, santaHat: pose.santaHat)
        // 爪子盖在脑袋前面，扒着屏幕边
        for (c, size) in paws {
            let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            ctx.setFillColor(pal.paws.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(pal.outline.cgColor)
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: rect)
            // 趾缝
            ctx.setStrokeColor(pal.outline.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            let vertical = size.height > size.width
            for f: CGFloat in [-0.18, 0.18] {
                if vertical {
                    let y = c.y + f * size.height
                    let x0 = edge == .right ? rect.minX : rect.maxX
                    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x0 + (edge == .right ? 4 : -4), y: y))
                } else {
                    let x = c.x + f * size.width
                    ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.minY + 4))
                }
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// 正脸大头：耳朵、花纹、圆眼高光、粉鼻子、ω 嘴、腮红、胡须
    private static func drawFrontHead(in ctx: CGContext, center: CGPoint, r: CGFloat, tilt: CGFloat,
                                      look: CGPoint, blink: Bool, pal: WalkerPalette, santaHat: Bool = false) {
        let earSize = CGFloat(pet?.shape.earSize ?? 1)
        let flare = CGFloat(pet?.shape.earFlare ?? 0)
        let folded = pet?.shape.earStyle == .folded
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: tilt)

        // 耳朵（先画，耳根被脸盖住；描边和脸一起做）
        var earPaths: [CGPath] = []
        for sign: CGFloat in [-1, 1] {
            let b1 = CGPoint(x: sign * r * 0.82, y: -r * 0.38)
            let b2 = CGPoint(x: sign * r * 0.18, y: -r * 0.86)
            let len = r * 0.85 * earSize * (folded ? 0.45 : 1)
            let ang = sign * (0.42 + flare * 0.9) + (folded ? sign * 0.8 : 0)
            let mid = CGPoint(x: (b1.x + b2.x) / 2, y: (b1.y + b2.y) / 2)
            let tip = CGPoint(x: mid.x + sin(ang) * len, y: mid.y - cos(ang) * len)
            let ear = CGMutablePath()
            ear.move(to: b1)
            ear.addQuadCurve(to: tip, control: CGPoint(x: (b1.x + tip.x) / 2 + sign * 2, y: (b1.y + tip.y) / 2))
            ear.addQuadCurve(to: b2, control: CGPoint(x: (b2.x + tip.x) / 2 - sign * 2, y: (b2.y + tip.y) / 2))
            ear.closeSubpath()
            ctx.setFillColor(pal.ears.cgColor)
            ctx.addPath(ear); ctx.fillPath()
            earPaths.append(ear)
            if let inner = pal.earInner, !folded {
                let i1 = CGPoint(x: b1.x + (tip.x - b1.x) * 0.22 - sign * 2, y: b1.y + (tip.y - b1.y) * 0.22)
                let i2 = CGPoint(x: b2.x + (tip.x - b2.x) * 0.22 + sign * 2, y: b2.y + (tip.y - b2.y) * 0.22)
                let it = CGPoint(x: mid.x + (tip.x - mid.x) * 0.8, y: mid.y + (tip.y - mid.y) * 0.8)
                ctx.setFillColor(inner.cgColor)
                ctx.move(to: i1); ctx.addLine(to: it); ctx.addLine(to: i2); ctx.closePath(); ctx.fillPath()
            }
        }

        // 脑袋 + 花纹
        let face = CGPath(ellipseIn: CGRect(x: -r * 1.05, y: -r * 0.92, width: r * 2.1, height: r * 1.84), transform: nil)
        ctx.setFillColor(pal.body.cgColor)
        ctx.addPath(face); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(face); ctx.clip()
        if let back = pal.back {
            ctx.setFillColor(back.cgColor)
            ctx.fill(CGRect(x: -r * 1.2, y: -r * 1.2, width: r * 2.4, height: r * 2.4))
            ctx.setFillColor(pal.body.cgColor)
            if pet?.whiteFace == true {
                // 大白脸：额头一道细线往下张开
                let m = CGMutablePath()
                m.move(to: CGPoint(x: 0, y: -r * 0.9))
                m.addLine(to: CGPoint(x: r * 0.12, y: -r * 0.3))
                m.addQuadCurve(to: CGPoint(x: r * 1.1, y: r * 0.5), control: CGPoint(x: r * 0.55, y: -r * 0.05))
                m.addLine(to: CGPoint(x: r * 1.1, y: r * 1.2)); m.addLine(to: CGPoint(x: -r * 1.1, y: r * 1.2))
                m.addLine(to: CGPoint(x: -r * 1.1, y: r * 0.5))
                m.addQuadCurve(to: CGPoint(x: -r * 0.12, y: -r * 0.3), control: CGPoint(x: -r * 0.55, y: -r * 0.05))
                m.closeSubpath()
                ctx.addPath(m); ctx.fillPath()
            } else {
                ctx.fillEllipse(in: CGRect(x: -r * 0.5, y: r * 0.05, width: r, height: r * 0.8))
                ctx.fill(CGRect(x: -r * 0.07, y: -r * 0.85, width: r * 0.14, height: r))
            }
        }
        if let calico = pal.calico {
            ctx.setFillColor(calico.cgColor)
            ctx.fillEllipse(in: CGRect(x: -r * 1.2, y: -r * 1.0, width: r * 0.95, height: r * 1.0))
        }
        if let mask = pal.mask {
            let cols = [mask.cgColor, mask.withAlphaComponent(0.8).cgColor, mask.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.45, 1]) {
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: 0, y: r * 0.15), startRadius: 0,
                                       endCenter: CGPoint(x: 0, y: r * 0.15), endRadius: r * 0.95, options: [])
            }
        }
        if let stripe = pal.stripe, pal.back == nil {
            ctx.setStrokeColor(stripe.cgColor); ctx.setLineWidth(2.4); ctx.setLineCap(.round)
            for x in [-0.3, 0, 0.3] as [CGFloat] {
                ctx.move(to: CGPoint(x: x * r, y: -r * 0.88)); ctx.addLine(to: CGPoint(x: x * r * 0.8, y: -r * 0.55))
            }
            ctx.strokePath()
        }
        if let belly = pal.belly {
            ctx.setFillColor(belly.cgColor)
            ctx.fillEllipse(in: CGRect(x: -r * 0.48, y: r * 0.08, width: r * 0.96, height: r * 0.78))
        }
        ctx.restoreGState()
        strokeOuterOutline(in: ctx, [face] + earPaths, color: pal.outline, width: 1.5)

        // 眼睛：圆眼 + 高光，瞳孔往 look 方向看
        let es = CGFloat(pet?.shape.eyeScale ?? 1)
        for sign: CGFloat in [-1, 1] {
            let c = CGPoint(x: sign * r * 0.4, y: -r * 0.04)
            let rx = r * 0.22 * es, ry = r * 0.25 * es
            if blink {
                ctx.setStrokeColor(HexColor.mix(pal.body, .black, 0.6).cgColor)
                if HexColor.luminance(pal.body) < 0.25 { ctx.setStrokeColor(pal.eye.cgColor) }
                ctx.setLineWidth(1.8); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: c.x - rx, y: c.y + 1))
                ctx.addQuadCurve(to: CGPoint(x: c.x + rx, y: c.y + 1), control: CGPoint(x: c.x, y: c.y + ry * 0.6))
                ctx.strokePath()
                continue
            }
            let eyeColor = (sign < 0 ? pet?.secondEyeColor : nil) ?? pal.eye
            ctx.setFillColor(eyeColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
            let p = CGPoint(x: c.x + look.x * rx * 0.35, y: c.y + look.y * ry * 0.3)
            ctx.setFillColor(catBlack.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - rx * 0.62, y: p.y - ry * 0.72, width: rx * 1.24, height: ry * 1.44))
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - rx * 0.45, y: p.y - ry * 0.6, width: rx * 0.55, height: rx * 0.55))
            ctx.fillEllipse(in: CGRect(x: p.x + rx * 0.15, y: p.y + ry * 0.2, width: rx * 0.25, height: rx * 0.25))
        }
        // 鼻子、嘴、腮红、胡须
        let nose = CGPoint(x: 0, y: r * 0.26)
        ctx.setFillColor(rgb(0xE9808F).cgColor)
        ctx.move(to: CGPoint(x: nose.x - r * 0.09, y: nose.y - r * 0.05))
        ctx.addLine(to: CGPoint(x: nose.x + r * 0.09, y: nose.y - r * 0.05))
        ctx.addLine(to: CGPoint(x: nose.x, y: nose.y + r * 0.06))
        ctx.closePath(); ctx.fillPath()
        let lineColor = HexColor.luminance(pal.belly ?? pal.body) < 0.3 ? HexColor.mix(pal.body, .white, 0.5) : HexColor.mix(pal.belly ?? pal.body, .black, 0.5)
        ctx.setStrokeColor(lineColor.cgColor); ctx.setLineWidth(1.1); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -r * 0.14, y: r * 0.4))
        ctx.addQuadCurve(to: CGPoint(x: 0, y: r * 0.33), control: CGPoint(x: -r * 0.07, y: r * 0.45))
        ctx.addQuadCurve(to: CGPoint(x: r * 0.14, y: r * 0.4), control: CGPoint(x: r * 0.07, y: r * 0.45))
        ctx.strokePath()
        if pal.cute {
            ctx.setFillColor(rgb(0xF58C9E, 0.3).cgColor)
            for sign: CGFloat in [-1, 1] {
                ctx.fillEllipse(in: CGRect(x: sign * r * 0.62 - r * 0.14, y: r * 0.22, width: r * 0.28, height: r * 0.15))
            }
        }
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.9)
        let curly = pet?.shape.curlyWhiskers == true
        for sign: CGFloat in [-1, 1] {
            for dy: CGFloat in [0.28, 0.4] {
                let from = CGPoint(x: sign * r * 0.32, y: r * dy)
                let to = CGPoint(x: sign * r * 1.15, y: r * (dy + (dy - 0.34) * 0.8))
                ctx.move(to: from)
                ctx.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: from.y + (curly ? -4 : -1)))
            }
        }
        ctx.strokePath()
        // 装扮：蝴蝶结在耳根，墨镜盖住眼睛
        switch CatSettings.shared.accessory {
        case .bow:
            let b = CGPoint(x: -r * 0.5, y: -r * 0.72)
            ctx.setFillColor(rgb(0xF27BA5).cgColor)
            ctx.fillEllipse(in: CGRect(x: b.x - 8, y: b.y - 4, width: 8, height: 8))
            ctx.fillEllipse(in: CGRect(x: b.x, y: b.y - 4, width: 8, height: 8))
            ctx.setFillColor(rgb(0xC94C7C).cgColor)
            ctx.fillEllipse(in: CGRect(x: b.x - 2.5, y: b.y - 2.5, width: 5, height: 5))
        case .shades:
            ctx.setFillColor(rgb(0x15161A).cgColor)
            for sign: CGFloat in [-1, 1] {
                ctx.addPath(CGPath(roundedRect: CGRect(x: sign * r * 0.4 - r * 0.3, y: -r * 0.28, width: r * 0.6, height: r * 0.46),
                                   cornerWidth: 6, cornerHeight: 6, transform: nil))
            }
            ctx.fillPath()
        default:
            break
        }
        // 圣诞季：正脸戴圣诞帽（帽尖歪向一边）
        if santaHat { drawSideSantaHat(in: ctx, r: r * 1.1, time: 0) }
        ctx.restoreGState()
    }

    /// 几块叠在一起的形状只描外轮廓：每块只描落在其他块外面的那段，重叠处不留线。
    /// alsoOutside：只用来裁剪、自己不描的形状（例如远侧腿只描露在身体外面的部分）
    private static func strokeOuterOutline(in ctx: CGContext, _ shapes: [CGPath], color: NSColor, width: CGFloat,
                                           alsoOutside: [CGPath] = []) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        for (i, shape) in shapes.enumerated() {
            ctx.saveGState()
            let others = shapes.enumerated().filter { $0.offset != i }.map(\.element) + alsoOutside
            for other in others {
                ctx.addRect(CGRect(x: -2000, y: -2000, width: 4000, height: 4000))
                ctx.addPath(other)
                ctx.clip(using: .evenOdd)
            }
            ctx.addPath(shape)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// 沿二次曲线的渐细肢体：起点宽、终点窄，两端圆头
    static func taperedLimb(from start: CGPoint, control: CGPoint, to end: CGPoint,
                            startWidth: CGFloat, endWidth: CGFloat) -> CGPath {
        let steps = 12
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            let p = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
            let d = CGPoint(x: 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x),
                            y: 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y))
            let len = max(0.001, hypot(d.x, d.y))
            let n = CGPoint(x: -d.y / len, y: d.x / len)
            // 大腿/上臂部分收得慢，到小腿才明显变细
            let w = (startWidth + (endWidth - startWidth) * pow(t, 0.75)) / 2
            left.append(CGPoint(x: p.x + n.x * w, y: p.y + n.y * w))
            right.append(CGPoint(x: p.x - n.x * w, y: p.y - n.y * w))
        }
        let path = CGMutablePath()
        path.addLines(between: left)
        // 末端圆头
        path.addQuadCurve(to: right[steps], control: CGPoint(x: end.x + (end.x - control.x) * 0.15, y: end.y + endWidth * 0.55))
        for pt in right.reversed().dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        return path
    }

    /// 侧身坐着：后腿团成一个圆屁股，前腿笔直撑地，尾巴绕到身前
    private static func drawSittingWalker(in ctx: CGContext, pose: WalkerPose, pal: WalkerPalette) {
        let feet = walkerFeet
        let breathe = sin(pose.time * 2.1) * 0.8
        let haunch = CGRect(x: feet.x - 38, y: feet.y - 44, width: 46, height: 44)
        // 胸口只到大腿一半高，前腿从胸口下面长出来
        let chest = CGRect(x: feet.x - 16, y: feet.y - 68 + breathe, width: 31, height: 50)
        let limb = CGFloat(pet?.shape.limbWidth ?? 1).squareRoot()
        func frontLeg(x: CGFloat) -> (limb: CGPath, paw: CGPath) {
            let top = CGPoint(x: x - 1, y: chest.maxY - 16)
            let end = CGPoint(x: x + 1, y: feet.y - 2)
            let path = taperedLimb(from: top, control: CGPoint(x: x + 1.5, y: (top.y + end.y) / 2), to: CGPoint(x: end.x, y: end.y - 2),
                                   startWidth: 14 * limb, endWidth: 8 * limb)
            let pw = 12 * limb
            let paw = CGPath(ellipseIn: CGRect(x: end.x - pw * 0.42, y: feet.y - 7, width: pw, height: 7.5), transform: nil)
            return (path, paw)
        }
        let farLeg = frontLeg(x: feet.x + 3)
        let nearLeg = frontLeg(x: feet.x + 11)

        // 尾巴贴着地面绕到前面，尖端轻轻翘
        let flick = sin(pose.time * 2.4) * 4
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: haunch.minX + 6, y: feet.y - 6))
        tail.addCurve(to: CGPoint(x: feet.x + 28, y: feet.y - 8 + flick),
                      control1: CGPoint(x: haunch.minX - 2, y: feet.y - 1),
                      control2: CGPoint(x: feet.x + 14, y: feet.y + 1))
        let tailW = 8.5 * CGFloat(pet?.shape.tailWidth ?? 1)
        let tailShape = tail.copy(strokingWithWidth: tailW, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.setFillColor(pal.tail.cgColor)
        ctx.addPath(tailShape); ctx.fillPath()

        let haunchPath = CGPath(ellipseIn: haunch, transform: nil)
        let chestPath = CGPath(roundedRect: chest, cornerWidth: 15, cornerHeight: 15, transform: nil)
        // 前腿先画：远的那条暗一点，两条的上端都被胸口盖住
        for (leg, shade) in [(farLeg, CGFloat(0.16)), (nearLeg, CGFloat(0))] {
            ctx.setFillColor(HexColor.mix(pal.legs, .black, shade).cgColor)
            ctx.addPath(leg.limb); ctx.fillPath()
            ctx.setFillColor(HexColor.mix(pal.paws, .black, shade).cgColor)
            ctx.addPath(leg.paw); ctx.fillPath()
        }
        strokeOuterOutline(in: ctx, [farLeg.limb, farLeg.paw], color: pal.outline, width: 1.4,
                           alsoOutside: [haunchPath, chestPath, nearLeg.limb, nearLeg.paw])
        let body = CGMutablePath()
        body.addPath(haunchPath)
        body.addPath(chestPath)
        ctx.setFillColor(pal.body.cgColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        if let back = pal.back {
            ctx.setFillColor(back.cgColor)
            ctx.fillEllipse(in: haunch.insetBy(dx: -4, dy: -6).offsetBy(dx: -8, dy: -10))
        }
        if let calico = pal.calico {
            ctx.setFillColor(calico.cgColor)
            ctx.fillEllipse(in: CGRect(x: haunch.midX - 4, y: haunch.minY - 2, width: 18, height: 16))
        }
        if let belly = pal.belly {
            ctx.setFillColor(belly.cgColor)
            ctx.fillEllipse(in: chest.insetBy(dx: 2, dy: 8).offsetBy(dx: 9, dy: 6))
        }
        if let stripe = pal.stripe {
            ctx.setStrokeColor(stripe.cgColor); ctx.setLineWidth(3); ctx.setLineCap(.round)
            for i in 0..<3 {
                let y = haunch.minY + 10 + CGFloat(i) * 9
                ctx.move(to: CGPoint(x: haunch.minX + 4, y: y))
                ctx.addQuadCurve(to: CGPoint(x: haunch.minX + 18, y: y - 3), control: CGPoint(x: haunch.minX + 10, y: y + 3))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
        // 身体 + 近侧前腿只描合起来的外轮廓
        strokeOuterOutline(in: ctx, [haunchPath, chestPath, tailShape, nearLeg.limb, nearLeg.paw], color: pal.outline, width: 1.5)
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.9)
        let r = nearLeg.paw.boundingBox
        for dx: CGFloat in [0.38, 0.62] {
            ctx.move(to: CGPoint(x: r.minX + r.width * dx + 1, y: r.maxY - 0.5))
            ctx.addLine(to: CGPoint(x: r.minX + r.width * dx + 1, y: r.maxY - 3.5))
        }
        ctx.strokePath()

        // 头：在胸口上方，偶尔歪一下
        let tilt = sin(pose.time * 0.7) * 0.06
        let bodyCTM = ctx.ctm
        ctx.saveGState()
        ctx.translateBy(x: feet.x + 2, y: chest.minY - 12 + breathe)
        ctx.rotate(by: tilt)
        drawWalkerHead(in: ctx, center: .zero, pose: pose, pal: pal, lookDown: false,
                       fuse: [haunchPath, chestPath], fuseCTM: bodyCTM)
        ctx.restoreGState()
    }

    // MARK: Nap

    /// 蜷着睡时头的位置：刚趴下时抬着头，蜷好后下巴埋到身前
    private static func curledHeadCenter(curl: CGFloat) -> CGPoint {
        let feet = walkerFeet
        return CGPoint(x: feet.x + 32 - curl * 14, y: feet.y - 48 + curl * 13)
    }

    /// 蜷成一团睡觉：圆滚滚的身子，后腿收在肚子边，前爪塞在下巴底下，尾巴绕过来盖住爪子。
    /// curl 从 0（趴着、抬头）过渡到 1（团成球、头埋下去），睡着时身子随呼吸一起一伏。
    private static func drawCurledWalker(in ctx: CGContext, pose: WalkerPose, pal: WalkerPalette) {
        let feet = walkerFeet
        let c = max(0, min(1, pose.curl))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * c }
        func mixPt(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y)) }
        let breathe = pose.asleep ? sin(pose.time * 1.8) : 0
        let widthK = CGFloat(pet?.shape.bodyWidth ?? 1).squareRoot()

        // 身子：从长条趴姿变成圆球，底边始终贴地；吸气时往上鼓一点
        let bodyW = mix(92, 82) * widthK
        let bodyH = mix(44, 60) * widthK + breathe * 1.6
        let bodyRect = CGRect(x: feet.x - mix(52, 50) * widthK, y: feet.y - bodyH, width: bodyW, height: bodyH)
        let body = CGPath(ellipseIn: bodyRect, transform: nil)

        // 尾巴：趴着时拖在身后，蜷起来时沿地面绕到身前、尖端搭在前爪上
        let tailBase = CGPoint(x: bodyRect.minX + 10, y: feet.y - mix(16, 12))
        let flick = pose.asleep ? sin(pose.time * 0.9) * 1.5 : sin(pose.time * 2.4) * 3
        let tailEnd = mixPt(CGPoint(x: bodyRect.minX - 36, y: feet.y - 6), CGPoint(x: feet.x + 40, y: feet.y - 13 + flick))
        let tail = CGMutablePath()
        tail.move(to: tailBase)
        tail.addCurve(to: tailEnd,
                      control1: mixPt(CGPoint(x: tailBase.x - 14, y: feet.y - 4), CGPoint(x: tailBase.x - 12, y: feet.y + 1)),
                      control2: mixPt(CGPoint(x: tailEnd.x + 12, y: feet.y - 2), CGPoint(x: feet.x + 24, y: feet.y + 4)))
        let tailW = 9 * CGFloat(pet?.shape.tailWidth ?? 1)
        let tailShape = tail.copy(strokingWithWidth: tailW, lineCap: .round, lineJoin: .round, miterLimit: 10)

        // 前爪：趴着时往前伸，蜷起来时收到下巴底下
        let pawW = 15 * CGFloat(pet?.shape.limbWidth ?? 1).squareRoot()
        let pawCenter = mixPt(CGPoint(x: feet.x + 48, y: feet.y - 5), CGPoint(x: feet.x + 22, y: feet.y - 6))
        let farPaw = CGPath(ellipseIn: CGRect(x: pawCenter.x - pawW / 2 + 7, y: pawCenter.y - 4.5, width: pawW, height: 9), transform: nil)
        let nearPaw = CGPath(ellipseIn: CGRect(x: pawCenter.x - pawW / 2, y: pawCenter.y - 4, width: pawW, height: 9), transform: nil)
        // 后腿：肚子边上一个圆圆的大腿 + 露出来的后脚
        let thigh = CGRect(x: bodyRect.minX + bodyW * 0.12, y: feet.y - bodyH * 0.78, width: bodyW * 0.42, height: bodyH * 0.72)
        let hindPaw = CGPath(ellipseIn: CGRect(x: thigh.midX - 2, y: feet.y - 8, width: pawW * 1.05, height: 8), transform: nil)

        // 远侧前爪在身子后面
        ctx.setFillColor(HexColor.mix(pal.paws, .black, 0.16).cgColor)
        ctx.addPath(farPaw); ctx.fillPath()
        strokeOuterOutline(in: ctx, [farPaw], color: pal.outline, width: 1.2, alsoOutside: [body, nearPaw])

        // 身子 + 花纹
        ctx.setFillColor(pal.body.cgColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        if let back = pal.back {
            // 双色：背上一大块色斑，肚子一侧是白的
            ctx.setFillColor(back.cgColor)
            ctx.fillEllipse(in: CGRect(x: bodyRect.minX - 6, y: bodyRect.minY - 8, width: bodyW * 0.92, height: bodyH * 0.78))
        }
        if let calico = pal.calico {
            ctx.setFillColor(calico.cgColor)
            ctx.fillEllipse(in: CGRect(x: bodyRect.midX - 4, y: bodyRect.minY - 2, width: 22, height: 17))
        }
        if let belly = pal.belly {
            ctx.setFillColor(belly.cgColor)
            ctx.fillEllipse(in: CGRect(x: bodyRect.midX - bodyW * 0.05, y: feet.y - bodyH * 0.42, width: bodyW * 0.6, height: bodyH * 0.6))
        }
        if let stripe = pal.stripe {
            // 背上一道道弧形条纹，跟着身子的弧度
            ctx.setStrokeColor(stripe.cgColor); ctx.setLineWidth(3); ctx.setLineCap(.round)
            for i in 0..<4 {
                let x = bodyRect.minX + bodyW * (0.22 + CGFloat(i) * 0.15)
                ctx.move(to: CGPoint(x: x - 3, y: bodyRect.minY + 1))
                ctx.addQuadCurve(to: CGPoint(x: x + 1, y: bodyRect.minY + bodyH * 0.36), control: CGPoint(x: x + 4, y: bodyRect.minY + bodyH * 0.16))
            }
            ctx.strokePath()
        }
        // 大腿的弧线：一条淡淡的线勾出后腿收在肚子边
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.1)
        ctx.addArc(center: CGPoint(x: thigh.midX, y: thigh.midY + 2), radius: thigh.width * 0.48,
                   startAngle: .pi * 1.05, endAngle: .pi * 1.75, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        // 后脚、近侧前爪
        ctx.setFillColor(pal.paws.cgColor)
        ctx.addPath(hindPaw); ctx.fillPath()
        ctx.addPath(nearPaw); ctx.fillPath()

        // 身子、后脚、近侧前爪合起来只描外轮廓；尾巴盖在上面的地方让开
        strokeOuterOutline(in: ctx, [body, hindPaw, nearPaw], color: pal.outline, width: 1.5, alsoOutside: [tailShape])

        // 头：趴着时抬头，蜷好后下巴往下埋
        let bodyCTM = ctx.ctm
        let head = curledHeadCenter(curl: c)
        ctx.saveGState()
        ctx.translateBy(x: head.x, y: head.y + breathe * 0.8)
        ctx.rotate(by: mix(0.05, 0.38))
        // 趴着时头从身子上长出来（不描接缝）；蜷起来后头是枕在身上的，整圈描边才看得出「一团」
        drawWalkerHead(in: ctx, center: .zero, pose: pose, pal: pal, lookDown: false,
                       fuse: c < 0.5 ? [body] : [], fuseCTM: bodyCTM)
        ctx.restoreGState()

        // 尾巴最后画：绕到身前盖住前爪；尾巴根和身子之间不描线
        ctx.setFillColor(pal.tail.cgColor)
        ctx.addPath(tailShape); ctx.fillPath()
        ctx.saveGState()
        ctx.addRect(CGRect(x: -500, y: -500, width: 1200, height: 1200))
        ctx.addEllipse(in: CGRect(x: tailBase.x - 11, y: tailBase.y - 11, width: 22, height: 22))
        ctx.clip(using: .evenOdd)
        ctx.setStrokeColor(pal.outline.cgColor)
        ctx.setLineWidth(1.4)
        ctx.addPath(tailShape); ctx.strokePath()
        ctx.restoreGState()
    }

    /// 睡着时从头顶飘出来的 z：一个接一个往上飘、慢慢变大再淡掉
    private static func drawSleepZs(in ctx: CGContext, from origin: CGPoint, facing: CGFloat, time: CGFloat) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 0..<3 {
            let phase = (time * 0.32 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            let size = 5 + phase * 6
            let center = CGPoint(x: origin.x + facing * (4 + phase * 22), y: origin.y - phase * 40)
            let alpha = sin(phase * .pi)
            let z = CGMutablePath()
            z.move(to: CGPoint(x: center.x - size / 2, y: center.y - size / 2))
            z.addLine(to: CGPoint(x: center.x + size / 2, y: center.y - size / 2))
            z.addLine(to: CGPoint(x: center.x - size / 2, y: center.y + size / 2))
            z.addLine(to: CGPoint(x: center.x + size / 2, y: center.y + size / 2))
            // 白边 + 蓝灰字：浅色、深色桌面上都看得清
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.85 * alpha).cgColor)
            ctx.setLineWidth(3.6)
            ctx.addPath(z); ctx.strokePath()
            ctx.setStrokeColor(rgb(0x5B6E93, alpha).cgColor)
            ctx.setLineWidth(1.7)
            ctx.addPath(z); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: Sign

    /// 举牌：木棍立在鼻尖前面，一只前爪从胸口伸出来攥着（画布坐标，朝右）
    static let signStickX: CGFloat = 148
    static let signBoardBottom: CGFloat = 40

    private static func drawSignStick(in ctx: CGContext, pose: WalkerPose, pal: WalkerPalette) {
        let sway = sin(pose.time * 3) * 2
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0x8B5A2B).cgColor)
        ctx.setLineWidth(3.2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: signStickX, y: 150))
        ctx.addLine(to: CGPoint(x: signStickX + sway, y: signBoardBottom))
        ctx.strokePath()
        // 前臂：从胸口伸出来，爪子攥在木棍上（胸口高度，不挡脸）
        let limb = CGFloat(pet?.shape.limbWidth ?? 1).squareRoot()
        let arm = taperedLimb(from: CGPoint(x: 104, y: 136), control: CGPoint(x: 126, y: 146),
                              to: CGPoint(x: signStickX - 5, y: 132), startWidth: 13 * limb, endWidth: 9 * limb)
        let paw = CGPath(ellipseIn: CGRect(x: signStickX - 7, y: 126, width: 14, height: 12), transform: nil)
        ctx.setFillColor(pal.legs.cgColor)
        ctx.addPath(arm)
        ctx.fillPath()
        ctx.setFillColor(pal.paws.cgColor)
        ctx.addPath(paw)
        ctx.fillPath()
        strokeOuterOutline(in: ctx, [arm, paw], color: pal.outline, width: 1.3)
        ctx.restoreGState()
    }

    /// 牌子：米色小木牌 + 两行字，轻轻晃着引人注意。宽度按字算，不出画布
    private static func drawSignBoard(in ctx: CGContext, pose: WalkerPose) {
        guard !pose.signLines.isEmpty else { return }
        let fonts: [NSFont] = [.systemFont(ofSize: 10.5, weight: .bold), .systemFont(ofSize: 9, weight: .medium)]
        let colors: [NSColor] = [rgb(0x3A2A1A), rgb(0x7A6A5A)]
        let lines = pose.signLines.prefix(2).enumerated().map { i, text in
            NSAttributedString(string: text, attributes: [.font: fonts[i], .foregroundColor: colors[i]])
        }
        let width = min(walkerCanvas.width - 8, (lines.map { $0.size().width }.max() ?? 0) + 16)
        let height = lines.reduce(8) { $0 + $1.size().height }
        let stickX = pose.facing < 0 ? walkerCanvas.width - signStickX : signStickX
        let centerX = min(max(stickX, width / 2 + 4), walkerCanvas.width - width / 2 - 4)
        let board = CGRect(x: centerX - width / 2, y: signBoardBottom - height, width: width, height: height)
        ctx.saveGState()
        // 以木棍顶端为轴轻轻晃
        let pivot = CGPoint(x: stickX, y: signBoardBottom)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: sin(pose.time * 3) * 0.04)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        let path = CGPath(roundedRect: board, cornerWidth: 5, cornerHeight: 5, transform: nil)
        let shadow = NSColor(calibratedWhite: 0, alpha: 0.25).cgColor
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: shadow)
        ctx.setFillColor(rgb(0xFFF6E2).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(rgb(0x8B5A2B).cgColor)
        ctx.setLineWidth(1.6)
        ctx.addPath(path)
        ctx.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        var y = board.minY + 4
        for line in lines {
            let size = line.size()
            line.draw(at: CGPoint(x: board.midX - size.width / 2, y: y))
            y += size.height
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
