import AppKit
import CoreGraphics

/// 生活陪伴的道具：睡帽、手里的咖啡/奶瓶/水杯、电量小图标。单独放一个文件，避免 CatRenderer 继续膨胀。
extension CatRenderer {
    // MARK: - Night Cap

    /// 睡帽：按头部椭球做成 3D，贴着脑袋戴。
    /// - 帽檐是头上一圈 3D 点（y = -17，略高于眼睛），只画朝前的半圈，转头时跟着弧度绕过去
    /// - 帽身从帽檐两端收成圆顶，再拉到垂向一侧的帽尖；帽尖带软弹簧惯性，歪头/跳舞时慢半拍地甩
    /// - 耳朵从帽子的两个洞里钻出来：先画帽身，再只在帽身范围内重画耳朵，耳根加一圈洞口阴影
    static func drawNightCap(in ctx: CGContext, center: CGPoint, physics: CatPhysics) {
        let on = physics.nightCap.value
        guard on > 0.02 else { return }
        let tilt = physics.headTilt.value
        let yawRad = physics.headYaw.value * 0.50
        let pitchRad = physics.headPitch.value * 0.36
        let drop = -(1 - min(1, on)) * 26            // 戴上时从上方落下
        func P(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (pt: CGPoint, z: CGFloat) {
            projectHead3D(x: x, y: y, z: z, yawRad: yawRad, pitchRad: pitchRad)
        }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y + drop)
        ctx.rotate(by: tilt)
        ctx.setAlpha(min(1, on * 1.4))

        // 帽檐的一圈：x 半径 35、z 半径 27（贴着这个高度的头骨截面）
        let ringY: CGFloat = -18.5, rx: CGFloat = 35, rz: CGFloat = 27
        let samples = 28
        var frontTop: [CGPoint] = [], frontBottom: [CGPoint] = []
        for i in 0...samples {
            let theta = CGFloat.pi * CGFloat(i) / CGFloat(samples)   // 0 = 右侧，π = 左侧，经过正前方
            let x = rx * cos(theta), z = rz * sin(theta)
            let top = P(x, ringY - 5, z), bottom = P(x, ringY + 4, z)
            guard top.z > -4 else { continue }                       // 转到脑后的部分被挡住
            frontTop.append(top.pt)
            frontBottom.append(bottom.pt)
        }
        guard let rightEdge = frontTop.first, let leftEdge = frontTop.last else { ctx.restoreGState(); return }

        // 帽尖：垂向右侧、略往后；加上惯性甩动和一点呼吸感
        let lagX = (physics.capSway.value - tilt) * -70
        let lagY = (physics.capBob.value - physics.headOffsetY.value) * -1.2
        let breathe = sin(physics.time * 1.6) * 1.5
        let tip = P(44 + lagX + breathe, -40 + lagY, -8).pt
        let domeLeft = P(-30, -50, 6).pt
        let domeTop = P(6, -66, 2).pt
        let shoulder = P(40, -58, -4).pt

        let body = CGMutablePath()
        body.move(to: leftEdge)
        body.addCurve(to: domeTop, control1: domeLeft, control2: CGPoint(x: domeTop.x - 22, y: domeTop.y))
        body.addCurve(to: tip, control1: CGPoint(x: domeTop.x + 18, y: domeTop.y), control2: shoulder)
        body.addQuadCurve(to: rightEdge, control: CGPoint(x: (tip.x + rightEdge.x) / 2 + 6, y: (tip.y + rightEdge.y) / 2))
        for pt in frontTop.dropFirst() { body.addLine(to: pt) }
        body.closeSubpath()

        // 帽身：左上受光的渐变
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let colors = [rgb(0x5162A8).cgColor, rgb(0x2F3B73).cgColor, rgb(0x232C57).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: leftEdge.x, y: domeTop.y), end: CGPoint(x: tip.x, y: rightEdge.y), options: [])
        }
        // 布料褶皱
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.22).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: domeTop.x - 4, y: domeTop.y + 10))
        ctx.addQuadCurve(to: CGPoint(x: tip.x - 6, y: tip.y + 2), control: CGPoint(x: shoulder.x - 8, y: shoulder.y + 10))
        ctx.strokePath()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor)
        ctx.move(to: CGPoint(x: leftEdge.x + 8, y: leftEdge.y - 6))
        ctx.addQuadCurve(to: CGPoint(x: domeTop.x - 6, y: domeTop.y + 6), control: CGPoint(x: domeLeft.x + 6, y: domeLeft.y + 4))
        ctx.strokePath()
        // 小星星（贴在帽面上）
        ctx.setFillColor(rgb(0xFFE07A).cgColor)
        for (x, y, z) in [(-16.0, -38.0, 14.0), (2.0, -52.0, 10.0), (20.0, -40.0, 12.0), (32.0, -50.0, 0.0)] {
            let star = P(CGFloat(x), CGFloat(y), CGFloat(z))
            guard star.z > -2 else { continue }
            ctx.fillEllipse(in: CGRect(x: star.pt.x - 1.4, y: star.pt.y - 1.4, width: 2.8, height: 2.8))
        }
        // 耳洞阴影 + 从洞里钻出来的耳朵（只在帽身范围内重画）
        ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        for sign: CGFloat in [-1, 1] {
            let hole = P(sign * 22, -22, 4)
            guard hole.z > -6 else { continue }
            ctx.fillEllipse(in: CGRect(x: hole.pt.x - 11, y: hole.pt.y - 4.5, width: 22, height: 9))
        }
        ctx.rotate(by: -tilt)
        ctx.translateBy(x: -center.x, y: -(center.y + drop))
        drawEarsLayer(in: ctx, center: center, physics: physics, coat: CatSettings.shared.coatTheme)
        ctx.restoreGState()

        // 帽檐压在头上的一道淡影
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.16).cgColor)
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addLines(between: frontBottom.map { CGPoint(x: $0.x, y: $0.y + 2.2) })
        ctx.strokePath()
        // 毛绒帽檐：宽带子 + 上下沿密集重叠的小毛球（连成一圈蓬松的边，不是一颗颗珠子）
        let brim = CGMutablePath()
        brim.addLines(between: frontTop)
        for pt in frontBottom.reversed() { brim.addLine(to: pt) }
        brim.closeSubpath()
        ctx.setFillColor(rgb(0xF5F3EE).cgColor)
        ctx.addPath(brim)
        ctx.fillPath()
        for pt in frontTop { ctx.fillEllipse(in: CGRect(x: pt.x - 3.2, y: pt.y - 3.2, width: 6.4, height: 6.4)) }
        for pt in frontBottom { ctx.fillEllipse(in: CGRect(x: pt.x - 3, y: pt.y - 2.8, width: 6, height: 5.6)) }
        // 帽檐上沿一点高光，下沿一点暗部，做出毛绒的体积感
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.2)
        ctx.addLines(between: frontTop.map { CGPoint(x: $0.x, y: $0.y - 1) })
        ctx.strokePath()
        ctx.setStrokeColor(rgb(0xD8D2C6, 0.8).cgColor)
        ctx.setLineWidth(1.4)
        ctx.addLines(between: frontBottom.map { CGPoint(x: $0.x, y: $0.y + 1.2) })
        ctx.strokePath()

        // 帽尖绒球
        ctx.setFillColor(rgb(0xF5F3EE).cgColor)
        ctx.fillEllipse(in: CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12))
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: tip.x - 3.5, y: tip.y - 4, width: 4, height: 3.2))
        ctx.restoreGState()
    }

    // MARK: - Held Prop

    /// 爪子捧着的道具：画在右爪位置上方；抿一口时杯口朝嘴边倾斜
    static func drawHeldProp(in ctx: CGContext, physics: CatPhysics) {
        guard physics.isHoldingProp, let prop = physics.heldProp else { return }
        let paw = physics.rightPaw.point
        let tilt: CGFloat = physics.isSipping ? -0.55 : -0.08
        ctx.saveGState()
        ctx.translateBy(x: paw.x - 1, y: paw.y - 9)
        ctx.rotate(by: tilt)
        switch prop {
        case .coffee:
            // 奶白马克杯 + 深咖啡液面 + 把手 + 两缕热气
            let body = CGPath(roundedRect: CGRect(x: -7, y: -8, width: 14, height: 15), cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(rgb(0xE9DCC8).cgColor)
            ctx.addEllipse(in: CGRect(x: 5, y: -4, width: 7, height: 7))
            ctx.strokePath()
            ctx.setFillColor(rgb(0xF6EFE3).cgColor)
            ctx.addPath(body)
            ctx.fillPath()
            ctx.setStrokeColor(rgb(0xC9B79C).cgColor)
            ctx.setLineWidth(0.8)
            ctx.addPath(body)
            ctx.strokePath()
            ctx.setFillColor(rgb(0x6B4226).cgColor)
            ctx.fillEllipse(in: CGRect(x: -6, y: -9, width: 12, height: 3.5))
            // 小爱心杯标
            ctx.setFillColor(rgb(0xE8828F).cgColor)
            ctx.fillEllipse(in: CGRect(x: -2.4, y: -1.5, width: 2.6, height: 2.6))
            ctx.fillEllipse(in: CGRect(x: -0.2, y: -1.5, width: 2.6, height: 2.6))
            if !physics.isSipping {
                ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.65).cgColor)
                ctx.setLineWidth(1.1)
                ctx.setLineCap(.round)
                for (i, x) in [CGFloat(-2.5), 2.5].enumerated() {
                    let wobble = sin(physics.time * 3 + CGFloat(i) * 1.7) * 1.5
                    ctx.move(to: CGPoint(x: x, y: -11))
                    ctx.addCurve(to: CGPoint(x: x + wobble, y: -21),
                                 control1: CGPoint(x: x + 2.5, y: -14), control2: CGPoint(x: x - 2.5, y: -18))
                    ctx.strokePath()
                }
            }
        case .milk:
            // 奶瓶：白瓶身 + 刻度 + 橙色瓶盖 + 奶嘴
            let body = CGPath(roundedRect: CGRect(x: -5, y: -7, width: 10, height: 16), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.96).cgColor)
            ctx.addPath(body)
            ctx.fillPath()
            ctx.setStrokeColor(rgb(0x9CC9E8).cgColor)
            ctx.setLineWidth(0.8)
            for y in [CGFloat(-1), 2, 5] {
                ctx.move(to: CGPoint(x: -4, y: y)); ctx.addLine(to: CGPoint(x: -1.5, y: y))
            }
            ctx.strokePath()
            ctx.setFillColor(rgb(0xF4A247).cgColor)
            ctx.fill(CGRect(x: -5.5, y: -10, width: 11, height: 3.5))
            ctx.setFillColor(rgb(0xF2C9A0).cgColor)
            ctx.fillEllipse(in: CGRect(x: -2.5, y: -15, width: 5, height: 6))
        case .water:
            // 透明水杯：杯身、水面、高光
            let glass = CGMutablePath()
            glass.move(to: CGPoint(x: -6.5, y: -9)); glass.addLine(to: CGPoint(x: 6.5, y: -9))
            glass.addLine(to: CGPoint(x: 5, y: 8)); glass.addLine(to: CGPoint(x: -5, y: 8)); glass.closeSubpath()
            ctx.setFillColor(rgb(0xDDF1FF, 0.55).cgColor)
            ctx.addPath(glass)
            ctx.fillPath()
            let water = CGMutablePath()
            water.move(to: CGPoint(x: -6, y: -3)); water.addLine(to: CGPoint(x: 6, y: -3))
            water.addLine(to: CGPoint(x: 5, y: 8)); water.addLine(to: CGPoint(x: -5, y: 8)); water.closeSubpath()
            ctx.setFillColor(rgb(0x6EC3F2, 0.75).cgColor)
            ctx.addPath(water)
            ctx.fillPath()
            ctx.setStrokeColor(rgb(0x7FB5D6).cgColor)
            ctx.setLineWidth(0.9)
            ctx.addPath(glass)
            ctx.strokePath()
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: -3.5, y: -6)); ctx.addLine(to: CGPoint(x: -2.8, y: 5))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Fish Treat & Swat

    /// 小鱼干：金黄鱼身 + 条纹 + 尾鳍 + 鱼眼；被咬掉的一端是一排圆弧缺口
    static func drawFishTreat(in ctx: CGContext, physics: CatPhysics) {
        guard let center = physics.fishPoint else { return }
        let eaten = CGFloat(physics.fishBites) / 3        // 0..1 从鱼头一侧往后啃
        guard eaten < 0.99 else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -0.12)
        let length: CGFloat = 30, height: CGFloat = 12
        // 只保留没被吃掉的部分：左边界是三个向右鼓的咬痕
        if eaten > 0 {
            let cut = -length / 2 + length * eaten * 0.8
            let clip = CGMutablePath()
            clip.move(to: CGPoint(x: cut, y: -height))
            let r = height * 2 / 6
            for i in 0..<3 {
                let cy = -height + r + CGFloat(i) * 2 * r
                clip.addArc(center: CGPoint(x: cut, y: cy), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            }
            clip.addLine(to: CGPoint(x: length, y: height))
            clip.addLine(to: CGPoint(x: length, y: -height))
            clip.closeSubpath()
            ctx.addPath(clip)
            ctx.clip()
        }
        // 尾鳍
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: length / 2 - 3, y: 0))
        tail.addLine(to: CGPoint(x: length / 2 + 7, y: -7))
        tail.addQuadCurve(to: CGPoint(x: length / 2 + 7, y: 7), control: CGPoint(x: length / 2 + 3, y: 0))
        tail.closeSubpath()
        ctx.setFillColor(rgb(0xE08A2E).cgColor)
        ctx.addPath(tail)
        ctx.fillPath()
        // 鱼身
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -length / 2, y: 0))
        body.addQuadCurve(to: CGPoint(x: length / 2 - 2, y: 0), control: CGPoint(x: 0, y: -height))
        body.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: 0, y: height))
        body.closeSubpath()
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let colors = [rgb(0xFFD27A).cgColor, rgb(0xF2A93B).cgColor, rgb(0xC97A22).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: -height / 2), end: CGPoint(x: 0, y: height / 2), options: [])
        }
        ctx.setStrokeColor(rgb(0xB8681C, 0.55).cgColor)
        ctx.setLineWidth(1)
        for x in [CGFloat(-3), 2, 7] {
            ctx.move(to: CGPoint(x: x, y: -5)); ctx.addQuadCurve(to: CGPoint(x: x, y: 5), control: CGPoint(x: x + 2.5, y: 0))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // 鱼眼
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: -length / 2 + 4, y: -2.6, width: 4, height: 4))
        ctx.setFillColor(rgb(0x2A1C10).cgColor)
        ctx.fillEllipse(in: CGRect(x: -length / 2 + 5, y: -1.8, width: 2.2, height: 2.2))
        ctx.restoreGState()
    }

    /// 出爪：爪尖后面两道速度线（黑猫的黑爪子拍出去也看得清）
    static func drawSwatStreak(in ctx: CGContext, physics: CatPhysics) {
        guard let streak = physics.swatStreak, streak.extension > 0.35 else { return }
        let paw = streak.paw
        let shoulderX = CatPhysics.seatAnchor.x + physics.bodyShiftX.value + (paw.x < CatPhysics.seatAnchor.x ? -20 : 20)
        let dir = CGPoint(x: paw.x - shoulderX, y: paw.y - 182)
        let len = max(1, hypot(dir.x, dir.y))
        let back = CGPoint(x: -dir.x / len, y: -dir.y / len)
        let normal = CGPoint(x: -back.y, y: back.x)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.75 * streak.extension).cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        for offset in [CGFloat(-6), 0, 6] {
            let start = CGPoint(x: paw.x + back.x * 9 + normal.x * offset, y: paw.y + back.y * 9 + normal.y * offset)
            let end = CGPoint(x: start.x + back.x * 14, y: start.y + back.y * 14)
            ctx.move(to: start); ctx.addLine(to: end)
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Battery Badge

    /// 身体左下方的电量小图标：低电量红色、充电绿色带闪电
    static func drawBatteryBadge(in ctx: CGContext, physics: CatPhysics) {
        guard let battery = physics.batteryBadge else { return }
        // 放在身体左下外侧，宽身材的皮肤也压不到肩膀
        let origin = CGPoint(x: 84, y: 208)
        let low = !battery.onAC && battery.percent <= 20
        let color = battery.onAC ? rgb(0x4CC46A) : (low ? rgb(0xE5484D) : rgb(0xF2B63D))
        ctx.saveGState()
        // 低电量时一闪一闪
        if low { ctx.setAlpha(0.65 + 0.35 * abs(sin(physics.time * 2.5))) }
        let pill = CGPath(roundedRect: CGRect(x: origin.x - 4, y: origin.y - 3, width: 48, height: 16),
                          cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.85).cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        let shell = CGRect(x: origin.x, y: origin.y + 1, width: 16, height: 8)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.95, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(shell)
        ctx.setFillColor(NSColor(calibratedWhite: 0.95, alpha: 1).cgColor)
        ctx.fill(CGRect(x: shell.maxX, y: shell.midY - 1.5, width: 1.6, height: 3))
        let level = max(0.08, CGFloat(battery.percent) / 100)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: shell.minX + 1.2, y: shell.minY + 1.2, width: (shell.width - 2.4) * level, height: shell.height - 2.4))
        let text = (battery.onAC ? "⚡" : "") + "\(battery.percent)%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: text, attributes: attrs).draw(at: CGPoint(x: shell.maxX + 4, y: origin.y - 0.5))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
