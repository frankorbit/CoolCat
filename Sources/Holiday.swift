import AppKit
import CoreGraphics

// MARK: - Calendar

/// 节日季：12 月戴圣诞帽、送圣诞礼物，冬天下小雪，平安夜和圣诞节当天打个招呼。纯逻辑，便于单测。
struct HolidaySeason: Equatable {
    /// 12/1–12/26：戴圣诞帽、礼物换成圣诞礼物
    var christmas: Bool
    /// 12 月到 2 月：下小雪
    var snow: Bool
    /// 12/24、12/25：平安夜 / 圣诞节当天的彩蛋
    var christmasDay: Bool

    static let none = HolidaySeason(christmas: false, snow: false, christmasDay: false)
    /// 设置里「预览 30 秒」用：帽子、雪、礼物都有
    static let preview = HolidaySeason(christmas: true, snow: true, christmasDay: false)

    static func on(_ date: Date, calendar: Calendar = .current) -> HolidaySeason {
        let parts = calendar.dateComponents([.month, .day], from: date)
        let month = parts.month ?? 0, day = parts.day ?? 0
        return HolidaySeason(christmas: month == 12 && day <= 26,
                             snow: month == 12 || (1...2).contains(month),
                             christmasDay: month == 12 && (day == 24 || day == 25))
    }

    /// 合并两份（预览叠在真实日期上）
    func union(_ other: HolidaySeason) -> HolidaySeason {
        HolidaySeason(christmas: christmas || other.christmas, snow: snow || other.snow,
                      christmasDay: christmasDay || other.christmasDay)
    }
}

// MARK: - Snow

/// 小猫身后飘的小雪：稀疏、慢、左右轻轻晃，落到桌面以下就从顶上重新飘
struct Snowfall {
    struct Flake {
        var x: CGFloat
        var y: CGFloat
        var size: CGFloat
        var speed: CGFloat
        var phase: CGFloat
    }

    static let count = 22
    private(set) var flakes: [Flake] = []
    /// 0..1 雪下得多大（进出时淡入淡出）
    private(set) var amount: CGFloat = 0
    private var rng = SystemRandomNumberGenerator()

    /// - Parameters:
    ///   - on: 现在该不该下雪
    ///   - bounds: 雪花活动的范围（画布坐标）
    mutating func step(dt: CGFloat, on: Bool, bounds: CGRect) {
        amount += ((on ? 1 : 0) - amount) * min(1, dt * (on ? 0.6 : 1.5))
        guard amount > 0.01 else {
            flakes.removeAll()
            return
        }
        while flakes.count < Self.count {
            // 一开始撒满整个范围，之后都从顶上飘下来
            let y = flakes.isEmpty || amount < 0.5
                ? CGFloat.random(in: bounds.minY...bounds.maxY, using: &rng)
                : bounds.minY - 6
            flakes.append(newFlake(y: y, bounds: bounds))
        }
        for i in flakes.indices {
            flakes[i].y += flakes[i].speed * dt
            flakes[i].phase += dt
            if flakes[i].y > bounds.maxY + 6 {
                flakes[i] = newFlake(y: bounds.minY - 6, bounds: bounds)
            }
        }
    }

    private mutating func newFlake(y: CGFloat, bounds: CGRect) -> Flake {
        Flake(x: CGFloat.random(in: bounds.minX...bounds.maxX, using: &rng), y: y,
              size: CGFloat.random(in: 1.6...3.4, using: &rng), speed: CGFloat.random(in: 12...24, using: &rng),
              phase: CGFloat.random(in: 0...(2 * .pi), using: &rng))
    }
}

