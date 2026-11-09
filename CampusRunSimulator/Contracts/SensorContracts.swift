import Foundation

// MARK: - 传感器流值对象（仅 REAL 链路）

/// Core Location 采样。来源恒 `.real`，初始化器内部强制。
public struct LocationSample: Sendable {
    public let coordinate: GeoPoint
    public let altitudeM: Double
    public let horizontalAccuracyM: Double
    public let verticalAccuracyM: Double
    public let courseDegrees: Double
    public let speedMps: Double
    public let timestamp: Date
    public let dataOrigin: DataOrigin

    public init(
        coordinate: GeoPoint,
        altitudeM: Double,
        horizontalAccuracyM: Double,
        verticalAccuracyM: Double,
        courseDegrees: Double,
        speedMps: Double,
        timestamp: Date
    ) {
        self.coordinate = coordinate
        self.altitudeM = altitudeM
        self.horizontalAccuracyM = horizontalAccuracyM
        self.verticalAccuracyM = verticalAccuracyM
        self.courseDegrees = courseDegrees
        self.speedMps = speedMps
        self.timestamp = timestamp
        self.dataOrigin = .real
    }

    /// 是否通过 50 m 精度门限（负值表示无效，直接丢弃）。
    public var passesAccuracyGate: Bool {
        horizontalAccuracyM >= 0 && horizontalAccuracyM <= AppConstants.accuracyGateMeters
    }
}

/// Core Motion 运动状态。
public enum MotionActivityKind: String, Codable, Sendable, CaseIterable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown
}

/// Core Motion 采样。来源恒 `.real`，初始化器内部强制。
/// 单位换算是 `Units` 的职责：paceMinPerKm 已由 s/m × 1000/60 得到，cadenceSpm 已由 步/秒 × 60 得到。
public struct MotionSample: Sendable {
    public let timestamp: Date
    public let steps: Int?
    public let distanceM: Double?
    public let paceMinPerKm: Double?
    public let cadenceSpm: Double?
    public let relativeAltitudeM: Double?
    public let absoluteAltitudeM: Double?
    public let activity: MotionActivityKind?
    public let dataOrigin: DataOrigin

    public init(
        timestamp: Date,
        steps: Int? = nil,
        distanceM: Double? = nil,
        paceMinPerKm: Double? = nil,
        cadenceSpm: Double? = nil,
        relativeAltitudeM: Double? = nil,
        absoluteAltitudeM: Double? = nil,
        activity: MotionActivityKind? = nil
    ) {
        self.timestamp = timestamp
        self.steps = steps
        self.distanceM = distanceM
        self.paceMinPerKm = paceMinPerKm
        self.cadenceSpm = cadenceSpm
        self.relativeAltitudeM = relativeAltitudeM
        self.absoluteAltitudeM = absoluteAltitudeM
        self.activity = activity
        self.dataOrigin = .real
    }

    /// 相对海拔叠加 `h0` 得到绝对海拔；缺失时返回 nil，绝不臆造。
    public func resolvedAltitude(initialAltitudeM: Double) -> Double? {
        if let absoluteAltitudeM = absoluteAltitudeM {
            return absoluteAltitudeM
        }
        guard let relativeAltitudeM = relativeAltitudeM else { return nil }
        return Units.absoluteAltitude(relativeM: relativeAltitudeM, initialAltitudeM: initialAltitudeM)
    }
}

/// 传感器可用性分支（不可用时字段标注「不可用」，不得臆造数值）。
public struct MotionAvailability: Sendable, Hashable {
    public let pedometerAvailable: Bool
    public let relativeAltitudeAvailable: Bool
    public let absoluteAltitudeAvailable: Bool
    public let activityAvailable: Bool
    public let note: String

    public init(
        pedometerAvailable: Bool,
        relativeAltitudeAvailable: Bool,
        absoluteAltitudeAvailable: Bool,
        activityAvailable: Bool,
        note: String = ""
    ) {
        self.pedometerAvailable = pedometerAvailable
        self.relativeAltitudeAvailable = relativeAltitudeAvailable
        self.absoluteAltitudeAvailable = absoluteAltitudeAvailable
        self.activityAvailable = activityAvailable
        self.note = note
    }

    public static let fullyUnavailable = MotionAvailability(
        pedometerAvailable: false,
        relativeAltitudeAvailable: false,
        absoluteAltitudeAvailable: false,
        activityAvailable: false,
        note: "运动传感器不可用，相关字段按「不可用」处理"
    )

    /// 面向用户的中文说明。
    public var summary: String {
        var parts: [String] = []
        parts.append("计步器：\(pedometerAvailable ? "可用" : "不可用")")
        parts.append("相对海拔：\(relativeAltitudeAvailable ? "可用" : "不可用")")
        parts.append("绝对海拔：\(absoluteAltitudeAvailable ? "可用" : "不可用")")
        parts.append("运动状态：\(activityAvailable ? "可用" : "不可用")")
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "；")
    }
}

/// 权限快照（F32/F33/F34 提供）。
/// 读取权限不可判定（HealthKit 隐私语义）时必须为 `.unknown`，按「无数据」呈现，不得提示「被拒绝」。
public struct PermissionSnapshot: Sendable, Hashable {
    public let locationStatus: PermissionStatus
    public let preciseLocationEnabled: Bool
    public let motionStatus: PermissionStatus
    public let healthKitReadStatus: PermissionStatus
    public let healthKitShareStatus: PermissionStatus
    public let backgroundDeliveryAvailable: Bool
    public let capturedAt: Date
    public let note: String

