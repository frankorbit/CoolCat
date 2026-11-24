import AppKit
import CoreAudio
import Foundation

/// 当前"谁在出声"的判定结果。
enum AudioActivity: Equatable {
    case silent
    /// 已知音乐播放器在出声（Music / Spotify / 网易云 / QQ 音乐 ...）
    case music(app: String)
    /// 其他 App 在出声（浏览器视频、游戏、会议等），或系统太老无法区分来源
    case otherAudio
}

struct NowPlayingTrack: Equatable {
    let title: String
    let artist: String?
}

/// 零权限的"正在听歌"检测器。
///
/// 两路信号合并：
/// 1. Core Audio 进程对象（macOS 14.2+）：`kAudioProcessPropertyIsRunningOutput` + bundle ID，
///    能知道是哪个 App 在往输出设备写音频，不需要录音/输入监控权限。
///    更老的系统退化为 `kAudioDevicePropertyDeviceIsRunningSomewhere`（只知道"有声音"）。
/// 2. Music.app / Spotify 的 DistributedNotification：带播放状态与歌名。
///    这两个 App 暂停后音频流常会保持一段时间，所以它们以通知状态为准。
///
/// 所有回调都在主线程触发；轮询间隔 1s，对 CPU 影响可忽略。
final class MusicMonitor {
    static let shared = MusicMonitor()

    var onActivityChange: ((AudioActivity) -> Void)?
    var onTrackChange: ((NowPlayingTrack) -> Void)?

    private(set) var activity: AudioActivity = .silent
    private var pollTimer: Timer?
    private var candidate: AudioActivity = .silent
    private var candidateSince: CFTimeInterval = 0
    private var lastTrack: NowPlayingTrack?

    /// 通知上报的播放状态（key = bundle ID 前缀）。nil 表示从未收到过，退回到 Core Audio 判断。
    private var notifiedPlaying: [String: Bool] = [:]
    /// 通知说"在放"但 Core Audio 看不到它出声的起始时间；持续太久就判定通知过期（崩溃/强退没发 Stopped）
    private var notifiedButSilentSince: [String: CFTimeInterval] = [:]

    // 小写子串匹配：bundle ID 命中任一即视为音乐播放器（含其 helper 进程）
    private static let musicAppTokens: [(token: String, name: String)] = [
        ("com.apple.music", "Apple Music"),
        ("com.apple.podcasts", "播客"),
        ("spotify", "Spotify"),
        ("163music", "网易云音乐"),
        ("neteasemusic", "网易云音乐"),
        ("qqmusic", "QQ 音乐"),
        ("kugou", "酷狗音乐"),
        ("kuwo", "酷我音乐"),
        ("ximalaya", "喜马拉雅"),
        ("tidal", "TIDAL"),
        ("deezer", "Deezer"),
        ("amazon.music", "Amazon Music"),
        ("coppertino.vox", "VOX"),
        ("swinsian", "Swinsian"),
        ("plexamp", "Plexamp"),
        ("cider", "Cider"),
        ("lx-music", "洛雪音乐"),
        ("foobar", "foobar2000")
    ]

    private static let notificationSources: [(name: String, bundlePrefix: String)] = [
        ("com.apple.Music.playerInfo", "com.apple.music"),
        ("com.spotify.client.PlaybackStateChanged", "com.spotify.client")
    ]

    private init() {}

