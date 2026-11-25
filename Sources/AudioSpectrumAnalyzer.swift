import Accelerate
import AppKit
import CoreAudio
import Foundation
import os

/// 分析器运行日志：只含采样率/峰值/鼓点数/BPM 等统计量，不含音频内容，标记为 public 便于 `log show` 查看
private let audioLog = Logger(subsystem: "ai.today.coolcat", category: "audio")

// MARK: - Snapshot

/// 主线程每帧读取的一份频谱快照。
struct AudioSpectrumSnapshot {
    static let bandCount = 24

    /// 0..1，按对数频率从低到高（约 40Hz ~ 16kHz）
    var bands = [CGFloat](repeating: 0, count: bandCount)
    /// 0..1 整体响度
    var level: CGFloat = 0
    /// 0..1 低频（鼓点）能量
    var bass: CGFloat = 0
    /// 每检测到一个鼓点 +1；主线程用它判断"刚刚有拍子"
    var beatSerial = 0
    /// 估计的 BPM（至少攒够几拍后才有）
    var bpm: CGFloat?
    /// true = 来自真实音频；false = 没有数据
    var isLive = false
    /// 从 tap 拿到声音到用户真正听到的延迟（秒）：蓝牙/AirPlay 下可达数百毫秒到 2 秒
    var outputLatency: CFTimeInterval = 0
    /// 当前输出设备（用来取这台设备的节拍校准偏移）
    var outputDeviceUID: String?
    var outputDeviceName: String?
    /// 诊断：速度估计的候选（BPM:得分）、选中的速度、相位置信度、节奏特征，写进 --beat-log
    var tempoDebug: String?
    /// 检测延迟：鼓点要进入分析窗口才认得出来，报告时实际已过去约半个窗口 + 半个 hop
    var analysisDelay: CFTimeInterval = 0
    /// 梳状相位估计：此刻距离"最近一个拍点"过去了多少秒（已扣除分析延迟），nil = 还没有可靠估计
    var secondsSinceBeat: CFTimeInterval?
    /// 0..1 拍点相位的置信度（强拍对齐得越干净越高）
    var beatConfidence: CGFloat = 0
    /// 0..1 歌曲的"能量感"：慢、稀疏、节奏模糊 → 0（舒缓）；快、密集、节奏清晰 → 1（激烈）。
    /// 和响度无关（响度是自适应归一化的，安静的歌也会被拉满），约 4 秒平滑
    var arousal: CGFloat = 0.6
    /// 0..1 节奏强度：鼓点网格有多清晰（梳状对比度 + 周期强度）。强 → 多点头、不出舒缓摇晃
    var rhythmStrength: CGFloat = 0.5
}

// MARK: - DSP（纯逻辑，可离线测试）

/// 单声道 PCM → 对数频段 + 鼓点检测 + BPM 估计。非线程安全，由调用方保证串行。
final class SpectrumDSP {
    let sampleRate: Double
    /// 窗口固定约 43ms：48k→2048、96k→4096、24k→1024。这样 hop 时长恒为 ~21ms，
    /// 低频分辨率、平滑系数和鼓点历史长度都不随采样率漂移
    private let fftSize: Int
    private let hopSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringFill = 0
    private var pendingSinceHop = 0

    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var bandEdges: [(lo: Int, hi: Int)] = []
    private var bassRange: (lo: Int, hi: Int) = (1, 2)

    /// 自适应增益：频段 dB 的滑动峰值，慢慢回落
    private var peakDB: Float = -30
    /// 每个频段近 ~2 秒的平均响度（dB）。柱高 = 当前相对平均高了多少，
    /// 平时停在三四成，鼓点/重音一来才往上冲——这样才看得出节奏
    private var bandMeanDB: [Float]?
    /// 每段的倾斜补偿（dB）：音乐能量随频率下降，约 +3dB/倍频程；只用于判断"是不是底噪"
    private var tiltDB: [Float] = []
    private var levelPeakDB: Float = -30
    private var windowed: [Float]
    private var smoothed = [Float](repeating: 0, count: AudioSpectrumSnapshot.bandCount)
    private var level: Float = 0
    private var bass: Float = 0

