import Foundation

/// 6 种速度模型（§B.9.1）。
public enum SpeedModelType: String, Codable, Sendable, CaseIterable {
    case steady
    case interval
    case accelerate
    case decelerate
    case elevation
    case custom

    public var localizedDescription: String {
        switch self {
        case .steady: return "匀速"
        case .interval: return "间歇"
        case .accelerate: return "渐进加速"
        case .decelerate: return "渐进减速"
        case .elevation: return "坡度联动"
        case .custom: return "自定义曲线"
        }
    }
}

/// 5 阶段（§B.9.2）。
public enum PhaseKind: String, Codable, Sendable, CaseIterable {
    case start
    case steady
    case accelerate
    case decelerate
    case finish

    public var localizedDescription: String {
        switch self {
        case .start: return "起步"
        case .steady: return "稳态"
        case .accelerate: return "加速"
        case .decelerate: return "减速"
        case .finish: return "冲刺收尾"
        }
    }
}

/// 仿真阶段（§3.2）。
public struct SimulationPhase: Identifiable, Codable, Sendable {
    public let id: String
    public let kind: PhaseKind
    public let durationSeconds: TimeInterval
    public let speedFromMps: Double
    public let speedToMps: Double
    public let cadenceFromSpm: Double
    public let cadenceToSpm: Double
    public let transitionSeconds: TimeInterval

    public init(
        id: String = UUID().uuidString,
        kind: PhaseKind,
        durationSeconds: TimeInterval,
        speedFromMps: Double,
        speedToMps: Double,
        cadenceFromSpm: Double,
        cadenceToSpm: Double,
        transitionSeconds: TimeInterval = 0
    ) {
        self.id = id
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.speedFromMps = speedFromMps
        self.speedToMps = speedToMps
        self.cadenceFromSpm = cadenceFromSpm
        self.cadenceToSpm = cadenceToSpm
        self.transitionSeconds = transitionSeconds
    }

    /// 阶段参数是否合法（时长 > 0、速度非负、步频为正、过渡不超过时长）。
    public var isValid: Bool {
        durationSeconds > 0
            && speedFromMps >= 0 && speedToMps >= 0
            && cadenceFromSpm > 0 && cadenceToSpm > 0
            && transitionSeconds >= 0 && transitionSeconds <= durationSeconds
    }
}

/// 自定义曲线的一个采样点（CSV 导入，见 §8 A10）。
public struct CustomSpeedSample: Codable, Sendable, Hashable {
    public let timeSeconds: TimeInterval
    public let speedMps: Double

    public init(timeSeconds: TimeInterval, speedMps: Double) {
        self.timeSeconds = timeSeconds
        self.speedMps = speedMps
    }
}

/// 自定义速度曲线：按时间线性插值，端点钳制，绝不外推。
public struct CustomSpeedCurve: Codable, Sendable {
    public let samples: [CustomSpeedSample]

    public init(samples: [CustomSpeedSample] = []) {
        self.samples = samples.sorted { $0.timeSeconds < $1.timeSeconds }
    }

    /// 曲线是否可用（至少两个点、时间严格递增、速度非负有限）。
    public var isValid: Bool {
        guard samples.count >= 2 else { return false }
        var index = 1
        while index < samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if current.timeSeconds <= previous.timeSeconds { return false }
            if !current.speedMps.isFinite || current.speedMps < 0 { return false }
            index += 1
        }
        return samples[0].speedMps.isFinite && samples[0].speedMps >= 0
    }

    /// 线性插值 `v(t)`；超出端点时钳制到端点值。
    public func speed(atTime t: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        if t <= first.timeSeconds { return first.speedMps }
        if t >= last.timeSeconds { return last.speedMps }
        var lower = 0
        var upper = samples.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if samples[middle].timeSeconds <= t {
                lower = middle
            } else {
                upper = middle
            }
        }
        let a = samples[lower]
        let b = samples[upper]
        let span = b.timeSeconds - a.timeSeconds
        guard span > 0 else { return a.speedMps }
        let ratio = (t - a.timeSeconds) / span
        return a.speedMps + (b.speedMps - a.speedMps) * ratio
    }

    /// 曲线覆盖的总时长。
    public var durationSeconds: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timeSeconds - first.timeSeconds)
    }
}

