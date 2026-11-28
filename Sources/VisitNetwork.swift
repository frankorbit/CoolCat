import Foundation
import Network

// MARK: - Visit Link

/// 和一位同事之间的一条连接：一行一条 JSON 消息。回调都在主线程
final class VisitLink {
    let connection: NWConnection
    var onMessage: ((VisitMessage) -> Void)?
    /// 断了（对方关了 App、网络断了、我们自己关的）：只回调一次
    var onClose: (() -> Void)?
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.finish() }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: VisitMessage) {
        guard !closed, let data = message.encodedLine() else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// 发完最后一条再关（比如 bye、recall）
    func send(_ message: VisitMessage, thenClose: Bool) {
        guard !closed, let data = message.encodedLine() else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard thenClose else { return }
            DispatchQueue.main.async { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onMessage = nil
        let handler = onClose
        onClose = nil
        handler?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    for message in VisitMessage.drain(&self.buffer) { self.onMessage?(message) }
                }
                if isComplete || error != nil {
                    self.finish()
                } else {
                    self.receive()
                }
            }
        }
    }
}

// MARK: - Visit Network

/// 在局域网里登记自己（Bonjour `_coolcat._tcp`）、发现同事的小猫、收发串门消息。
/// 只在设置里打开「串门」时才运行；第一次运行 macOS 会弹「本地网络」授权
final class VisitNetwork {
    /// 局域网里找到的一位同事
    struct Peer: Equatable {
        /// 对方这次启动的编号
        let id: String
        /// 对方小猫顶在头上的名字
        var name: String
        let endpoint: NWEndpoint
    }

    /// 同事列表变了（主线程）
    var onPeersChanged: (([Peer]) -> Void)?
    /// 有同事连进来了（主线程）：调用方接手这条连接
    var onIncoming: ((VisitLink) -> Void)?
    /// 出问题了（没有本地网络权限、端口开不了……）：设置里显示的原因（主线程）
    var onStatusChanged: ((String?) -> Void)?
    private(set) var peers: [Peer] = []
    /// 现在的问题（nil = 一切正常，在找同事）
    private(set) var problem: String? {
        didSet { if problem != oldValue { onStatusChanged?(problem) } }
    }
    /// 这次启动的编号：认出自己，不去串自己的门
    let myID = String(UUID().uuidString.prefix(8))
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var advertisedName = ""

    var isRunning: Bool { listener != nil }

    func start(name: String) {
        guard listener == nil else {
            rename(name)
            return
        }
        advertisedName = name
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = makeService(name: name)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    let link = VisitLink(connection: connection)
                    if let onIncoming = self?.onIncoming {
                        onIncoming(link)
                    } else {
                        connection.cancel()
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async { self?.listenerChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "开不了监听：\(error.localizedDescription)"
            return
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: VisitService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.updatePeers(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.browserChanged(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        peers = []
        problem = nil
        onPeersChanged?(peers)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            // 监听坏了：放手，关掉再打开串门就会重来
            listener?.cancel()
            listener = nil
            problem = Self.describe(error)
        case .ready:
            if listener != nil, browser != nil { problem = nil }
        default:
            break
        }
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            problem = Self.describe(error)
        case .ready:
            problem = nil
        default:
            break
        }
    }

    /// 没有本地网络权限时 Bonjour 报 kDNSServiceErr_PolicyDenied（-65570）
    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65_570 {
            return "没有「本地网络」权限：在系统设置 → 隐私与安全性 → 本地网络里允许 CoolCat"
        }
        return "局域网暂时用不了：\(error.localizedDescription)"
    }

    /// 改了名字：重新登记一下，同事那边的菜单里马上就是新名字
    func rename(_ name: String) {
        guard let listener, name != advertisedName else { return }
        advertisedName = name
        listener.service = makeService(name: name)
    }

    /// 连到一位同事（去串门）
    func connect(to peer: Peer) -> VisitLink {
        let link = VisitLink(connection: NWConnection(to: peer.endpoint, using: .tcp))
        link.start()
        return link
    }

    private func makeService(name: String) -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[VisitService.nameKey] = name
        txt[VisitService.idKey] = myID
        return NWListener.Service(name: "CoolCat-\(myID)", type: VisitService.type, domain: nil, txtRecord: txt)
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        var found: [Peer] = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let id = txt[VisitService.idKey], id != myID else {
                continue
            }
            // 名字是局域网里别人登记的：清理、截断，空了就叫「同事的猫」
            let name = CatProfile.cleanName(txt[VisitService.nameKey] ?? "")
            found.append(Peer(id: id, name: name.isEmpty ? "同事的猫" : name, endpoint: result.endpoint))
        }
        found.sort { $0.name < $1.name }
        guard found != peers else { return }
        peers = found
        onPeersChanged?(peers)
    }
}
