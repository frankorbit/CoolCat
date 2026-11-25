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
        // 朝左时水平翻转
        if pose.facing < 0 {
            ctx.translateBy(x: walkerCanvas.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        switch pose.pose {
        case .sit: drawSittingWalker(in: ctx, pose: pose, pal: pal)
        case .sign:
            drawSittingWalker(in: ctx, pose: pose, pal: pal)
            drawSignStick(in: ctx, pose: pose, pal: pal)
        case .curl: drawCurledWalker(in: ctx, pose: pose, pal: pal)
        default: drawMovingWalker(in: ctx, pose: pose, pal: pal)
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

    private static func drawMovingWalker(in ctx: CGContext, pose: WalkerPose, pal: WalkerPalette) {
        let feet = walkerFeet
        let ground = feet.y
        let bodyLen: CGFloat = 36 * CGFloat(pet?.shape.bodyWidth ?? 1).squareRoot()
        // 身体厚一点，和大头的比例协调
        var bodyH: CGFloat = 23
        var lift: CGFloat = 50 // 身体中心离地高度
        var tilt: CGFloat = 0
        var stretch: CGFloat = 1
        let p = pose.phase
        // 飞奔（旋转式奔跑，和猎豹一样）：u 是一个步幅周期里的进度。
        // u = 0 伸展腾空：前腿往前探、后腿往后蹬直、脊柱拉长；u = 0.5 收拢腾空：脊柱弓起、后腿收到肚子底下
        let galloping = pose.pose == .run
        let cycle = p / (2 * .pi)
        let u = galloping ? cycle - floor(cycle) : 0
        let flex = cos(2 * .pi * u) // 1 = 伸展，-1 = 收拢
        let arch = galloping ? max(0, -flex) * 9 - max(0, flex) * 2 : 0
        switch pose.pose {
        case .walk:
            lift += sin(p * 2) * 1.6
        case .run:
            // 两次腾空时身体最高，四爪着地时最低；伸展时身子拉长变薄，收拢时缩短变厚；前脚着地时低头、后脚蹬地时抬头
            lift = 45 + 6 * (0.5 + 0.5 * cos(4 * .pi * u))
            stretch = 1.05 + 0.17 * flex
            bodyH = 21.5 - 1.5 * flex
            tilt = 0.08 * sin(2 * .pi * u)
        case .crouch:
            lift = 35
            bodyH = 24
        case .air:
            // 起跳时抬头、落下时低头
            tilt = (pose.air - 0.5) * 0.7
            stretch = 1.12
            bodyH = 20.5
            lift = 50
        case .land:
            lift = 38
            bodyH = 25
        case .stalk:
            // 潜伏：肚子快贴地，头比肩低，一步一步慢慢挪
            lift = 36 + sin(p * 2) * 0.8
            bodyH = 23.5
            stretch = 1.05
            tilt = 0.05
        case .wiggle:
            // 扭屁股蓄力：前低后高，屁股左右扭（画在大腿根上）
            lift = 33
            bodyH = 24.5
            tilt = 0.09
        case .climb:
            // 爬窗框：身体紧贴着墙（转过来后"地面"就是窗框），身子稍微拉长
            lift = 31 + sin(p * 2) * 1.2
            bodyH = 22
            stretch = 1.1
        case .stand, .sit, .peek, .curl, .sign:
            lift += sin(pose.time * 2.1) * 0.8
        }
        let center = CGPoint(x: feet.x - 6, y: ground - lift)
        let halfLen = bodyLen * stretch

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: tilt)

        // 身体由三块组成：躯干 + 胸口 + 圆鼓鼓的大腿根；腿从胸口和大腿根里长出来
        let torso: CGPath
        if galloping {
            // 飞奔时躯干是一条会弯的脊柱：收拢时背弓起来、肚子收进去，伸展时微微塌腰
            let spine = CGMutablePath()
            spine.move(to: CGPoint(x: -halfLen, y: 0))
            spine.addCurve(to: CGPoint(x: halfLen, y: 0),
                           control1: CGPoint(x: -halfLen, y: -bodyH * 1.33 - arch), control2: CGPoint(x: halfLen, y: -bodyH * 1.33 - arch))
            spine.addCurve(to: CGPoint(x: -halfLen, y: 0),
                           control1: CGPoint(x: halfLen, y: bodyH * 1.3 - arch * 0.7), control2: CGPoint(x: -halfLen, y: bodyH * 1.3 - arch * 0.7))
            spine.closeSubpath()
            torso = spine
        } else {
            torso = CGPath(roundedRect: CGRect(x: -halfLen, y: -bodyH, width: halfLen * 2, height: bodyH * 2),
                           cornerWidth: bodyH, cornerHeight: bodyH, transform: nil)
        }
        // 飞奔时胸口和屁股一伸一缩：伸展时拉开，收拢时挤到一起、屁股往上拱
        let spread = galloping ? flex * 3 : 0
        let chestRect = CGRect(x: halfLen * 0.3 + spread, y: -bodyH * 0.95, width: halfLen * 0.92, height: bodyH * 1.88)
        let chest = CGPath(ellipseIn: chestRect, transform: nil)
        // 扭屁股：大腿根抬高一点、左右快速扭
        let wiggleX = pose.pose == .wiggle ? sin(pose.time * 16) * 3.2 : 0
        let wiggleUp: CGFloat = pose.pose == .wiggle ? 8 : 0
        let haunchRect = CGRect(x: -halfLen * 1.08 - spread + wiggleX, y: -bodyH * 0.9 - arch * 0.45 - wiggleUp,
                                width: halfLen * 1.0, height: bodyH * 1.95)
        let haunch = CGPath(ellipseIn: haunchRect, transform: nil)
        let bodyParts = [torso, chest, haunch]

        // 关节：藏在胸口/大腿根里面，腿的上端被身体盖住，接缝处看不出来
        let shoulder = CGPoint(x: chestRect.midX + 1, y: chestRect.midY + 2)
        let hip = CGPoint(x: haunchRect.midX + 2, y: haunchRect.midY)
        let groundY = lift / max(0.6, cos(tilt)) // 身体坐标里地面的大致位置
        let limb = CGFloat(pet?.shape.limbWidth ?? 1).squareRoot()

        /// 飞奔时一条腿的落点和弯曲程度。前腿在 u≈0.22 附近着地、后腿在 u≈0.72 附近着地；
        /// 着地时腿伸直从前往后扫，悬空时折起来（腕关节、跗关节收拢）往前摆。远侧腿比近侧早一点（旋转式奔跑）
        func gallopLeg(_ joint: CGPoint, front: Bool, near: Bool) -> (end: CGPoint, fold: CGFloat) {
            let v = u + (near ? 0 : 0.07)
            // 偏离竖直的角度，正 = 往前。前腿以往前探为主（+0.95 … -0.6），后腿以往后蹬为主（-0.95 … +0.7）
            let c = cos(2 * .pi * v)
            let theta = front ? 0.18 + 0.77 * c : -0.12 - 0.83 * c
            let contactAt: CGFloat = front ? 0.22 : 0.72
            var d = v - contactAt
            d -= floor(d + 0.5) // 环形距离，-0.5...0.5
            let full = groundY - joint.y
            if abs(d) < 0.17 {
                let len = min(full / max(0.4, cos(theta)), full * 1.25)
                return (CGPoint(x: joint.x + sin(theta) * len, y: joint.y + cos(theta) * len), 0)
            }
            // 悬空：从着地结束（d = 0.17）到下一次着地（d = -0.17 + 1）之间，中段折得最厉害
            let swing = (d > 0 ? d - 0.17 : d + 1 - 0.17) / 0.66
            // 刚离地时腿还是直的（蹬出去的那一下），摆到中段才折起来，快落地时再伸直
            let fold = pow(max(0, sin(.pi * (swing - 0.15) / 0.85)), 1.4)
            let len = full * (1 - 0.4 * fold)
            return (CGPoint(x: joint.x + sin(theta) * len, y: joint.y + cos(theta) * len - fold * 4), fold)
        }

        func legEnd(_ joint: CGPoint, offset: CGFloat, front: Bool) -> CGPoint {
            switch pose.pose {
            case .air:
                // 腾空：前腿往前伸，后腿往后蹬
                let len = groundY - joint.y - 4
                return CGPoint(x: joint.x + (front ? len * 0.75 : -len * 0.75), y: joint.y + len * 0.62)
            case .climb:
                // 往上爬：前腿顺着墙往头顶方向够、钩住再往下拉；后腿收在屁股下面蹬墙。
                // 腿是顺着墙斜着的，不是横着支出来的
                let c = sin(p + offset)
                if front {
                    let reach = 0.5 + 0.5 * c                         // 1 = 够到最远，0 = 拉回到肩膀下
                    let lift = max(0, cos(p + offset)) * 5            // 往上够的时候爪子稍微离墙
                    return CGPoint(x: joint.x + 10 + reach * 30, y: groundY - lift)
                }
                return CGPoint(x: joint.x - 2 + c * 9, y: groundY)
            case .walk, .run, .stalk:
                // 潜伏时步子小、爪子几乎不离地
                let amp: CGFloat = pose.pose == .run ? 0.6 : (pose.pose == .stalk ? 0.28 : 0.4)
                let a = sin(p + offset) * amp
                let len = groundY - joint.y
                let raise = max(0, cos(p + offset)) * (pose.pose == .run ? 9 : (pose.pose == .stalk ? 2.5 : 5.5))
                return CGPoint(x: joint.x + sin(a) * len, y: joint.y + cos(a) * len - raise)
            default:
                return CGPoint(x: joint.x + (front ? 2 : -3), y: groundY)
            }
        }

        /// 一条腿：上宽下窄的弯曲肢体 + 椭圆爪子。后腿往后弯出跗关节的弧度，前腿在腕部微微前挺
        func leg(_ joint: CGPoint, _ end: CGPoint, front: Bool, fold: CGFloat = 0) -> (limb: CGPath, paw: CGPath) {
            let mid = CGPoint(x: (joint.x + end.x) / 2, y: (joint.y + end.y) / 2)
            // 折腿时：前腿腕关节往前顶，后腿跗关节往后撅
            let bend: CGFloat = front ? 2.5 + 11 * fold : -9 - 9 * fold
            let control = CGPoint(x: mid.x + bend, y: mid.y)
            let w0 = (front ? 15 : 19) * limb, w1 = 7.2 * limb
            let path = taperedLimb(from: joint, control: control, to: CGPoint(x: end.x, y: end.y - 3), startWidth: w0, endWidth: w1)
            let pw = 11.5 * limb
            let paw = CGPath(ellipseIn: CGRect(x: end.x - pw * 0.42, y: end.y - 6.5, width: pw, height: 7.5), transform: nil)
            return (path, paw)
        }

        func fillLeg(_ l: (limb: CGPath, paw: CGPath), far: Bool) {
            let shade: CGFloat = far ? 0.16 : 0
            ctx.setFillColor(HexColor.mix(pal.legs, .black, shade).cgColor)
            ctx.addPath(l.limb); ctx.fillPath()
            ctx.setFillColor(HexColor.mix(pal.paws, .black, shade).cgColor)
            ctx.addPath(l.paw); ctx.fillPath()
        }

        // 远侧两条腿（画在身体后面，颜色暗一点）；只描露在身体外面的轮廓
        /// 走路用钟摆步态，飞奔用上面的 gallopLeg
        func makeLeg(_ joint: CGPoint, top: CGPoint, offset: CGFloat, front: Bool, near: Bool) -> (limb: CGPath, paw: CGPath) {
            if galloping {
                let g = gallopLeg(joint, front: front, near: near)
                return leg(top, g.end, front: front, fold: g.fold)
            }
            if pose.pose == .climb {
                // 后腿深深弯着（膝盖、跗关节收起来蹬墙），前腿伸直往上够
                return leg(top, legEnd(joint, offset: offset, front: front), front: front, fold: front ? 0 : 0.8)
            }
            return leg(top, legEnd(joint, offset: offset, front: front), front: front)
        }
        let farFront = makeLeg(CGPoint(x: shoulder.x - 5, y: shoulder.y), top: CGPoint(x: shoulder.x - 5, y: shoulder.y - 2),
                               offset: .pi, front: true, near: false)
        let farHind = makeLeg(CGPoint(x: hip.x + 5, y: hip.y), top: CGPoint(x: hip.x + 5, y: hip.y - 2),
                              offset: 0, front: false, near: false)
        for l in [farFront, farHind] {
            fillLeg(l, far: true)
            strokeOuterOutline(in: ctx, [l.limb, l.paw], color: pal.outline, width: 1.4, alsoOutside: bodyParts)
        }

        // 尾巴：从屁股往上翘，走路时左右甩
        let hunting = pose.pose == .stalk || pose.pose == .wiggle
        // 盯上猎物时尾巴放低，只有尾巴尖在快速抽动
        let sway = hunting ? sin(pose.time * 18) * 7 : sin(pose.time * 3.2 + p * 0.5) * 6
        let tailRoot = CGPoint(x: -halfLen * 0.92 + wiggleX, y: -bodyH * 0.25 - wiggleUp)
        // 爬窗框时尾巴顺着墙往下垂（转过来后"往后"就是往下）
        let tailUp: CGFloat = pose.pose == .air ? 0.45 : (hunting ? 0.25 : (pose.pose == .climb ? 0.1 : 1))
        let tail = CGMutablePath()
        tail.move(to: tailRoot)
        if galloping {
            // 飞奔：尾巴往后拉直当平衡杆，跟着身体一伸一缩上下甩
            let whip = sin(2 * .pi * u - 0.8) * 7
            let tailTip = CGPoint(x: -halfLen - 40, y: -bodyH * 0.9 + whip)
            tail.addCurve(to: tailTip, control1: CGPoint(x: tailRoot.x - 14, y: tailRoot.y - 4),
                          control2: CGPoint(x: tailTip.x + 14, y: tailTip.y - whip * 0.6))
        } else {
            let tailTip = CGPoint(x: -halfLen - 20 + sway * 0.4, y: -bodyH - 30 * tailUp + sway * 0.3)
            tail.addCurve(to: tailTip, control1: CGPoint(x: tailRoot.x - 18, y: tailRoot.y + 4),
                          control2: CGPoint(x: tailTip.x - 10 + sway, y: tailTip.y + 16))
        }
        let tailW = 8.5 * CGFloat(pet?.shape.tailWidth ?? 1)
        // 尾巴是一块实心形状：根部被身体盖住，轮廓和身体一起只描外圈，接缝处没有线
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

        // 头：在身体前上方，走路时和身体反着轻轻点头
        let nod: CGFloat = pose.pose == .walk ? -sin(p * 2) * 1.2 : 0
        // 飞奔时头往前探、压低，并抵消身体的俯仰，眼睛始终平视前方（猎豹那种稳定的头）
        // 潜伏、扭屁股时头往前伸、压到肩膀高度，死死盯着；爬窗框时同样贴着墙往上看
        let headCenter = galloping
            ? CGPoint(x: halfLen * 0.95 + 14, y: -bodyH - 9 - arch * 0.3)
            : (hunting || pose.pose == .climb ? CGPoint(x: halfLen * 0.95 + 15, y: -bodyH - 6)
                       : CGPoint(x: halfLen * 0.95 + 10, y: -bodyH - 15 + nod))
        // 头和身体重叠的那段（脖子）不描线，看起来是长在身体上的
        let bodyCTM = ctx.ctm
        ctx.saveGState()
        ctx.translateBy(x: headCenter.x, y: headCenter.y)
        ctx.rotate(by: galloping || hunting ? -tilt * 0.9 : 0)
        drawWalkerHead(in: ctx, center: .zero, pose: pose, pal: pal, lookDown: pose.pose == .crouch,
                       fuse: bodyParts, fuseCTM: bodyCTM)
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// 侧身的头：圆脑袋 + 前面一个小口鼻，一只看得见的大眼睛，两只耳朵
    /// - Parameters:
    ///   - fuse: 头要和哪些身体部件融为一体（在 fuseCTM 那个坐标系下）：头的轮廓线不画在它们上面
    private static func drawWalkerHead(in ctx: CGContext, center: CGPoint, pose: WalkerPose, pal: WalkerPalette, lookDown: Bool,
                                       fuse: [CGPath] = [], fuseCTM: CGAffineTransform = .identity) {
        let hs = CGFloat(pet?.shape.headSize ?? 1)
        // 和坐姿一样的大头比例
        let r: CGFloat = 30 * hs * CGFloat(pet?.shape.headWidth ?? 1).squareRoot()
        let earSize = CGFloat(pet?.shape.earSize ?? 1)
        let flare = CGFloat(pet?.shape.earFlare ?? 0)
        let folded = pet?.shape.earStyle == .folded
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: lookDown ? 0.25 : 0)
        // 身体部件换算到头的局部坐标
        var toLocal = fuseCTM.concatenating(ctx.ctm.inverted())
        let fuseLocal = fuse.compactMap { $0.copy(using: &toLocal) }

        /// 耳朵：头顶上的圆角三角形，大耳朵（德文）往后外撇。耳根埋在头里，画在头后面
        func ear(base: CGFloat, far: Bool) -> CGPath {
            let len = r * 0.95 * earSize * (folded ? 0.5 : 1)
            let angle = -0.25 - flare * 0.6 + (folded ? 0.9 : 0)
            let b1 = CGPoint(x: base - r * 0.42 * earSize.squareRoot(), y: -r * 0.62)
            let b2 = CGPoint(x: base + r * 0.38 * earSize.squareRoot(), y: -r * 0.82)
            let mid = CGPoint(x: (b1.x + b2.x) / 2, y: (b1.y + b2.y) / 2)
            let tip = CGPoint(x: mid.x + sin(angle) * len, y: mid.y - cos(angle) * len)
            let path = CGMutablePath()
            path.move(to: b1)
            path.addQuadCurve(to: tip, control: CGPoint(x: (b1.x + tip.x) / 2 - 2, y: (b1.y + tip.y) / 2))
            path.addQuadCurve(to: b2, control: CGPoint(x: (b2.x + tip.x) / 2 + 3, y: (b2.y + tip.y) / 2))
            path.closeSubpath()
            let color = far ? HexColor.mix(pal.ears, .black, 0.18) : pal.ears
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path); ctx.fillPath()
            if !far, let inner = pal.earInner, !folded {
                let i1 = CGPoint(x: b1.x + (tip.x - b1.x) * 0.2 + 2, y: b1.y + (tip.y - b1.y) * 0.2)
                let i2 = CGPoint(x: b2.x + (tip.x - b2.x) * 0.2 - 2, y: b2.y + (tip.y - b2.y) * 0.2)
                let it = CGPoint(x: mid.x + (tip.x - mid.x) * 0.78, y: mid.y + (tip.y - mid.y) * 0.78)
                ctx.setFillColor(inner.cgColor)
                ctx.move(to: i1); ctx.addLine(to: it); ctx.addLine(to: i2); ctx.closePath(); ctx.fillPath()
            }
            return path
        }
        let farEar = ear(base: -r * 0.1, far: true)
        let nearEar = ear(base: r * 0.2, far: false)

        // 脑袋 + 口鼻
        let skull = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 1.92), transform: nil)
        let snout = CGPath(ellipseIn: CGRect(x: r * 0.35, y: -r * 0.05, width: r * 0.95, height: r * 0.78), transform: nil)
        let head = CGMutablePath()
        head.addPath(skull)
        head.addPath(snout)
        ctx.setFillColor(pal.body.cgColor)
        ctx.addPath(head); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(head); ctx.clip()
        if let back = pal.back {
            // 双色：头顶是色块，口鼻和下巴白（大白脸的猫白得更多）
            ctx.setFillColor(back.cgColor)
            let whiteFace = pet?.whiteFace == true
            ctx.fillEllipse(in: CGRect(x: -r * 1.4, y: -r * 1.5, width: r * (whiteFace ? 2.1 : 2.4), height: r * (whiteFace ? 1.95 : 2.2)))
        }
        if let calico = pal.calico {
            ctx.setFillColor(calico.cgColor)
            ctx.fillEllipse(in: CGRect(x: -r * 1.2, y: -r * 1.3, width: r * 1.1, height: r * 1.2))
        }
        if let mask = pal.mask {
            // 重点色：口鼻和眼周深色，往后渐淡
            let cols = [mask.cgColor, mask.withAlphaComponent(0.75).cgColor, mask.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.45, 1]) {
                let c = CGPoint(x: r * 0.7, y: r * 0.2)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 1.2, options: [])
            }
        }
        if let stripe = pal.stripe, pal.back == nil {
            ctx.setStrokeColor(stripe.cgColor)
            ctx.setLineWidth(2.2)
            ctx.setLineCap(.round)
            for i in 0..<3 {
                let x = -r * 0.45 + CGFloat(i) * r * 0.28
                ctx.move(to: CGPoint(x: x, y: -r * 0.98))
                ctx.addLine(to: CGPoint(x: x + 1.5, y: -r * 0.62))
            }
            ctx.strokePath()
        }
        if let belly = pal.belly {
            ctx.setFillColor(belly.cgColor)
            ctx.fillEllipse(in: CGRect(x: r * 0.3, y: r * 0.1, width: r * 1.1, height: r * 0.85))
        }
        ctx.restoreGState()
        // 头、口鼻、近侧耳朵合起来只描外轮廓（耳根没有接缝）；远侧耳朵只描露在外面的那段
        strokeOuterOutline(in: ctx, [skull, snout, nearEar], color: pal.outline, width: 1.4, alsoOutside: fuseLocal)
        strokeOuterOutline(in: ctx, [farEar], color: pal.outline, width: 1.3, alsoOutside: [skull, snout, nearEar] + fuseLocal)

        // 眼睛：一只看得见的大圆眼 + 高光（眨眼时一条弧线）
        let eyeScale = CGFloat(pet?.shape.eyeScale ?? 1)
        let eye = CGPoint(x: r * 0.42, y: -r * 0.12)
        // 五官跟着头的大小走（原尺寸按 r = 20 设计）
        let f = r / 20
        let ew: CGFloat = 5.6 * f * eyeScale, eh: CGFloat = 6.6 * f * eyeScale
        // 睡着、刚趴下犯困时也闭眼
        if pose.blink || pose.pose == .land || (pose.pose == .curl && (pose.asleep || pose.curl > 0.35)) {
            ctx.setStrokeColor((pal.cute ? HexColor.mix(pal.body, .black, 0.6) : pal.eye).cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: eye.x - ew * 0.9, y: eye.y + 1))
            ctx.addQuadCurve(to: CGPoint(x: eye.x + ew * 0.9, y: eye.y + 1), control: CGPoint(x: eye.x, y: eye.y + 3.5))
            ctx.strokePath()
        } else {
            ctx.setFillColor(pal.eye.cgColor)
            ctx.fillEllipse(in: CGRect(x: eye.x - ew, y: eye.y - eh, width: ew * 2, height: eh * 2))
            ctx.setFillColor(catBlack.cgColor)
            // 狩猎时瞳孔放大成圆圆的大黑眼（竖瞳的猫也是）
            let pw = pose.hunting || pose.pose == .stalk || pose.pose == .wiggle ? ew * 1.35 : (pal.cute ? ew * 1.05 : ew * 0.5)
            ctx.fillEllipse(in: CGRect(x: eye.x - pw * 0.6 + 1.2, y: eye.y - eh * 0.82, width: pw * 1.2, height: eh * 1.64))
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
            ctx.fillEllipse(in: CGRect(x: eye.x + 0.2, y: eye.y - eh * 0.6, width: ew * 0.7, height: ew * 0.7))
        }
        // 鼻子、嘴、腮红
        let nose = CGPoint(x: r * 1.25, y: r * 0.12)
        ctx.setFillColor(rgb(pal.cute || pal.mask != nil ? 0xE9808F : 0x3A2A2C).cgColor)
        ctx.fillEllipse(in: CGRect(x: nose.x - 2.4 * f, y: nose.y - 1.8 * f, width: 3.6 * f, height: 3 * f))
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: nose.x - 0.8 * f, y: nose.y + 1.2 * f))
        ctx.addQuadCurve(to: CGPoint(x: nose.x - 5 * f, y: nose.y + 4.5 * f), control: CGPoint(x: nose.x - 1.5 * f, y: nose.y + 4.5 * f))
        ctx.strokePath()
        if pal.cute {
            ctx.setFillColor(rgb(0xF58C9E, 0.32).cgColor)
            ctx.fillEllipse(in: CGRect(x: r * 0.3, y: r * 0.22, width: 8 * f, height: 4.5 * f))
        }
        // 胡须（卷胡须的猫弯一弯）
        ctx.setStrokeColor(pal.outline.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(0.9)
        let curly = pet?.shape.curlyWhiskers == true
        for dy: CGFloat in [-1, 2.5] {
            let from = CGPoint(x: nose.x - 3, y: nose.y + dy + 1)
            let to = CGPoint(x: nose.x + 14 * f, y: nose.y + dy * 2.2 + 1)
            ctx.move(to: from)
            ctx.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: from.y + (curly ? -3.5 : -1)))
        }
        ctx.strokePath()

        // 装扮：项圈/围巾在脖子，蝴蝶结在耳根，墨镜盖住眼睛
        switch CatSettings.shared.accessory {
        case .bell, .scarf:
            let scarf = CatSettings.shared.accessory == .scarf
            ctx.setStrokeColor(rgb(scarf ? 0xD94848 : 0xC0394B).cgColor)
            ctx.setLineWidth(scarf ? 6 : 3.2)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: -r * 0.55, y: r * 0.72))
            ctx.addQuadCurve(to: CGPoint(x: r * 0.55, y: r * 0.82), control: CGPoint(x: 0, y: r * 1.05))
            ctx.strokePath()
            if !scarf {
                ctx.setFillColor(rgb(0xF2B630).cgColor)
                ctx.fillEllipse(in: CGRect(x: r * 0.1, y: r * 0.88, width: 6, height: 6))
            }
        case .bow:
            ctx.setFillColor(rgb(0xF27BA5).cgColor)
            let b = CGPoint(x: r * 0.05, y: -r * 0.82)
            ctx.fillEllipse(in: CGRect(x: b.x - 7, y: b.y - 3.5, width: 7, height: 7))
            ctx.fillEllipse(in: CGRect(x: b.x, y: b.y - 3.5, width: 7, height: 7))
            ctx.setFillColor(rgb(0xC94C7C).cgColor)
            ctx.fillEllipse(in: CGRect(x: b.x - 2, y: b.y - 2, width: 4, height: 4))
        case .shades:
            ctx.setFillColor(rgb(0x15161A).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: eye.x - ew * 1.25, y: eye.y - eh * 0.9, width: ew * 2.6, height: eh * 1.6),
                               cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(rgb(0x15161A).cgColor)
            ctx.setLineWidth(1.6)
            ctx.move(to: CGPoint(x: eye.x - ew * 1.2, y: eye.y - eh * 0.4))
            ctx.addLine(to: CGPoint(x: -r * 0.5, y: -r * 0.3))
            ctx.strokePath()
        case .none:
            break
        }
        // 圣诞季：斜扣一顶圣诞帽
        if pose.santaHat { drawSideSantaHat(in: ctx, r: r, time: pose.time) }
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
        ctx.translateBy(x: feet.x + 4, y: chest.minY - 13 + breathe)
        ctx.rotate(by: tilt)
        drawWalkerHead(in: ctx, center: .zero, pose: pose, pal: pal, lookDown: false,
                       fuse: [haunchPath, chestPath], fuseCTM: bodyCTM)
        ctx.restoreGState()
    }

    // MARK: Nap

    /// 蜷着睡时头的位置：刚趴下时抬着头，蜷好后下巴埋到身前
    private static func curledHeadCenter(curl: CGFloat) -> CGPoint {
        let feet = walkerFeet
        return CGPoint(x: feet.x + 36 - curl * 16, y: feet.y - 50 + curl * 15)
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