    // 鼓点检测：逐频点对数谱通量（低频为主、中频为辅）→ 滑动中位数阈值 + 局部最大
    private var onsetRange: (lo: Int, hi: Int) = (1, 2)   // ~30–2000Hz
    private var lowSplit = 2                               // < ~200Hz 记为"低频"
    private var prevLogPower: [Float] = []
    /// 起音强度包络（每个 hop 一个值），约 6 秒，用于中位数阈值和速度自相关
    private var onsetEnvelope: [Float] = []
    /// 只含低频（<200Hz，底鼓/低音鼓）的起音包络：用来判断"鼓点有多强"，钢琴、吉他再规整也不算
    private var lowOnsetEnvelope: [Float] = []
    /// 选中速度的拍长（hop），给低频梳状对比度用
    private var lastChosenLag: Double?
    private var lastLowContrast: Float = 0
    /// 4–12kHz 的起音包络（镲片、军鼓的噪声）：有它才说明是"鼓组"，而不是规整弹奏的钢琴
    private var highOnsetEnvelope: [Float] = []
    private var highRange: (lo: Int, hi: Int) = (1, 2)
    private var prevHighLog: [Float] = []
    private var lastHighContrast: Float = 0
    private let envelopeLength: Int
    private let medianWindow: Int                          // ~0.5 秒
    private var hopsSinceTempo = 0
    private var lastBeatTime: Double = -10
    private var pendingTempo: Float?
    /// 新速度需要连续多少次估计（每次约 0.5 秒）一致才切换
    private var pendingCount = 0
    /// 梳状相位：最近一个拍点在多少秒前 + 置信度
    private var combPhase: (secondsSinceBeat: Double, confidence: Float)?
    /// 近 6 秒的鼓点时刻（算起音密度）
    private var recentBeatTimes: [Double] = []
    /// 最近一次速度估计的周期强度（自相关得分）
    private var pulseClarity: Float = 0
    /// 选中速度的梳状对比度：真正的鼓点网格通常 > 1.8，铺底音色的缓慢起伏只有 1.2~1.5
    private var lastCombContrast: Float = 0
    private var arousal: Float = 0.5
    private var rhythmStrength: Float = 0.5
    private(set) var beatSerial = 0
    private(set) var bpm: Float?
    /// 已处理的样本总数，作为音频时钟
    private var samplesProcessed: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let exponent = max(9, min(14, Int((log2(max(8000, sampleRate) * 0.0427)).rounded())))
        fftSize = 1 << exponent
        hopSize = fftSize / 2
        let hopSeconds = Double(fftSize / 2) / sampleRate
        envelopeLength = Int(8.0 / hopSeconds)
        medianWindow = max(8, Int(0.5 / hopSeconds))
        log2n = vDSP_Length(exponent)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetup 失败：fftSize 必须是 2 的幂")
        }
        fftSetup = setup
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)

        // 对数分布的频段边界（bin 下标），保证每段至少 1 个 bin
        let binHz = sampleRate / Double(fftSize)
        let lo = 40.0, hi = min(16000.0, sampleRate / 2 - binHz)
        let count = AudioSpectrumSnapshot.bandCount
        var previousHi = 1
        for i in 0..<count {
            let f0 = lo * pow(hi / lo, Double(i) / Double(count))
            let f1 = lo * pow(hi / lo, Double(i + 1) / Double(count))
            let b0 = max(previousHi, Int(f0 / binHz))
            let b1 = max(b0 + 1, Int(f1 / binHz))
            bandEdges.append((b0, min(b1, fftSize / 2)))
            tiltDB.append(Float(3 * log2(sqrt(f0 * f1) / lo)))
            previousHi = b1
        }
        bassRange = (max(1, Int(40 / binHz)), max(2, Int(160 / binHz)))
        onsetRange = (max(1, Int(30 / binHz)), min(fftSize / 2, max(3, Int(2000 / binHz))))
        lowSplit = max(onsetRange.lo + 1, Int(200 / binHz))
        prevLogPower = [Float](repeating: -10, count: fftSize / 2)
        highRange = (min(fftSize / 2 - 2, Int(4000 / binHz)), min(fftSize / 2, max(Int(4000 / binHz) + 2, Int(min(12000, sampleRate / 2 - binHz) / binHz))))
        prevHighLog = [Float](repeating: -10, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// 喂入单声道样本；每攒够一个 hop 就分析一次。返回本次调用里是否检测到了鼓点。
    @discardableResult
    func feed(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        var beat = false
        var index = 0
        while index < samples.count {
            let take = min(samples.count - index, fftSize - ringFill)
            // 环形缓冲：满了就整体左移 hop，保留最近 fftSize 个样本
            for j in 0..<take { ring[ringFill + j] = samples[index + j] }
            ringFill += take
            index += take
            pendingSinceHop += take
            samplesProcessed += take
            if ringFill == fftSize {
                if pendingSinceHop >= hopSize {
                    pendingSinceHop = 0
                    if analyze() { beat = true }
                }
                ring.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    memmove(base, base + hopSize, (fftSize - hopSize) * MemoryLayout<Float>.size)
                }
                ringFill = fftSize - hopSize
            }
        }
        return beat
    }

    /// 诊断：最近一次速度估计的候选和结果
    private var lastTempoDebug: String?

    /// 诊断：节奏强度的原始分量（低频/高频/整体梳状对比度、周期强度），用来按真实歌曲标定阈值
    var rhythmFeatures: String {
        String(format: "low=%.2f high=%.2f comb=%.2f clarity=%.2f", lastLowContrast, lastHighContrast, lastCombContrast, pulseClarity)
    }

    func snapshot() -> AudioSpectrumSnapshot {
        var snap = AudioSpectrumSnapshot()
        snap.bands = smoothed.map { CGFloat($0) }
        snap.level = CGFloat(level)
        snap.bass = CGFloat(bass)
        snap.beatSerial = beatSerial
        snap.bpm = bpm.map { CGFloat($0) }
        // 由离线测试标定：鼓点进入窗口最新的部分就会被看到，再加局部最大判定的一个 hop
        snap.analysisDelay = Double(fftSize) / sampleRate
        snap.arousal = CGFloat(arousal)
        snap.rhythmStrength = CGFloat(rhythmStrength)
        snap.tempoDebug = lastTempoDebug.map { $0 + String(format: " conf=%.2f ", combPhase?.confidence ?? 0) + rhythmFeatures }
        if let phase = combPhase {
            snap.secondsSinceBeat = phase.secondsSinceBeat
            snap.beatConfidence = CGFloat(phase.confidence)
        }
        snap.isLive = true
        return snap
    }

    private func analyze() -> Bool {
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                windowed.withUnsafeBufferPointer { input in
                    guard let inputBase = input.baseAddress else { return }
                    inputBase.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer { powerPtr in
                    guard let powerBase = powerPtr.baseAddress else { return }
                    vDSP_zvmags(&split, 1, powerBase, 1, vDSP_Length(fftSize / 2))
                }
            }
        }
        power[0] = 0 // DC 与 Nyquist 打包在一起，直接丢弃

        // 频段 dB
        var bandDB = [Float](repeating: -120, count: bandEdges.count)
        var frameMax: Float = -120
        for (i, edge) in bandEdges.enumerated() {
            var sum: Float = 0
            for bin in edge.lo..<edge.hi { sum += power[bin] }
            let mean = sum / Float(max(1, edge.hi - edge.lo))
            let db = 10 * log10(mean + 1e-12)
            bandDB[i] = db
            frameMax = max(frameMax, db)
        }
        // 峰值跟随：立刻上升，每秒回落约 6dB，让安静段落也有起伏
        let hopSeconds = Float(hopSize) / Float(sampleRate)
        peakDB = max(frameMax, peakDB - 6 * hopSeconds)
        let range: Float = 42
        // 整体静音（暂停、曲间空白、底噪）：所有柱子归零，平均值也冻结，
        // 否则平均值会慢慢降到底噪水平，把底噪"放大"成闪动的柱子
        let frameLevelDB = 20 * log10(rms + 1e-9)
        let frameSilent = frameLevelDB < -55
        // 平均值的时间常数 2 秒；hop 约 21ms
        let meanAlpha = frameSilent ? 0 : min(1, hopSeconds / 2.0)
        var means = bandMeanDB ?? bandDB
        for i in 0..<bandDB.count {
            means[i] += (bandDB[i] - means[i]) * meanAlpha
            // 比全局峰值低 45dB、或绝对电平极低的频段视为底噪，不点亮
            let audible = !frameSilent && bandDB[i] + tiltDB[i] > max(peakDB - 45, -85)
            // 相对平均：+0dB → 0.33，+10dB → 1.0，-5dB → 0
            let v = audible ? max(0, min(1, (bandDB[i] - means[i] + 5) / 15)) : 0
            // 快攻慢放
            // 快攻、较快回落（每 hop 回落 30%），拍与拍之间柱子能落下来
            smoothed[i] = v > smoothed[i] ? smoothed[i] + (v - smoothed[i]) * 0.75 : smoothed[i] * 0.7 + v * 0.3
        }
        bandMeanDB = means

        let levelDB = 20 * log10(rms + 1e-9)
        levelPeakDB = max(levelDB, levelPeakDB - 4 * hopSeconds)
        let silence = levelDB < -60
        level = silence ? level * 0.8 : max(0, min(1, (levelDB - (levelPeakDB - 30)) / 30))

        // 低频能量（给频谱用）
        var bassSum: Float = 0
        for bin in bassRange.lo..<bassRange.hi { bassSum += power[bin] }
        let bassLog = log10(bassSum + 1e-9)
        bass = max(0, min(1, (10 * bassLog - (peakDB - range)) / range))

        // 起音强度：每个频点"比上一帧响了多少"（对数，只取正值），低频权重 1、中频 0.4。
        // 比"低频总能量差"灵敏得多：贝斯线持续占着能量时，底鼓的起音仍然看得出来
        var lowFlux: Float = 0, midFlux: Float = 0
        // 地板：比当前最响频段低 50dB 以下的能量视为底噪。没有它的话，近乎无声的频点
        // 取对数后的随机抖动会被放大成巨大的"上升"，把真正的鼓点淹没
        let floorPower = max(1e-12, pow(10, (peakDB - 50) / 10))
        for bin in onsetRange.lo..<onsetRange.hi {
            let lp = log10(power[bin] + floorPower)
            let rise = max(0, lp - prevLogPower[bin])
            prevLogPower[bin] = lp
            if bin < lowSplit { lowFlux += rise } else { midFlux += rise }
        }
        let lowBins = Float(max(1, lowSplit - onsetRange.lo))
        let midBins = Float(max(1, onsetRange.hi - lowSplit))
        let onset = silence ? 0 : lowFlux / lowBins + 0.4 * midFlux / midBins
        onsetEnvelope.append(onset)
        if onsetEnvelope.count > envelopeLength { onsetEnvelope.removeFirst(onsetEnvelope.count - envelopeLength) }
        lowOnsetEnvelope.append(silence ? 0 : lowFlux / lowBins)
        if lowOnsetEnvelope.count > envelopeLength { lowOnsetEnvelope.removeFirst(lowOnsetEnvelope.count - envelopeLength) }
        var highFlux: Float = 0
        for bin in highRange.lo..<highRange.hi {
            let lp = log10(power[bin] + floorPower)
            highFlux += max(0, lp - prevHighLog[bin])
            prevHighLog[bin] = lp
        }
        highOnsetEnvelope.append(silence ? 0 : highFlux / Float(max(1, highRange.hi - highRange.lo)))
        if highOnsetEnvelope.count > envelopeLength { highOnsetEnvelope.removeFirst(highOnsetEnvelope.count - envelopeLength) }

        updateCombPhase(hopSeconds: Double(hopSeconds))
        hopsSinceTempo += 1
        if hopsSinceTempo >= medianWindow {
            hopsSinceTempo = 0
            estimateTempo(hopSeconds: Double(hopSeconds))
        }

        // 局部最大判定需要看后一帧，所以判定的是"上一帧"：检测延迟多一个 hop（已计入 analysisDelay）
        let n = onsetEnvelope.count
        guard !silence, n > medianWindow + 2 else { return false }
        let candidate = onsetEnvelope[n - 2]
        guard candidate > onsetEnvelope[n - 3], candidate >= onsetEnvelope[n - 1] else { return false }
        let recent = onsetEnvelope[(n - 2 - medianWindow)..<(n - 2)].sorted()
        let median = recent[recent.count / 2]
        let mean = recent.reduce(0, +) / Float(recent.count)
        // 中位数阈值对持续的密集起音（镲片、扫弦）不敏感，只有明显突出的起音才算鼓点
        // 再要求达到最近 ~2 秒最强起音的 30%：抒情段落拍间几乎没起音时，中位数会低到让零碎小起音也过关
        let recentPeak = onsetEnvelope.suffix(medianWindow * 4).max() ?? 0
        let threshold = max(median * 1.5 + mean * 0.15 + 0.004, recentPeak * 0.3)
        let beatTime = Double(samplesProcessed - hopSize) / sampleRate
        // 0.25s 不应期：最快 240 BPM
        updateArousal(now: beatTime, hopSeconds: Double(hopSeconds))
        guard candidate > threshold, beatTime - lastBeatTime > 0.25 else { return false }
        lastBeatTime = beatTime
        beatSerial &+= 1
        recentBeatTimes.append(beatTime)
        return true
    }

    /// 梳状相位估计：以当前拍长为齿距，在最近约 4 秒的起音包络上找"齿尖总能量"最大的对齐位置。
    /// 强拍能量占主导，零碎的十六分音符/切分起音对结果影响很小——比"每个起音都去拽相位"稳得多。
    /// 越近的拍权重越高（0.85^k），这样换段落时相位能跟上
    private func updateCombPhase(hopSeconds: Double) {
        guard let tempo = bpm else { combPhase = nil; return }
        let period = 60.0 / Double(tempo) / hopSeconds          // 拍长（hop，带小数）
        let n = onsetEnvelope.count
        let beatsBack = Int(6.0 * Double(tempo) / 60.0)        // 约 6 秒
        guard period >= 4, n > Int(period * Double(beatsBack + 1)) + 2 else { combPhase = nil; return }
        let offsets = Int(period.rounded(.up))
        var scores = [Float](repeating: 0, count: offsets)
        for o in 0..<offsets {
            var sum: Float = 0, weight: Float = 1
            for k in 0..<beatsBack {
                let idx = n - 1 - o - Int((Double(k) * period).rounded())
                if idx < 0 { break }
                sum += onsetEnvelope[idx] * weight
                weight *= 0.9
            }
            scores[o] = sum
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return }
        let mean = scores.reduce(0, +) / Float(scores.count)
        guard mean > 1e-9 else { combPhase = nil; return }
        // 抛物线插值到亚 hop 精度（环形）
        let l = scores[(best - 1 + offsets) % offsets], m = scores[best], r = scores[(best + 1) % offsets]
        let denom = l - 2 * m + r
        let frac = abs(denom) > 1e-9 ? max(-0.5, min(0.5, 0.5 * (l - r) / denom)) : 0
        // 包络第 n-1 项对应的鼓点，实际发生在约 (fft - hop)/2 之前（窗口里最新的那一段被看到）
        let hopsAgo = Double(best) + Double(frac)
        let envelopeLag = (Double(fftSize) - Double(hopSize)) * 0.5 / sampleRate
        var since = hopsAgo * hopSeconds + envelopeLag
        let beatSeconds = 60.0 / Double(tempo)
        since = since.truncatingRemainder(dividingBy: beatSeconds)
        // 置信度：最佳对齐比平均高出多少（1.0 = 高出一倍）
        let confidence = max(0, min(1, (m / mean - 1) / 1.0))
        combPhase = (since, confidence)
    }

    /// 速度 50%、起音密度 30%、节奏清晰度 20% 合成能量感，时间常数约 4 秒
    private func updateArousal(now: Double, hopSeconds: Double) {
        recentBeatTimes.removeAll { now - $0 > 6 }
        // 周期性很弱 = 没有明确节拍（氛围、自由节奏的弹唱）：速度不可信，整体按舒缓处理
        let rhythmic = pulseClarity >= 0.15 && lastCombContrast >= 1.7
        let tempo = rhythmic ? (bpm.map { max(0, min(1, ($0 - 65) / 60)) } ?? 0.5) : 0
        let density = max(0, min(1, (Float(recentBeatTimes.count) / 6 - 0.8) / 2.2))
        let clarity = max(0, min(1, (pulseClarity - 0.08) / 0.3))
        var raw = 0.5 * tempo + 0.3 * density + 0.2 * clarity
        if !rhythmic { raw = min(raw, 0.3) }
        // 节奏强度 = 有底鼓网格 × 有镲片/军鼓的高频瞬态网格（缺一个都不算"鼓组"），约 2 秒平滑
        // 只看低频（鼓）网格：底鼓清晰 → 强；只有钢琴/吉他规整地弹 → 弱
        let kickF = max(0, min(1, (lastLowContrast - 1.6) / 1.2))
        let kitF = max(0, min(1, (lastHighContrast - 1.3) / 0.8))
        let drumF = kickF * kitF
        let strengthRaw = rhythmic ? 0.75 * drumF + 0.25 * clarity * drumF : 0
        rhythmStrength += (strengthRaw - rhythmStrength) * Float(min(1, hopSeconds / 2))
        arousal += (raw - arousal) * Float(min(1, hopSeconds / 4))
    }

    /// 选速度分两步：
    /// 1. 起音包络的自相关**只负责提名**：取前 3 个周期峰，再加上它们的 ×2、÷2、×1.5、÷1.5（最常见的误判关系）
    /// 2. 每个候选用**梳状对比度**打分（按这个拍长对齐时，齿尖处起音比平均强多少）× 以 120 BPM 为中心的先验。
    ///    真正的拍同时对齐底鼓和军鼓，对比度最高；快一倍会混进较弱的八分音符，2:3 会一半落在反拍，慢一半只采到一半的重音
    private func estimateTempo(hopSeconds: Double) {
        let n = onsetEnvelope.count
        guard n >= Int(4.0 / hopSeconds) else { return }
        let mean = onsetEnvelope.reduce(0, +) / Float(n)
        let centered = onsetEnvelope.map { $0 - mean }
        var energy: Float = 0
        vDSP_svesq(centered, 1, &energy, vDSP_Length(n))
        guard energy > 1e-9 else { return }

        func tempoOf(lag: Double) -> Double { 60.0 / (lag * hopSeconds) }
        let minLag = max(2, Int((60.0 / 190.0) / hopSeconds))
        let maxLag = min(n / 3, Int((60.0 / 55.0) / hopSeconds) + 1)
        guard maxLag > minLag + 2 else { return }
        var acf = [Float](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var dot: Float = 0
            centered.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(n - lag))
            }
            acf[lag] = dot / energy
        }
        // 自相关的局部峰（抛物线插值到小数 lag）
        var peaks: [(lag: Double, score: Float)] = []
        for lag in minLag...maxLag where acf[lag] > acf[lag - 1] && acf[lag] >= acf[lag + 1] && acf[lag] > 0 {
            let l = acf[lag - 1], m = acf[lag], r = acf[lag + 1]
            let denom = l - 2 * m + r
            let offset = abs(denom) > 1e-9 ? Double(max(-0.5, min(0.5, 0.5 * (l - r) / denom))) : 0
            peaks.append((Double(lag) + offset, m))
        }
        peaks.sort { $0.score > $1.score }
        guard let strongest = peaks.first else { pulseClarity = 0; return }
        pulseClarity = strongest.score
        // 周期性太弱（散拍、纯人声）就不给速度
        guard strongest.score > 0.08 else { return }

        var candidates: [Double] = []
        for peak in peaks.prefix(3) {
            for ratio in [1.0, 2.0, 0.5, 1.5, 1.0 / 1.5] {
                let lag = peak.lag * ratio
                let tempo = tempoOf(lag: lag)
                guard tempo >= 60, tempo <= 180,
                      !candidates.contains(where: { abs($0 - lag) / lag < 0.03 }) else { continue }
                candidates.append(lag)
            }
        }
        let warm = Double(n) * hopSeconds >= 7.5
        var best: (lag: Double, score: Double)?
        for lag in candidates {
            guard let contrast = combContrast(period: lag) else { continue }
            let tempo = tempoOf(lag: lag)
            let octaves = log2(tempo / 120.0)
            var score = Double(contrast) * exp(-0.5 * (octaves / 0.9) * (octaves / 0.9))
            // 很弱的连续性偏好，且热身期（前 ~8 秒）不启用，避免把开头的误判粘住
            if warm, let current = bpm {
                let drift = log2(tempo / Double(current))
                score *= 0.9 + 0.1 * exp(-0.5 * (drift / 0.05) * (drift / 0.05))
            }
            if best == nil || score > best!.score { best = (lag, score) }
        }
        guard let chosen = best else { return }
        // 在位优势：已经锁着一个速度时，只有证据够强、新速度明显更好才换。
        // 实测抒情歌（6/8、三连音）里 140/93/70 这几种"数法"得分常常只差几个百分点，
        // 节奏清晰度一低（间奏、鼓停）就会被拽到另一种数法上，小猫的拍子跟着乱跳
        if warm, let current = bpm {
            let currentLag = 60.0 / Double(current) / hopSeconds
            let currentOctaves = log2(Double(current) / 120.0)
            let currentScore = (combContrast(period: currentLag).map(Double.init) ?? 0)
                * exp(-0.5 * (currentOctaves / 0.9) * (currentOctaves / 0.9))
            if !Self.shouldSwitchTempo(current: Double(current), currentScore: currentScore,
                                       candidate: tempoOf(lag: chosen.lag), candidateScore: chosen.score,
                                       clarity: Double(pulseClarity)) {
                lastTempoDebug = String(format: "hold=%.1f (cand %.0f:%.2f vs %.2f, clarity %.2f)",
                                        Double(current), tempoOf(lag: chosen.lag), chosen.score, currentScore, Double(pulseClarity))
                applyTempoEstimate(current)
                return
            }
        }
        // 记下打分最高的几个候选：哪首歌在 2:3、1:2 之间犹豫，一眼能看出来
        var scored: [(bpm: Double, score: Double)] = []
        for lag in candidates {
            guard let contrast = combContrast(period: lag) else { continue }
            let tempo = tempoOf(lag: lag)
            let octaves = log2(tempo / 120.0)
            scored.append((tempo, Double(contrast) * exp(-0.5 * (octaves / 0.9) * (octaves / 0.9))))
        }
        let top = scored.sorted { $0.score > $1.score }.prefix(4)
            .map { String(format: "%.0f:%.2f", $0.bpm, $0.score) }.joined(separator: ",")
        lastTempoDebug = String(format: "pick=%.1f cand=[%@]", tempoOf(lag: chosen.lag), top)
        lastCombContrast = combContrast(period: chosen.lag) ?? 0
        lastChosenLag = chosen.lag
        lastLowContrast = combContrast(period: chosen.lag, envelope: lowOnsetEnvelope) ?? 0
        // 镲片常打在八分、十六分音符上：拍长、1/2、1/4 都试，取最强
        lastHighContrast = [1.0, 0.5, 0.25].compactMap { ratio -> Float? in
            let period = chosen.lag * ratio
            return period >= 2 ? combContrast(period: period, envelope: highOnsetEnvelope) : nil
        }.max() ?? 0
        applyTempoEstimate(Float(tempoOf(lag: chosen.lag)))
    }

    /// 要不要从当前速度换到候选速度。和当前差不到 4% 的算同一个速度（正常微调），直接放行；
    /// 否则要求节奏足够清晰（clarity ≥ 0.15），且候选得分比当前高 12% 以上
    static func shouldSwitchTempo(current: Double, currentScore: Double, candidate: Double, candidateScore: Double,
                                  clarity: Double) -> Bool {
        if abs(candidate - current) / current <= 0.04 { return true }
        guard clarity >= 0.15 else { return false }
        return candidateScore > currentScore * 1.12
    }

    /// 以 period（hop，可带小数）为齿距，在最近约 8 秒包络上找最佳对齐，返回"齿尖平均强度 / 整体平均"
    private func combContrast(period: Double, envelope: [Float]? = nil) -> Float? {
        let onsetEnvelope = envelope ?? self.onsetEnvelope
        let hopSeconds = Double(hopSize) / sampleRate
        let n = onsetEnvelope.count
        let window = min(n, Int(8.0 / hopSeconds))
        let teeth = Int(Double(window - 1) / period)
        guard teeth >= 3 else { return nil }
        let base = n - window
        var overall: Float = 0
        for i in base..<n { overall += max(0, onsetEnvelope[i]) }
        overall /= Float(window)
        guard overall > 1e-9 else { return nil }
        var bestMean: Float = 0
        for o in 0..<Int(period.rounded(.up)) {
            var sum: Float = 0
            for k in 0..<teeth {
                let idx = n - 1 - o - Int((Double(k) * period).rounded())
                if idx < base { break }
                // 齿尖 ±1 hop 取最大，容忍量化抖动
                let lo = max(base, idx - 1), hi = min(n - 1, idx + 1)
                var peak: Float = 0
                for j in lo...hi { peak = max(peak, onsetEnvelope[j]) }
                sum += peak
            }
            bestMean = max(bestMean, sum / Float(teeth))
        }
        return bestMean / overall
    }

    private func applyTempoEstimate(_ estimate: Float) {
        // 迟滞：新估计和当前差 4% 以上时，要连续两次一致才切换（防止在倍频间来回跳）
        // 迟滞：新估计和当前差 4% 以上时，要连续 3 次（约 1.5 秒）一致才切换，防止在 2:3、1:2 间来回跳
        if let current = bpm, abs(estimate - current) / current > 0.04 {
            if let pending = pendingTempo, abs(estimate - pending) / pending < 0.04 {
                pendingCount += 1
                pendingTempo = pending + (estimate - pending) * 0.5
                if pendingCount >= 3 {
                    bpm = pendingTempo
                    pendingTempo = nil
                    pendingCount = 0
                }
            } else {
                pendingTempo = estimate
                pendingCount = 1
            }
        } else if let current = bpm {
            bpm = current + (estimate - current) * 0.3
            pendingTempo = nil
            pendingCount = 0
        } else {
            bpm = estimate
        }
    }
}

