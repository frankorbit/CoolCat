import AppKit
import Foundation

// MARK: - Public Status Model

/// 接入的 AI 编程助手。rawValue 用于会话键和持久化，别改。
enum CodingAgent: String, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

enum ClaudeWaitKind: Equatable {
    /// 弹出了权限确认（要你点"允许"）
    case permission
    /// 闲置等你回复 / 需要你回答问题
    case input
}

/// 多个 Claude Code 会话聚合后的、小猫要表演的状态。
enum ClaudeStatus: Equatable {
    case idle
    case working(tool: String?, sessions: Int)
    case waiting(ClaudeWaitKind)
    case done

    var isActive: Bool { self != .idle }
}

// MARK: - Hook Relay (runs inside the short-lived `CoolCat --claude-hook` process)

/// Claude Code hook → 运行中的小猫。
///
/// Claude Code 每次触发 hook 都会启动 `CoolCat --claude-hook`，把事件 JSON 写进 stdin。
/// 这里只挑出无隐私的字段（事件名、会话 ID、工具名、项目目录名），通过 DistributedNotification
/// 广播给常驻的小猫进程后立刻退出。小猫没运行时广播无人接收，不影响 Claude Code。
///
/// 注意：UserPromptSubmit 的 stdout 会被注入到对话上下文，所以这里绝不能打印任何东西。
enum ClaudeHookRelay {
    static let notificationName = Notification.Name("ai.today.coolcat.claude-event")
    static let argument = "--claude-hook"
    /// Codex 的 hooks.json 和 Claude Code 同格式，复用同一个中继，只多带一个 agent 字段
    static let codexArgument = "--codex-hook"

    static func argument(for agent: CodingAgent) -> String {
        agent == .codex ? codexArgument : argument
    }

    static func run(agent: CodingAgent = .claude) -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let event = json["hook_event_name"] as? String {
            var info: [String: String] = ["event": event, "agent": agent.rawValue]
            if let session = json["session_id"] as? String { info["session"] = session }
            if let tool = json["tool_name"] as? String { info["tool"] = tool }
            if let cwd = json["cwd"] as? String { info["project"] = (cwd as NSString).lastPathComponent }
            if let type = json["notification_type"] as? String {
                info["notificationType"] = type
            } else if let message = json["message"] as? String {
                // 旧版本没有 notification_type，按文案兜底判断
                if message.localizedCaseInsensitiveContains("permission") {
                    info["notificationType"] = "permission_prompt"
                } else if message.localizedCaseInsensitiveContains("waiting for your input") {
                    info["notificationType"] = "idle_prompt"
                } else {
                    info["notificationType"] = "other"
                }
            }
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: nil, userInfo: info, deliverImmediately: true
            )
        }
        exit(0)
    }
}

// MARK: - Session Tracker (runs inside the cat app)

/// 气泡里的一行：某个会话（项目）当前在干什么。
struct ClaudeSessionLine: Equatable {
    enum Kind: Equatable { case working, waiting, done }
    let project: String
    let detail: String
    let kind: Kind
    /// 本轮提示词开始到现在的秒数（仅 working）
    let elapsed: CFTimeInterval?
    /// 来自哪个助手（气泡里用不同的转圈图标区分）
    var agent: CodingAgent = .claude
}

/// 按 session_id 维护每个 Claude Code 会话的阶段，并聚合成一个 `ClaudeStatus` 和逐会话的 `lines`。
/// 只在主线程使用。
final class ClaudeActivityTracker {
    static let shared = ClaudeActivityTracker()

    private enum Phase: Equatable {
        case idle
        case working
        case waiting(ClaudeWaitKind, since: CFTimeInterval)
        case done(at: CFTimeInterval)
    }

    private struct Session {
        var phase: Phase
        var updatedAt: CFTimeInterval
        var project: String
        var agent: CodingAgent = .claude
        var promptStartedAt: CFTimeInterval?
        /// 并行工具调用：工具名 -> 未结束的次数。PostToolUse 只减自己那一个，不清空别人
        var inFlight: [String: Int] = [:]
        /// 最近开始的、仍在跑的工具
        var currentTool: String?
        /// 最近一次工具事件；Read/Edit 只跑几十毫秒，靠它让标签至少停留一会儿
        var lastTool: (name: String, at: CFTimeInterval)?
        /// 权限弹窗对应的工具（发 Notification 前最近一次 PreToolUse）。只有它结束才算批准完成，
        /// 并行子代理的其他工具事件不能把等待态冲掉
        var waitingTool: String?
        /// 最近一次 PreToolUse 的工具名
        var lastPreTool: String?
        /// 状态来自"猜测用户已回应"（按键/点击），而非真实 hook 事件：用短超时兜底
        var assumed = false

