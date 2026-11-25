import AppKit
import SwiftUI

// MARK: - Host

/// 设置面板需要 App 层做的事（窗口、开机启动、音频分析、Claude hook……）。
/// 由 AppDelegate 实现；面板本身只负责展示和改 CatSettings。
protocol SettingsHost: AnyObject {
    var physics: CatPhysics { get }
    var petVisible: Bool { get set }
    var autoStartEnabled: Bool { get set }
    func applyScale(_ scale: CGFloat)
    func applyWindowBehavior()
    /// 音乐相关开关变了：重新决定是否启动实时音频分析
    func audioSettingsChanged(resetPermission: Bool)
    func selectCoat(_ coat: CatCoatTheme)
    func resetPetPosition()
    func relaunch()
    func openInputMonitoring()
    func install(_ agent: CodingAgent)
    func uninstall(_ agent: CodingAgent)
    func runDemo(_ demo: SettingsDemo)
}

enum SettingsDemo {
    case typing, life, meeting, claude, codex, gift, roam, peek, nap, hop
}

// MARK: - Store

/// 把 CatSettings（普通 class + didSet 持久化）桥接成 SwiftUI 可观察的数据源。
/// 面板打开期间每秒刷新一次，展示实时状态（音频分析、会议、Claude 会话、亲密度）。
final class SettingsStore: ObservableObject {
    let host: SettingsHost
    private var timer: Timer?

    init(host: SettingsHost) {
        self.host = host
    }

    var settings: CatSettings { .shared }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<CatSettings, T>, after: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: { CatSettings.shared[keyPath: keyPath] },
            set: { [weak self] value in
                CatSettings.shared[keyPath: keyPath] = value
                after?(value)
                self?.objectWillChange.send()
            }
        )
    }

    func binding(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { [weak self] value in
            set(value)
            self?.objectWillChange.send()
        })
    }

    func refresh() { objectWillChange.send() }

    func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Live Preview

/// 设置面板里的小猫：独立的 CatPhysics，用空闲脚本输入驱动，只在面板可见时以 30fps 渲染
final class CatPreviewModel: ObservableObject {
    @Published private(set) var image: CGImage?
    private let physics = CatPhysics()
    private var timer: Timer?
    private var clock: CFTimeInterval = 100

    func start() {
        guard timer == nil else { return }
        for _ in 0..<20 { advance(1.0 / 60) }
        render()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.advance(1.0 / 30)
            self?.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func advance(_ dt: CGFloat) {
        clock += Double(dt)
        let input = ScriptedFrameInput(
            now: clock, activeKeys: [], orderedKeys: [], mouseScreenPos: .zero, mouseVelocity: .zero,
            leftMouseDown: false, rightMouseDown: false,
            lastMouseMoveTime: 0, lastMouseClickTime: 0, lastKeyActivityTime: 0
        )
        physics.step(dt: dt, windowFrameInScreen: .zero, scripted: input)
    }

    private func render() {
        let scale: CGFloat = 2
        let size = CatPhysics.canvasSize
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        CatRenderer.draw(in: ctx, physics: physics, showPermissionPill: false)
        image = ctx.makeImage()
    }
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, interaction, bond, music, life, meeting, claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .interaction: return "互动"
        case .bond: return "亲密度"
        case .music: return "音乐"
        case .life: return "生活陪伴"
        case .meeting: return "会议模式"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .interaction: return "hand.point.up.left.fill"
        case .bond: return "heart.fill"
        case .music: return "music.note"
        case .life: return "moon.stars.fill"
        case .meeting: return "video.fill"
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.56, blue: 0.60)
        case .appearance: return Color(red: 0.98, green: 0.58, blue: 0.20)
        case .interaction: return Color(red: 0.26, green: 0.62, blue: 0.98)
        case .bond: return Color(red: 0.96, green: 0.38, blue: 0.55)
        case .music: return Color(red: 0.98, green: 0.30, blue: 0.35)
        case .life: return Color(red: 0.42, green: 0.40, blue: 0.90)
        case .meeting: return Color(red: 0.20, green: 0.74, blue: 0.45)
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.16, green: 0.17, blue: 0.20)
        }
    }
}

