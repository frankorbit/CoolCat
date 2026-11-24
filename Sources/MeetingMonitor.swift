import AppKit
import CoreAudio
import CoreMediaIO
import Foundation

struct MeetingState: Equatable {
    /// 麦克风被某个 App 占用（开会、录音、语音输入）
    var micActive = false
    /// 占用麦克风的 App 友好名；系统太老无法区分来源时为 nil
    var micApp: String?
    /// 任意摄像头正在被使用
    var cameraActive = false

    static let idle = MeetingState()
}

/// 零权限的"正在开会"检测器：麦克风靠 Core Audio 进程对象，摄像头靠 CoreMediaIO。
///
/// 只读取"设备是否被占用"这一状态位，不采集任何音视频，因此不会触发系统的麦克风/摄像头授权，
/// 也不会点亮菜单栏的橙色/绿色指示点。轮询 1.5s，开/关分别防抖。
final class MeetingMonitor {
    static let shared = MeetingMonitor()

    var onChange: ((MeetingState) -> Void)?
    private(set) var state = MeetingState.idle

    private var timer: Timer?
    private var micCandidate = (active: false, since: CFTimeInterval(0))
    private var cameraCandidate = (active: false, since: CFTimeInterval(0))

    // 系统语音服务（听写、Siri）也会短暂占用麦克风，不算开会
    private static let ignoredMicTokens = ["siri", "speech", "dictation", "assistant", "corespeech", "com.apple.controlcenter"]

    private static let meetingAppTokens: [(token: String, name: String)] = [
        ("zoom", "Zoom"),
        ("com.tencent.meeting", "腾讯会议"),
        ("wemeet", "腾讯会议"),
        ("teams", "Teams"),
        ("feishu", "飞书"),
        ("lark", "飞书"),
        ("dingtalk", "钉钉"),
        ("facetime", "FaceTime"),
        ("slack", "Slack"),
        ("discord", "Discord"),
        ("webex", "Webex"),
        ("xinwechat", "微信"),
        ("skype", "Skype"),
        ("chrome", "浏览器"),
        ("safari", "浏览器"),
        ("edge", "浏览器"),
        ("firefox", "浏览器"),
        ("company.thebrowser", "浏览器")
    ]

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let now = CACurrentMediaTime()
        let mic = Self.detectMic()
        let camera = Self.cameraIsRunning()

        if mic.active != micCandidate.active { micCandidate = (mic.active, now) }
        if camera != cameraCandidate.active { cameraCandidate = (camera, now) }

        var next = state
        // 麦克风：开 2s 才算（过滤听写），关 4s 才算（过滤会议软件切换设备时的短暂释放）
        if micCandidate.active != state.micActive && now - micCandidate.since >= (micCandidate.active ? 2 : 4) {
            next.micActive = micCandidate.active
        }
        next.micApp = next.micActive ? (mic.app ?? state.micApp) : nil
        if cameraCandidate.active != state.cameraActive && now - cameraCandidate.since >= (cameraCandidate.active ? 1 : 3) {
            next.cameraActive = cameraCandidate.active
        }
        if next != state {
            state = next
            onChange?(next)
        }
    }

    private static func detectMic() -> (active: Bool, app: String?) {
        if #available(macOS 14.2, *) {
            let ids = AudioProcessProbe.bundleIDs(runningOutput: false)
                .map { $0.lowercased() }
                .filter { id in !ignoredMicTokens.contains { id.contains($0) } }
            guard !ids.isEmpty else { return (false, nil) }
            for id in ids {
                if let match = meetingAppTokens.first(where: { id.contains($0.token) }) {
                    return (true, match.name)
                }
            }
            return (true, nil)
        }
        // 老系统只能看"设备是否被占用"，不分输入输出。AirPods/USB 耳麦输入输出是同一个设备，
        // 听歌也会被当成开麦，这种情况宁可不报
        if let input = AudioProcessProbe.defaultDeviceID(input: true),
           input == AudioProcessProbe.defaultDeviceID(input: false) {
            return (false, nil)
        }
        return (AudioProcessProbe.defaultDeviceIsRunning(input: true), nil)
    }

    /// 任意 CoreMediaIO 视频设备 "running somewhere" 即视为摄像头在用（含 Continuity Camera）。
    private static func cameraIsRunning() -> Bool {
        // 0 = kCMIOObjectPropertyElementMain；直接用数值避免 macOS 11 上的可用性差异
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size) {
            var running: UInt32 = 0
            var outSize: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &outSize, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
