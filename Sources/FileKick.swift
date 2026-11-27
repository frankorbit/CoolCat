import CoreGraphics
import Foundation

// MARK: - Kicked File

/// 飞行中的一个残影：那一帧图标的中心、角度、缩放
struct KickGhost: Equatable {
    var center: CGPoint
    var angle: CGFloat
    var scale: CGFloat
}

/// 你让小猫踢飞的那个文件图标：从你右键的地方蹦出来 → 掉到下面的窗口顶 / 屏幕底，弹两下站稳 →
/// 等小猫跑来一脚踢中 → 转着圈、越飞越远地飞出屏幕。
///
/// 纯逻辑（屏幕坐标，y 向上；角度逆时针为正），由调用方每帧喂能落脚的面，便于单测
struct KickedFile {
    enum Phase: Equatable {
        /// 刚从原来的位置蹦起来（放大一下、抖一抖）
        case popping
        case falling
        /// 躺在某个面上，等小猫来踢
        case resting(surfaceID: Int)
        /// 被踢飞了
        case flying
        /// 飞出屏幕了（或者取消后淡出完了）
        case gone
    }

    /// 底边中点；飞起来之后是图标中心（绕中心翻跟头，轨迹才是一条干净的弧线）
    private(set) var pos: CGPoint
    private(set) var vel = CGVector(dx: 0, dy: 0)
    private(set) var angle: CGFloat = 0
    private(set) var spin: CGFloat = 0
    private(set) var phase: Phase = .popping
    /// 图标边长（屏幕点）
    let size: CGFloat
    /// 这一阶段开始了多久
    private(set) var phaseTime: CGFloat = 0
    /// 窗口顶上不去：只落在屏幕底
    private(set) var onlyFloor = false
    /// 取消了：原地缩小淡出
    private(set) var cancelled = false
    private var bounces = 0
    /// 躺在面上时离这段上沿左端多远：窗口挪动时跟着走
    private var restDX: CGFloat = 0
    /// 踢中的那一点（画「砰」的冲击星）和过了多久
    private(set) var impact: CGPoint?
    /// 飞行中最近几帧的位置（画残影）：最新的在最后
    private(set) var trail: [KickGhost] = []

    static let popTime: CGFloat = 0.42
    static let gravity: CGFloat = 1500
    /// 飞的时候重力小一点：踢出去的弧线又高又远，总能飞出屏幕
    static let flightGravity: CGFloat = 900
    /// 飞着越来越远：最小缩到这么大
    static let farScale: CGFloat = 0.55
    static let fadeTime: CGFloat = 0.3
    /// 最多飞几秒（保险）
    static let maxFlight: CGFloat = 4
    static let trailLength = 6

    /// - Parameter center: 图标原来的中心（你右键的地方）
    init(center: CGPoint, size: CGFloat) {
        self.size = size
        pos = CGPoint(x: center.x, y: center.y - size / 2)
    }

    var isGone: Bool { phase == .gone }
    var isFlying: Bool { phase == .flying }
    /// 还没被踢出去（取消的时候用：已经飞出去的就来不及了）
    var canCancel: Bool {
        switch phase {
        case .popping, .falling, .resting: return !cancelled
        case .flying, .gone: return false
        }
    }

    /// 画的时候的缩放：蹦出来时先放大一下；飞远了变小；取消时缩没
    var scale: CGFloat {
        if cancelled { return max(0, 1 - phaseTime / Self.fadeTime) }
        switch phase {
        case .popping:
            return 1 + 0.18 * sin(.pi * min(1, phaseTime / Self.popTime))
        case .flying:
            return max(Self.farScale, 1 - phaseTime * 0.4)
        default:
            return 1
        }
    }

    var opacity: CGFloat {
        cancelled ? max(0, 1 - phaseTime / Self.fadeTime) : 1
    }

    /// 画的时候的角度：蹦出来时抖一抖；小猫逼近时（nervous）瑟瑟发抖
    func displayAngle(nervous: Bool, time: CGFloat) -> CGFloat {
        switch phase {
        case .popping:
            return angle + 0.16 * sin(phaseTime * 38) * (1 - min(1, phaseTime / Self.popTime))
        case .resting where nervous && !cancelled:
            return angle + 0.05 * sin(time * 46)
        default:
            return angle
        }
    }

    /// 图标中心（画的时候绕中心转）
    var center: CGPoint {
        if phase == .flying || phase == .gone { return pos }
        return CGPoint(x: pos.x - sin(angle) * size / 2 * scale, y: pos.y + cos(angle) * size / 2 * scale)
    }

