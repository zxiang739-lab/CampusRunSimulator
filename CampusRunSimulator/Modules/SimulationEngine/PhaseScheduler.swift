import Foundation

// MARK: - 阶段边界

/// 5 阶段（start / steady / accelerate / decelerate / finish）在时间轴上的边界（F26 / §B.9.2）。
/// `transitionSeconds` 用于阶段起点与上一阶段末速做 smoothstep 混合，保证过渡连续无阶跃。
public struct PhaseBoundary: Sendable, Hashable {
    public let kind: PhaseKind
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let transitionSeconds: TimeInterval
    public let speedFromMps: Double
    public let speedToMps: Double
    public let cadenceFromSpm: Double
    public let cadenceToSpm: Double

    public init(
        kind: PhaseKind,
        startTime: TimeInterval,
        endTime: TimeInterval,
        transitionSeconds: TimeInterval,
        speedFromMps: Double,
        speedToMps: Double,
        cadenceFromSpm: Double,
        cadenceToSpm: Double
    ) {
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.transitionSeconds = max(0, transitionSeconds)
        self.speedFromMps = speedFromMps
        self.speedToMps = speedToMps
        self.cadenceFromSpm = cadenceFromSpm
        self.cadenceToSpm = cadenceToSpm
    }

    /// 阶段时长（s），负值视为 0。
    public var durationSeconds: TimeInterval {
        max(0, endTime - startTime)
    }

    /// 该阶段是否覆盖给定时刻。
    public func contains(_ t: TimeInterval) -> Bool {
        t >= startTime && t < endTime
    }
}

// MARK: - 阶段调度器

/// 5 阶段编排 + 过渡平滑 + 步频曲线 `c(t)` + 坡度联动（F26 / §3.2）。
/// 全部为确定性纯函数，不持有任何随机状态；波动由 F31 的统一 `SmoothNoise` 注入。
public struct PhaseScheduler: Sendable {
    /// 按时间顺序排列的阶段边界。
    public let boundaries: [PhaseBoundary]
    /// 覆盖完整时间轴的总时长，与 `SpeedCurveFactory.effectiveDuration` 同源。
    public let totalDuration: TimeInterval

    private let referenceSpeed: Double
    private let targetCadenceSpm: Double
    private let slopeInfluence: Double

    public init(profile: SimulationProfile) {
        let duration = SpeedCurveFactory.effectiveDuration(profile)
        let baseSpeed = SpeedCurveFactory.referenceSpeed(profile)
        let phases: [SimulationPhase]
        if profile.phases.isEmpty {
            // 空阶段配置：退化为覆盖全时长的单一稳态阶段（真实逻辑，不臆造多阶段）。
            phases = [SimulationPhase(
                kind: .steady,
                durationSeconds: duration,
                speedFromMps: baseSpeed,
                speedToMps: baseSpeed,
                cadenceFromSpm: profile.targetCadenceSpm,
                cadenceToSpm: profile.targetCadenceSpm,
                transitionSeconds: min(10, duration / 10)
            )]
        } else {
            phases = profile.phases
        }

        // 把阶段时长按比例缩放到总时长，保证 5 阶段恰好覆盖完整时间轴。
        let rawSum = phases.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let scale = rawSum > 0 ? duration / rawSum : 1
        var accumulator: TimeInterval = 0
        var built: [PhaseBoundary] = []
        built.reserveCapacity(phases.count)
        for phase in phases {
            let length = max(0, phase.durationSeconds) * scale
            let end = accumulator + length
            let transition = min(max(0, phase.transitionSeconds) * scale, length)
            built.append(PhaseBoundary(
                kind: phase.kind,
                startTime: accumulator,
                endTime: end,
                transitionSeconds: transition,
                speedFromMps: max(0, phase.speedFromMps),
                speedToMps: max(0, phase.speedToMps),
                cadenceFromSpm: max(1, phase.cadenceFromSpm),
                cadenceToSpm: max(1, phase.cadenceToSpm)
            ))
            accumulator = end
        }
        // 浮点累加残差修正：末阶段终点严格等于 totalDuration。
        if let last = built.last {
            built[built.count - 1] = PhaseBoundary(
                kind: last.kind,
                startTime: last.startTime,
                endTime: duration,
                transitionSeconds: last.transitionSeconds,
                speedFromMps: last.speedFromMps,
                speedToMps: last.speedToMps,
                cadenceFromSpm: last.cadenceFromSpm,
                cadenceToSpm: last.cadenceToSpm
            )
        }

        self.boundaries = built
        self.totalDuration = duration
        self.referenceSpeed = baseSpeed > 0 ? baseSpeed : 1
        self.targetCadenceSpm = max(1, profile.targetCadenceSpm)
        self.slopeInfluence = CurveMath.clamp(profile.slopeInfluence, lower: 0, upper: 1)
    }