// MARK: - Root

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    /// 由窗口控制器持有：窗口关闭时停掉 30fps 渲染
    @ObservedObject var preview: CatPreviewModel
    @State private var selection: SettingsPane?

    init(store: SettingsStore, preview: CatPreviewModel, initial: SettingsPane = .general) {
        self.store = store
        self.preview = preview
        _selection = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // 标题栏透明：给红绿灯留出位置，侧栏背景一直铺到窗口顶部
                Color.clear.frame(height: 40)
                List(selection: $selection) {
                    ForEach(SettingsPane.allCases) { pane in
                        HStack(spacing: 9) {
                            SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                            Text(pane.title).font(.system(size: 13))
                        }
                        .padding(.vertical, 2)
                        .tag(pane)
                    }
                }
                .listStyle(SidebarListStyle())
            }
            .frame(width: 196)
            .background(SidebarMaterial())

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text((selection ?? .general).title)
                        .font(.system(size: 22, weight: .bold))
                        .padding(.top, 4)
                    page(for: selection ?? .general)
                }
                .padding(.horizontal, 28)
                .padding(.top, 46)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .edgesIgnoringSafeArea(.top)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { store.startTicking(); preview.start() }
    }

    @ViewBuilder
    private func page(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(store: store)
        case .appearance: AppearancePane(store: store, preview: preview)
        case .interaction: InteractionPane(store: store)
        case .bond: BondPane(store: store, preview: preview)
        case .music: MusicPane(store: store)
        case .life: LifePane(store: store)
        case .meeting: MeetingPane(store: store)
        case .claude: AgentPane(store: store, agent: .claude)
        case .codex: AgentPane(store: store, agent: .codex)
        }
    }
}

// MARK: - Building Blocks

/// 侧栏毛玻璃（SwiftUI 在 macOS 11 上没有对应的 Material API）
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundColor(.white)
            )
    }
}

/// 仿「系统设置」的分组卡片：圆角底 + 行间分割线
struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String?
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .controlSize(.small)
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        SettingsRow(title: title) {
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct ActionRow: View {
    let title: String
    var subtitle: String?
    let button: String
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Button(button, action: action)
        }
    }
}

struct CatPreviewCard: View {
    @ObservedObject var preview: CatPreviewModel
    var height: CGFloat = 220

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.72, green: 0.76, blue: 0.74), Color(red: 0.62, green: 0.67, blue: 0.65)]),
                    startPoint: .top, endPoint: .bottom))
            if let image = preview.image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(CatPhysics.canvasSize, contentMode: .fit)
                    .padding(.top, 6)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Status Text

/// 各模块的实时状态文案（面板和菜单共用）
enum SettingsStatus {
    static func analyzer(_ settings: CatSettings) -> String {
        switch AudioSpectrumAnalyzer.shared.state {
        case .off: return settings.realAudioAnalysis ? "等音乐响起时启动" : "已关闭，使用模拟节拍"
        case .starting: return "启动中…"
        case .running:
            let bpm = AudioSpectrumAnalyzer.shared.snapshot().bpm.map { "，约 \(Int($0)) BPM" } ?? ""
            return "分析中\(bpm)"
        case .silentNoPermission: return "⚠️ 只收到静音：在「隐私与安全性 → 录屏与系统录音」允许 CoolCat 后，重新打开上面的开关"
        case .unsupported: return "需要 macOS 14.2+，当前使用模拟节拍"
        case .failed(let reason): return "启动失败：\(reason)"
        }
    }

    static func nowPlaying() -> String {
        switch MusicMonitor.shared.activity {
        case .music(let app): return "正在听：\(app)"
        case .otherAudio: return "其他 App 在出声"
        case .silent: return "当前没有声音"
        }
    }

