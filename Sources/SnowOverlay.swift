import AppKit
import QuartzCore

// MARK: - Snow Overlay

/// 画窗口顶积雪的全屏透明窗口：点击完全穿透，只在小猫那块屏幕上。
/// 用不带位图的 layer-hosting 视图 + 几个 CAShapeLayer，全屏也不会多开一张 4K 大小的位图；
/// 层级比漫游小猫低一档，小猫踩在雪上、雪画在别的窗口上面
final class SnowOverlayWindow: NSPanel {
    private let capLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    private let printLayer = CAShapeLayer()
    private let clumpLayer = CAShapeLayer()
    /// 上次画的时候积雪的「指纹」：厚度、脚印深浅都没变就不重建路径
    private var drawnSignature: Int?
    private var hadClumps = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        let host = NSView()
        // 先给 layer 再打开 wantsLayer：layer-hosting，根 layer 没有内容、不占位图
        host.layer = CALayer()
        host.wantsLayer = true
        contentView = host
        for layer in [capLayer, shadeLayer, printLayer, clumpLayer] {
            host.layer?.addSublayer(layer)
        }
        capLayer.fillColor = NSColor(calibratedRed: 0.985, green: 0.99, blue: 1, alpha: 1).cgColor
        // 淡蓝描边 + 一点点投影：浅色窗口标题栏上也看得见
        capLayer.strokeColor = CatRenderer.rgb(0xAFC0D6, 0.9).cgColor
        capLayer.lineWidth = 0.8
        capLayer.shadowColor = NSColor.black.cgColor
        capLayer.shadowOpacity = 0.16
        capLayer.shadowRadius = 1.2
        capLayer.shadowOffset = CGSize(width: 0, height: -0.8)
        shadeLayer.fillColor = CatRenderer.rgb(0xDCE5F0, 0.9).cgColor
        printLayer.fillColor = CatRenderer.rgb(0x9FB4CC, 0.8).cgColor
        clumpLayer.fillColor = NSColor.white.cgColor
        clumpLayer.strokeColor = CatRenderer.rgb(0xAFC0D6, 0.7).cgColor
        clumpLayer.lineWidth = 0.6
        applyWindowLevelAndBehavior()
    }

    /// 比漫游小猫的窗口低一档
    func applyWindowLevelAndBehavior() {
        if CatSettings.shared.fullScreenOverlay {
            level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    /// 每帧调用：雪层和脚印只在厚度、脚印深浅、窗口位置变了时重建路径；飞着的雪块每帧更新
    func render(_ pack: Snowpack, on screen: NSScreen) {
        guard pack.hasVisibleSnow else {
            if isVisible { orderOut(nil) }
            return
        }
        if frame != screen.frame {
            setFrame(screen.frame, display: false)
            drawnSignature = nil
        }
        let scale = screen.backingScaleFactor
        let origin = screen.frame.origin
        let signature = Self.signature(of: pack)
        let animating = !pack.clumps.isEmpty || hadClumps
        // 什么都没变（积满了、没有脚印、没有飞着的雪块）：这一帧不碰 Core Animation
        guard signature != drawnSignature || animating || capLayer.contentsScale != scale else {
            if !isVisible { orderFrontRegardless() }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if signature != drawnSignature {
            drawnSignature = signature
            let caps = pack.capPath(origin: origin)
            capLayer.path = caps
            capLayer.shadowPath = caps
            shadeLayer.path = pack.capShadePath(origin: origin)
            printLayer.path = pack.printPath(origin: origin)
        }
        if animating {
            clumpLayer.path = pack.clumpPath(origin: origin)
            hadClumps = !pack.clumps.isEmpty
        }
        for layer in [capLayer, shadeLayer, printLayer, clumpLayer] where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }

    /// 厚度按 1%、脚印按 2 秒一档：积满之后、没有脚印时完全不用重画
    private static func signature(of pack: Snowpack) -> Int {
        var hasher = Hasher()
        hasher.combine(pack.revision)
        for (id, cap) in pack.caps.sorted(by: { $0.key < $1.key }) {
            hasher.combine(id)
            hasher.combine(Int(cap.depth * 100))
        }
        for print in pack.prints { hasher.combine(Int(print.age / 2)) }
        return hasher.finalize()
    }
}
