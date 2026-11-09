import Foundation

/// 路线类型。
public enum RouteType: String, Codable, Sendable, CaseIterable {
    case loop
    case outAndBack
    case free

    public var localizedDescription: String {
        switch self {
        case .loop: return "环形"
        case .outAndBack: return "折返"
        case .free: return "自由"
        }
    }
}

/// 海拔来源（必标来源，禁止臆造）。
public enum ElevationSource: String, Codable, Sendable, CaseIterable {
    case userDefined
    case gpx
    case device
    case externalService

    public var localizedDescription: String {
        switch self {
        case .userDefined: return "用户自定义（假设值）"
        case .gpx: return "GPX <ele> 导入"
        case .device: return "设备气压计（实测）"
        case .externalService: return "外部高程服务（需联网同意）"
        }
    }
}

/// 点位种类（用户放置，非任何平台点位）。
public enum WaypointKind: String, Codable, Sendable, CaseIterable {
    case mandatory
    case random
    case finish

    public var localizedDescription: String {
        switch self {
        case .mandatory: return "必经点"
        case .random: return "普通点"
        case .finish: return "终点"
        }
    }
}

/// 海拔剖面段类型。
public enum ElevationSegmentKind: String, Codable, Sendable, CaseIterable {
    case uphill
    case downhill
    case flat

    public var localizedDescription: String {
        switch self {
        case .uphill: return "上坡"
        case .downhill: return "下坡"
        case .flat: return "平路"
        }
    }
}

/// 路线点（§3.2）。`arcLengthFromStartM` 由 F27 弧长参数化写入。
public struct RoutePoint: Codable, Sendable, Hashable {
    public let id: String
    public let orderIndex: Int
    public let latitude: Double
    public let longitude: Double
    public let altitudeM: Double?
    public let arcLengthFromStartM: Double

    public init(
        id: String = UUID().uuidString,
        orderIndex: Int,
        latitude: Double,
        longitude: Double,
        altitudeM: Double? = nil,
        arcLengthFromStartM: Double = 0
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeM = altitudeM
        self.arcLengthFromStartM = arcLengthFromStartM
    }

    public var geoPoint: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }
}

/// 路线版本快照（§B.8）。`snapshot` 为 `[RoutePoint]` 的 JSON 编码，可回溯。
public struct RouteVersion: Identifiable, Codable, Sendable {
    public let id: String
    public let routeId: String
    public let snapshot: Data
    public let createdAt: Date
    public let changeNote: String

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(
        id: String = UUID().uuidString,
        routeId: String,
        snapshot: Data,
        createdAt: Date = Date(),
        changeNote: String = ""
    ) {
        self.id = id
        self.routeId = routeId
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.changeNote = changeNote
    }

    /// 由点位数组生成快照。
    public init(
        id: String = UUID().uuidString,
        routeId: String,
        points: [RoutePoint],
        createdAt: Date = Date(),
        changeNote: String = ""
    ) throws {
        let data = try RouteVersion.encoder.encode(points)
        self.init(
            id: id,
            routeId: routeId,
            snapshot: data,
            createdAt: createdAt,
            changeNote: changeNote
        )
    }

    /// 解码快照点位；损坏时返回空数组，不臆造点位。
    public func decodedPoints() -> [RoutePoint] {
        (try? RouteVersion.decoder.decode([RoutePoint].self, from: snapshot)) ?? []
    }
}

/// 用户放置的点位（半径是假设值，UI 必须标注）。
public struct Waypoint: Identifiable, Codable, Sendable {
    public let id: String
    public let routeId: String
    public let kind: WaypointKind
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let orderIndex: Int?

    public init(
        id: String = UUID().uuidString,
        routeId: String,
        kind: WaypointKind,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 50,
        orderIndex: Int? = nil
    ) {
        self.id = id
        self.routeId = routeId
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.orderIndex = orderIndex
    }

    public var geoPoint: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// 判断给定坐标是否落在判定半径内（Haversine 口径）。
    public func contains(_ point: GeoPoint) -> Bool {
        Units.haversineMeters(geoPoint, point) <= radiusMeters
    }
}

/// 海拔剖面段（§B.8）。
public struct ElevationSegment: Identifiable, Codable, Sendable {
    public let id: String
    public let startArcLengthM: Double
    public let endArcLengthM: Double
    public let slopePercent: Double
    public let kind: ElevationSegmentKind

    public init(
        id: String = UUID().uuidString,
        startArcLengthM: Double,
        endArcLengthM: Double,
        slopePercent: Double,
        kind: ElevationSegmentKind
    ) {
        self.id = id
        self.startArcLengthM = startArcLengthM
        self.endArcLengthM = endArcLengthM
        self.slopePercent = slopePercent
        self.kind = kind
    }

    /// 段长（m），负值视为 0。
    public var lengthM: Double {
        max(0, endArcLengthM - startArcLengthM)
    }

    /// 该段在弧长 `s` 处的海拔增量（相对段起点，线性插值）。
    public func altitudeDelta(atArcLength s: Double) -> Double {
        guard s > startArcLengthM, lengthM > 0 else { return 0 }
        let clamped = min(s, endArcLengthM)
        let horizontal = clamped - startArcLengthM
        return horizontal * slopePercent / 100
    }
}

