import AppKit
import QuartzCore
import QuickLookThumbnailing

// MARK: - File Kick Companion

/// 「小猫踢飞（移到废纸篓）」的 App 这一侧：接 Finder 右键服务（和菜单里的「小猫踢飞文件…」），
/// 先把文件移进废纸篓，同时在你右键的地方蹦出它的图标；每帧推进图标的物理、告诉漫游小猫去哪儿踢；
/// 踢中时让图标转着飞出屏幕。踢之前按 Esc 可以取消（文件从废纸篓放回原处）。
///
/// 只移进废纸篓，绝不永久删除；系统目录、主目录、磁盘根目录、小猫自己都不让踢
final class FileKickCompanion: NSObject {
    /// 提示气泡（踢进去了、没踢动、取消了）
    var onNotice: ((String) -> Void)?
    /// 小猫藏起来了：问调用方能不能踢（藏着就不踢，免得文件凭空消失）
    var canKick: (() -> Bool)?

    private(set) var file: KickedFile?
    /// 文件在哪块屏幕上（你右键的地方）：小猫这一趟去那块屏幕；nil = 小猫自己那块（菜单里选的文件）
    private(set) var targetScreen: NSScreen?
    private(set) var icon: NSImage?
    /// 这一脚要踢的文件：原来的位置 → 废纸篓里的位置（取消时放回去）
    private var trashed: [(original: URL, inTrash: URL?)] = []
    /// 移进废纸篓之后、图标出现之前：等下一帧有屏幕信息再放出来
    private var pendingSpawn: (point: CGPoint?, size: CGFloat)?
    /// 正在移进废纸篓（后台）
    private var trashing = false
    private var time: CGFloat = 0

    /// 最近一次右键（或 Control + 左键）的位置和时刻：Finder 服务里拿不到图标位置，就从这里蹦出来
    private var lastContextClick: (point: CGPoint, at: CFTimeInterval)?
    private var clickMonitor: Any?

    /// 图标边长（侧身小猫画布单位，乘体型缩放）：比猫身子略小一点
    static let iconUnits: CGFloat = 46
    /// 右键多久之内调起的服务，算是从右键的地方蹦出来
    static let contextClickMaxAge: CFTimeInterval = 15

    var isBusy: Bool { file != nil || trashing || pendingSpawn != nil }

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

    /// 踢这些文件。point = 图标从哪儿蹦出来（屏幕坐标）；nil = 从屏幕顶上掉下来（菜单里选的文件）
    func request(_ urls: [URL], at point: CGPoint?) {
        guard !isBusy else {
            onNotice?("小猫正忙着踢上一个呢")
            return
        }
        guard canKick?() ?? true else {
            onNotice?("小猫藏起来了，先显示小猫再让它踢吧")
            return
        }
        let targets: [URL]
        switch FileKickRules.validate(urls) {
        case .failure(let reason):
            onNotice?(reason.message)
            return
        case .success(let valid):
            targets = valid
        }
        targetScreen = point.flatMap { spot in NSScreen.screens.first { $0.frame.contains(spot) } }
        trashing = true
        let size = Self.iconUnits * CatSettings.shared.scale * CatRenderer.walkerArtScale
        // 先照 Finder 的样子拿图标（文件还在原处才拿得到），再移进废纸篓
        Self.finderIcon(for: targets, size: size) { [weak self] image in
            self?.icon = image
            self?.moveToTrash(targets, spawnAt: point, size: size)
        }
    }

    /// 和 Finder 里看到的一样的图标：内容缩略图（文本前几行、图片 / PDF 预览，带页角和边框），没有就是类型图标。
    /// 多选时用系统的「一叠文件」图标。最多等 0.8 秒，等不到就用类型图标
    private static func finderIcon(for urls: [URL], size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let fallback = NSWorkspace.shared.icon(forFiles: urls.map(\.path))
        guard urls.count == 1, let url = urls.first else {
            completion(fallback)
            return
        }
        var finished = false
        let finish = { (image: NSImage?) in
            guard !finished else { return }
            finished = true
            completion(image)
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .all)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            DispatchQueue.main.async { finish(thumbnail?.nsImage ?? fallback) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish(fallback) }
    }

    /// 移进废纸篓放到后台（网络盘可能要一会儿）；移完了图标才蹦出来：原来的图标消失、这个蹦出来，像它自己跳出来的
    private func moveToTrash(_ targets: [URL], spawnAt point: CGPoint?, size: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async {
            var moved: [(original: URL, inTrash: URL?)] = []
            var failure: String?
            var finderDenied = false
            for url in targets {
                // 先请 Finder 删：Finder 自己删的，原图标马上消失；自己删的话 Finder 要两三秒才发现，
                // 这期间原图标还在，看起来像有两个图标
                switch Self.trashViaFinder(url) {
                case .success(let inTrash):
                    moved.append((url, inTrash))
                    continue
                case .failure(let reason):
                    finderDenied = finderDenied || reason == .notAuthorized
                }
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                    moved.append((url, resulting as URL?))
                } catch {
                    failure = "没踢动「\(url.lastPathComponent)」：\(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.trashing = false
                self.trashed = moved
                if finderDenied && failure == nil {
                    self.onNotice?("在「隐私与安全性 → 自动化」里允许 CoolCat 控制 Finder，原图标就会马上消失")
                }
                if let failure {
                    // 一个都没进去：不演了；进去了几个：照样踢（进去了的就是踢走了的）
                    self.onNotice?(failure)
                    guard !moved.isEmpty else {
                        self.icon = nil
                        self.targetScreen = nil
                        return
                    }
                }
                self.pendingSpawn = (point, size)
            }
        }
    }

