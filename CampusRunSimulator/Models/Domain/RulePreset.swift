import Foundation

/// 评估条件名（§B.7.1 / §B.7.2 JSON 契约）。
public enum RuleCondition: String, Codable, Sendable, CaseIterable {
    case minDistance = "minDistance"
    case maxDistance = "maxDistance"
    case dailyCap = "dailyCapMeters"
    case duration = "duration"
    case maxPause = "pause"
    case timeWindow = "timeWindow"
    case dateRange = "dateRange"
    case pace = "pace"
    case cadence = "cadence"
    case cadenceFluctuation = "cadenceFluctuation"
    case routeType = "routeType"
    case closedLoop = "closedLoop"
    case geofence = "geofence"
    case waypoints = "waypoints"
    case finishPoint = "finishPoint"
    case orderStrict = "orderStrict"
    case dailyValidRecordCap = "dailyValidRecordCap"

    public var localizedDescription: String {
        switch self {
        case .minDistance: return "最低距离"
        case .maxDistance: return "单次距离上限"
        case .dailyCap: return "每日距离上限"
        case .duration: return "时长"
        case .maxPause: return "累计暂停上限"
        case .timeWindow: return "有效时段"
        case .dateRange: return "有效日期范围"
        case .pace: return "配速区间"
        case .cadence: return "步频区间"
        case .cadenceFluctuation: return "步频波动（自定义统计阈值）"
        case .routeType: return "路线类型"
        case .closedLoop: return "首尾闭合"
        case .geofence: return "电子围栏"
        case .waypoints: return "必经点 / 普通点"
        case .finishPoint: return "终点点"
        case .orderStrict: return "按序经过"
        case .dailyValidRecordCap: return "每日记录数上限"
        }
    }
}

/// 三态评估结论（§B.7.4）。**类型系统层面不存在 score / grade / record 字段。**
public enum EvaluationOutcome: String, Codable, Sendable, CaseIterable {
    case passed
    case failed
    case insufficientData

    public var localizedDescription: String {
        switch self {
        case .passed: return "通过"
        case .failed: return "不通过"
        case .insufficientData: return "数据不足"
        }
    }
}

/// 距离规则（§B.7.2；全部为示例假设值）。
public struct RuleDistance: Codable, Sendable, Hashable {
    public let minDistanceMeters: Double
    public let maxDistanceMeters: Double
    public let dailyCapMeters: Double

    public init(
        minDistanceMeters: Double = 2_000,
        maxDistanceMeters: Double = 10_000,
        dailyCapMeters: Double = 0
    ) {
        self.minDistanceMeters = minDistanceMeters
        self.maxDistanceMeters = maxDistanceMeters
        self.dailyCapMeters = dailyCapMeters
    }

    public var isValid: Bool {
        minDistanceMeters >= 0 && dailyCapMeters >= 0
            && (maxDistanceMeters == 0 || maxDistanceMeters >= minDistanceMeters)
    }
}

/// 时长规则（§B.7.2）。
public struct RuleDuration: Codable, Sendable, Hashable {
    public let minDurationSeconds: TimeInterval
    public let maxDurationSeconds: TimeInterval
    public let maxPauseSeconds: TimeInterval

    public init(
        minDurationSeconds: TimeInterval = 0,
        maxDurationSeconds: TimeInterval = 0,
        maxPauseSeconds: TimeInterval = 480
    ) {
        self.minDurationSeconds = minDurationSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.maxPauseSeconds = maxPauseSeconds
    }

    public var isValid: Bool {
        minDurationSeconds >= 0 && maxPauseSeconds >= 0
            && (maxDurationSeconds == 0 || maxDurationSeconds >= minDurationSeconds)
    }
}

/// 有效时段（本地时间 HH:mm，支持跨午夜多段）。
public struct TimeWindow: Codable, Sendable, Hashable {
    public let start: String
    public let end: String

    public init(start: String = "06:00", end: String = "22:00") {
        self.start = start
        self.end = end
    }

    /// 是否为合法 HH:mm（00–23 / 00–59）。
    public var isValid: Bool {
        guard let s = minutesOfDay(start), let e = minutesOfDay(end) else { return false }
        return s >= 0 && s < 1_440 && e >= 0 && e < 1_440
    }

    private func minutesOfDay(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// 判断给定本地时间是否落在该时段内（跨午夜窗口自动处理）。
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isValid, let from = minutesOfDay(start), let to = minutesOfDay(end) else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let now = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if from <= to {
            return now >= from && now <= to
        }
        return now >= from || now <= to
    }
}

