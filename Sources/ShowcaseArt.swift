import AppKit
import CoreGraphics

/// README 配图：头图 + 特色功能卡片。只在 `--render-readme-art <目录>` 时运行，不影响 App。
enum ShowcaseArt {
    private static let scale: CGFloat = 2

    private static func idle(_ p: CatPhysics, frames: Int) {
        for _ in 0..<frames {
            let input = ScriptedFrameInput(
                now: 100, activeKeys: [], orderedKeys: [], mouseScreenPos: .zero, mouseVelocity: .zero,
                leftMouseDown: false, rightMouseDown: false,
                lastMouseMoveTime: 0, lastMouseClickTime: 0, lastKeyActivityTime: 0
            )
            p.step(dt: 1.0 / 60, windowFrameInScreen: .zero, scripted: input)
        }
    }

    // MARK: Scenes

    struct Scene {
        let title: String
        let subtitle: String
        let coat: CatCoatTheme
        let eye: EyeColorTheme
        let accessory: CatAccessory
        let background: (NSColor, NSColor)
        /// 准备好 physics；返回需要额外画的光标位置
        let setup: (CatPhysics) -> CGPoint?
    }

    private static func dance(_ p: CatPhysics, _ move: DanceMove, beatFraction: Double) {
        p.setListening(true, musicApp: true)
        p.debugArousal = move.isCalm ? 0.2 : 0.8
        idle(p, frames: 180)
        p.debugForceDance(move)
        let framesPerBeat = 3600.0 / Double(p.beatsPerMinute)
        idle(p, frames: Int(framesPerBeat * (2 + beatFraction)))
        p.floatingKeycaps.removeAll()
    }

    static let featureScenes: [Scene] = [
        Scene(title: "🎧 跟着鼓点跳舞", subtitle: "耳机 + LED 频谱墙，强节奏点头、慢歌轻摇",
              coat: .orangeWhite, eye: .warmAmber, accessory: .none,
              background: (rgb(0x2B2F45), rgb(0x1C1E2C))) { p in
            dance(p, .raiseTheRoof, beatFraction: 0.05)
            return nil
        },
        Scene(title: "🤖 Claude Code 联动", subtitle: "逐会话显示项目、动作、耗时，等批准挥手",
              coat: .siamese, eye: .siameseBlue, accessory: .none,
              background: (rgb(0xFBE3D3), rgb(0xF4C9AE))) { p in
            idle(p, frames: 120)
            p.updateClaude(.working(tool: "Edit", sessions: 2))
            p.claudeLines = [
                ClaudeSessionLine(project: "CoolCat", detail: "写代码", kind: .working, elapsed: 134),
                ClaudeSessionLine(project: "api-server", detail: "跑命令", kind: .working, elapsed: 35)
            ]
            idle(p, frames: 60)
            return nil
        },
        Scene(title: "🎙 会议模式", subtitle: "开麦戴耳麦，打字太吵会「嘘」你",
              coat: .shorthair, eye: .referenceHazel, accessory: .none,
              background: (rgb(0xD9F2E4), rgb(0xB8E3CB))) { p in
            CatSettings.shared.meetingMode = true
            CatSettings.shared.keyboardNoiseReminder = true
            p.setMeeting(mic: true, micApp: nil, camera: false)
            idle(p, frames: 40)
            for k in [PhysicalKey.j, .k, .l, .f, .d, .s, .a, .j, .k, .l] { p.triggerKeyDown(k) }
            idle(p, frames: 45)
            p.floatingKeycaps.removeAll()
            return nil
        },
        Scene(title: "🌙 生活陪伴", subtitle: "深夜睡帽、早晨咖啡、没电犯困、久坐喝水",
              coat: .classicBlack, eye: .neonChartreuse, accessory: .none,
              background: (rgb(0xDCD8F7), rgb(0xBDB6EE))) { p in
            CatSettings.shared.lifeNight = true
            p.debugNight = true
            idle(p, frames: 60)
            return nil
        },
        Scene(title: "🪶 光标逗猫", subtitle: "慢慢晃光标：盯上 → 扭屁股 → 出爪拍",
              coat: .orangeWhite, eye: .warmAmber, accessory: .none,
              background: (rgb(0xD6EAFB), rgb(0xB3D6F6))) { p in
            let cursor = CGPoint(x: 86, y: 168)
            p.debugCursorCanvas = cursor
            p.debugPlayAvailable = true
            for _ in 0..<240 {
                idle(p, frames: 1)
                if let s = p.swatStreak, s.extension > 0.9 { break }
            }
            return cursor
        },
        Scene(title: "🐟 喂小鱼干", subtitle: "双爪捧着啃、掉渣、打嗝，每天最多 6 条",
              coat: .classicBlack, eye: .neonChartreuse, accessory: .none,
              background: (rgb(0xFCF0D2), rgb(0xF6DFA6))) { p in
            p.feed()
            idle(p, frames: Int(2.3 * 60))
            return nil
        },
        Scene(title: "💞 亲密度养成", subtitle: "攒亲密度解锁装扮，还会推礼物给你",
              coat: .siamese, eye: .siameseBlue, accessory: .scarf,
              background: (rgb(0xFBDDE7), rgb(0xF5BCD0))) { p in
            p.offerGift(kind: .mouseToy)
            idle(p, frames: Int(2.5 * 60))
            return nil
        },
        Scene(title: "⌨️ 键盘习惯", subtitle: "狂按 ⌫ 冒汗、⌘S 盖章、破纪录戴皇冠",
              coat: .shorthair, eye: .referenceHazel, accessory: .none,
              background: (rgb(0xF1F3F5), rgb(0xDDE2E7))) { p in
            CatSettings.shared.keyHabitReactions = true
            idle(p, frames: 60)
            p.react(to: .recordBurstStarted)
            p.react(to: .newKPMRecord(312))
            idle(p, frames: 40)
            p.floatingKeycaps.removeAll()
            return nil
        }
    ]

    // MARK: Entry

