import AppKit
import CoreGraphics

// MARK: - Walker Window

/// 漫游中的侧身小猫：一个跟着小猫移动的透明小窗口，点击完全穿透
final class RoamWindow: NSPanel {
    let walkerView = RoamView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = walkerView
        applyWindowLevelAndBehavior()
    }

    func applyWindowLevelAndBehavior() {
        // 和主窗口同一层级：全屏应用上也能看到
        if CatSettings.shared.fullScreenOverlay {
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    /// 把窗口摆到「画布上的 anchor 落在屏幕上的 feet」的位置。平时 anchor 是脚底；爬窗框时是贴着窗框的那一点
    func place(feet: CGPoint, scale: CGFloat, anchor: CGPoint = CatRenderer.walkerFeet) {
        // 侧身小猫额外放大，和坐着的小猫体型一致
        let k = scale * CatRenderer.walkerArtScale
        let size = CGSize(width: CatRenderer.walkerCanvas.width * k, height: CatRenderer.walkerCanvas.height * k)
        let origin = CGPoint(x: feet.x - anchor.x * k,
                             y: feet.y - (CatRenderer.walkerCanvas.height - anchor.y) * k)
        let frame = CGRect(origin: origin, size: size).integral
        if frame != self.frame { setFrame(frame, display: false) }
    }
}

final class RoamView: NSView {
    var pose = CatRenderer.WalkerPose(pose: .stand, phase: 0, facing: 1, air: 0, time: 0, blink: false)
    /// 沿屏幕边裁剪（画布坐标）：屏幕外的部分不画，多屏时不会画到隔壁屏上
    var clip: (edge: RoamEdge, at: CGFloat)?
    /// 串门来的客人猫：照它的名片画（nil = 画你自己的猫）
    var visitor: CatProfile?
    /// 顶在头上的名字牌（客人猫）
    var nameTag: String?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.saveGState()
        ctx.scaleBy(x: bounds.width / CatRenderer.walkerCanvas.width, y: bounds.height / CatRenderer.walkerCanvas.height)
        if let clip {
            let w = CatRenderer.walkerCanvas.width, h = CatRenderer.walkerCanvas.height
            switch clip.edge {
            case .left: ctx.clip(to: CGRect(x: clip.at, y: 0, width: max(0, w - clip.at), height: h))
            case .right: ctx.clip(to: CGRect(x: 0, y: 0, width: max(0, clip.at), height: h))
            case .bottom: ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: max(0, clip.at)))
            }
        }
        CatRenderer.drawing(as: visitor) {
            CatRenderer.drawWalker(in: ctx, pose: pose)
        }
        if let nameTag, !nameTag.isEmpty {
            drawNameTag(nameTag, in: ctx)
        }
        ctx.restoreGState()
    }

    /// 头顶上方一块半透明深色圆角牌，白字写名字；蜷着睡时头低，牌子跟着往下挪。不跟着朝向翻转
    private func drawNameTag(_ name: String, in ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let width = size.width + 14
        let height = size.height + 5
        let headX = CatRenderer.walkerFeet.x + pose.facing * 12
        let centerY: CGFloat = pose.pose == .curl ? 104 : 46
        let rect = CGRect(x: headX - width / 2, y: centerY - height / 2, width: width, height: height)
        ctx.saveGState()
        let pill = CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        ctx.addPath(pill)
        ctx.setFillColor(NSColor(calibratedWhite: 0.1, alpha: 0.72).cgColor)
        ctx.fillPath()
        ctx.addPath(pill)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.35).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.restoreGState()
        text.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 2.5))
    }
}

// MARK: - Surfaces

/// 一次扫描的结果：能站的窗口上沿，以及其余窗口为什么站不了（设置里显示、预览按钮提示用）
struct RoamScanReport {
    var surfaces: [RoamSurface] = []
    /// 能爬上去的窗框侧边（窗口顶太高跳不上去时用）
    var walls: [RoamWall] = []
    /// 窗口顶上方空间不够站一只猫
    var noRoom = 0
    /// 窗口上沿被前面的窗口挡住了
    var occluded = 0
    /// 窗口太窄
    var tooNarrow = 0
    /// 窗口顶上方至少要留出多少点
    var neededRoom: CGFloat = 0
    /// 这次看到的所有窗口的位置（窗口号 → 屏幕坐标）：积雪用来判断窗口挪没挪、关没关
    var frames: [Int: CGRect] = [:]

    var summary: String {
        if !surfaces.isEmpty {
            return "现在有 \(surfaces.count) 处能跳" + (walls.isEmpty ? "" : "，\(walls.count) 条窗框能爬（太高跳不上去时爬上去）")
        }
        var reasons: [String] = []
        if noRoom > 0 { reasons.append("\(noRoom) 个窗口顶上空间不够（要留出约 \(Int(neededRoom)) 点）") }
        if occluded > 0 { reasons.append("\(occluded) 个被前面的窗口挡住") }
        if tooNarrow > 0 { reasons.append("\(tooNarrow) 个太窄") }
        return reasons.isEmpty ? "这块屏幕上没有窗口" : "现在没有能跳的窗口：" + reasons.joined(separator: "，")
    }
}

/// 扫描屏幕上能站的窗口上沿。只读窗口位置（不需要屏幕录制权限），不读内容。
enum RoamSurfaceScanner {
    static func windowTops(on screen: NSScreen, catHeight: CGFloat, minWidth: CGFloat) -> [RoamSurface] {
        scan(on: screen, catHeight: catHeight, minWidth: minWidth).surfaces
    }