/// 有效日期范围（可选，两端可为 nil）。
public struct DateRange: Codable, Sendable, Hashable {
    public let start: Date?
    public let end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        if let start = start, date < start { return false }
        if let end = end, date > end { return false }
        return true
    }

    public var isValid: Bool {
        guard let start = start, let end = end else { return true }
        return start <= end
    }
}

/// 配速计算口径。
public enum PaceBasis: String, Codable, Sendable, CaseIterable {
    case average
    case perSegment

    public var localizedDescription: String {
        switch self {
        case .average: return "全程平均"
        case .perSegment: return "逐分段"
        }
    }
}

/// 配速规则（s/km；最快 = 数值小，最慢 = 数值大）。
public struct RulePace: Codable, Sendable, Hashable {
    public let minPaceSecPerKm: Double
    public let maxPaceSecPerKm: Double
    public let paceBasis: PaceBasis
    public let segmentLengthMeters: Double

    public init(
        minPaceSecPerKm: Double = 180,
        maxPaceSecPerKm: Double = 600,
        paceBasis: PaceBasis = .average,
        segmentLengthMeters: Double = 500
    ) {
        self.minPaceSecPerKm = minPaceSecPerKm
        self.maxPaceSecPerKm = maxPaceSecPerKm
        self.paceBasis = paceBasis
        self.segmentLengthMeters = segmentLengthMeters
    }

    /// 最快配速不得大于最慢配速（§B.13.3-11）。
    public var isValid: Bool {
        minPaceSecPerKm > 0 && maxPaceSecPerKm > 0
            && minPaceSecPerKm <= maxPaceSecPerKm
            && segmentLengthMeters > 0
    }
}

/// 步频规则（自定义统计阈值，不模拟任何平台算法）。
public struct RuleCadence: Codable, Sendable, Hashable {
    public let minCadenceSpm: Double
    public let maxCadenceSpm: Double
    public let cadenceFluctuationCheck: Bool
    public let cadenceFluctuationThreshold: Double

    public init(
        minCadenceSpm: Double = 40,
        maxCadenceSpm: Double = 300,
        cadenceFluctuationCheck: Bool = false,
        cadenceFluctuationThreshold: Double = 0.35
    ) {
        self.minCadenceSpm = minCadenceSpm
        self.maxCadenceSpm = maxCadenceSpm
        self.cadenceFluctuationCheck = cadenceFluctuationCheck
        self.cadenceFluctuationThreshold = cadenceFluctuationThreshold
    }

    public var isValid: Bool {
        minCadenceSpm > 0 && maxCadenceSpm >= minCadenceSpm
            && cadenceFluctuationThreshold >= 0
    }
}

/// 路线规则（多边形为用户自定义坐标，可空）。
public struct RuleRoute: Codable, Sendable, Hashable {
    public let routeType: RouteType
    public let requireClosedLoop: Bool
    public let geofencePolygon: [GeoPoint]

    public init(
        routeType: RouteType = .loop,
        requireClosedLoop: Bool = true,
        geofencePolygon: [GeoPoint] = []
    ) {
        self.routeType = routeType
        self.requireClosedLoop = requireClosedLoop
        self.geofencePolygon = geofencePolygon
    }