    static func meeting() -> String {
        let state = MeetingMonitor.shared.state
        var parts: [String] = []
        if state.micActive { parts.append("🎙 " + (state.micApp ?? "麦克风") + " 在用") }
        if state.cameraActive { parts.append("📷 摄像头开着") }
        return parts.isEmpty ? "当前没有在开会" : parts.joined(separator: " · ")
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var store: SettingsStore
    private static let scales: [(String, CGFloat)] = [("迷你", 0.65), ("偏小", 0.85), ("标准", 1.0), ("偏大", 1.25), ("超大", 1.5)]

    var body: some View {
        let engine = InputEngine.shared
        let host = store.host
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "小猫") {
                ToggleRow(title: "显示小猫", isOn: store.binding(get: { host.petVisible }, set: { host.petVisible = $0 }))
                RowDivider()
                SettingsRow(title: "尺寸") {
                    Picker("", selection: scaleIndex) {
                        ForEach(Self.scales.indices, id: \.self) { i in Text(Self.scales[i].0).tag(i) }
                    }
                    .labelsHidden()
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 300)
                }
                RowDivider()
                ActionRow(title: "位置", subtitle: "拖动小猫可以随意摆放", button: "重置到右下角") { host.resetPetPosition() }
            }
            SettingsCard(title: "窗口") {
                ToggleRow(title: "完全鼠标穿透", subtitle: "点击直接穿过小猫；按住 ⌥Option 可临时右键、拖动",
                          isOn: store.binding(\.fullClickThrough))
                RowDivider()
                ToggleRow(title: "在全屏游戏 / 应用上方显示", isOn: store.binding(\.fullScreenOverlay) { _ in host.applyWindowBehavior() })
                RowDivider()
                ToggleRow(title: "开机自动启动", isOn: store.binding(get: { host.autoStartEnabled }, set: { host.autoStartEnabled = $0 }))
            }
            SettingsCard(title: "状态", footer: "授权「输入监控」后如果键盘没反应，点「重启 CoolCat」让系统重新建立监听。") {
                SettingsRow(title: "键盘监听", subtitle: engine.status.rawValue) {
                    if engine.status.needsAttention {
                        Button("去授权…") { host.openInputMonitoring() }
                    } else {
                        Text("正常").font(.system(size: 12)).foregroundColor(.green)
                    }
                }
                RowDivider()
                InfoRow(title: "今日", value: "击键 \(engine.totalKeystrokesToday) · KPM \(engine.currentKPM) · 摸猫 \(host.physics.totalPetSessions) 次")
                RowDivider()
                ActionRow(title: "重启 CoolCat", button: "重启") { host.relaunch() }
                RowDivider()
                InfoRow(title: "版本", value: "CoolCat v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
            }
        }
    }

    private var scaleIndex: Binding<Int> {
        Binding(
            get: {
                let s = CatSettings.shared.scale
                return Self.scales.indices.min { abs(Self.scales[$0].1 - s) < abs(Self.scales[$1].1 - s) } ?? 2
            },
            set: { i in
                store.host.applyScale(Self.scales[i].1)
                store.refresh()
            }
        )
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var preview: CatPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CatPreviewCard(preview: preview)
            SettingsCard(title: "小猫") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("猫咪").font(.system(size: 13))
                    CoatGallery(store: store)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                RowDivider()
                if let pet = PetLibrary.shared.active {
                    SettingsRow(title: "瞳色", subtitle: "\(pet.name)有自己的招牌瞳色") {
                        Circle().fill(Color(pet.eyeColor)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                    }
                } else {
                SettingsRow(title: "瞳色", subtitle: CatSettings.shared.eyeTheme.rawValue) {
                    HStack(spacing: 8) {
                        ForEach(EyeColorTheme.allCases, id: \.self) { eye in
                            let selected = CatSettings.shared.eyeTheme == eye
                            Button {
                                CatSettings.shared.eyeTheme = eye
                                store.refresh()
                            } label: {
                                Circle()
                                    .fill(Color(eye.primaryColor))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                                    .padding(3)
                                    .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help(eye.rawValue)
                        }
                    }
                }
                }
                RowDivider()
                SettingsRow(title: "装扮", subtitle: "在「亲密度」里随等级解锁") {
                    Text(CatSettings.shared.accessory.title).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            SettingsCard(title: "键盘") {
                SettingsRow(title: "配色") {
                    Picker("", selection: store.binding(\.keyboardTheme)) {
                        ForEach(KeyboardTheme.allCases, id: \.self) { Text($0.shortName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 280)
                }
                RowDivider()
                ToggleRow(title: "显示键帽字符", isOn: store.binding(\.showKeyLegends))
            }
        }
    }
}

/// 可选的猫：4 只经典猫 + PetLibrary 里的新猫
enum CoatOption: Hashable {
    case classic(CatCoatTheme)
    case pet(String)

    static var all: [CoatOption] {
        CatCoatTheme.allCases.map { .classic($0) } + PetLibrary.shared.all.map { .pet($0.id) }
    }

    static var current: CoatOption {
        if let pet = PetLibrary.shared.active { return .pet(pet.id) }
        return .classic(CatSettings.shared.coatTheme)
    }

    var name: String {
        switch self {
        case .classic(let coat): return coat.shortName
        case .pet(let id): return PetLibrary.shared.pet(id: id)?.name ?? id
        }
    }
}

/// 猫咪缩略图：离屏画一只静止的猫，裁出头和上半身；每种只画一次
final class CoatThumbnails {
    static let shared = CoatThumbnails()
    private var cache: [CoatOption: CGImage] = [:]
    /// 画布里头和上半身的范围
    private let crop = CGRect(x: 110, y: 58, width: 148, height: 156)

    func image(for option: CoatOption) -> CGImage? {
        if let cached = cache[option] { return cached }
        let settings = CatSettings.shared
        let saved = (settings.coatTheme, settings.eyeTheme, settings.customPetID, settings.accessory)
        defer { (settings.coatTheme, settings.eyeTheme, settings.customPetID, settings.accessory) = saved }
        settings.accessory = .none
        switch option {
        case .classic(let coat):
            settings.customPetID = nil
            settings.coatTheme = coat
            settings.eyeTheme = coat.signatureEye
        case .pet(let id):
            guard let pet = PetLibrary.shared.pet(id: id) else { return nil }
            PetLibrary.shared.select(pet)
        }
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(crop.width * scale), height: Int(crop.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: crop.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        CatRenderer.draw(in: ctx, physics: CatPhysics(), showPermissionPill: false)
        let image = ctx.makeImage()
        cache[option] = image
        return image
    }
}

private struct CoatGallery: View {
    @ObservedObject var store: SettingsStore
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)]

    var body: some View {
        let current = CoatOption.current
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(CoatOption.all, id: \.self) { option in
                let selected = option == current
                Button {
                    switch option {
                    case .classic(let coat): store.host.selectCoat(coat)
                    case .pet(let id): PetLibrary.shared.select(PetLibrary.shared.pet(id: id))
                    }
                    store.refresh()
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 0.70, green: 0.74, blue: 0.72))
                            if let image = CoatThumbnails.shared.image(for: option) {
                                Image(decorative: image, scale: 2)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(height: 84)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                        )
                        Text(option.name)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundColor(selected ? .accentColor : .primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

extension CatCoatTheme {
    /// 每只经典猫的招牌瞳色（换毛色时自动配上）
    var signatureEye: EyeColorTheme {
        switch self {
        case .classicBlack: return .neonChartreuse
        case .siamese: return .siameseBlue
        case .shorthair, .orangeWhite: return .softAmber
        }
    }

    var shortName: String {
        switch self {
        case .classicBlack: return "小黑猫"
        case .siamese: return "暹罗"
        case .shorthair: return "美短"
        case .orangeWhite: return "橘白"
        }
    }
}

extension KeyboardTheme {
    var shortName: String {
        switch self {
        case .classicMilk: return "奶白暖黄"
        case .midnightHacker: return "暗夜极客"
        case .retroCream: return "复古奶油"
        }
    }
}

// MARK: - Interaction

private struct InteractionPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "和小猫玩") {
                ToggleRow(title: "摸头 / 摸背闭眼", subtitle: "光标在小猫头上、背上来回划", isOn: store.binding(\.petInteraction))
                RowDivider()
                ToggleRow(title: "光标逗猫", subtitle: "在小猫身前慢慢晃光标：盯上 → 扭屁股 → 出爪拍", isOn: store.binding(\.cursorPlay))
                RowDivider()
                ToggleRow(title: "空闲时的小动作", subtitle: "打哈欠、伸懒腰、踩奶、慢眨眼……", isOn: store.binding(\.idleAnimations))
                RowDivider()
                ToggleRow(title: "满屏漫游 🐾",
                          subtitle: "30 秒没打字就自己跳下键盘溜达、跳上窗口顶、躲到屏幕边偷看；"
                              + "你一打字就跑回来，Claude / Codex 等你批准时也会回来提醒；放歌时守在键盘前跟着节奏摇",
                          isOn: store.binding(\.roaming))
                RowDivider()
                ActionRow(title: "现在去溜达一圈", subtitle: "预览用：不等闲置，立刻出门（敲一下键盘就回来）", button: "出发") {
                    store.host.runDemo(.roam)
                }
                RowDivider()
                ActionRow(title: "偷看一下 👀", subtitle: "预览用：溜达时会随机躲到屏幕边外，只露脑袋和两只爪子偷看你", button: "看看") {
                    store.host.runDemo(.peek)
                }
                RowDivider()
                ActionRow(title: "窗口跳台 🪟", subtitle: "预览用：把桌面上的窗口当桌子，在窗口顶上走、从一扇窗跳到另一扇（窗口上方得留点空）",
                          button: "跳吧") {
                    store.host.runDemo(.hop)
                }
                RowDivider()
                ActionRow(title: "打个盹 💤", subtitle: "预览用：溜达时会随机找个地方（最爱窗口顶上）蜷成一团睡一会儿", button: "睡吧") {
                    store.host.runDemo(.nap)
                }
            }
            SettingsCard(title: "键盘和鼠标") {
                ToggleRow(title: "按键气泡", subtitle: "按下的键从键盘上冒出来，如 [S] [W] [⇧]", isOn: store.binding(\.showKeyBadges))
                RowDivider()
                ToggleRow(title: "鼠标点击气泡", subtitle: "[左键] [右键]", isOn: store.binding(\.showMouseBadges))
                RowDivider()
                ToggleRow(title: "键盘习惯小反应", subtitle: "狂按 ⌫ 冒汗、⌘S 盖章、截图比耶、KPM 破纪录戴皇冠",
                          isOn: store.binding(\.keyHabitReactions))
                RowDivider()
                ToggleRow(title: "「用脚按」彩蛋 🐾", subtitle: "同时按住 3 个键，小猫伸出后脚帮忙", isOn: store.binding(\.footEasterEgg))
            }
            SettingsCard {
                ActionRow(title: "演示打字 + 摸猫", button: "播放") { store.host.runDemo(.typing) }
            }
        }
    }
}

// MARK: - Bond

private struct BondPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var preview: CatPreviewModel

    var body: some View {
        let physics = store.host.physics
        let bond = physics.bondForDisplay
        let level = bond.level
        let next = bond.nextLevel
        let progress: Double = {
            guard let next else { return 1 }
            let span = Double(next.threshold - level.threshold)
            return span > 0 ? Double(bond.points - level.threshold) / span : 1
        }()
        let today = bond.todayBySource.values.reduce(0, +)

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                CatPreviewCard(preview: preview, height: 170)
                    .frame(width: 210)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Lv\(level.level)").font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundColor(SettingsPane.bond.tint)
                        Text(level.title).font(.system(size: 18, weight: .semibold))
                    }
                    ProgressView(value: min(1, max(0, progress)))
                        .accentColor(SettingsPane.bond.tint)
                    Text(next.map { "\(bond.points) / \($0.threshold) · 下一级「\($0.title)」解锁 \($0.unlock?.title ?? "")" }
                         ?? "\(bond.points) 分 · 满级啦，你们是最好的朋友")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    HStack(spacing: 16) {
                        BondStat(value: "\(bond.daysKnown())", label: "认识天数")
                        BondStat(value: "\(bond.pets)", label: "摸摸")
                        BondStat(value: "\(bond.catches)", label: "抓到光标")
                        BondStat(value: "\(bond.fish)", label: "小鱼干")
                        BondStat(value: "+\(today)", label: "今天")
                    }
                    .padding(.top, 4)
                }
            }
            SettingsCard(title: "装扮") {
                HStack(spacing: 10) {
                    ForEach(CatAccessory.allCases, id: \.self) { accessory in
                        AccessoryTile(accessory: accessory, bond: bond,
                                      selected: CatSettings.shared.accessory == accessory) {
                            CatSettings.shared.accessory = accessory
                            store.refresh()
                        }
                    }
                }
                .padding(12)
            }
            SettingsCard(title: "喂食", footer: "摸摸、逗猫、喂鱼、一起听歌、陪 Claude Code 干完活都会加亲密度；每种每天有上限，不理它也不会掉分。") {
                SettingsRow(title: "🐟 喂一条小鱼干", subtitle: "今天 \(physics.feedLog.count) / \(FeedLog.dailyLimit) 条，吃饱了会摇头") {
                    Button("喂") { physics.feed(); store.refresh() }
                }
            }
            SettingsCard(title: "随等级解锁的互动") {
                UnlockRow(title: "主动蹭你", subtitle: "光标停在它头上不动，它会歪头来回蹭", need: 2, level: level.level)
                RowDivider()
                UnlockRow(title: "每天送一个小礼物", subtitle: "趁你闲着推到桌上，用光标碰一下收下", need: 3, level: level.level) {
                    Button("演示") { store.host.runDemo(.gift) }
                }
            }
        }
    }
}

