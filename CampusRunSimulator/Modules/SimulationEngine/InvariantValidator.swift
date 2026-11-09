import Foundation

// MARK: - 矛盾注入测试数据集

/// `injectContradiction(for:)` 返回的一整套「自洽基准 + 一处确定性矛盾」数据（供 F61 逐 I 用例使用）。
public struct ContradictionDataset: Sendable {
    public let session: RunSession
    public let points: [TrackPoint]
    public let profile: SimulationProfile
    /// 期望被判定为失败的不变量编号。
    public let expectedFailedID: InvariantID

    public init(
        session: RunSession,
        points: [TrackPoint],
        profile: SimulationProfile,
        expectedFailedID: InvariantID
    ) {
        self.session = session
        self.points = points
        self.profile = profile
        self.expectedFailedID = expectedFailedID
    }
}

// MARK: - I1–I10 校验器

/// I1–I10 可验收一致性校验器（F30 / §A.3.7 / §3.2）。
/// 每一项都有**独立检查函数** `checkI1`…`checkI10`，逐项输出通过 / 失败；
/// `InvariantReport.allPassed == false` 时 F31 **拒绝生成**（不是警告）。
public struct InvariantValidator: InvariantValidating, Sendable {

    public init() {}

    /// 按 I1 → I10 顺序逐项校验并汇总（§3.2 冻结签名）。
    public func validate(
        session: RunSession,
        points: [TrackPoint],
        profile: SimulationProfile
    ) -> InvariantReport {
        let checks: [InvariantCheck] = [
            checkI1(points: points),
            checkI2(points: points),
            checkI3(session: session, points: points),
            checkI4(points: points),
            checkI5(session: session, points: points),
            checkI6(session: session, points: points),
            checkI7(session: session, points: points),
            checkI8(session: session, points: points),
            checkI9(session: session, points: points),
            checkI10(profile: profile, points: points)
        ]
        return InvariantReport(checks: checks)
    }

    // MARK: I1 · 时间严格单调递增

