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

    /// 把窗口摆到「脚底在 feet」的位置
    func place(feet: CGPoint, scale: CGFloat) {
        // 侧身小猫额外放大，和坐着的小猫体型一致
        let k = scale * CatRenderer.walkerArtScale
        let size = CGSize(width: CatRenderer.walkerCanvas.width * k, height: CatRenderer.walkerCanvas.height * k)
        let origin = CGPoint(x: feet.x - CatRenderer.walkerFeet.x * k,
                             y: feet.y - (CatRenderer.walkerCanvas.height - CatRenderer.walkerFeet.y) * k)
        let frame = CGRect(origin: origin, size: size).integral
        if frame != self.frame { setFrame(frame, display: false) }
    }
}

final class RoamView: NSView {
    var pose = CatRenderer.WalkerPose(pose: .stand, phase: 0, facing: 1, air: 0, time: 0, blink: false)
    /// 沿屏幕边裁剪（画布坐标）：屏幕外的部分不画，多屏时不会画到隔壁屏上
    var clip: (edge: RoamEdge, at: CGFloat)?

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
        CatRenderer.drawWalker(in: ctx, pose: pose)
        ctx.restoreGState()
    }
}

// MARK: - Surfaces

/// 扫描屏幕上能站的窗口上沿。只读窗口位置（不需要屏幕录制权限），不读内容。
enum RoamSurfaceScanner {
    /// - Parameters:
    ///   - screen: 小猫所在的屏幕
    ///   - catHeight: 小猫站着的高度（屏幕点）：上沿离屏幕最上沿至少得有它的八成（耳朵可以伸进菜单栏）
    ///   - minWidth: 太窄的不站
    static func windowTops(on screen: NSScreen, catHeight: CGFloat, minWidth: CGFloat) -> [RoamSurface] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return [] }
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
        }
        var result: [RoamSurface] = []
        for (index, item) in rects.enumerated() {
            let top = item.rect.maxY
            guard item.rect.width >= minWidth,
                  top > visible.minY + 60, top < visible.maxY - 8, top + catHeight * 0.8 < screen.frame.maxY,
                  item.rect.maxX > visible.minX, item.rect.minX < visible.maxX else { continue }
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
            for (i, seg) in segments.enumerated() where seg.1 - seg.0 >= minWidth {
                result.append(RoamSurface(id: item.id * 8 + i + 1, minX: seg.0, maxX: seg.1, y: top))
            }
        }
        return result
    }
}