    func start() {
        guard pollTimer == nil else { return }
        let center = DistributedNotificationCenter.default()
        for source in Self.notificationSources {
            center.addObserver(
                self,
                selector: #selector(handlePlayerNotification(_:)),
                name: Notification.Name(source.name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleAppTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier?.lowercased() else { return }
        for prefix in notifiedPlaying.keys where id.hasPrefix(prefix) {
            notifiedPlaying[prefix] = nil
            notifiedButSilentSince[prefix] = nil
        }
        poll()
    }

    // MARK: - Distributed Notifications

    @objc private func handlePlayerNotification(_ note: Notification) {
        guard let source = Self.notificationSources.first(where: { $0.name == note.name.rawValue }) else { return }
        let info = note.userInfo ?? [:]
        let state = info["Player State"] as? String
        notifiedPlaying[source.bundlePrefix] = (state == "Playing")
        // 新通知重新计时，避免上一次的"沉默起点"把这次真实播放立刻判成过期
        notifiedButSilentSince[source.bundlePrefix] = nil

        if state == "Playing", let title = info["Name"] as? String, !title.isEmpty {
            let track = NowPlayingTrack(title: title, artist: info["Artist"] as? String)
            if track != lastTrack {
                lastTrack = track
                onTrackChange?(track)
            }
        }
        poll()
    }

    // MARK: - Polling

    private func poll() {
        let detected = detectActivity()
        let now = CACurrentMediaTime()
        if detected != candidate {
            candidate = detected
            candidateSince = now
        }
        // 防抖：开始出声需持续 1.5s（过滤系统提示音），静音需持续 3s（过滤切歌间隙）
        let required: CFTimeInterval = (candidate == .silent) ? 3.0 : 1.5
        // 音乐 App 优先级更高：从 otherAudio 升级到 music 立即生效
        let isUpgrade: Bool = {
            if case .music = candidate, activity == .otherAudio { return true }
            return false
        }()
        if candidate != activity && (isUpgrade || now - candidateSince >= required) {
            activity = candidate
            onActivityChange?(activity)
        }
    }

    private func detectActivity() -> AudioActivity {
        var outputting: [String] = []
        if #available(macOS 14.2, *) {
            outputting = AudioProcessProbe.bundleIDs(runningOutput: true).map { $0.lowercased() }
            // 交叉校验：通知说在放，但 10 秒都没看到它出声 → 通知过期
            let now = CACurrentMediaTime()
            for (prefix, playing) in notifiedPlaying where playing {
                if outputting.contains(where: { $0.hasPrefix(prefix) }) {
                    notifiedButSilentSince[prefix] = nil
                } else if let since = notifiedButSilentSince[prefix] {
                    if now - since > 10 {
                        notifiedPlaying[prefix] = false
                        notifiedButSilentSince[prefix] = nil
                    }
                } else {
                    notifiedButSilentSince[prefix] = now
                }
            }
        }

        // 通知明确说"在放"的优先
        for (prefix, playing) in notifiedPlaying where playing {
            if let match = Self.musicAppTokens.first(where: { prefix.contains($0.token) }) {
                return .music(app: match.name)
            }
        }

        if #available(macOS 14.2, *) {
            var sawOther = false
            for lower in outputting {
                // 有通知源的 App 以通知为准，避免暂停后音频流未关导致"一直在听"
                if let prefix = notifiedPlaying.keys.first(where: { lower.hasPrefix($0) }),
                   notifiedPlaying[prefix] == false {
                    continue
                }
                if let match = Self.musicAppTokens.first(where: { lower.contains($0.token) }) {
                    return .music(app: match.name)
                }
                sawOther = true
            }
            return sawOther ? .otherAudio : .silent
        }
        return AudioProcessProbe.defaultDeviceIsRunning(input: false) ? .otherAudio : .silent
    }
}

// MARK: - Core Audio Process Probe

/// 无权限的 Core Audio 查询工具：谁在放声音 / 谁在用麦克风。
enum AudioProcessProbe {
    /// macOS 14.2+：枚举正在输出（或采集）音频的进程 bundle ID，不含本进程。
    /// 没有 bundle ID 的命令行进程（afplay、ffmpeg 等）记为 "unknown.process"。
    @available(macOS 14.2, *)
    static func bundleIDs(runningOutput: Bool) -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        let selector = runningOutput ? kAudioProcessPropertyIsRunningOutput : kAudioProcessPropertyIsRunningInput
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [String] = []
        for process in processes {
            guard uint32Property(process, selector) == 1 else { continue }
            if let pid = int32Property(process, kAudioProcessPropertyPID), pid == myPID { continue }
            if let bundleID = stringProperty(process, kAudioProcessPropertyBundleID), !bundleID.isEmpty {
                result.append(bundleID)
            } else {
                result.append("unknown.process")
            }
        }
        return result
    }

    static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// 默认输出/输入设备是否被任意进程占用（macOS 14.2 以下的兜底，无法区分来源）。
    static func defaultDeviceIsRunning(input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        return uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func int32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