/// 海拔误差模型（§B.8：bias / drift / noise / deadband）。
public struct ElevationErrorModel: Codable, Sendable, Hashable {
    public let biasM: Double
    public let driftMPerSecond: Double
    public let noiseAmplitudeM: Double
    public let deadbandMeters: Double

    public init(
        biasM: Double = 0,
        driftMPerSecond: Double = 0,
        noiseAmplitudeM: Double = 0,
        deadbandMeters: Double = AppConstants.elevationDeadbandMeters
    ) {
        self.biasM = biasM
        self.driftMPerSecond = driftMPerSecond
        self.noiseAmplitudeM = noiseAmplitudeM
        self.deadbandMeters = deadbandMeters
    }

    /// 无误差模型。
    public static let none = ElevationErrorModel()

    /// 在给定时间上确定性地计算 bias + drift（噪声由 SeededRandom 统一驱动，避免独立随机）。
    public func deterministicOffset(atTime t: TimeInterval) -> Double {
        guard t.isFinite else { return biasM }
        return biasM + driftMPerSecond * t
    }
}

/// 海拔剖面（§B.8）。
public struct ElevationProfile: Identifiable, Codable, Sendable {
    public let id: String
    public let routeId: String
    public let initialAltitudeM: Double
    public let segments: [ElevationSegment]
    public let source: ElevationSource
    public let errorModel: ElevationErrorModel

    public init(
        id: String = UUID().uuidString,
        routeId: String,
        initialAltitudeM: Double = 0,
        segments: [ElevationSegment] = [],
        source: ElevationSource = .userDefined,
        errorModel: ElevationErrorModel = .none
    ) {
        self.id = id
        self.routeId = routeId
        self.initialAltitudeM = initialAltitudeM
        self.segments = segments
        self.source = source
        self.errorModel = errorModel
    }

    /// 在弧长 `s` 处的基准海拔（不含误差模型；误差由 F28 统一注入）。
    /// 段外返回初始海拔加上末段累计增量，绝不臆造缺失剖面。
    public func altitude(atArcLength s: Double) -> Double {
        var altitude = initialAltitudeM
        let ordered = segments.sorted { $0.startArcLengthM < $1.startArcLengthM }
        guard !ordered.isEmpty else { return altitude }
        var index = 0
        while index < ordered.count {
            let segment = ordered[index]
            if s <= segment.startArcLengthM { break }
            altitude += segment.altitudeDelta(atArcLength: s)
            if s <= segment.endArcLengthM { break }
            index += 1
        }
        return altitude
    }

    /// 剖面总覆盖长度（m）。
    public var coveredLengthM: Double {
        segments.reduce(0) { $0 + $1.lengthM }
    }
}

/// 用户自建路线（§3.2）。**不含 `dataOrigin`**：由引用它的 `RunSession` 决定导出标记。
public struct Route: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let routeType: RouteType
    public let totalDistanceM: Double
    public let points: [RoutePoint]
    public let waypoints: [Waypoint]
    public let elevationProfile: ElevationProfile
    public let versions: [RouteVersion]
    public let currentVersionId: String
    public let elevationSource: ElevationSource
    public let externalServiceAttribution: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        routeType: RouteType = .loop,
        totalDistanceM: Double = 0,
        points: [RoutePoint] = [],
        waypoints: [Waypoint] = [],
        elevationProfile: ElevationProfile,
        versions: [RouteVersion] = [],
        currentVersionId: String = "",
        elevationSource: ElevationSource = .userDefined,
        externalServiceAttribution: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.routeType = routeType
        self.totalDistanceM = totalDistanceM
        self.points = points
        self.waypoints = waypoints
        self.elevationProfile = elevationProfile
        self.versions = versions
        self.currentVersionId = currentVersionId
        self.elevationSource = elevationSource
        self.externalServiceAttribution = externalServiceAttribution
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 便捷构造：自动补齐与路线 id 绑定的海拔剖面与当前版本 id。
    public init(
        id: String = UUID().uuidString,
        name: String,
        routeType: RouteType = .loop,
        points: [RoutePoint] = [],
        waypoints: [Waypoint] = [],
        elevationSource: ElevationSource = .userDefined
    ) {
        let profile = ElevationProfile(routeId: id, source: elevationSource)
        self.init(
            id: id,
            name: name,
            routeType: routeType,
            points: points,
            waypoints: waypoints,
            elevationProfile: profile,
            currentVersionId: "\(id)_v1",
            elevationSource: elevationSource
        )
    }

    /// 按 `orderIndex` 排序的点位（弧长计算的输入）。
    public func orderedPoints() -> [RoutePoint] {
        points.sorted { $0.orderIndex < $1.orderIndex }
    }

    /// 是否闭合环形（首尾近似重合，容差 5 m）。
    public func isClosedLoop(toleranceMeters: Double = 5) -> Bool {
        let ordered = orderedPoints()
        guard let first = ordered.first, let last = ordered.last, ordered.count > 2 else { return false }
        return Units.haversineMeters(first.geoPoint, last.geoPoint) <= toleranceMeters
    }
}
