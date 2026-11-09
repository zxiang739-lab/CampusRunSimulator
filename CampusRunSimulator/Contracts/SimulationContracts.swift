import Foundation

// MARK: - 仿真结果

/// 引擎生成结果：`session` 恒 `.simulated`，`points` 逐点继承，`report` 为 I1–I10 逐项结果。
public struct SimulationResult: Sendable {
    public let session: RunSession
    public let points: [TrackPoint]
    public let report: InvariantReport

    public init(session: RunSession, points: [TrackPoint], report: InvariantReport) {
        self.session = session
        self.points = points
        self.report = report
    }
}

/// 引擎主干量 → 派生量的单帧（F29 产出，F22 契约层承载类型定义）。
/// `dataOrigin` 恒 `.simulated`，初始化器内部强制，不接受外部传入。
/// 全部派生量只由 6 个主干量（t / s / v / c / h / route）确定性推导，禁止任何字段独立随机（I9）。
public struct SimulationFrame: Identifiable, Sendable {
    public let id: String
    public let index: Int
    public let t: TimeInterval
    public let arcLengthM: Double
    public let speedMps: Double
    public let cadenceSpm: Double
    public let altitudeM: Double
    public let coordinate: GeoPoint
    public let courseDegrees: Double
    public let deltaDistanceM: Double
    public let cumulativeDistanceM: Double
    public let instantPaceSecPerKm: Double
    public let avgPaceSecPerKm: Double
    public let strideLengthM: Double
    public let cumulativeSteps: Double
    public let elevationGainSoFarM: Double
    public let elevationLossSoFarM: Double
    public let slopePercent: Double
    public let horizontalAccuracyM: Double
    public let verticalAccuracyM: Double
    public let speedAccuracyMps: Double
    public let dataOrigin: DataOrigin

    /// 初始化器强制 `dataOrigin = .simulated`（合规铁律：测试帧永不落入 REAL 域）。
    public init(
        id: String = UUID().uuidString,
        index: Int,
        t: TimeInterval,
        arcLengthM: Double,
        speedMps: Double,
        cadenceSpm: Double,
        altitudeM: Double,
        coordinate: GeoPoint,
        courseDegrees: Double,
        deltaDistanceM: Double,
        cumulativeDistanceM: Double,
        instantPaceSecPerKm: Double,
        avgPaceSecPerKm: Double,
        strideLengthM: Double,
        cumulativeSteps: Double,
        elevationGainSoFarM: Double,
        elevationLossSoFarM: Double,
        slopePercent: Double,
        horizontalAccuracyM: Double = -1,
        verticalAccuracyM: Double = -1,
        speedAccuracyMps: Double = -1
    ) {
        self.id = id
        self.index = index
        self.t = t
        self.arcLengthM = arcLengthM
        self.speedMps = speedMps
        self.cadenceSpm = cadenceSpm
        self.altitudeM = altitudeM
        self.coordinate = coordinate
        self.courseDegrees = courseDegrees
        self.deltaDistanceM = deltaDistanceM
        self.cumulativeDistanceM = cumulativeDistanceM
        self.instantPaceSecPerKm = instantPaceSecPerKm
        self.avgPaceSecPerKm = avgPaceSecPerKm
        self.strideLengthM = strideLengthM
        self.cumulativeSteps = cumulativeSteps
        self.elevationGainSoFarM = elevationGainSoFarM
        self.elevationLossSoFarM = elevationLossSoFarM
        self.slopePercent = slopePercent
        self.horizontalAccuracyM = horizontalAccuracyM
        self.verticalAccuracyM = verticalAccuracyM
        self.speedAccuracyMps = speedAccuracyMps
        self.dataOrigin = .simulated
    }

    /// 把一帧转换为落盘的 `TrackPoint`（来源继承且不可变）。
    public func trackPoint(sessionId: String, startTime: Date, segmentIndex: Int = 0) -> TrackPoint {
        TrackPoint(
            id: OriginID.makeID(.simulated, suffix: "\(sessionId)_\(index)"),
            sessionId: sessionId,
            dataOrigin: .simulated,
            timestamp: startTime.addingTimeInterval(t),
            elapsedSeconds: t,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitudeM: altitudeM,
            horizontalAccuracyM: horizontalAccuracyM,
            verticalAccuracyM: verticalAccuracyM,
            courseDegrees: courseDegrees,
            speedMps: speedMps,
            speedAccuracyMps: speedAccuracyMps,
            instantPaceSecPerKm: instantPaceSecPerKm,
            avgPaceSecPerKm: avgPaceSecPerKm,
            cadenceSpm: cadenceSpm,
            strideLengthM: strideLengthM,
            cumulativeSteps: cumulativeSteps,
            cumulativeDistanceM: cumulativeDistanceM,
            elevationGainSoFarM: elevationGainSoFarM,
            elevationLossSoFarM: elevationLossSoFarM,
            segmentIndex: segmentIndex,
            qualityFlags: []
        )
    }
}

// MARK: - 查询谓词

/// 排序键。
public enum RunSortKey: String, Codable, Sendable, CaseIterable {
    case startTime
    case createdAt
    case durationSeconds
    case totalDistanceMeters
}

