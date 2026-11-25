import AppKit
import QuartzCore

// MARK: - Desk Overlay

/// 覆盖层上的一个小东西（被推下桌的笔、瓶盖……）
struct TrinketSprite: Equatable {
    var kind: Trinket
    /// 底边中点（屏幕坐标）
    var pos: CGPoint
    var angle: CGFloat
    var opacity: CGFloat
}

/// 小猫「桌面」上的东西：窗口顶的积雪、被推下桌的小东西。一个全屏透明窗口，点击完全穿透，只在小猫那块屏幕上。
/// 用不带位图的 layer-hosting 视图 + 几个 CALayer，全屏也不会多开一张 4K 大小的位图；
/// 层级比漫游小猫低一档，小猫踩在雪上、东西画在别的窗口上面
final class DeskOverlayWindow: NSPanel {
    private let capLayer = CAShapeLayer()
    private let shadeLayer = CAShapeLayer()
    private let printLayer = CAShapeLayer()
    private let clumpLayer = CAShapeLayer()
    /// 上次画的时候积雪的「指纹」：厚度、脚印深浅都没变就不重建路径
    private var drawnSignature: Int?
    private var hadClumps = false
    /// 小东西：每个一个 CALayer（位图按种类缓存）
    private var trinketLayers: [CALayer] = []
    private var trinketImages: [String: CGImage] = [:]
    private var drawnSprites: [TrinketSprite] = []

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

    /// 每帧调用：雪层和脚印只在厚度、脚印深浅、窗口位置变了时重建路径；飞着的雪块、小东西变了才更新
    /// - Parameter pointsPerUnit: 侧身小猫画布单位到屏幕点的缩放（小东西和猫一起缩放）
    func render(_ pack: Snowpack, trinkets: [TrinketSprite], pointsPerUnit: CGFloat, on screen: NSScreen) {
        guard pack.hasVisibleSnow || !trinkets.isEmpty || !drawnSprites.isEmpty else {
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
        // 什么都没变（积满了、没有脚印、没有飞着的雪块、东西都躺着）：这一帧不碰 Core Animation
        let changed = signature != drawnSignature || trinkets != drawnSprites || capLayer.contentsScale != scale
        guard changed || animating else {
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
        if trinkets != drawnSprites {
            placeTrinkets(trinkets, origin: origin, pointsPerUnit: pointsPerUnit, pixelScale: scale)
        }
        CATransaction.commit()
        setShown(pack.hasVisibleSnow || !trinkets.isEmpty)
    }

    private func setShown(_ shown: Bool) {
        if shown && !isVisible {
            orderFrontRegardless()
        } else if !shown && isVisible {
            orderOut(nil)
        }
    }

    /// 每个小东西一个 layer：位置、角度、透明度跟着物理走，位图按种类和缩放缓存
    private func placeTrinkets(_ sprites: [TrinketSprite], origin: CGPoint, pointsPerUnit: CGFloat,
                               pixelScale: CGFloat) {
        drawnSprites = sprites
        while trinketLayers.count < sprites.count {
            let layer = CALayer()
            layer.contentsGravity = .resize
            contentView?.layer?.addSublayer(layer)
            trinketLayers.append(layer)
        }
        for (i, layer) in trinketLayers.enumerated() {
            guard i < sprites.count else {
                layer.isHidden = true
                continue
            }
            let sprite = sprites[i]
            let key = "\(sprite.kind.rawValue)@\(pointsPerUnit)x\(pixelScale)"
            if trinketImages[key] == nil {
                trinketImages[key] = CatRenderer.trinketImage(sprite.kind, pointsPerUnit: pointsPerUnit,
                                                              pixelScale: pixelScale)
            }
            let size = CatRenderer.trinketImageSize(sprite.kind, pointsPerUnit: pointsPerUnit)
            layer.isHidden = false
            layer.contents = trinketImages[key]
            layer.contentsScale = pixelScale
            layer.bounds = CGRect(origin: .zero, size: size)
            // 底边中点在 pos：中心往上半个东西的高度
            let half = sprite.kind.size.height / 2 * pointsPerUnit
            layer.position = CGPoint(x: sprite.pos.x - origin.x, y: sprite.pos.y - origin.y + half)
            // 画布 y 向下、屏幕 y 向上：转向反过来
            layer.setAffineTransform(CGAffineTransform(rotationAngle: -sprite.angle))
            layer.opacity = Float(sprite.opacity)
        }
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
