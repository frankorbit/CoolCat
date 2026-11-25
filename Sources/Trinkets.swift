import CoreGraphics
import Foundation

// MARK: - Trinket

/// 小猫从你桌上叼走、再推下窗口的小东西
enum Trinket: Int, CaseIterable {
    case pen, eraser, bottleCap, paperBall, hairTie

    /// 比照猫头放大：一支笔比猫脑袋还宽一点
    static let artScale: CGFloat = 1.4

    /// 画布上的大小（侧身小猫画布单位，和猫一起缩放）
    var size: CGSize {
        CGSize(width: baseSize.width * Self.artScale, height: baseSize.height * Self.artScale)
    }

    /// 没放大之前的大小：画法里的细节按这个尺寸来
    var baseSize: CGSize {
        switch self {
        case .pen: return CGSize(width: 26, height: 4.6)
        case .eraser: return CGSize(width: 13, height: 7)
        case .bottleCap: return CGSize(width: 11, height: 7)
        case .paperBall: return CGSize(width: 12, height: 11)
        case .hairTie: return CGSize(width: 13, height: 5)
        }
    }

    /// 圆的东西落地后还会滚一段
    var rolls: Bool { self == .paperBall || self == .bottleCap }

    /// 落地后躺平：笔、橡皮、发圈横着躺（角度回到 0 或 π），圆的随便停在哪个角度
    var liesFlat: Bool { !rolls }
}

// MARK: - Physics

/// 被推下去（或者从嘴里掉下来）的小东西：翻着跟头往下掉，落在窗口顶或屏幕底，弹两下、滚一滚，
/// 躺一会儿就淡出。窗口挪走了，躺在上面的东西接着往下掉。
///
/// 纯逻辑（屏幕坐标，y 向上），由调用方每帧喂能落脚的面，便于单测。
struct TrinketPhysics {
    struct Item: Equatable {
        var kind: Trinket
        /// 底边中点（落在面上时就是面上的那一点）
        var pos: CGPoint
        var vel: CGVector
        /// 旋转角（弧度）和角速度
        var angle: CGFloat
        var spin: CGFloat
        /// 落定了：躺在某个面上
        var resting = false
        /// 落定后过了多久（到点淡出）
        var restTime: CGFloat = 0
        var bounces = 0
    }

    static let gravity: CGFloat = 1500
    /// 落定后躺多久开始淡出、淡出要多久
    static let stayTime: CGFloat = 25
    static let fadeTime: CGFloat = 1.2
    /// 同时最多留几个（多了最早的先消失）
    static let maxItems = 6

    private(set) var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }

    /// 0…1：快消失时淡出
    static func opacity(of item: Item) -> CGFloat {
        guard item.resting else { return 1 }
        return max(0, min(1, (stayTime + fadeTime - item.restTime) / fadeTime))
    }

    /// 放手：从 at 开始，带着横向速度往下掉（推下去的有速度，从嘴里掉下来的没有）
    mutating func release(_ kind: Trinket, at pos: CGPoint, vx: CGFloat, spin: CGFloat) {
        items.append(Item(kind: kind, pos: pos, vel: CGVector(dx: vx, dy: 40), angle: 0, spin: spin))
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
    }

    /// - Parameters:
    ///   - surfaces: 能落脚的面（屏幕底部 + 窗口上沿）
    ///   - walls: 屏幕左右边：东西不会滚出屏幕
    mutating func update(dt: CGFloat, surfaces: [RoamSurface], walls: ClosedRange<CGFloat>) {
        for i in items.indices {
            if items[i].resting {
                stepResting(&items[i], dt: dt, surfaces: surfaces)
            } else {
                stepFalling(&items[i], dt: dt, surfaces: surfaces)
            }
            // 屏幕两边：碰到就弹回来
            if items[i].pos.x < walls.lowerBound || items[i].pos.x > walls.upperBound {
                items[i].pos.x = min(max(items[i].pos.x, walls.lowerBound), walls.upperBound)
                items[i].vel.dx = -items[i].vel.dx * 0.4
            }
        }
        items.removeAll { $0.resting && $0.restTime >= Self.stayTime + Self.fadeTime }
    }

    private func stepFalling(_ item: inout Item, dt: CGFloat, surfaces: [RoamSurface]) {
        item.vel.dy -= Self.gravity * dt
        let oldY = item.pos.y
        let newY = oldY + item.vel.dy * dt
        item.pos.x += item.vel.dx * dt
        item.angle += item.spin * dt
        // 落到脚下最高的那个面
        let below = surfaces
            .filter { $0.contains(x: item.pos.x) && $0.y <= oldY + 0.5 && $0.y >= newY }
            .max { $0.y < $1.y }
        guard let landing = below else {
            item.pos.y = newY
            return
        }
        item.pos.y = landing.y
        if -item.vel.dy > 160 && item.bounces < 3 {
            // 弹起来：一次比一次低，转得也慢下来
            item.vel.dy = -item.vel.dy * 0.32
            item.vel.dx *= item.kind.rolls ? 0.8 : 0.5
            item.spin *= 0.45
            item.bounces += 1
        } else {
            item.vel.dy = 0
            item.resting = true
            item.restTime = 0
        }
    }

    private func stepResting(_ item: inout Item, dt: CGFloat, surfaces: [RoamSurface]) {
        // 脚下的面没了（窗口关了、挪走了）：接着往下掉
        guard surfaces.contains(where: { $0.contains(x: item.pos.x) && abs($0.y - item.pos.y) < 1.5 }) else {
            item.resting = false
            item.vel = CGVector(dx: item.vel.dx * 0.5, dy: 0)
            return
        }
        // 滑 / 滚一段停下；滚出了面的边就掉下去（上面那个 guard 下一帧接手）
        let friction: CGFloat = item.kind.rolls ? 1.6 : 7
        item.pos.x += item.vel.dx * dt
        item.vel.dx *= max(0, 1 - friction * dt)
        if abs(item.vel.dx) < 2 { item.vel.dx = 0 }
        if item.kind.rolls {
            // 滚：转动和移动对得上
            item.angle += item.vel.dx * dt / max(1, item.kind.size.height / 2)
        } else {
            // 躺平：转到最近的平躺角度
            let flat = (item.angle / .pi).rounded() * .pi
            item.angle += (flat - item.angle) * min(1, dt * 12)
        }
        item.spin = 0
        item.restTime += dt
    }
}