// MARK: - System Audio Tap (macOS 14.2+)

/// 只 tap 指定进程（音乐 App）的输出，不碰麦克风、不包含输出设备本身。
/// 聚合设备里只有这个 tap：不会把 AirPods 的麦克风流拉进来，也就不会把它们切到通话模式。
/// 首次使用会触发系统「录制系统音频」授权；被拒绝时回调里只有静音。
@available(macOS 14.2, *)
private final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private(set) var format = AudioStreamBasicDescription()

    enum TapError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): return "\(step) 失败（OSStatus \(status)）"
            }
        }
    }

    /// - Parameters:
    ///   - processes: 要 tap 的 Core Audio 进程对象
    ///   - ioQueue: 音频回调所在的串行队列
    ///   - controlQueue: 格式变化通知投递的队列
    ///   - onFormatChange: tap 格式（采样率/声道）变了，需要重建
    func start(processes: [AudioObjectID], ioQueue: DispatchQueue, controlQueue: DispatchQueue,
               onFormatChange: @escaping () -> Void,
               handler: @escaping (UnsafePointer<AudioBufferList>, AudioStreamBasicDescription) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "CoolCat Visualizer"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("创建音频 tap", status) }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
        guard status == noErr else { stop(); throw TapError.coreAudio("读取 tap 格式", status) }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in onFormatChange() }
        if AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, controlQueue, listener) == noErr {
            formatListener = listener
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CoolCat Visualizer",
            kAudioAggregateDeviceUIDKey: "ai.today.coolcat.visualizer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw TapError.coreAudio("创建聚合设备", status) }

        let tapFormat = format
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inputData, _, _, _ in
            handler(inputData, tapFormat)
        }
        guard status == noErr else { stop(); throw TapError.coreAudio("注册音频回调", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw TapError.coreAudio("启动聚合设备", status) }
    }

    /// 拆除顺序：停 IO → 销毁 IOProc → 销毁聚合设备 → 移除监听 → 销毁 tap
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            if let listener = formatListener {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioTapPropertyFormat,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                // 投递队列必须和注册时一致；这里传 nil 由系统按 block 匹配
                AudioObjectRemovePropertyListenerBlock(tapID, &address, nil, listener)
            }
            AudioHardwareDestroyProcessTap(tapID)
        }
        formatListener = nil
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

