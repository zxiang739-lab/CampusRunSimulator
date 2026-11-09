import Foundation
import SwiftData

// MARK: - SwiftData 持久化对象（统一 SD 前缀，§7.8）
//
// 合规不变式：
// 1. `dataOriginRaw` 仅在 `init` 赋值；无公开 setter、无 mutating 方法；迁移 stage 禁止任何改写。
// 2. 每个类 `@Attribute(.unique) var id`，写入前按来源加 `sim_` / `real_` 前缀，两个容器 id 空间独立。
// 3. 复杂嵌套值类型统一用 JSON blob 持久化（Codable），双向转换由 SDMapper 完成。
// 4. `@Model` 不泄漏到 UI 层；UI 只见领域值类型。

/// 会话持久化对象。
@Model
public final class SDRunSession {
    @Attribute(.unique) public var id: String
    /// 合规字段：只在 init 赋值，绝不改写（含迁移）。
    public var dataOriginRaw: String
    public var startTime: Date
    public var endTime: Date
    public var durationSeconds: Double
    public var totalDistanceMeters: Double
    public var avgSpeedMps: Double
    public var avgPaceSecPerKm: Double
    public var totalSteps: Double
    public var elevationGainM: Double
    public var elevationLossM: Double
    public var routeId: String?
    public var simulationProfileId: String?
    public var rulePresetId: String?
    public var note: String
    public var createdAt: Date
    public var schemaVersion: String
    public var originChainJSON: Data

    /// 级联删除：删除会话时一并删除其全部采样点；反向关系由 SwiftData 由 `SDTrackPoint.session` 自动推断。
    @Relationship(deleteRule: .cascade)
    public var points: [SDTrackPoint]? = []

    public init(
        id: String,
        dataOriginRaw: String,
        startTime: Date,
        endTime: Date,
        durationSeconds: Double,
        totalDistanceMeters: Double,
        avgSpeedMps: Double,
        avgPaceSecPerKm: Double,
        totalSteps: Double,
        elevationGainM: Double,
        elevationLossM: Double,
        routeId: String?,
        simulationProfileId: String?,
        rulePresetId: String?,
        note: String,
        createdAt: Date,
        schemaVersion: String,
        originChainJSON: Data
    ) {
        self.id = id
        self.dataOriginRaw = dataOriginRaw
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.totalDistanceMeters = totalDistanceMeters
        self.avgSpeedMps = avgSpeedMps
        self.avgPaceSecPerKm = avgPaceSecPerKm
        self.totalSteps = totalSteps
        self.elevationGainM = elevationGainM
        self.elevationLossM = elevationLossM
        self.routeId = routeId
        self.simulationProfileId = simulationProfileId
        self.rulePresetId = rulePresetId
        self.note = note
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.originChainJSON = originChainJSON
    }
}

/// 采样点持久化对象（全标量与 TrackPoint 一一对应）。
@Model
public final class SDTrackPoint {
    @Attribute(.unique) public var id: String
    public var sessionId: String
    /// 合规字段：只在 init 赋值。
    public var dataOriginRaw: String
    public var timestamp: Date
    public var elapsedSeconds: Double
    public var latitude: Double
    public var longitude: Double
    public var altitudeM: Double
    public var horizontalAccuracyM: Double
    public var verticalAccuracyM: Double
    public var courseDegrees: Double
    public var speedMps: Double
    public var speedAccuracyMps: Double
    public var instantPaceSecPerKm: Double
    public var avgPaceSecPerKm: Double
    public var cadenceSpm: Double
    public var strideLengthM: Double
    public var cumulativeSteps: Double
    public var cumulativeDistanceM: Double
    public var elevationGainSoFarM: Double
    public var elevationLossSoFarM: Double
    public var segmentIndex: Int
    public var qualityFlagsJSON: Data

    /// 反向关系由 `SDRunSession.points` 的 inverse 建立。
    public var session: SDRunSession?

