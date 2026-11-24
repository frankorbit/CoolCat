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
        defer {
            (settings.coatTheme, settings.eyeTheme, settings.accessory, settings.meetingMode,
             settings.keyboardNoiseReminder, settings.lifeNight, settings.keyHabitReactions,
             settings.musicVisualizer, settings.musicDance, settings.keyboardTheme) = saved
        }
        settings.musicVisualizer = true
        settings.musicDance = true
        settings.keyboardTheme = .classicMilk
        write(renderFeatures(), to: dir + "/features.png")
        write(renderHero(), to: dir + "/hero.png")
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

        let chips = ["🎧 鼓点跳舞", "🤖 Claude Code", "🎙 会议模式", "🌙 生活陪伴", "🪶 光标逗猫", "🐟 喂小鱼干", "💞 亲密度装扮", "⚙️ 设置面板"]
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

    private static func rgb(_ hex: Int) -> NSColor { CatRenderer.rgb(hex) }
}