    static func render(toDirectory dir: String) {
        let settings = CatSettings.shared
        let saved = (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.meetingMode,
                     settings.keyboardNoiseReminder, settings.lifeNight, settings.keyHabitReactions,
                     settings.musicVisualizer, settings.musicDance, settings.keyboardTheme)
        let savedPet = settings.customPetID
        defer {
            (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.meetingMode,
             settings.keyboardNoiseReminder, settings.lifeNight, settings.keyHabitReactions,
             settings.musicVisualizer, settings.musicDance, settings.keyboardTheme) = saved
            settings.customPetID = savedPet
        }
        settings.musicVisualizer = true
        settings.musicDance = true
        settings.keyboardTheme = .classicMilk
        write(renderFeatures(), to: dir + "/features.png")
        write(renderHero(), to: dir + "/hero.png")
        write(renderRoam(english: false), to: dir + "/roam.png")
        write(renderRoam(english: true), to: dir + "/roam.en.png")
        write(renderGallop(english: false), to: dir + "/gallop.png")
        write(renderGallop(english: true), to: dir + "/gallop.en.png")
        write(renderRoamPlay(english: false), to: dir + "/roam-play.png")
        write(renderRoamPlay(english: true), to: dir + "/roam-play.en.png")
        write(renderAgentSign(english: false), to: dir + "/agent-sign.png")
        write(renderAgentSign(english: true), to: dir + "/agent-sign.en.png")
        write(renderSnowpack(english: false), to: dir + "/snowpack.png")
        write(renderSnowpack(english: true), to: dir + "/snowpack.en.png")
        write(renderKnock(english: false), to: dir + "/knock.png")
        write(renderKnock(english: true), to: dir + "/knock.en.png")
    }

    // MARK: Knock Things Off

