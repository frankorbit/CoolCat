import AppKit
import QuartzCore

// MARK: - Visit Companion

/// 串门的 App 这一侧，两头都管。小猫自己决定去谁家，主人家不用点同意（「敲门 / 来吧」是两台电脑自动完成的）：
/// - 出门：敲同事的门 → 对方回来吧 → 自家猫走出屏幕边 → 告诉对方「出门了」→ 等对方说「它走了」→ 自家猫从那条边走回来
/// - 来客：有人敲门 → 回来吧（只有在开会、或者屏幕上已经挤了好几只客人时才婉拒）→ 对方出门了 →
///   屏幕边跳进来一只照着名片画的猫，头上顶着名字，先跑去跟自家猫打招呼，溜达一会儿，从屏幕边跳出去 → 告诉对方「它走了」。
///   几位同事的猫可以同时来；自家猫出门在外时也照样接待
///
/// 任何一步断了、超时了，都当作结束：自家猫回家、客人猫走掉
final class VisitCompanion {
    let network = VisitNetwork()
    /// 提示气泡
    var onNotice: ((String) -> Void)?
    /// 同事列表、网络状态变了（刷新菜单、设置）
    var onPeersChanged: (() -> Void)?
    /// 现在不方便接待客人（开会：可能在共享屏幕）
    var isInconvenient: (() -> Bool)?

    /// 出门：敲门中、往屏幕边走、在同事那边
    private enum TripState {
        case knocking
        case going
        case away
    }

    private struct Trip {
        var state: TripState
        let link: VisitLink
        let hostName: String
        var since: CFTimeInterval
    }

    private var trip: Trip?
    /// 自家猫往哪条屏幕边走出去（给漫游世界的 visitExit）；nil = 不串门 / 回来了
    private(set) var exitEdge: RoamEdge?
    var isOut: Bool { trip != nil }

    /// 来客：已经回了来吧、还没进门（等对方的猫走出它那边的屏幕）
    private struct PendingGuest {
        let link: VisitLink
        let profile: CatProfile
        let since: CFTimeInterval
    }

    private var pendingGuests: [ObjectIdentifier: PendingGuest] = [:]

    /// 正在家里的一只客人猫（每只一个窗口）
    private struct Visitor {
        /// 演示（不走网络）时是 nil
        let link: VisitLink?
        let profile: CatProfile
        let edge: RoamEdge
        let arrived: CFTimeInterval
        let window: RoamWindow
        var roam: RoamDirector
        var greetSpot: RoamSignTarget?
        var leaving = false
        /// 水平速度（屏幕点/秒）：自家猫看它跑得快就去追
        var speed: CGFloat = 0
    }

    private var visitors: [Visitor] = []
    /// 客人来了，自家猫什么时候去陪它玩、什么时候回座位
    private var playdate = PlaydateClock()
    /// 连进来的连接：自己存着，断了才放手（只靠回调里的弱引用，函数一返回连接就被释放，消息全收不到）
    private var incoming: [ObjectIdentifier: VisitLink] = [:]
    var hasVisitors: Bool { !visitors.isEmpty }

    /// 敲门多久没人应就算了
    static let knockTimeout: CFTimeInterval = 8
    /// 往屏幕边走多久还没走出去（被什么事拦住了）就算了
    static let goingTimeout: CFTimeInterval = 40
    /// 在同事那边最多待多久（对方一直没说「走了」，比如对方睡眠了）
    static let awayTimeout: CFTimeInterval = 150
    /// 客人最多待多久：到点了就请它回去（留够和自家猫玩两三轮的时间）
    static let maxStay: CFTimeInterval = 120
    /// 回了来吧之后，等对方的猫走出它那边的屏幕最多等多久
    static let enterTimeout: CFTimeInterval = 60
    /// 屏幕上最多同时几只客人猫（不是限制串门，是免得十几只挤在一块屏幕上）
    static let maxGuests = 4

    init() {
        network.onPeersChanged = { [weak self] _ in self?.onPeersChanged?() }
        network.onStatusChanged = { [weak self] _ in self?.onPeersChanged?() }
        network.onIncoming = { [weak self] link in self?.accept(link) }
    }

    var peers: [VisitNetwork.Peer] { network.peers }

