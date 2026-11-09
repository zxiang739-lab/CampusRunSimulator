import Foundation

// MARK: - 派生量清单

/// F29 产出的全部派生量及其所依赖的 6 个主干量（t / s / v(t) / c(t) / h(s) / route + seed）。
/// 单一真值源红线：清单内**没有任何字段允许独立随机或独立设定**（I9）。
public enum DerivedField: String, Codable, Sendable, CaseIterable {
    case coordinate
    case courseDegrees
    case deltaDistanceM
    case cumulativeDistanceM
    case speedMps
    case instantPaceSecPerKm
    case avgPaceSecPerKm
    case strideLengthM
    case cumulativeSteps
    case elevationGainSoFarM
    case elevationLossSoFarM
    case slopePercent
    case horizontalAccuracyM
    case verticalAccuracyM
    case speedAccuracyMps

    /// 该派生量依赖的主干量名称（用于报告 / 一致性说明）。
    public var dependencies: [String] {
        switch self {
        case .coordinate, .courseDegrees:
            return ["s(t)", "route"]
        case .deltaDistanceM, .cumulativeDistanceM, .speedMps:
            return ["s(t)", "t", "route"]
        case .instantPaceSecPerKm, .avgPaceSecPerKm:
            return ["t", "s(t)"]
        case .strideLengthM, .cumulativeSteps:
            return ["v(t)", "c(t)", "t"]
        case .elevationGainSoFarM, .elevationLossSoFarM, .slopePercent:
            return ["h(s)", "s(t)"]
        case .horizontalAccuracyM, .verticalAccuracyM, .speedAccuracyMps:
            return ["误差模型", "seed"]
        }
    }

    public var localizedDescription: String {
        switch self {
        case .coordinate: return "GPS 坐标"
        case .courseDegrees: return "方位角"
        case .deltaDistanceM: return "相邻点位移"
        case .cumulativeDistanceM: return "累计距离"
        case .speedMps: return "瞬时速度"
        case .instantPaceSecPerKm: return "实时配速"
        case .avgPaceSecPerKm: return "平均配速"
        case .strideLengthM: return "步幅 L = 60v/c"
        case .cumulativeSteps: return "累计步数"
        case .elevationGainSoFarM: return "累计爬升"
        case .elevationLossSoFarM: return "累计下降"
        case .slopePercent: return "坡度"
        case .horizontalAccuracyM: return "水平精度"
        case .verticalAccuracyM: return "垂直精度"
        case .speedAccuracyMps: return "速度精度"
        }
    }

    /// 6 个主干量名称（唯一真值源）。
    public static let primaryQuantities: [String] = ["t", "s(t)", "v(t)", "c(t)", "h(s)", "route + seed"]
}

// MARK: - 组装器内部状态

/// 逐帧累积状态。用引用类型承载，使冻结签名中的 `assemble` / `finalize` 保持非 `mutating`，
/// 同时状态成员全部为 Sendable 值类型（Double / Int / GeoPoint / Date / String）。
private final class AssemblerState: @unchecked Sendable {
    var index: Int = 0
    var previousT: TimeInterval?
    var previousCoordinate: GeoPoint?
    var previousAltitude: Double?
    var arcLength: Double = 0
    var cumulativeDistance: Double = 0
    var cumulativeSteps: Double = 0
    var elevationGain: Double = 0
    var elevationLoss: Double = 0

    let sessionId: String
    let startTime: Date
    let deadband: Double
    let routeId: String?
    let simulationProfileId: String?
    let note: String

    init(
        sessionId: String,
        startTime: Date,
        deadband: Double,
        routeId: String?,
        simulationProfileId: String?,
        note: String
    ) {
        self.sessionId = sessionId
        self.startTime = startTime
        self.deadband = deadband
        self.routeId = routeId
        self.simulationProfileId = simulationProfileId
        self.note = note
    }
}

// MARK: - 全部派生量唯一出口