        var hasToolInFlight: Bool { !inFlight.isEmpty }
    }

    private var sessions: [String: Session] = [:]
    /// 庆祝动画持续时长
    private let doneDuration: CFTimeInterval = 3.2
    /// 工具标签在工具结束后继续显示的时长
    private let toolLabelLinger: CFTimeInterval = 2.5
    /// 收不到 Stop/SessionEnd（进程被杀等）时的兜底：没有工具在跑、10 分钟无事件 → 视为结束。
    /// 有工具在跑（长构建）则放宽到 60 分钟
    private let staleIdleTimeout: CFTimeInterval = 10 * 60
    private let staleToolTimeout: CFTimeInterval = 60 * 60

    private(set) var lastEventTime: CFTimeInterval = 0
    /// 用户在终端里按 Esc：Esc 打断不会触发 Stop，用它探测"已被打断"（只针对一个会话，判定后清除）
    private var escapeProbe: (session: String, at: CFTimeInterval)?
    private var lastNavigationAt: CFTimeInterval?
    /// 猜测状态（按键/点击推断）的兜底超时
    private let assumedTimeout: CFTimeInterval = 10 * 60
    private let interruptProbeWindow: CFTimeInterval = 3

    private init() {}

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleEvent(_:)),
            name: ClaudeHookRelay.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleEvent(_ note: Notification) {
        guard let info = note.userInfo as? [String: String], let event = info["event"] else { return }
        let agent = info["agent"].flatMap(CodingAgent.init(rawValue:)) ?? .claude
        apply(event: event, session: info["session"] ?? "default", tool: info["tool"],
              notificationType: info["notificationType"], project: info["project"], agent: agent,
              now: CACurrentMediaTime())
        noteEventReceived(from: agent)
    }

    /// 某个助手最近一次真实事件的时间（墙上时间，持久化）：用来判断 hook 是否已经真正跑通
    /// （Codex 新 hook 需要用户在 /hooks 里信任后才会运行，写进文件不代表已生效）
    static func lastEventDate(for agent: CodingAgent) -> Date? {
        UserDefaults.standard.object(forKey: "CoolCat.LastHookEvent.\(agent.rawValue)") as? Date
    }

    private func noteEventReceived(from agent: CodingAgent) {
        let key = "CoolCat.LastHookEvent.\(agent.rawValue)"
        // 每分钟最多写一次，别每个工具事件都写盘
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 60 { return }
        UserDefaults.standard.set(Date(), forKey: key)
    }

    /// 单独暴露出来便于预览/测试直接喂事件。
    /// - Parameter agent: 不同助手的会话 ID 可能撞车，内部按「助手:会话」区分
    func apply(event: String, session rawSession: String, tool: String?, notificationType: String?,
               project: String? = nil, agent: CodingAgent = .claude, now: CFTimeInterval) {
        lastEventTime = now
        let session = agent == .claude ? rawSession : agent.rawValue + ":" + rawSession
        if event == "SessionEnd" {
            sessions[session] = nil
            return
        }
        var state = sessions[session] ?? Session(phase: .idle, updatedAt: now, project: project ?? agent.displayName, agent: agent)
        if let project, !project.isEmpty { state.project = project }

        var isWaiting = false
        if case .waiting = state.phase { isWaiting = true }

        switch event {
        case "SessionStart":
            // 自动压缩（source=compact）会在一轮中途触发 SessionStart，工作/等待中时忽略
            if state.phase == .working || isWaiting { return }
            state.phase = .idle
        case "UserPromptSubmit":
            state.phase = .working
            state.promptStartedAt = now
            state.inFlight.removeAll()
            state.currentTool = nil
            state.lastTool = nil
            state.waitingTool = nil
        case "PreToolUse":
            let name = tool ?? "工具"
            // 等批准期间其他（子代理的）工具照常计数，但不解除等待
            if !isWaiting { state.phase = .working }
            if state.promptStartedAt == nil { state.promptStartedAt = now }
            state.inFlight[name, default: 0] += 1
            state.currentTool = name
            state.lastTool = (name, now)
            state.lastPreTool = name
        case "PostToolUse", "PostToolUseFailure":
            let name = tool ?? "工具"
            if let count = state.inFlight[name] {
                state.inFlight[name] = count > 1 ? count - 1 : nil
            }
            if state.currentTool == name && state.inFlight[name] == nil {
                // 当前显示的工具结束了，退回到仍在跑的其他工具（如果有）
                state.currentTool = state.inFlight.keys.sorted().first
            }
            state.lastTool = (name, now)
            if isWaiting {
                // 只有被卡住的那个工具结束，才说明权限已批准
                if state.waitingTool == nil || state.waitingTool == name {
                    state.phase = .working
                    state.waitingTool = nil
                }
            } else if state.phase == .idle {
                state.phase = .working
            }
        case "Notification":
            // 只认这三类；auth_success 等其他通知不该让小猫喊人
            switch notificationType {
            case "permission_prompt":
                state.phase = .waiting(.permission, since: now)
                state.waitingTool = state.lastPreTool
            case "idle_prompt", "elicitation_dialog":
                state.phase = .waiting(.input, since: now)
            default:
                return
            }
        case "PermissionRequest":
            // Codex：要你批准某个工具调用（自带工具名，比按"最近一次 PreToolUse"猜更准）
            state.phase = .waiting(.permission, since: now)
            state.waitingTool = tool ?? state.lastPreTool
        case "Interrupt":
            // Codex：用户按 Esc 打断，这一轮不会再有 Stop
            resetToIdle(&state)
        case "Stop":
            state.phase = .done(at: now)
            state.inFlight.removeAll()
            state.currentTool = nil
            state.promptStartedAt = nil
            state.waitingTool = nil
        default:
            return
        }
        state.assumed = false // 真实事件到达，不再是猜测状态
        state.updatedAt = now
        sessions[session] = state
    }

    enum UserResponse {
        /// 回车 / 1 / 2 / 点击：大概率批准
        case approve
        /// Esc / 3：拒绝或打断
        case reject
        /// 用方向键挑过选项再回车：不知道选了什么
        case uncertain
    }

    /// 用户回应了弹窗（调用方需确保前台是终端/IDE 且没按修饰键）。只作用于最近开始等待的那个会话：
    /// - 批准：权限 → 回到工作态（工具可能要跑很久，不能一直喊）
    /// - 拒绝：Claude 不会再发 Stop，直接回空闲
    /// - 不确定：先回工作态，但标记为猜测，10 分钟没真实事件就收起
    /// - "等回复"被回应：回空闲
    func acknowledgeWaiting(userActionAt time: CFTimeInterval, response: UserResponse) {
        var target: (id: String, since: CFTimeInterval)?
        for (id, state) in sessions {
            guard case let .waiting(_, since) = state.phase, time - since > 0.6 else { continue }
            if target == nil || since > target!.since { target = (id, since) }
        }
        guard let id = target?.id, var state = sessions[id], case let .waiting(kind, since) = state.phase else { return }
        var response = response
        if response == .approve, let nav = lastNavigationAt, nav > since { response = .uncertain }
        if kind == .permission && response != .reject {
            state.phase = .working
            state.assumed = (response == .uncertain)
        } else {
            resetToIdle(&state)
        }
        state.waitingTool = nil
        state.updatedAt = time
        sessions[id] = state
    }

    /// 等待期间用方向键挑过选项：之后的回车只能算"不确定"
    func noteSelectionNavigation(at time: CFTimeInterval) {
        lastNavigationAt = time
    }

    /// 终端里按了 Esc：只针对最近活跃的那个工作中会话，3 秒内它没有新事件就判定为被打断。
    func userPressedEscape(at time: CFTimeInterval) {
        let candidate = sessions
            .filter { $0.value.phase == .working }
            .max { $0.value.updatedAt < $1.value.updatedAt }
        escapeProbe = candidate.map { (session: $0.key, at: time) }
    }

    private func resetToIdle(_ state: inout Session) {
        state.phase = .idle
        state.inFlight.removeAll()
        state.currentTool = nil
        state.promptStartedAt = nil
        state.waitingTool = nil
        state.assumed = false
    }

    var hasUnacknowledgedWaiting: Bool {
        sessions.values.contains { if case .waiting = $0.phase { return true } else { return false } }
    }

    /// 过期清理：每帧调用 status/lines 前先做一遍
    private func expire(now: CFTimeInterval) {
        for (id, state) in sessions {
            switch state.phase {
            case .waiting(let kind, let since):
                // "等你回复"5 分钟没人理就收起，人走开了别一直喊；权限请求一直保留
                if kind == .input && now - since > 300 { sessions[id]?.phase = .idle }
            case .working:
                var interrupted = false
                if let probe = escapeProbe, probe.session == id, now - probe.at > interruptProbeWindow {
                    interrupted = state.updatedAt < probe.at
                    escapeProbe = nil // 只判定一次
                }
                let timeout = state.assumed ? assumedTimeout : (state.hasToolInFlight ? staleToolTimeout : staleIdleTimeout)
                if interrupted || now - state.updatedAt >= timeout {
                    if var updated = sessions[id] {
                        resetToIdle(&updated)
                        sessions[id] = updated
                    }
                }
            case .done(let at):
                if now - at >= doneDuration { sessions[id]?.phase = .idle }
            case .idle:
                break
            }
        }
    }

    /// 给小猫做动作用的聚合状态：等你 > 干活 > 搞定 > 空闲
    func status(now: CFTimeInterval, agents: Set<CodingAgent> = Set(CodingAgent.allCases)) -> ClaudeStatus {
        expire(now: now)
        var waitingKind: ClaudeWaitKind?
        var working: [Session] = []
        var anyDone = false
        for state in sessions.values where agents.contains(state.agent) {
            switch state.phase {
            case .waiting(let kind, _):
                if waitingKind != .permission { waitingKind = kind }
            case .working:
                working.append(state)
            case .done:
                anyDone = true
            case .idle:
                break
            }
        }
        if let kind = waitingKind { return .waiting(kind) }
        if !working.isEmpty {
            let latest = working.max { $0.updatedAt < $1.updatedAt }
            return .working(tool: latest.flatMap { toolName(for: $0, now: now) }, sessions: working.count)
        }
        return anyDone ? .done : .idle
    }

    /// 给气泡用的逐会话明细：等你的排最前，其次按开始时间
    func lines(now: CFTimeInterval, agents: Set<CodingAgent> = Set(CodingAgent.allCases)) -> [ClaudeSessionLine] {
        expire(now: now)
        var result: [(order: Int, start: CFTimeInterval, line: ClaudeSessionLine)] = []
        for state in sessions.values where agents.contains(state.agent) {
            switch state.phase {
            case .waiting(let kind, let since):
                let detail = kind == .permission ? "等你批准" : "等你回复"
                result.append((0, since, ClaudeSessionLine(project: state.project, detail: detail, kind: .waiting,
                                                           elapsed: nil, agent: state.agent)))
            case .working:
                let start = state.promptStartedAt ?? state.updatedAt
                let detail = Self.label(forTool: toolName(for: state, now: now))
                result.append((1, start, ClaudeSessionLine(project: state.project, detail: detail, kind: .working,
                                                           elapsed: now - start, agent: state.agent)))
            case .done(let at):
                result.append((2, at, ClaudeSessionLine(project: state.project, detail: "搞定", kind: .done,
                                                        elapsed: nil, agent: state.agent)))
            case .idle:
                break
            }
        }
        return result.sorted { ($0.order, $0.start) < ($1.order, $1.start) }.map(\.line)
    }

    /// 正在跑的工具优先；刚结束的工具标签再停留 2.5 秒；否则视为在思考
    private func toolName(for state: Session, now: CFTimeInterval) -> String? {
        if let current = state.currentTool { return current }
        if let last = state.lastTool, now - last.at < toolLabelLinger { return last.name }
        return nil
    }

    /// 工具名 → 小猫气泡里的中文动作
    static func label(forTool tool: String?) -> String {
        guard let tool else { return "思考中" }
        switch tool {
        case "Bash", "BashOutput", "KillShell", "KillBash", "shell", "exec_command", "unified_exec": return "跑命令"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return "写代码"
        case "Read": return "读代码"
        case "Grep", "Glob", "LS": return "翻文件"
        case "WebFetch", "WebSearch": return "上网查"
        case "Task", "Agent": return "派小弟"
        case "TodoWrite": return "列计划"
        case "AskUserQuestion": return "有问题问你"
        default:
            if tool.hasPrefix("mcp__") {
                // mcp__server__tool → 显示 server 名
                let parts = tool.components(separatedBy: "__")
                return parts.count >= 2 ? "用 \(parts[1])" : "用工具"
            }
            return tool
        }
    }

    /// "12s" / "3m" / "1h05m"
    static func formatElapsed(_ seconds: CFTimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
    }
}


