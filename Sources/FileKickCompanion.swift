import AppKit
import QuartzCore

// MARK: - File Kick Companion

/// 「小猫踢飞（移到废纸篓）」的 App 这一侧：接 Finder 右键服务（和菜单里的「小猫踢飞文件…」），
/// 先把文件移进废纸篓，同时在每个文件原来的地方蹦出它的图标；每帧推进图标的物理、告诉漫游小猫下一个去踢哪个
/// （从近到远一个个踢）；踢中时让图标转着飞出屏幕。踢之前按 Esc 可以取消（还没踢的文件从废纸篓放回原处）。
///
/// 只移进废纸篓，绝不永久删除；系统目录、主目录、磁盘根目录、小猫自己都不让踢
final class FileKickCompanion: NSObject {
    /// 提示气泡（踢进去了、没踢动、取消了）
    var onNotice: ((String) -> Void)?
    /// 小猫藏起来了：问调用方能不能踢（藏着就不踢，免得文件凭空消失）
    var canKick: (() -> Bool)?

    /// 一个要踢的文件：图标、物理、在废纸篓里的位置
    private struct Kickable {
        let id: Int
        let original: URL
        var inTrash: URL?
        var icon: NSImage?
        /// 图标从哪儿蹦出来（屏幕坐标）；nil = 从屏幕顶上掉下来（菜单里选的文件）
        var origin: CGPoint?
        /// 还要等多久才蹦出来：几个文件错开一点，不在同一帧
        var delay: CGFloat
        var file: KickedFile?
        /// 已经被踢出去了
        var launched = false
    }

    private var items: [Kickable] = []
    /// 小猫正在去踢的那个（编号）：选定了就不换，免得半路改主意来回跑
    private var target: Int?
    /// 这一批里已经踢出去的
    private var kickedNames: [String] = []
    /// 文件在哪块屏幕上（你右键的地方）：小猫这一趟去那块屏幕；nil = 小猫自己那块（菜单里选的文件）
    private(set) var targetScreen: NSScreen?
    /// 正在取图标、移进废纸篓（后台）
    private var trashing = false
    private var size: CGFloat = 0
    private var time: CGFloat = 0

    /// 最近一次右键（或 Control + 左键）的位置和时刻：Finder 服务里拿不到图标位置，就从这里蹦出来
    private var lastContextClick: (point: CGPoint, at: CFTimeInterval)?
    private var clickMonitor: Any?

    /// 图标边长（侧身小猫画布单位，乘体型缩放）：比猫身子略小一点
    static let iconUnits: CGFloat = 46
    /// 右键多久之内调起的服务，算是从右键的地方蹦出来
    static let contextClickMaxAge: CFTimeInterval = 15
    /// 一次最多踢几个：再多屏幕上就乱成一锅粥了
    static let maxFiles = 20
    /// 相邻两个文件蹦出来错开多久
    static let spawnStagger: CGFloat = 0.06

    var isBusy: Bool { !items.isEmpty || trashing }
    /// 屏幕上有文件图标（扫窗口勤快点，文件要跟着窗口走）
    var hasFiles: Bool { items.contains { $0.file != nil } }