    public init(
        id: String,
        sessionId: String,
        dataOriginRaw: String,
        timestamp: Date,
        elapsedSeconds: Double,
        latitude: Double,
        longitude: Double,
        altitudeM: Double,
        horizontalAccuracyM: Double,
        verticalAccuracyM: Double,
        courseDegrees: Double,
        speedMps: Double,
        speedAccuracyMps: Double,
        instantPaceSecPerKm: Double,
        avgPaceSecPerKm: Double,
        cadenceSpm: Double,
        strideLengthM: Double,
        cumulativeSteps: Double,
        cumulativeDistanceM: Double,
        elevationGainSoFarM: Double,
        elevationLossSoFarM: Double,
        segmentIndex: Int,
        qualityFlagsJSON: Data
    ) {
        self.id = id
        self.sessionId = sessionId
        self.dataOriginRaw = dataOriginRaw
        self.timestamp = timestamp
        self.elapsedSeconds = elapsedSeconds
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeM = altitudeM
        self.horizontalAccuracyM = horizontalAccuracyM
        self.verticalAccuracyM = verticalAccuracyM
        self.courseDegrees = courseDegrees
        self.speedMps = speedMps
        self.speedAccuracyMps = speedAccuracyMps
        self.instantPaceSecPerKm = instantPaceSecPerKm
        self.avgPaceSecPerKm = avgPaceSecPerKm
        self.cadenceSpm = cadenceSpm
        self.strideLengthM = strideLengthM
        self.cumulativeSteps = cumulativeSteps
        self.cumulativeDistanceM = cumulativeDistanceM
        self.elevationGainSoFarM = elevationGainSoFarM
        self.elevationLossSoFarM = elevationLossSoFarM
        self.segmentIndex = segmentIndex
        self.qualityFlagsJSON = qualityFlagsJSON
    }
}

/// 路线持久化对象（用户自建中立对象，无 dataOrigin）。
@Model
public final class SDRoute {
    @Attribute(.unique) public var id: String
    public var name: String
    public var routeTypeRaw: String
    public var totalDistanceM: Double
    public var pointsJSON: Data
    public var waypointsJSON: Data
    public var elevationProfileJSON: Data
    public var currentVersionId: String
    public var elevationSourceRaw: String
    public var externalServiceAttribution: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// 版本快照级联删除，可回溯；反向关系由 `SDRouteVersion.route` 自动推断。
    @Relationship(deleteRule: .cascade)
    public var versions: [SDRouteVersion]? = []

