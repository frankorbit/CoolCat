import Foundation

/// 从改名前的 KuroCat（bundle ID com.chanke.kurocat）迁移到 CoolCat。只在新版首次启动时跑一次：
/// - 偏好设置：旧域里所有 `KuroCat.*` 复制为 `CoolCat.*`（皮肤、开关、击键统计、KPM 纪录……），新值已存在则不覆盖
/// - 开机自启：删掉指向旧 KuroCat.app 的 LaunchAgent，并标记由 AppDelegate 用新路径重建
/// Claude Code hook 不在这里处理：`ClaudeHookInstaller.repairIfOutdated()` 能识别旧名字的 hook 并重写。
enum LegacyMigration {
    static let legacyBundleID = "com.chanke.kurocat"
    static let legacyName = "KuroCat"
    static let autoStartPendingKey = "CoolCat.AutoStartMigrationPending"
    private static let doneKey = "CoolCat.MigratedFromKuroCat"
    private static let permissionScopedKeys: Set<String> = [
        "DidRequestInputMonitoring", "AudioCaptureExplained", "AudioCaptureSeenSignal"
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        if let legacy = defaults.persistentDomain(forName: legacyBundleID) {
            let oldPrefix = legacyName + "."
            var copied = 0
            for (key, value) in legacy where key.hasPrefix(oldPrefix) {
                let suffix = String(key.dropFirst(oldPrefix.count))
                // 权限是跟着包标识走的：新包标识要重新授权，这些"已申请过/已确认授权"的标记不能带过来
                guard !permissionScopedKeys.contains(suffix) else { continue }
                let newKey = "CoolCat." + suffix
                guard defaults.object(forKey: newKey) == nil else { continue }
                defaults.set(value, forKey: newKey)
                copied += 1
            }
            NSLog("CoolCat: migrated %d settings from %@", copied, legacyBundleID)
        }

        let fm = FileManager.default
        let oldAgent = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyBundleID).plist")
        if fm.fileExists(atPath: oldAgent.path) {
            do {
                try fm.removeItem(at: oldAgent)
                defaults.set(true, forKey: autoStartPendingKey)
            } catch {
                NSLog("CoolCat: failed to remove legacy LaunchAgent: %@", error.localizedDescription)
            }
        }
    }
}