private struct BondStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}

private struct AccessoryTile: View {
    let accessory: CatAccessory
    let bond: BondLog
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let unlocked = bond.isUnlocked(accessory)
        let need = BondLog.levels.first { $0.unlock == accessory }
        Button(action: action) {
            VStack(spacing: 4) {
                Text(emoji).font(.system(size: 24))
                    .opacity(unlocked ? 1 : 0.35)
                Text(name).font(.system(size: 11, weight: .medium))
                Text(unlocked ? (selected ? "戴着" : " ") : "🔒 Lv\(need?.level ?? 0)")
                    .font(.system(size: 10))
                    .foregroundColor(selected ? SettingsPane.bond.tint : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? SettingsPane.bond.tint.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? SettingsPane.bond.tint : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!unlocked)
    }

    private var emoji: String {
        switch accessory {
        case .none: return "🚫"
        case .bell: return "🔔"
        case .scarf: return "🧣"
        case .bow: return "🎀"
        case .shades: return "🕶️"
        }
    }

    private var name: String {
        switch accessory {
        case .none: return "不戴"
        case .bell: return "铃铛项圈"
        case .scarf: return "毛线围巾"
        case .bow: return "蝴蝶结"
        case .shades: return "墨镜"
        }
    }
}

private struct UnlockRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    let need: Int
    let level: Int
    var trailing: Trailing