    /// 小猫该去的地方：躺着的那个面；还在蹦、在掉时预计会落在的那个面（先跑过去等着）
    /// - Parameter minWidth: 窗口上沿至少这么宽才落得住（小猫要能站在文件旁边踢）
    func kickTarget(surfaces: [RoamSurface], floor: RoamSurface, minWidth: CGFloat) -> RoamKickTarget? {
        guard !cancelled else { return nil }
        switch phase {
        case .resting(let id):
            return RoamKickTarget(surfaceID: id, x: pos.x, halfWidth: size / 2, ready: true)
        case .popping, .falling:
            let landing = landingSurface(below: pos.y, surfaces: surfaces, floor: floor, minWidth: minWidth)
            return RoamKickTarget(surfaceID: landing.id, x: clampX(pos.x, on: landing), halfWidth: size / 2,
                                  ready: false)
        case .flying, .gone:
            return nil
        }
    }

    /// 窗口顶上不去：从那儿掉下来，落到屏幕底
    mutating func dropToFloor() {
        guard !onlyFloor else { return }
        onlyFloor = true
        if case .resting(let id) = phase, id != 0 { enter(.falling) }
    }

    /// 你按了 Esc：原地缩小淡出（已经踢出去的来不及了）
    mutating func cancel() {
        guard canCancel else { return }
        cancelled = true
        phaseTime = 0
    }

    /// 一脚踢中：往 dir 那边、仰角 angle 飞出去，边飞边转（往右踢顺时针翻跟头）
    mutating func kick(angle launch: CGFloat, dir: CGFloat, speed: CGFloat, spin newSpin: CGFloat) {
        guard canCancel else { return }
        impact = CGPoint(x: pos.x - dir * size * 0.42, y: pos.y + size * 0.35)
        pos = center
        vel = CGVector(dx: cos(launch) * speed * dir, dy: sin(launch) * speed)
        spin = -dir * abs(newSpin)
        enter(.flying)
    }

    /// - Parameters:
    ///   - surfaces: 能落脚的窗口上沿（不含屏幕底）
    ///   - floor: 屏幕底
    ///   - bounds: 小猫这块屏幕：飞出去就算没了
    mutating func update(dt: CGFloat, surfaces: [RoamSurface], floor: RoamSurface, minWidth: CGFloat,
                         bounds: CGRect) {
        phaseTime += dt
        if cancelled {
            if phaseTime >= Self.fadeTime { phase = .gone }
            return
        }
        switch phase {
        case .popping:
            if phaseTime >= Self.popTime {
                // 从原来的位置往上一蹦，再掉下去
                vel = CGVector(dx: 0, dy: 240)
                spin = CGFloat.random(in: -1.6...1.6)
                enter(.falling)
            }
        case .falling:
            stepFalling(dt: dt, surfaces: surfaces, floor: floor, minWidth: minWidth)
        case .resting(let id):
            stepResting(id: id, dt: dt, surfaces: surfaces, floor: floor)
        case .flying:
            stepFlying(dt: dt, bounds: bounds)
        case .gone:
            break
        }
    }

    private mutating func enter(_ next: Phase) {
        phase = next
        phaseTime = 0
    }

    /// 脚下最高的那个面：够宽的窗口上沿（onlyFloor 时只算屏幕底），都没有就是屏幕底
    private func landingSurface(below height: CGFloat, surfaces: [RoamSurface], floor: RoamSurface,
                                minWidth: CGFloat) -> RoamSurface {
        guard !onlyFloor else { return floor }
        return surfaces
            .filter { $0.id != floor.id && $0.width >= minWidth && $0.contains(x: pos.x) && $0.y <= height + 0.5 }
            .max { $0.y < $1.y } ?? floor
    }

    /// 落在面上时不探出边：整个图标都在面上
    private func clampX(_ value: CGFloat, on surface: RoamSurface) -> CGFloat {
        let half = size / 2
        guard surface.width > size else { return (surface.minX + surface.maxX) / 2 }
        return min(max(value, surface.minX + half), surface.maxX - half)
    }