// MARK: - Analyzer Facade

/// 对外的分析器。
/// - 主线程：`setWanted(_:)`、`snapshot()`、状态回调
/// - controlQueue：建/拆 tap（同步 Core Audio 调用可能上百毫秒，不能卡渲染）
/// - ioQueue：音频回调与 DSP
final class AudioSpectrumAnalyzer {
    static let shared = AudioSpectrumAnalyzer()

    enum State: Equatable {
        case off
        case starting
        case running
        /// 一直只收到静音：多半没给「录制系统音频」授权。停用到用户重新打开开关或重启 App
        case silentNoPermission
        case unsupported
        case failed(String)
    }

    private(set) var state: State = .off
    /// 主线程回调
    var onStateChange: ((State) -> Void)?

    private let controlQueue = DispatchQueue(label: "ai.today.coolcat.audiotap.control")
    private let ioQueue = DispatchQueue(label: "ai.today.coolcat.audiotap.io", qos: .userInteractive)
    private let lock = NSLock()

    // lock 保护
    private var latest = AudioSpectrumSnapshot()
    private var wantedFlag = false
    private var generation = 0

    // 主线程
    private var permissionLikelyDenied = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    // controlQueue
    private var tapBox: AnyObject?
    private var retryAttempt = 0
    /// controlQueue 写、ioQueue 读，lock 保护
    private var outputLatency: CFTimeInterval = 0
    private var outputDevice: (uid: String, name: String)?