    private enum FinderTrashFailure: Error, Equatable {
        /// 你没允许 CoolCat 控制 Finder（-1743）
        case notAuthorized
        case failed
    }

    /// 请 Finder 把文件移到废纸篓（和 ⌘⌫ 一样，能「放回原处」），返回它在废纸篓里的位置。
    /// 用 osascript 子进程发，不卡主线程；第一次会弹「CoolCat 想控制 Finder」的授权
    private static func trashViaFinder(_ url: URL) -> Result<URL?, FinderTrashFailure> {
        let script = """
        on run argv
            tell application "Finder"
                set trashed to delete (POSIX file (item 1 of argv) as alias)
                return POSIX path of (trashed as alias)
            end tell
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(.failed)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(message.contains("-1743") ? .notAuthorized : .failed)
        }
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(path.isEmpty ? nil : URL(fileURLWithPath: path))
    }

    /// Esc：还没踢出去就不踢了，把文件从废纸篓放回原处
    func cancel() {
        guard var current = file, current.canCancel else { return }
        current.cancel()
        file = current
        let items = trashed
        trashed = []
        var failed: [String] = []
        for item in items {
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
        onNotice?(failed.isEmpty ? "好吧，不踢了，放回去啦" : "「\(failed[0])」没放回去，去废纸篓里「放回原处」吧")
    }

    // MARK: Roam Hooks

    /// 小猫一脚踢中：图标往那个角度飞出去
    func kicked(angle: CGFloat, dir: CGFloat) {
        guard var current = file, current.canCancel else { return }
        current.kick(angle: angle, dir: dir, speed: CGFloat.random(in: 1500...1900), spin: CGFloat.random(in: 9...14))
        file = current
        let count = trashed.count
        let name = trashed.first?.original.lastPathComponent ?? ""
        trashed = []
        onNotice?(count == 1 ? "🗑️ 把「\(name)」踢进废纸篓啦" : "🗑️ 把 \(count) 个文件踢进废纸篓啦")
    }

    /// 文件落在小猫上不去的窗口顶上：让它掉到屏幕底
    func targetUnreachable() {
        file?.dropToFloor()
    }

    // MARK: Per Frame

    /// 每帧：放出等着的图标、推进物理；飞出屏幕就收工
    /// - Parameter screen: 小猫这一帧在哪块屏幕上活动（surfaces、floor 都是这块屏幕的）
    func update(dt: CGFloat, surfaces: [RoamSurface], floor: RoamSurface, screen: NSScreen, scale: CGFloat) {
        time += dt
        // 文件在另一块屏幕上、小猫还没回座位换过去：图标先别蹦（这一帧的窗口、地面都是另一块屏幕的）
        if let spawn = pendingSpawn, targetScreen.map({ $0 == screen }) ?? true {
            pendingSpawn = nil
            file = KickedFile(center: Self.spawnPoint(spawn.point, size: spawn.size, screen: screen), size: spawn.size)
        }
        guard var current = file else { return }
        current.update(dt: dt, surfaces: surfaces, floor: floor,
                       minWidth: Self.landingWidth(size: current.size, scale: scale), bounds: screen.frame)
        file = current.isGone ? nil : current
        if file == nil {
            icon = nil
            targetScreen = nil
        }
    }

    /// 小猫该去哪儿踢（没有要踢的、已经踢出去了：nil）
    func kickTarget(surfaces: [RoamSurface], floor: RoamSurface, scale: CGFloat) -> RoamKickTarget? {
        guard let file else { return nil }
        return file.kickTarget(surfaces: surfaces, floor: floor,
                               minWidth: Self.landingWidth(size: file.size, scale: scale))
    }

    /// 覆盖层上画的图标；小猫靠近时瑟瑟发抖
    func sprite(catX: CGFloat?, scale: CGFloat) -> FileKickSprite? {
        guard let file else { return nil }
        let nervous = catX.map { abs($0 - file.pos.x) < 150 * scale } ?? false
        return FileKickSprite(center: file.center, angle: file.displayAngle(nervous: nervous, time: time),
                              scale: file.scale, opacity: file.opacity, size: file.size,
                              trail: file.isFlying ? file.trail : [])
    }

    /// 窗口上沿至少这么宽，文件才落得住：小猫要能站在文件任意一边踢
    private static func landingWidth(size: CGFloat, scale: CGFloat) -> CGFloat {
        2 * (RoamDirector.kickReach * scale + size / 2 + 30 * scale) + 4
    }

    /// 图标从哪儿蹦出来：右键的地方（挪进可用区域里）；不在小猫这块屏幕上、或者没有位置，就从屏幕顶上掉下来
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