    /// 给定时刻所属阶段（§3.2 冻结签名）。
    public func resolvePhase(atTime t: TimeInterval) -> PhaseKind {
        for boundary in boundaries where boundary.contains(t) {
            return boundary.kind
        }
        return boundaries.last?.kind ?? .steady
    }

    /// 阶段速度缩放乘数（相对基准速度），阶段内 smoothstep 变化、边界过渡无阶跃。
    public func speedMultiplier(atTime t: TimeInterval) -> Double {
        let speed = phaseSpeed(atTime: t)
        return max(0, speed / referenceSpeed)
    }

    /// 步频曲线 `c(t)`（spm）：阶段内 smoothstep 变化 + 坡度联动（上坡略升、下坡略降）。
    public func cadence(atTime t: TimeInterval, slopePercent: Double) -> Double {
        guard let entry = boundary(at: t), entry.boundary.durationSeconds > 0 else {
            return targetCadenceSpm
        }
        let local = (t - entry.boundary.startTime) / entry.boundary.durationSeconds
        let eased = CurveMath.smoothstep(local)
        let base = entry.boundary.cadenceFromSpm
            + (entry.boundary.cadenceToSpm - entry.boundary.cadenceFromSpm) * eased
        let adjustment = CurveMath.clamp(
            1 + slopeInfluence * slopePercent / 100,
            lower: 0.85,
            upper: 1.15
        )
        return max(1, base * adjustment)
    }

    /// 覆盖的 5 阶段种类（供 UI 展示与测试断言）。
    public var phaseKinds: [PhaseKind] {
        boundaries.map(\.kind)
    }

    // MARK: 私有实现

    /// 阶段内目标速度：从 `speedFrom` 到 `speedTo` 的 smoothstep 插值，
    /// 起点 `transitionSeconds` 内与上一阶段末速混合，消除阶跃。
    private func phaseSpeed(atTime t: TimeInterval) -> Double {
        guard let entry = boundary(at: t), entry.boundary.durationSeconds > 0 else {
            return boundaries.last?.speedToMps ?? referenceSpeed
        }
        let boundary = entry.boundary
        let local = (t - boundary.startTime) / boundary.durationSeconds
        let eased = CurveMath.smoothstep(local)
        var value = boundary.speedFromMps
            + (boundary.speedToMps - boundary.speedFromMps) * eased
        if boundary.transitionSeconds > 0,
           t < boundary.startTime + boundary.transitionSeconds,
           entry.index > 0 {
            let previous = boundaries[entry.index - 1]
            let ratio = CurveMath.smoothstep(
                (t - boundary.startTime) / boundary.transitionSeconds
            )
            value = previous.speedToMps + (value - previous.speedToMps) * ratio
        }
        return max(0, value)
    }

    /// 二分 / 线性定位给定时刻所在阶段。
    private func boundary(at t: TimeInterval) -> (index: Int, boundary: PhaseBoundary)? {
        guard !boundaries.isEmpty else { return nil }
        let time = max(0, t)
        var lower = 0
        var upper = boundaries.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if time < boundaries[middle].startTime {
                upper = middle
            } else if time >= boundaries[middle].endTime {
                lower = middle + 1
            } else {
                return (middle, boundaries[middle])
            }
        }
        let index = min(lower, boundaries.count - 1)
        return (index, boundaries[index])
    }
}