    public init(
        locationStatus: PermissionStatus = .unknown,
        preciseLocationEnabled: Bool = false,
        motionStatus: PermissionStatus = .unknown,
        healthKitReadStatus: PermissionStatus = .unknown,
        healthKitShareStatus: PermissionStatus = .unknown,
        backgroundDeliveryAvailable: Bool = false,
        capturedAt: Date = Date(),
        note: String = ""
    ) {
        self.locationStatus = locationStatus
        self.preciseLocationEnabled = preciseLocationEnabled
        self.motionStatus = motionStatus
        self.healthKitReadStatus = healthKitReadStatus
        self.healthKitShareStatus = healthKitShareStatus
        self.backgroundDeliveryAvailable = backgroundDeliveryAvailable
        self.capturedAt = capturedAt
        self.note = note
    }

    /// 全 unknown 快照（读取权限不可判定时的安全默认）。
    public static let unknown = PermissionSnapshot()

    /// 是否允许开始真实记录（WhenInUse / Always + 精确位置建议）。
    public var canStartLiveRun: Bool {
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// 是否存在需要横幅提示的权限异常。
    public var hasDegradedPermission: Bool {
        if !canStartLiveRun { return true }
        if !preciseLocationEnabled { return true }
        if healthKitShareStatus == .denied || healthKitShareStatus == .restricted { return true }
        return false
    }

    /// 面向用户的摘要（读取权限不可判定统一表述为「无数据」）。
    public var summary: String {
        var lines: [String] = []
        lines.append("定位：\(locationStatus.localizedDescription)")
        lines.append("精确位置：\(preciseLocationEnabled ? "已开启" : "未开启")")
        lines.append("运动传感器：\(motionStatus.localizedDescription)")
        lines.append("健康数据读取：\(healthKitReadStatus == .unknown ? "无数据" : healthKitReadStatus.localizedDescription)")
        lines.append("健康数据写入：\(healthKitShareStatus.localizedDescription)")
        if !note.isEmpty { lines.append(note) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 服务侧协议（§3.2 冻结签名）

/// 定位提供者（仅 REAL 链路）。
public protocol LocationProvider: AnyObject {
    var samples: AsyncStream<LocationSample> { get }
    var authorizationSnapshot: PermissionSnapshot { get }
    func requestAuthorization()
    func start() throws
    func pause()
    func resume()
    func stop()
}

/// 运动传感器提供者（仅 REAL 链路）。
public protocol MotionProvider: AnyObject {
    var samples: AsyncStream<MotionSample> { get }
    func availability() -> MotionAvailability
    func start(from: Date) throws
    func stop()
}

/// 健康数据服务。
/// - 重要合规契约：`write(session:routePoints:)` 实现首行必须
///   `guard session.dataOrigin == .real else { throw AppError.simulatedWriteForbidden }`。
///   本服务**仅 `.real` 可写**，不存在任何 `simulated -> HealthKit` 路径。
public protocol HealthKitService: Sendable {
    /// 读授权单独申请。
    func requestReadAuthorization() async throws
    /// 写授权单独申请。
    func requestShareAuthorization() async throws
    /// 读取权限不可判定 → `.unknown`「无数据」。
    func readStatus() async -> PermissionSnapshot
    /// 仅 `.real`：把真实跑步记录写入健康 App；测试数据一律拒绝。
    func write(session: RunSession, routePoints: [TrackPoint]) async throws
    /// 后台 delivery：entitlement / stepCount 上限 hourly / 模拟器不支持需提示 / 必须调用 completion。
    func enableBackgroundDelivery() async throws
}

/// 规则评估协议（三态、无分数）。
public protocol RuleEvaluating: Sendable {
    /// 前置守卫：`session.dataOrigin == .simulated`，REAL 记录不参与规则评估。
    func evaluate(
        session: RunSession,
        points: [TrackPoint],
        presets: [RulePreset]
    ) -> [RuleEvaluationResult]
    /// 多预设并列对比，只显示用户自建预设名称。
    func compare(_ results: [RuleEvaluationResult]) -> ComparisonTable
}

/// 导出管理协议（单一来源守卫 + 三重标记 + 审计）。
public protocol ExportManaging: Sendable {
    /// 混合来源输入抛 `AppError.mixedOriginExportForbidden`。
    func export(
        session: RunSession,
        points: [TrackPoint],
        format: ExportFormat
    ) async throws -> ExportedFile
    /// 每次导出持久化 `ExportRecord` 用于合规审计。
    func audit(_ record: ExportRecord) async
}

/// 三重标记协议（缺一即拒绝导出，`AppError.missingOriginMarker`）。
public protocol DataMarking: Sendable {
    /// `SIMULATED_YYYYMMDD_HHMMSS.<ext>` / `REAL_YYYYMMDD_HHMMSS.<ext>`（UTC）。
    func fileName(_ origin: DataOrigin, format: ExportFormat, date: Date) -> String
    /// 文件内 metadata：dataOrigin / isHypothetical / disclaimer / generator / schemaVersion。
    func metadataBlock(_ origin: DataOrigin) -> MarkerMetadata
    /// CSV 首行注释（或 GPX/JSON 对应的首行说明）。
    func firstLineComment(_ origin: DataOrigin) -> String
    /// JSON 顶层标记字典。
    func jsonTopLevel(_ origin: DataOrigin) -> [String: String]
    /// 校验三重标记，缺失即抛错。
    func verifyMarkers(_ data: Data, origin: DataOrigin, format: ExportFormat) throws
}