    private mutating func stepFalling(dt: CGFloat, surfaces: [RoamSurface], floor: RoamSurface, minWidth: CGFloat) {
        vel.dy -= Self.gravity * dt
        let newY = pos.y + vel.dy * dt
        angle += spin * dt
        let landing = landingSurface(below: pos.y, surfaces: surfaces, floor: floor, minWidth: minWidth)
        guard newY <= landing.y else {
            pos.y = newY
            return
        }
        pos.y = landing.y
        pos.x = clampX(pos.x, on: landing)
        if -vel.dy > 220 && bounces < 2 {
            // 弹起来：一次比一次低
            vel.dy = -vel.dy * 0.3
            spin *= -0.5
            bounces += 1
        } else {
            vel = CGVector(dx: 0, dy: 0)
            spin = 0
            restDX = pos.x - landing.minX
            enter(.resting(surfaceID: landing.id))
        }
    }

    private mutating func stepResting(id: Int, dt: CGFloat, surfaces: [RoamSurface], floor: RoamSurface) {
        // 站正：转回 0
        angle += (0 - angle) * min(1, dt * 14)
        if id == floor.id {
            pos.y = floor.y
            pos.x = clampX(pos.x, on: floor)
            return
        }
        // 窗口挪了就跟着挪；关了、被挡住了就接着往下掉
        guard let here = surfaces.first(where: { $0.id == id }) else {
            vel = CGVector(dx: 0, dy: 0)
            bounces = 0
            enter(.falling)
            return
        }
        pos = CGPoint(x: clampX(here.minX + restDX, on: here), y: here.y)
    }

    private mutating func stepFlying(dt: CGFloat, bounds: CGRect) {
        trail.append(KickGhost(center: pos, angle: angle, scale: scale))
        if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
        vel.dy -= Self.flightGravity * dt
        pos.x += vel.dx * dt
        pos.y += vel.dy * dt
        angle += spin * dt
        // 整个图标（连同残影）都出了屏幕才算没了
        let reach = size * scale
        let out = pos.x + reach < bounds.minX || pos.x - reach > bounds.maxX
            || pos.y - reach > bounds.maxY || pos.y + reach < bounds.minY
        let trailOut = trail.allSatisfy {
            !bounds.insetBy(dx: -size, dy: -size).contains($0.center)
        }
        if (out && trailOut) || phaseTime > Self.maxFlight { phase = .gone }
    }
}

// MARK: - Rules

/// 哪些文件能让小猫踢：只移进废纸篓，系统要用的、整个主目录 / 磁盘、废纸篓里的、小猫自己都不踢
enum FileKickRules {
    enum Rejection: Error, Equatable {
        case nothing
        case notLocal
        case missing(String)
        case protected(String)
        case alreadyInTrash
        case itsMe

        var message: String {
            switch self {
            case .nothing: return "没有选中文件"
            case .notLocal: return "只能踢本机上的文件"
            case .missing(let name): return "「\(name)」已经不在了"
            case .protected(let name): return "「\(name)」是系统要用的，小猫不敢踢"
            case .alreadyInTrash: return "已经在废纸篓里啦"
            case .itsMe: return "小猫不踢自己 🙀"
            }
        }
    }

    /// 能不能踢：本机、存在、不是系统 / 主目录 / 磁盘根目录、不在废纸篓里、不是小猫自己
    static func validate(_ urls: [URL], fileManager: FileManager = .default,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         app: URL = Bundle.main.bundleURL) -> Result<[URL], Rejection> {
        guard !urls.isEmpty else { return .failure(.nothing) }
        let homePath = home.standardizedFileURL.path
        let trashPath = homePath + "/.Trash"
        let protectedPaths: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes",
                                           "/private", "/usr", "/bin", "/sbin", "/etc", "/var", "/opt", "/cores",
                                           homePath, trashPath,
                                           homePath + "/Library", homePath + "/Desktop", homePath + "/Documents",
                                           homePath + "/Downloads"]
        var valid: [URL] = []
        for url in urls {
            guard url.isFileURL else { return .failure(.notLocal) }
            let standard = url.standardizedFileURL
            let path = standard.path
            let name = fileManager.displayName(atPath: path)
            guard fileManager.fileExists(atPath: path) else { return .failure(.missing(name)) }
            let components = standard.pathComponents
            let volumeRoot = components.count == 3 && components[1] == "Volumes"
            guard !protectedPaths.contains(path), !volumeRoot else { return .failure(.protected(name)) }
            guard !path.hasPrefix(trashPath + "/"), !path.contains("/.Trashes/") else {
                return .failure(.alreadyInTrash)
            }
            guard path != app.standardizedFileURL.path else { return .failure(.itsMe) }
            valid.append(standard)
        }
        return .success(valid)
    }
}
