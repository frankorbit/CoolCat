import Foundation

// MARK: - Lock Statistics

/// 最近一段时间（约 5 秒）检测到的鼓点相对小猫节拍网格的统计：衡量"猫的拍子和音乐里的鼓点对得有多齐"。
/// 只反映内部一致性；猫的拍子和你耳朵听到的拍子差多少，要靠跟拍校准来量。
struct BeatLockSummary: Equatable {
    /// 检测到的鼓点数
    var beats: Int
    /// 落在整拍附近（|误差| < 0.3 拍）的鼓点数
    var onGrid: Int
    /// 严丝合缝（|误差| < 0.1 拍）的鼓点数
    var locked: Int
    /// 落在反拍上（0.35…0.5 拍）的鼓点数：多了说明网格可能整体偏了半拍
    var offBeat: Int
    /// 落在整拍附近的鼓点，平均绝对误差（毫秒）：抖动
    var meanAbsMs: Double
    /// 落在整拍附近的鼓点，平均有符号误差（毫秒）：正 = 鼓点比猫的拍晚
    var biasMs: Double
    var bpm: Double

    /// 0…1 锁拍率：严丝合缝的鼓点占全部鼓点的比例
    var lockRatio: Double { beats > 0 ? Double(locked) / Double(beats) : 0 }

    /// 从一批误差（单位：拍，-0.5…0.5）汇总
    init(errors: [Double], bpm: Double) {
        let msPerBeat = 60_000 / max(1, bpm)
        let near = errors.filter { abs($0) < 0.3 }
        beats = errors.count
        onGrid = near.count
        locked = near.filter { abs($0) < 0.1 }.count
        offBeat = errors.filter { abs($0) >= 0.35 }.count
        meanAbsMs = near.isEmpty ? 0 : near.map(abs).reduce(0, +) / Double(near.count) * msPerBeat
        biasMs = near.isEmpty ? 0 : near.reduce(0, +) / Double(near.count) * msPerBeat
        self.bpm = bpm
    }

    var logLine: String {
        String(format: "beats=%d onGrid=%d locked=%d offBeat=%d jitter=%.0fms bias=%+.0fms bpm=%.1f",
               beats, onGrid, locked, offBeat, meanAbsMs, biasMs, bpm)
    }
}

// MARK: - Steadiness

/// 拍子锁稳了没有：只有锁稳了才跳硬卡点的舞步。冲击曲线把"踩在拍上"放大了，也把"踩错拍"放大了，
/// 没锁稳时跳平滑的舒缓舞步，误差被柔和的动作掩盖掉。
///
/// 判断用最近 6 秒：
/// - 准：落在整拍附近的鼓点里，严丝合缝的占多少（不用"占全部鼓点"——反拍上的镲片、拍手很常见，不代表网格错了），加上抖动
/// - 没偏半拍：整拍附近的鼓点不能明显少于反拍上的
/// - 速度不飘：6 秒内 BPM 的起伏
/// 迟滞：连续 3 秒都好才算锁稳；只有明显变差才退回，免得一个样本很少的窗口就来回跳
struct BeatSteadinessTracker {
    static let window = 6.0
    static let settleTime = 3.0

    /// 相位准：鼓点稳稳落在小猫的拍上 → 可以用冲击曲线硬卡点
    private(set) var isSteady = false
    /// 速度稳：BPM 不乱跳 → 可以跳有节奏感的舞步（点头、弹跳……），只是相位不准时动作放软
    private(set) var tempoStable = false
    private var samples: [(time: Double, error: Double)] = []
    private var tempos: [(time: Double, bpm: Double)] = []
    private var goodSince: Double?
    private var tempoGoodSince: Double?

    /// 每检测到一个鼓点：它离小猫最近整拍的误差（拍，-0.5…0.5）
    mutating func record(error: Double, at time: Double) {
        samples.append((time, error))
    }

    /// 每帧调用。live = 拿到了真实音频且拍子锁着（模拟节拍永远不算稳）
    mutating func update(time: Double, bpm: Double, live: Bool) {
        samples.removeAll { time - $0.time > Self.window }
        if time - (tempos.last?.time ?? -1) >= 0.5 { tempos.append((time, bpm)) }
        tempos.removeAll { time - $0.time > Self.window }
        guard live else {
            isSteady = false
            tempoStable = false
            goodSince = nil
            tempoGoodSince = nil
            return
        }
        updateTempoStability(time: time, bpm: bpm)
        guard samples.count >= 6 else {
            isSteady = false
            goodSince = nil
            return
        }
        let errors = samples.map(\.error)
        let near = errors.filter { abs($0) < 0.3 }
        let offBeat = errors.filter { abs($0) >= 0.35 }.count
        let msPerBeat = 60_000 / max(1, bpm)
        let jitterMs = near.isEmpty ? .infinity : near.map(abs).reduce(0, +) / Double(near.count) * msPerBeat
        let precision = near.isEmpty ? 0 : Double(near.filter { abs($0) < 0.1 }.count) / Double(near.count)
        let bpms = tempos.map(\.bpm)
        let drift = ((bpms.max() ?? bpm) - (bpms.min() ?? bpm)) / max(1, bpm)
        let good = jitterMs < 30 && precision >= 0.6 && Double(near.count) >= 0.8 * Double(offBeat) && drift < 0.03
        let bad = jitterMs > 50 || precision < 0.4 || Double(near.count) < 0.5 * Double(offBeat) || drift > 0.05
        if isSteady {
            if bad {
                isSteady = false
                goodSince = nil
            }
        } else if good {
            let since = goodSince ?? time
            goodSince = since
            if time - since >= Self.settleTime { isSteady = true }
        } else {
            goodSince = nil
        }
    }
}