    /// 设置里开关「串门」、改了名字
    func setEnabled(_ enabled: Bool, name: String) {
        if enabled {
            network.start(name: name)
        } else {
            recall()
            dismissGuests()
            incoming.values.forEach { $0.close() }
            incoming.removeAll()
            network.stop()
        }
    }

    // MARK: Going Out

    /// 去这位同事家串门（菜单里点的，或者溜达时自己想去）
    func visit(_ peer: VisitNetwork.Peer) {
        guard trip == nil else { return }
        let link = network.connect(to: peer)
        trip = Trip(state: .knocking, link: link, hostName: peer.name, since: CACurrentMediaTime())
        link.onMessage = { [weak self] message in self?.handleAsGuest(message) }
        link.onClose = { [weak self] in self?.tripEnded(notice: nil) }
        link.send(.knock(profile: .mine))
    }

    /// 自己挑一位同事去串门（溜达时自己想去）
    func visitSomeone() {
        guard let peer = peers.randomElement() else { return }
        visit(peer)
    }

    /// 叫自家猫回来（开会、agent 等你、要踢文件、开番茄钟、关了串门）：告诉对方，让它那边的猫马上走
    func recall() {
        guard let current = trip else { return }
        trip = nil
        exitEdge = nil
        current.link.onClose = nil
        if current.state == .knocking {
            current.link.close()
        } else {
            current.link.send(.recall, thenClose: true)
        }
    }

    /// 自家猫走出屏幕边了：告诉对方，对方屏幕上跳进来一只
    func catWentAway() {
        guard var current = trip, current.state == .going else { return }
        current.state = .away
        current.since = CACurrentMediaTime()
        trip = current
        current.link.send(.enter)
    }

    private func handleAsGuest(_ message: VisitMessage) {
        guard var current = trip else { return }
        switch message {
        case .welcome where current.state == .knocking:
            current.state = .going
            current.since = CACurrentMediaTime()
            trip = current
            exitEdge = Bool.random() ? .left : .right
            onNotice?("🏠 去「\(current.hostName)」家串门啦")
        case .busy:
            tripEnded(notice: "「\(current.hostName)」那边正在开会，下次再去")
        case .bye:
            tripEnded(notice: "🏠 从「\(current.hostName)」家串门回来啦")
        default:
            break
        }
    }

    /// 这趟串门结束了（对方说走了、断了、超时了）：自家猫从屏幕边走回来
    private func tripEnded(notice: String?) {
        guard let current = trip else { return }
        trip = nil
        exitEdge = nil
        current.link.onClose = nil
        current.link.close()
        if let notice { onNotice?(notice) }
    }

    // MARK: Guests

    /// 有同事连进来：存住这条连接，等它敲门
    private func accept(_ link: VisitLink) {
        let key = ObjectIdentifier(link)
        incoming[key] = link
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handleAsHost(message, from: link)
        }
        link.onClose = { [weak self, weak link] in
            guard let self else { return }
            self.incoming[key] = nil
            self.pendingGuests[key] = nil
            if let link { self.markLeaving(link) }
        }
        link.start()
    }

    private func handleAsHost(_ message: VisitMessage, from link: VisitLink) {
        let key = ObjectIdentifier(link)
        switch message {
        case .knock(let profile):
            // 不用谁点同意：只有开会（可能在共享屏幕）、或者屏幕上已经挤满客人时才婉拒
            let crowded = visitors.count + pendingGuests.count >= Self.maxGuests
            guard CatSettings.shared.visits, !crowded, !(isInconvenient?() ?? false) else {
                link.send(.busy, thenClose: true)
                return
            }
            pendingGuests[key] = PendingGuest(link: link, profile: profile, since: CACurrentMediaTime())
            link.send(.welcome)
        case .enter:
            guard let pending = pendingGuests.removeValue(forKey: key) else { return }
            admit(pending.profile, link: link)
        case .recall:
            pendingGuests[key] = nil
            markLeaving(link)
        default:
            break
        }
    }

    /// 客人猫进门：从左边或右边屏幕外跳进来
    private func admit(_ profile: CatProfile, link: VisitLink?) {
        var roam = RoamDirector()
        roam.goOutNow()
        visitors.append(Visitor(link: link, profile: profile, edge: Bool.random() ? .left : .right,
                                arrived: CACurrentMediaTime(), window: RoamWindow(), roam: roam))
    }

    /// 这位客人家里有事、或者断了：请它回去
    private func markLeaving(_ link: VisitLink) {
        for index in visitors.indices where visitors[index].link === link {
            visitors[index].leaving = true
        }
    }

    /// 关了串门：客人都请回去
    private func dismissGuests() {
        pendingGuests.values.forEach { $0.link.close() }
        pendingGuests.removeAll()
        for index in visitors.indices { visitors[index].leaving = true }
    }

    /// 演示（`--visit-demo`、设置里的「客人预览」）：不走网络，假装来了一只叫「阿橘」的大橘
    func demoVisitor() {
        guard visitors.count < Self.maxGuests else { return }
        let pet = PetLibrary.shared.pet(id: "orange-tabby")
        let profile = CatProfile(name: "阿橘", breed: pet?.name ?? "大橘",
                                 coat: (pet?.style.baseCoat ?? .orangeWhite).rawValue,
                                 eye: EyeColorTheme.warmAmber.rawValue, petID: pet?.id,
                                 accessory: CatAccessory.scarf.rawValue)
        admit(profile, link: nil)
    }
}