/// `RunRepository.fetch(origin:predicate:)` 的查询条件（纯值类型）。
public struct RunPredicate: Sendable, Hashable {
    public let searchText: String
    public let fromDate: Date?
    public let toDate: Date?
    public let routeId: String?
    public let sortKey: RunSortKey
    public let ascending: Bool
    public let limit: Int?

    public init(
        searchText: String = "",
        fromDate: Date? = nil,
        toDate: Date? = nil,
        routeId: String? = nil,
        sortKey: RunSortKey = .startTime,
        ascending: Bool = false,
        limit: Int? = nil
    ) {
        self.searchText = searchText
        self.fromDate = fromDate
        self.toDate = toDate
        self.routeId = routeId
        self.sortKey = sortKey
        self.ascending = ascending
        self.limit = limit
    }

    public static let `default` = RunPredicate()

    /// 在内存中对会话列表应用筛选与排序（供仓库实现复用，含真实逻辑）。
    public func apply(to sessions: [RunSession]) -> [RunSession] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = sessions.filter { session in
            if !keyword.isEmpty, !session.note.localizedCaseInsensitiveContains(keyword),
               !session.id.localizedCaseInsensitiveContains(keyword) {
                return false
            }
            if let fromDate = fromDate, session.startTime < fromDate { return false }
            if let toDate = toDate, session.startTime > toDate { return false }
            if let routeId = routeId, session.routeId != routeId { return false }
            // 脏数据（id 与来源域不一致）不进入正常列表，交由 unclassified() 隔离。
            return OriginID.isValid(session.id, for: session.dataOrigin)
        }
        result.sort { lhs, rhs in
            let ordered: Bool
            switch sortKey {
            case .startTime: ordered = lhs.startTime < rhs.startTime
            case .createdAt: ordered = lhs.createdAt < rhs.createdAt
            case .durationSeconds: ordered = lhs.durationSeconds < rhs.durationSeconds
            case .totalDistanceMeters: ordered = lhs.totalDistanceMeters < rhs.totalDistanceMeters
            }
            return ascending ? ordered : !ordered
        }
        if let limit = limit, limit >= 0 {
            return Array(result.prefix(limit))
        }
        return result
    }
}

// MARK: - 仿真侧协议（§3.2 冻结签名）

/// 仿真引擎协议。实现约束：不得 import `CLLocationManager` / HealthKit / 网络栈。
public protocol SimulationEngine: Sendable {
    func generate(profile: SimulationProfile, route: Route) async throws -> SimulationResult
    func preview(profile: SimulationProfile, route: Route) async throws -> [SimulationFrame]
    func validateParameters(profile: SimulationProfile, route: Route) throws
}

/// I1–I10 一致性校验协议（失败即拒绝生成，不是警告）。
public protocol InvariantValidating: Sendable {
    func validate(
        session: RunSession,
        points: [TrackPoint],
        profile: SimulationProfile
    ) -> InvariantReport
}

/// 回放控制器协议（`@MainActor` 类实现）。
public protocol ReplayControlling: AnyObject {
    var state: ReplayState { get }
    func load(sessionId: String) async throws
    func play()
    func pause()
    func resume()
    func seek(to elapsed: TimeInterval)
    func setRate(_ rate: PlaybackRate)
    func frame(at elapsed: TimeInterval) -> TrackPoint?
}

/// 双存储域仓库协议。
/// 契约硬约束：不存在任何 `simulated -> real` 的转换 / 复制 / 导出方法。
public protocol RunRepository: Sendable {
    func save(_ session: RunSession, points: [TrackPoint]) async throws
    func fetch(origin: DataOrigin, predicate: RunPredicate) async throws -> [RunSession]
    func points(sessionId: String) async throws -> [TrackPoint]
    func delete(ids: [String], origin: DataOrigin) async throws
    func clear(origin: DataOrigin) async throws
    func routes() async throws -> [Route]
    func presets() async throws -> [RulePreset]
    func profiles() async throws -> [SimulationProfile]
    /// 脏数据隔离：缺 `dataOrigin` 的记录归入 `.unclassified`，绝不默认 real。
    func unclassified() async throws -> [RunSession]
    /// 另存副本：保留 `originChain`，来源不变。
    func duplicate(_ session: RunSession) async throws -> RunSession
}

/// GPX 编解码协议。
public protocol GPXCoding: Sendable {
    func encode(session: RunSession, points: [TrackPoint]) throws -> Data
    func decode(_ data: Data) throws -> GPXImportResult
}

/// 报告构建协议（F37 AnalysisBuilder 实现）。
public protocol ReportBuilding: Sendable {
    /// `range` 为采样点索引区间（闭区间）。
    func segmentStatistics(_ points: [TrackPoint], range: ClosedRange<Int>) -> SegmentStatistics
    func invariantReport(_ result: SimulationResult) -> InvariantReport
    func dataQualityReport(_ points: [TrackPoint]) -> DataQualityReport
    /// 生成含固定免责声明的评估文本。
    func ruleEvaluationText(_ result: RuleEvaluationResult) -> String
}
