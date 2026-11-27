import AppKit
import CoreGraphics

// MARK: - Kick Pose

/// 侧身小猫踢文件的那一脚：瞄准 → 身子后仰、近侧前腿往后上方收 → 一甩踢出去（腿停在多高，文件就往多高飞）→ 收回来。
/// 时间轴和 RoamDirector.Kick 对齐；都画在身体变换里（y 向下，朝右）
extension CatRenderer {
    private typealias KickTiming = RoamDirector.Kick

    /// 踢腿那条腿：方向（从正下方往前转的弧度）、长度、弯曲程度
    private struct KickLeg {
        var alpha: CGFloat
        var length: CGFloat
        var fold: CGFloat
    }

    /// 站着时腿略微向前，蓄力时往后上方收，踢完停在「90° + 仰角」附近
    private static let kickStandAlpha: CGFloat = 0.1
    private static let kickBackAlpha: CGFloat = -0.6
    private static let kickWindupLength: CGFloat = 22
    private static let kickReachLength: CGFloat = 34

    private static func smoothStep(_ value: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func mix(_ from: CGFloat, _ target: CGFloat, _ amount: CGFloat) -> CGFloat {
        from + (target - from) * amount
    }

    /// 0...1 的缓出（甩腿：一开始最快）
    private static func easeOut(_ value: CGFloat) -> CGFloat { 1 - (1 - value) * (1 - value) }

    /// 某一段里走了多少（0...1）
    private static func progress(_ time: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        max(0, min(1, (time - start) / (end - start)))
    }

    /// 踢到最高时腿的方向：仰角越大腿抬得越高（压缩一点，不至于竖成一根棍）
    private static func kickTopAlpha(_ angle: CGFloat) -> CGFloat { 1.25 + angle * 0.85 }

    /// 身子：蓄力时后仰下沉，踢出去时往前一送，再慢慢回正
    static func kickBody(_ time: CGFloat) -> (tilt: CGFloat, drop: CGFloat) {
        if time < KickTiming.aimEnd { return (0, 0) }
        if time < KickTiming.windupEnd {
            let windup = smoothStep(progress(time, from: KickTiming.aimEnd, to: KickTiming.windupEnd))
            return (-0.16 * windup, 4 * windup)
        }
        if time < KickTiming.strikeEnd {
            let strike = easeOut(progress(time, from: KickTiming.windupEnd, to: KickTiming.strikeEnd))
            return (-0.16 + 0.28 * strike, 4 - 3 * strike)
        }
        if time < KickTiming.holdEnd {
            let hold = progress(time, from: KickTiming.strikeEnd, to: KickTiming.holdEnd)
            return (0.12 - 0.05 * hold, 1)
        }
        let recover = smoothStep(progress(time, from: KickTiming.holdEnd, to: KickTiming.total))
        return (0.07 * (1 - recover), 1 - recover)
    }

    /// 蓄力到踢出去这段眯着眼（使劲）
    static func kickFocused(_ time: CGFloat) -> Bool {
        time >= KickTiming.aimEnd * 0.6 && time < KickTiming.strikeEnd + 0.05
    }

    private static func kickLeg(time: CGFloat, angle: CGFloat, rest: CGFloat) -> KickLeg {
        let top = kickTopAlpha(angle)
        if time < KickTiming.aimEnd { return KickLeg(alpha: kickStandAlpha, length: rest, fold: 0) }
        if time < KickTiming.windupEnd {
            // 爪子往后上方收起来（离地），看得出在蓄力
            let windup = smoothStep(progress(time, from: KickTiming.aimEnd, to: KickTiming.windupEnd))
            return KickLeg(alpha: mix(kickStandAlpha, kickBackAlpha, windup),
                           length: mix(rest, kickWindupLength, windup), fold: windup)
        }
        if time < KickTiming.strikeEnd {
            let strike = easeOut(progress(time, from: KickTiming.windupEnd, to: KickTiming.strikeEnd))
            return KickLeg(alpha: mix(kickBackAlpha, top, strike),
                           length: mix(kickWindupLength, kickReachLength, strike), fold: 0.9 * (1 - strike))
        }
        if time < KickTiming.holdEnd {
            // 腿停在半空，微微往回落一点
            let hold = progress(time, from: KickTiming.strikeEnd, to: KickTiming.holdEnd)
            return KickLeg(alpha: top - 0.08 * hold, length: kickReachLength, fold: 0)
        }
        let recover = smoothStep(progress(time, from: KickTiming.holdEnd, to: KickTiming.total))
        return KickLeg(alpha: mix(top - 0.08, kickStandAlpha, recover), length: mix(kickReachLength, rest, recover),
                       fold: 0.35 * sin(.pi * recover))
    }

    /// 近侧前腿的爪子落在哪、弯多少（给走路那套画腿的代码用）
    static func kickLegEnd(_ joint: CGPoint, groundY: CGFloat, time: CGFloat,
                           angle: CGFloat) -> (end: CGPoint, fold: CGFloat) {
        let rest = (groundY - joint.y) / cos(kickStandAlpha)
        let leg = kickLeg(time: time, angle: angle, rest: rest)
        let end = CGPoint(x: joint.x + leg.length * sin(leg.alpha), y: joint.y + leg.length * cos(leg.alpha))
        return (end, leg.fold)
    }

    /// 踢出去时爪子划过的两道弧线（深色描边 + 白芯：深色、浅色背景上都看得见）
    static func drawKickSwoosh(in ctx: CGContext, shoulder: CGPoint, groundY: CGFloat, time: CGFloat,
                               angle: CGFloat) {
        let fadeEnd = KickTiming.holdEnd + 0.1
        guard time > KickTiming.windupEnd + 0.02, time < fadeEnd else { return }
        let fade = time < KickTiming.strikeEnd ? 1 : 1 - progress(time, from: KickTiming.strikeEnd, to: fadeEnd)
        let rest = (groundY - shoulder.y) / cos(kickStandAlpha)
        let current = kickLeg(time: min(time, KickTiming.strikeEnd), angle: angle, rest: rest).alpha
        // 只画往前甩的那一段：弧线不要扫到地面以下
        let start = max(0.55, current - 1.3)
        let finish = current - 0.12
        guard finish > start + 0.05 else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        for (radius, width) in [(kickReachLength + 7, 2.2 as CGFloat), (kickReachLength - 5, 1.6 as CGFloat)] {
            let path = CGMutablePath()
            let steps = 14
            for step in 0...steps {
                let along = start + (finish - start) * CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: shoulder.x + radius * sin(along), y: shoulder.y + radius * cos(along))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.28 * fade).cgColor)
            ctx.setLineWidth(width + 1.6)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.9 * fade).cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// 踢中那一下：爪尖前面炸开一颗黄色的「砰」星，带几道放射线
    static func drawKickImpact(in ctx: CGContext, shoulder: CGPoint, groundY: CGFloat, time: CGFloat,
                               angle: CGFloat) {
        let duration: CGFloat = 0.24
        guard time >= KickTiming.contact, time < KickTiming.contact + duration else { return }
        let burst = (time - KickTiming.contact) / duration
        let paw = kickLegEnd(shoulder, groundY: groundY, time: KickTiming.contact, angle: angle).end
        let center = CGPoint(x: paw.x + 9, y: paw.y - 2)
        let outer = 7 + 10 * burst
        let inner = outer * 0.45
        let alpha = 1 - burst * burst
        let star = CGMutablePath()
        let spikes = 8
        for corner in 0..<(spikes * 2) {
            let radius = corner.isMultiple(of: 2) ? outer : inner
            let direction = CGFloat(corner) * .pi / CGFloat(spikes) + 0.2
            let point = CGPoint(x: center.x + radius * cos(direction), y: center.y + radius * sin(direction))
            if corner == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()
        ctx.saveGState()
        ctx.addPath(star)
        ctx.setFillColor(rgb(0xFFD84D, alpha).cgColor)
        ctx.fillPath()
        ctx.addPath(star)
        ctx.setStrokeColor(rgb(0x5A3A10, 0.8 * alpha).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokePath()
        // 放射线
        ctx.setStrokeColor(rgb(0xFFF3C4, 0.9 * alpha).cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        for ray in 0..<5 {
            let direction = -0.9 + CGFloat(ray) * 0.45
            let near = outer + 2
            let far = outer + 6 + 6 * burst
            ctx.move(to: CGPoint(x: center.x + near * cos(direction), y: center.y + near * sin(direction)))
            ctx.addLine(to: CGPoint(x: center.x + far * cos(direction), y: center.y + far * sin(direction)))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