// MARK: - Hook Installer (~/.claude/settings.json, ~/.codex/hooks.json)

enum HookInstallState: Equatable {
    case notInstalled
    case installed
    /// 已安装，但指向的 CoolCat 路径和当前运行的不一致（App 被挪过位置），或事件列表变了
    case outdated
}

/// 把 CoolCat 的 hook 写进（或移出）某个助手的 hook 配置文件。Claude Code 和 Codex 的格式相同：
/// `{ "hooks": { 事件名: [ { "matcher": "*", "hooks": [ { "type": "command", "command": ... } ] } ] } }`
///
/// - 只增删 command 里带本助手中继参数的条目，其他 hook 和配置原样保留。
/// - 第一次修改前备份为 `<文件>.coolcat-backup`。
/// - 文件不是合法 JSON（例如手写了注释）时拒绝修改，交给用户处理。
struct AgentHookInstaller {
    enum InstallError: LocalizedError {
        case unreadableSettings(path: String, detail: String)
        case writeFailed(path: String, detail: String)
        case translocated
        case unexpectedShape(path: String, detail: String)

        var errorDescription: String? {
            switch self {
            case let .unreadableSettings(path, detail): return "无法解析 \(path)：\(detail)"
            case let .writeFailed(path, detail): return "写入 \(path) 失败：\(detail)"
            case .translocated: return "CoolCat 正在 macOS 的临时隔离目录里运行，路径重启后会失效。请先把 CoolCat.app 拖进「应用程序」文件夹再打开。"
            case let .unexpectedShape(path, detail): return "\(path) 里的 hooks 格式不符合预期（\(detail)），为避免覆盖你的配置，已放弃修改。"
            }
        }
    }

