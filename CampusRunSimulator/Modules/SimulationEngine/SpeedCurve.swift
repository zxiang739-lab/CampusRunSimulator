import Foundation

// MARK: - 曲线数学工具

/// 曲线共用数学工具（跨 F25 / F26 复用的唯一实现，避免重复实现）。
public enum CurveMath {
    /// 三次 smoothstep：`3x² − 2x³`，端点一阶导为 0，用于无阶跃过渡。
    public static func smoothstep(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        let clamped = min(max(x, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// 把 `value` 钳制到 `[lower, upper]`（非有限值回落到 lower）。
    public static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

// MARK: - 速度曲线协议

/// 速度曲线 `v(t)` 的统一契约（§3.2 / F25）。返回绝对速度 m/s，必须确定性、非负、有限。
public protocol SpeedCurve: Sendable {
    func speed(atTime t: TimeInterval) -> Double
}

// MARK: - 6 种速度模型

/// ① 稳定匀速：恒定 `v0`，叠加的小幅有界平滑波动由引擎统一注入（曲线本身纯确定性）。
public struct SteadyCurve: SpeedCurve {
    private let baseSpeed: Double

    public init(baseSpeed: Double) {
        self.baseSpeed = CurveMath.clamp(baseSpeed, lower: 0, upper: 12)
    }

    public func speed(atTime t: TimeInterval) -> Double {
        baseSpeed
    }
}

/// ② 间歇：快段 / 慢段交替，方波经 smoothstep 过渡，无阶跃（§B.9.1）。
public struct IntervalCurve: SpeedCurve {
    private let baseSpeed: Double
    private let duration: TimeInterval
    private let fastFactor: Double
    private let slowFactor: Double
    private let transitionSeconds: TimeInterval
    private let segmentCount: Int

    public init(
        baseSpeed: Double,
        duration: TimeInterval,
        segmentCount: Int = 6,
        fastFactor: Double = 1.25,
        slowFactor: Double = 0.78
    ) {
        let resolvedDuration = duration > 0 ? duration : 600
        let resolvedSegmentCount = max(2, segmentCount)
        let segmentLength = resolvedDuration / Double(resolvedSegmentCount)
        self.baseSpeed = CurveMath.clamp(baseSpeed, lower: 0, upper: 12)
        self.duration = resolvedDuration
        self.segmentCount = resolvedSegmentCount
        self.fastFactor = fastFactor
        self.slowFactor = slowFactor
        self.transitionSeconds = min(6, segmentLength * 0.2)
    }

    public func speed(atTime t: TimeInterval) -> Double {
        let time = max(0, t)
        let segmentLength = duration / Double(segmentCount)
        let rawIndex = Int((time / segmentLength).rounded(.down))
        let index = min(max(0, rawIndex), segmentCount - 1)
        let local = time - Double(index) * segmentLength
        let isFast = index % 2 == 0
        let currentFactor = isFast ? fastFactor : slowFactor
        let previousFactor = index > 0 ? (isFast ? slowFactor : fastFactor) : currentFactor
        var factor = currentFactor
        if transitionSeconds > 0, local < transitionSeconds, index > 0 {
            factor = previousFactor
                + (currentFactor - previousFactor) * CurveMath.smoothstep(local / transitionSeconds)
        }
        // 收尾段平滑回落到基准速度，保证末端无跳变。
        if time > duration - transitionSeconds, transitionSeconds > 0 {
            let ratio = CurveMath.smoothstep((time - (duration - transitionSeconds)) / transitionSeconds)
            factor += (1 - factor) * ratio
        }
        return max(0, baseSpeed * factor)
    }
}

/// ③ 渐加速：`v(t)` 从 `vStart` 单调平滑增至 `vEnd`（smoothstep 缓动）。
public struct AccelerateCurve: SpeedCurve {
    private let baseSpeed: Double
    private let duration: TimeInterval

    public init(baseSpeed: Double, duration: TimeInterval) {
        self.baseSpeed = CurveMath.clamp(baseSpeed, lower: 0, upper: 12)
        self.duration = duration > 0 ? duration : 600
    }

    public func speed(atTime t: TimeInterval) -> Double {
        let progress = CurveMath.smoothstep(max(0, t) / duration)
        return max(0, baseSpeed * (0.75 + 0.5 * progress))
    }
}

/// ④ 渐减速：`v(t)` 从 `vStart` 单调平滑降至 `vEnd`。
public struct DecelerateCurve: SpeedCurve {
    private let baseSpeed: Double
    private let duration: TimeInterval

    public init(baseSpeed: Double, duration: TimeInterval) {
        self.baseSpeed = CurveMath.clamp(baseSpeed, lower: 0, upper: 12)
        self.duration = duration > 0 ? duration : 600
    }

    public func speed(atTime t: TimeInterval) -> Double {
        let progress = CurveMath.smoothstep(max(0, t) / duration)
        return max(0, baseSpeed * (1.25 - 0.5 * progress))
    }
}

/// ⑤ 上下坡联动：`v(t)` 由坡度剖面反馈（上坡降速、下坡升速，系数可配）。
/// 坡度查询由 F31 用 `ElevationSampler.slope(atArcLength:)` 注入；
/// 未提供真实剖面时 `slopeAtArc` 返回 0，按平地处理，**绝不臆造坡度**。
public struct ElevationFeedbackCurve: SpeedCurve {
    private let baseSpeed: Double
    private let influence: Double
    private let approximateArcPerSecond: Double
    private let slopeAtArc: @Sendable (Double) -> Double

    public init(
        baseSpeed: Double,
        influence: Double,
        approximateArcPerSecond: Double,
        slopeAtArc: @escaping @Sendable (Double) -> Double
    ) {
        self.baseSpeed = CurveMath.clamp(baseSpeed, lower: 0, upper: 12)
        self.influence = CurveMath.clamp(influence, lower: 0, upper: 1)
        self.approximateArcPerSecond = max(0, approximateArcPerSecond)
        self.slopeAtArc = slopeAtArc
    }

    public func speed(atTime t: TimeInterval) -> Double {
        let arc = approximateArcPerSecond * max(0, t)
        let slope = slopeAtArc(arc)
        let factor = CurveMath.clamp(1 - influence * slope / 100, lower: 0.5, upper: 1.5)
        return max(0, baseSpeed * factor)
    }
}

/// ⑥ 自定义曲线：委托 BATCH_1 冻结的 `CustomSpeedCurve.speed(atTime:)`（端点钳制、绝不外推）。
public struct CustomCurve: SpeedCurve {
    private let samples: [CustomSpeedSample]

    public init(curve: CustomSpeedCurve) {
        self.samples = curve.samples
    }

    public func speed(atTime t: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        if t <= first.timeSeconds { return max(0, first.speedMps) }
        if t >= last.timeSeconds { return max(0, last.speedMps) }
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
        guard span > 0 else { return max(0, a.speedMps) }
        let ratio = (t - a.timeSeconds) / span
        return max(0, a.speedMps + (b.speedMps - a.speedMps) * ratio)
    }
}

// MARK: - 工厂与约束校验

/// 速度曲线工厂（§3.2 冻结签名 `make(_:profile:)` + 带坡度注入的重载）。
public enum SpeedCurveFactory {
    /// 由参考步幅与目标步频反算的基准速度：`v = L · c / 60`（§A.3.4）。
    /// 与 `L = 60v/c` 互为逆运算，保证步频×步幅×速度三角关系自洽。
    public static func referenceSpeed(_ profile: SimulationProfile) -> Double {
        let stride = max(0, profile.referenceStrideLengthM)
        let cadence = max(0, profile.targetCadenceSpm)
        let speed = stride * cadence / Units.secondsPerMinute
        return speed.isFinite ? max(0, speed) : 0
    }

    /// 有效总时长：`totalDurationSeconds` 优先，其次 5 阶段时长之和，最后回退 600 s。
    /// **与 `PhaseScheduler.totalDuration` 共用此实现**（单一真值源）。
    public static func effectiveDuration(_ profile: SimulationProfile) -> TimeInterval {
        if let declared = profile.totalDurationSeconds, declared > 0, declared.isFinite {
            return declared
        }
        let phasesSum = profile.phases.reduce(0) { $0 + max(0, $1.durationSeconds) }
        if phasesSum > 0, phasesSum.isFinite {
            return phasesSum
        }
        return 600
    }

    /// 冻结签名：无外部坡度剖面时按平地处理（slope = 0），不臆造海拔 / 坡度。
    public static func make(_ type: SpeedModelType, profile: SimulationProfile) -> SpeedCurve {
        make(type, profile: profile, slopeAtArc: { _ in 0 })
    }

    /// F31 使用：注入 `ElevationSampler.slope(atArcLength:)` 形成坡度 → 速度单向反馈。
    public static func make(
        _ type: SpeedModelType,
        profile: SimulationProfile,
        slopeAtArc: @escaping @Sendable (Double) -> Double
    ) -> SpeedCurve {
        let base = referenceSpeed(profile)
        let duration = effectiveDuration(profile)
        switch type {
        case .steady:
            return SteadyCurve(baseSpeed: base)
        case .interval:
            return IntervalCurve(baseSpeed: base, duration: duration)
        case .accelerate:
            return AccelerateCurve(baseSpeed: base, duration: duration)
        case .decelerate:
            return DecelerateCurve(baseSpeed: base, duration: duration)
        case .elevation:
            return ElevationFeedbackCurve(
                baseSpeed: base,
                influence: profile.slopeInfluence,
                approximateArcPerSecond: base,
                slopeAtArc: slopeAtArc
            )
        case .custom:
            if let curve = profile.customCurve, curve.isValid {
                return CustomCurve(curve: curve)
            }
            // 自定义曲线非法时退化为匀速基线（不臆造曲线），由 F31 前置校验拦截。
            return SteadyCurve(baseSpeed: base)
        }
    }

    /// 用中点法数值积分 `∫v(t)dt` 得到「时长 × 速度」估算总距离（参数冲突校验基础）。
    public static func integratedDistance(
        _ curve: SpeedCurve,
        duration: TimeInterval,
        step: TimeInterval
    ) -> Double {
        guard duration > 0, duration.isFinite, step > 0, step.isFinite else { return 0 }
        var distance = 0.0
        var t = 0.0
        var guardCount = 0
        while t < duration, guardCount < AppConstants.maxTrackPoints {
            let dt = min(step, duration - t)
            let speed = curve.speed(atTime: t + dt / 2)
            if speed.isFinite {
                distance += max(0, speed) * dt
            }
            t += dt
            guardCount += 1
        }
        return distance
    }

    /// 端点与总时长 / 总距离约束校验（§B.9.1「自定义曲线需额外校验」）。
    /// 返回冲突原因列表；空列表表示通过。
    public static func validateConstraints(
        _ curve: SpeedCurve,
        profile: SimulationProfile,
        averagePhaseMultiplier: Double = 1
    ) -> [String] {
        var issues: [String] = []
        let duration = effectiveDuration(profile)
        let step = max(0.05, profile.sampleIntervalSeconds)
        let startSpeed = curve.speed(atTime: 0)
        let endSpeed = curve.speed(atTime: duration)
        if !startSpeed.isFinite || startSpeed < 0 {
            issues.append("速度曲线起点非法（v(0)=\(startSpeed)）")
        }
        if !endSpeed.isFinite || endSpeed < 0 {
            issues.append("速度曲线终点非法（v(T)=\(endSpeed)）")
        }
        // 计入 5 阶段调制的平均乘数，使「时长×速度」估算与引擎真实输出同口径。
        let distance = integratedDistance(curve, duration: duration, step: step)
            * max(0, averagePhaseMultiplier)
        if let declared = profile.totalDistanceMeters, declared > 0 {
            let relative = abs(distance - declared) / declared
            if relative > 0.05 {
                issues.append(String(
                    format: "时长×速度估算距离 %.1f m 与设定总距离 %.1f m 偏差 %.1f%%",
                    distance, declared, relative * 100
                ))
            }
        }
        if profile.modelType == .custom, let custom = profile.customCurve {
            if !custom.isValid {
                issues.append("自定义曲线采样点非法（少于 2 点 / 时间非严格递增 / 速度负值）")
            } else if abs(custom.durationSeconds - duration) / max(1, duration) > 0.05 {
                issues.append(String(
                    format: "自定义曲线覆盖时长 %.1f s 与总时长 %.1f s 不一致",
                    custom.durationSeconds, duration
                ))
            }
        }
        return issues
    }
}
