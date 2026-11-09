import Foundation

/// WGS84 经纬度值对象（单位：度）。
public struct GeoPoint: Codable, Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 是否为合法地理坐标（传入三角函数前必须校验）。
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180
    }

    /// 归一化到合法范围（用于生成坐标的兜底，不改变数据语义）。
    public var normalized: GeoPoint {
        GeoPoint(
            latitude: latitude.clamped(to: -90...90),
            longitude: longitude.clamped(to: -180...180)
        )
    }
}

/// 采样点质量标记（§B.8）。
public enum QualityFlag: String, Codable, Sendable, CaseIterable {
    case lowAccuracy
    case driftSuspect
    case gap
    case paused
    case interpolatedFalse

    /// 面向用户的中文说明。
    public var localizedDescription: String {
        switch self {
        case .lowAccuracy: return "低精度"
        case .driftSuspect: return "疑似漂移"
        case .gap: return "信号中断段"
        case .paused: return "暂停（不计距）"
        case .interpolatedFalse: return "非插值（实测）"
        }
    }
}

/// 单个轨迹采样点（§3.2 / §B.8 全字段）。
/// `dataOrigin` 强制不可变 `let`，继承 `RunSession`，构造后无 setter、无转换器。
public struct TrackPoint: Identifiable, Codable, Sendable {
    public let id: String
    public let sessionId: String
    public let dataOrigin: DataOrigin
    public let timestamp: Date
    public let elapsedSeconds: TimeInterval
    public let latitude: Double
    public let longitude: Double
    public let altitudeM: Double
    public let horizontalAccuracyM: Double
    public let verticalAccuracyM: Double
    public let courseDegrees: Double
    public let speedMps: Double
    public let speedAccuracyMps: Double
    public let instantPaceSecPerKm: Double
    public let avgPaceSecPerKm: Double
    public let cadenceSpm: Double
    public let strideLengthM: Double
    public let cumulativeSteps: Double
    public let cumulativeDistanceM: Double
    public let elevationGainSoFarM: Double
    public let elevationLossSoFarM: Double
    public let segmentIndex: Int
    public let qualityFlags: [QualityFlag]

    public init(
        id: String,
        sessionId: String,
        dataOrigin: DataOrigin,
        timestamp: Date,
        elapsedSeconds: TimeInterval,
        latitude: Double,
        longitude: Double,
        altitudeM: Double,
        horizontalAccuracyM: Double = -1,
        verticalAccuracyM: Double = -1,
        courseDegrees: Double = 0,
        speedMps: Double = 0,
        speedAccuracyMps: Double = -1,
        instantPaceSecPerKm: Double = 0,
        avgPaceSecPerKm: Double = 0,
        cadenceSpm: Double = 0,
        strideLengthM: Double = 0,
        cumulativeSteps: Double = 0,
        cumulativeDistanceM: Double = 0,
        elevationGainSoFarM: Double = 0,
        elevationLossSoFarM: Double = 0,
        segmentIndex: Int = 0,
        qualityFlags: [QualityFlag] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
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
        self.qualityFlags = qualityFlags
    }

    /// 经纬度值对象（供 Haversine / 地图使用；日志禁止写出此值）。
    public var geoPoint: GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// 是否被打上暂停标记（暂停段不计距、跨段不连线）。
    public var isPaused: Bool {
        qualityFlags.contains(.paused)
    }

    /// 是否存在信号中断标记。
    public var hasGap: Bool {
        qualityFlags.contains(.gap)
    }

    /// 是否通过精度门限（负值 = 无效）。
    public var hasValidAccuracy: Bool {
        horizontalAccuracyM >= 0 && horizontalAccuracyM <= AppConstants.accuracyGateMeters
    }

    /// 返回追加质量标记后的新点（值类型，不修改原对象）。
    public func adding(flag: QualityFlag) -> TrackPoint {
        guard !qualityFlags.contains(flag) else { return self }
        // 通过重新构造保证所有 `let` 字段保持不可变语义。
        return TrackPoint(
            id: id,
            sessionId: sessionId,
            dataOrigin: dataOrigin,
            timestamp: timestamp,
            elapsedSeconds: elapsedSeconds,
            latitude: latitude,
            longitude: longitude,
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
            qualityFlags: qualityFlags + [flag]
        )
    }
}