    init(title: String, subtitle: String, need: Int, level: Int, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.need = need
        self.level = level
        self.trailing = trailing()
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 10) {
                trailing
                Text(level >= need ? "已解锁" : "🔒 Lv\(need)")
                    .font(.system(size: 12))
                    .foregroundColor(level >= need ? .green : .secondary)
            }
        }
    }
}

extension UnlockRow where Trailing == EmptyView {
    init(title: String, subtitle: String, need: Int, level: Int) {
        self.init(title: title, subtitle: subtitle, need: need, level: level) { EmptyView() }
    }
}

// MARK: - Music

private struct MusicPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let host = store.host
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "听歌时") {
                ToggleRow(title: "戴耳机、跟着节拍摇头 🎧", isOn: store.binding(\.musicHeadphones) { _ in
                    host.audioSettingsChanged(resetPermission: false)
                })
                RowDivider()
                ToggleRow(title: "看视频 / 玩游戏有声音时也戴", isOn: store.binding(\.headphonesForAnyAudio) { _ in
                    host.audioSettingsChanged(resetPermission: false)
                })
                RowDivider()
                ToggleRow(title: "切歌时冒出歌名气泡", isOn: store.binding(\.showTrackBubble))
                RowDivider()
                ToggleRow(title: "猫身后的频谱墙", isOn: store.binding(\.musicVisualizer) { _ in
                    host.audioSettingsChanged(resetPermission: false)
                })
                RowDivider()
                ToggleRow(title: "没在打字时跟着节奏跳舞 💃", subtitle: "强节奏多点头，舒缓的歌慢慢摇",
                          isOn: store.binding(\.musicDance) { _ in host.audioSettingsChanged(resetPermission: false) })
            }
            BeatCalibrationCard(physics: host.physics)
            SettingsCard(title: "节拍来源", footer: "关掉后用模拟节拍：动作照样有，只是不会严丝合缝地踩在鼓点上。") {
                ToggleRow(title: "跟随真实音频节拍", subtitle: "需要在「隐私与安全性 → 录屏与系统录音」允许 CoolCat",
                          isOn: store.binding(\.realAudioAnalysis) { on in host.audioSettingsChanged(resetPermission: on) })
                RowDivider()
                InfoRow(title: "实时音频", value: SettingsStatus.analyzer(store.settings))
                RowDivider()
                InfoRow(title: "当前", value: SettingsStatus.nowPlaying())
            }
        }
    }
}

