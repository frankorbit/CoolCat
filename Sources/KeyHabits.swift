import Foundation
import QuartzCore

/// 从按键流里识别出的"键盘习惯"事件，小猫据此做小反应。
enum KeyHabitEvent: Equatable {
    /// 短时间狂按退格：改来改去，冒汗
    case backspaceStorm
    /// ⌘S / ⌘⇧S：盖"已保存"章
    case save
    /// ⌘⇧3 / ⌘⇧4 / ⌘⇧5：截图，比耶
    case screenshot
    /// 本次连打的 KPM 刚超过历史最高：先戴上皇冠
    case recordBurstStarted
    /// 连打结束，结算新纪录
    case newKPMRecord(Int)
}

/// 纯逻辑的按键习惯识别器：不依赖 UI，便于单测。所有时间用 `CACurrentMediaTime()` 同一时基。
struct KeyHabitDetector {
    static let bestKPMKey = "CoolCat.BestKPM"

    /// 1.6 秒内退格 ≥ 6 次算"狂删"
    private let backspaceWindow: CFTimeInterval = 1.6
    private let backspaceThreshold = 6
    private let backspaceCooldown: CFTimeInterval = 25
    /// 连续 ⌘S 不要每次都盖章
    private let saveCooldown: CFTimeInterval = 1.5
    /// 低于这个 KPM 不算破纪录，避免第一天随便打几下就戴皇冠
    private let recordFloor = 240
    /// 连打峰值回落到一半以下视为这一轮结束
    private let burstEndRatio = 0.5

    private var backspaceTimes: [CFTimeInterval] = []
    private var lastBackspaceStorm: CFTimeInterval = -.infinity
    private var lastSave: CFTimeInterval = -.infinity
    private(set) var bestKPM: Int
    private var burstPeak = 0
    private var inRecordBurst = false

    init(bestKPM: Int = UserDefaults.standard.integer(forKey: KeyHabitDetector.bestKPMKey)) {
        self.bestKPM = bestKPM
    }

    /// `held` 为按下这个键时仍按住的所有键（含它自己）。
    mutating func keyDown(_ key: PhysicalKey, held: Set<PhysicalKey>, now: CFTimeInterval) -> KeyHabitEvent? {
        let command = held.contains(.leftCommand) || held.contains(.rightCommand)
        let shift = held.contains(.leftShift) || held.contains(.rightShift)

        if command && shift && [.k3, .k4, .k5].contains(key) {
            return .screenshot
        }
        if command && key == .s {
            guard now - lastSave >= saveCooldown else { return nil }
            lastSave = now
            return .save
        }
        if key == .backspace || key == .forwardDelete {
            backspaceTimes.append(now)
            backspaceTimes.removeAll { now - $0 > backspaceWindow }
            if backspaceTimes.count >= backspaceThreshold && now - lastBackspaceStorm >= backspaceCooldown {
                lastBackspaceStorm = now
                backspaceTimes.removeAll()
                return .backspaceStorm
            }
        }
        return nil
    }

    /// 周期性喂入当前 KPM（约每 0.25s）。超过纪录时先返回 `.recordBurstStarted`，
    /// 这一轮连打结束后返回 `.newKPMRecord(峰值)` 并持久化。
    mutating func sampleKPM(_ kpm: Int) -> KeyHabitEvent? {
        if inRecordBurst {
            burstPeak = max(burstPeak, kpm)
            guard Double(kpm) < Double(burstPeak) * burstEndRatio else { return nil }
            inRecordBurst = false
            bestKPM = burstPeak
            UserDefaults.standard.set(bestKPM, forKey: Self.bestKPMKey)
            return .newKPMRecord(burstPeak)
        }
        guard kpm >= recordFloor, kpm > bestKPM else { return nil }
        inRecordBurst = true
        burstPeak = kpm
        return .recordBurstStarted
    }
}