/// **全部派生量唯一出口**（F29 / §3.2 / §7.12 铁律 4）。
/// 逐帧把 6 个主干量确定性推导为 `SimulationFrame`，再汇总为 `RunSession` + `[TrackPoint]`。
///
/// 一致性设计（保证 I1–I10 精确成立）：
/// - `s` 由 `v(t)·Δt` 积分推进，`P = arc.point(atArcLength: s)`（I2）；
/// - `Δd = distance(P_{i−1}, P_i)` 用统一距离口径（I3）；
/// - `speedMps = Δd / Δt` 由距离反算（I4 精确成立）；
/// - `L = 60 * v / c`、`Δsteps = c·Δt/60`，故 `ΣΔsteps·L = ΣΔd = D`（I7 精确成立）；
/// - 配速 `= 1000·Δt/Δd`、平均配速 `= 1000·t/D`（I6）；
/// - gain/loss 由 `h` 差分 + 死区 ε（I8）。
public struct TrackPointAssembler: Sendable {
    private let state: AssemblerState

    public init(
        sessionId: String = OriginID.makeID(.simulated),
        startTime: Date,
        deadband: Double = AppConstants.elevationDeadbandMeters,
        routeId: String? = nil,
        simulationProfileId: String? = nil,
        note: String = ""
    ) {
        // 会话 id 强制落在 `sim_` 独立 id 空间，绝不跨来源复用。
        let normalized = OriginID.normalize(sessionId, for: .simulated)
        self.state = AssemblerState(
            sessionId: normalized,
            startTime: startTime,
            deadband: max(0, deadband),
            routeId: routeId,
            simulationProfileId: simulationProfileId,
            note: note
        )
    }

    /// 组装单帧（§3.2 冻结签名 + `origin` 合规守卫）。
    /// - Throws: `AppError.parameterConflict` —— `origin != .simulated` 时**拒绝生成**，
    ///   因为 `SimulationFrame.init` 内部强制 `dataOrigin = .simulated`，绝不构造 REAL 帧。
    public func assemble(
        t: Double,
        arc: RouteArcLength,
        speed: Double,
        cadence: Double,
        altitude: Double,
        origin: DataOrigin
    ) throws -> SimulationFrame {
        guard origin == .simulated else {
            throw AppError.parameterConflict(
                reason: "组装来源必须为 .simulated，拒绝把测试帧构造为真实记录"
            )
        }
        let index = state.index
        let deltaT: TimeInterval
        if let previousT = state.previousT {
            deltaT = max(0, t - previousT)
        } else {
            deltaT = 0
        }

        // 主干：s(t) = ∫v dt（矩形积分，Δt 恒定）。
        let effectiveSpeed = speed.isFinite ? max(0, speed) : 0
        if deltaT > 0 {
            state.arcLength += effectiveSpeed * deltaT
        }
        let arcLength = state.arcLength
        let routePoint = arc.point(atArcLength: arcLength)
        let coordinate = routePoint.geoPoint
        let course = arc.course(atArcLength: arcLength)

        // 派生：Δd 由 GPS 相邻点距离（统一口径），首帧为 0。
        let deltaDistance: Double
        if let previousCoordinate = state.previousCoordinate, deltaT > 0 {
            deltaDistance = max(0, Haversine.distance(previousCoordinate, coordinate))
        } else {
            deltaDistance = 0
        }
        let previousCumulative = state.cumulativeDistance
        state.cumulativeDistance += deltaDistance
        let cumulativeDistance = state.cumulativeDistance
        // 全部派生量统一基于累计距离的差分，保证与 I1–I10 校验器重放走完全相同的浮点路径。
        let effectiveDelta = max(0, cumulativeDistance - previousCumulative)

        // 速度 / 配速：零距离时无定义，记 0（不产生 inf / NaN，且明确为「不可用」语义）。
        let outputSpeed = deltaT > 0 ? effectiveDelta / deltaT : 0
        let instantPace = effectiveDelta > 0
            ? Units.paceSecPerKm(deltaSeconds: deltaT, deltaMeters: effectiveDelta)
            : 0
        let avgPace = cumulativeDistance > 0
            ? Units.averagePaceSecPerKm(totalSeconds: t, totalMeters: cumulativeDistance)
            : 0

        // 步幅 L = 60 * v / c（Units.strideLength 为唯一实现处）；累计步数由步频对时间积分。
        let stride = Units.strideLength(speedMps: outputSpeed, cadenceSpm: cadence)
        state.cumulativeSteps += Units.stepIncrement(cadenceSpm: cadence, deltaSeconds: deltaT)
        let cumulativeSteps = state.cumulativeSteps

        // 海拔 / 坡度 / 爬升下降（死区 ε）。
        let referenceAltitude = state.previousAltitude ?? altitude
        let deltaAltitude = altitude - referenceAltitude
        if abs(deltaAltitude) > state.deadband {
            if deltaAltitude > 0 {
                state.elevationGain += deltaAltitude
            } else {
                state.elevationLoss += -deltaAltitude
            }
        }
        let slope = Units.slopePercent(
            deltaAltitudeM: deltaAltitude,
            horizontalDistanceM: deltaDistance
        )

        let frame = SimulationFrame(
            id: "\(state.sessionId)_frame_\(index)",
            index: index,
            t: t,
            arcLengthM: arcLength,
            speedMps: outputSpeed,
            cadenceSpm: cadence,
            altitudeM: altitude,
            coordinate: coordinate,
            courseDegrees: course,
            deltaDistanceM: deltaDistance,
            cumulativeDistanceM: cumulativeDistance,
            instantPaceSecPerKm: instantPace,
            avgPaceSecPerKm: avgPace,
            strideLengthM: stride,
            cumulativeSteps: cumulativeSteps,
            elevationGainSoFarM: state.elevationGain,
            elevationLossSoFarM: state.elevationLoss,
            slopePercent: slope,
            // 测试数据不伪造传感器精度：-1 表示「无效 / 不可用」（§7.1）。
            horizontalAccuracyM: -1,
            verticalAccuracyM: -1,
            speedAccuracyMps: -1
        )

        // 推进逐帧状态。
        state.index += 1
        state.previousT = t
        state.previousCoordinate = coordinate
        state.previousAltitude = altitude
        return frame
    }

