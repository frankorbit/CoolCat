import AppKit
import CoreGraphics

/// 亲密度解锁的装扮（项圈 / 围巾 / 蝴蝶结 / 墨镜）和小猫送的礼物
extension CatRenderer {
    // MARK: - Neck: Bell Collar & Scarf

    /// 脖子上的项圈或围巾：按实际脖子左右轮廓贴合，自然环绕在脖子外侧
    static func drawNeckAccessory(in ctx: CGContext, center: CGPoint, neck: NeckSilhouette, physics: CatPhysics) {
        let accessory = CatSettings.shared.accessory
        guard accessory == .bell || accessory == .scarf else { return }
        let isScarf = accessory == .scarf
        let neckTilt = physics.headTilt.value * 0.5
        let cN = cos(neckTilt), sN = sin(neckTilt)
        let yawShift = physics.headYaw.value * 4
        let thickness: CGFloat = isScarf ? 11 : 5.2
        let edgeY: CGFloat = neck.isWedge ? (isScarf ? 32.0 : 31.5) : (isScarf ? 25.5 : 23.5)

        func sampleNeckX(_ curve: (CGPoint, CGPoint, CGPoint, CGPoint)) -> CGFloat {
            let (p0, p1, p2, p3) = curve
            var prevX: CGFloat = 0, prevY: CGFloat = 0
            var bestX: CGFloat = 0, bestDiff: CGFloat = .greatestFiniteMagnitude
            let steps = 32
            for i in 0...steps {
                let t = 0.78 * CGFloat(i) / CGFloat(steps)
                let u = 1 - t
                let wx = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
                let wy = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
                let dx = (wx - center.x) / headSize
                let dy = (wy - center.y) / headSize
                let lx = dx * cN + dy * sN
                let ly = -dx * sN + dy * cN
                let diff = abs(ly - edgeY)
                if diff < bestDiff {
                    bestDiff = diff
                    bestX = lx
                }
                if i > 0, (prevY - edgeY) * (ly - edgeY) <= 0 {
                    let denom = ly - prevY
                    let frac = abs(denom) > 0.0001 ? (edgeY - prevY) / denom : 0
                    return prevX + (lx - prevX) * frac
                }
                prevX = lx
                prevY = ly
            }
            return bestX
        }

        let leftX = sampleNeckX(neck.leftCurve)
        let rightX = sampleNeckX(neck.rightCurve)
        let midX = (leftX + rightX) * 0.5
        let halfW = max(14, (rightX - leftX) * 0.5)
        let dip = max(6.0, halfW * (isScarf ? 0.18 : 0.23))
        let spanHalfW = halfW + (isScarf ? 1.5 : 0.9)

        var top: [CGPoint] = [], bottom: [CGPoint] = []
        let samples = 24
        for i in 0...samples {
            let theta = CGFloat.pi * CGFloat(i) / CGFloat(samples)
            let sinT = sin(theta)
            let x = midX + spanHalfW * cos(theta) + yawShift * sinT
            let mid = edgeY + dip * sinT
            let w = thickness * ((isScarf ? 0.68 : 0.48) + (isScarf ? 0.32 : 0.52) * sinT)
            top.append(CGPoint(x: x, y: mid - w / 2))
            bottom.append(CGPoint(x: x, y: mid + w / 2))
        }
        let band = CGMutablePath()
        band.addLines(between: top)
        for pt in bottom.reversed() { band.addLine(to: pt) }
        band.closeSubpath()

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: neckTilt)
        ctx.scaleBy(x: headSize, y: headSize)