    /// 推东西下桌配图：左边叼着你的笔出门；右边把橡皮放在窗口边一下下拨，瓶盖正往下掉，笔已经躺在地上
    private static func renderKnock(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 460
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let k: CGFloat = 0.9
        let left = CGRect(x: 40, y: 40, width: 470, height: 380)
        let right = CGRect(x: 530, y: 40, width: 710, height: 380)
        let panels = [
            (left, english ? "Steals something off your desk" : "叼走你桌上的小东西",
             english ? "Now and then it heads out with a pen, an eraser or a bottle cap"
                     : "出门溜达时偶尔叼走一支笔、一块橡皮、一个瓶盖",
             (rgb(0xFFF1E6), rgb(0xFFE8EE))),
            (right, english ? "…and knocks it off a window" : "放在窗口边，一下下拨下去",
             english ? "It sets it by the edge, stares at it, swats it bit by bit, then leans over to watch it fall"
                     : "放在窗口边上，盯着看一会儿，再用爪子一下下往外拨，掉下去了还探头看",
             (rgb(0xE8F1FF), rgb(0xF3E8FF)))
        ]
        for (rect, title, subtitle, colors) in panels {
            fillGradient(rect, radius: 18, colors: colors, in: ctx)
            text(title, at: CGPoint(x: rect.minX + 22, y: rect.minY + 18), size: 20, weight: .heavy,
                 color: rgb(0x1D1D24), in: ctx)
            text(subtitle, at: CGPoint(x: rect.minX + 22, y: rect.minY + 50), size: 13, weight: .regular,
                 color: rgb(0x6B6E78), in: ctx, maxWidth: rect.width - 44)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: rect.minX + 18, y: rect.maxY - 30))
            ctx.addLine(to: CGPoint(x: rect.maxX - 18, y: rect.maxY - 30))
            ctx.strokePath()
        }
        // 左：叼着笔小跑
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby"))
        drawWalker(.init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.6, blink: false, trinket: .pen),
                   feet: CGPoint(x: left.midX - 30, y: left.maxY - 30), k: 1.15, alpha: 1, in: ctx)
        // 右：窗口顶上拨橡皮
        PetLibrary.shared.select(nil)
        CatSettings.shared.coatTheme = .siamese
        CatSettings.shared.eyeTheme = .siameseBlue
        let win = CGRect(x: right.minX + 70, y: right.minY + 190, width: 430, height: 130)
        drawFakeWindow(win, title: english ? "Terminal" : "终端", in: ctx)
        let catX = win.maxX - 80
        drawWalker(.init(pose: .knockTap, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, tap: 0.45),
                   feet: CGPoint(x: catX, y: win.minY), k: k, alpha: 1, in: ctx)
        drawArtTrinket(.eraser, at: CGPoint(x: win.maxX - 6, y: win.minY), angle: 0, k: k, in: ctx)
        // 先推下去的两样：瓶盖正在半空翻跟头（虚线是它的轨迹），笔已经躺在地上
        let floorY = right.maxY - 30
        let path = CGMutablePath()
        path.move(to: CGPoint(x: win.maxX + 4, y: win.minY - 4))
        path.addQuadCurve(to: CGPoint(x: win.maxX + 92, y: floorY - 110),
                          control: CGPoint(x: win.maxX + 60, y: win.minY - 30))
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xA6ABBA).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 7])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
        drawArtTrinket(.bottleCap, at: CGPoint(x: win.maxX + 98, y: floorY - 96), angle: 0.9, k: k, in: ctx)
        drawArtTrinket(.pen, at: CGPoint(x: win.maxX + 150, y: floorY), angle: .pi, k: k, in: ctx)
        return ctx.makeImage()
    }

    /// 画一个小东西：at 是它底边中点（画布 y 向下）
    private static func drawArtTrinket(_ kind: Trinket, at point: CGPoint, angle: CGFloat, k: CGFloat,
                                       in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y - kind.size.height / 2 * k)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: k, y: k)
        CatRenderer.drawTrinket(kind, in: ctx)
        ctx.restoreGState()
    }

    // MARK: Snowpack

    /// 积雪配图里侧身小猫的大小
    private static let snowArtScale: CGFloat = 0.9

    /// 窗口积雪配图：左边窗口顶积雪、一串脚印、抬爪抖雪；右边拖动窗口雪滑下来、小猫在地上甩身子
    private static func renderSnowpack(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 460
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let left = CGRect(x: 40, y: 40, width: 590, height: 380)
        let right = CGRect(x: 650, y: 40, width: 590, height: 380)
        let panels = [
            (left, english ? "Snow piles up on your windows" : "窗口顶会积雪",
             english ? "Dec–Feb, window tops gather snow; the cat leaves paw prints and shakes its paws"
                     : "12 月到 2 月，窗口顶慢慢积一层雪；小猫走过留下一串脚印，走久了抬起爪子抖一抖",
             (rgb(0x2C3A57), rgb(0x3B3A5E))),
            (right, english ? "Drag a window and the snow slides off" : "拖动窗口，雪整块滑下来",
             english ? "Back on the ground after a snowy walk, it shakes its whole body from head to tail"
                     : "从积雪的窗口下到地上，从头到尾巴甩一甩全身的雪",
             (rgb(0x2E3D5A), rgb(0x40395F)))
        ]
        for (rect, title, subtitle, colors) in panels {
            fillGradient(rect, radius: 18, colors: colors, in: ctx)
            // 冬夜的深蓝底：白雪才看得清
            text(title, at: CGPoint(x: rect.minX + 22, y: rect.minY + 18), size: 20, weight: .heavy, color: .white,
                 in: ctx)
            text(subtitle, at: CGPoint(x: rect.minX + 22, y: rect.minY + 50), size: 13, weight: .regular,
                 color: rgb(0xC5CEE0), in: ctx, maxWidth: rect.width - 44)
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.18).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: rect.minX + 18, y: rect.maxY - 30))
            ctx.addLine(to: CGPoint(x: rect.maxX - 18, y: rect.maxY - 30))
            ctx.strokePath()
        }
        PetLibrary.shared.select(nil)
        CatSettings.shared.coatTheme = .siamese
        CatSettings.shared.eyeTheme = .siameseBlue
        let seq = SeededRandom(seed: 7)
        drawSnowWalkPanel(in: ctx, panel: left, canvasHeight: height, english: english, seq: seq)
        drawSnowDragPanel(in: ctx, panel: right, canvasHeight: height, english: english, seq: seq)
        PetLibrary.shared.select(nil)
        return ctx.makeImage()
    }

    /// 积雪配图左半：窗口顶积满雪，从左往右走出一串脚印，停下来抖爪子
    private static func drawSnowWalkPanel(in ctx: CGContext, panel left: CGRect, canvasHeight height: CGFloat,
                                          english: Bool, seq: SeededRandom) {
        let k = snowArtScale
        /// 画布是 y 向下的；积雪逻辑是 y 向上的屏幕坐标：换算一下
        func up(_ y: CGFloat) -> CGFloat { height - y }
        let win = CGRect(x: left.minX + 60, y: left.maxY - 150, width: 470, height: 120)
        drawFakeWindow(win, title: english ? "Notes" : "备忘录", in: ctx)
        var pack = Snowpack(random: { seq.next() })
        let top = RoamSurface(id: 1 * 8 + 1, minX: win.minX, maxX: win.maxX, y: up(win.minY))
        let frame = CGRect(x: win.minX, y: up(win.maxY), width: win.width, height: win.height)
        for _ in 0..<60 {
            pack.update(dt: 0.1, snowing: true, growTime: 3, surfaces: [top], frames: [1: frame], floorY: 0)
        }
        let catX = win.minX + 330
        var phase: CGFloat = 0
        var x = win.minX + 40
        while x < catX {
            // 和 App 里一样：走路一个步态周期约 40 画布点
            phase += 6 / (40 * k) * 2 * .pi
            x += 6
            pack.track(Snowpack.Walker(pos: CGPoint(x: x, y: top.y), surfaceID: top.id, moving: true, running: false,
                                       gaitPhase: phase, facing: 1), k: k)
        }
        pack.shakeOff(.paw, at: CGPoint(x: catX, y: top.y), facing: 1, k: k)
        for _ in 0..<5 {
            pack.update(dt: 0.03, snowing: true, growTime: 3, surfaces: [top], frames: [1: frame], floorY: 0)
        }
        drawSnowpack(pack, canvasHeight: height, in: ctx)
        drawWalker(.init(pose: .pawShake, phase: 0, facing: 1, air: 0, time: 0.1, blink: false, santaHat: true,
                         shake: 0.5, pawSnow: 0.8),
                   feet: CGPoint(x: catX, y: win.minY), k: k, alpha: 1, in: ctx)
    }

    /// 积雪配图右半：窗口被拖走，原来位置上的雪碎成雪块往下掉；小猫在地上甩身子
    private static func drawSnowDragPanel(in ctx: CGContext, panel right: CGRect, canvasHeight height: CGFloat,
                                          english: Bool, seq: SeededRandom) {
        let k = snowArtScale
        func up(_ y: CGFloat) -> CGFloat { height - y }
        let oldWin = CGRect(x: right.minX + 40, y: right.minY + 96, width: 250, height: 110)
        let newWin = oldWin.offsetBy(dx: 290, dy: 20)
        var pack2 = Snowpack(random: { seq.next() })
        let oldTop = RoamSurface(id: 2 * 8 + 1, minX: oldWin.minX, maxX: oldWin.maxX, y: up(oldWin.minY))
        let oldFrame = CGRect(x: oldWin.minX, y: up(oldWin.maxY), width: oldWin.width, height: oldWin.height)
        for _ in 0..<60 {
            pack2.update(dt: 0.1, snowing: true, growTime: 3, surfaces: [oldTop], frames: [2: oldFrame], floorY: 0)
        }
        let newTop = RoamSurface(id: 2 * 8 + 1, minX: newWin.minX, maxX: newWin.maxX, y: up(newWin.minY))
        let newFrame = CGRect(x: newWin.minX, y: up(newWin.maxY), width: newWin.width, height: newWin.height)
        for _ in 0..<7 {
            pack2.update(dt: 0.03, snowing: true, growTime: 30, surfaces: [newTop], frames: [2: newFrame], floorY: 0)
        }
        // 原来的位置：虚线框 + 拖动箭头
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xAEB8CC).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 5])
        ctx.addPath(CGPath(roundedRect: oldWin, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
        drawFakeWindow(newWin, title: english ? "Terminal" : "终端", in: ctx)
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xD5DCEA).cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        let arrowFrom = CGPoint(x: oldWin.minX + 90, y: oldWin.midY + 6)
        let arrowTo = CGPoint(x: newWin.minX - 12, y: oldWin.midY + 16)
        ctx.move(to: arrowFrom)
        ctx.addLine(to: arrowTo)
        ctx.move(to: CGPoint(x: arrowTo.x - 10, y: arrowTo.y - 9))
        ctx.addLine(to: arrowTo)
        ctx.addLine(to: CGPoint(x: arrowTo.x - 12, y: arrowTo.y + 6))
        ctx.strokePath()
        ctx.restoreGState()
        let floorY = right.maxY - 30
        let shakeX = right.minX + 150
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby"))
        pack2.shakeOff(.body, at: CGPoint(x: shakeX, y: up(floorY)), facing: 1, k: k)
        for _ in 0..<4 {
            pack2.update(dt: 0.03, snowing: true, growTime: 30, surfaces: [newTop], frames: [2: newFrame], floorY: 0)
        }
        drawSnowpack(pack2, canvasHeight: height, in: ctx)
        drawWalker(.init(pose: .bodyShake, phase: 0, facing: 1, air: 0, time: 0.046, blink: false, santaHat: true,
                         shake: 0.5),
                   feet: CGPoint(x: shakeX, y: floorY), k: k, alpha: 1, in: ctx)
    }

    /// 画积雪（和 App 里 SnowOverlayWindow 一样的路径和配色）。积雪逻辑是 y 向上的，画布是 y 向下的
    private static func drawSnowpack(_ pack: Snowpack, canvasHeight: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)
        let caps = pack.capPath(origin: .zero)
        ctx.saveGState()
        let shadow = NSColor(calibratedWhite: 0, alpha: 0.16).cgColor
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: shadow)
        ctx.setFillColor(NSColor(calibratedRed: 0.985, green: 0.99, blue: 1, alpha: 1).cgColor)
        ctx.addPath(caps)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(CatRenderer.rgb(0xAFC0D6, 0.9).cgColor)
        ctx.setLineWidth(0.8)
        ctx.addPath(caps)
        ctx.strokePath()
        ctx.setFillColor(CatRenderer.rgb(0xDCE5F0, 0.9).cgColor)
        ctx.addPath(pack.capShadePath(origin: .zero))
        ctx.fillPath()
        ctx.setFillColor(CatRenderer.rgb(0x9FB4CC, 0.8).cgColor)
        ctx.addPath(pack.printPath(origin: .zero))
        ctx.fillPath()
        let clumps = pack.clumpPath(origin: .zero)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(clumps)
        ctx.fillPath()
        ctx.setStrokeColor(CatRenderer.rgb(0xAFC0D6, 0.7).cgColor)
        ctx.setLineWidth(0.6)
        ctx.addPath(clumps)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 配图用的可复现随机数：每次渲染出来一样
    private final class SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1 }
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    // MARK: Agent sign

    /// 举牌提醒配图：左边坐在你正在看的窗口顶上举牌，右边窗口顶上不去就在它正下方的屏幕底边举
    private static func renderAgentSign(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 460
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let k: CGFloat = 0.9
        let panels: [(rect: CGRect, title: String, subtitle: String, colors: (NSColor, NSColor))] = [
            (CGRect(x: 40, y: 40, width: 590, height: 380),
             english ? "Holds up a sign on your window" : "跑到你正在看的窗口上举牌",
             english ? "An agent needs approval, you idle for 3 s: it sits atop your frontmost window"
                     : "Claude Code 等你批准、你 3 秒没打字：小猫跑到最前面那扇窗口顶上坐下举牌",
             (rgb(0xE8F1FF), rgb(0xF3E8FF))),
            (CGRect(x: 650, y: 40, width: 590, height: 380),
             english ? "Or right below it" : "上不去就在正下方举",
             english ? "Too tall to reach? It sits right below. Approve or type and it heads home"
                     : "窗口顶太高够不着：坐在它正下方的屏幕底边举；你一批准或开始打字就回家",
             (rgb(0xFFF1E6), rgb(0xFFE8EE)))
        ]
        for panel in panels {
            fillGradient(panel.rect, radius: 18, colors: panel.colors, in: ctx)
            text(panel.title, at: CGPoint(x: panel.rect.minX + 22, y: panel.rect.minY + 18), size: 20, weight: .heavy,
                 color: rgb(0x1D1D24), in: ctx)
            text(panel.subtitle, at: CGPoint(x: panel.rect.minX + 22, y: panel.rect.minY + 50), size: 13,
                 weight: .regular, color: rgb(0x6B6E78), in: ctx, maxWidth: panel.rect.width - 44)
            let floorY = panel.rect.maxY - 30
            ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: panel.rect.minX + 18, y: floorY))
            ctx.addLine(to: CGPoint(x: panel.rect.maxX - 18, y: floorY))
            ctx.strokePath()
        }
        // 左：窗口顶上举牌
        let left = panels[0].rect
        let window = CGRect(x: left.minX + 70, y: left.maxY - 130, width: 450, height: 100)
        drawFakeWindow(window, title: english ? "Browser" : "浏览器", in: ctx)
        PetLibrary.shared.select(nil)
        CatSettings.shared.coatTheme = .siamese
        CatSettings.shared.eyeTheme = .siameseBlue
        let approval = english ? "Claude Code needs approval" : "Claude Code 等你批准"
        drawWalker(.init(pose: .sign, phase: 0, facing: 1, air: 0, time: 0.4, blink: false, signLines: [approval, "CoolCat"]),
                   feet: CGPoint(x: window.midX - 20, y: window.minY), k: k, alpha: 1, in: ctx)
        // 右：窗口太高，在正下方的屏幕底边举
        let right = panels[1].rect
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: right, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.clip()
        let tall = CGRect(x: right.minX + 40, y: right.minY + 96, width: 510, height: 150)
        drawFakeWindow(tall, title: english ? "Terminal" : "终端", in: ctx)
        ctx.restoreGState()
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby"))
        let reply = english ? "Codex is waiting for you" : "Codex 等你回复"
        drawWalker(.init(pose: .sign, phase: 0, facing: -1, air: 0, time: 1.1, blink: false, signLines: [reply, "api-server"]),
                   feet: CGPoint(x: tall.midX + 20, y: right.maxY - 30), k: k, alpha: 1, in: ctx)
        PetLibrary.shared.select(nil)
        return ctx.makeImage()
    }

    // MARK: Roam play

    /// 漫游玩法配图：左边追光标（盯上 → 扭屁股 → 扑），右边爬窗户（太高跳不上去就顺着窗框爬）
    private static func renderRoamPlay(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 440
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let k: CGFloat = 0.9

        // 左：追光标
        let left = CGRect(x: 40, y: 40, width: 590, height: 360)
        fillGradient(left, radius: 18, colors: (rgb(0xE8F1FF), rgb(0xF3E8FF)), in: ctx)
        text(english ? "Chases your cursor" : "追光标", at: CGPoint(x: left.minX + 22, y: left.minY + 18), size: 20,
             weight: .heavy, color: rgb(0x1D1D24), in: ctx)
        text(english ? "Wiggle the cursor near a roaming cat: it stalks, wiggles its butt and pounces"
                     : "在溜达的小猫前面慢慢晃光标：盯上 → 压低挪近 → 扭屁股 → 扑",
             at: CGPoint(x: left.minX + 22, y: left.minY + 50), size: 13, weight: .regular, color: rgb(0x6B6E78), in: ctx)
        let floorY = left.maxY - 40
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: left.minX + 18, y: floorY)); ctx.addLine(to: CGPoint(x: left.maxX - 18, y: floorY))
        ctx.strokePath()
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby"))
        let cursor = CGPoint(x: left.maxX - 70, y: floorY - 150)
        drawWalker(.init(pose: .stalk, phase: 0.6, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: left.minX + 110, y: floorY), k: k, alpha: 0.35, in: ctx)
        drawWalker(.init(pose: .wiggle, phase: 0, facing: 1, air: 0, time: 0.12, blink: false),
                   feet: CGPoint(x: left.minX + 250, y: floorY), k: k, alpha: 0.6, in: ctx)
        // 扑的弧线
        let launch = CGPoint(x: left.minX + 290, y: floorY - 30)
        let arc = CGMutablePath()
        arc.move(to: launch)
        arc.addQuadCurve(to: CGPoint(x: cursor.x - 6, y: cursor.y + 30), control: CGPoint(x: launch.x + 60, y: cursor.y - 40))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 9])
        ctx.addPath(arc)
        ctx.strokePath()
        ctx.restoreGState()
        drawWalker(.init(pose: .air, phase: 0, facing: 1, air: 0.35, time: 0.3, blink: false, hunting: true),
                   feet: CGPoint(x: cursor.x - 60, y: cursor.y + 62 * k), k: k, alpha: 1, in: ctx)
        drawMacCursor(in: ctx, at: cursor, clicking: false)

        // 右：爬窗户
        let right = CGRect(x: 650, y: 40, width: 590, height: 360)
        fillGradient(right, radius: 18, colors: (rgb(0xFFF1E6), rgb(0xFFE8EE)), in: ctx)
        text(english ? "Climbs tall windows" : "爬窗户", at: CGPoint(x: right.minX + 22, y: right.minY + 18), size: 20,
             weight: .heavy, color: rgb(0x1D1D24), in: ctx)
        text(english ? "Window too high to jump onto? It climbs up the frame and keeps hopping from the top"
                     : "窗口太高跳不上去？顺着窗框爬上去，再在窗口之间跳来跳去",
             at: CGPoint(x: right.minX + 22, y: right.minY + 50), size: 13, weight: .regular, color: rgb(0x6B6E78), in: ctx)
        let floor2 = right.maxY - 40
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
        ctx.move(to: CGPoint(x: right.minX + 18, y: floor2)); ctx.addLine(to: CGPoint(x: right.maxX - 18, y: floor2))
        ctx.strokePath()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: right, cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.clip()
        let window = CGRect(x: right.minX + 250, y: right.minY + 205, width: 300, height: floor2 - right.minY - 205 + 30)
        drawFakeWindow(window, title: english ? "Terminal" : "终端", in: ctx)
        ctx.restoreGState()
        PetLibrary.shared.select(nil)
        CatSettings.shared.coatTheme = .siamese
        CatSettings.shared.eyeTheme = .siameseBlue
        // 地上走向窗框 → 抓着窗框往上爬 → 站上窗口顶
        drawWalker(.init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: window.minX - 175, y: floor2), k: k, alpha: 0.35, in: ctx)
        drawWalker(.init(pose: .climb, phase: 0, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: window.minX, y: window.minY + 85), k: k, alpha: 1, in: ctx,
                   anchor: CatRenderer.climbAnchor(wallOnRight: true))
        drawWalker(.init(pose: .stand, phase: 0, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: window.minX + 200, y: window.minY), k: k, alpha: 0.4, in: ctx)
        return ctx.makeImage()
    }

    // MARK: Gallop

    /// 飞奔分解图：一个步幅周期 6 帧，标出伸展腾空和收拢腾空
    private static func renderGallop(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 330
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        CatSettings.shared.accessory = .none
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby"))
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        text(english ? "Gallops like a cheetah" : "像猎豹一样飞奔", at: CGPoint(x: 40, y: 26), size: 26, weight: .heavy,
             color: rgb(0x1D1D24), in: ctx)
        text(english ? "A rotary gallop with a flexing spine and two flight phases — head level, tail streaming back"
                     : "旋转式飞奔：脊柱一伸一弓、两次腾空，头保持水平，尾巴往后拉直当平衡杆",
             at: CGPoint(x: 40, y: 64), size: 14, weight: .regular, color: rgb(0x6B6E78), in: ctx)
        let card = CGRect(x: 40, y: 98, width: width - 80, height: 212)
        fillGradient(card, radius: 18, colors: (rgb(0xFDF1E2), rgb(0xF6E3EE)), in: ctx)
        let ground = card.maxY - 44
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: card.minX + 20, y: ground)); ctx.addLine(to: CGPoint(x: card.maxX - 20, y: ground))
        ctx.strokePath()
        let frames = 6
        let step = (card.width - 40) / CGFloat(frames)
        for i in 0..<frames {
            let feet = CGPoint(x: card.minX + 20 + step * (CGFloat(i) + 0.5), y: ground)
            let pose = CatRenderer.WalkerPose(pose: .run, phase: CGFloat(i) / CGFloat(frames) * 2 * .pi, facing: 1,
                                              air: 0, time: 0.3, blink: false)
            ctx.saveGState()
            ctx.translateBy(x: feet.x - CatRenderer.walkerFeet.x * 0.9, y: feet.y - CatRenderer.walkerFeet.y * 0.9)
            ctx.scaleBy(x: 0.9, y: 0.9)
            CatRenderer.drawWalker(in: ctx, pose: pose)
            ctx.restoreGState()
            let label: String? = i == 0 ? (english ? "extended flight" : "伸展腾空")
                : (i == 3 ? (english ? "gathered flight" : "收拢腾空") : nil)
            if let label {
                let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                let w = (label as NSString).size(withAttributes: [.font: font]).width + 20
                let r = CGRect(x: feet.x - w / 2, y: ground + 12, width: w, height: 24)
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.fillPath()
                text(label, at: CGPoint(x: r.minX + 10, y: r.minY + 4), size: 13, weight: .semibold, color: rgb(0x33343C), in: ctx)
            }
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage?, to path: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8))
        }
    }

    /// 按场景准备一只猫（装扮、毛色都在这里切换）
    private static func makeCat(_ scene: Scene) -> (CatPhysics, CGPoint?) {
        let settings = CatSettings.shared
        settings.coatTheme = scene.coat
        settings.eyeTheme = scene.eye
        settings.accessory = scene.accessory
        let physics = CatPhysics()
        physics.debugBond = previewBond
        idle(physics, frames: 30)
        let cursor = scene.setup(physics)
        return (physics, cursor)
    }

    /// 礼物等功能需要的高等级亲密度，用独立存储，不碰真实数据
    private static let previewBond: BondLog = {
        let suite = "coolcat.readme.bond"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        store.set(520, forKey: "CoolCat.Bond.Points")
        return BondLog(store: store, today: "2026-11-24")
    }()

    private static func makeContext(width: CGFloat, height: CGFloat) -> CGContext? {
        guard let ctx = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
                             color: NSColor, in ctx: CGContext, maxWidth: CGFloat? = nil) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let str = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para
        ])
        if let maxWidth {
            str.draw(with: CGRect(x: point.x, y: point.y, width: maxWidth, height: 200),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        } else {
            str.draw(at: point)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func fillGradient(_ rect: CGRect, radius: CGFloat, colors: (NSColor, NSColor), in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        let cols = [colors.0.cgColor, colors.1.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
    }

    /// 在 rect 里画整只猫（画布 360×320 按宽度缩放）
    private static func drawCat(_ physics: CatPhysics, cursor: CGPoint?, in rect: CGRect, ctx: CGContext) {
        let k = rect.width / CatPhysics.canvasSize.width
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: k, y: k)
        CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
        if let cursor { drawMacCursor(in: ctx, at: cursor, clicking: false) }
        ctx.restoreGState()
    }

    // MARK: Features

    private static func renderFeatures() -> CGImage? {
        let cols = 4, rows = 2
        let cardW: CGFloat = 300, catH: CGFloat = 267, captionH: CGFloat = 66
        let cardH = catH + captionH
        let gap: CGFloat = 22, margin: CGFloat = 40, header: CGFloat = 96
        let width = margin * 2 + cardW * CGFloat(cols) + gap * CGFloat(cols - 1)
        let height = header + cardH * CGFloat(rows) + gap * CGFloat(rows - 1) + margin
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        text("CoolCat 特色功能", at: CGPoint(x: margin, y: 30), size: 30, weight: .heavy, color: rgb(0x1D1D24), in: ctx)
        text("全部由 CoreGraphics 程序化绘制，弹簧物理驱动，13 只猫咪通用",
             at: CGPoint(x: margin + 268, y: 42), size: 14, weight: .regular, color: rgb(0x7A7D88), in: ctx)

        for (i, scene) in featureScenes.enumerated() {
            let col = i % cols, row = i / cols
            let x = margin + CGFloat(col) * (cardW + gap)
            let y = header + CGFloat(row) * (cardH + gap)
            let card = CGRect(x: x, y: y, width: cardW, height: cardH)
            // 卡片阴影 + 渐变底
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor(calibratedWhite: 0, alpha: 0.12).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            // 场景区：裁进卡片圆角里，只有上面两个角是圆的
            let (physics, cursor) = makeCat(scene)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.clip()
            fillGradient(CGRect(x: x, y: y, width: cardW, height: catH), radius: 0, colors: scene.background, in: ctx)
            drawCat(physics, cursor: cursor, in: CGRect(x: x, y: y, width: cardW, height: catH), ctx: ctx)
            ctx.restoreGState()

            text(scene.title, at: CGPoint(x: x + 16, y: y + catH + 12), size: 17, weight: .bold, color: rgb(0x1D1D24), in: ctx)
            text(scene.subtitle, at: CGPoint(x: x + 16, y: y + catH + 38), size: 12, weight: .regular,
                 color: rgb(0x6B6E78), in: ctx, maxWidth: cardW - 32)
        }
        return ctx.makeImage()
    }

    // MARK: Hero

    private static func renderHero() -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 600
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        fillGradient(CGRect(x: 0, y: 0, width: width, height: height), radius: 0,
                     colors: (rgb(0x1E2240), rgb(0x3A2858)), in: ctx)
        // 点点星光
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<70 {
            let p = CGPoint(x: CGFloat.random(in: 0...width, using: &rng), y: CGFloat.random(in: 0...height, using: &rng))
            let r = CGFloat.random(in: 0.6...1.6, using: &rng)
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: CGFloat.random(in: 0.15...0.5, using: &rng)).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }

        // 右侧：戴围巾的小猫在频谱墙前跳舞
        let dancer = Scene(title: "", subtitle: "", coat: .classicBlack, eye: .neonChartreuse, accessory: .bell,
                           background: (.clear, .clear)) { p in
            p.showTrack(title: "猫咪狂想曲", artist: "CoolCat")
            dance(p, .raiseTheRoof, beatFraction: 0.05)
            return nil
        }
        let (physics, _) = makeCat(dancer)
        // 舞台光晕
        let glowCenter = CGPoint(x: 930, y: 330)
        let glowColors = [NSColor(calibratedRed: 0.55, green: 0.45, blue: 1, alpha: 0.45).cgColor,
                          NSColor(calibratedRed: 0.55, green: 0.45, blue: 1, alpha: 0).cgColor] as CFArray
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 330, options: [])
        }
        drawCat(physics, cursor: nil, in: CGRect(x: 640, y: 40, width: 600, height: 533), ctx: ctx)

        // 左侧：标题 + 卖点
        let left: CGFloat = 72
        let pill = CGRect(x: left, y: 92, width: 214, height: 28)
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        text("macOS 桌面小猫 · Swift", at: CGPoint(x: left + 14, y: 97), size: 13, weight: .semibold,
             color: NSColor(calibratedWhite: 1, alpha: 0.85), in: ctx)
        text("CoolCat", at: CGPoint(x: left - 4, y: 132), size: 84, weight: .black, color: .white, in: ctx)
        text("会听歌、会开会、会盯 Claude Code 的桌面小猫", at: CGPoint(x: left, y: 240), size: 24, weight: .semibold,
             color: NSColor(calibratedWhite: 1, alpha: 0.92), in: ctx)
        text("你打字它跟着按键，你听歌它戴上耳机跟着鼓点跳舞。", at: CGPoint(x: left, y: 280), size: 16, weight: .regular,
             color: NSColor(calibratedWhite: 1, alpha: 0.62), in: ctx)

        let chips = ["🎧 鼓点跳舞", "🤖 Claude Code", "🐾 满屏漫游", "🎙 会议模式", "🌙 生活陪伴", "🪶 光标逗猫",
                     "🐟 喂小鱼干", "💞 亲密度装扮", "⚙️ 设置面板"]
        var cx = left, cy: CGFloat = 330
        for chip in chips {
            let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            let w = (chip as NSString).size(withAttributes: [.font: font]).width + 26
            if cx + w > 620 { cx = left; cy += 44 }
            let r = CGRect(x: cx, y: cy, width: w, height: 32)
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.1).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.18).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.strokePath()
            text(chip, at: CGPoint(x: cx + 13, y: cy + 7), size: 14, weight: .semibold, color: .white, in: ctx)
            cx += w + 10
        }
        text("基于 chanke17/KuroCat 魔改 · MIT", at: CGPoint(x: left, y: 530), size: 13, weight: .medium,
             color: NSColor(calibratedWhite: 1, alpha: 0.45), in: ctx)
        return ctx.makeImage()
    }

    // MARK: Roam

    /// 满屏漫游配图：桌面上几扇窗口当跳台，小猫走到桌边起跳、在另一扇窗口上打盹、在屏幕底边偷看，键盘前的座位空着
    private static func renderRoam(english: Bool) -> CGImage? {
        let width: CGFloat = 1280, height: CGFloat = 700
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        let settings = CatSettings.shared
        settings.accessory = .none
        ctx.setFillColor(rgb(0xFAFAFC).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        text(english ? "Roams your whole screen" : "满屏漫游", at: CGPoint(x: 40, y: 30), size: 30, weight: .heavy, color: rgb(0x1D1D24), in: ctx)
        text(english ? "When you're idle it hops off the keyboard and treats your windows like tables. Start typing and it runs back."
                     : "闲下来它会跳下键盘，把窗口当成一张张桌子跳来跳去；你一打字，它就跑回来",
             at: CGPoint(x: 40, y: 74), size: 15, weight: .regular, color: rgb(0x6B6E78), in: ctx)

        // 桌面：圆角屏幕 + 菜单栏
        let desk = CGRect(x: 40, y: 112, width: 1200, height: 560)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: NSColor(calibratedWhite: 0, alpha: 0.16).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(CGPath(roundedRect: desk, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: desk, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.clip()
        fillGradient(desk, radius: 0, colors: (rgb(0xB9CDF0), rgb(0xEBD3EE)), in: ctx)
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor)
        ctx.fill(CGRect(x: desk.minX, y: desk.minY, width: desk.width, height: 24))

        // 三扇窗口（桌子）
        let w1 = CGRect(x: 80, y: 372, width: 360, height: 400)
        let w2 = CGRect(x: 560, y: 262, width: 300, height: 290)
        let w3 = CGRect(x: 930, y: 300, width: 200, height: 150)
        drawFakeWindow(w1, title: english ? "notes.md" : "笔记.md", in: ctx)
        drawFakeWindow(w2, title: "main.swift", in: ctx)
        drawFakeWindow(w3, title: english ? "Music" : "音乐", in: ctx)

        // 键盘前的座位空着（小猫出门了）
        let home = CatPhysics()
        idle(home, frames: 10)
        home.catAway = true
        drawCat(home, cursor: nil, in: CGRect(x: 960, y: 420, width: 280, height: 249), ctx: ctx)

        let k: CGFloat = 0.95
        // ① 大橘：沿窗口顶走到桌边 → 蹲下瞄准 → 跳向另一扇窗
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "orange-tabby"))
        let launch = CGPoint(x: w1.maxX - 10, y: w1.minY)
        let land = CGPoint(x: w2.minX + 60, y: w2.minY)
        let control = CGPoint(x: (launch.x + land.x) / 2, y: min(launch.y, land.y) - 120)
        func arcPoint(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * launch.x + 2 * u * t * control.x + t * t * land.x,
                           y: u * u * launch.y + 2 * u * t * control.y + t * t * land.y)
        }
        // 跳跃轨迹（虚线抛物线）
        let arc = CGMutablePath()
        arc.move(to: launch)
        arc.addQuadCurve(to: land, control: control)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 9])
        ctx.addPath(arc)
        ctx.strokePath()
        ctx.restoreGState()
        drawWalker(.init(pose: .walk, phase: .pi / 2, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: w1.minX + 95, y: w1.minY), k: k, alpha: 0.35, in: ctx)
        drawWalker(.init(pose: .crouch, phase: 0, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: launch.x - 55, y: w1.minY), k: k, alpha: 0.6, in: ctx)
        let mid = arcPoint(0.55)
        drawWalker(.init(pose: .air, phase: 0, facing: 1, air: 0.5, time: 0.3, blink: false),
                   feet: CGPoint(x: mid.x - 10, y: mid.y + 52), k: k, alpha: 1, in: ctx)

        // ② 暹罗：在窗口顶上蜷成一团打盹
        PetLibrary.shared.select(nil)
        settings.coatTheme = .siamese
        settings.eyeTheme = .siameseBlue
        drawWalker(.init(pose: .curl, phase: 0, facing: -1, air: 0, time: 1.2, blink: false, curl: 1, asleep: true),
                   feet: CGPoint(x: w2.maxX - 80, y: w2.minY), k: k, alpha: 1, in: ctx)

        // ③ 三花：躲在屏幕底边偷看
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "calico"))
        drawWalker(.init(pose: .peek, phase: 0, facing: 1, air: 0, time: 0.3, blink: false, peekEdge: .bottom, peekReveal: 1),
                   feet: CGPoint(x: 520, y: desk.maxY), k: k, alpha: 1, in: ctx)

        // ④ 奶牛猫：听到打字声，沿屏幕底部跑回键盘
        PetLibrary.shared.select(PetLibrary.shared.pet(id: "tuxedo"))
        drawWalker(.init(pose: .run, phase: .pi * 0.3, facing: 1, air: 0, time: 0.3, blink: false),
                   feet: CGPoint(x: 800, y: desk.maxY - 4), k: k, alpha: 1, in: ctx)
        ctx.restoreGState()

        // 标注
        let notes: [(String, CGPoint)] = english ? [
            ("① Walk to the edge, aim, leap!", CGPoint(x: 96, y: 196)),
            ("② Curl up for a nap", CGPoint(x: 860, y: 190)),
            ("③ Peek from the screen edge", CGPoint(x: 330, y: 574)),
            ("④ Type and it runs home", CGPoint(x: 975, y: 545))
        ] : [
            ("① 走到桌边 · 瞄准 · 跳！", CGPoint(x: 100, y: 196)),
            ("② 蜷成一团打个盹", CGPoint(x: 860, y: 190)),
            ("③ 躲在屏幕边偷看", CGPoint(x: 360, y: 574)),
            ("④ 一打字就跑回键盘", CGPoint(x: 985, y: 545))
        ]
        for (label, at) in notes {
            let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            let w = (label as NSString).size(withAttributes: [.font: font]).width + 24
            let r = CGRect(x: at.x, y: at.y, width: w, height: 30)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(calibratedWhite: 0, alpha: 0.15).cgColor)
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.94).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 15, cornerHeight: 15, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            text(label, at: CGPoint(x: at.x + 12, y: at.y + 6), size: 14, weight: .semibold, color: rgb(0x33343C), in: ctx)
        }
        return ctx.makeImage()
    }

    /// 简化的 macOS 窗口：白底、红黄绿三个按钮、标题、几行内容条
    private static func drawFakeWindow(_ rect: CGRect, title: String, in ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 22, color: NSColor(calibratedWhite: 0, alpha: 0.18).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(rgb(0xF2F2F5).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 30))
        for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(color).cgColor)
            ctx.fillEllipse(in: CGRect(x: rect.minX + 12 + CGFloat(i) * 18, y: rect.minY + 10, width: 11, height: 11))
        }
        text(title, at: CGPoint(x: rect.minX + 72, y: rect.minY + 7), size: 12, weight: .semibold, color: rgb(0x8A8C96), in: ctx)
        ctx.setFillColor(rgb(0xE6E7EC).cgColor)
        var y = rect.minY + 50
        var i = 0
        while y < rect.maxY - 20 {
            let w = (rect.width - 40) * [0.8, 0.55, 0.7, 0.4, 0.65][i % 5]
            ctx.addPath(CGPath(roundedRect: CGRect(x: rect.minX + 20, y: y, width: w, height: 9), cornerWidth: 4.5, cornerHeight: 4.5,
                               transform: nil))
            ctx.fillPath()
            y += 24
            i += 1
        }
        ctx.restoreGState()
    }

    /// 把侧身小猫画在 feet（脚底中点）处；alpha < 1 用透明图层画，叠在一起的部件不会透出接缝
    /// - Parameter anchor: 画布上对准 feet 的那一点（爬窗框时是贴着窗框的那一点）
    private static func drawWalker(_ pose: CatRenderer.WalkerPose, feet: CGPoint, k: CGFloat, alpha: CGFloat, in ctx: CGContext,
                                   anchor: CGPoint = CatRenderer.walkerFeet) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.translateBy(x: feet.x - anchor.x * k, y: feet.y - anchor.y * k)
        ctx.scaleBy(x: k, y: k)
        CatRenderer.drawWalker(in: ctx, pose: pose)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func rgb(_ hex: Int) -> NSColor { CatRenderer.rgb(hex) }
}