    /// 汇总为 `RunSession(.simulated)` + `[TrackPoint]`（§3.2 冻结签名）。
    /// 所有汇总量由最后一帧派生，绝不在汇总阶段引入新的独立数值。
    public func finalize(_ frames: [SimulationFrame]) -> (RunSession, [TrackPoint]) {
        let points = frames.map {
            $0.trackPoint(sessionId: state.sessionId, startTime: state.startTime, segmentIndex: 0)
        }
        guard let last = frames.last else {
            // 空帧防御：返回零值会话；F31 前置守卫保证正常流程不会出现空帧。
            let session = RunSession(
                id: state.sessionId,
                dataOrigin: .simulated,
                startTime: state.startTime,
                endTime: state.startTime,
                durationSeconds: 0,
                totalDistanceMeters: 0,
                avgSpeedMps: 0,
                avgPaceSecPerKm: 0,
                totalSteps: 0,
                elevationGainM: 0,
                elevationLossM: 0,
                routeId: state.routeId,
                simulationProfileId: state.simulationProfileId,
                note: state.note,
                createdAt: state.startTime
            )
            return (session, points)
        }

        let duration = max(0, last.t)
        let distance = max(0, last.cumulativeDistanceM)
        let avgSpeed = duration > 0 ? distance / duration : 0
        let avgPace = Units.averagePaceSecPerKm(totalSeconds: duration, totalMeters: distance)
        let session = RunSession(
            id: state.sessionId,
            dataOrigin: .simulated,
            startTime: state.startTime,
            endTime: state.startTime.addingTimeInterval(duration),
            durationSeconds: duration,
            totalDistanceMeters: distance,
            avgSpeedMps: avgSpeed,
            avgPaceSecPerKm: avgPace,
            totalSteps: last.cumulativeSteps,
            elevationGainM: last.elevationGainSoFarM,
            elevationLossM: last.elevationLossSoFarM,
            routeId: state.routeId,
            simulationProfileId: state.simulationProfileId,
            note: state.note,
            createdAt: state.startTime
        )
        return (session, points)
    }
}