    /// 这台机器上是否曾经收到过真实信号：收到过就说明授权没问题，之后的全零只是"在安静"
    /// （网易云这类 App 暂停/切歌时不关音频流，会持续输出数字静音）
    private var everSeenSignal = UserDefaults.standard.bool(forKey: "CoolCat.AudioCaptureSeenSignal")

    // ioQueue
    private var dsp: SpectrumDSP?
    private var mono: [Float] = []
    private var silentSeconds: Double = 0
    private var reportedSilence = false
    /// 每 5 秒打一条运行摘要，便于用 `log show` 确认是否真的拿到了音频
    private var statsSeconds: Double = 0
    private var statsBeats = 0
    private var statsPeak: Float = 0

    private init() {}

    func snapshot() -> AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 用户在菜单里重新打开"真实音频"：忘掉上次"疑似没授权"的判断，允许再试
    func resetPermissionMemory() {
        permissionLikelyDenied = false
        if state == .silentNoPermission { setState(.off) }
    }

    /// 主线程调用：音乐响起时 true，停播/关开关时 false
    func setWanted(_ wanted: Bool) {
        guard #available(macOS 14.2, *) else {
            if wanted { setState(.unsupported) }
            return
        }
        let effective = wanted && !permissionLikelyDenied
        lock.lock()
        let changed = wantedFlag != effective
        wantedFlag = effective
        generation &+= 1
        let gen = generation
        lock.unlock()
        guard changed else { return }