    /// 判断点是否落在多边形内（射线法；空多边形视为不限制）。
    public func contains(_ point: GeoPoint) -> Bool {
        guard geofencePolygon.count >= 3 else { return true }
        var inside = false
        var j = geofencePolygon.count - 1
        for i in 0..<geofencePolygon.count {
            let a = geofencePolygon[i]
            let b = geofencePolygon[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude) {
                let denominator = b.latitude - a.latitude
                if denominator != 0 {
                    let crossLongitude = (b.longitude - a.longitude)
                        * (point.latitude - a.latitude) / denominator + a.longitude
                    if point.longitude < crossLongitude { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }
}

/// 点位策略（§B.7.1 WaypointPolicy 全字段）。
public struct WaypointPolicy: Codable, Sendable, Hashable {
    public let requiredMandatoryCount: Int
    public let requiredRandomCount: Int
    public let totalGeneratedCount: Int
    public let ordered: Bool
    public let mandatoryPointIds: [String]
    public let randomPointIds: [String]
    public let finishPointId: String?
    public let waypointRadiusMeters: Double
    public let finishPointRequired: Bool
    public let orderStrict: Bool

    public init(
        requiredMandatoryCount: Int = 1,
        requiredRandomCount: Int = 2,
        totalGeneratedCount: Int = 5,
        ordered: Bool = false,
        mandatoryPointIds: [String] = ["wp_1"],
        randomPointIds: [String] = ["wp_2", "wp_3", "wp_4", "wp_5"],
        finishPointId: String? = nil,
        waypointRadiusMeters: Double = 50,
        finishPointRequired: Bool = false,
        orderStrict: Bool = false
    ) {
        self.requiredMandatoryCount = requiredMandatoryCount
        self.requiredRandomCount = requiredRandomCount
        self.totalGeneratedCount = totalGeneratedCount
        self.ordered = ordered
        self.mandatoryPointIds = mandatoryPointIds
        self.randomPointIds = randomPointIds
        self.finishPointId = finishPointId
        self.waypointRadiusMeters = waypointRadiusMeters
        self.finishPointRequired = finishPointRequired
        self.orderStrict = orderStrict
    }

    public var isValid: Bool {
        requiredMandatoryCount >= 0 && requiredRandomCount >= 0
            && totalGeneratedCount >= requiredMandatoryCount + requiredRandomCount
            && waypointRadiusMeters > 0
    }
}

/// 记录有效性（§B.7.2）。
/// `resultIsScore` 与 `producesExternalRecord` **固定 false**：初始化器与解码器双重强制，
/// 不允许任何调用方或 JSON 把它们改成 true（AC-C6）。
public struct RecordValidity: Codable, Sendable, Hashable {
    public let requireAllConditions: Bool
    public let conditions: [RuleCondition]
    public let dailyValidRecordCap: Int
    public let resultIsScore: Bool
    public let producesExternalRecord: Bool

    private enum CodingKeys: String, CodingKey {
        case requireAllConditions, conditions, dailyValidRecordCap
        case resultIsScore, producesExternalRecord
    }

    public init(
        requireAllConditions: Bool = true,
        conditions: [RuleCondition] = [
            .minDistance, .pace, .cadence, .waypoints, .timeWindow, .maxPause, .geofence
        ],
        dailyValidRecordCap: Int = 1
    ) {
        self.requireAllConditions = requireAllConditions
        self.conditions = conditions
        self.dailyValidRecordCap = dailyValidRecordCap
        self.resultIsScore = false
        self.producesExternalRecord = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requireAllConditions = try container.decode(Bool.self, forKey: .requireAllConditions)
        conditions = try container.decode([RuleCondition].self, forKey: .conditions)
        dailyValidRecordCap = try container.decode(Int.self, forKey: .dailyValidRecordCap)
        // 忽略 JSON 中的这两个字段，永远固定 false。
        resultIsScore = false
        producesExternalRecord = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requireAllConditions, forKey: .requireAllConditions)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(dailyValidRecordCap, forKey: .dailyValidRecordCap)
        try container.encode(false, forKey: .resultIsScore)
        try container.encode(false, forKey: .producesExternalRecord)
    }
}

/// 预设元数据（§B.7.2）。
public struct RuleMeta: Codable, Sendable, Hashable {
    public let schoolProfileLabel: String
    public let comparisonGroup: String
    public let source: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        schoolProfileLabel: String = "示例：偏严格",
        comparisonGroup: String = "课堂对比组 1",
        source: String = AppConstants.documentSource,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schoolProfileLabel = schoolProfileLabel
        self.comparisonGroup = comparisonGroup
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 生成副本元数据（保留 comparisonGroup，刷新 updatedAt）。
    public func duplicate() -> RuleMeta {
        RuleMeta(
            schoolProfileLabel: schoolProfileLabel,
            comparisonGroup: comparisonGroup,
            source: source,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

/// 用户自建假设规则预设（§3.2 / §B.7.2 全字段）。
///
/// 合规硬约束：
/// - `isHypothetical` 初始化器强制 `true`，JSON 中出现 `false` 时解码直接抛错；
/// - `disclaimer` 固定为 `AppConstants.ruleDisclaimer`；
/// - `dataOrigin` 恒 `.simulated`（评估对象只能是测试数据）；
/// - 不内置、不默认填充任何真实平台/学校规则；
/// - 评估结果类型 `RuleEvaluationResult` 中没有 score 字段。
public struct RulePreset: Identifiable, Codable, Sendable {
    public let id: String
    public let schemaVersion: String
    public let displayName: String
    public let note: String
    public let isHypothetical: Bool
    public let disclaimer: String
    public let distance: RuleDistance
    public let duration: RuleDuration
    public let timeWindows: [TimeWindow]
    public let dateRange: DateRange?
    public let pace: RulePace
    public let cadence: RuleCadence
    public let route: RuleRoute
    public let waypoints: WaypointPolicy
    public let validity: RecordValidity
    public let meta: RuleMeta
    public let dataOrigin: DataOrigin

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, displayName, note, isHypothetical, disclaimer
        case distance, duration, timeWindows, dateRange, pace, cadence, route
        case waypoints, validity, meta, dataOrigin
    }

    /// 完整初始化器：**不接受** `isHypothetical` / `disclaimer` / `dataOrigin`，
    /// 三者由初始化器强制，外部无法覆盖。
    public init(
        id: String = "hypo_default_a",
        schemaVersion: String = AppConstants.schemaVersion,
        displayName: String = "假设规则 A",
        note: String = "课堂演示用，全部为示例假设值",
        distance: RuleDistance = RuleDistance(),
        duration: RuleDuration = RuleDuration(),
        timeWindows: [TimeWindow] = [TimeWindow()],
        dateRange: DateRange? = nil,
        pace: RulePace = RulePace(),
        cadence: RuleCadence = RuleCadence(),
        route: RuleRoute = RuleRoute(),
        waypoints: WaypointPolicy = WaypointPolicy(),
        validity: RecordValidity = RecordValidity(),
        meta: RuleMeta = RuleMeta()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.note = note
        self.isHypothetical = true
        self.disclaimer = AppConstants.ruleDisclaimer
        self.distance = distance
        self.duration = duration
        self.timeWindows = timeWindows
        self.dateRange = dateRange
        self.pace = pace
        self.cadence = cadence
        self.route = route
        self.waypoints = waypoints
        self.validity = validity
        self.meta = meta
        self.dataOrigin = .simulated
    }

    /// 解码：`isHypothetical == false` 一律拒绝（`DecodingError`），
    /// 由 F38 RuleValidator 转成 `AppError.ruleHypotheticalViolation`（V2.5）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        displayName = try container.decode(String.self, forKey: .displayName)
        note = try container.decode(String.self, forKey: .note)
        let decodedHypothetical = try container.decode(Bool.self, forKey: .isHypothetical)
        guard decodedHypothetical else {
            throw DecodingError.dataCorruptedError(
                forKey: .isHypothetical,
                in: container,
                debugDescription: "isHypothetical 必须为 true：拒绝内置真实规则或非假设预设"
            )
        }
        isHypothetical = true
        disclaimer = AppConstants.ruleDisclaimer
        distance = try container.decode(RuleDistance.self, forKey: .distance)
        duration = try container.decode(RuleDuration.self, forKey: .duration)
        timeWindows = try container.decode([TimeWindow].self, forKey: .timeWindows)
        dateRange = try container.decodeIfPresent(DateRange.self, forKey: .dateRange)
        pace = try container.decode(RulePace.self, forKey: .pace)
        cadence = try container.decode(RuleCadence.self, forKey: .cadence)
        route = try container.decode(RuleRoute.self, forKey: .route)
        waypoints = try container.decode(WaypointPolicy.self, forKey: .waypoints)
        validity = try container.decode(RecordValidity.self, forKey: .validity)
        meta = try container.decode(RuleMeta.self, forKey: .meta)
        dataOrigin = .simulated
    }

    /// 编码：强制写出 `isHypothetical: true` + 固定免责声明 + `dataOrigin: simulated`。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(note, forKey: .note)
        try container.encode(true, forKey: .isHypothetical)
        try container.encode(AppConstants.ruleDisclaimer, forKey: .disclaimer)
        try container.encode(distance, forKey: .distance)
        try container.encode(duration, forKey: .duration)
        try container.encode(timeWindows, forKey: .timeWindows)
        try container.encodeIfPresent(dateRange, forKey: .dateRange)
        try container.encode(pace, forKey: .pace)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(route, forKey: .route)
        try container.encode(waypoints, forKey: .waypoints)
        try container.encode(validity, forKey: .validity)
        try container.encode(meta, forKey: .meta)
        try container.encode(DataOrigin.simulated, forKey: .dataOrigin)
    }

    /// 参数合法性自检（供 F38 RuleValidator 复用）。
    public var isBasicallyValid: Bool {
        distance.isValid && duration.isValid && pace.isValid && cadence.isValid
            && waypoints.isValid && (dateRange.map(\.isValid) ?? true)
            && timeWindows.allSatisfy(\.isValid)
            && schemaVersion == AppConstants.schemaVersion
            && isHypothetical
            && dataOrigin == .simulated
    }

    /// 生成副本：新 id、保留 `comparisonGroup`，合规字段依旧强制。
    public func duplicate(newID: String = UUID().uuidString) -> RulePreset {
        RulePreset(
            id: newID,
            schemaVersion: schemaVersion,
            displayName: displayName + "（副本）",
            note: note,
            distance: distance,
            duration: duration,
            timeWindows: timeWindows,
            dateRange: dateRange,
            pace: pace,
            cadence: cadence,
            route: route,
            waypoints: waypoints,
            validity: validity,
            meta: meta.duplicate()
        )
    }

    /// 示例假设预设（§B.7.2 JSON 契约的字段值；非任何平台真实规则）。
    public static func exampleHypothetical() -> RulePreset {
        RulePreset()
    }
}