    /// 开始记右键位置（全局鼠标监听不需要额外权限）
    func start() {
        guard clickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.rightMouseDown, .leftMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let contextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard contextClick else { return }
            self?.lastContextClick = (NSEvent.mouseLocation, CACurrentMediaTime())
        }
    }

    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Requests

    /// Finder 右键 → 服务 →「CoolCat 小猫踢飞（移到废纸篓）」（Info.plist 里 NSServices 的 NSMessage = kickFile）
    @objc func kickFile(_ pasteboard: NSPasteboard, userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []).compactMap { $0 as? URL }
        guard !urls.isEmpty else {
            error.pointee = "请先在 Finder 里选中要踢的文件" as NSString
            return
        }
        let recent = lastContextClick.flatMap {
            CACurrentMediaTime() - $0.at < Self.contextClickMaxAge ? $0.point : nil
        }
        request(urls, at: recent ?? NSEvent.mouseLocation)
    }

    /// 踢这些文件。point = 你右键的地方（屏幕坐标）：桌面上的文件从各自的位置蹦出来，其余的以这里为中心排开；
    /// nil = 从屏幕顶上掉下来（菜单里选的文件）
    func request(_ urls: [URL], at point: CGPoint?) {
        guard !isBusy else {
            onNotice?("小猫正忙着踢上一批呢")
            return
        }
        guard canKick?() ?? true else {
            onNotice?("小猫藏起来了，先显示小猫再让它踢吧")
            return
        }
        var targets: [URL]
        switch FileKickRules.validate(urls) {
        case .failure(let reason):
            onNotice?(reason.message)
            return
        case .success(let valid):
            targets = valid
        }
        if targets.count > Self.maxFiles {
            targets = Array(targets.prefix(Self.maxFiles))
            onNotice?("一次最多踢 \(Self.maxFiles) 个，先踢前 \(Self.maxFiles) 个")
        }
        targetScreen = point.flatMap { spot in NSScreen.screens.first { $0.frame.contains(spot) } }
        trashing = true
        kickedNames = []
        size = Self.iconUnits * CatSettings.shared.scale * CatRenderer.walkerArtScale
        // 先照 Finder 的样子拿图标（文件还在原处才拿得到），再移进废纸篓
        FinderBridge.thumbnails(for: targets, size: size) { [weak self] icons in
            self?.moveToTrash(targets, icons: icons, around: point)
        }
    }

    /// 进了废纸篓的一个文件：它是第几个、在废纸篓里的位置、删之前在桌面上的位置
    private struct Moved {
        var index: Int
        var inTrash: URL?
        var spot: CGPoint?
    }

    /// 移进废纸篓放到后台（网络盘可能要一会儿）；移完了图标才蹦出来：原来的图标消失、这个蹦出来，像它自己跳出来的
    private func moveToTrash(_ targets: [URL], icons: [NSImage?], around point: CGPoint?) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 先请 Finder 一次删完（顺便问桌面上的图标在哪）：Finder 自己删的，原图标马上消失；
            // 自己删的话 Finder 要两三秒才发现，这期间原图标还在，看起来像有两个图标
            let viaFinder = FinderBridge.trash(targets)
            var results: [FinderBridge.Trashed] = []
            var finderDenied = false
            switch viaFinder {
            case .success(let items): results = items
            case .failure(let reason):
                finderDenied = reason == .notAuthorized
                results = targets.map { _ in FinderBridge.Trashed(desktopSpot: nil, inTrash: nil, trashed: false) }
            }
            var moved: [Moved] = []
            var failure: String?
            for (index, url) in targets.enumerated() {
                let result = results[index]
                if result.trashed {
                    moved.append(Moved(index: index, inTrash: result.inTrash, spot: result.desktopSpot))
                    continue
                }
                // Finder 没删成：自己删
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                    moved.append(Moved(index: index, inTrash: resulting as URL?, spot: nil))
                } catch {
                    failure = failure ?? "没踢动「\(url.lastPathComponent)」：\(error.localizedDescription)"
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.trashing = false
                if finderDenied {
                    self.onNotice?("在「隐私与安全性 → 自动化」里允许 CoolCat 控制 Finder，原图标就会马上消失")
                }
                // 没进废纸篓的不演；进去了的照样踢
                if let failure { self.onNotice?(failure) }
                guard !moved.isEmpty else {
                    self.targetScreen = nil
                    return
                }
                let cluster = point.map { FileKickOrder.clusterSpots(count: moved.count, around: $0, size: self.size) }
                self.items = moved.enumerated().map { order, entry in
                    Kickable(id: order, original: targets[entry.index], inTrash: entry.inTrash,
                             icon: icons[entry.index], origin: entry.spot ?? cluster?[order],
                             delay: CGFloat(order) * Self.spawnStagger)
                }
            }
        }
    }

    /// Esc：还没踢出去的不踢了，从废纸篓放回原处（已经飞出去的来不及了）
    func cancel() {
        let pending = items.filter { !$0.launched && ($0.file?.canCancel ?? true) }
        guard !pending.isEmpty else { return }
        var failed: [String] = []
        for item in pending {
            guard let inTrash = item.inTrash else {
                failed.append(item.original.lastPathComponent)
                continue
            }
            do {
                try FileManager.default.moveItem(at: inTrash, to: item.original)
            } catch {
                failed.append(item.original.lastPathComponent)
            }
        }
        let pendingIDs = Set(pending.map(\.id))
        // 已经蹦出来的缩小淡出；还没蹦出来的直接不要了
        items = items.compactMap { item in
            guard pendingIDs.contains(item.id) else { return item }
            guard var file = item.file else { return nil }
            file.cancel()
            var cancelled = item
            cancelled.file = file
            return cancelled
        }
        target = nil
        onNotice?(failed.isEmpty ? "好吧，不踢了，放回去啦" : "「\(failed[0])」没放回去，去废纸篓里「放回原处」吧")
    }

    // MARK: Roam Hooks

    /// 小猫一脚踢中：正在踢的那个往那个角度飞出去；全踢完了冒个气泡
    func kicked(angle: CGFloat, dir: CGFloat) {
        guard let id = target, let index = items.firstIndex(where: { $0.id == id }),
              var file = items[index].file, file.canCancel else { return }
        file.kick(angle: angle, dir: dir, speed: CGFloat.random(in: 1500...1900), spin: CGFloat.random(in: 9...14))
        items[index].file = file
        items[index].launched = true
        kickedNames.append(items[index].original.lastPathComponent)
        target = nil
        guard !items.contains(where: { !$0.launched && ($0.file?.canCancel ?? true) }) else { return }
        let count = kickedNames.count
        onNotice?(count == 1 ? "🗑️ 把「\(kickedNames[0])」踢进废纸篓啦" : "🗑️ 把 \(count) 个文件踢进废纸篓啦")
    }

    /// 正在踢的那个落在小猫上不去的窗口顶上：让它掉到屏幕底
    func targetUnreachable() {
        guard let id = target, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].file?.dropToFloor()
    }

    // MARK: Per Frame

    /// 每帧：一个个放出等着的图标、推进物理；全飞出屏幕就收工
    /// - Parameter screen: 小猫这一帧在哪块屏幕上活动（surfaces、floor 都是这块屏幕的）
    func update(dt: CGFloat, surfaces: [RoamSurface], floor: RoamSurface, screen: NSScreen, scale: CGFloat) {
        time += dt
        // 文件在另一块屏幕上、小猫还没回座位换过去：图标先别蹦（这一帧的窗口、地面都是另一块屏幕的）
        let screenReady = targetScreen.map { $0 == screen } ?? true
        let minWidth = Self.landingWidth(size: size, scale: scale)
        for index in items.indices {
            if items[index].file == nil {
                guard screenReady else { continue }
                items[index].delay -= dt
                guard items[index].delay <= 0 else { continue }
                items[index].file = KickedFile(center: Self.spawnPoint(items[index].origin, size: size, screen: screen),
                                               size: size)
            }
            items[index].file?.update(dt: dt, surfaces: surfaces, floor: floor, minWidth: minWidth,
                                      bounds: screen.frame)
        }
        items.removeAll { $0.file?.isGone ?? false }
        if items.isEmpty && !trashing {
            targetScreen = nil
            target = nil
        }
    }

    /// 小猫下一个去踢哪个：选定了就一直是它；踢完了挑剩下里离小猫最近的（还在掉的按它会落到的地方算）
    /// - Parameter cat: 小猫现在在哪（在座位上就是座位）
    func kickTarget(surfaces: [RoamSurface], floor: RoamSurface, scale: CGFloat, from cat: CGPoint) -> RoamKickTarget? {
        // 还有没蹦出来的：等全都出来了再挑（不然先蹦出来的那个总被挑中，不一定是最近的）
        guard !items.contains(where: { $0.file == nil }) else { return nil }
        let minWidth = Self.landingWidth(size: size, scale: scale)
        var targets: [Int: RoamKickTarget] = [:]
        for item in items where !item.launched {
            guard let file = item.file, let kickTarget = file.kickTarget(surfaces: surfaces, floor: floor,
                                                                          minWidth: minWidth) else { continue }
            targets[item.id] = kickTarget
        }
        if let id = target, let locked = targets[id] { return locked }
        let surfaceY = { (id: Int) in ([floor] + surfaces).first { $0.id == id }?.y ?? floor.y }
        let candidates = targets.map { (id: $0.key, spot: CGPoint(x: $0.value.x, y: surfaceY($0.value.surfaceID))) }
        target = FileKickOrder.nearest(candidates, to: cat)
        return target.flatMap { targets[$0] }
    }

    /// 覆盖层上画的图标；小猫靠近时瑟瑟发抖
    func sprites(catX: CGFloat?, scale: CGFloat) -> [FileKickSprite] {
        items.compactMap { item in
            guard let file = item.file else { return nil }
            let nervous = catX.map { abs($0 - file.pos.x) < 150 * scale } ?? false
            return FileKickSprite(center: file.center, angle: file.displayAngle(nervous: nervous, time: time),
                                  scale: file.scale, opacity: file.opacity, size: file.size,
                                  trail: file.isFlying ? file.trail : [], icon: item.icon)
        }
    }

    /// 窗口上沿至少这么宽，文件才落得住：小猫要能站在文件任意一边踢
    private static func landingWidth(size: CGFloat, scale: CGFloat) -> CGFloat {
        2 * (RoamDirector.kickReach * scale + size / 2 + 30 * scale) + 4
    }

    /// 图标从哪儿蹦出来：原来的地方（挪进可用区域里）；不在小猫这块屏幕上、或者没有位置，就从屏幕顶上掉下来
    private static func spawnPoint(_ point: CGPoint?, size: CGFloat, screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let half = size / 2
        guard let point, screen.frame.contains(point) else {
            let spread = visible.width * 0.25
            return CGPoint(x: visible.midX + CGFloat.random(in: -spread...spread), y: visible.maxY - half)
        }
        return CGPoint(x: min(max(point.x, visible.minX + half), visible.maxX - half),
                       y: min(max(point.y, visible.minY + half), visible.maxY - half))
    }
}