// MARK: - Beat Calibration

/// 节拍校准面板的数据：节拍灯、锁拍统计、跟拍校准流程、按设备的偏移。打开时 30fps 刷新，关掉就停
final class BeatCalibrationModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case collecting(Int)
        case result(String, success: Bool)
    }

    let physics: CatPhysics
    @Published private(set) var flash: Double = 0
    @Published private(set) var stats = "放首歌就有数据"
    @Published private(set) var device = "—"
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var canCalibrate = false
    private var deviceUID: String?
    private var calibrator = BeatTapCalibrator()
    private var timer: Timer?
    private var keyMonitor: Any?
    private var lastStatsUpdate: CFTimeInterval = 0

    init(physics: CatPhysics) {
        self.physics = physics
    }

    deinit {
        stop()
    }

    var offsetMs: Double {
        get { BeatOffsetStore.shared.offsetMs(for: deviceUID) }
        set {
            BeatOffsetStore.shared.setOffsetMs((newValue / 10).rounded() * 10, for: deviceUID)
            objectWillChange.send()
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endCollecting()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let live = physics.audio.isLive && physics.isEnjoyingMusic
        if live {
            // 节拍灯：正好在小猫的拍点上最亮，四分之一拍内暗下去
            let position = Double(physics.beatPosition(at: now))
            flash = max(0, 1 - (position - position.rounded(.down)) * 4)
        } else {
            flash = 0
        }
        guard now - lastStatsUpdate > 0.5 else { return }
        lastStatsUpdate = now
        let snapshot = physics.audio
        deviceUID = snapshot.outputDeviceUID
        device = snapshot.isLive
            ? "\(snapshot.outputDeviceName ?? "未知设备") · 系统报告延迟 \(Int(snapshot.outputLatency * 1000)) ms"
            : "等音乐响起"
        canCalibrate = physics.canCalibrateBeat
        if let s = physics.currentLockSummary, live {
            let state = physics.beatIsSteady ? "卡点中" : (physics.beatTempoStable ? "跟拍中（相位不太准，动作放软）" : "找拍子中")
            stats = String(format: "%@ · 锁拍 %.0f%% · 抖动 %.0f ms · %.0f BPM", state, s.lockRatio * 100, s.meanAbsMs, s.bpm)
        } else {
            stats = live ? "统计中…" : "放首歌就有数据"
        }
    }

    // MARK: 跟拍校准

    func beginCollecting() {
        guard physics.canCalibrateBeat else {
            stage = .result("先放一首鼓点清楚的歌，等小猫戴上耳机、跟上拍子再来", success: false)
            return
        }
        calibrator.reset()
        stage = .collecting(0)
        endKeyMonitor()
        // 用按下空格那一刻的事件时间戳，不用按钮回调：鼠标点按钮要松开才触发，会晚 100ms 左右
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49 else { return event }
            if !event.isARepeat { self.recordTap(at: event.timestamp) }
            return nil
        }
    }

    func cancel() {
        endCollecting()
        stage = .idle
    }

    private func recordTap(at timestamp: TimeInterval) {
        guard case .collecting = stage else { return }
        // NSEvent.timestamp 和 CACurrentMediaTime 都是开机以来的秒数（mach 时钟），可以直接比
        calibrator.record(beatPosition: Double(physics.beatPosition(at: timestamp)),
                          secondsPerBeat: Double(physics.secondsPerBeat))
        switch calibrator.outcome {
        case .needMore:
            stage = .collecting(calibrator.count)
        case .done(let offset, let spread):
            endCollecting()
            let ms = offset * 1000
            let before = offsetMs
            offsetMs = before + ms
            let direction = ms >= 0 ? "早" : "晚"
            let fix = abs(ms) < 15 ? "已经很准了" : "已经帮你修正（\(Int(before)) → \(Int(offsetMs)) ms）"
            stage = .result(String(format: "小猫比你听到的%@ %.0f ms，%@。你按得很稳（±%.0f ms）", direction, abs(ms), fix, spread),
                            success: true)
        case .inconsistent(let spread):
            endCollecting()
            stage = .result(String(format: "按得有点散（±%.0f ms），跟着底鼓「咚」那一下再试一次", spread), success: false)
        case .offBeat:
            endCollecting()
            stage = .result("好像都按在两拍中间了（反拍）。跟着底鼓「咚」那一下再试一次", success: false)
        }
    }

    private func endCollecting() {
        endKeyMonitor()
        if case .collecting = stage { stage = .idle }
    }

    private func endKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct BeatCalibrationCard: View {
    @StateObject private var model: BeatCalibrationModel

    init(physics: CatPhysics) {
        _model = StateObject(wrappedValue: BeatCalibrationModel(physics: physics))
    }

    var body: some View {
        SettingsCard(title: "节拍校准",
                     footer: "蓝牙耳机、外接音箱自报的延迟常常不准，会让小猫每一拍都早一点或晚一点。按输出设备分别记住，换耳机不用重新调。") {
            InfoRow(title: "输出设备", value: model.device)
            RowDivider()
            SettingsRow(title: "节拍灯", subtitle: "亮的那一下就是小猫认为的拍点，和你听到的鼓点对比看看") {
                HStack(spacing: 10) {
                    Text(model.stats)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                    Circle()
                        .fill(Color.orange.opacity(0.18 + 0.82 * model.flash))
                        .frame(width: 16, height: 16)
                        .scaleEffect(1 + 0.25 * model.flash)
                }
            }
            RowDivider()
            SettingsRow(title: "跟拍校准", subtitle: "放一首鼓点清楚的歌，跟着鼓点按空格键 \(BeatTapCalibrator.taps) 下") {
                switch model.stage {
                case .collecting(let n):
                    HStack(spacing: 8) {
                        Text("按空格 \(n)/\(BeatTapCalibrator.taps)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Button("取消") { model.cancel() }
                    }
                default:
                    Button("开始") { model.beginCollecting() }
                        .disabled(!model.canCalibrate)
                }
            }
            if case .result(let text, let success) = model.stage {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(success ? .green : .orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            RowDivider()
            SettingsRow(title: "手动微调", subtitle: "正数 = 小猫往后挪（原来太早），负数 = 往前挪") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { model.offsetMs }, set: { model.offsetMs = $0 }),
                           in: BeatOffsetStore.range)
                        .frame(width: 150)
                    Text(String(format: "%+.0f ms", model.offsetMs))
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                    Button("归零") { model.offsetMs = 0 }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - Life

private struct LifePane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "陪你过日子") {
                ToggleRow(title: "🌙 深夜戴睡帽、提醒早点睡", subtitle: "23 点、1 点各提醒一次", isOn: store.binding(\.lifeNight))
                RowDivider()
                ToggleRow(title: "☀️ 早上第一次开工端咖啡", isOn: store.binding(\.lifeMorning))
                RowDivider()
                ToggleRow(title: "🪫 低电量没精神 / ⚡ 插电喝奶", isOn: store.binding(\.lifeBattery))
                RowDivider()
                ToggleRow(title: "💧 连续工作 50 分钟提醒喝水", subtitle: "歇满 5 分钟重新计时", isOn: store.binding(\.lifeWorkBreak))
            }
            SettingsCard {
                ActionRow(title: "演示", subtitle: "睡帽 → 咖啡 → 没电 → 插电 → 喝水，约 30 秒", button: "播放") {
                    store.host.runDemo(.life)
                }
            }
        }
    }
}