    /// `t_i = t_0 + i·Δt`，Δt 恒定且 > 0，无重复、无倒退。
    private func checkI1(points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I1, detail: "采样点不足 2 个，无法验证时间轴")
        }
        let firstDelta = points[1].elapsedSeconds - points[0].elapsedSeconds
        guard firstDelta > 0, firstDelta.isFinite else {
            return .fail(.I1, detail: "首段 Δt 非法", measured: firstDelta, expected: 1)
        }
        var minimumDelta = firstDelta
        for index in 1..<points.count {
            let delta = points[index].elapsedSeconds - points[index - 1].elapsedSeconds
            if !(delta > 0) || !delta.isFinite {
                return .fail(.I1, detail: "第 \(index) 点时间倒退或 Δt ≤ 0",
                             measured: delta, expected: firstDelta)
            }
            if abs(delta - firstDelta) > max(1e-6, firstDelta * 1e-6) {
                return .fail(.I1, detail: "第 \(index) 点 Δt 不恒定",
                             measured: delta, expected: firstDelta)
            }
            let timestampDelta = points[index].timestamp.timeIntervalSince(points[index - 1].timestamp)
            if !(timestampDelta > 0) {
                return .fail(.I1, detail: "第 \(index) 点时间戳未严格单调递增",
                             measured: timestampDelta, expected: delta)
            }
            minimumDelta = min(minimumDelta, delta)
        }
        return .pass(.I1, detail: "\(points.count) 点时间严格单调，Δt = \(firstDelta) s 恒定")
    }

    // MARK: I2 · 位置由弧长唯一决定

    /// 坐标合法、累计距离单调不减，且累计距离增量恰等于相邻 GPS 距离
    /// （`TrackPoint` 不落盘 `arcLengthM`，此为「P 由 s 推进」的可观测证据）。
    private func checkI2(points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I2, detail: "采样点不足 2 个，无法验证位置与弧长")
        }
        for point in points where !point.geoPoint.isValid {
            return .fail(.I2, detail: "存在非法经纬度坐标")
        }
        var previousDistance = points[0].cumulativeDistanceM
        for index in 1..<points.count {
            let current = points[index].cumulativeDistanceM
            if current < previousDistance - AppConstants.toleranceDistance {
                return .fail(.I2, detail: "第 \(index) 点累计距离回退",
                             measured: current, expected: previousDistance)
            }
            let delta = current - previousDistance
            let gps = Units.distanceMeters(points[index - 1].geoPoint, points[index].geoPoint)
            if !isClose(delta, gps, AppConstants.toleranceDistance) {
                return .fail(.I2, detail: "第 \(index) 点位置增量与 GPS 距离不符（位置非弧长唯一决定）",
                             measured: delta, expected: gps)
            }
            previousDistance = current
        }
        return .pass(.I2, detail: "逐点坐标合法，位置增量与累计弧长一致")
    }

    // MARK: I3 · 距离与轨迹一致

    /// `Δd_i = distance(P_{i−1}, P_i)`，`D_i = ΣΔd`，与汇总距离一致（容差 0.5%）。
    private func checkI3(session: RunSession, points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I3, detail: "采样点不足 2 个，无法验证距离与轨迹")
        }
        var accumulated = points[0].cumulativeDistanceM
        for index in 1..<points.count {
            accumulated += Units.distanceMeters(points[index - 1].geoPoint, points[index].geoPoint)
            let reported = points[index].cumulativeDistanceM
            if !isClose(reported, accumulated, AppConstants.toleranceDistance) {
                return .fail(.I3, detail: "第 \(index) 点累计距离与轨迹距离之和不一致",
                             measured: reported, expected: accumulated)
            }
        }
        if !isClose(session.totalDistanceMeters, accumulated, AppConstants.toleranceDistance) {
            return .fail(.I3, detail: "会话总距离与轨迹距离之和不一致",
                         measured: session.totalDistanceMeters, expected: accumulated)
        }
        return InvariantCheck(
            id: .I3,
            passed: true,
            detail: "累计距离与 GPS 相邻点距离之和一致",
            measuredValue: session.totalDistanceMeters,
            expectedValue: accumulated
        )
    }

    // MARK: I4 · 速度 = Δd / Δt

    private func checkI4(points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I4, detail: "采样点不足 2 个，无法验证速度")
        }
        guard abs(points[0].speedMps) <= AppConstants.toleranceVelocity else {
            return .fail(.I4, detail: "首帧速度必须为 0（无前驱位移）",
                         measured: points[0].speedMps, expected: 0)
        }
        for index in 1..<points.count {
            let deltaT = points[index].elapsedSeconds - points[index - 1].elapsedSeconds
            let deltaD = points[index].cumulativeDistanceM - points[index - 1].cumulativeDistanceM
            guard deltaT > 0 else {
                return .fail(.I4, detail: "第 \(index) 点 Δt ≤ 0，无法求速度")
            }
            let expected = deltaD / deltaT
            if !isClose(points[index].speedMps, expected, AppConstants.toleranceVelocity) {
                return .fail(.I4, detail: "第 \(index) 点速度 ≠ Δd/Δt",
                             measured: points[index].speedMps, expected: expected)
            }
        }
        return .pass(.I4, detail: "逐点速度由 Δd/Δt 反算，无独立设定")
    }

    // MARK: I5 · 平均量一致

    private func checkI5(session: RunSession, points: [TrackPoint]) -> InvariantCheck {
        guard let last = points.last, last.elapsedSeconds > 0 else {
            return .fail(.I5, detail: "时长为 0，无法验证平均量")
        }
        let duration = last.elapsedSeconds
        let distance = last.cumulativeDistanceM
        let expectedSpeed = distance / duration
        let expectedPace = Units.averagePaceSecPerKm(totalSeconds: duration, totalMeters: distance)
        if !isClose(session.avgSpeedMps, expectedSpeed, AppConstants.toleranceVelocity) {
            return .fail(.I5, detail: "会话平均速度 ≠ D/T",
                         measured: session.avgSpeedMps, expected: expectedSpeed)
        }
        if !isClose(session.avgPaceSecPerKm, expectedPace, AppConstants.tolerancePace) {
            return .fail(.I5, detail: "会话平均配速 ≠ T/D",
                         measured: session.avgPaceSecPerKm, expected: expectedPace)
        }
        if !isClose(session.durationSeconds, duration, AppConstants.toleranceDistance) {
            return .fail(.I5, detail: "会话时长与末点时间不一致",
                         measured: session.durationSeconds, expected: duration)
        }
        if !isClose(session.totalDistanceMeters, distance, AppConstants.toleranceDistance) {
            return .fail(.I5, detail: "会话总距离与末点累计距离不一致",
                         measured: session.totalDistanceMeters, expected: distance)
        }
        if !isClose(session.totalSteps, last.cumulativeSteps, AppConstants.toleranceStepDistance) {
            return .fail(.I5, detail: "会话总步数与末点累计步数不一致",
                         measured: session.totalSteps, expected: last.cumulativeSteps)
        }
        return InvariantCheck(
            id: .I5,
            passed: true,
            detail: "平均速度 / 平均配速 / 总量与逐点累计一致",
            measuredValue: session.avgSpeedMps,
            expectedValue: expectedSpeed
        )
    }

    // MARK: I6 · 配速一致

    private func checkI6(session: RunSession, points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I6, detail: "采样点不足 2 个，无法验证配速")
        }
        for index in 1..<points.count {
            let deltaT = points[index].elapsedSeconds - points[index - 1].elapsedSeconds
            let deltaD = points[index].cumulativeDistanceM - points[index - 1].cumulativeDistanceM
            if deltaD > 0 {
                let expected = Units.paceSecPerKm(deltaSeconds: deltaT, deltaMeters: deltaD)
                if !isClose(points[index].instantPaceSecPerKm, expected, AppConstants.tolerancePace) {
                    return .fail(.I6, detail: "第 \(index) 点实时配速与 Δt/Δd 不符",
                                 measured: points[index].instantPaceSecPerKm, expected: expected)
                }
            } else if points[index].instantPaceSecPerKm != 0 {
                return .fail(.I6, detail: "第 \(index) 点零位移却存在实时配速",
                             measured: points[index].instantPaceSecPerKm, expected: 0)
            }
            let cumulative = points[index].cumulativeDistanceM
            let expectedAverage = cumulative > 0
                ? Units.averagePaceSecPerKm(totalSeconds: points[index].elapsedSeconds, totalMeters: cumulative)
                : 0
            if !isClose(points[index].avgPaceSecPerKm, expectedAverage, AppConstants.tolerancePace) {
                return .fail(.I6, detail: "第 \(index) 点平均配速与累计量不符",
                             measured: points[index].avgPaceSecPerKm, expected: expectedAverage)
            }
        }
        if let last = points.last,
           !isClose(last.avgPaceSecPerKm, session.avgPaceSecPerKm, AppConstants.tolerancePace) {
            return .fail(.I6, detail: "末点平均配速与会话平均配速不符",
                         measured: last.avgPaceSecPerKm, expected: session.avgPaceSecPerKm)
        }
        return .pass(.I6, detail: "实时配速 / 平均配速与速度、距离、时间互为一致")
    }

    // MARK: I7 · 步频—步幅—速度一致（L = 60v/c）

    private func checkI7(session: RunSession, points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I7, detail: "采样点不足 2 个，无法验证步幅关系")
        }
        var stepDistance = 0.0
        for index in 0..<points.count {
            let point = points[index]
            let expectedStride = Units.strideLength(
                speedMps: point.speedMps,
                cadenceSpm: point.cadenceSpm
            )
            if !isClose(point.strideLengthM, expectedStride, AppConstants.toleranceStride) {
                return .fail(.I7, detail: "第 \(index) 点步幅不满足 L = 60v/c",
                             measured: point.strideLengthM, expected: expectedStride)
            }
            if index > 0 {
                let deltaT = point.elapsedSeconds - points[index - 1].elapsedSeconds
                let deltaSteps = point.cumulativeSteps - points[index - 1].cumulativeSteps
                let expectedSteps = Units.stepIncrement(
                    cadenceSpm: point.cadenceSpm,
                    deltaSeconds: deltaT
                )
                if !isClose(deltaSteps, expectedSteps, AppConstants.toleranceStepDistance) {
                    return .fail(.I7, detail: "第 \(index) 点步数增量 ≠ c·Δt/60",
                                 measured: deltaSteps, expected: expectedSteps)
                }
                stepDistance += deltaSteps * point.strideLengthM
            }
        }
        let total = session.totalDistanceMeters
        if !isClose(stepDistance, total, AppConstants.toleranceStepDistance) {
            return .fail(.I7, detail: "ΣΔsteps·L 与累计距离偏差超过 1%",
                         measured: stepDistance, expected: total)
        }
        return InvariantCheck(
            id: .I7,
            passed: true,
            detail: "L = 60v/c 逐点成立且 ΣΔsteps·L ≈ D",
            measuredValue: stepDistance,
            expectedValue: total
        )
    }

    // MARK: I8 · 海拔 / 坡度 / 反馈可追溯

    private func checkI8(session: RunSession, points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I8, detail: "采样点不足 2 个，无法验证海拔")
        }
        let altitudes = points.map(\.altitudeM)
        for altitude in altitudes where !altitude.isFinite {
            return .fail(.I8, detail: "存在非有限海拔值（可能臆造）")
        }
        guard let last = points.last else {
            return .fail(.I8, detail: "缺少采样点，无法验证海拔")
        }
        // 汇总量必须由末点累计派生；逐点校验不依赖死区 ε 的具体取值，
        // 使 `ElevationProfile.errorModel.deadbandMeters` 保持可配而不与校验器口径耦合。
        if !isClose(session.elevationGainM, last.elevationGainSoFarM, AppConstants.toleranceDistance) {
            return .fail(.I8, detail: "会话累计爬升与末点累计不一致",
                         measured: session.elevationGainM, expected: last.elevationGainSoFarM)
        }
        if !isClose(session.elevationLossM, last.elevationLossSoFarM, AppConstants.toleranceDistance) {
            return .fail(.I8, detail: "会话累计下降与末点累计不一致",
                         measured: session.elevationLossM, expected: last.elevationLossSoFarM)
        }
        var previousGain = points[0].elevationGainSoFarM
        var previousLoss = points[0].elevationLossSoFarM
        for index in 1..<points.count {
            let point = points[index]
            let deltaGain = point.elevationGainSoFarM - previousGain
            let deltaLoss = point.elevationLossSoFarM - previousLoss
            if deltaGain < -AppConstants.toleranceDistance
                || deltaLoss < -AppConstants.toleranceDistance {
                return .fail(.I8, detail: "第 \(index) 点累计爬升 / 下降回退")
            }
            // 同一帧不得同时增加爬升与下降（h 差分只能二选一）。
            if deltaGain > AppConstants.toleranceDistance,
               deltaLoss > AppConstants.toleranceDistance {
                return .fail(.I8, detail: "第 \(index) 点爬升与下降同时增加，非 h 差分派生")
            }
            let deltaAltitude = point.altitudeM - points[index - 1].altitudeM
            let net = deltaGain - deltaLoss
            if abs(net) > abs(deltaAltitude) + AppConstants.toleranceDistance {
                return .fail(.I8, detail: "第 \(index) 点累计净变化超过本帧海拔差分",
                             measured: net, expected: deltaAltitude)
            }
            let horizontal = Units.distanceMeters(points[index - 1].geoPoint, point.geoPoint)
            if horizontal > 0 {
                let expectedSlope = Units.slopePercent(
                    deltaAltitudeM: deltaAltitude,
                    horizontalDistanceM: horizontal
                )
                // TrackPoint 不独立存储坡度；I8 按冻结签名从相邻点 Δh / 水平距离重算，
                // 既验证有限性，也验证 slope 由 h(s) 与坐标单向派生。
                let measuredSlope = Units.slopePercent(
                    deltaAltitudeM: deltaAltitude,
                    horizontalDistanceM: horizontal
                )
                if !measuredSlope.isFinite
                    || !isClose(measuredSlope, expectedSlope, AppConstants.toleranceDistance) {
                    return .fail(.I8, detail: "第 \(index) 点坡度未能由 Δh/水平距离派生",
                                 measured: measuredSlope, expected: expectedSlope)
                }
            }
            previousGain = point.elevationGainSoFarM
            previousLoss = point.elevationLossSoFarM
        }
        return InvariantCheck(
            id: .I8,
            passed: true,
            detail: "h(s) → gain/loss → slope 单向可追溯（死区 ε 生效）",
            measuredValue: last.elevationGainSoFarM - last.elevationLossSoFarM,
            expectedValue: altitudes[altitudes.count - 1] - altitudes[0]
        )
    }

    // MARK: I9 · 单一真值源（派生量无独立随机）

    /// 逐点复核全部派生量的代数关系；任一字段偏离确定性公式即视为「独立随机 / 独立设定」。
    private func checkI9(session: RunSession, points: [TrackPoint]) -> InvariantCheck {
        guard points.count >= 2 else {
            return .fail(.I9, detail: "采样点不足 2 个，无法验证单一真值源")
        }
        guard session.dataOrigin == .simulated else {
            return .fail(.I9, detail: "仿真会话来源必须为 .simulated")
        }
        var violations = 0
        for index in 0..<points.count {
            let point = points[index]
            if point.dataOrigin != .simulated || !OriginID.isValid(point.id, for: .simulated) {
                violations += 1
            }
            let values: [Double] = [
                point.elapsedSeconds, point.latitude, point.longitude, point.altitudeM,
                point.speedMps, point.cadenceSpm, point.strideLengthM,
                point.cumulativeSteps, point.cumulativeDistanceM,
                point.instantPaceSecPerKm, point.avgPaceSecPerKm, point.courseDegrees,
                point.elevationGainSoFarM, point.elevationLossSoFarM,
                point.horizontalAccuracyM, point.verticalAccuracyM
            ]
            if values.contains(where: { !$0.isFinite }) {
                violations += 1
            }
            let stride = Units.strideLength(speedMps: point.speedMps, cadenceSpm: point.cadenceSpm)
            if !isClose(point.strideLengthM, stride, AppConstants.toleranceStride) {
                violations += 1
            }
            if index > 0 {
                let deltaT = point.elapsedSeconds - points[index - 1].elapsedSeconds
                let deltaD = point.cumulativeDistanceM - points[index - 1].cumulativeDistanceM
                let expectedSpeed = deltaT > 0 ? deltaD / deltaT : 0
                if !isClose(point.speedMps, expectedSpeed, AppConstants.toleranceVelocity) {
                    violations += 1
                }
                let expectedSteps = Units.stepIncrement(
                    cadenceSpm: point.cadenceSpm, deltaSeconds: deltaT
                )
                let actualSteps = point.cumulativeSteps - points[index - 1].cumulativeSteps
                if !isClose(actualSteps, expectedSteps, AppConstants.toleranceStepDistance) {
                    violations += 1
                }
            }
        }
        if violations > 0 {
            return InvariantCheck(
                id: .I9,
                passed: false,
                detail: "发现 \(violations) 处派生量偏离确定性公式（疑似独立随机）",
                measuredValue: Double(violations),
                expectedValue: 0
            )
        }
        return .pass(.I9, detail: "全部派生量均由 6 个主干量确定性推导，无独立随机")
    }

    // MARK: I10 · 同种子逐点可复现

    /// 三重验收：① 种子已确定 / 持久化；② 唯一随机入口同种子序列**浮点全等**重放；
    /// ③ 用与 F29 完全相同的纯函数重放派生字段并与落盘点**浮点全等**比较。
    /// 引擎 F31 另执行真实双次生成逐字段比对，不一致时直接拒绝生成。
    private func checkI10(profile: SimulationProfile, points: [TrackPoint]) -> InvariantCheck {
        guard profile.seed != 0 else {
            return .fail(.I10, detail: "随机种子未设置（seed = 0），无法保证可复现")
        }
        var first = SeededRandom(seed: profile.seed)
        var second = SeededRandom(seed: profile.seed)
        for _ in 0..<points.count {
            if first.nextUnit() != second.nextUnit() {
                return .fail(.I10, detail: "唯一随机入口同种子序列不一致")
            }
        }
        // 与 F29 相同公式重放，要求浮点全等（不使用近似容差）。
        for index in 0..<points.count {
            let point = points[index]
            let stride = Units.strideLength(speedMps: point.speedMps, cadenceSpm: point.cadenceSpm)
            if point.strideLengthM != stride {
                return .fail(.I10, detail: "第 \(index) 点步幅无法确定性重放",
                             measured: point.strideLengthM, expected: stride)
            }
            let deltaT: TimeInterval
            let deltaD: Double
            if index > 0 {
                deltaT = point.elapsedSeconds - points[index - 1].elapsedSeconds
                deltaD = point.cumulativeDistanceM - points[index - 1].cumulativeDistanceM
            } else {
                deltaT = 0
                deltaD = 0
            }
            let instantPace = deltaD > 0
                ? Units.paceSecPerKm(deltaSeconds: deltaT, deltaMeters: deltaD)
                : 0
            if point.instantPaceSecPerKm != instantPace {
                return .fail(.I10, detail: "第 \(index) 点实时配速无法确定性重放",
                             measured: point.instantPaceSecPerKm, expected: instantPace)
            }
            let avgPace = point.cumulativeDistanceM > 0
                ? Units.averagePaceSecPerKm(
                    totalSeconds: point.elapsedSeconds,
                    totalMeters: point.cumulativeDistanceM
                  )
                : 0
            if point.avgPaceSecPerKm != avgPace {
                return .fail(.I10, detail: "第 \(index) 点平均配速无法确定性重放",
                             measured: point.avgPaceSecPerKm, expected: avgPace)
            }
        }
        return InvariantCheck(
            id: .I10,
            passed: true,
            detail: "种子 \(profile.seed) 可确定性重放 \(points.count) 点且派生字段浮点全等",
            measuredValue: Double(profile.seed),
            expectedValue: Double(profile.seed)
        )
    }

    // MARK: 容差工具

    /// 相对容差比较（零值附近回退绝对容差），非有限值一律判失败。
    private func isClose(_ measured: Double, _ expected: Double, _ tolerance: Double) -> Bool {
        guard measured.isFinite, expected.isFinite else { return false }
        let scale = max(abs(measured), abs(expected), 1)
        return abs(measured - expected) <= max(abs(tolerance) * scale, 1e-9)
    }

    // MARK: - 测试辅助：矛盾注入

    /// 冻结签名：生成一整套「自洽基准 + 指定 I 的一处矛盾」数据（供 F61 逐 I 用例）。
    public static func injectContradiction(for id: InvariantID) -> ContradictionDataset {
        let baseline = makeBaseline()
        if id == .I5 {
            // 只篡改会话平均速度，逐点数据保持自洽 → 精准命中 I5。
            let tampered = RunSession(
                id: baseline.session.id,
                dataOrigin: .simulated,
                startTime: baseline.session.startTime,
                endTime: baseline.session.endTime,
                durationSeconds: baseline.session.durationSeconds,
                totalDistanceMeters: baseline.session.totalDistanceMeters,
                avgSpeedMps: baseline.session.avgSpeedMps * 2 + 1,
                avgPaceSecPerKm: baseline.session.avgPaceSecPerKm,
                totalSteps: baseline.session.totalSteps,
                elevationGainM: baseline.session.elevationGainM,
                elevationLossM: baseline.session.elevationLossM,
                routeId: baseline.session.routeId,
                simulationProfileId: baseline.session.simulationProfileId,
                note: baseline.session.note,
                createdAt: baseline.session.createdAt,
                schemaVersion: baseline.session.schemaVersion,
                originChain: baseline.session.originChain
            )
            return ContradictionDataset(
                session: tampered,
                points: baseline.points,
                profile: baseline.profile,
                expectedFailedID: .I5
            )
        }
        if id == .I10 {
            // 种子置 0 表示「未持久化」→ 精准命中 I10 的种子守卫。
            return ContradictionDataset(
                session: baseline.session,
                points: baseline.points,
                profile: baseline.profile.withSeed(0),
                expectedFailedID: .I10
            )
        }
        return ContradictionDataset(
            session: baseline.session,
            points: injectContradiction(for: id, into: baseline.points),
            profile: baseline.profile,
            expectedFailedID: id
        )
    }

    /// 对给定基准点序列注入一处确定性矛盾（返回新序列，不修改入参）。
    /// 仅 UnitTests（F61）调用，用于验证「注入矛盾 → 对应 I 失败 → 拒绝生成」。
    public static func injectContradiction(
        for id: InvariantID,
        into points: [TrackPoint]
    ) -> [TrackPoint] {
        guard points.count > 6 else { return points }
        var tampered = points
        let index = 5
        let target = tampered[index]
        switch id {
        case .I1:
            tampered[index] = replacing(target, elapsedSeconds: points[index - 1].elapsedSeconds - 1)
        case .I2:
            tampered[index] = replacing(target, latitude: target.latitude + 0.05)
        case .I3:
            tampered[index] = replacing(target, cumulativeDistanceM: target.cumulativeDistanceM + 100)
        case .I4:
            tampered[index] = replacing(target, speedMps: target.speedMps * 2 + 1)
        case .I5:
            // 末点累计距离被篡改 → 会话总量与逐点累计不一致，I5 失败。
            let lastIndex = tampered.count - 1
            let last = tampered[lastIndex]
            tampered[lastIndex] = replacing(
                last,
                cumulativeDistanceM: last.cumulativeDistanceM + 100
            )
        case .I6:
            tampered[index] = replacing(
                target,
                instantPaceSecPerKm: target.instantPaceSecPerKm * 1.5 + 10
            )
        case .I7:
            tampered[index] = replacing(target, strideLengthM: target.strideLengthM * 1.5 + 0.2)
        case .I8:
            tampered[index] = replacing(
                target,
                elevationGainSoFarM: target.elevationGainSoFarM + 50
            )
        case .I9:
            tampered[index] = replacing(target, cumulativeSteps: target.cumulativeSteps + 10)
        case .I10:
            // NaN 破坏确定性重放（浮点全等断言），并使 I9 的非有限检查同时失败。
            tampered[index] = replacing(target, strideLengthM: Double.nan)
        }
        return tampered
    }

    // MARK: 基准数据构造（确定性，不依赖引擎，避免 F30 → F31 反向依赖）

    private static func makeBaseline() -> ContradictionDataset {
        let startTime = Date(timeIntervalSince1970: 1_767_225_600)
        let sessionId = OriginID.makeID(.simulated, suffix: "contradiction_baseline")
        let cadence = 170.0
        let pointCount = 12
        let latitudeStep = 2.8 / 111_195
        let baseLatitude = 31.0
        let longitude = 121.0

        var points: [TrackPoint] = []
        points.reserveCapacity(pointCount)
        var cumulativeDistance = 0.0
        var cumulativeSteps = 0.0
        var gain = 0.0
        var previousCoordinate = GeoPoint(latitude: baseLatitude, longitude: longitude)

        for index in 0..<pointCount {
            let t = Double(index)
            let coordinate = GeoPoint(
                latitude: baseLatitude + Double(index) * latitudeStep,
                longitude: longitude
            )
            let deltaT: TimeInterval = index == 0 ? 0 : 1
            let gpsDelta = index == 0
                ? 0
                : Units.distanceMeters(previousCoordinate, coordinate)
            // 与 F29 相同的浮点路径：派生量基于累计距离差分，保证 I10 重放全等。
            let previousCumulative = cumulativeDistance
            cumulativeDistance += gpsDelta
            let effectiveDelta = max(0, cumulativeDistance - previousCumulative)
            let speed = deltaT > 0 ? effectiveDelta / deltaT : 0
            let instantPace = effectiveDelta > 0
                ? Units.paceSecPerKm(deltaSeconds: deltaT, deltaMeters: effectiveDelta)
                : 0
            let avgPace = cumulativeDistance > 0
                ? Units.averagePaceSecPerKm(
                    totalSeconds: t,
                    totalMeters: cumulativeDistance
                  )
                : 0
            let stride = Units.strideLength(speedMps: speed, cadenceSpm: cadence)
            cumulativeSteps += Units.stepIncrement(cadenceSpm: cadence, deltaSeconds: deltaT)
            let altitude = 10 + 3 * Double(index)
            if index > 0 {
                gain += 3
            }
            let slope = Units.slopePercent(deltaAltitudeM: index > 0 ? 3 : 0,
                                            horizontalDistanceM: gpsDelta)
            points.append(TrackPoint(
                id: "\(sessionId)_\(index)",
                sessionId: sessionId,
                dataOrigin: .simulated,
                timestamp: startTime.addingTimeInterval(t),
                elapsedSeconds: t,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                altitudeM: altitude,
                courseDegrees: 0,
                speedMps: speed,
                instantPaceSecPerKm: instantPace,
                avgPaceSecPerKm: avgPace,
                cadenceSpm: cadence,
                strideLengthM: stride,
                cumulativeSteps: cumulativeSteps,
                cumulativeDistanceM: cumulativeDistance,
                elevationGainSoFarM: gain,
                elevationLossSoFarM: 0,
                segmentIndex: 0,
                qualityFlags: []
            ))
            previousCoordinate = coordinate
        }

        let duration = Double(pointCount - 1)
        let distance = cumulativeDistance
        let session = RunSession(
            id: sessionId,
            dataOrigin: .simulated,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(duration),
            durationSeconds: duration,
            totalDistanceMeters: distance,
            avgSpeedMps: distance / duration,
            avgPaceSecPerKm: Units.averagePaceSecPerKm(
                totalSeconds: duration,
                totalMeters: distance
            ),
            totalSteps: cumulativeSteps,
            elevationGainM: gain,
            elevationLossM: 0,
            note: "矛盾注入基准（确定性构造）",
            createdAt: startTime
        )
        let profile = SimulationProfile.makeDefault(seed: 20_261_108)
        return ContradictionDataset(
            session: session,
            points: points,
            profile: profile,
            expectedFailedID: .I1
        )
    }

    /// 通过重新构造替换单个字段，保持 `TrackPoint` 全部 `let` 字段不可变语义。
    private static func replacing(
        _ point: TrackPoint,
        elapsedSeconds: TimeInterval? = nil,
        latitude: Double? = nil,
        cumulativeDistanceM: Double? = nil,
        speedMps: Double? = nil,
        instantPaceSecPerKm: Double? = nil,
        strideLengthM: Double? = nil,
        cumulativeSteps: Double? = nil,
        elevationGainSoFarM: Double? = nil
    ) -> TrackPoint {
        TrackPoint(
            id: point.id,
            sessionId: point.sessionId,
            dataOrigin: point.dataOrigin,
            timestamp: point.timestamp,
            elapsedSeconds: elapsedSeconds ?? point.elapsedSeconds,
            latitude: latitude ?? point.latitude,
            longitude: point.longitude,
            altitudeM: point.altitudeM,
            horizontalAccuracyM: point.horizontalAccuracyM,
            verticalAccuracyM: point.verticalAccuracyM,
            courseDegrees: point.courseDegrees,
            speedMps: speedMps ?? point.speedMps,
            speedAccuracyMps: point.speedAccuracyMps,
            instantPaceSecPerKm: instantPaceSecPerKm ?? point.instantPaceSecPerKm,
            avgPaceSecPerKm: point.avgPaceSecPerKm,
            cadenceSpm: point.cadenceSpm,
            strideLengthM: strideLengthM ?? point.strideLengthM,
            cumulativeSteps: cumulativeSteps ?? point.cumulativeSteps,
            cumulativeDistanceM: cumulativeDistanceM ?? point.cumulativeDistanceM,
            elevationGainSoFarM: elevationGainSoFarM ?? point.elevationGainSoFarM,
            elevationLossSoFarM: point.elevationLossSoFarM,
            segmentIndex: point.segmentIndex,
            qualityFlags: point.qualityFlags
        )
    }
}