// MARK: - Per Frame

extension VisitCompanion {
    /// 每帧：超时检查
    func tick(now: CFTimeInterval) {
        if let current = trip {
            let waited = now - current.since
            switch current.state {
            case .knocking where waited > Self.knockTimeout:
                tripEnded(notice: "「\(current.hostName)」没开门，下次再去")
            case .going where waited > Self.goingTimeout:
                recall()
            case .away where waited > Self.awayTimeout:
                recall()
            default:
                break
            }
        }
        for (key, pending) in pendingGuests where now - pending.since > Self.enterTimeout {
            pending.link.close()
            pendingGuests[key] = nil
        }
    }

    /// 每帧推着客人猫走、摆好它们的窗口。走出屏幕了就告诉对方「它走了」
    /// - Parameters:
    ///   - host: 自家座位那块屏幕的漫游世界（地面、窗口顶、窗框、光标……客人猫和自家猫踩同一套）
    ///   - home: 自家猫在哪（客人进门先跑去它旁边打招呼）、是不是正在陪客人玩（客人们也把它当玩伴）
    ///   - onGreet: 打招呼的那一刻（让自家猫冒个气泡）
    func stepVisitors(dt: CGFloat, host: RoamWorld, home: VisitHostCat, time: CGFloat,
                      onGreet: (CatProfile) -> Void) {
        var left: [Visitor] = []
        for index in visitors.indices {
            let events = stepVisitor(index, dt: dt, host: host, home: home, time: time)
            if events.contains(.greeted) { onGreet(visitors[index].profile) }
            if events.contains(.arrivedHome) { left.append(visitors[index]) }
        }
        for gone in left {
            // 跳出屏幕了：告诉对方，它那边的猫可以回家了
            gone.link?.onClose = nil
            gone.link?.send(.bye, thenClose: true)
            gone.window.orderOut(nil)
        }
        visitors.removeAll { visitor in left.contains { $0.window === visitor.window } }
    }

    /// 现在要不要让自家猫去陪客人玩（每帧问一次）
    /// - Parameters:
    ///   - canPlay: 现在方便玩（没开会、agent 没在等你、没开番茄钟、没在踢文件、自家猫没出门）
    ///   - userBusy: 你正在打字：玩够最少的时间就回座位
    func updatePlaydate(now: CFTimeInterval, canPlay: Bool, userBusy: Bool) -> Bool {
        let hasGuest = visitors.contains { !$0.leaving && !$0.roam.isHome }
        return playdate.update(now: now, hasGuest: hasGuest, canPlay: canPlay, userBusy: userBusy)
    }

    /// 自家猫的玩伴：离它最近的那只客人猫（正要走的不算）
    func playmateForHost(near cat: CGPoint) -> RoamPlaymate? {
        let guests = visitors.filter { !$0.leaving && !$0.roam.isHome }
        guard let nearest = guests.min(by: { abs($0.roam.pos.x - cat.x) < abs($1.roam.pos.x - cat.x) }) else {
            return nil
        }
        let airborne = nearest.roam.pose == .air
        return RoamPlaymate(pos: nearest.roam.pos, surfaceID: airborne ? nil : nearest.roam.surfaceID,
                            speed: nearest.speed, homeAfter: true)
    }