    /// 小猫这块屏幕上最靠前的普通窗口（多半是你正在看的那扇）：只读位置。跳过小猫自己的窗口（设置窗口）
    static func frontmostWindow(on screen: NSScreen) -> (id: Int, rect: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        for info in raw {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = info[kCGWindowNumber as String] as? Int else { continue }
            let cg = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard cg.width >= 120, cg.height >= 80 else { continue }
            // 小猫自己的设置窗口不算，看它后面那一扇（在设置里点「举牌预览」时最前面就是设置窗口）
            guard (info[kCGWindowOwnerPID as String] as? Int) != myPID else { continue }
            let rect = CGRect(x: cg.minX, y: primary.frame.maxY - cg.maxY, width: cg.width, height: cg.height)
            // 最前面的窗口在别的屏幕上（小猫过不去）：看小猫这块屏幕上最靠前的那扇，免得目标忽有忽无
            guard screen.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            return (id, rect)
        }
        return nil
    }

    /// 侧边被前面的窗口挡住了三成以上：不爬（看起来像爬在别的窗口上）
    private static func sideCovered(x: CGFloat, from bottom: CGFloat, to top: CGFloat, by fronts: [CGRect]) -> Bool {
        var covered: CGFloat = 0
        for r in fronts where r.minX - 2 <= x && r.maxX + 2 >= x {
            covered += max(0, min(top, r.maxY) - max(bottom, r.minY))
        }
        return covered > (top - bottom) * 0.3
    }

    /// - Parameters:
    ///   - screen: 小猫所在的屏幕
    ///   - catHeight: 小猫站着的高度（屏幕点）：上沿离屏幕最上沿至少得有它的八成（耳朵可以伸进菜单栏）
    ///   - minWidth: 太窄的不站
    static func scan(on screen: NSScreen, catHeight: CGFloat, minWidth: CGFloat) -> RoamScanReport {
        var report = RoamScanReport(neededRoom: catHeight * 0.8)
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return report }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let visible = screen.visibleFrame
        // 脚下那条边被前面的窗口盖住才算站不了；前面窗口只挡住上方空间时，小猫画在最上层，看起来就是站在它前面
        let footZone = catHeight * 0.08
        // 前后顺序：列表里越靠前越在上层
        var rects: [(id: Int, rect: CGRect)] = []
        for info in raw {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != myPID,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = info[kCGWindowNumber as String] as? Int else { continue }
            let cg = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            // CG 坐标原点在主屏左上角、y 向下 → AppKit 坐标
            let rect = CGRect(x: cg.minX, y: primary.frame.maxY - cg.maxY, width: cg.width, height: cg.height)
            guard rect.width >= 40, rect.height >= 40 else { continue }
            rects.append((id, rect))
            report.frames[id] = rect
        }
        for (index, item) in rects.enumerated() {
            let top = item.rect.maxY
            // 只统计上沿在这块屏幕里的窗口
            guard item.rect.maxX > visible.minX, item.rect.minX < visible.maxX,
                  top > visible.minY + 60, top <= screen.frame.maxY else { continue }
            guard item.rect.width >= minWidth else {
                report.tooNarrow += 1
                continue
            }
            guard top < visible.maxY - 8, top + catHeight * 0.8 < screen.frame.maxY else {
                report.noRoom += 1
                continue
            }
            var segments = [(max(item.rect.minX, visible.minX), min(item.rect.maxX, visible.maxX))]
            // 被前面的窗口盖住的那段去掉
            for front in rects.prefix(index) {
                let r = front.rect
                guard r.minY < top + footZone, r.maxY > top - 2 else { continue }
                segments = segments.flatMap { seg -> [(CGFloat, CGFloat)] in
                    if r.maxX <= seg.0 || r.minX >= seg.1 { return [seg] }
                    var out: [(CGFloat, CGFloat)] = []
                    if r.minX > seg.0 { out.append((seg.0, r.minX)) }
                    if r.maxX < seg.1 { out.append((r.maxX, seg.1)) }
                    return out
                }
            }
            let usable = segments.enumerated().filter { $0.element.1 - $0.element.0 >= minWidth }
            if usable.isEmpty { report.occluded += 1 }
            for (i, seg) in usable {
                let surface = RoamSurface(id: item.id * 8 + i + 1, minX: seg.0, maxX: seg.1, y: top)
                report.surfaces.append(surface)
                // 这段上沿正好到窗口的左/右角，而且那条侧边没被前面的窗口挡住：可以顺着侧边爬上来
                let bottom = max(item.rect.minY, visible.minY)
                for (x, windowOnRight) in [(item.rect.minX, true), (item.rect.maxX, false)] {
                    let atCorner = windowOnRight ? abs(seg.0 - x) < 2 : abs(seg.1 - x) < 2
                    let fronts = rects.prefix(index).map(\.rect)
                    guard atCorner, x > visible.minX + 30, x < visible.maxX - 30, top - bottom > 60,
                          !Self.sideCovered(x: x, from: bottom, to: top, by: fronts) else { continue }
                    report.walls.append(RoamWall(x: x, windowOnRight: windowOnRight, minY: bottom, top: top,
                                                 surfaceID: surface.id))
                }
            }
        }
        return report
    }
}