        if effective {
            observeOutputDeviceChanges()
            setState(.starting)
            controlQueue.async { [weak self] in self?.rebuild(generation: gen) }
        } else {
            removeOutputListener()
            controlQueue.async { [weak self] in self?.teardown() }
            lock.lock()
            latest = AudioSpectrumSnapshot()
            lock.unlock()
            if state != .silentNoPermission && state != .unsupported { setState(.off) }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantedFlag && generation == gen
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        audioLog.notice("analyzer \(String(describing: self.state), privacy: .public) → \(String(describing: new), privacy: .public)")
        state = new
        onStateChange?(new)
    }

    private func publishState(_ new: State) {
        DispatchQueue.main.async { [weak self] in self?.setState(new) }
    }

    // MARK: controlQueue

    private func teardown() {
        if #available(macOS 14.2, *), let tap = tapBox as? SystemAudioTap {
            tap.stop()
        }
        tapBox = nil
    }

    /// 拆掉旧 tap 再按当前音乐进程重建；失败按 2/5/10/20 秒退避重试，直到不再需要
    private func rebuild(generation gen: Int) {
        guard #available(macOS 14.2, *) else { return }
        teardown()
        guard isCurrent(gen) else { return }

        // 新一轮：清空 DSP 与静音检测状态，避免上一首歌的 BPM / "疑似无权限"标记串过来
        ioQueue.sync {
            dsp = nil
            silentSeconds = 0
            reportedSilence = false
            statsSeconds = 0
            statsBeats = 0
            statsPeak = 0
        }
        lock.lock()
        latest = AudioSpectrumSnapshot()
        lock.unlock()

        let processes = AudioProcessProbe.processObjects { MusicMonitor.isMusicBundle($0) }
        audioLog.notice("tapping \(processes.count, privacy: .public) music process(es)")
        do {
            guard !processes.isEmpty else {
                throw SystemAudioTap.TapError.coreAudio("找不到音乐 App 的音频进程", -1)
            }
            let tap = SystemAudioTap()
            try tap.start(
                processes: processes,
                ioQueue: ioQueue,
                controlQueue: controlQueue,
                onFormatChange: { [weak self] in
                    // 跳出监听回调再重建，避免在回调里移除自身监听
                    guard let self else { return }
                    let current = self.currentGeneration()
                    self.controlQueue.async { [weak self] in
                        guard let self, self.isCurrent(current) else { return }
                        self.rebuild(generation: current)
                    }
                },
                handler: { [weak self] buffers, format in
                    self?.process(buffers, format: format)
                }
            )
            tapBox = tap
            retryAttempt = 0
            let latency = AudioProcessProbe.defaultOutputLatency()
            let device = AudioProcessProbe.defaultOutputDevice()
            lock.lock()
            outputLatency = latency
            outputDevice = device
            lock.unlock()
            audioLog.notice("output \(device?.name ?? "?", privacy: .public) latency \(Int(latency * 1000), privacy: .public)ms")
            publishState(.running)
        } catch {
            publishState(.failed(error.localizedDescription))
            let delays: [Double] = [2, 5, 10, 20]
            let delay = delays[min(retryAttempt, delays.count - 1)]
            retryAttempt += 1
            controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.rebuild(generation: gen)
            }
        }
    }

    // MARK: main thread

    /// 切换输出设备（插拔 AirPods / 切 AirPlay）：延迟和 tap 格式可能都变了，重建一次。
    /// 监听器的生命周期跟"需要分析"绑定，不跟 tap 是否建成绑定，所以失败后切回设备也能恢复
    private func observeOutputDeviceChanges() {
        guard outputListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let gen = self.currentGeneration()
            self.controlQueue.async { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.retryAttempt = 0
                self.rebuild(generation: gen)
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            outputListener = block
        }
    }

    private func removeOutputListener() {
        guard let block = outputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        outputListener = nil
    }

    /// 持续静音 → 判定疑似未授权：停掉 tap，不再每首歌都重试
    private func handleLikelyDenied() {
        guard state == .running else { return }
        permissionLikelyDenied = true
        setState(.silentNoPermission)
        lock.lock()
        wantedFlag = false
        generation &+= 1
        latest = AudioSpectrumSnapshot()
        lock.unlock()
        removeOutputListener()
        controlQueue.async { [weak self] in self?.teardown() }
    }

    // MARK: ioQueue

    /// 混成单声道喂给 DSP。只做定长缓冲复用，不在这里加锁之外的阻塞操作
    private func process(_ bufferList: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate > 0 else { return }
        if dsp == nil || dsp?.sampleRate != format.mSampleRate {
            dsp = SpectrumDSP(sampleRate: format.mSampleRate)
        }
        guard let dsp else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var frames = 0
        if nonInterleaved {
            // 每个 buffer 一个声道：逐声道累加后取平均
            guard let first = buffers.first, first.mDataByteSize > 0 else { return }
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            for i in 0..<frames { mono[i] = 0 }
            var used = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<n { mono[i] += data[i] }
                used += 1
            }
            let scale = 1 / Float(max(1, used))
            for i in 0..<frames { mono[i] *= scale }
        } else {
            guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = max(1, Int(buffer.mNumberChannels))
            frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[i * channels + c] }
                mono[i] = sum / Float(channels)
            }
        }
        guard frames > 0 else { return }

        // 连续 8 秒全是 0：tap 被系统静音了（多半没授权）。阈值大于 MusicMonitor 的 3 秒停播防抖
        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(frames))
        if peak == 0 {
            silentSeconds += Double(frames) / format.mSampleRate
            if silentSeconds > 8 && !reportedSilence && !everSeenSignal {
                reportedSilence = true
                DispatchQueue.main.async { [weak self] in self?.handleLikelyDenied() }
            }
        } else {
            silentSeconds = 0
            if !everSeenSignal {
                everSeenSignal = true
                DispatchQueue.main.async {
                    UserDefaults.standard.set(true, forKey: "CoolCat.AudioCaptureSeenSignal")
                }
            }
        }

        let hadBeat = mono.withUnsafeBufferPointer { pointer in
            dsp.feed(UnsafeBufferPointer(rebasing: pointer[0..<frames]))
        }
        statsSeconds += Double(frames) / format.mSampleRate
        statsPeak = max(statsPeak, peak)
        if hadBeat { statsBeats += 1 }
        if statsSeconds >= 5 {
            let bpmText = dsp.bpm.map { String(format: "%.1f", $0) } ?? "-"
            let snapNow = dsp.snapshot()
            let line = String(format: "stats 5s: sr=%.0f peak=%.3f beats=%d bpm=%@ level=%.2f rhythm=%.2f arousal=%.2f %@ silent=%@",
                              format.mSampleRate, statsPeak, statsBeats, bpmText, Double(snapNow.level),
                              Double(snapNow.rhythmStrength), Double(snapNow.arousal), dsp.rhythmFeatures,
                              reportedSilence ? "yes" : "no")
            audioLog.notice("\(line, privacy: .public)")
            statsSeconds = 0
            statsBeats = 0
            statsPeak = 0
        }
        var snap = dsp.snapshot()
        snap.isLive = !reportedSilence
        lock.lock()
        snap.outputLatency = outputLatency
        snap.outputDeviceUID = outputDevice?.uid
        snap.outputDeviceName = outputDevice?.name
        latest = snap
        lock.unlock()
    }
}