    /// 推一只客人猫走一帧，交出这一帧的事件（打了招呼、跳出屏幕了）
    private func stepVisitor(_ index: Int, dt: CGFloat, host: RoamWorld, home: VisitHostCat,
                             time: CGFloat) -> [RoamEvent] {
        var current = visitors[index]
        let before = current.roam.pos
        let unit = host.scale
        let floor = host.floor
        let seatX = current.edge == .left ? floor.minX - 220 * unit : floor.maxX + 220 * unit
        if current.greetSpot == nil {
            // 好几只一起来：一只挨一只排开，不叠在一起
            let queue = visitors.prefix(index).filter { $0.edge == current.edge }.count
            current.greetSpot = VisitGreeting.spot(host: host, hostCat: home.cat, from: current.edge, queue: queue)
        }
        if CACurrentMediaTime() - current.arrived > Self.maxStay { current.leaving = true }
        var world = host
        world.seat = CGPoint(x: seatX, y: floor.y)
        world.homeRect = CGRect(x: seatX, y: floor.y, width: 1, height: 1)
        world.keyIdle = 1000
        world.userActive = false
        world.mustStayHome = current.leaving
        world.wanderAllowed = true
        world.needsAttention = false
        world.signTarget = nil
        world.focusSpot = nil
        world.kickTarget = nil
        world.visitExit = nil
        world.knockAllowed = false
        world.snowySurfaces = []
        world.greetSpot = current.greetSpot
        // 自家猫在陪客人玩：客人也把它当玩伴（正要走的客人不玩了）
        world.playmate = current.leaving ? nil : home.playmate
        let events = current.roam.update(dt: dt, world: world)
        current.speed = dt > 0 ? (current.roam.pos.x - before.x) / dt : 0
        visitors[index] = current
        placeWindow(of: current, petScale: CatSettings.shared.scale, time: time)
        return events
    }

    private func placeWindow(of current: Visitor, petScale: CGFloat, time: CGFloat) {
        let roam = current.roam
        let window = current.window
        guard !roam.isHome else {
            if window.isVisible { window.orderOut(nil) }
            return
        }
        let anchor = roam.climbWallOnRight.map { CatRenderer.climbAnchor(wallOnRight: $0) } ?? CatRenderer.walkerFeet
        window.place(feet: roam.pos, scale: petScale, anchor: anchor)
        window.walkerView.visitor = current.profile
        window.walkerView.nameTag = current.profile.displayName
        window.walkerView.pose = CatRenderer.WalkerPose(
            pose: roam.pose, phase: roam.gaitPhase, facing: roam.facing, air: roam.airProgress, time: time,
            blink: time.truncatingRemainder(dividingBy: 3.7) < 0.13, peekEdge: roam.peekEdge,
            peekReveal: roam.peekReveal,
            sink: roam.sinkDepth, curl: roam.napCurl, asleep: roam.napAsleep, hunting: roam.isPlaying,
            shake: roam.shakeProgress, tap: roam.tapProgress, runBlend: roam.runBlend, moveBlend: roam.moveBlend,
            crouchProgress: roam.crouchProgress, landProgress: roam.landProgress, skidding: roam.isSkidding,
            turnScale: roam.turnScale
        )
        window.walkerView.clip = Self.clip(for: roam, frame: window.frame, petScale: petScale)
        window.walkerView.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// 屏幕边换算到画布坐标：跳进来、跳出去时屏幕外的部分不画
    private static func clip(for roam: RoamDirector, frame: CGRect,
                             petScale: CGFloat) -> (edge: RoamEdge, at: CGFloat)? {
        guard let clip = roam.clipEdge else { return nil }
        let unit = petScale * CatRenderer.walkerArtScale
        switch clip.edge {
        case .left, .right: return (clip.edge, (clip.at - frame.minX) / unit)
        case .bottom: return (.bottom, CatRenderer.walkerCanvas.height - (clip.at - frame.minY) / unit)
        }
    }
}
