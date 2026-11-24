import Foundation
import CoreGraphics
import AppKit

enum CatHitZone {
    case none
    case head
    case body
    case permissionPill
}

enum CatRenderer {
    private static func patterned(_ coat: CatCoatTheme) -> Bool { coat == .shorthair || coat == .orangeWhite }
    static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: CGFloat((hex >> 16) & 255)/255,
                green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha)
    }
    private static func bodyColor(_ coat: CatCoatTheme) -> NSColor {
        coat == .shorthair ? rgb(0xC2C5C1) : (coat == .orangeWhite ? rgb(0xF2EEE4) : catBlack)
    }
    private static func limbColor(_ coat: CatCoatTheme) -> NSColor {
        coat == .orangeWhite ? rgb(0xD8AA73) : bodyColor(coat)
    }
    private static func pawColor(_ coat: CatCoatTheme) -> NSColor {
        patterned(coat) ? rgb(0xF2EEE4) : (coat == .siamese ? siamesePoint : catBlack)
    }
    private static func earTailColor(_ coat: CatCoatTheme) -> NSColor {
        coat == .siamese ? siamesePoint : limbColor(coat)
    }
    private static func creaseColor(_ coat: CatCoatTheme) -> NSColor {
        patterned(coat) ? rgb(0x8B8171, 0.60) : contourMint
    }

    static let catBlack = NSColor(calibratedRed: 0.085, green: 0.085, blue: 0.095, alpha: 1.0)
    static let contourMint = NSColor(calibratedRed: 0.82, green: 0.92, blue: 0.89, alpha: 0.76)
    static let whiskerColor = NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.92, alpha: 0.72)

    // Siamese Seal-Point Palette (小豆泥风暖奶白躯干 + 柔和丝绒焦糖可可重点色)
    static let siameseCream    = NSColor(calibratedRed: 0.965, green: 0.937, blue: 0.894, alpha: 1.0) // #F6EFE4
    static let siameseLatte    = NSColor(calibratedRed: 0.918, green: 0.859, blue: 0.784, alpha: 1.0) // #EADBC8
    static let siameseMocha    = NSColor(calibratedRed: 0.416, green: 0.314, blue: 0.255, alpha: 1.0) // #6A5041
    static let siamesePoint    = NSColor(calibratedRed: 0.208, green: 0.149, blue: 0.122, alpha: 1.0) // #35261F
    static let siameseInnerEar = NSColor(calibratedRed: 0.365, green: 0.275, blue: 0.228, alpha: 1.0) // #5D463A
    static let siameseOutline  = NSColor(calibratedRed: 0.68,  green: 0.59,  blue: 0.50,  alpha: 0.42) // soft plush rim
    static let siameseCrease   = NSColor(calibratedRed: 0.553, green: 0.471, blue: 0.404, alpha: 0.54) // #8D7867
    static let siameseWhisker  = NSColor(calibratedRed: 0.478, green: 0.388, blue: 0.325, alpha: 0.62) // #7A6353

    static let permissionPillRect = CGRect(x: 92, y: 294, width: 176, height: 22)

    /// Hit test in 360x320 logical canvas coordinates for smart click-through & petting.
    static func hitTest(point p: CGPoint, physics: CatPhysics, showPermissionPill: Bool) -> CatHitZone {
        if showPermissionPill && permissionPillRect.insetBy(dx: -4, dy: -4).contains(p) {
            return .permissionPill
        }

        let cx = CatPhysics.seatAnchor.x + physics.bodyShiftX.value
        let breath = sin(physics.time * 2.1) * 1.6
        let siameseLift: CGFloat = (CatSettings.shared.coatTheme == .siamese) ? -3.0 : 0.0
        let headCenter = CGPoint(x: cx + physics.bodyTilt.value * 42, y: 124 + siameseLift + physics.headOffsetY.value + breath)

        // Head hit ellipse (strictly on the cat's head — never overlaps keyboard)
        let hdx = (p.x - headCenter.x) / 44.0
        let hdy = (p.y - headCenter.y) / 38.0
        if hdx * hdx + hdy * hdy <= 1.0 {
            return .head
        }

        // Torso + keyboard area hit check
        let bdx = (p.x - cx) / 58.0
        let bdy = (p.y - 196.0) / 56.0
        if bdx * bdx + bdy * bdy <= 1.0 {
            return .body
        }

        // Mini keyboard & mouse area (allows dragging by grabbing keyboard too)
        let kbRect = CGRect(x: 58, y: 232, width: 236, height: 64)
        if kbRect.contains(p) {
            return .body
        }

        return .none
    }

    /// Main 60fps draw routine in flipped 360x320 logical coordinate space.
    static func draw(in ctx: CGContext, physics: CatPhysics, showPermissionPill: Bool,
                     permissionPillText: String = "点击开启全局/游戏键盘监听 🔑") {
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let settings = CatSettings.shared
        let coat = settings.coatTheme
        let breath = sin(physics.time * 2.1) * 1.6
        let seatX = CatPhysics.seatAnchor.x + physics.bodyShiftX.value
        let seatY = CatPhysics.seatAnchor.y

        // 0. 听歌时猫身后的频谱墙（最先画，压在所有东西下面）
        if physics.spectrumVisibility.value > 0.01 {
            drawSpectrumWall(in: ctx, physics: physics)
        }

        // 1. Mini White Mouse (left of keyboard)
        drawMouse(in: ctx, physics: physics, theme: settings.keyboardTheme)

        // 2. Mini Angled 65% Mechanical Keyboard + Dynamic Keycap Glow
        drawKeyboard(in: ctx, physics: physics, theme: settings.keyboardTheme, eyeTheme: settings.eyeTheme, showLegends: settings.showKeyLegends)

        // 3. Cat Tail (behind body)
        drawTail(in: ctx, seatX: seatX, seatY: seatY, physics: physics, coat: coat)

        // 4. 3D-Projected Ears (behind crown silhouette so Siamese seal-point ears emerge cleanly from cream skull!)
        let siameseLift: CGFloat = (coat == .siamese) ? -3.0 : 0.0
        let headCenter = CGPoint(
            x: seatX + physics.bodyTilt.value * 36 + physics.headYaw.value * 7.5,
            y: 126 + siameseLift + physics.headOffsetY.value + physics.headPitch.value * 4.8 + breath * 1.1
        )
        drawEarsLayer(in: ctx, center: headCenter, physics: physics, coat: coat)

        // 4b. 转头时远侧耳机罩被脑袋挡住，先画在头后面
        let headphones = max(0, physics.headphonesOn.value)
        if headphones > 0.01 {
            drawHeadphones(in: ctx, center: headCenter, physics: physics, coat: coat, eyeTheme: settings.eyeTheme, layer: .back)
        }

        // 5. Unified C1-Continuous Head + Neck + Pear Torso Silhouette + Siamese 2.5D Face Mask
        drawUnifiedSilhouette(
            in: ctx,
            seatX: seatX,
            seatY: seatY,
            headCenter: headCenter,
            breath: breath,
            physics: physics,
            coat: coat
        )

        // 6. Hind Foot (3rd simultaneous key easter egg!)
        if physics.hindFootActive.value > 0.03 {
            drawHindFoot(in: ctx, seatX: seatX, seatY: seatY, physics: physics, coat: coat)
        }

        // 7. 2.5D Turning Head Features: Luminous Eyes & Whiskers
        drawHeadFeatures(in: ctx, center: headCenter, physics: physics, eyeTheme: settings.eyeTheme, coat: coat)

        // 7b. 头梁 + 近侧耳机罩盖在头上
        if headphones > 0.01 {
            drawHeadphones(in: ctx, center: headCenter, physics: physics, coat: coat, eyeTheme: settings.eyeTheme, layer: .front)
        }

        // 7c. 头上的小配件：KPM 皇冠、狂删冒汗
        if physics.crownPop.value > 0.02 || physics.sweatTimer > 0 {
            drawHeadAccessories(in: ctx, center: headCenter, physics: physics)
        }
        // 7d. 深夜睡帽（皇冠戴着时让位）
        if physics.crownPop.value < 0.3 {
            drawNightCap(in: ctx, center: headCenter, physics: physics)
        }

        // 8. Front Arms / Paws (over torso & keyboard/mouse with crisp separation outlines / Siamese chocolate socks!)
        drawFrontPaws(in: ctx, seatX: seatX, seatY: seatY, breath: breath, physics: physics, coat: coat)

        // 8a. 爪子捧着的咖啡 / 奶瓶 / 水杯，电量小图标
        drawHeldProp(in: ctx, physics: physics)
        drawFishTreat(in: ctx, physics: physics)
        drawSwatStreak(in: ctx, physics: physics)
        drawBatteryBadge(in: ctx, physics: physics)

        // 8b. 嘘：嘴边冒一个"嘘~"（黑猫捂嘴时爪子和脸同色，需要文字点题）
        if physics.shushTimer > 0 {
            let m = physics.mouthCanvasPoint
            let a = min(1, physics.shushTimer / 0.4) * min(1, (2.4 - physics.shushTimer) / 0.2)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 1)
            ]
            let str = NSAttributedString(string: "嘘~", attributes: attrs)
            let size = str.size()
            // 小深色胶囊垫底：黑猫/浅色猫上都清晰，小字号描边会糊
            let pill = CGRect(x: m.x + 16, y: m.y - 7 + sin(physics.time * 5) * 1.5,
                              width: size.width + 8, height: size.height + 2)
            ctx.saveGState()
            ctx.setAlpha(max(0, a))
            ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.88).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            str.draw(at: CGPoint(x: pill.minX + 4, y: pill.minY + 1))
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }

        // 8. Floating Mechanical Keycap Badges (keyboard + mouse clicks)
        if !physics.floatingKeycaps.isEmpty {
            drawFloatingKeycaps(in: ctx, physics: physics)
        }

        // 9. Subtle Petting Sparkles / Sleep Z
        drawSparkles(in: ctx, physics: physics, eyeTheme: settings.eyeTheme)

        // 9b. Claude Code 状态气泡（右上角）
        let claudeVisible = physics.claudeBubble.value > 0.02
        if claudeVisible {
            drawClaudeBubble(in: ctx, physics: physics, headCenter: headCenter)
        }

        // 9c. 歌名 / 会议提醒气泡（和 Claude 气泡同时出现时挪到最上面）
        if let toast = physics.toast {
            let accent: NSColor
            switch toast.style {
            case .track: accent = settings.eyeTheme.primaryColor
            case .meeting: accent = NSColor(calibratedRed: 0.96, green: 0.36, blue: 0.36, alpha: 1)
            case .camera, .habit: accent = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.35, alpha: 1)
            }
            drawToastBubble(in: ctx, text: toast.text, age: toast.age, headCenter: headCenter,
                            accent: accent, raised: claudeVisible)
        }

        // 9d. ⌘S 印章、截图比耶手势、闪光灯
        if let age = physics.saveStampAge {
            drawSaveStamp(in: ctx, age: age)
        }
        if physics.peaceTimer > 0 {
            drawPeaceSign(in: ctx, physics: physics)
        }
        if physics.cameraFlash > 0.01 {
            drawRadialGlow(in: ctx, center: CGPoint(x: seatX, y: 160), radius: 175,
                           color: NSColor(calibratedWhite: 1, alpha: physics.cameraFlash * 0.8))
        }

        // 10. Optional non-intrusive Permission Pill if global monitoring not yet granted
        if showPermissionPill {
            drawPermissionPill(in: ctx, text: permissionPillText)
        }

        ctx.restoreGState()
    }

    // MARK: - Mini White Mouse

    private static func drawMouse(in ctx: CGContext, physics: CatPhysics, theme: KeyboardTheme) {
        let center = CGPoint(
            x: CatPhysics.mouseBaseCenter.x + physics.mouseOffset.point.x,
            y: CatPhysics.mouseBaseCenter.y + physics.mouseOffset.point.y
        )
        let pressShift = max(physics.mousePressLeft.value, physics.mousePressRight.value) * 1.6

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y + pressShift)
        ctx.rotate(by: 0.22) // angled naturally for the cat's right paw (facing the cat!)

        // Soft underside shadow
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.0, alpha: 0.24).cgColor)
        ctx.fillEllipse(in: CGRect(x: -13.5, y: -13.5 + 4.0, width: 27, height: 31))
        ctx.restoreGState()

        let bodyRect = CGRect(x: -13.5, y: -16.5, width: 27, height: 33)
        let bodyColor: NSColor
        let borderColor: NSColor
        let wheelColor: NSColor
        switch theme {
        case .classicMilk:
            bodyColor = NSColor(calibratedRed: 0.955, green: 0.950, blue: 0.925, alpha: 1.0)
            borderColor = NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1.0)
            wheelColor = NSColor(calibratedRed: 0.96, green: 0.69, blue: 0.16, alpha: 1.0)
        case .midnightHacker:
            bodyColor = NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.24, alpha: 1.0)
            borderColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
            wheelColor = NSColor(calibratedRed: 0.78, green: 0.95, blue: 0.25, alpha: 1.0)
        case .retroCream:
            bodyColor = NSColor(calibratedRed: 0.89, green: 0.87, blue: 0.82, alpha: 1.0)
            borderColor = NSColor(calibratedRed: 0.20, green: 0.19, blue: 0.18, alpha: 1.0)
            wheelColor = NSColor(calibratedRed: 0.88, green: 0.42, blue: 0.24, alpha: 1.0)
        }

        // Mouse body (palm-rest dome toward cat at top, click buttons & scroll wheel away from cat at bottom!)
        ctx.setFillColor(bodyColor.cgColor)
        ctx.fillEllipse(in: bodyRect)

        // Subtle click flash highlight (cat-facing: left button = inner right side, right button = outer left side!)
        if physics.mousePressLeft.value > 0.05 {
            ctx.saveGState()
            ctx.addEllipse(in: bodyRect)
            ctx.clip()
            ctx.setFillColor(NSColor(calibratedRed: 0.79, green: 0.95, blue: 0.25, alpha: 0.38 * physics.mousePressLeft.value).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 14, height: 17))
            ctx.restoreGState()
        }
        if physics.mousePressRight.value > 0.05 {
            ctx.saveGState()
            ctx.addEllipse(in: bodyRect)
            ctx.clip()
            ctx.setFillColor(NSColor(calibratedRed: 0.79, green: 0.95, blue: 0.25, alpha: 0.38 * physics.mousePressRight.value).cgColor)
            ctx.fill(CGRect(x: -14, y: 0, width: 14, height: 17))
            ctx.restoreGState()
        }

        // Button split seam pointing forward (bottom, away from cat!)
        ctx.setStrokeColor(borderColor.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(1.05)
        ctx.move(to: CGPoint(x: 0, y: 16))
        ctx.addLine(to: CGPoint(x: 0, y: 1.5))
        ctx.strokePath()

        // Signature amber scroll wheel on the front (bottom) half facing away from cat
        let wheelRect = CGRect(x: -1.9, y: 2.5, width: 3.8, height: 8.5)
        let wheelPath = CGPath(roundedRect: wheelRect, cornerWidth: 1.9, cornerHeight: 1.9, transform: nil)
        ctx.setFillColor(wheelColor.cgColor)
        ctx.addPath(wheelPath)
        ctx.fillPath()

        // Outer crisp outline
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(1.7)
        ctx.strokeEllipse(in: bodyRect)

        ctx.restoreGState()
    }

    // MARK: - Mini Angled 65% Mechanical Keyboard (facing the cat!)

    private static func drawKeyboard(
        in ctx: CGContext,
        physics: CatPhysics,
        theme: KeyboardTheme,
        eyeTheme: EyeColorTheme,
        showLegends: Bool
    ) {
        let tl = KeyboardLayout.screenQuadPoint(su: -0.012, sv: -0.04)
        let tr = KeyboardLayout.screenQuadPoint(su: 1.012, sv: -0.04)
        let bl = KeyboardLayout.screenQuadPoint(su: -0.016, sv: 1.04)
        let br = KeyboardLayout.screenQuadPoint(su: 1.016, sv: 1.04)

        let caseDepth: CGFloat = 4.5

        // Soft ambient drop shadow beneath keyboard
        ctx.saveGState()
        let shadowPath = roundedQuadPath(
            tl: CGPoint(x: tl.x, y: tl.y + caseDepth + 2),
            tr: CGPoint(x: tr.x, y: tr.y + caseDepth + 2),
            br: CGPoint(x: br.x, y: br.y + caseDepth + 3),
            bl: CGPoint(x: bl.x, y: bl.y + caseDepth + 3),
            radius: 6
        )
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.22).cgColor)
        ctx.addPath(shadowPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Dark 3D chassis lower lip
        let baseColor: NSColor
        let deckColor: NSColor
        let keyColor: NSColor
        let keyBorderColor: NSColor
        let accentColor: NSColor

        switch theme {
        case .classicMilk:
            baseColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
            deckColor = NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1.0)
            keyColor = NSColor(calibratedRed: 0.968, green: 0.964, blue: 0.942, alpha: 1.0)
            keyBorderColor = NSColor(calibratedRed: 0.78, green: 0.77, blue: 0.74, alpha: 0.75)
            accentColor = NSColor(calibratedRed: 0.97, green: 0.70, blue: 0.16, alpha: 1.0)
        case .midnightHacker:
            baseColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)
            deckColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
            keyColor = NSColor(calibratedRed: 0.21, green: 0.22, blue: 0.25, alpha: 1.0)
            keyBorderColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.95)
            accentColor = NSColor(calibratedRed: 0.77, green: 0.94, blue: 0.25, alpha: 1.0)
        case .retroCream:
            baseColor = NSColor(calibratedRed: 0.25, green: 0.24, blue: 0.22, alpha: 1.0)
            deckColor = NSColor(calibratedRed: 0.38, green: 0.36, blue: 0.33, alpha: 1.0)
            keyColor = NSColor(calibratedRed: 0.90, green: 0.88, blue: 0.82, alpha: 1.0)
            keyBorderColor = NSColor(calibratedRed: 0.68, green: 0.65, blue: 0.60, alpha: 0.85)
            accentColor = NSColor(calibratedRed: 0.88, green: 0.42, blue: 0.24, alpha: 1.0)
        }

        let lowerChassis = roundedQuadPath(
            tl: CGPoint(x: tl.x, y: tl.y + caseDepth),
            tr: CGPoint(x: tr.x, y: tr.y + caseDepth),
            br: CGPoint(x: br.x, y: br.y + caseDepth),
            bl: CGPoint(x: bl.x, y: bl.y + caseDepth),
            radius: 5.5
        )
        ctx.setFillColor(baseColor.cgColor)
        ctx.addPath(lowerChassis)
        ctx.fillPath()

        let topChassis = roundedQuadPath(tl: tl, tr: tr, br: br, bl: bl, radius: 5.0)
        ctx.setFillColor(deckColor.cgColor)
        ctx.addPath(topChassis)
        ctx.fillPath()

        // Individual keycaps — tight clean mechanical spacing matching the reference video
        let padU: CGFloat = 0.0028
        let padV: CGFloat = 0.014
        let glowBaseColor = eyeTheme.glowColor

        for cap in KeyboardLayout.keycaps {
            let glow = physics.keyGlow[cap.key] ?? 0
            // 180° rotated to face the cat: su = 1 - u, sv = 1 - v
            let su0 = (1.0 - (cap.xUnits + cap.widthUnits)) + padU
            let su1 = (1.0 - cap.xUnits) - padU
            let sv0 = (1.0 - CGFloat(cap.row + 1) / 5.0) + padV
            let sv1 = (1.0 - CGFloat(cap.row) / 5.0) - padV

            let pressDy = glow * 1.9
            let kTL = offsetY(KeyboardLayout.screenQuadPoint(su: su0, sv: sv0), pressDy)
            let kTR = offsetY(KeyboardLayout.screenQuadPoint(su: su1, sv: sv0), pressDy)
            let kBR = offsetY(KeyboardLayout.screenQuadPoint(su: su1, sv: sv1), pressDy)
            let kBL = offsetY(KeyboardLayout.screenQuadPoint(su: su0, sv: sv1), pressDy)

            let kPath = roundedQuadPath(tl: kTL, tr: kTR, br: kBR, bl: kBL, radius: 1.6)

            var fill = cap.isAmberAccent ? accentColor : keyColor
            if glow > 0.02 {
                fill = blendColor(fill, glowBaseColor, t: glow * 0.55)
            }

            ctx.setFillColor(fill.cgColor)
            ctx.addPath(kPath)
            ctx.fillPath()

            ctx.setStrokeColor(keyBorderColor.cgColor)
            ctx.setLineWidth(0.65)
            ctx.addPath(kPath)
            ctx.strokePath()

            if showLegends {
                let isSpace = cap.key == .space
                let legend = isSpace ? "space" : keycapLegend(cap.key)
                if !legend.isEmpty {
                    var cx = (kTL.x + kTR.x + kBR.x + kBL.x) * 0.25
                    var cy = (kTL.y + kTR.y + kBR.y + kBL.y) * 0.25
                    if isSpace {
                        // The spacebar sits right under the cat: its legs hide the middle, and an
                        // unlabeled visible end looked like an odd blank patch beside the cat.
                        // Label the end that stays visible instead.
                        let sp = KeyboardLayout.screenQuadPoint(su: su0 + (su1 - su0) * 0.82, sv: (sv0 + sv1) * 0.5)
                        cx = sp.x
                        cy = sp.y + pressDy
                    }
                    let textColor: NSColor
                    if cap.isAmberAccent || theme != .midnightHacker {
                        textColor = NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 0.78)
                    } else {
                        textColor = NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.92, alpha: 0.82)
                    }
                    let fontSize: CGFloat = legend.count <= 1 ? 5.2 : 4.2
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: textColor
                    ]
                    let str = NSAttributedString(string: legend, attributes: attrs)
                    let sz = str.size()
                    ctx.saveGState()
                    ctx.translateBy(x: cx, y: cy)
                    // Keyboard faces the cat (180°), so legends read upright from the cat's seat.
                    ctx.rotate(by: .pi + 0.052)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                    str.draw(at: CGPoint(x: -sz.width * 0.5, y: -sz.height * 0.5))
                    NSGraphicsContext.restoreGraphicsState()
                    ctx.restoreGState()
                }
            }
        }

        // Signature soft chartreuse backlit glow halos on active keys!
        for (key, glow) in physics.keyGlow where glow > 0.05 {
            let center = KeyboardLayout.canvasPoint(for: key)
            drawRadialGlow(
                in: ctx,
                center: center,
                radius: 17.0 + glow * 6.0,
                color: glowBaseColor.withAlphaComponent(0.36 * glow)
            )
        }
    }

    // MARK: - Tail

    private static func drawTail(in ctx: CGContext, seatX: CGFloat, seatY: CGFloat, physics: CatPhysics, coat: CatCoatTheme) {
        let p = physics.tailPhase
        let hunt = max(0, min(1, physics.huntIntensity.value))
        // 跳舞/看尾巴时摆幅加大
        let amp = max(0.3, physics.tailAmplitude)
        let wag1 = sin(p) * (8.0 + hunt * 5.5) * amp
        let wag2 = cos(p * 1.3) * (6.0 + hunt * 4.5) * amp
        // Tail drops lower & swishes tautly when stalking/hunting!
        let huntDrop = hunt * 14.0

        // Signature low sweep out to the right, then playful upward curl at the tip!
        let root = CGPoint(x: seatX + 34, y: seatY - 6)
        let c1 = CGPoint(x: seatX + 64, y: seatY + 2 + wag1 * 0.35 + huntDrop * 0.4)
        let c2 = CGPoint(x: seatX + 66 + wag2 * 0.4, y: seatY - 26 + wag1 * 0.7 + huntDrop)
        let tip = CGPoint(x: seatX + 91 + wag2 * 0.5, y: seatY - 30 + wag1 * 0.85 + huntDrop)

        ctx.saveGState()
        let tailColor = earTailColor(coat)
        ctx.setStrokeColor(tailColor.cgColor)
        ctx.setLineWidth(coat == .siamese ? 9.5 : 11.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: root)
        ctx.addCurve(to: tip, control1: c1, control2: c2)
        let tailLine = ctx.path
        ctx.strokePath()
        if patterned(coat), let line = tailLine {
            ctx.saveGState()
            ctx.addPath(line.copy(strokingWithWidth: 11, lineCap: .round, lineJoin: .round, miterLimit: 10))
            ctx.clip()
            ctx.setStrokeColor(rgb(coat == .shorthair ? 0x55595A : 0xA57543, 0.50).cgColor)
            ctx.setLineWidth(3.5); ctx.setLineCap(.butt)
            for t: CGFloat in [0.50, 0.78] {
                let u = 1-t
                let p = CGPoint(x: u*u*u*root.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*tip.x,
                                y: u*u*u*root.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*tip.y)
                let dx = 3*u*u*(c1.x-root.x)+6*u*t*(c2.x-c1.x)+3*t*t*(tip.x-c2.x)
                let dy = 3*u*u*(c1.y-root.y)+6*u*t*(c2.y-c1.y)+3*t*t*(tip.y-c2.y)
                let length = max(0.001, hypot(dx,dy)), nx = -dy/length*8, ny = dx/length*8
                ctx.move(to: CGPoint(x:p.x+nx,y:p.y+ny)); ctx.addLine(to: CGPoint(x:p.x-nx,y:p.y-ny)); ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: - Unified C1-Continuous Cat Silhouette (Crown -> Cheeks -> Plush Neck -> Pear Hips)

    private static func drawUnifiedSilhouette(
        in ctx: CGContext,
        seatX: CGFloat,
        seatY: CGFloat,
        headCenter: CGPoint,
        breath: CGFloat,
        physics: CatPhysics,
        coat: CatCoatTheme
    ) {
        let yaw = physics.headYaw.value
        let pitch = physics.headPitch.value
        let hTilt = physics.headTilt.value
        let bTilt = physics.bodyTilt.value

        let cH = cos(hTilt), sH = sin(hTilt)
        func H(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
            CGPoint(
                x: headCenter.x + lx * cH - ly * sH,
                y: headCenter.y + lx * sH + ly * cH
            )
        }

        let cB = cos(bTilt), sB = sin(bTilt)
        let sy = physics.bodySquash.value
        let sx = 1.0 + (1.0 - sy) * 0.55
        func B(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
            let rx = lx * sx
            let ry = ly * sy
            return CGPoint(
                x: seatX + rx * cB - ry * sB,
                y: seatY + rx * sB + ry * cB
            )
        }

        let isSiamese = (coat == .siamese)
        let cheekShift = yaw * 3.0
        let crownDrop = pitch * 2.0
        let cheekHalfW: CGFloat = isSiamese ? 42.5 : 42.5
        let crownCtrlW: CGFloat = isSiamese ? 25.0 : 26.0
        let crownBaseY: CGFloat = isSiamese ? -29.5 : -30.0
        let cheekY: CGFloat = isSiamese ? 6.5 : 5.0
        let neckPinchX: CGFloat = isSiamese ? 6.5 : 2.5
        let neckCtrlY: CGFloat = isSiamese ? 27.5 : 24.0
        let hipHalfW: CGFloat = isSiamese ? 44.5 : 49.0
        let waistCtrlW: CGFloat = isSiamese ? 41.0 : 51.5
        let waistCtrlY: CGFloat = isSiamese ? -50.0 : -48.0
        let botOuterW: CGFloat = isSiamese ? 42.0 : 47.0
        let botInnerW: CGFloat = isSiamese ? 32.0 : 36.0
        let botHalfW: CGFloat = isSiamese ? 22.0 : 24.0
        let leftCheekX: CGFloat = -cheekHalfW + cheekShift * 0.4
        let rightCheekX: CGFloat = cheekHalfW + cheekShift * 0.4

        // ONE single tangent-continuous closed cubic Bezier path — mathematically impossible to form any ledge or protrusion!
        let crown  = H(cheekShift * 0.2, crownBaseY + crownDrop)
        let rCheek = H(rightCheekX, cheekY)
        let rHip   = B(hipHalfW, -14)
        let rBot   = B(botHalfW, 12)
        let lBot   = B(-botHalfW, 12)
        let lHip   = B(-hipHalfW, -14)
        let lCheek = H(leftCheekX, cheekY)

        let cheekCtrlTopY: CGFloat = isSiamese ? -13.0 : -14.0
        let path = CGMutablePath()
        path.move(to: crown)
        path.addCurve(to: rCheek, control1: H(crownCtrlW + cheekShift * 0.3, crownBaseY + crownDrop), control2: H(rightCheekX + 1.5, cheekCtrlTopY))
        path.addCurve(to: rHip,   control1: H(rightCheekX - neckPinchX, neckCtrlY), control2: B(waistCtrlW, waistCtrlY + breath * 0.5))
        path.addCurve(to: rBot,   control1: B(botOuterW, 5), control2: B(botInnerW, 12))
        path.addLine(to: lBot)
        path.addCurve(to: lHip,   control1: B(-botInnerW, 12), control2: B(-botOuterW, 5))
        path.addCurve(to: lCheek, control1: B(-waistCtrlW, waistCtrlY + breath * 0.5), control2: H(leftCheekX + neckPinchX, neckCtrlY))
        path.addCurve(to: crown,  control1: H(leftCheekX - 1.5, cheekCtrlTopY), control2: H(-crownCtrlW + cheekShift * 0.3, crownBaseY + crownDrop))
        path.closeSubpath()

        ctx.saveGState()
        if coat != .siamese {
            ctx.setFillColor(bodyColor(coat).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            if patterned(coat) {
                ctx.saveGState(); ctx.addPath(path); ctx.clip()
                drawCoatMarks(in: ctx, seatX: seatX, seatY: seatY, head: headCenter, physics: physics, coat: coat)
                ctx.restoreGState()
            }
        } else {
            // Siamese warm oat-milk cream gradient + soft toasted back shading + 2.5D rotating seal-point face mask!
            ctx.addPath(path)
            ctx.clip()

            let cs = CGColorSpaceCreateDeviceRGB()
            let bodyColors = [siameseCream.cgColor, siameseLatte.cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: bodyColors, locations: [0.15, 1.0]) {
                ctx.drawLinearGradient(
                    grad,
                    start: CGPoint(x: seatX, y: headCenter.y - 34),
                    end: CGPoint(x: seatX, y: seatY + 18),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }

            // Soft toasted ear-base blend at top crown so espresso ears melt organically into cream head
            let yawRad = yaw * 0.50
            let pitchRad = pitch * 0.36
            ctx.saveGState()
            ctx.translateBy(x: headCenter.x, y: headCenter.y)
            ctx.rotate(by: hTilt)

            // 2.5D Rotating Seal-Point "挖煤" Face Mask (layered soft mocha halo + velvety seal-brown muzzle!)
            let maskCenter = projectHead3D(x: 0, y: 3.0, z: 27.0, yawRad: yawRad, pitchRad: pitchRad).pt
            let maskScaleX = max(0.76, cos(yawRad * 0.7))
            let maskScaleY = max(0.82, cos(pitchRad * 0.7))

            // Layer 1: Soft wide eye-and-cheek mocha mask halo (startRadius: 0 so there is NEVER a center hole!)
            ctx.saveGState()
            ctx.translateBy(x: maskCenter.x, y: maskCenter.y)
            ctx.scaleBy(x: maskScaleX * 1.24, y: maskScaleY * 0.88)
            let maskColors = [
                siamesePoint.cgColor,
                siamesePoint.withAlphaComponent(0.92).cgColor,
                siameseMocha.withAlphaComponent(0.62).cgColor,
                siameseMocha.withAlphaComponent(0.0).cgColor
            ] as CFArray
            if let maskGrad = CGGradient(colorsSpace: cs, colors: maskColors, locations: [0.0, 0.42, 0.74, 1.0]) {
                ctx.drawRadialGradient(
                    maskGrad,
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: 31.5,
                    options: [.drawsBeforeStartLocation]
                )
            }
            ctx.restoreGState()

            // Layer 2: Soft warm cocoa muzzle depth below eyes
            let muzzleCenter = projectHead3D(x: 0, y: 7.5, z: 28.0, yawRad: yawRad, pitchRad: pitchRad).pt
            ctx.saveGState()
            ctx.translateBy(x: muzzleCenter.x, y: muzzleCenter.y)
            ctx.scaleBy(x: maskScaleX * 1.04, y: maskScaleY * 0.76)
            let muzzleColors = [
                siamesePoint.cgColor,
                siamesePoint.withAlphaComponent(0.85).cgColor,
                siamesePoint.withAlphaComponent(0.0).cgColor
            ] as CFArray
            if let muzGrad = CGGradient(colorsSpace: cs, colors: muzzleColors, locations: [0.0, 0.50, 1.0]) {
                ctx.drawRadialGradient(
                    muzGrad,
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: 19.5,
                    options: [.drawsBeforeStartLocation]
                )
            }
            ctx.restoreGState()
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Ultra-soft plush rim on Siamese cream body (never a harsh dark outline)
        if coat == .siamese {
            ctx.saveGState()
            ctx.setStrokeColor(siameseOutline.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Tucked hind paws peeking softly along bottom edge
        ctx.saveGState()
        ctx.translateBy(x: seatX, y: seatY)
        ctx.rotate(by: bTilt)
        ctx.scaleBy(x: sx, y: sy)
        ctx.setFillColor(pawColor(coat).cgColor)

        let leftHindX: CGFloat = isSiamese ? -31.0 : -35.0
        let hindW: CGFloat = isSiamese ? 15.5 : 17.0
        let rightHindX: CGFloat = isSiamese ? 15.5 : 18.0
        let leftHindY: CGFloat = isSiamese ? 3.5 : 3.0
        let leftHindH: CGFloat = isSiamese ? 12.0 : 11.0
        let rightHindY: CGFloat = (coat == .classicBlack || isSiamese) ? 4.5 : 3.0
        let rightHindH: CGFloat = (coat == .classicBlack || isSiamese) ? 12.5 : 11.0

        ctx.fillEllipse(in: CGRect(x: leftHindX, y: leftHindY, width: hindW, height: leftHindH))
        if physics.hindFootActive.value < 0.35 {
            ctx.fillEllipse(in: CGRect(x: rightHindX, y: rightHindY, width: hindW, height: rightHindH))
        }

        // Subtle bottom rim highlights on tucked haunches
        let rimColor = (coat == .siamese) ? siameseCream.withAlphaComponent(0.55) : creaseColor(coat).withAlphaComponent(0.58)
        ctx.setStrokeColor(rimColor.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: leftHindX + hindW * 0.5, y: leftHindY + leftHindH * 0.5), radius: 7.5, startAngle: 0.25, endAngle: .pi - 0.25, clockwise: false)
        ctx.strokePath()
        if physics.hindFootActive.value < 0.35 {
            ctx.addArc(center: CGPoint(x: rightHindX + hindW * 0.5, y: rightHindY + rightHindH * 0.5), radius: 7.5, startAngle: 0.25, endAngle: .pi - 0.25, clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func coatMarkPoint(_ p: CGPoint, headSurface: Bool, skull: Bool, coat: CatCoatTheme, seatX: CGFloat, seatY: CGFloat,
                                      head: CGPoint, physics: CatPhysics) -> CGPoint {
        if headSurface {
            let depth: CGFloat = coat == .orangeWhite
                ? 29.6 * sqrt(max(0, 1 - pow(p.x / 46, 2) - pow(p.y / 40, 2))) : 27.5
            let projected = skull ? p : projectHead3D(x: p.x, y: p.y, z: depth,
                                          yawRad: physics.headYaw.value * 0.50,
                                          pitchRad: physics.headPitch.value * 0.36).pt
            let c = cos(physics.headTilt.value), s = sin(physics.headTilt.value)
            return CGPoint(x: head.x + projected.x*c - projected.y*s,
                           y: head.y + projected.x*s + projected.y*c)
        }
        let sy = physics.bodySquash.value, sx = 1 + (1 - sy) * 0.55
        let c = cos(physics.bodyTilt.value), s = sin(physics.bodyTilt.value)
        return CGPoint(x: seatX + p.x*sx*c - p.y*sy*s,
                       y: seatY + p.x*sx*s + p.y*sy*c)
    }
    private static func drawCoatMarks(in ctx: CGContext, seatX: CGFloat, seatY: CGFloat,
                                      head: CGPoint, physics: CatPhysics, coat: CatCoatTheme) {
        let marks = CoatPatterns.marks(for: coat)
        func markPath(_ mark: CoatMark) -> CGMutablePath {
            let path = CGMutablePath()
            for (i, point) in mark.points.enumerated() {
                let p = coatMarkPoint(point, headSurface: mark.head, skull: mark.skull, coat: coat, seatX: seatX, seatY: seatY, head: head, physics: physics)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            if mark.width == 0 { path.closeSubpath() }
            return path
        }
        for mark in marks {
            ctx.saveGState()
            let path = markPath(mark)
            let color = rgb(mark.rgb, mark.alpha)
            if mark.width == 0 {
                path.closeSubpath(); ctx.setFillColor(color.cgColor); ctx.addPath(path); ctx.fillPath()
            } else {
                ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(mark.width)
                ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.addPath(path); ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: - 3rd Key Hind Foot Easter Egg

    private static func drawHindFoot(in ctx: CGContext, seatX: CGFloat, seatY: CGFloat, physics: CatPhysics, coat: CatCoatTheme) {
        let hip = CGPoint(x: seatX + 26, y: seatY + 2)
        let target = physics.hindFoot.point
        let mid = CGPoint(
            x: (hip.x + target.x) * 0.5 + 10,
            y: (hip.y + target.y) * 0.5 - 8
        )

        drawLimb(
            in: ctx,
            start: hip,
            control: mid,
            end: target,
            startWidth: 15.0,
            endWidth: 12.0,
            outlineOnLeftSide: true,
            outlineAlpha: 0.85 * physics.hindFootActive.value,
            coat: coat
        )
    }

    // MARK: - 2.5D Spherical Head Projection Helper

    /// Projects a 3D point on the cat's head ellipsoid rotated by (yawRad, pitchRad)
    /// into 2D head-local coordinates — creating true Live2D-style 2.5D head turning!
    static func projectHead3D(
        x: CGFloat, y: CGFloat, z: CGFloat,
        yawRad: CGFloat, pitchRad: CGFloat
    ) -> (pt: CGPoint, z: CGFloat) {
        // 1. Yaw around Y axis (positive yaw = turning right toward viewer's right)
        let cy = cos(yawRad)
        let sy = sin(yawRad)
        let x1 = x * cy + z * sy
        let z1 = -x * sy + z * cy

        // 2. Pitch around X axis (positive pitch = nodding down)
        let cp = cos(pitchRad)
        let sp = sin(pitchRad)
        let y2 = y * cp + z1 * sp
        let z2 = -y * sp + z1 * cp

        return (CGPoint(x: x1, y: y2), z2)
    }

    // MARK: - 2.5D Ears Layer (drawn behind unified silhouette so Siamese seal-point ears emerge organically!)

    static func drawEarsLayer(
        in ctx: CGContext,
        center: CGPoint,
        physics: CatPhysics,
        coat: CatCoatTheme
    ) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: physics.headTilt.value)

        let yawRad = physics.headYaw.value * 0.50
        let pitchRad = physics.headPitch.value * 0.36
        let fold = physics.earFold.value
        let twitch = physics.earTwitch.value * 0.045

        drawEar3D(in: ctx, isLeft: true, yawRad: yawRad, pitchRad: pitchRad, fold: fold, twitch: twitch, coat: coat)
        drawEar3D(in: ctx, isLeft: false, yawRad: yawRad, pitchRad: pitchRad, fold: fold, twitch: -twitch, coat: coat)

        ctx.restoreGState()
    }

    // MARK: - 2.5D Head Features (Luminous Eyes & Whiskers)

    private static func drawHeadFeatures(
        in ctx: CGContext,
        center: CGPoint,
        physics: CatPhysics,
        eyeTheme: EyeColorTheme,
        coat: CatCoatTheme
    ) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: physics.headTilt.value)

        let yaw = physics.headYaw.value      // -1 (left) .. +1 (right)
        let pitch = physics.headPitch.value  // -1 (up)   .. +1 (down)
        let yawRad = yaw * 0.50              // ~±28.5° authentic head turn
        let pitchRad = pitch * 0.36          // ~±20.5° authentic head nod

        // 1. 3D-Projected Eyes with authentic spherical foreshortening & parallax!
        drawEye3D(in: ctx, isLeft: true, yawRad: yawRad, pitchRad: pitchRad, physics: physics, eyeTheme: eyeTheme, coat: coat)
        drawEye3D(in: ctx, isLeft: false, yawRad: yawRad, pitchRad: pitchRad, physics: physics, eyeTheme: eyeTheme, coat: coat)

        // 1b. Cute little kitty nose + delicate `:3` mouth hint on Siamese (小豆泥 charm!)
        if coat == .siamese {
            let nose = projectHead3D(x: 0, y: 8.2, z: 29.0, yawRad: yawRad, pitchRad: pitchRad).pt
            let mouthL = projectHead3D(x: -4.2, y: 12.2, z: 28.4, yawRad: yawRad, pitchRad: pitchRad).pt
            let mouthM = projectHead3D(x: 0, y: 11.2, z: 28.8, yawRad: yawRad, pitchRad: pitchRad).pt
            let mouthR = projectHead3D(x: 4.2, y: 12.2, z: 28.4, yawRad: yawRad, pitchRad: pitchRad).pt
            ctx.saveGState()
            // Tiny warm dark-rose-espresso triangle nose
            let nPath = CGMutablePath()
            nPath.move(to: CGPoint(x: nose.x - 2.3, y: nose.y - 1.1))
            nPath.addQuadCurve(to: CGPoint(x: nose.x + 2.3, y: nose.y - 1.1), control: CGPoint(x: nose.x, y: nose.y - 1.6))
            nPath.addQuadCurve(to: CGPoint(x: nose.x, y: nose.y + 1.5), control: CGPoint(x: nose.x + 1.8, y: nose.y + 0.6))
            nPath.addQuadCurve(to: CGPoint(x: nose.x - 2.3, y: nose.y - 1.1), control: CGPoint(x: nose.x - 1.8, y: nose.y + 0.6))
            nPath.closeSubpath()
            ctx.setFillColor(NSColor(calibratedRed: 0.14, green: 0.09, blue: 0.08, alpha: 0.95).cgColor)
            ctx.addPath(nPath)
            ctx.fillPath()
            // Delicate light-mocha `ω` kitty mouth
            ctx.setStrokeColor(NSColor(calibratedRed: 0.78, green: 0.66, blue: 0.56, alpha: 0.55).cgColor)
            ctx.setLineWidth(1.05)
            ctx.setLineCap(.round)
            ctx.move(to: mouthL)
            ctx.addQuadCurve(to: mouthM, control: CGPoint(x: (mouthL.x + mouthM.x) * 0.5, y: mouthL.y + 1.6))
            ctx.addQuadCurve(to: mouthR, control: CGPoint(x: (mouthM.x + mouthR.x) * 0.5, y: mouthR.y + 1.6))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 1c. 张嘴：唱歌 / 打哈欠 / 舔爪子
        let open = max(0, min(1, physics.mouthOpen.value))
        if open > 0.04 {
            let mouth = projectHead3D(x: 0, y: 13.5, z: 28.2, yawRad: yawRad, pitchRad: pitchRad).pt
            let w = 4.5 + open * 5.5
            let h = 2 + open * 9
            let rect = CGRect(x: mouth.x - w / 2, y: mouth.y - 1.5, width: w, height: h)
            ctx.saveGState()
            ctx.setFillColor(rgb(0x3A1C1F).cgColor)
            ctx.fillEllipse(in: rect)
            // 舌头：下半部分的粉色
            ctx.addEllipse(in: rect)
            ctx.clip()
            ctx.setFillColor(rgb(0xF08A9B).cgColor)
            ctx.fillEllipse(in: CGRect(x: rect.minX + w * 0.12, y: rect.minY + h * 0.52, width: w * 0.76, height: h * 0.7))
            ctx.restoreGState()
            // 黑猫的嘴和脸同色，描一圈浅色边才看得见
            if coat == .classicBlack {
                ctx.saveGState()
                ctx.setStrokeColor(contourMint.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(0.9)
                ctx.strokeEllipse(in: rect)
                ctx.restoreGState()
            }
        }

        // 2. 3D-Projected Whiskers (outer-side whiskers poke out past silhouette when turning!)
        drawWhiskers3D(in: ctx, yawRad: yawRad, pitchRad: pitchRad, physics: physics, coat: coat)

        ctx.restoreGState()
    }

    private static func drawEar3D(
        in ctx: CGContext,
        isLeft: Bool,
        yawRad: CGFloat,
        pitchRad: CGFloat,
        fold: CGFloat,
        twitch: CGFloat,
        coat: CatCoatTheme
    ) {
        let sign: CGFloat = isLeft ? -1.0 : 1.0
        let isSiamese = (coat == .siamese)
        // Siamese (小豆泥 style): cute, compact, softly-rounded triangular cat ears
        let foldAngle = sign * ((isSiamese ? 0.14 : 0.06) + fold * 0.34) + twitch
        let earLen: CGFloat = isSiamese ? 29.5 : 32.0

        let tipDx = sin(foldAngle) * earLen
        let tipDy = -cos(foldAngle) * earLen

        // Bases anchored comfortably inside the upper skull contour so they merge seamlessly at every yaw/pitch!
        let innerBase3D = projectHead3D(x: sign * (isSiamese ? 10.0 : 9.0), y: isSiamese ? -16.5 : -16.0, z: 0.0, yawRad: yawRad, pitchRad: pitchRad).pt
        let outerBase3D = projectHead3D(x: sign * (isSiamese ? 35.5 : 35.0), y: isSiamese ? -4.5 : -5.0, z: -2.0, yawRad: yawRad, pitchRad: pitchRad).pt
        let tip3D       = projectHead3D(x: sign * (isSiamese ? 25.0 : 24.5) + tipDx, y: (isSiamese ? -18.5 : -20.0) + tipDy, z: -3.0, yawRad: yawRad, pitchRad: pitchRad).pt

        // Soft plush rounded-tip feline ear
        let tipSpread: CGFloat = isSiamese ? 4.2 : 3.8
        let tipLeft  = CGPoint(x: tip3D.x - sign * tipSpread, y: tip3D.y + 2.8)
        let tipRight = CGPoint(x: tip3D.x + sign * tipSpread, y: tip3D.y + 3.2)

        let ear = CGMutablePath()
        ear.move(to: innerBase3D)
        ear.addQuadCurve(
            to: tipLeft,
            control: CGPoint(x: (innerBase3D.x + tipLeft.x) * 0.5 - sign * 1.5, y: (innerBase3D.y + tipLeft.y) * 0.5 - 2.0)
        )
        ear.addQuadCurve(to: tipRight, control: CGPoint(x: tip3D.x, y: tip3D.y - 2.2))
        ear.addQuadCurve(
            to: outerBase3D,
            control: CGPoint(x: (outerBase3D.x + tipRight.x) * 0.5 + sign * 2.5, y: (outerBase3D.y + tipRight.y) * 0.5 - 2.0)
        )
        ear.closeSubpath()

        ctx.saveGState()
        ctx.setFillColor(earTailColor(coat).cgColor)
        ctx.addPath(ear)
        ctx.fillPath()

        // Cute warm dusty-cocoa inner ear hollow on Siamese so big ears look soft & unmistakably cat-like
        if isSiamese {
            let inI = CGPoint(x: innerBase3D.x + (tip3D.x - innerBase3D.x) * 0.24 + sign * 3.0,
                              y: innerBase3D.y + (tip3D.y - innerBase3D.y) * 0.16)
            let outI = CGPoint(x: outerBase3D.x + (tip3D.x - outerBase3D.x) * 0.20 - sign * 3.8,
                               y: outerBase3D.y + (tip3D.y - outerBase3D.y) * 0.18)
            let tipI = CGPoint(x: (innerBase3D.x + outerBase3D.x) * 0.16 + tip3D.x * 0.68,
                               y: (innerBase3D.y + outerBase3D.y) * 0.14 + tip3D.y * 0.72 + 2.5)
            let inner = CGMutablePath()
            inner.move(to: inI)
            inner.addQuadCurve(to: tipI, control: CGPoint(x: (inI.x + tipI.x) * 0.5 - sign * 0.8, y: (inI.y + tipI.y) * 0.5))
            inner.addQuadCurve(to: outI, control: CGPoint(x: (outI.x + tipI.x) * 0.5 + sign * 1.2, y: (outI.y + tipI.y) * 0.5))
            inner.closeSubpath()
            ctx.setFillColor(siameseInnerEar.cgColor)
            ctx.addPath(inner)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawEye3D(
        in ctx: CGContext,
        isLeft: Bool,
        yawRad: CGFloat,
        pitchRad: CGFloat,
        physics: CatPhysics,
        eyeTheme: EyeColorTheme,
        coat: CatCoatTheme
    ) {
        let sign: CGFloat = isLeft ? -1.0 : 1.0
        let eyeColor = eyeTheme.primaryColor

        // Eye sits on the front surface of the 3D head sphere at (±17.5, -2.0, +28.0)
        let proj = projectHead3D(x: sign * 17.2, y: -2.0, z: 27.5, yawRad: yawRad, pitchRad: pitchRad)

        // Authentic spherical foreshortening: the eye turning away toward the edge narrows horizontally!
        let eyeNormalAngle = yawRad + sign * 0.34
        let foreshortenX = max(0.64, min(1.06, cos(eyeNormalAngle) / cos(0.34)))
        let foreshortenY = max(0.78, min(1.03, cos(pitchRad * 0.85)))

        ctx.saveGState()
        ctx.translateBy(x: proj.pt.x, y: proj.pt.y)
        ctx.scaleBy(x: foreshortenX, y: foreshortenY)

        // Mode 1: Happy closed glowing lime-green curved line eyes (petting head!)
        if physics.isHappyClosedEyes {
            ctx.setStrokeColor(eyeColor.cgColor)
            ctx.setLineWidth(2.6)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: -11.5, y: 1.0))
            ctx.addQuadCurve(
                to: CGPoint(x: 11.5, y: 1.0),
                control: CGPoint(x: sign * 1.5, y: 3.4)
            )
            ctx.strokePath()
            ctx.restoreGState()
            return
        }

        // Mode 2: Blissful half-squint glowing lime slits (petting back/body!)
        if physics.isBlissfulSquint {
            ctx.setFillColor(eyeColor.cgColor)
            let slit = CGMutablePath()
            slit.move(to: CGPoint(x: -11.5, y: -0.5))
            slit.addQuadCurve(to: CGPoint(x: 11.5, y: -0.5), control: CGPoint(x: 0, y: 0.6))
            slit.addQuadCurve(to: CGPoint(x: -11.5, y: -0.5), control: CGPoint(x: 0, y: 4.8))
            slit.closeSubpath()
            ctx.addPath(slit)
            ctx.fillPath()
            ctx.restoreGState()
            return
        }

        let hunt = max(0, min(1, physics.huntIntensity.value))

        // Subtle feline eye angle (straightens slightly when wide-eyed hunting!)
        ctx.rotate(by: sign * (0.06 * (1.0 - hunt * 0.6)))

        // Eyes grow rounder & slightly larger in full hunting focus!
        let isSiameseEye = (coat == .siamese && eyeTheme == .siameseBlue)
        let rx: CGFloat = (isSiameseEye ? 11.4 + hunt * 1.3 : 12.0 + hunt * 1.1)
        let ry: CGFloat = (isSiameseEye ? 9.8 + hunt * 2.0 : 10.8 + hunt * 1.8)
        let eyeRect = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)

        // Clip to the visible opening before painting any iris/pupil pixels.
        // Painting a lid over an antialiased oval leaves a colored fringe.
        ctx.saveGState()
        ctx.addEllipse(in: eyeRect)
        ctx.clip()

        let closure = max(0, min(1, physics.effectiveEyeClosure))
        if closure >= 1 {
            ctx.restoreGState()
            ctx.restoreGState()
            return
        }
        if closure > 0 {
            ctx.clip(to: CGRect(x: -rx - 2, y: -ry + 2 * ry * closure,
                                width: 2 * rx + 4, height: 2 * ry * (1 - closure)))
        }

        // Luminous iris (flat-art translucent pale crystal ice-blue top-to-bottom wash for Siamese!)
        ctx.setFillColor(eyeColor.cgColor)
        ctx.fill(eyeRect)
        if eyeTheme == .siameseBlue {
            let cs = CGColorSpaceCreateDeviceRGB()
            let irisCols = [
                NSColor(calibratedRed: 0.56, green: 0.77, blue: 0.90, alpha: 1.0).cgColor,  // #8FC4E6 soft cool upper iris
                NSColor(calibratedRed: 0.71, green: 0.87, blue: 0.96, alpha: 1.0).cgColor,  // #B5DEF5 airy pale sky blue
                NSColor(calibratedRed: 0.86, green: 0.945, blue: 0.99, alpha: 1.0).cgColor  // #DBF1FC clear luminous lower iris
            ] as CFArray
            if let irisGrad = CGGradient(colorsSpace: cs, colors: irisCols, locations: [0.0, 0.55, 1.0]) {
                ctx.drawLinearGradient(
                    irisGrad,
                    start: CGPoint(x: 0, y: -ry),
                    end: CGPoint(x: 0, y: ry),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
        }

        // Pupil morphs smoothly from vertical almond slit -> HUGE round black boba pupil when hunting!
        let gaze = physics.eyeGaze.point
        let px = gaze.x * (4.2 - hunt * 1.2)
        let py = gaze.y * (3.6 - hunt * 1.0)
        let pScale = physics.pupilScale.value
        let normalW: CGFloat = 5.0 * pScale
        let normalH: CGFloat = 13.5 * min(1.12, pScale)
        let huntDiameter: CGFloat = 18.8 // huge round boba pupil leaving an electric chartreuse ring!
        let pupilW = normalW + (huntDiameter - normalW) * hunt
        let pupilH = normalH + (huntDiameter - normalH) * hunt
        let pupilRect = CGRect(x: px - pupilW * 0.5, y: py - pupilH * 0.5, width: pupilW, height: pupilH)
        // Photo-sampled hazel: #DAB257 outside, a narrow #8D9180 ring by the pupil.
        // Paint inside the existing lid clip and follow the animated pupil position/size.
        if eyeTheme == .referenceHazel {
            for i in 0...24 {
                let t = CGFloat(i) / 24
                let mix = t * t * (3 - 2 * t)
                ctx.setFillColor(NSColor(calibratedRed: (218 - 77 * mix)/255,
                    green: (178 - 33 * mix)/255, blue: (87 + 41 * mix)/255, alpha: 1).cgColor)
                let rim = (1 - t) * 2.2
                ctx.fillEllipse(in: pupilRect.insetBy(dx: -rim, dy: -rim))
            }
        }
        ctx.setFillColor(catBlack.cgColor)
        ctx.fillEllipse(in: pupilRect)

        // Tiny crisp white specular sparkle dot (subtle catchlight on translucent Siamese blue eyes + hunting boba sparkle!)
        if hunt > 0.25 {
            let glintAlpha = min(1.0, (hunt - 0.25) / 0.55) * 0.92
            ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: glintAlpha).cgColor)
            let glintR: CGFloat = 2.1 + hunt * 0.9
            ctx.fillEllipse(in: CGRect(
                x: px - pupilW * 0.22 - glintR * 0.5,
                y: py - pupilH * 0.22 - glintR * 0.5,
                width: glintR * 2,
                height: glintR * 2
            ))
        } else if eyeTheme == .siameseBlue {
            ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.86).cgColor)
            let glintR: CGFloat = 1.65
            ctx.fillEllipse(in: CGRect(
                x: px - 2.9 - glintR,
                y: py - 3.6 - glintR,
                width: glintR * 2,
                height: glintR * 2
            ))
        }

        ctx.restoreGState()
        ctx.restoreGState()
    }

    private static func drawWhiskers3D(
        in ctx: CGContext,
        yawRad: CGFloat,
        pitchRad: CGFloat,
        physics: CatPhysics,
        coat: CatCoatTheme
    ) {
        let wiggle = sin(physics.time * 4.5) * (max(physics.petHeadIntensity, physics.petBodyIntensity) * 1.2)
        ctx.saveGState()
        let wColor = (coat == .siamese) ? siameseWhisker : (patterned(coat) ? rgb(0x8D8170) : whiskerColor).withAlphaComponent(0.68)
        ctx.setStrokeColor(wColor.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineCap(.round)

        // 3D cheek whiskers — when turning left, left whiskers naturally poke past silhouette
        // while right whiskers sweep inward across the cheek (exact Xiaohongshu effect!)
        for sign in [-1.0, 1.0] as [CGFloat] {
            let rows: [(CGFloat, CGFloat, CGFloat)] = [
                (10.5, 36.5, 8.8 + wiggle),
                (14.2, 37.8, 14.2 + wiggle * 0.5),
                (18.0, 35.5, 19.6 - wiggle * 0.4)
            ]
            for (y0, xEnd, yEnd) in rows {
                let p0 = projectHead3D(x: sign * 24.0, y: y0, z: 23.0, yawRad: yawRad, pitchRad: pitchRad).pt
                let p2 = projectHead3D(x: sign * xEnd, y: yEnd, z: 14.0, yawRad: yawRad, pitchRad: pitchRad).pt
                let ctrl = CGPoint(x: (p0.x + p2.x) * 0.5, y: (p0.y + p2.y) * 0.5 - 0.8)
                ctx.move(to: p0)
                ctx.addQuadCurve(to: p2, control: ctrl)
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Front Paws (Idle Sitting & Dynamic Reaching with Signature Outlines / Siamese Socks)

    private static func drawFrontPaws(
        in ctx: CGContext,
        seatX: CGFloat,
        seatY: CGFloat,
        breath: CGFloat,
        physics: CatPhysics,
        coat: CatCoatTheme
    ) {
        let lPos = physics.leftPaw.point
        let rPos = physics.rightPaw.point

        let lDist = hypot(lPos.x - CatPhysics.leftPawRest.x, lPos.y - CatPhysics.leftPawRest.y)
        let rDist = hypot(rPos.x - CatPhysics.rightPawRest.x, rPos.y - CatPhysics.rightPawRest.y)

        // Attach to the transformed chest, below the moving face rather than its white blaze.
        let isSiamese = (coat == .siamese)
        let siameseLift: CGFloat = isSiamese ? -3.0 : 0.0
        let idleTopY: CGFloat = isSiamese ? seatY - 31 : seatY - 30
        let idleTopX: CGFloat = isSiamese ? 16.5 : 18.0
        let idleBotX: CGFloat = isSiamese ? 15.0 : 16.0
        let shX: CGFloat = isSiamese ? 18.5 : 20.0
        func shoulder(_ x: CGFloat) -> CGPoint {
            let sy = physics.bodySquash.value, sx = 1 + (1 - sy) * 0.55
            let c = cos(physics.bodyTilt.value), s = sin(physics.bodyTilt.value)
            let faceBottom = 126 + siameseLift + physics.headOffsetY.value + physics.headPitch.value * 4.8 + breath * 1.1 + 52
            return CGPoint(x: seatX + x*sx*c + 43*sy*s,
                           y: max(seatY + x*sx*s - 43*sy*c, faceBottom))
        }
        let leftShoulder = shoulder(-shX)
        let rightShoulder = shoulder(shX)

        // Left arm
        if lDist < 6.0 && !physics.leftPawOnMouse && !physics.leftPawTyping {
            drawIdleFrontLeg(in: ctx, top: CGPoint(x: seatX - idleTopX, y: idleTopY), bottom: CGPoint(x: seatX - idleBotX, y: seatY + 12), isLeft: true, coat: coat)
        } else {
            let mid = CGPoint(
                x: (leftShoulder.x + lPos.x) * 0.5 - (physics.leftPawOnMouse ? 8 : 4),
                y: (leftShoulder.y + lPos.y) * 0.5 - 6
            )
            drawLimb(
                in: ctx,
                start: leftShoulder,
                control: mid,
                end: lPos,
                startWidth: isSiamese ? 17.0 : 19.0,
                endWidth: isSiamese ? 12.5 : 13.5,
                outlineOnLeftSide: false,
                outlineAlpha: 0.78,
                coat: coat
            )
        }

        // Right arm
        if rDist < 6.0 && !physics.rightPawTyping {
            drawIdleFrontLeg(in: ctx, top: CGPoint(x: seatX + idleTopX, y: idleTopY), bottom: CGPoint(x: seatX + idleBotX, y: seatY + 12), isLeft: false, coat: coat)
        } else {
            let mid = CGPoint(
                x: (rightShoulder.x + rPos.x) * 0.5 + 4,
                y: (rightShoulder.y + rPos.y) * 0.5 - 6
            )
            drawLimb(
                in: ctx,
                start: rightShoulder,
                control: mid,
                end: rPos,
                startWidth: isSiamese ? 17.0 : 19.0,
                endWidth: isSiamese ? 12.5 : 13.5,
                outlineOnLeftSide: true,
                outlineAlpha: 0.78,
                coat: coat
            )
        }
    }

    /// Signature tucked sitting front legs (black with mint lines OR Siamese cream-to-chocolate socks!)
    private static func drawIdleFrontLeg(in ctx: CGContext, top: CGPoint, bottom: CGPoint, isLeft: Bool, coat: CatCoatTheme) {
        let sign: CGFloat = isLeft ? -1.0 : 1.0
        ctx.saveGState()

        if coat == .siamese {
            // Creamy upper leg dipping smoothly into adorable seal-point chocolate socks resting on the keyboard!
            let legRect = CGRect(x: bottom.x - 7.5, y: top.y, width: 15.0, height: bottom.y - top.y + 5.0)
            let legPath = CGPath(roundedRect: legRect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
            ctx.saveGState()
            ctx.addPath(legPath)
            ctx.clip()
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [
                siameseCream.withAlphaComponent(0.0).cgColor,
                siameseMocha.withAlphaComponent(0.75).cgColor,
                siamesePoint.cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.05, 0.50, 0.82]) {
                ctx.drawLinearGradient(
                    grad,
                    start: CGPoint(x: top.x, y: top.y),
                    end: CGPoint(x: bottom.x, y: bottom.y + 5.0),
                    options: []
                )
            }
            ctx.restoreGState()
        }

        if patterned(coat) || coat == .classicBlack {
            ctx.setFillColor(pawColor(coat).cgColor)
            let cuff = CGRect(x: bottom.x - 7.5, y: bottom.y - 13, width: 15, height: 18)
            ctx.addPath(CGPath(roundedRect: cuff, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
            ctx.fillPath()
        }
        let lineColor = (coat == .siamese) ? siameseCrease : creaseColor(coat)
        ctx.setStrokeColor(lineColor.cgColor)
        ctx.setLineWidth(1.45)
        ctx.setLineCap(.round)

        // Outer separation crease
        ctx.move(to: CGPoint(x: top.x + sign * 8.5, y: top.y))
        ctx.addQuadCurve(
            to: CGPoint(x: bottom.x + sign * 7.5, y: bottom.y - 1),
            control: CGPoint(x: top.x + sign * 9.5, y: (top.y + bottom.y) * 0.5)
        )
        // Inner separation crease
        ctx.move(to: CGPoint(x: top.x - sign * 7.0, y: top.y + 4))
        ctx.addQuadCurve(
            to: CGPoint(x: bottom.x - sign * 6.0, y: bottom.y - 1),
            control: CGPoint(x: top.x - sign * 6.5, y: (top.y + bottom.y) * 0.5)
        )
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Smooth tapered limb + plump rounded paw (matte black OR Siamese cream-to-espresso chocolate socks!)
    private static func drawLimb(
        in ctx: CGContext,
        start: CGPoint,
        control: CGPoint,
        end: CGPoint,
        startWidth: CGFloat,
        endWidth: CGFloat,
        outlineOnLeftSide: Bool,
        outlineAlpha: CGFloat,
        coat: CatCoatTheme
    ) {
        let steps = 14
        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = quadPoint(start, control, end, t: t)
            let tan = quadTangent(start, control, end, t: t)
            let len = max(0.001, hypot(tan.x, tan.y))
            let nx = -tan.y / len
            let ny = tan.x / len
            let halfW = (startWidth + (endWidth - startWidth) * t) * 0.5
            leftEdge.append(CGPoint(x: p.x + nx * halfW, y: p.y + ny * halfW))
            rightEdge.append(CGPoint(x: p.x - nx * halfW, y: p.y - ny * halfW))
        }

        let limbPath = CGMutablePath()
        limbPath.move(to: leftEdge[0])
        for pt in leftEdge.dropFirst() { limbPath.addLine(to: pt) }
        for pt in rightEdge.reversed() { limbPath.addLine(to: pt) }
        let tangent = quadTangent(start, control, end, t: 0)
        let length = max(0.001, hypot(tangent.x, tangent.y))
        limbPath.addQuadCurve(to: leftEdge[0], control: CGPoint(
            x: start.x - tangent.x/length*startWidth*0.5,
            y: start.y - tangent.y/length*startWidth*0.5))
        limbPath.closeSubpath()

        let pawR = endWidth * 0.58
        let pawRect = CGRect(x: end.x - pawR, y: end.y - pawR * 0.85, width: pawR * 2, height: pawR * 1.7)

        ctx.saveGState()
        if coat != .siamese {
            ctx.setFillColor(limbColor(coat).cgColor)
            ctx.addPath(limbPath)
            if patterned(coat) {
                ctx.saveGState(); ctx.clip()
                let colors = [pawColor(coat).cgColor, limbColor(coat).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.30]) {
                    ctx.drawLinearGradient(gradient, start: start, end: end,
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                ctx.restoreGState()
            } else { ctx.fillPath() }
            if !patterned(coat) { ctx.fillEllipse(in: pawRect) }
            if patterned(coat) {
                let cuff = CGMutablePath()
                let first = Int(CGFloat(steps) * 0.72)
                cuff.move(to: leftEdge[first])
                for pt in leftEdge.dropFirst(first + 1) { cuff.addLine(to: pt) }
                for pt in rightEdge.dropFirst(first).reversed() { cuff.addLine(to: pt) }
                cuff.closeSubpath()
                ctx.setFillColor(pawColor(coat).cgColor); ctx.addPath(cuff); ctx.fillPath()
                ctx.fillEllipse(in: pawRect)
            }
        } else {
            // Siamese chocolate-dipped socks gradient along the limb!
            // Starts transparent at shoulder (0.0) so it melts 100% seamlessly into the creamy chest!
            ctx.saveGState()
            ctx.addPath(limbPath)
            ctx.clip()
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [
                siameseCream.withAlphaComponent(0.0).cgColor,
                siameseCream.cgColor,
                siameseMocha.cgColor,
                siamesePoint.cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 0.16, 0.48, 0.78]) {
                ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()

            // Solid rich espresso-chocolate rounded paw tip (no winding-rule overlap artifacts!)
            ctx.setFillColor(siamesePoint.cgColor)
            ctx.fillEllipse(in: pawRect)

            // Clean outer edge outline on Siamese arm (fading in below shoulder) so it reads crisply over light backgrounds
            ctx.setStrokeColor(siameseOutline.withAlphaComponent(0.72).cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let outerEdge = outlineOnLeftSide ? rightEdge : leftEdge
            if outerEdge.count > 4 {
                ctx.move(to: outerEdge[3])
                for idx in 4..<(outerEdge.count - 1) { ctx.addLine(to: outerEdge[idx]) }
                ctx.strokePath()
            }
        }

        // Crisp separation stroke along upper-to-mid arm where it crosses the torso
        let highlightEdge = outlineOnLeftSide ? leftEdge : rightEdge
        if highlightEdge.count > 6 {
            let strokeColor = (coat == .siamese)
                ? siameseOutline.withAlphaComponent(outlineAlpha * 0.78)
                : creaseColor(coat).withAlphaComponent(outlineAlpha * 0.9)
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.35)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let startIdx = 2
            let endIdx = Int(CGFloat(highlightEdge.count - 1) * 0.68)
            ctx.move(to: highlightEdge[startIdx])
            for idx in (startIdx + 1)...endIdx {
                ctx.addLine(to: highlightEdge[idx])
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Floating Mechanical Keycap Popups

    private static func drawFloatingKeycaps(in ctx: CGContext, physics: CatPhysics) {
        for badge in physics.floatingKeycaps {
            let progress = badge.age / badge.lifetime
            // Spring pop-in scale (starts crisp and readable immediately!)
            let scale: CGFloat
            if badge.age < 0.09 {
                let t = badge.age / 0.09
                scale = 0.72 + 0.38 * sin(t * .pi * 0.65)
            } else if badge.age < 0.18 {
                let t = (badge.age - 0.09) / 0.09
                scale = 1.10 - 0.10 * t
            } else {
                scale = 1.0
            }

            let alpha: CGFloat = progress < 0.62 ? 1.0 : max(0, 1.0 - (progress - 0.62) / 0.38)

            let charCount = badge.label.count
            let fontSize: CGFloat = charCount <= 1 ? 11.5 : 10.0
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
            ]
            let attrStr = NSAttributedString(string: badge.label, attributes: attrs)
            let strSize = attrStr.size()
            let w: CGFloat = max(23, ceil(strSize.width) + 12)
            let h: CGFloat = 22

            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.translateBy(x: badge.position.x, y: badge.position.y)
            ctx.rotate(by: badge.rotation)
            ctx.scaleBy(x: scale, y: scale)

            // 3D bottom keycap edge / shadow
            let baseRect = CGRect(x: -w * 0.5, y: -h * 0.5 + 2.5, width: w, height: h)
            let basePath = CGPath(roundedRect: baseRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
            ctx.setFillColor(NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.17, alpha: 0.95).cgColor)
            ctx.addPath(basePath)
            ctx.fillPath()

            // Crisp white mechanical keycap top face
            let faceRect = CGRect(x: -w * 0.5, y: -h * 0.5, width: w, height: h)
            let facePath = CGPath(roundedRect: faceRect, cornerWidth: 5.2, cornerHeight: 5.2, transform: nil)
            ctx.setFillColor(NSColor(calibratedRed: 0.975, green: 0.972, blue: 0.952, alpha: 1.0).cgColor)
            ctx.addPath(facePath)
            ctx.fillPath()

            ctx.setStrokeColor(NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.45)
            ctx.addPath(facePath)
            ctx.strokePath()

            // Centered bold key label
            let drawPt = CGPoint(x: -strSize.width * 0.5, y: -strSize.height * 0.5 - 0.5)
            NSGraphicsContext.saveGraphicsState()
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = nsCtx
            attrStr.draw(at: drawPt)
            NSGraphicsContext.restoreGraphicsState()

            ctx.restoreGState()
        }
    }

    // MARK: - Subtle Petting Sparkles & Sleep Z

    private static func drawSparkles(in ctx: CGContext, physics: CatPhysics, eyeTheme: EyeColorTheme) {
        for sp in physics.sparkles {
            let p = sp.age / sp.lifetime
            let alpha = sin(min(1.0, p) * .pi)
            ctx.saveGState()
            ctx.setAlpha(alpha * (sp.noteGlyph == nil ? 0.85 : 1.0))
            if let glyph = sp.noteGlyph, sp.gravity > 0 {
                // 彩带：小号、旋转、高饱和
                ctx.translateBy(x: sp.position.x, y: sp.position.y)
                ctx.rotate(by: sp.spin * sp.age)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7.5, weight: .black),
                    .foregroundColor: NSColor(calibratedHue: sp.noteHue, saturation: 0.75, brightness: 0.98, alpha: 1)
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSAttributedString(string: glyph, attributes: attrs).draw(at: CGPoint(x: -3, y: -5))
                NSGraphicsContext.restoreGraphicsState()
            } else if let glyph = sp.noteGlyph {
                let color = NSColor(calibratedHue: sp.noteHue, saturation: 0.62, brightness: 0.98, alpha: 1)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.35)
                shadow.shadowBlurRadius = 1.5
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 15 + p * 4, weight: .heavy),
                    .foregroundColor: color,
                    .shadow: shadow
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSAttributedString(string: glyph, attributes: attrs).draw(at: sp.position)
                NSGraphicsContext.restoreGraphicsState()
            } else if sp.isSleepZ {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11 + p * 3, weight: .bold),
                    .foregroundColor: eyeTheme.primaryColor
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSAttributedString(string: "z", attributes: attrs).draw(at: sp.position)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                // Tiny glowing chartreuse 4-point star
                let r: CGFloat = 3.5 + p * 1.5
                ctx.translateBy(x: sp.position.x, y: sp.position.y)
                ctx.setFillColor(eyeTheme.primaryColor.cgColor)
                let star = CGMutablePath()
                star.move(to: CGPoint(x: 0, y: -r))
                star.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0.8, y: -0.8))
                star.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: 0.8, y: 0.8))
                star.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -0.8, y: 0.8))
                star.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -0.8, y: -0.8))
                star.closeSubpath()
                ctx.addPath(star)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Music Headphones 🎧

    enum HeadphoneLayer { case back, front }

    private struct HeadphonePalette {
        let shell: NSColor
        let shellShade: NSColor
        let cushion: NSColor
        let accent: NSColor
    }

    /// 按皮肤挑撞色：黑猫配奶白、暹罗配樱花粉、美短配薄荷、橘白配藏青
    private static func headphonePalette(_ coat: CatCoatTheme, eyeTheme: EyeColorTheme) -> HeadphonePalette {
        switch coat {
        case .classicBlack:
            return HeadphonePalette(shell: rgb(0xF4F1EA), shellShade: rgb(0xCFCAC0), cushion: rgb(0x3A3A40), accent: eyeTheme.primaryColor)
        case .siamese:
            return HeadphonePalette(shell: rgb(0xF6B8C4), shellShade: rgb(0xD98A9C), cushion: rgb(0x4A3630), accent: rgb(0xFFF4E8))
        case .shorthair:
            return HeadphonePalette(shell: rgb(0x9ED9C6), shellShade: rgb(0x6FB39E), cushion: rgb(0x3B4743), accent: rgb(0xFFF8E6))
        case .orangeWhite:
            return HeadphonePalette(shell: rgb(0x34466B), shellShade: rgb(0x223050), cushion: rgb(0x1C2234), accent: rgb(0xF6B04A))
        }
    }

    /// 头戴式耳机：头梁是投影到 2.5D 头部椭球上的一段弧，耳罩贴在两颊外侧。
    /// headphonesOn < 1 时从头顶往下"戴上"（弹簧过冲 → 啪嗒一下）。
    private static func drawHeadphones(
        in ctx: CGContext,
        center: CGPoint,
        physics: CatPhysics,
        coat: CatCoatTheme,
        eyeTheme: EyeColorTheme,
        layer: HeadphoneLayer
    ) {
        let on = physics.headphonesOn.value
        let alpha = max(0, min(1, on * 1.6))
        let drop = (1 - on) * -46 // 未戴好时悬在头顶上方

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y + drop)
        ctx.rotate(by: physics.headTilt.value)
        ctx.setAlpha(alpha)

        let yawRad = physics.headYaw.value * 0.50
        let pitchRad = physics.headPitch.value * 0.36
        let pal = headphonePalette(coat, eyeTheme: eyeTheme)

        func proj(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (pt: CGPoint, z: CGFloat) {
            projectHead3D(x: x, y: y, z: z, yawRad: yawRad, pitchRad: pitchRad)
        }

        // 头梁：x/y 平面上的半椭圆，略靠后（z=-4）；顶点 y=-30.5 压在头顶轮廓上，转头时不露缝
        if layer == .front {
            let band = CGMutablePath()
            let steps = 18
            for i in 0...steps {
                let theta = CGFloat.pi * CGFloat(i) / CGFloat(steps)
                let pt = proj(-cos(theta) * 41.5, -9 - sin(theta) * 21.5, -4).pt
                if i == 0 { band.move(to: pt) } else { band.addLine(to: pt) }
            }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(pal.shellShade.cgColor)
            ctx.setLineWidth(6.2)
            ctx.addPath(band)
            ctx.strokePath()
            ctx.setStrokeColor(pal.shell.cgColor)
            ctx.setLineWidth(4.4)
            ctx.addPath(band)
            ctx.strokePath()
            // 头梁高光
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.45).cgColor)
            ctx.setLineWidth(1.1)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: -1.2)
            ctx.addPath(band)
            ctx.strokePath()
            ctx.restoreGState()
        }

        for sign: CGFloat in [-1, 1] {
            let cup = proj(sign * 42.5, -1.5, 0)
            // 耳罩朝外的法线 (sign,0,0) 经 yaw 后的 z 分量 > 0 表示朝向观众
            let normalZ = -sign * sin(yawRad)
            let isFar = cup.z < -6 || normalZ < -0.28
            guard (layer == .back) == isFar else { continue }

            let faceOpen = max(0, normalZ) // 0 = 侧面看，1 = 正对外壳
            let w: CGFloat = 12.5 + faceOpen * 9
            let h: CGFloat = 25
            // 耳罩偏向头外侧，正对时向外再挪一点露出外壳
            let cx = cup.pt.x + sign * (2.5 + faceOpen * 3)
            let cy = cup.pt.y

            // 连接头梁的小滑块
            let slider = proj(sign * 41.5, -11.5, -4).pt
            ctx.setStrokeColor(pal.shellShade.cgColor)
            ctx.setLineWidth(3.2)
            ctx.setLineCap(.round)
            ctx.move(to: slider)
            ctx.addLine(to: CGPoint(x: cx, y: cy - h * 0.42))
            ctx.strokePath()

            // 内侧海绵垫（靠头的一侧）
            let cushionRect = CGRect(x: cx - w * 0.5 - sign * 2.2, y: cy - h * 0.5 + 1, width: w, height: h - 2)
            ctx.setFillColor(pal.cushion.cgColor)
            ctx.fillEllipse(in: cushionRect)

            // 外壳
            let shellRect = CGRect(x: cx - w * 0.5 + sign * 1.2, y: cy - h * 0.5, width: w, height: h)
            let shellPath = CGPath(roundedRect: shellRect, cornerWidth: w * 0.48, cornerHeight: h * 0.42, transform: nil)
            ctx.setFillColor(pal.shell.cgColor)
            ctx.addPath(shellPath)
            ctx.fillPath()
            ctx.setStrokeColor(pal.shellShade.cgColor)
            ctx.setLineWidth(1.1)
            ctx.addPath(shellPath)
            ctx.strokePath()

            // 外壳上的彩色圆标（跟着节拍微微闪烁）
            let pulse = physics.beatPulse * (physics.isListeningToMusicApp ? 1 : 0)
            let dotR: CGFloat = 3.2 + faceOpen * 2.2 + pulse * 0.8
            let dot = CGRect(x: shellRect.midX - dotR, y: shellRect.midY - dotR, width: dotR * 2, height: dotR * 2)
            ctx.setFillColor(pal.accent.withAlphaComponent(0.85 + pulse * 0.15).cgColor)
            ctx.fillEllipse(in: dot)

            // 外壳高光
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.5).cgColor)
            ctx.setLineWidth(1.2)
            ctx.addArc(center: CGPoint(x: shellRect.midX, y: shellRect.midY),
                       radius: min(w, h) * 0.34,
                       startAngle: .pi * 1.1, endAngle: .pi * 1.45, clockwise: false)
            ctx.strokePath()

            // 开麦指示灯：耳罩顶上一颗呼吸的红灯
            let boom = max(0, min(1, physics.boomMic.value))
            if boom > 0.05 && sign < 0 {
                let blink = 0.55 + 0.45 * abs(sin(physics.time * 3))
                ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.27, blue: 0.27, alpha: boom * blink).cgColor)
                ctx.fillEllipse(in: CGRect(x: shellRect.midX - 1.8, y: shellRect.minY + 2, width: 3.6, height: 3.6))
            }
        }

        // 麦克风杆：固定从左耳罩伸出，弹簧从下垂位置转到嘴边
        let boom = max(0, physics.boomMic.value)
        if layer == .front && boom > 0.02 {
            let root = proj(-43, 3, 3).pt
            let restTip = proj(-46, 30, 2).pt
            let liveTip = proj(-10, 14.5, 30).pt
            let tip = CGPoint(x: restTip.x + (liveTip.x - restTip.x) * boom, y: restTip.y + (liveTip.y - restTip.y) * boom)
            let ctrl = CGPoint(x: (root.x + tip.x) * 0.5 - 4, y: max(root.y, tip.y) + 8 * boom)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(pal.shellShade.cgColor)
            ctx.setLineWidth(2.6)
            ctx.move(to: root)
            ctx.addQuadCurve(to: tip, control: ctrl)
            ctx.strokePath()
            ctx.setStrokeColor(pal.shell.cgColor)
            ctx.setLineWidth(1.2)
            ctx.move(to: root)
            ctx.addQuadCurve(to: tip, control: ctrl)
            ctx.strokePath()
            // 防喷海绵
            ctx.setFillColor(pal.cushion.cgColor)
            ctx.fillEllipse(in: CGRect(x: tip.x - 4.2, y: tip.y - 3.4, width: 8.4, height: 6.8))
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.22).cgColor)
            ctx.fillEllipse(in: CGRect(x: tip.x - 2.6, y: tip.y - 2.6, width: 3, height: 2.2))
        }

        ctx.restoreGState()
    }

    private static func drawToastBubble(in ctx: CGContext, text: String, age: CGFloat, headCenter: CGPoint,
                                        accent: NSColor, raised: Bool) {
        // 0.25s 淡入上浮，最后 0.6s 淡出
        let fadeIn = min(1, age / 0.25)
        let fadeOut = max(0, min(1, (Toast.duration - age) / 0.6))
        let alpha = fadeIn * fadeOut
        guard alpha > 0.01 else { return }

        var display = text
        if display.count > 26 { display = String(display.prefix(25)) + "…" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)
        ]
        let str = NSAttributedString(string: display, attributes: attrs)
        let size = str.size()
        let w = size.width + 18
        let h: CGFloat = 20
        // Claude 气泡占右上角时，提示气泡挪到左上角
        let x = raised ? 4 : max(4, min(CatPhysics.canvasSize.width - w - 4, headCenter.x - w * 0.5))
        let y = raised ? 4 : max(4, headCenter.y - 98 + (1 - fadeIn) * 6)
        let rect = CGRect(x: x, y: y, width: w, height: h)

        ctx.saveGState()
        ctx.setAlpha(alpha)
        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.88).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.1)
        ctx.addPath(path)
        ctx.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: rect.minX + 9, y: rect.midY - size.height * 0.5 - 0.5))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: - Spectrum Wall

    /// 猫身后的竖直 LED 均衡器墙：柱子从桌面往上长，每根由一格格方块组成；
    /// 低音在中间（打鼓时会从猫头后面冒出来），往两边频率越来越高，左右镜像。
    /// 没点亮的方块也淡淡地画出来，安静段落也看得出是一面墙。
    private static func drawSpectrumWall(in ctx: CGContext, physics: CatPhysics) {
        let vis = max(0, min(1, physics.spectrumVisibility.value))
        let bands = physics.spectrum
        let peaks = physics.spectrumPeaks
        guard bands.count == peaks.count, !bands.isEmpty else { return }
        let t = physics.time
        let kick = physics.beatKick

        let columns = 32
        let left: CGFloat = 12, right: CGFloat = 348
        let pitch = (right - left) / CGFloat(columns)
        let barWidth = pitch * 0.72
        let baseline: CGFloat = 228
        let segmentHeight: CGFloat = 4.2
        let segmentPitch: CGFloat = 6
        let maxSegments = 28
        let center = CGFloat(columns - 1) / 2

        ctx.saveGState()
        ctx.setAlpha(vis)

        // 墙根的柔光，随鼓点亮一下
        let glowHue = (t * 0.04).truncatingRemainder(dividingBy: 1)
        drawRadialGlow(in: ctx, center: CGPoint(x: (left + right) / 2, y: baseline - 40), radius: 190,
                       color: NSColor(calibratedHue: glowHue, saturation: 0.5, brightness: 1, alpha: 0.10 + kick * 0.12))

        var unlit: [CGRect] = []
        unlit.reserveCapacity(columns * maxSegments)
        for c in 0..<columns {
            let distance = abs(CGFloat(c) - center) / (center + 0.5)          // 0 中间 … 1 两边
            let band = min(bands.count - 1, Int(distance * CGFloat(bands.count)))
            let value = bands[band]
            let peak = peaks[band]
            let x = left + CGFloat(c) * pitch + (pitch - barWidth) / 2
            let lit = Int((value * CGFloat(maxSegments)).rounded())
            let peakSegment = min(maxSegments - 1, Int((peak * CGFloat(maxSegments)).rounded()))
            // 每列一个色相，整面墙缓慢流动
            let hue = ((1 - distance) * 0.78 + t * 0.05).truncatingRemainder(dividingBy: 1)

            var litRects: [CGRect] = []
            for k in 0..<maxSegments {
                let rect = CGRect(x: x, y: baseline - CGFloat(k + 1) * segmentPitch, width: barWidth, height: segmentHeight)
                if k < lit { litRects.append(rect) } else { unlit.append(rect) }
            }
            if !litRects.isEmpty {
                // 越往上越亮：底部稍暗，顶端接近白
                for (k, rect) in litRects.enumerated() {
                    let h = CGFloat(k) / CGFloat(maxSegments)
                    let color = NSColor(calibratedHue: hue, saturation: 0.85 - h * 0.35, brightness: 0.75 + h * 0.25,
                                        alpha: 0.78 + kick * 0.2)
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(rect)
                }
            }
            // 峰值帽
            if peak > 0.04 {
                let capY = baseline - CGFloat(peakSegment + 1) * segmentPitch
                ctx.setFillColor(NSColor(calibratedHue: hue, saturation: 0.25, brightness: 1, alpha: 0.95).cgColor)
                ctx.fill(CGRect(x: x, y: capY, width: barWidth, height: segmentHeight * 0.75))
            }
        }
        // 未点亮的格子一次性画完
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.07).cgColor)
        ctx.fill(unlit)
        ctx.restoreGState()
    }

    // MARK: - Key Habit Accessories

    /// 皇冠和汗滴都画在头部局部坐标里，跟随 2.5D 转头/歪头
    private static func drawHeadAccessories(in ctx: CGContext, center: CGPoint, physics: CatPhysics) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: physics.headTilt.value)
        let yawRad = physics.headYaw.value * 0.50
        let pitchRad = physics.headPitch.value * 0.36

        // 皇冠：戴上时从上方弹下来，略微歪戴
        let pop = physics.crownPop.value
        if pop > 0.02 {
            let base = projectHead3D(x: 0, y: -31, z: 4, yawRad: yawRad, pitchRad: pitchRad).pt
            ctx.saveGState()
            ctx.translateBy(x: base.x + 3, y: base.y - (1 - min(1, pop)) * 22)
            ctx.rotate(by: 0.14)
            let s = max(0, pop) * 1.25
            ctx.scaleBy(x: s, y: s)
            ctx.setAlpha(min(1, pop * 1.5))

            let crown = CGMutablePath()
            crown.move(to: CGPoint(x: -13, y: 0))
            crown.addLine(to: CGPoint(x: -14, y: -13))
            crown.addLine(to: CGPoint(x: -7, y: -6))
            crown.addLine(to: CGPoint(x: 0, y: -16))
            crown.addLine(to: CGPoint(x: 7, y: -6))
            crown.addLine(to: CGPoint(x: 14, y: -13))
            crown.addLine(to: CGPoint(x: 13, y: 0))
            crown.closeSubpath()
            ctx.saveGState()
            ctx.addPath(crown)
            ctx.clip()
            let gold = [rgb(0xFFE27A).cgColor, rgb(0xF2A900).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gold, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: -16), end: CGPoint(x: 0, y: 0), options: [])
            }
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(0xB57800).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.addPath(crown)
            ctx.strokePath()
            // 宝石
            ctx.setFillColor(rgb(0xE5484D).cgColor)
            ctx.fillEllipse(in: CGRect(x: -2.2, y: -5.5, width: 4.4, height: 4.4))
            ctx.setFillColor(rgb(0x4C8DF6).cgColor)
            ctx.fillEllipse(in: CGRect(x: -9.5, y: -4.5, width: 3.2, height: 3.2))
            ctx.fillEllipse(in: CGRect(x: 6.3, y: -4.5, width: 3.2, height: 3.2))
            // 闪光
            let glint = max(0, sin(physics.time * 3.1))
            if glint > 0.6 {
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: (glint - 0.6) * 2.5).cgColor)
                let star = CGMutablePath()
                let c = CGPoint(x: 9, y: -11), r: CGFloat = 3.5
                star.move(to: CGPoint(x: c.x, y: c.y - r))
                star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
                ctx.addPath(star)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        // 汗滴：两侧太阳穴各一滴，往下滑，循环两次
        if physics.sweatTimer > 0 {
            let progress = 1 - physics.sweatTimer / CatPhysics.sweatDuration
            let fade = min(1, physics.sweatTimer / 0.4) * min(1, progress * 6)
            for (i, side) in [CGFloat(1), -1].enumerated() {
                let phase = (progress * 2 + CGFloat(i) * 0.45).truncatingRemainder(dividingBy: 1)
                // 太阳穴、头轮廓边上（漫画式汗滴），远离眼睛免得像眼泪
                let p = projectHead3D(x: side * 37, y: -22 + phase * 9, z: 0, yawRad: yawRad, pitchRad: pitchRad)
                guard p.z > -8 else { continue }
                let size: CGFloat = i == 0 ? 1.55 : 1.05
                ctx.saveGState()
                ctx.translateBy(x: p.pt.x, y: p.pt.y)
                ctx.scaleBy(x: size, y: size)
                ctx.setAlpha(fade * (1 - phase * 0.4))
                let drop = CGMutablePath()
                drop.move(to: CGPoint(x: 0, y: -6))
                drop.addQuadCurve(to: CGPoint(x: 3.6, y: 1.5), control: CGPoint(x: 3.2, y: -2.5))
                drop.addArc(center: CGPoint(x: 0, y: 1.5), radius: 3.6, startAngle: 0, endAngle: .pi, clockwise: false)
                drop.addQuadCurve(to: CGPoint(x: 0, y: -6), control: CGPoint(x: -3.2, y: -2.5))
                ctx.setFillColor(rgb(0x8FD3FF).cgColor)
                ctx.addPath(drop)
                ctx.fillPath()
                ctx.setStrokeColor(rgb(0x3E9BD6).cgColor)
                ctx.setLineWidth(0.8)
                ctx.addPath(drop)
                ctx.strokePath()
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.8).cgColor)
                ctx.fillEllipse(in: CGRect(x: -1.8, y: -0.5, width: 1.6, height: 2.2))
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    /// ⌘S："已保存"印章从上方砸下来，停留后淡出
    private static func drawSaveStamp(in ctx: CGContext, age: CGFloat) {
        let slam = min(1, age / 0.12)
        let scale = 1.8 - 0.8 * slam
        let fadeOut = max(0, min(1, (CatPhysics.saveStampDuration - age) / 0.35))
        let alpha = slam * fadeOut
        guard alpha > 0.01 else { return }
        let red = NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.20, alpha: 1)

        ctx.saveGState()
        ctx.translateBy(x: 92, y: 198)
        ctx.rotate(by: -0.2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAlpha(alpha)
        let rect = CGRect(x: -25, y: -12, width: 50, height: 24)
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.97, blue: 0.93, alpha: 0.88).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(red.cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setLineWidth(0.8)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 2.5, dy: 2.5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.strokePath()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .black),
            .foregroundColor: red
        ]
        let str = NSAttributedString(string: "已保存", attributes: attrs)
        let size = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// 截图：举起的爪子上方比个 ✌
    private static func drawPeaceSign(in ctx: CGContext, physics: CatPhysics) {
        let paw = physics.rightPaw.point
        let t = physics.peaceTimer
        let alpha = min(1, (CatPhysics.peaceDuration - t) / 0.2) * min(1, t / 0.3)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17)]
        ctx.saveGState()
        ctx.setAlpha(max(0, alpha))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: "✌️", attributes: attrs)
            .draw(at: CGPoint(x: paw.x - 4, y: paw.y - 30 + sin(physics.time * 8) * 1.5))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: - Claude Code Status Bubble

    private static let claudeOrange = NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757
    private static let waitingAmber = NSColor(calibratedRed: 0.98, green: 0.69, blue: 0.20, alpha: 1)
    private static let doneGreen = NSColor(calibratedRed: 0.40, green: 0.80, blue: 0.50, alpha: 1)

    /// 头右上方的状态气泡：干活 = 思考云 + 转圈星号；等你 = 抖动的对话框；完成 = 绿色对话框。
    private static func drawClaudeBubble(in ctx: CGContext, physics: CatPhysics, headCenter: CGPoint) {
        let status = physics.claudeBubbleStatus
        guard status != .idle else { return }
        let t = physics.time
        // 和终端里的 spinner 同款字形，来回循环；多行时错开相位
        let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

        let accent: NSColor
        var isThought = false
        switch status {
        case .working: accent = claudeOrange; isThought = true
        case .waiting: accent = waitingAmber
        case .done: accent = doneGreen
        case .idle: return
        }

        // 每个会话一行：「✻ Faceplant · 写代码 · 2m」。没有明细时（预览/旧数据）退回单行聚合文案
        var lines = physics.claudeLines
        if lines.isEmpty {
            switch status {
            case .working(let tool, _):
                lines = [ClaudeSessionLine(project: "", detail: ClaudeActivityTracker.label(forTool: tool), kind: .working, elapsed: nil)]
            case .waiting(let kind):
                lines = [ClaudeSessionLine(project: "", detail: kind == .permission ? "等你批准" : "等你回复", kind: .waiting, elapsed: nil)]
            case .done, .idle:
                lines = [ClaudeSessionLine(project: "", detail: "搞定！", kind: .done, elapsed: nil)]
            }
        }
        // 最多 3 行；超出时前 2 行照常显示（等你的会话已排在最前），第 3 行列出其余项目名
        let maxRows = 3
        var hidden: [ClaudeSessionLine] = []
        if lines.count > maxRows {
            hidden = Array(lines.dropFirst(maxRows - 1))
            lines = Array(lines.prefix(maxRows - 1))
        }

        // 行内容只随 spinner 帧（9fps）、等待闪烁档位和明细变化，按 key 缓存，避免 60fps 下每帧重建富文本
        let frameIndex = Int(t * 9) % frames.count
        let waitStep = Int(abs(sin(t * 4)) * 6)
        let cacheKey = ClaudeBubbleCacheKey(lines: lines, hidden: hidden, frameIndex: frameIndex, waitStep: waitStep)
        let rendered: [NSAttributedString]
        let textW: CGFloat
        if let cached = claudeBubbleCache, cached.key == cacheKey {
            rendered = cached.rows
            textW = cached.width
        } else {
            let rows = buildClaudeRows(lines: lines, hidden: hidden, frameIndex: frameIndex, waitStep: waitStep, frames: frames)
            rendered = rows
            textW = rows.map { $0.size().width }.max() ?? 40
            claudeBubbleCache = (cacheKey, rows, textW)
        }

        let rowH: CGFloat = 14
        let padX: CGFloat = 9
        let padY: CGFloat = 4
        let w = max(66, ceil(textW) + padX * 2)
        let h = CGFloat(rendered.count) * rowH + padY * 2
        drawClaudeBubbleShell(in: ctx, physics: physics, headCenter: headCenter, status: status, accent: accent,
                              isThought: isThought, rendered: rendered, w: w, h: h, rowH: rowH, padX: padX, padY: padY)
    }

    private struct ClaudeBubbleCacheKey: Equatable {
        let lines: [ClaudeSessionLine]
        let hidden: [ClaudeSessionLine]
        let frameIndex: Int
        let waitStep: Int
    }

    private static var claudeBubbleCache: (key: ClaudeBubbleCacheKey, rows: [NSAttributedString], width: CGFloat)?

    private static func buildClaudeRows(lines: [ClaudeSessionLine], hidden: [ClaudeSessionLine],
                                        frameIndex: Int, waitStep: Int, frames: [String]) -> [NSAttributedString] {
        let boldFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        let regularFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let dim = NSColor(calibratedWhite: 0.78, alpha: 1)
        let white = NSColor(calibratedWhite: 0.97, alpha: 1)
        var rendered: [NSAttributedString] = []
        for (i, line) in lines.enumerated() {
            let row = NSMutableAttributedString()
            let glyph: String
            let glyphColor: NSColor
            switch line.kind {
            case .working:
                glyph = frames[(frameIndex + i * 3) % frames.count]
                glyphColor = claudeOrange
            case .waiting:
                // 等待行的叹号闪烁
                glyph = "‼"
                glyphColor = waitingAmber.withAlphaComponent(0.5 + 0.5 * CGFloat(waitStep) / 6)
            case .done:
                glyph = "✓"
                glyphColor = doneGreen
            }
            row.append(NSAttributedString(string: glyph + " ", attributes: [.font: boldFont, .foregroundColor: glyphColor]))
            if !line.project.isEmpty {
                var name = line.project
                if name.count > 14 { name = String(name.prefix(13)) + "…" }
                row.append(NSAttributedString(string: name, attributes: [.font: boldFont, .foregroundColor: white]))
                row.append(NSAttributedString(string: " · ", attributes: [.font: regularFont, .foregroundColor: dim]))
            }
            let detailColor = line.kind == .working ? dim : (line.kind == .waiting ? waitingAmber : doneGreen)
            row.append(NSAttributedString(string: line.detail, attributes: [.font: line.project.isEmpty ? boldFont : regularFont, .foregroundColor: line.project.isEmpty ? white : detailColor]))
            if let elapsed = line.elapsed {
                row.append(NSAttributedString(string: " · " + ClaudeActivityTracker.formatElapsed(elapsed),
                                              attributes: [.font: regularFont, .foregroundColor: dim]))
            }
            rendered.append(row)
        }
        if !hidden.isEmpty {
            var names = hidden.map(\.project).joined(separator: "、")
            if names.count > 22 { names = String(names.prefix(21)) + "…" }
            let row = NSMutableAttributedString(string: "+\(hidden.count) ", attributes: [.font: boldFont, .foregroundColor: claudeOrange])
            row.append(NSAttributedString(string: names, attributes: [.font: regularFont, .foregroundColor: dim]))
            rendered.append(row)
        }
        return rendered
    }

    private static func drawClaudeBubbleShell(in ctx: CGContext, physics: CatPhysics, headCenter: CGPoint,
                                              status: ClaudeStatus, accent: NSColor, isThought: Bool,
                                              rendered: [NSAttributedString], w: CGFloat, h: CGFloat,
                                              rowH: CGFloat, padX: CGFloat, padY: CGFloat) {
        let t = physics.time
        let pop = max(0, physics.claudeBubble.value)
        // 气泡尾巴指向头顶右侧；多行时向上长，靠右但不出画布
        let anchor = CGPoint(x: headCenter.x + 30, y: headCenter.y - 48)
        let rect = CGRect(x: max(4, min(CatPhysics.canvasSize.width - w - 4, anchor.x - 16)),
                          y: max(2, anchor.y - 19 - h), width: w, height: h)

        ctx.saveGState()
        ctx.setAlpha(min(1, pop * 1.4))
        // 以尾巴为锚点做弹出缩放；等你时周期性抖动
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.scaleBy(x: pop, y: pop)
        if case .waiting = status {
            let shake = sin(t * 26) * 0.05 * max(0, sin(t * 2.4))
            ctx.rotate(by: shake)
        }
        ctx.translateBy(x: -anchor.x, y: -anchor.y)

        let fill = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.9)
        ctx.setFillColor(fill.cgColor)
        if isThought {
            // 思考云下方的两个小圆点
            ctx.fillEllipse(in: CGRect(x: anchor.x - 2.5, y: anchor.y - 3, width: 5, height: 5))
            ctx.fillEllipse(in: CGRect(x: anchor.x + 1, y: anchor.y - 13, width: 8, height: 8))
        } else {
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: anchor.x - 4, y: rect.maxY - 1))
            tail.addLine(to: CGPoint(x: anchor.x, y: anchor.y - 4))
            tail.addLine(to: CGPoint(x: anchor.x + 8, y: rect.maxY - 1))
            tail.closeSubpath()
            ctx.addPath(tail)
            ctx.fillPath()
        }

        let path = CGPath(roundedRect: rect, cornerWidth: min(10.5, h / 2), cornerHeight: min(10.5, h / 2), transform: nil)
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        var stroke = accent
        if case .waiting = status {
            // 边框呼吸闪烁，提醒感更强
            stroke = accent.withAlphaComponent(0.55 + 0.45 * abs(sin(t * 4)))
        }
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1.4)
        ctx.addPath(path)
        ctx.strokePath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (i, row) in rendered.enumerated() {
            let size = row.size()
            row.draw(at: CGPoint(x: rect.minX + padX, y: rect.minY + padY + CGFloat(i) * rowH + (rowH - size.height) * 0.5))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: - Non-Intrusive Permission Pill

    private static func drawPermissionPill(in ctx: CGContext, text: String) {
        let r = permissionPillRect
        let path = CGPath(roundedRect: r, cornerWidth: 11, cornerHeight: 11, transform: nil)

        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.90).cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor(calibratedRed: 0.79, green: 0.95, blue: 0.25, alpha: 0.90).cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(path)
        ctx.strokePath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.90, alpha: 1.0)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5 - 0.5))
        NSGraphicsContext.restoreGraphicsState()

        ctx.restoreGState()
    }

    // MARK: - Geometry & Color Helpers

    private static func keycapLegend(_ key: PhysicalKey) -> String {
        switch key {
        case .escape: return "ESC"
        case .tab: return "⇥"
        case .capsLock: return "⇪"
        case .leftShift, .rightShift: return "⇧"
        case .leftControl, .rightControl: return "⌃"
        case .leftOption, .rightOption: return "⌥"
        case .leftCommand, .rightCommand: return "⌘"
        case .backspace: return "⌫"
        case .enter: return "↵"
        case .space: return ""
        default: return key.badgeLabel
        }
    }

    private static func offsetY(_ pt: CGPoint, _ dy: CGFloat) -> CGPoint {
        CGPoint(x: pt.x, y: pt.y + dy)
    }

    private static func quadPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
            y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y
        )
    }

    private static func quadTangent(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: 2 * mt * (p1.x - p0.x) + 2 * t * (p2.x - p1.x),
            y: 2 * mt * (p1.y - p0.y) + 2 * t * (p2.y - p1.y)
        )
    }

    private static func roundedQuadPath(
        tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint, radius: CGFloat
    ) -> CGPath {
        let p = CGMutablePath()
        let midTop = CGPoint(x: (tl.x + tr.x) * 0.5, y: (tl.y + tr.y) * 0.5)
        p.move(to: midTop)
        p.addArc(tangent1End: tr, tangent2End: br, radius: radius)
        p.addArc(tangent1End: br, tangent2End: bl, radius: radius)
        p.addArc(tangent1End: bl, tangent2End: tl, radius: radius)
        p.addArc(tangent1End: tl, tangent2End: tr, radius: radius)
        p.closeSubpath()
        return p
    }

    private static func blendColor(_ a: NSColor, _ b: NSColor, t: CGFloat) -> NSColor {
        let ca = a.usingColorSpace(.deviceRGB) ?? a
        let cb = b.usingColorSpace(.deviceRGB) ?? b
        let clamped = max(0, min(1, t))
        return NSColor(
            calibratedRed: ca.redComponent + (cb.redComponent - ca.redComponent) * clamped,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * clamped,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * clamped,
            alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * clamped
        )
    }

    private static func drawRadialGlow(in ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [color.cgColor, color.withAlphaComponent(0.0).cgColor] as CFArray
        let locs: [CGFloat] = [0.0, 1.0]
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: locs) {
            ctx.saveGState()
            ctx.drawRadialGradient(
                grad,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: []
            )
            ctx.restoreGState()
        }
    }
}
