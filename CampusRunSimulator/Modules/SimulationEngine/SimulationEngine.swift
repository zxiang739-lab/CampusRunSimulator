import Foundation

// MARK: - 生成结果状态

/// 引擎生成结果状态（F31）：把 `throws` 收敛为可检查的值，供 F55 / F60 / F61 使用。
public enum GenerationOutcome: Sendable {
    case accepted(result: SimulationResult, effectiveSeed: UInt64)
    case rejected(error: AppError, failedInvariants: [InvariantID])

    /// 是否通过 I1–I10 并被接受。
    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// 实际使用的种子（空种子自动生成后回传上层持久化）。
    public var effectiveSeed: UInt64? {
        if case .accepted(_, let seed) = self { return seed }
        return nil
    }

    /// 被拒绝时的违规不变量编号。
    public var failedInvariants: [InvariantID] {
        if case .rejected(_, let ids) = self { return ids }
        return []
    }

    /// 被拒绝时的错误。
    public var rejectionError: AppError? {
        if case .rejected(let error, _) = self { return error }
        return nil
    }
}

// MARK: - 引擎编排

/// 仿真引擎编排（F31 / §3.2 / §4.1）。
///
/// 合规硬约束：本文件只 import Foundation，**不引入**任何定位管理器、健康数据框架、
/// 网络栈、`LocationAndSensors` / `Repository` / `UI`；不申请任何权限；距离口径统一由
/// `Units`（Core 层）封装的位置值对象提供，绝不持有系统定位服务。生成顺序严格为：
/// `参数校验 → 主干量生成 → 组装 → I1–I10 → 拒绝 / 返回`。
public actor DefaultSimulationEngine: SimulationEngine {

    /// 测试数据固定时间基准（2026-01-01 00:00:00 UTC）。
    /// 固定 epoch 保证同种子两次生成的 `TrackPoint.timestamp` 浮点全等（I10 / AC-D5）。
    private static let simulationEpoch = Date(timeIntervalSince1970: 1_767_225_600)

    /// 内部生成产物（同一 assembler 的帧、会话、点，避免重复组装引入差异）。
    private struct GenerationBundle: Sendable {
        let frames: [SimulationFrame]
        let session: RunSession
        let points: [TrackPoint]
    }

    public init() {}

    // MARK: SimulationEngine 协议

    /// 生成并校验一次仿真；I1–I10 未全通过即抛 `AppError.invariantFailed` 拒绝生成。
    public func generate(
        profile: SimulationProfile,
        route: Route
    ) async throws -> SimulationResult {
        let effective = resolveSeed(profile)
        let first = try buildFrames(profile: effective, route: route)

        // I10 引擎级保证：同 profile + 同 seed 连续两次生成，逐字段浮点全等。
        let second = try buildFrames(profile: effective, route: route)
        guard framesAreIdentical(first.frames, second.frames) else {
            await AuditLogger.shared.logRejection(
                sessionId: first.session.id,
                origin: .simulated,
                kind: AuditEvent.Kind.generationRejected,
                error: AppError.invariantFailed([.I10])
            )
            throw AppError.invariantFailed([.I10])
        }

        let report = InvariantValidator().validate(
            session: first.session,
            points: first.points,
            profile: effective
        )
        guard report.isCompleteAndPassed else {
            await AuditLogger.shared.logRejection(
                sessionId: first.session.id,
                origin: .simulated,
                kind: AuditEvent.Kind.generationRejected,
                error: AppError.invariantFailed(report.failedIDs)
            )
            throw AppError.invariantFailed(report.failedIDs)
        }

        await AuditLogger.shared.log(AuditEvent(
            sessionId: first.session.id,
            dataOrigin: .simulated,
            kind: AuditEvent.Kind.simulationGenerated,
            count: first.points.count,
            resultCode: "ok"
        ))
        return SimulationResult(session: first.session, points: first.points, report: report)
    }

    /// 预览：只返回 `[SimulationFrame]`，不落盘、不写审计、不触发任何权限。
    public func preview(
        profile: SimulationProfile,
        route: Route
    ) async throws -> [SimulationFrame] {
        let effective = resolveSeed(profile)
        let bundle = try buildFrames(profile: effective, route: route)
        guard !bundle.frames.isEmpty else {
            throw AppError.parameterConflict(reason: "预览未产生任何采样帧，请检查时长与采样率")
        }
        return bundle.frames
    }

    /// 参数冲突校验（§4.1 / SIM-05）：
    /// ① 基础参数；② 空种子；③ 路线点数；④ 采样点数上限；
    /// ⑤ 速度曲线端点 / 自定义曲线 / 「时长×速度 vs 设定总距离」；
    /// ⑥ 「时长×速度 vs 自由路线长度」。**冲突时明确报错，绝不静默择一**。
    /// 参数校验（`SimulationEngine` 协议的同步方法，Swift 6.2 严格并发下必须 `nonisolated`）。
    /// 方法体只依赖入参 `profile` / `route` 与 `SpeedCurveFactory`（enum 静态方法）、
    /// `PhaseScheduler`（`Sendable` struct）、`AppConstants`（`static let`），**不读写 actor 存储属性**，
    /// 因此标记 `nonisolated` 不引入数据竞争（QA CI 第 1 轮编译错误 3）。
    public nonisolated func validateParameters(profile: SimulationProfile, route: Route) throws {
        guard profile.isBasicallyValid else {
            throw AppError.parameterConflict(
                reason: "仿真配置基础参数非法（采样率 / 目标步频 / 参考步幅 / 阶段 / 自定义曲线）"
            )
        }
        guard profile.seed != 0 else {
            throw AppError.seedMissing
        }
        guard route.orderedPoints().count >= 2 else {
            throw AppError.parameterConflict(reason: "路线至少需要 2 个有序点才能做弧长参数化")
        }

        let duration = SpeedCurveFactory.effectiveDuration(profile)
        let deltaT = profile.sampleIntervalSeconds
        guard deltaT > 0, deltaT.isFinite, duration > 0, duration.isFinite else {
            throw AppError.parameterConflict(reason: "总时长与采样间隔 Δt 必须为有限正数")
        }
        let requested = Int((duration / deltaT).rounded(.down)) + 1
        if requested > AppConstants.maxTrackPoints {
            throw AppError.tooManyPoints(
                requested: requested,
                limit: AppConstants.maxTrackPoints
            )
        }

        let scheduler = PhaseScheduler(profile: profile)
        let sampleCount = 64
        var multiplierSum = 0.0
        for index in 0..<sampleCount {
            let t = duration * Double(index) / Double(sampleCount - 1)
            multiplierSum += scheduler.speedMultiplier(atTime: t)
        }
        let averageMultiplier = multiplierSum / Double(sampleCount)

        // 无外部剖面时按平地处理；冲突校验只关心速度量级，不臆造坡度。
        let curve = SpeedCurveFactory.make(profile.modelType, profile: profile)
        let issues = SpeedCurveFactory.validateConstraints(
            curve,
            profile: profile,
            averagePhaseMultiplier: averageMultiplier
        )
        if !issues.isEmpty {
            throw AppError.parameterConflict(reason: issues.joined(separator: "；"))
        }

        let estimated = SpeedCurveFactory.integratedDistance(
            curve,
            duration: duration,
            step: max(0.05, deltaT)
        ) * max(0, averageMultiplier)
        // 自由路线不可重复铺圈 / 折返：估算距离超过用户声明的路线长度即冲突。
        if route.routeType == .free, route.totalDistanceM > 0,
           estimated > route.totalDistanceM * 1.02 {
            throw AppError.parameterConflict(reason: String(
                format: "时长×速度估算 %.1f m 超出自由路线长度 %.1f m，请缩短时长 / 降低速度或改用环形 / 折返路线",
                estimated, route.totalDistanceM
            ))
        }
    }

    /// 非抛出入口：把生成结果收敛为 `GenerationOutcome`，并把有效种子回传上层持久化。
    public func outcome(
        for profile: SimulationProfile,
        route: Route
    ) async -> GenerationOutcome {
        do {
            let result = try await generate(profile: profile, route: route)
            return .accepted(result: result, effectiveSeed: resolveSeed(profile).seed)
        } catch let error as AppError {
            let failed: [InvariantID]
            if case .invariantFailed(let ids) = error {
                failed = ids
            } else {
                failed = []
            }
            return .rejected(error: error, failedInvariants: failed)
        } catch {
            return .rejected(
                error: AppError.parameterConflict(reason: "生成失败：\(error.localizedDescription)"),
                failedInvariants: []
            )
        }
    }

    // MARK: 主干量生成 → 组装

    /// 构建全部帧（纯确定性，可重复调用以做 I10 复现比对）。
    private func buildFrames(
        profile: SimulationProfile,
        route: Route
    ) throws -> GenerationBundle {
        try validateParameters(profile, route: route)
        let duration = SpeedCurveFactory.effectiveDuration(profile)
        let deltaT = profile.sampleIntervalSeconds
        let count = Int((duration / deltaT).rounded(.down)) + 1
        let arc = RouteArcLength(route: route)

        // 唯一随机入口：所有子流都由 profile.seed 经主 RNG 确定性派生（I9 / I10）。
        var master = SeededRandom(seed: profile.seed)
        let noiseSeed = master.nextUInt64()
        let elevationSeed = master.nextUInt64()
        var noise = SmoothNoise(
            rng: SeededRandom(seed: noiseSeed),
            correlationSeconds: 8,
            amplitude: 1
        )
        let sampler = ElevationSampler(
            profile: route.elevationProfile,
            rng: SeededRandom(seed: elevationSeed)
        )
        let curve = SpeedCurveFactory.make(
            profile.modelType,
            profile: profile,
            slopeAtArc: { arcLength in sampler.slope(atArcLength: arcLength) }
        )
        let scheduler = PhaseScheduler(profile: profile)
        let assembler = TrackPointAssembler(
            sessionId: OriginID.makeID(
                .simulated,
                suffix: "run_\(profile.seed)_\(profile.id)"
            ),
            startTime: Self.simulationEpoch,
            deadband: route.elevationProfile.errorModel.deadbandMeters,
            routeId: route.id,
            simulationProfileId: profile.id,
            note: "seed=\(profile.seed)；示例假设配置，测试数据 / SIMULATED"
        )

        var frames: [SimulationFrame] = []
        frames.reserveCapacity(count)
        var previousArc = 0.0
        let referenceSpeed = SpeedCurveFactory.referenceSpeed(profile)

        for index in 0..<count {
            let t = Double(index) * deltaT
            // 同一扰动共享给 v 与 c（时间相关、有界、相关扰动，C-03）。
            let disturbance = noise.value(atTime: t)
            // 坡度反馈使用上一帧弧长（滞后一帧，保证反馈单向可追溯，I8）。
            let slopeArc = previousArc + referenceSpeed * deltaT
            let slope = sampler.slope(atArcLength: slopeArc)
            let baseSpeed = curve.speed(atTime: t)
            let speed = max(
                0,
                baseSpeed
                    * scheduler.speedMultiplier(atTime: t)
                    * (1 + profile.noiseAmplitude * disturbance)
            )
            let cadence = max(
                1,
                scheduler.cadence(atTime: t, slopePercent: slope)
                    * (1 + profile.noiseAmplitude * 0.5 * disturbance)
            )
            let currentArc = previousArc + speed * deltaT
            let altitude = sampler.altitude(atArcLength: currentArc, time: t)
            let frame = try assembler.assemble(
                t: t,
                arc: arc,
                speed: speed,
                cadence: cadence,
                altitude: altitude,
                origin: .simulated
            )
            frames.append(frame)
            previousArc = frame.arcLengthM
        }

        let (session, points) = assembler.finalize(frames)
        return GenerationBundle(frames: frames, session: session, points: points)
    }

    // MARK: 空种子处理

    /// `seed == 0` 视为「空种子」：由 profile 标识经 FNV-1a 确定性派生一个新种子，
    /// 不调用系统随机、不用 UUID 参与数值；新种子通过 `GenerationOutcome.effectiveSeed`
    /// 与 `RunSession.note` 回传上层写回 `SimulationProfile` 持久化（§7.3-4）。
    private func resolveSeed(_ profile: SimulationProfile) -> SimulationProfile {
        guard profile.seed == 0 else { return profile }
        let digest = fnv1a(profile.id + "|" + profile.name)
        let derived = SeededRandom.derive(0x5EED_5EED_5EED_5EED, from: digest)
        return profile.withSeed(derived == 0 ? 20_261_108 : derived)
    }

    /// FNV-1a 64 位字符串哈希（纯确定性，不依赖任何系统随机源）。
    private func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    // MARK: 逐字段浮点全等比对（I10）

    /// 两次生成的帧逐字段浮点全等比较（不使用近似容差，AC-D5 要求浮点全等）。
    private func framesAreIdentical(
        _ lhs: [SimulationFrame],
        _ rhs: [SimulationFrame]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var index = 0
        while index < lhs.count {
            let a = lhs[index]
            let b = rhs[index]
            if a.id != b.id
                || a.index != b.index
                || a.t != b.t
                || a.arcLengthM != b.arcLengthM
                || a.speedMps != b.speedMps
                || a.cadenceSpm != b.cadenceSpm
                || a.altitudeM != b.altitudeM
                || a.coordinate.latitude != b.coordinate.latitude
                || a.coordinate.longitude != b.coordinate.longitude
                || a.courseDegrees != b.courseDegrees
                || a.deltaDistanceM != b.deltaDistanceM
                || a.cumulativeDistanceM != b.cumulativeDistanceM
                || a.instantPaceSecPerKm != b.instantPaceSecPerKm
                || a.avgPaceSecPerKm != b.avgPaceSecPerKm
                || a.strideLengthM != b.strideLengthM
                || a.cumulativeSteps != b.cumulativeSteps
                || a.elevationGainSoFarM != b.elevationGainSoFarM
                || a.elevationLossSoFarM != b.elevationLossSoFarM
                || a.slopePercent != b.slopePercent
                || a.horizontalAccuracyM != b.horizontalAccuracyM
                || a.verticalAccuracyM != b.verticalAccuracyM
                || a.speedAccuracyMps != b.speedAccuracyMps
                || a.dataOrigin != b.dataOrigin {
                return false
            }
            index += 1
        }
        return true
    }
}
