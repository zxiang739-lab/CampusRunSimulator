import Foundation

// MARK: - 海拔字段缺失诊断

/// 海拔字段不可用的原因（F28 / §B.8 / §7.1）。
/// 合规硬约束：GPX 缺 `<ele>`、无剖面、设备气压计不可用时**绝不臆造海拔**，
/// 相关字段按「不可用」处理；仅在用户显式给出参考海拔 `h0` 且来源为用户自定义时沿用该值。
public enum ElevationFieldMissing: String, Codable, Sendable, CaseIterable {
    case gpxMissingEle
    case profileMissing
    case deviceUnavailable

    public var localizedDescription: String {
        switch self {
        case .gpxMissingEle:
            return "GPX 缺少 <ele> 字段，海拔按不可用处理（不臆造）"
        case .profileMissing:
            return "未提供海拔剖面，仅保留用户显式给定的初始海拔 h0"
        case .deviceUnavailable:
            return "设备气压计不可用，海拔字段标注为不可用（不臆造）"
        }
    }

    /// 处理策略：只有「无剖面 + 用户自定义来源 + 显式 h0」才返回该基准值，其余一律 nil。
    public func resolvedAltitude(source: ElevationSource, reference: Double?) -> Double? {
        switch self {
        case .profileMissing:
            guard source == .userDefined, let reference = reference, reference.isFinite else {
                return nil
            }
            return reference
        case .gpxMissingEle, .deviceUnavailable:
            return nil
        }
    }
}

// MARK: - 海拔采样器

/// 海拔剖面 `h(s)` + 误差模型（bias / 慢漂移 / 有界噪声 / 死区 ε）+ gain/loss（F28 / §3.2）。
/// 噪声由 `SeededRandom` 派生的一个确定性相位驱动（唯一随机入口，I9），
/// 采用「时间相关 + 空间相关」的双正弦有界平滑扰动，`altitude` 为纯函数、非 mutating、逐点可复现。
public struct ElevationSampler: Sendable {
    private let profile: ElevationProfile
    private let phase: Double
    private let noiseAmplitudeM: Double
    private let deadbandMeters: Double
    private let temporalCorrelationSeconds: TimeInterval
    private let spatialCorrelationMeters: Double

    public init(profile: ElevationProfile, rng: SeededRandom) {
        var generator = rng
        // 相位来自唯一随机入口；其余误差项全部为 t / s 的确定性函数。
        self.phase = generator.nextUnit() * 2 * Double.pi
        self.profile = profile
        self.noiseAmplitudeM = max(0, profile.errorModel.noiseAmplitudeM)
        self.deadbandMeters = max(0, profile.errorModel.deadbandMeters)
        self.temporalCorrelationSeconds = 12
        self.spatialCorrelationMeters = 250
    }

    /// 在弧长 `s`、时刻 `t` 采样绝对海拔（m）：
    /// `h = h0 + 剖面(s) + bias + drift·t + 有界平滑噪声(s, t)`（§A.3.7 I8）。
    public func altitude(atArcLength s: Double, time t: TimeInterval) -> Double {
        let base = profile.altitude(atArcLength: s)
        let offset = profile.errorModel.deterministicOffset(atTime: t)
        let noise = boundedNoise(atArcLength: s, time: t)
        let value = base + offset + noise
        return value.isFinite ? value : base
    }

    /// 在弧长 `s` 处的局部坡度百分比（供 F25 坡度反馈与 F29 坡度派生共用）。
    /// 无覆盖段时返回 0（平地），绝不臆造坡度。
    public func slope(atArcLength s: Double) -> Double {
        let arc = max(0, s)
        for segment in profile.segments
        where arc >= segment.startArcLengthM && arc <= segment.endArcLengthM {
            return segment.slopePercent
        }
        return 0
    }

    /// 累计爬升 / 下降（死区 ε），委托 BATCH_1 冻结的 `Units.elevationGainLoss`（唯一实现处）。
    public func gainLoss(series: [Double], deadband: Double? = nil) -> (Double, Double) {
        let epsilon = max(0, deadband ?? deadbandMeters)
        return Units.elevationGainLoss(series, deadband: epsilon)
    }

    /// 死区 ε（m），供 F29 逐帧累计与 F37 报告复用。
    public var deadband: Double {
        deadbandMeters
    }

    /// 海拔字段可用性诊断：GPX 来源但无剖面且 h0 为 0 → 视为缺 `<ele>`。
    public var missingField: ElevationFieldMissing? {
        if profile.source == .gpx, profile.segments.isEmpty, profile.initialAltitudeM == 0 {
            return .gpxMissingEle
        }
        if profile.source == .device, profile.segments.isEmpty, profile.initialAltitudeM == 0 {
            return .deviceUnavailable
        }
        if profile.segments.isEmpty, profile.source == .userDefined {
            return .profileMissing
        }
        return nil
    }

    /// 剖面来源（必标来源，禁止臆造）。
    public var source: ElevationSource {
        profile.source
    }

    // MARK: 私有实现

    /// 有界平滑噪声：`|noise| ≤ noiseAmplitudeM`，时间相关 + 空间相关，非逐点白噪声。
    private func boundedNoise(atArcLength s: Double, time t: TimeInterval) -> Double {
        guard noiseAmplitudeM > 0, t.isFinite, s.isFinite else { return 0 }
        let temporal = sin(t / temporalCorrelationSeconds + phase)
        let spatial = sin(s / spatialCorrelationMeters + phase * 0.5)
        return noiseAmplitudeM * (0.6 * temporal + 0.4 * spatial)
    }
}