extension CatRenderer {
    /// 画小雪：白色小圆点，左右轻轻晃；淡蓝描边让它在浅色桌面上也看得见
    static func drawSnow(in ctx: CGContext, snow: Snowfall) {
        guard snow.amount > 0.01 else { return }
        ctx.saveGState()
        for flake in snow.flakes {
            let x = flake.x + sin(flake.phase * 1.3) * 6
            let r = flake.size
            let alpha = 0.85 * snow.amount
            ctx.setFillColor(rgb(0xB8C7DC, alpha * 0.55).cgColor)
            let halo = r + 0.6
            ctx.fillEllipse(in: CGRect(x: x - halo, y: flake.y - halo, width: halo * 2, height: halo * 2))
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - r, y: flake.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()
    }

    // MARK: - Christmas Gifts

    /// 圣诞礼盒：红盒子 + 金色丝带十字 + 蝴蝶结
    static func drawPresent(in ctx: CGContext) {
        let box = CGRect(x: -8, y: -6, width: 16, height: 12)
        ctx.setFillColor(rgb(0xD8343C).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
        ctx.fillPath()
        // 盒盖
        ctx.setFillColor(rgb(0xE9474F).cgColor)
        let lid = CGRect(x: -9, y: -8.5, width: 18, height: 4)
        ctx.addPath(CGPath(roundedRect: lid, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        ctx.fillPath()
        // 丝带
        ctx.setFillColor(rgb(0xF2C14E).cgColor)
        ctx.fill(CGRect(x: -1.4, y: -8.5, width: 2.8, height: 14.5))
        ctx.fill(CGRect(x: -8, y: -1, width: 16, height: 2.4))
        // 蝴蝶结
        for sign: CGFloat in [-1, 1] {
            ctx.fillEllipse(in: CGRect(x: sign > 0 ? 0.5 : -6.5, y: -12.5, width: 6, height: 4.6))
        }
        ctx.setFillColor(rgb(0xC99A2E).cgColor)
        ctx.fillEllipse(in: CGRect(x: -1.6, y: -11.4, width: 3.2, height: 3.2))
    }

    /// 拐杖糖：红白条纹的弯钩
    static func drawCandyCane(in ctx: CGContext) {
        let cane = CGMutablePath()
        cane.move(to: CGPoint(x: -3, y: 7))
        cane.addLine(to: CGPoint(x: -3, y: -4))
        cane.addArc(center: CGPoint(x: 1.5, y: -4), radius: 4.5, startAngle: .pi, endAngle: 0, clockwise: false)
        cane.addLine(to: CGPoint(x: 6, y: -1.5))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(3.6)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 1).cgColor)
        ctx.addPath(cane)
        ctx.strokePath()
        // 红条纹：沿着糖身画一段段斜线，裁在糖身里
        let shape = cane.copy(strokingWithWidth: 3.6, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(shape)
        ctx.clip()
        ctx.setStrokeColor(rgb(0xD8343C).cgColor)
        ctx.setLineWidth(1.4)
        var y: CGFloat = 9
        while y > -12 {
            ctx.move(to: CGPoint(x: -8, y: y))
            ctx.addLine(to: CGPoint(x: 8, y: y - 6))
            y -= 3.2
        }
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0xB9B2A8, 0.7).cgColor)
        ctx.setLineWidth(0.6)
        ctx.addPath(shape)
        ctx.strokePath()
    }

    // MARK: - Walker Santa Hat

    /// 侧身小猫的圣诞帽（头的局部坐标，r = 头半径，朝右）：半圆帽身扣在头顶，帽尖由粗到细往后垂，白毛绒帽檐 + 绒球
    static func drawSideSantaHat(in ctx: CGContext, r: CGFloat, time: CGFloat) {
        let sway = sin(time * 2.2) * 0.05
        ctx.saveGState()
        ctx.rotate(by: -0.16 + sway)
        let brimY = -r * 0.62
        // 帽身：扣在头顶的半个椭圆
        let dome = CGMutablePath()
        dome.move(to: CGPoint(x: -r * 0.82, y: brimY))
        dome.addCurve(to: CGPoint(x: r * 0.74, y: brimY),
                      control1: CGPoint(x: -r * 0.82, y: -r * 1.62), control2: CGPoint(x: r * 0.66, y: -r * 1.5))
        dome.closeSubpath()
        // 帽尖：从帽顶往后垂下来，由粗到细
        let tip = CGPoint(x: -r * 1.08 + sin(time * 1.7) * r * 0.04, y: -r * 0.98)
        let droop = taperedLimb(from: CGPoint(x: -r * 0.05, y: -r * 1.2), control: CGPoint(x: -r * 0.55, y: -r * 1.62),
                                to: tip, startWidth: r * 0.62, endWidth: r * 0.16)
        // 帽身和帽尖分开填：两条路径绕向相反，合成一个裁剪区域时重叠处会被抵消成空洞
        let colors = [rgb(0xEC4A52).cgColor, rgb(0xB71C25).cgColor] as CFArray
        for part in [droop, dome as CGPath] {
            ctx.saveGState()
            ctx.addPath(part)
            ctx.clip()
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let from = CGPoint(x: -r * 0.6, y: -r * 1.5), to = CGPoint(x: r * 0.6, y: brimY)
                ctx.drawLinearGradient(grad, start: from, end: to, options: [])
            }
            ctx.restoreGState()
        }
        // 帽尖压在帽身上的那道褶
        ctx.setStrokeColor(rgb(0x8E141B, 0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -r * 0.12, y: -r * 1.02))
        ctx.addQuadCurve(to: CGPoint(x: -r * 0.62, y: -r * 1.2), control: CGPoint(x: -r * 0.4, y: -r * 1.02))
        ctx.strokePath()
        // 毛绒帽檐：一串重叠的小圆
        ctx.setFillColor(rgb(0xF5F3EE).cgColor)
        let steps = 9
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = -r * 0.88 + t * r * 1.68
            ctx.fillEllipse(in: CGRect(x: x - r * 0.16, y: brimY - r * 0.17, width: r * 0.32, height: r * 0.32))
        }
        // 绒球
        ctx.fillEllipse(in: CGRect(x: tip.x - r * 0.21, y: tip.y - r * 0.21, width: r * 0.42, height: r * 0.42))
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: tip.x - r * 0.12, y: tip.y - r * 0.14, width: r * 0.14, height: r * 0.11))
        ctx.restoreGState()
    }
}