// MARK: - Meeting

private struct MeetingPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "开会时") {
                InfoRow(title: "当前", value: SettingsStatus.meeting())
                RowDivider()
                ToggleRow(title: "开麦戴耳麦、开摄像头先洗脸", isOn: store.binding(\.meetingMode))
                RowDivider()
                ToggleRow(title: "开麦时打字太猛提醒「嘘」🤫", isOn: store.binding(\.keyboardNoiseReminder))
            }
            SettingsCard {
                ActionRow(title: "演示", subtitle: "开摄像头 → 开麦 → 打字太吵", button: "播放") {
                    store.host.runDemo(.meeting)
                }
            }
        }
    }
}

// MARK: - Agents (Claude Code / Codex)

private struct AgentPane: View {
    @ObservedObject var store: SettingsStore
    let agent: CodingAgent

    var body: some View {
        let installer = AgentHookInstaller.installer(for: agent)
        let state = installer.state()
        let lines = ClaudeActivityTracker.shared.lines(now: CACurrentMediaTime(), agents: [agent])
        let host = store.host
        let lastEvent = ClaudeActivityTracker.lastEventDate(for: agent)
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "连接", footer: footer(installer)) {
                SettingsRow(title: statusTitle(state), subtitle: statusSubtitle(state, lastEvent: lastEvent)) {
                    HStack(spacing: 8) {
                        if state != .notInstalled {
                            Button("断开") { host.uninstall(agent); store.refresh() }
                        }
                        Button(state == .notInstalled ? "连接…" : "重新连接") { host.install(agent); store.refresh() }
                    }
                }
                if agent == .codex && state != .notInstalled {
                    RowDivider()
                    SettingsRow(title: "信任 hook", subtitle: "Codex 不会运行未经信任的新 hook：桌面 App 在「设置 → Hooks」点「needs review」，CLI 输入 /hooks，信任标题为「CoolCat 桌面小猫」的 8 条") {
                        Text(lastEvent == nil ? "等待信任" : "已生效")
                            .font(.system(size: 12))
                            .foregroundColor(lastEvent == nil ? .orange : .green)
                    }
                }
                RowDivider()
                ToggleRow(title: "显示状态气泡和动作", subtitle: "思考中、等你批准、完成撒花",
                          isOn: store.binding(get: { CatSettings.shared.isIntegrationEnabled(agent) },
                                              set: { CatSettings.shared.setIntegration(agent, enabled: $0) }))
            }
            SettingsCard(title: "会话") {
                if lines.isEmpty {
                    InfoRow(title: state == .installed ? "所有会话都空闲" : "还没有会话", value: "")
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if index > 0 { RowDivider() }
                        InfoRow(title: line.project,
                                value: line.detail + (line.elapsed.map { " · " + ClaudeActivityTracker.formatElapsed($0) } ?? ""))
                    }
                }
            }
            SettingsCard {
                ActionRow(title: "演示", subtitle: "思考 → 等批准 → 搞定", button: "播放") {
                    host.runDemo(agent == .codex ? .codex : .claude)
                }
            }
        }
    }

    private func footer(_ installer: AgentHookInstaller) -> String {
        "连接会在 \(installer.displayPath) 里加入 hook：只把事件名、工具名、项目文件夹名发给小猫，不读取提示词和代码；原文件会备份。"
    }

    private func statusTitle(_ state: HookInstallState) -> String {
        switch state {
        case .notInstalled: return "未连接 \(agent.displayName)"
        case .outdated: return "⚠️ 需要重新连接"
        case .installed: return "已连接 \(agent.displayName)"
        }
    }

    private func statusSubtitle(_ state: HookInstallState, lastEvent: Date?) -> String? {
        switch state {
        case .notInstalled:
            return "连接后，小猫会跟着 \(agent.displayName) 思考、等你批准、完成任务做出反应"
        case .outdated:
            return "hook 还指向旧的 CoolCat 位置，或缺少新版本需要的事件"
        case .installed:
            if let lastEvent {
                let f = RelativeDateTimeFormatter()
                f.locale = Locale(identifier: "zh_CN")
                return "已收到事件（最近一次 \(f.localizedString(for: lastEvent, relativeTo: Date()))）"
            }
            return agent == .codex ? "已写入，还没收到事件：先在 Codex 里信任 hook" : "已打开的会话需要重启（或执行 /hooks）后生效"
        }
    }
}

// MARK: - Window

/// 设置窗口：单例复用，关闭时停掉预览和刷新
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    private let preview = CatPreviewModel()

    init(host: SettingsHost) {
        store = SettingsStore(host: host)
        let hosting = NSHostingController(rootView: SettingsRootView(store: store, preview: preview))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CoolCat 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        window.setFrameAutosaveName("CoolCat.SettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        // 菜单栏 App（LSUIElement）默认不在前台：先激活再显示
        NSApp.activate(ignoringOtherApps: true)
        store.refresh()
        store.startTicking()
        preview.start()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        store.stopTicking()
        preview.stop()
    }
}
