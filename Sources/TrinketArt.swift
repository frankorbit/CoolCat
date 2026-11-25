import AppKit
import CoreGraphics

// MARK: - Trinket Art

extension CatRenderer {
    /// 画一个小东西：以它的中心为原点，画布 y 向下，单位和侧身小猫画布一样
    static func drawTrinket(_ kind: Trinket, in ctx: CGContext) {
        let size = kind.baseSize
        let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        let outline = rgb(0x4A4650, 0.55).cgColor
        ctx.saveGState()
        ctx.scaleBy(x: Trinket.artScale, y: Trinket.artScale)
        ctx.setLineWidth(0.8)
        ctx.setStrokeColor(outline)
        switch kind {
        case .pen: drawPen(in: ctx, rect: rect, outline: outline)
        case .eraser: drawEraser(in: ctx, rect: rect, outline: outline)
        case .bottleCap: drawBottleCap(in: ctx, rect: rect, outline: outline)
        case .paperBall: drawPaperBall(in: ctx, rect: rect, outline: outline)
        case .hairTie: drawHairTie(in: ctx, rect: rect, outline: outline)
        }
        ctx.restoreGState()
    }

    private static func drawPen(in ctx: CGContext, rect: CGRect, outline: CGColor) {
        // 笔身 + 笔帽（带夹子）+ 削尖的笔头
        let body = CGPath(roundedRect: rect.insetBy(dx: 0, dy: 0), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor(rgb(0x3E72DA).cgColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.setFillColor(rgb(0x2A4FA3).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 8, height: rect.height))
        ctx.setFillColor(rgb(0xC9CDD6).cgColor)
        ctx.fill(CGRect(x: rect.minX + 2, y: rect.minY - 0.6, width: 7, height: 1.2))
        let tip = CGMutablePath()
        tip.move(to: CGPoint(x: rect.maxX - 5, y: rect.minY))
        tip.addLine(to: CGPoint(x: rect.maxX + 3, y: 0))
        tip.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.maxY))
        tip.closeSubpath()
        ctx.setFillColor(rgb(0xEBDCB8).cgColor)
        ctx.addPath(tip); ctx.fillPath()
        ctx.setFillColor(rgb(0x2B2B33).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.maxX + 0.6, y: -0.9, width: 2.2, height: 1.8))
        ctx.addPath(body); ctx.strokePath()
    }

    private static func drawEraser(in ctx: CGContext, rect: CGRect, outline: CGColor) {
        // 粉色橡皮，一半套着蓝色纸套
        let body = CGPath(roundedRect: rect, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil)
        ctx.setFillColor(rgb(0xF4A3B5).cgColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(body); ctx.clip()
        ctx.setFillColor(rgb(0x4C7FD4).cgColor)
        ctx.fill(CGRect(x: rect.minX + rect.width * 0.42, y: rect.minY, width: rect.width, height: rect.height))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.fill(CGRect(x: rect.minX + rect.width * 0.42, y: -0.6, width: rect.width, height: 1.2))
        ctx.restoreGState()
        ctx.addPath(body); ctx.strokePath()
    }

    private static func drawBottleCap(in ctx: CGContext, rect: CGRect, outline: CGColor) {
        // 侧面看的红瓶盖：一道道竖纹，顶上一圈亮边
        let body = CGPath(roundedRect: rect, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil)
        ctx.setFillColor(rgb(0xD8343C).cgColor)
        ctx.addPath(body); ctx.fillPath()
        ctx.setStrokeColor(rgb(0x9E1E25, 0.7).cgColor)
        ctx.setLineWidth(0.7)
        var x = rect.minX + 1.8
        while x < rect.maxX - 1 {
            ctx.move(to: CGPoint(x: x, y: rect.minY + 1.8)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY - 0.6))
            x += 1.8
        }
        ctx.strokePath()
        ctx.setFillColor(rgb(0xF0676D).cgColor)
        ctx.fill(CGRect(x: rect.minX + 0.6, y: rect.minY + 0.4, width: rect.width - 1.2, height: 1.3))
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(0.8)
        ctx.addPath(body); ctx.strokePath()
    }

    private static func drawPaperBall(in ctx: CGContext, rect: CGRect, outline: CGColor) {
        // 揉皱的纸团：米白小球 + 几道折痕
        let ball = CGPath(ellipseIn: rect, transform: nil)
        ctx.setFillColor(rgb(0xF6F3EA).cgColor)
        ctx.addPath(ball); ctx.fillPath()
        ctx.setStrokeColor(rgb(0xB7B1A3, 0.9).cgColor)
        ctx.setLineWidth(0.7)
        ctx.move(to: CGPoint(x: -3.5, y: -2))
        ctx.addLine(to: CGPoint(x: 0, y: 0.5))
        ctx.addLine(to: CGPoint(x: 3, y: -2.5))
        ctx.move(to: CGPoint(x: 0, y: 0.5)); ctx.addLine(to: CGPoint(x: 0.8, y: 4))
        ctx.move(to: CGPoint(x: -4, y: 2)); ctx.addLine(to: CGPoint(x: -1.5, y: 3))
        ctx.strokePath()
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(0.8)
        ctx.addPath(ball); ctx.strokePath()
    }

    private static func drawHairTie(in ctx: CGContext, rect: CGRect, outline: CGColor) {
        // 紫色发圈：侧面看是一个扁扁的圈
        ctx.setStrokeColor(rgb(0x9B6BD6).cgColor)
        ctx.setLineWidth(2.4)
        ctx.strokeEllipse(in: rect.insetBy(dx: 1.2, dy: 1.2))
        ctx.setStrokeColor(rgb(0xC9A9F0, 0.8).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: rect.insetBy(dx: 1.6, dy: 1.4))
    }

    /// 小东西的位图（覆盖层的 CALayer 用）：pointsPerUnit 是画布单位到屏幕点的缩放，pixelScale 是屏幕倍率
    static func trinketImage(_ kind: Trinket, pointsPerUnit: CGFloat, pixelScale: CGFloat) -> CGImage? {
        let pad: CGFloat = 6
        let size = CGSize(width: kind.size.width + pad * 2, height: kind.size.height + pad * 2)
        let scale = pointsPerUnit * pixelScale
        let pixels = (width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)))
        guard let ctx = CGContext(data: nil, width: pixels.width, height: pixels.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 画布是 y 向下的：翻过来画，得到正着的位图
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        drawTrinket(kind, in: ctx)
        return ctx.makeImage()
    }

    /// 位图对应的大小（屏幕点，含四周留白）
    static func trinketImageSize(_ kind: Trinket, pointsPerUnit: CGFloat) -> CGSize {
        CGSize(width: (kind.size.width + 12) * pointsPerUnit, height: (kind.size.height + 12) * pointsPerUnit)
    }
}