    public init(
        id: String,
        name: String,
        routeTypeRaw: String,
        totalDistanceM: Double,
        pointsJSON: Data,
        waypointsJSON: Data,
        elevationProfileJSON: Data,
        currentVersionId: String,
        elevationSourceRaw: String,
        externalServiceAttribution: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.routeTypeRaw = routeTypeRaw
        self.totalDistanceM = totalDistanceM
        self.pointsJSON = pointsJSON
        self.waypointsJSON = waypointsJSON
        self.elevationProfileJSON = elevationProfileJSON
        self.currentVersionId = currentVersionId
        self.elevationSourceRaw = elevationSourceRaw
        self.externalServiceAttribution = externalServiceAttribution
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 路线版本快照持久化对象。
@Model
public final class SDRouteVersion {
    @Attribute(.unique) public var id: String
    public var routeId: String
    public var snapshot: Data
    public var createdAt: Date
    public var changeNote: String

    public var route: SDRoute?

    public init(
        id: String,
        routeId: String,
        snapshot: Data,
        createdAt: Date,
        changeNote: String
    ) {
        self.id = id
        self.routeId = routeId
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.changeNote = changeNote
    }
}

/// 规则预设持久化对象（假设值强制 true，来源恒 simulated）。
@Model
public final class SDRulePreset {
    @Attribute(.unique) public var id: String
    public var schemaVersion: String
    public var displayName: String
    public var note: String
    public var isHypothetical: Bool
    public var disclaimer: String
    /// 合规字段：只在 init 赋值，恒 `simulated`。
    public var dataOriginRaw: String
    public var comparisonGroup: String
    public var createdAt: Date
    public var updatedAt: Date
    /// 完整 `RulePreset` 的 JSON 编码。
    public var payloadJSON: Data

    public init(
        id: String,
        schemaVersion: String,
        displayName: String,
        note: String,
        isHypothetical: Bool,
        disclaimer: String,
        dataOriginRaw: String,
        comparisonGroup: String,
        createdAt: Date,
        updatedAt: Date,
        payloadJSON: Data
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.note = note
        self.isHypothetical = isHypothetical
        self.disclaimer = disclaimer
        self.dataOriginRaw = dataOriginRaw
        self.comparisonGroup = comparisonGroup
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payloadJSON = payloadJSON
    }
}

/// 仿真配置持久化对象（来源恒 simulated）。
@Model
public final class SDSimulationProfile {
    @Attribute(.unique) public var id: String
    public var name: String
    public var modelTypeRaw: String
    /// UInt64 以十进制字符串保存，避免持久化类型差异导致精度问题。
    public var seedRaw: String
    public var sampleRateHz: Double
    /// 合规字段：只在 init 赋值，恒 `simulated`。
    public var dataOriginRaw: String
    public var createdAt: Date
    /// 完整 `SimulationProfile` 的 JSON 编码。
    public var payloadJSON: Data

    public init(
        id: String,
        name: String,
        modelTypeRaw: String,
        seedRaw: String,
        sampleRateHz: Double,
        dataOriginRaw: String,
        createdAt: Date,
        payloadJSON: Data
    ) {
        self.id = id
        self.name = name
        self.modelTypeRaw = modelTypeRaw
        self.seedRaw = seedRaw
        self.sampleRateHz = sampleRateHz
        self.dataOriginRaw = dataOriginRaw
        self.createdAt = createdAt
        self.payloadJSON = payloadJSON
    }
}

/// 全局设置（单例 id = AppConstants.globalSettingsID，无 dataOrigin）。
@Model
public final class SDAppSettings {
    @Attribute(.unique) public var id: String
    public var payloadJSON: Data
    public var updatedAt: Date

    public init(id: String, payloadJSON: Data, updatedAt: Date) {
        self.id = id
        self.payloadJSON = payloadJSON
        self.updatedAt = updatedAt
    }
}

/// 全局权限状态（单例 id = AppConstants.globalPermissionStateID，无 dataOrigin）。
@Model
public final class SDPermissionState {
    @Attribute(.unique) public var id: String
    public var payloadJSON: Data
    public var lastCheckedAt: Date

    public init(id: String, payloadJSON: Data, lastCheckedAt: Date) {
        self.id = id
        self.payloadJSON = payloadJSON
        self.lastCheckedAt = lastCheckedAt
    }
}

/// 导出审计记录持久化对象。
@Model
public final class SDExportRecord {
    @Attribute(.unique) public var id: String
    public var sessionId: String
    /// 合规字段：只在 init 赋值。
    public var dataOriginRaw: String
    public var format: String
    public var fileName: String
    public var createdAt: Date
    public var markersIncludedJSON: Data
    public var schemaVersion: String

    public init(
        id: String,
        sessionId: String,
        dataOriginRaw: String,
        format: String,
        fileName: String,
        createdAt: Date,
        markersIncludedJSON: Data,
        schemaVersion: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.dataOriginRaw = dataOriginRaw
        self.format = format
        self.fileName = fileName
        self.createdAt = createdAt
        self.markersIncludedJSON = markersIncludedJSON
        self.schemaVersion = schemaVersion
    }
}

/// 错误事件持久化对象。
@Model
public final class SDErrorEvent {
    @Attribute(.unique) public var id: String
    public var sessionId: String?
    public var kind: String
    public var timestamp: Date
    public var messageKey: String
    public var recoverable: Bool
    /// 可选：审计事件按来源分域存储时的来源标记（无来源时 nil）。
    public var dataOriginRaw: String?

    public init(
        id: String,
        sessionId: String?,
        kind: String,
        timestamp: Date,
        messageKey: String,
        recoverable: Bool,
        dataOriginRaw: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.timestamp = timestamp
        self.messageKey = messageKey
        self.recoverable = recoverable
        self.dataOriginRaw = dataOriginRaw
    }
}

// MARK: - 值类型 ↔ 持久化对象双向映射

/// `SDMapper`：全部 `toValue` 返回可选（脏数据 / 缺 `dataOrigin` 返回 nil，交由仓库归入「未分类」，
/// **绝不默认 real**）；全部 `fromValue` 为 `throws`（JSON 编码失败不静默吞掉）。
public enum SDMapper {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 通用编码（供仓库层复用）。
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    /// 通用解码（供仓库层复用）。
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// 从原始字符串解析来源；非法/缺失返回 nil（脏数据隔离）。
    public static func origin(from raw: String?) -> DataOrigin? {
        guard let raw = raw else { return nil }
        return DataOrigin(rawValue: raw)
    }

    // MARK: RunSession

    public static func toValue(_ model: SDRunSession) -> RunSession? {
        guard let origin = origin(from: model.dataOriginRaw) else { return nil }
        let chain = (try? decode([String].self, from: model.originChainJSON)) ?? []
        return RunSession(
            id: model.id,
            dataOrigin: origin,
            startTime: model.startTime,
            endTime: model.endTime,
            durationSeconds: model.durationSeconds,
            totalDistanceMeters: model.totalDistanceMeters,
            avgSpeedMps: model.avgSpeedMps,
            avgPaceSecPerKm: model.avgPaceSecPerKm,
            totalSteps: model.totalSteps,
            elevationGainM: model.elevationGainM,
            elevationLossM: model.elevationLossM,
            routeId: model.routeId,
            simulationProfileId: model.simulationProfileId,
            rulePresetId: model.rulePresetId,
            note: model.note,
            createdAt: model.createdAt,
            schemaVersion: model.schemaVersion,
            originChain: chain
        )
    }

    public static func fromValue(_ value: RunSession) throws -> SDRunSession {
        let chain = try encode(value.originChain)
        return SDRunSession(
            id: OriginID.normalize(value.id, for: value.dataOrigin),
            dataOriginRaw: value.dataOrigin.rawValue,
            startTime: value.startTime,
            endTime: value.endTime,
            durationSeconds: value.durationSeconds,
            totalDistanceMeters: value.totalDistanceMeters,
            avgSpeedMps: value.avgSpeedMps,
            avgPaceSecPerKm: value.avgPaceSecPerKm,
            totalSteps: value.totalSteps,
            elevationGainM: value.elevationGainM,
            elevationLossM: value.elevationLossM,
            routeId: value.routeId,
            simulationProfileId: value.simulationProfileId,
            rulePresetId: value.rulePresetId,
            note: value.note,
            createdAt: value.createdAt,
            schemaVersion: value.schemaVersion,
            originChainJSON: chain
        )
    }

    // MARK: TrackPoint

    public static func toValue(_ model: SDTrackPoint) -> TrackPoint? {
        guard let origin = origin(from: model.dataOriginRaw) else { return nil }
        let flags = (try? decode([QualityFlag].self, from: model.qualityFlagsJSON)) ?? []
        return TrackPoint(
            id: model.id,
            sessionId: model.sessionId,
            dataOrigin: origin,
            timestamp: model.timestamp,
            elapsedSeconds: model.elapsedSeconds,
            latitude: model.latitude,
            longitude: model.longitude,
            altitudeM: model.altitudeM,
            horizontalAccuracyM: model.horizontalAccuracyM,
            verticalAccuracyM: model.verticalAccuracyM,
            courseDegrees: model.courseDegrees,
            speedMps: model.speedMps,
            speedAccuracyMps: model.speedAccuracyMps,
            instantPaceSecPerKm: model.instantPaceSecPerKm,
            avgPaceSecPerKm: model.avgPaceSecPerKm,
            cadenceSpm: model.cadenceSpm,
            strideLengthM: model.strideLengthM,
            cumulativeSteps: model.cumulativeSteps,
            cumulativeDistanceM: model.cumulativeDistanceM,
            elevationGainSoFarM: model.elevationGainSoFarM,
            elevationLossSoFarM: model.elevationLossSoFarM,
            segmentIndex: model.segmentIndex,
            qualityFlags: flags
        )
    }

    public static func fromValue(_ value: TrackPoint) throws -> SDTrackPoint {
        let flags = try encode(value.qualityFlags)
        return SDTrackPoint(
            id: OriginID.normalize(value.id, for: value.dataOrigin),
            sessionId: value.sessionId,
            dataOriginRaw: value.dataOrigin.rawValue,
            timestamp: value.timestamp,
            elapsedSeconds: value.elapsedSeconds,
            latitude: value.latitude,
            longitude: value.longitude,
            altitudeM: value.altitudeM,
            horizontalAccuracyM: value.horizontalAccuracyM,
            verticalAccuracyM: value.verticalAccuracyM,
            courseDegrees: value.courseDegrees,
            speedMps: value.speedMps,
            speedAccuracyMps: value.speedAccuracyMps,
            instantPaceSecPerKm: value.instantPaceSecPerKm,
            avgPaceSecPerKm: value.avgPaceSecPerKm,
            cadenceSpm: value.cadenceSpm,
            strideLengthM: value.strideLengthM,
            cumulativeSteps: value.cumulativeSteps,
            cumulativeDistanceM: value.cumulativeDistanceM,
            elevationGainSoFarM: value.elevationGainSoFarM,
            elevationLossSoFarM: value.elevationLossSoFarM,
            segmentIndex: value.segmentIndex,
            qualityFlagsJSON: flags
        )
    }

    // MARK: Route

    public static func toValue(_ model: SDRoute) -> Route? {
        guard let routeType = RouteType(rawValue: model.routeTypeRaw),
              let source = ElevationSource(rawValue: model.elevationSourceRaw),
              let points = try? decode([RoutePoint].self, from: model.pointsJSON),
              let waypoints = try? decode([Waypoint].self, from: model.waypointsJSON),
              let profile = try? decode(ElevationProfile.self, from: model.elevationProfileJSON) else {
            return nil
        }
        let versions: [RouteVersion] = (model.versions ?? []).compactMap { toValue($0) }
        return Route(
            id: model.id,
            name: model.name,
            routeType: routeType,
            totalDistanceM: model.totalDistanceM,
            points: points,
            waypoints: waypoints,
            elevationProfile: profile,
            versions: versions,
            currentVersionId: model.currentVersionId,
            elevationSource: source,
            externalServiceAttribution: model.externalServiceAttribution,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }

    public static func fromValue(_ value: Route) throws -> SDRoute {
        SDRoute(
            id: value.id,
            name: value.name,
            routeTypeRaw: value.routeType.rawValue,
            totalDistanceM: value.totalDistanceM,
            pointsJSON: try encode(value.points),
            waypointsJSON: try encode(value.waypoints),
            elevationProfileJSON: try encode(value.elevationProfile),
            currentVersionId: value.currentVersionId,
            elevationSourceRaw: value.elevationSource.rawValue,
            externalServiceAttribution: value.externalServiceAttribution,
            createdAt: value.createdAt,
            updatedAt: value.updatedAt
        )
    }

    // MARK: RouteVersion

    public static func toValue(_ model: SDRouteVersion) -> RouteVersion? {
        RouteVersion(
            id: model.id,
            routeId: model.routeId,
            snapshot: model.snapshot,
            createdAt: model.createdAt,
            changeNote: model.changeNote
        )
    }

    public static func fromValue(_ value: RouteVersion, routeId: String? = nil) throws -> SDRouteVersion {
        SDRouteVersion(
            id: value.id,
            routeId: routeId ?? value.routeId,
            snapshot: value.snapshot,
            createdAt: value.createdAt,
            changeNote: value.changeNote
        )
    }

    // MARK: RulePreset

    public static func toValue(_ model: SDRulePreset) -> RulePreset? {
        guard model.isHypothetical,
              origin(from: model.dataOriginRaw) == .simulated,
              let preset = try? decode(RulePreset.self, from: model.payloadJSON),
              preset.isHypothetical,
              preset.dataOrigin == .simulated else {
            return nil
        }
        return preset
    }

    public static func fromValue(_ value: RulePreset) throws -> SDRulePreset {
        SDRulePreset(
            id: value.id,
            schemaVersion: value.schemaVersion,
            displayName: value.displayName,
            note: value.note,
            isHypothetical: true,
            disclaimer: AppConstants.ruleDisclaimer,
            dataOriginRaw: DataOrigin.simulated.rawValue,
            comparisonGroup: value.meta.comparisonGroup,
            createdAt: value.meta.createdAt,
            updatedAt: value.meta.updatedAt,
            payloadJSON: try encode(value)
        )
    }

    // MARK: SimulationProfile

    public static func toValue(_ model: SDSimulationProfile) -> SimulationProfile? {
        guard origin(from: model.dataOriginRaw) == .simulated,
              let profile = try? decode(SimulationProfile.self, from: model.payloadJSON),
              profile.dataOrigin == .simulated else {
            return nil
        }
        return profile
    }

    public static func fromValue(_ value: SimulationProfile) throws -> SDSimulationProfile {
        SDSimulationProfile(
            id: value.id,
            name: value.name,
            modelTypeRaw: value.modelType.rawValue,
            seedRaw: String(value.seed),
            sampleRateHz: value.sampleRateHz,
            dataOriginRaw: DataOrigin.simulated.rawValue,
            createdAt: Date(),
            payloadJSON: try encode(value)
        )
    }

    // MARK: AppSettings

    public static func toValue(_ model: SDAppSettings) -> AppSettings? {
        try? decode(AppSettings.self, from: model.payloadJSON)
    }

    public static func fromValue(_ value: AppSettings) throws -> SDAppSettings {
        SDAppSettings(
            id: AppConstants.globalSettingsID,
            payloadJSON: try encode(value),
            updatedAt: Date()
        )
    }

    // MARK: PermissionState

    public static func toValue(_ model: SDPermissionState) -> PermissionState? {
        try? decode(PermissionState.self, from: model.payloadJSON)
    }

    public static func fromValue(_ value: PermissionState) throws -> SDPermissionState {
        SDPermissionState(
            id: AppConstants.globalPermissionStateID,
            payloadJSON: try encode(value),
            lastCheckedAt: value.lastCheckedAt
        )
    }

    // MARK: ExportRecord

    public static func toValue(_ model: SDExportRecord) -> ExportRecord? {
        guard let origin = origin(from: model.dataOriginRaw) else { return nil }
        let markers = (try? decode([MarkerKind].self, from: model.markersIncludedJSON)) ?? []
        return ExportRecord(
            id: model.id,
            sessionId: model.sessionId,
            dataOrigin: origin,
            format: model.format,
            fileName: model.fileName,
            createdAt: model.createdAt,
            markersIncluded: markers,
            schemaVersion: model.schemaVersion
        )
    }

    public static func fromValue(_ value: ExportRecord) throws -> SDExportRecord {
        SDExportRecord(
            id: value.id,
            sessionId: value.sessionId,
            dataOriginRaw: value.dataOrigin.rawValue,
            format: value.format,
            fileName: value.fileName,
            createdAt: value.createdAt,
            markersIncludedJSON: try encode(value.markersIncluded),
            schemaVersion: value.schemaVersion
        )
    }

    // MARK: ErrorEvent

    public static func toValue(_ model: SDErrorEvent) -> ErrorEvent {
        ErrorEvent(
            id: model.id,
            sessionId: model.sessionId,
            kind: model.kind,
            timestamp: model.timestamp,
            messageKey: model.messageKey,
            recoverable: model.recoverable
        )
    }

    public static func fromValue(_ value: ErrorEvent, origin: DataOrigin? = nil) throws -> SDErrorEvent {
        SDErrorEvent(
            id: value.id,
            sessionId: value.sessionId,
            kind: value.kind,
            timestamp: value.timestamp,
            messageKey: value.messageKey,
            recoverable: value.recoverable,
            dataOriginRaw: origin?.rawValue
        )
    }
}