extension BeatSteadinessTracker {
    /// 速度稳定：最近 6 秒 BPM 起伏 < 3% 并保持 3 秒；起伏 > 5% 立刻算不稳
    fileprivate mutating func updateTempoStability(time: Double, bpm: Double) {
        let bpms = tempos.map(\.bpm)
        guard bpms.count >= 6 else {
            tempoStable = false
            tempoGoodSince = nil
            return
        }
        let drift = ((bpms.max() ?? bpm) - (bpms.min() ?? bpm)) / max(1, bpm)
        if tempoStable {
            if drift > 0.05 {
                tempoStable = false
                tempoGoodSince = nil
            }
        } else if drift < 0.03 {
            let since = tempoGoodSince ?? time
            tempoGoodSince = since
            if time - since >= Self.settleTime { tempoStable = true }
        } else {
            tempoGoodSince = nil
        }
    }
}

// MARK: - Tap Calibration

/// 跟拍校准：放着歌，用户跟着鼓点按键；每一下和小猫的节拍网格比，求出"猫比你听到的早/晚多少"。
/// 节奏游戏的标准做法。按拍内相位做圆周平均，所以拍点附近的前后抖动不会因为跨过整拍而抵消。
struct BeatTapCalibrator {
    enum Outcome: Equatable {
        /// 还要再按几下
        case needMore(Int)
        /// 成功：offsetSeconds 正 = 猫比你听到的早，应该再晚这么多；spreadMs 是你按键的离散程度
        case done(offsetSeconds: Double, spreadMs: Double)
        /// 按得太散，量不准
        case inconsistent(spreadMs: Double)
        /// 基本都按在两拍中间：多半是在跟反拍（军鼓、拍手）或者网格偏了半拍，不自动修正
        case offBeat
    }

    /// 一共按几下；前 warmup 下用来找感觉，不计入
    static let taps = 12
    static let warmup = 2
    /// 离散程度超过这个就算不准（人按键本身就有 30–50ms 的抖动）
    static let maxSpreadMs = 70.0

    private(set) var phases: [Double] = []
    private var secondsPerBeat: [Double] = []

    var count: Int { phases.count }

    /// - Parameters:
    ///   - beatPosition: 按下那一刻小猫的节拍位置（单位：拍，可以带整数部分）
    ///   - secondsPerBeat: 当前拍长
    mutating func record(beatPosition: Double, secondsPerBeat spb: Double) {
        phases.append(beatPosition - beatPosition.rounded())
        secondsPerBeat.append(spb)
    }

    mutating func reset() {
        phases.removeAll()
        secondsPerBeat.removeAll()
    }

    var outcome: Outcome {
        guard phases.count >= Self.taps else { return .needMore(Self.taps - phases.count) }
        let used = Array(phases.dropFirst(Self.warmup))
        // 圆周平均：拍内相位映射到圆上
        var sumCos = 0.0, sumSin = 0.0
        for phase in used {
            sumCos += cos(2 * .pi * phase)
            sumSin += sin(2 * .pi * phase)
        }
        let count = Double(used.count)
        let resultant = min(1, hypot(sumCos, sumSin) / count)
        let meanPhase = atan2(sumSin, sumCos) / (2 * .pi)               // -0.5…0.5 拍
        let spb = secondsPerBeat.dropFirst(Self.warmup).reduce(0, +) / count
        // 圆周标准差（拍）→ 毫秒
        let spreadBeats = sqrt(max(0, -2 * log(max(1e-9, resultant)))) / (2 * .pi)
        let spreadMs = spreadBeats * spb * 1000
        if abs(meanPhase) > 0.42 { return .offBeat }
        if spreadMs > Self.maxSpreadMs { return .inconsistent(spreadMs: spreadMs) }
        return .done(offsetSeconds: meanPhase * spb, spreadMs: spreadMs)
    }
}

// MARK: - Per-Device Offset

/// 每个输出设备一份节拍偏移（毫秒）：系统报告的输出延迟经常不准（蓝牙尤其如此），用户校准后按设备记住。
/// 正 = 小猫的拍子往后挪（原来太早），负 = 往前挪。
final class BeatOffsetStore {
    static let shared = BeatOffsetStore()
    static let range: ClosedRange<Double> = -300...500
    private static let key = "CoolCat.BeatOffsetMs"
    private let defaults: UserDefaults
    private var cache: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cache = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
    }

    /// 没拿到设备标识时用这个键
    static func key(for deviceUID: String?) -> String { deviceUID ?? "default" }

    func offsetMs(for deviceUID: String?) -> Double {
        cache[Self.key(for: deviceUID)] ?? 0
    }

    func setOffsetMs(_ value: Double, for deviceUID: String?) {
        let clamped = min(Self.range.upperBound, max(Self.range.lowerBound, value))
        cache[Self.key(for: deviceUID)] = clamped
        defaults.set(cache, forKey: Self.key)
    }
}