/// 仿真配置（§3.2）。`dataOrigin` 恒 `.simulated`：
/// 初始化器内部强制赋值，并自定义 `init(from:)` 使 JSON 无法覆盖来源。
public struct SimulationProfile: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let modelType: SpeedModelType
    public let phases: [SimulationPhase]
    public let targetCadenceSpm: Double
    public let referenceStrideLengthM: Double
    public let noiseAmplitude: Double
    public let slopeInfluence: Double
    public let sampleRateHz: Double
    public let seed: UInt64
    public let totalDurationSeconds: TimeInterval?
    public let totalDistanceMeters: Double?
    public let customCurve: CustomSpeedCurve?
    public let dataOrigin: DataOrigin

    private enum CodingKeys: String, CodingKey {
        case id, name, modelType, phases, targetCadenceSpm, referenceStrideLengthM
        case noiseAmplitude, slopeInfluence, sampleRateHz, seed
        case totalDurationSeconds, totalDistanceMeters, customCurve, dataOrigin
    }

    /// 完整初始化器：**不接受 `dataOrigin` 参数**，内部强制 `.simulated`。
    public init(
        id: String = UUID().uuidString,
        name: String,
        modelType: SpeedModelType = .steady,
        phases: [SimulationPhase] = [],
        targetCadenceSpm: Double = 170,
        referenceStrideLengthM: Double = 1.1,
        noiseAmplitude: Double = 0.02,
        slopeInfluence: Double = 0,
        sampleRateHz: Double = AppConstants.defaultSampleRateHz,
        seed: UInt64,
        totalDurationSeconds: TimeInterval? = nil,
        totalDistanceMeters: Double? = nil,
        customCurve: CustomSpeedCurve? = nil
    ) {
        self.id = id
        self.name = name
        self.modelType = modelType
        self.phases = phases
        self.targetCadenceSpm = targetCadenceSpm
        self.referenceStrideLengthM = referenceStrideLengthM
        self.noiseAmplitude = noiseAmplitude
        self.slopeInfluence = slopeInfluence
        self.sampleRateHz = sampleRateHz
        self.seed = seed
        self.totalDurationSeconds = totalDurationSeconds
        self.totalDistanceMeters = totalDistanceMeters
        self.customCurve = customCurve
        self.dataOrigin = .simulated
    }

    /// 解码时强制 `.simulated`，忽略 JSON 中的 `dataOrigin`，防止来源被外部注入。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        modelType = try container.decode(SpeedModelType.self, forKey: .modelType)
        phases = try container.decode([SimulationPhase].self, forKey: .phases)
        targetCadenceSpm = try container.decode(Double.self, forKey: .targetCadenceSpm)
        referenceStrideLengthM = try container.decode(Double.self, forKey: .referenceStrideLengthM)
        noiseAmplitude = try container.decode(Double.self, forKey: .noiseAmplitude)
        slopeInfluence = try container.decode(Double.self, forKey: .slopeInfluence)
        sampleRateHz = try container.decode(Double.self, forKey: .sampleRateHz)
        seed = try container.decode(UInt64.self, forKey: .seed)
        totalDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .totalDurationSeconds)
        totalDistanceMeters = try container.decodeIfPresent(Double.self, forKey: .totalDistanceMeters)
        customCurve = try container.decodeIfPresent(CustomSpeedCurve.self, forKey: .customCurve)
        dataOrigin = .simulated
    }

    /// 编码时始终写出 `.simulated`（导出带 SIMULATED 标记）。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(modelType, forKey: .modelType)
        try container.encode(phases, forKey: .phases)
        try container.encode(targetCadenceSpm, forKey: .targetCadenceSpm)
        try container.encode(referenceStrideLengthM, forKey: .referenceStrideLengthM)
        try container.encode(noiseAmplitude, forKey: .noiseAmplitude)
        try container.encode(slopeInfluence, forKey: .slopeInfluence)
        try container.encode(sampleRateHz, forKey: .sampleRateHz)
        try container.encode(seed, forKey: .seed)
        try container.encodeIfPresent(totalDurationSeconds, forKey: .totalDurationSeconds)
        try container.encodeIfPresent(totalDistanceMeters, forKey: .totalDistanceMeters)
        try container.encodeIfPresent(customCurve, forKey: .customCurve)
        try container.encode(DataOrigin.simulated, forKey: .dataOrigin)
    }

    /// 采样间隔 `Δt = 1 / sampleRateHz`，恒定且 > 0。
    public var sampleIntervalSeconds: TimeInterval {
        guard sampleRateHz > 0, sampleRateHz.isFinite else { return 1 }
        return 1 / sampleRateHz
    }

    /// 参数基础校验（更严格的冲突校验由 F31 完成）。
    public var isBasicallyValid: Bool {
        guard sampleRateHz > 0, sampleRateHz <= AppConstants.maximumSampleRateHz,
              targetCadenceSpm > 0, referenceStrideLengthM > 0,
              noiseAmplitude >= 0 else { return false }
        if modelType == .custom, customCurve?.isValid != true { return false }
        return phases.allSatisfy(\.isValid)
    }

    /// 由给定种子派生一个新配置（种子变更不触碰 `dataOrigin`）。
    public func withSeed(_ newSeed: UInt64) -> SimulationProfile {
        SimulationProfile(
            id: id,
            name: name,
            modelType: modelType,
            phases: phases,
            targetCadenceSpm: targetCadenceSpm,
            referenceStrideLengthM: referenceStrideLengthM,
            noiseAmplitude: noiseAmplitude,
            slopeInfluence: slopeInfluence,
            sampleRateHz: sampleRateHz,
            seed: newSeed,
            totalDurationSeconds: totalDurationSeconds,
            totalDistanceMeters: totalDistanceMeters,
            customCurve: customCurve
        )
    }

    /// 默认示例配置（全部为示例假设值，5 阶段、固定种子）。
    public static func makeDefault(seed: UInt64 = 20_261_108) -> SimulationProfile {
        let phases: [SimulationPhase] = [
            SimulationPhase(kind: .start, durationSeconds: 60, speedFromMps: 1.8, speedToMps: 2.6,
                            cadenceFromSpm: 150, cadenceToSpm: 165, transitionSeconds: 10),
            SimulationPhase(kind: .steady, durationSeconds: 600, speedFromMps: 2.6, speedToMps: 2.6,
                            cadenceFromSpm: 165, cadenceToSpm: 168, transitionSeconds: 10),
            SimulationPhase(kind: .accelerate, durationSeconds: 120, speedFromMps: 2.6, speedToMps: 3.2,
                            cadenceFromSpm: 168, cadenceToSpm: 176, transitionSeconds: 15),
            SimulationPhase(kind: .decelerate, durationSeconds: 120, speedFromMps: 3.2, speedToMps: 2.5,
                            cadenceFromSpm: 176, cadenceToSpm: 164, transitionSeconds: 15),
            SimulationPhase(kind: .finish, durationSeconds: 60, speedFromMps: 2.5, speedToMps: 3.0,
                            cadenceFromSpm: 164, cadenceToSpm: 175, transitionSeconds: 10)
        ]
        return SimulationProfile(
            name: "示例假设配置 A",
            modelType: .steady,
            phases: phases,
            targetCadenceSpm: 168,
            referenceStrideLengthM: 1.05,
            noiseAmplitude: 0.02,
            slopeInfluence: 0.1,
            sampleRateHz: AppConstants.defaultSampleRateHz,
            seed: seed,
            totalDurationSeconds: 960,
            totalDistanceMeters: nil,
            customCurve: nil
        )
    }
}