        if isScarf {
            drawScarf(in: ctx, band: band, top: top, bottom: bottom, midX: midX, halfW: spanHalfW,
                      baseRingY: edgeY, dip: dip, yawShift: yawShift, physics: physics)
        } else {
            ctx.saveGState()
            ctx.addPath(band)
            ctx.clip()
            let collarColors = [
                rgb(0x8E2232).cgColor,
                rgb(0xC43B4E).cgColor,
                rgb(0xD84E60).cgColor,
                rgb(0xC43B4E).cgColor,
                rgb(0x8E2232).cgColor
            ] as CFArray
            let hiLoc = min(0.75, max(0.25, 0.5 + physics.headYaw.value * 0.14))
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: collarColors,
                                     locations: [0.0, 0.22, hiLoc, 0.78, 1.0]) {
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: midX - spanHalfW, y: edgeY),
                                       end: CGPoint(x: midX + spanHalfW, y: edgeY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()

            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.22).cgColor)
            ctx.setLineWidth(0.8)
            ctx.addLines(between: Array(top[3...(samples - 3)]))
            ctx.strokePath()

            ctx.setStrokeColor(rgb(0x7F1E2D).cgColor)
            ctx.setLineWidth(0.85)
            ctx.addPath(band)
            ctx.strokePath()

            drawBell(in: ctx, hang: CGPoint(x: midX + yawShift, y: edgeY + dip + thickness * 0.5), physics: physics)
        }
        ctx.restoreGState()
    }

    private static func drawBell(in ctx: CGContext, hang: CGPoint, physics: CatPhysics) {
        // 铃铛：挂在正前方，跟着身体晃（跳舞、打字时叮当晃）
        let swing = sin(physics.time * 5.5) * 0.12 * physics.musicVibe
            - physics.bodyShiftX.velocity * 0.004 + physics.headTilt.value * -0.4
        ctx.saveGState()
        ctx.translateBy(x: hang.x, y: hang.y)
        ctx.rotate(by: max(-0.5, min(0.5, swing)))
        let r: CGFloat = 5.2
        let bell = CGRect(x: -r, y: 1.5, width: r * 2, height: r * 2)
        let colors = [rgb(0xFFE89A).cgColor, rgb(0xF2B630).cgColor, rgb(0xB7811A).cgColor] as CFArray
        ctx.saveGState()
        ctx.addEllipse(in: bell)
        ctx.clip()
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: -1.8, y: 3.8), startRadius: 0.5,
                                   endCenter: CGPoint(x: 0, y: 1.5 + r), endRadius: r + 1, options: [])
        }
        ctx.restoreGState()
        // 铃铛上的环和开口
        ctx.setStrokeColor(rgb(0xB7811A).cgColor)
        ctx.setLineWidth(1.1)
        ctx.strokeEllipse(in: CGRect(x: -1.6, y: -1, width: 3.2, height: 3))
        ctx.setStrokeColor(rgb(0x6E4A0C).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -2.6, y: 1.5 + r * 1.25))
        ctx.addLine(to: CGPoint(x: 2.6, y: 1.5 + r * 1.25))
        ctx.strokePath()
        ctx.setFillColor(rgb(0x6E4A0C).cgColor)
        ctx.fillEllipse(in: CGRect(x: -1.1, y: 1.5 + r * 1.25, width: 2.2, height: 2.2))
        ctx.restoreGState()
    }

    private static func drawScarf(in ctx: CGContext, band: CGPath, top: [CGPoint], bottom: [CGPoint],
                                  midX: CGFloat, halfW: CGFloat, baseRingY: CGFloat, dip: CGFloat,
                                  yawShift: CGFloat, physics: CatPhysics) {
        let red = rgb(0xD94848), dark = rgb(0xA83232), cream = rgb(0xF6EBDD)

        // 垂下来的围巾尾巴（先画，压在脖子那圈下面）：跟着身体晃
        let sway = -physics.bodyShiftX.velocity * 0.02 + sin(physics.time * 1.7) * 1.2
        let root = CGPoint(x: midX + halfW * 0.38 + yawShift * 0.5, y: baseRingY + dip + 1.5)
        let endPt = CGPoint(x: root.x + 5 + sway, y: root.y + 33)
        let ctrlY = (root.y + endPt.y) * 0.5
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: root.x - 6, y: root.y))
        tail.addQuadCurve(to: CGPoint(x: endPt.x - 6, y: endPt.y), control: CGPoint(x: root.x - 4 + sway * 0.4, y: ctrlY))
        tail.addLine(to: CGPoint(x: endPt.x + 6, y: endPt.y + 1))
        tail.addQuadCurve(to: CGPoint(x: root.x + 6, y: root.y), control: CGPoint(x: root.x + 8 + sway * 0.4, y: ctrlY))
        tail.closeSubpath()
        ctx.saveGState()
        ctx.addPath(tail)
        ctx.clip()
        ctx.setFillColor(red.cgColor)
        ctx.fill(CGRect(x: root.x - 30, y: root.y - 2, width: 60, height: 40))
        // 两道奶白条纹
        ctx.setFillColor(cream.cgColor)
        for y: CGFloat in [root.y + 11, root.y + 19] {
            ctx.fill(CGRect(x: root.x - 30, y: y, width: 60, height: 3.2))
        }
        ctx.restoreGState()
        // 流苏
        ctx.setStrokeColor(dark.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        for i in 0..<5 {
            let x = endPt.x - 5 + CGFloat(i) * 2.5
            ctx.move(to: CGPoint(x: x, y: endPt.y + 0.5))
            ctx.addLine(to: CGPoint(x: x + sway * 0.15, y: endPt.y + 5))
        }
        ctx.strokePath()

        // 绕脖子的一圈：红色毛线 + 竖向罗纹
        ctx.saveGState()
        ctx.addPath(band)
        ctx.clip()
        ctx.setFillColor(red.cgColor)
        ctx.fill(CGRect(x: midX - halfW - 10, y: 0, width: (halfW + 10) * 2, height: baseRingY + 35))
        ctx.setStrokeColor(dark.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        for i in stride(from: 0, to: min(top.count, bottom.count), by: 2) {
            ctx.move(to: top[i])
            ctx.addLine(to: bottom[i])
        }
        ctx.strokePath()
        // 下沿暗一点，做出厚度
        ctx.setStrokeColor(dark.cgColor)
        ctx.setLineWidth(2.4)
        ctx.addLines(between: bottom)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.addLines(between: top.map { CGPoint(x: $0.x, y: $0.y + 1) })
        ctx.strokePath()
    }

    // MARK: - Bow

    /// 蝴蝶结：别在左耳根前面，跟着头 3D 转
    static func drawBow(in ctx: CGContext, center: CGPoint, physics: CatPhysics) {
        guard CatSettings.shared.accessory == .bow, physics.nightCap.value < 0.4 else { return }
        let yawRad = physics.headYaw.value * 0.50
        let pitchRad = physics.headPitch.value * 0.36
        let anchor = projectHead3D(x: -24, y: -21, z: 17, yawRad: yawRad, pitchRad: pitchRad)
        guard anchor.z > -2 else { return }
        let squeeze = max(0.45, cos(yawRad + 0.6))     // 转向另一侧时变窄

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: physics.headTilt.value)
        ctx.translateBy(x: anchor.pt.x, y: anchor.pt.y)
        ctx.rotate(by: -0.35)
        ctx.scaleBy(x: squeeze, y: 1)

        let pink = rgb(0xF27BA5), deep = rgb(0xC94C7C)
        for sign: CGFloat in [-1, 1] {
            let loop = CGMutablePath()
            loop.move(to: .zero)
            loop.addCurve(to: CGPoint(x: sign * 11, y: -6), control1: CGPoint(x: sign * 4, y: -9), control2: CGPoint(x: sign * 9, y: -10))
            loop.addCurve(to: .zero, control1: CGPoint(x: sign * 13, y: 1), control2: CGPoint(x: sign * 5, y: 5))
            ctx.setFillColor(pink.cgColor)
            ctx.addPath(loop)
            ctx.fillPath()
            ctx.setStrokeColor(deep.cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(loop)
            ctx.strokePath()
            // 蝴蝶结垂下来的两条小飘带
            let ribbon = CGMutablePath()
            ribbon.move(to: CGPoint(x: sign * 1, y: 1))
            ribbon.addLine(to: CGPoint(x: sign * 5, y: 9))
            ribbon.addLine(to: CGPoint(x: sign * 2.5, y: 8))
            ribbon.addLine(to: CGPoint(x: sign * 1.5, y: 10))
            ribbon.addLine(to: CGPoint(x: -sign * 0.5, y: 2))
            ribbon.closeSubpath()
            ctx.setFillColor(deep.cgColor)
            ctx.addPath(ribbon)
            ctx.fillPath()
        }
        // 白色波点 + 中间的结
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.85).cgColor)
        for (x, y) in [(-7.0, -5.0), (7.5, -4.0), (-5.0, -1.0)] {
            ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
        }
        ctx.setFillColor(deep.cgColor)
        ctx.fillEllipse(in: CGRect(x: -3, y: -3, width: 6, height: 6))
        ctx.restoreGState()
    }

    // MARK: - Shades

    /// 墨镜：镜片贴在两只眼睛上；犯困时推到额头上
    static func drawShades(in ctx: CGContext, center: CGPoint, physics: CatPhysics) {
        guard CatSettings.shared.accessory == .shades else { return }
        let yawRad = physics.headYaw.value * 0.50
        let pitchRad = physics.headPitch.value * 0.36
        let lift = -16 * min(1, physics.sleepiness * 1.4)
        func P(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (pt: CGPoint, z: CGFloat) {
            projectHead3D(x: x, y: y + lift, z: z, yawRad: yawRad, pitchRad: pitchRad)
        }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: physics.headTilt.value)

        // 镜腿：从镜框外侧伸到耳朵方向
        ctx.setStrokeColor(rgb(0x15161A).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        for sign: CGFloat in [-1, 1] {
            let a = P(sign * 28, -3, 22), b = P(sign * 38, -6, 4)
            guard a.z > -4 else { continue }
            ctx.move(to: a.pt)
            ctx.addLine(to: b.pt)
        }
        ctx.strokePath()

        var lensCenters: [CGPoint] = []
        for sign: CGFloat in [-1, 1] {
            let c = P(sign * 17.2, -2, 28.5)
            lensCenters.append(c.pt)
            guard c.z > -2 else { continue }
            let facing = max(0.35, cos(yawRad + sign * 0.34))      // 侧过去的镜片变窄
            let w: CGFloat = 25 * facing, h: CGFloat = 19
            let lens = CGPath(roundedRect: CGRect(x: c.pt.x - w / 2, y: c.pt.y - h / 2 + 1, width: w, height: h),
                              cornerWidth: min(w / 2, 8.5), cornerHeight: 8.5, transform: nil)
            ctx.saveGState()
            ctx.addPath(lens)
            ctx.clip()
            let colors = [rgb(0x3A3F4F).cgColor, rgb(0x121318).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: c.pt.x, y: c.pt.y - h / 2), end: CGPoint(x: c.pt.x, y: c.pt.y + h / 2), options: [])
            }
            // 斜向反光
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.22).cgColor)
            let glare = CGMutablePath()
            glare.move(to: CGPoint(x: c.pt.x - w * 0.35, y: c.pt.y + h * 0.1))
            glare.addLine(to: CGPoint(x: c.pt.x - w * 0.05, y: c.pt.y - h * 0.5))
            glare.addLine(to: CGPoint(x: c.pt.x + w * 0.12, y: c.pt.y - h * 0.5))
            glare.addLine(to: CGPoint(x: c.pt.x - w * 0.18, y: c.pt.y + h * 0.1))
            glare.closeSubpath()
            ctx.addPath(glare)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(0x0B0B0E).cgColor)
            ctx.setLineWidth(1.6)
            ctx.addPath(lens)
            ctx.strokePath()
        }
        // 鼻梁
        if lensCenters.count == 2 {
            let mid = P(0, -4, 30).pt
            ctx.setStrokeColor(rgb(0x0B0B0E).cgColor)
            ctx.setLineWidth(1.8)
            ctx.move(to: CGPoint(x: lensCenters[0].x + 9, y: lensCenters[0].y - 4))
            ctx.addQuadCurve(to: CGPoint(x: lensCenters[1].x - 9, y: lensCenters[1].y - 4), control: CGPoint(x: mid.x, y: mid.y - 3))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Gift

    /// 小猫推到桌上的礼物；收下后变小淡出，放太久也会淡出
    static func drawGift(in ctx: CGContext, physics: CatPhysics) {
        guard let gift = physics.gift, let p = physics.giftPoint else { return }
        var alpha: CGFloat = 1
        var scale: CGFloat = 1
        if let a = gift.acceptedAge {
            alpha = max(0, 1 - a / 0.6)
            scale = 1 + a * 0.8
        } else {
            alpha = min(1, max(0, (CatPhysics.giftLifetime - gift.age) / 2))
        }
        // 停下后轻轻弹两下，引人注意
        let settle = gift.age > 0.7 ? abs(sin((gift.age - 0.7) * 5)) * max(0, 1 - (gift.age - 0.7) / 1.6) * 4 : 0

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: p.x, y: p.y - settle)
        // 礼物画大一点，桌面上一眼能看到
        ctx.scaleBy(x: scale * 1.45, y: scale * 1.45)
        // 桌面阴影
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.16).cgColor)
        ctx.fillEllipse(in: CGRect(x: -10, y: 6 + settle, width: 20, height: 4))
        switch gift.kind {
        case .mouseToy: drawToyMouse(in: ctx)
        case .yarn: drawYarn(in: ctx)
        case .flower: drawFlower(in: ctx)
        case .feather: drawFeather(in: ctx)
        case .present: drawPresent(in: ctx)
        case .candyCane: drawCandyCane(in: ctx)
        }
        ctx.restoreGState()

        // 没收下时，旁边一闪一闪的小星
        if gift.acceptedAge == nil, gift.age > 1 {
            let tw = (sin(physics.time * 4) + 1) / 2
            ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.9, blue: 0.5, alpha: 0.4 + 0.6 * tw).cgColor)
            let s = CGPoint(x: p.x + 16, y: p.y - 15)
            let r = 2 + tw * 1.5
            let star = CGMutablePath()
            star.move(to: CGPoint(x: s.x, y: s.y - r * 1.8))
            star.addLine(to: CGPoint(x: s.x + r * 0.5, y: s.y))
            star.addLine(to: CGPoint(x: s.x, y: s.y + r * 1.8))
            star.addLine(to: CGPoint(x: s.x - r * 0.5, y: s.y))
            star.closeSubpath()
            star.move(to: CGPoint(x: s.x - r * 1.8, y: s.y))
            star.addLine(to: CGPoint(x: s.x, y: s.y - r * 0.5))
            star.addLine(to: CGPoint(x: s.x + r * 1.8, y: s.y))
            star.addLine(to: CGPoint(x: s.x, y: s.y + r * 0.5))
            star.closeSubpath()
            ctx.addPath(star)
            ctx.fillPath()
        }
    }

    private static func drawToyMouse(in ctx: CGContext) {
        // 尾巴
        ctx.setStrokeColor(rgb(0xE79AAE).cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 8, y: 3))
        ctx.addCurve(to: CGPoint(x: 15, y: -2), control1: CGPoint(x: 13, y: 6), control2: CGPoint(x: 16, y: 3))
        ctx.strokePath()
        // 身体（朝左的水滴）
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -11, y: 3))
        body.addCurve(to: CGPoint(x: 9, y: 4), control1: CGPoint(x: -6, y: -9), control2: CGPoint(x: 9, y: -8))
        body.addLine(to: CGPoint(x: -11, y: 4.5))
        body.closeSubpath()
        ctx.setFillColor(rgb(0xB9BCC4).cgColor)
        ctx.addPath(body)
        ctx.fillPath()
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: -3, y: -4, width: 7, height: 3))
        // 耳朵、眼睛、鼻子
        ctx.setFillColor(rgb(0xA4A7B0).cgColor)
        ctx.fillEllipse(in: CGRect(x: -7, y: -6, width: 6, height: 6))
        ctx.setFillColor(rgb(0xF2A7BA).cgColor)
        ctx.fillEllipse(in: CGRect(x: -5.8, y: -4.8, width: 3.6, height: 3.6))
        ctx.fillEllipse(in: CGRect(x: -12.5, y: 1.6, width: 2.6, height: 2.2))
        ctx.setFillColor(rgb(0x222226).cgColor)
        ctx.fillEllipse(in: CGRect(x: -8.6, y: -0.6, width: 1.8, height: 1.8))
    }

    private static func drawYarn(in ctx: CGContext) {
        // 松开的一截毛线
        ctx.setStrokeColor(rgb(0x7FB6E8).cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 5, y: 5))
        ctx.addCurve(to: CGPoint(x: 18, y: 6), control1: CGPoint(x: 9, y: 10), control2: CGPoint(x: 14, y: 1))
        ctx.strokePath()
        ctx.setFillColor(rgb(0x7FB6E8).cgColor)
        ctx.fillEllipse(in: CGRect(x: -7.5, y: -8, width: 15, height: 15))
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: -7.5, y: -8, width: 15, height: 15))
        ctx.clip()
        ctx.setStrokeColor(rgb(0x4E86BF).cgColor)
        ctx.setLineWidth(1)
        for i in 0..<4 {
            let o = CGFloat(i) * 4 - 6
            ctx.move(to: CGPoint(x: -9, y: o - 3))
            ctx.addQuadCurve(to: CGPoint(x: 9, y: o + 3), control: CGPoint(x: 0, y: o - 6))
        }
        ctx.move(to: CGPoint(x: -3, y: -9))
        ctx.addQuadCurve(to: CGPoint(x: -2, y: 8), control: CGPoint(x: 4, y: 0))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawFlower(in ctx: CGContext) {
        ctx.setStrokeColor(rgb(0x5FA35A).cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 0, y: -2))
        ctx.addQuadCurve(to: CGPoint(x: 10, y: 5), control: CGPoint(x: 2, y: 5))
        ctx.strokePath()
        ctx.setFillColor(rgb(0x6DB866).cgColor)
        ctx.fillEllipse(in: CGRect(x: 4, y: 0, width: 6, height: 3.5))
        ctx.setFillColor(rgb(0xFFF4F7).cgColor)
        for i in 0..<5 {
            let a = CGFloat(i) / 5 * .pi * 2 - .pi / 2
            ctx.fillEllipse(in: CGRect(x: cos(a) * 4.6 - 3.4, y: -4 + sin(a) * 4.6 - 3.4, width: 6.8, height: 6.8))
        }
        ctx.setFillColor(rgb(0xF6C343).cgColor)
        ctx.fillEllipse(in: CGRect(x: -2.6, y: -6.6, width: 5.2, height: 5.2))
    }

    private static func drawFeather(in ctx: CGContext) {
        let shaft = CGMutablePath()
        shaft.move(to: CGPoint(x: -13, y: 4))
        shaft.addQuadCurve(to: CGPoint(x: 13, y: -6), control: CGPoint(x: 0, y: 3))
        // 羽片：沿着羽轴两侧铺开
        let vane = CGMutablePath()
        vane.move(to: CGPoint(x: -8, y: 3))
        vane.addQuadCurve(to: CGPoint(x: 13, y: -6), control: CGPoint(x: 2, y: -9))
        vane.addQuadCurve(to: CGPoint(x: -8, y: 3), control: CGPoint(x: 5, y: 7))
        ctx.setFillColor(rgb(0x4FC1B5).cgColor)
        ctx.addPath(vane)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(vane)
        ctx.clip()
        ctx.setStrokeColor(rgb(0x2E8F86).cgColor)
        ctx.setLineWidth(0.8)
        for i in 0..<7 {
            let x = -6 + CGFloat(i) * 3
            ctx.move(to: CGPoint(x: x, y: 2 - CGFloat(i) * 1.1))
            ctx.addLine(to: CGPoint(x: x + 3, y: -6 - CGFloat(i) * 0.6))
            ctx.move(to: CGPoint(x: x, y: 2 - CGFloat(i) * 1.1))
            ctx.addLine(to: CGPoint(x: x + 3, y: 6 - CGFloat(i) * 1.2))
        }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xF0B44C).cgColor)
        ctx.fillEllipse(in: CGRect(x: 9, y: -9, width: 6, height: 6))
        ctx.setStrokeColor(rgb(0xF5F0E6).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.addPath(shaft)
        ctx.strokePath()
    }
}