    let agent: CodingAgent
    let settingsURL: URL
    /// 给用户看的路径（~ 开头）
    let displayPath: String
    let events: [String]
    /// 这些事件支持按工具名匹配，需要 matcher
    let toolEvents: Set<String>
    /// 有些事件有更短的超时上限（Codex 的 SessionEnd / Interrupt 最多 3 秒）
    let timeouts: [String: Int]
    /// Codex 设置页用它当 hook 标题（不写就只显示「Hook 1」，用户认不出是谁的）
    var statusMessage: String?

    static let claude = AgentHookInstaller(
        agent: .claude,
        settingsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        displayPath: "~/.claude/settings.json",
        // PostToolUseFailure：工具失败时不发 PostToolUse，漏掉它会让工具计数一直挂着
        events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                 "Notification", "Stop", "SessionEnd"],
        toolEvents: ["PreToolUse", "PostToolUse", "PostToolUseFailure"],
        timeouts: [:]
    )

    static let codex = AgentHookInstaller(
        agent: .codex,
        settingsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json"),
        displayPath: "~/.codex/hooks.json",
        // PermissionRequest = 等你批准；Interrupt = 按 Esc 打断（不会再有 Stop）
        events: ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                 "Stop", "Interrupt", "SessionEnd"],
        toolEvents: ["PreToolUse", "PermissionRequest", "PostToolUse"],
        timeouts: ["SessionEnd": 2, "Interrupt": 2],
        statusMessage: "CoolCat 桌面小猫"
    )

    static func installer(for agent: CodingAgent) -> AgentHookInstaller {
        agent == .codex ? codex : claude
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    /// 从"下载"等目录直接双击运行时，系统会把 App 随机挪进 AppTranslocation 只读目录，这个路径重启就失效
    static var isTranslocated: Bool {
        executablePath.contains("/AppTranslocation/")
    }

    var relayArgument: String { ClaudeHookRelay.argument(for: agent) }

    /// App 被移走/删除后不能让助手每个事件都报 127：可执行文件不存在时吞掉 stdin 并静默退出 0
    var hookCommand: String {
        let quoted = Self.shellQuote(Self.executablePath)
        return "[ -x \(quoted) ] && exec \(quoted) \(relayArgument); cat >/dev/null; exit 0"
    }

    /// 这个助手是否装在这台机器上（有配置目录）
    var isAgentPresent: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    func state() -> HookInstallState {
        guard let root = try? loadSettings(settingsURL),
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        func ourHandlers(_ event: String) -> [[String: Any]] {
            ((hooks[event] as? [[String: Any]]) ?? [])
                .compactMap { $0["hooks"] as? [[String: Any]] }
                .flatMap { $0 }
                .filter { isOurCommand($0["command"] as? String ?? "") }
        }
        let all = hooks.keys.flatMap(ourHandlers)
        if all.isEmpty { return .notInstalled }
        // 路径变了、新版本多了要监听的事件、或标题（statusMessage）变了，都需要重写
        let complete = events.allSatisfy { !ourHandlers($0).isEmpty }
        let current = all.allSatisfy {
            ($0["command"] as? String) == hookCommand && ($0["statusMessage"] as? String) == statusMessage
        }
        return (complete && current) ? .installed : .outdated
    }

    func install() throws {
        guard !Self.isTranslocated else { throw InstallError.translocated }
        try mutateSettings { root in
            var hooks = removingOurHooks(from: try validatedHooks(root))
            for event in events {
                var handler: [String: Any] = ["type": "command", "command": hookCommand, "timeout": timeouts[event] ?? 5]
                if let statusMessage { handler["statusMessage"] = statusMessage }
                var group: [String: Any] = ["hooks": [handler]]
                if toolEvents.contains(event) { group["matcher"] = "*" }
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(group)
                hooks[event] = groups
            }
            root["hooks"] = hooks
        }
    }

    func uninstall() throws {
        try mutateSettings { root in
            guard root["hooks"] != nil else { return }
            let cleaned = removingOurHooks(from: try validatedHooks(root))
            root["hooks"] = cleaned.isEmpty ? nil : cleaned
        }
    }

    /// 启动时调用：已安装但路径指向别处（App 被挪过）时自动改成当前路径。失败静默，设置面板里仍会提示。
    func repairIfOutdated() {
        guard !Self.isTranslocated, state() == .outdated else { return }
        try? install()
    }

    // MARK: Helpers

    /// hooks 必须是 { 事件名: [对象] }；形状不对就拒绝修改，避免覆盖用户手写的配置
    private func validatedHooks(_ root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else {
            throw InstallError.unexpectedShape(path: displayPath, detail: "hooks 不是对象")
        }
        for event in events {
            if let value = hooks[event], !(value is [[String: Any]]) {
                throw InstallError.unexpectedShape(path: displayPath, detail: "\(event) 不是数组")
            }
        }
        return hooks
    }

    /// 读-改-写：解析软链接写到真实文件；写之前比对修改时间，期间被别人（例如助手自己）改过就重来
    private func mutateSettings(_ body: (inout [String: Any]) throws -> Void) throws {
        let target = settingsURL.resolvingSymlinksInPath()
        for _ in 0..<3 {
            let before = Self.modificationDate(target)
            var root = try loadSettings(target)
            try body(&root)
            guard Self.modificationDate(target) == before else { continue }
            try save(root, to: target)
            return
        }
        throw InstallError.writeFailed(path: displayPath, detail: "文件在修改过程中被其他程序反复改动，请稍后重试")
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func isOurCommand(_ command: String) -> Bool {
        // 也认改名前的 KuroCat hook，这样升级后能自动替换掉旧路径
        command.contains(relayArgument)
            && (command.contains("CoolCat") || command.contains(LegacyMigration.legacyName))
    }

    private func removingOurHooks(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { !isOurCommand($0["command"] as? String ?? "") }
                if remaining.isEmpty { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private func loadSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw InstallError.unreadableSettings(path: displayPath, detail: error.localizedDescription)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableSettings(path: displayPath, detail: "顶层不是 JSON 对象")
            }
            return dict
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.unreadableSettings(path: displayPath, detail: error.localizedDescription)
        }
    }

    private func save(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 只保留第一次修改前的原始文件；之后的安装/卸载不再覆盖它
            let backup = url.appendingPathExtension("coolcat-backup")
            // 改名前已经留过 KuroCat 时期的原始备份，就不再另存（那份才是最原始的）
            let legacyBackup = url.appendingPathExtension(LegacyMigration.legacyName.lowercased() + "-backup")
            if fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: backup.path)
                && !fm.fileExists(atPath: legacyBackup.path) {
                try fm.copyItem(at: url, to: backup)
            }
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.writeFailed(path: displayPath, detail: error.localizedDescription)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
