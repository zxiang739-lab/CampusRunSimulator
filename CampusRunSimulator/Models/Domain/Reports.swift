import Foundation

/// I1–I10 一致性不变量编号（§3.2 / §7.7）。
public enum InvariantID: String, Codable, CaseIterable, Sendable {
    case I1
    case I2
    case I3
    case I4
    case I5
    case I6
    case I7
    case I8
    case I9
    case I10

    /// 面向用户的中文说明。
    public var localizedDescription: String {
        switch self {
        case .I1: return "时间严格单调递增"
        case .I2: return "位置由弧长唯一决定"
        case .I3: return "距离与轨迹一致"
        case .I4: return "速度 = Δd / Δt"
        case .I5: return "平均量一致"
        case .I6: return "配速一致"
        case .I7: return "步幅 L = 60v/c 且 ΣΔsteps·L ≈ D"
        case .I8: return "海拔 / 坡度 / 反馈可追溯"
        case .I9: return "单一真值源（派生量无独立随机）"
        case .I10: return "同种子逐点可复现"
        }
    }
}

/// 单条不变量校验结果。
public struct InvariantCheck: Codable, Sendable, Hashable {
    public let id: InvariantID
    public let passed: Bool
    public let detail: String
    public let measuredValue: Double?
    public let expectedValue: Double?

    public init(
        id: InvariantID,
        passed: Bool,
        detail: String,
        measuredValue: Double? = nil,
        expectedValue: Double? = nil
    ) {
        self.id = id
        self.passed = passed
        self.detail = detail
        self.measuredValue = measuredValue
        self.expectedValue = expectedValue
    }

    /// 构造一条通过记录。
    public static func pass(_ id: InvariantID, detail: String) -> InvariantCheck {
        InvariantCheck(id: id, passed: true, detail: detail)
    }

    /// 构造一条失败记录。
    public static func fail(
        _ id: InvariantID,
        detail: String,
        measured: Double? = nil,
        expected: Double? = nil
    ) -> InvariantCheck {
        InvariantCheck(id: id, passed: false, detail: detail,
                       measuredValue: measured, expectedValue: expected)
    }
}

/// I1–I10 报告。`allPassed == false` 时引擎拒绝生成（不是警告）。
public struct InvariantReport: Codable, Sendable {
    public let checks: [InvariantCheck]
    public let allPassed: Bool

    public init(checks: [InvariantCheck]) {
        self.checks = checks
        self.allPassed = !checks.isEmpty && checks.allSatisfy(\.passed)
    }

    /// 失败的不变量编号列表（用于 `AppError.invariantFailed`）。
    public var failedIDs: [InvariantID] {
        checks.filter { !$0.passed }.map(\.id)
    }

    /// 全部通过且覆盖 I1–I10 十项。
    public var isCompleteAndPassed: Bool {
        allPassed && Set(checks.map(\.id)) == Set(InvariantID.allCases)
    }

    /// 面向用户的逐项摘要。
    public var summary: String {
        checks.map { "\($0.id.rawValue) \($0.passed ? "通过" : "未通过")：\($0.detail)" }
            .joined(separator: "\n")
    }
}

/// 单条件评估结果（三态 + 实测值 + 假设阈值）。
public struct RuleConditionResult: Codable, Sendable, Hashable {
    public let condition: RuleCondition
    public let outcome: EvaluationOutcome
    public let measuredValue: Double?
    public let hypotheticalThreshold: String
    public let note: String

    public init(
        condition: RuleCondition,
        outcome: EvaluationOutcome,
        measuredValue: Double? = nil,
        hypotheticalThreshold: String,
        note: String = ""
    ) {
        self.condition = condition
        self.outcome = outcome
        self.measuredValue = measuredValue
        self.hypotheticalThreshold = hypotheticalThreshold
        self.note = note
    }

    /// 面向用户的一行说明（含「示例假设值」标注）。
    public var displayText: String {
        var text = "\(condition.localizedDescription)：\(outcome.localizedDescription)"
        text += "（示例假设值 \(hypotheticalThreshold)）"
        if let measuredValue = measuredValue {
            text += String(format: "，实测 %.2f", measuredValue)
        }
        if !note.isEmpty { text += "，\(note)" }
        return text
    }
}

/// 规则评估结果（§B.7.4）。
/// **本类型没有任何 score / grade / rank / validRecord 字段**：评估不产生成绩。
public struct RuleEvaluationResult: Codable, Sendable {
    public let presetId: String
    public let displayName: String
    public let sessionId: String
    public let dataOrigin: DataOrigin
    public let conditionResults: [RuleConditionResult]
    public let overallOutcome: EvaluationOutcome
    public let disclaimer: String
    public let notice: String
    public let evaluatedAt: Date

    public init(
        presetId: String,
        displayName: String,
        sessionId: String,
        dataOrigin: DataOrigin = .simulated,
        conditionResults: [RuleConditionResult],
        overallOutcome: EvaluationOutcome,
        disclaimer: String = AppConstants.ruleDisclaimer,
        notice: String = AppConstants.ruleEvaluationNotice,
        evaluatedAt: Date = Date()
    ) {
        self.presetId = presetId
        self.displayName = displayName
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
        self.conditionResults = conditionResults
        self.overallOutcome = overallOutcome
        self.disclaimer = disclaimer
        self.notice = notice
        self.evaluatedAt = evaluatedAt
    }

    /// 页首 / 导出文件内必须展示的固定文本。
    public var headerText: String {
        "\(disclaimer)\n\(AppConstants.evaluationObjectLabel)\n\(notice)"
    }

    /// REAL 记录不参与规则评估的前置判定。
    public var isEvaluable: Bool {
        dataOrigin == .simulated
    }
}

/// 数据质量报告（§B.13.3-3 / F37）。
public struct DataQualityReport: Codable, Sendable {
    public let sessionId: String
    public let dataOrigin: DataOrigin
    public let totalPointCount: Int
    public let discardedByAccuracyGate: Int
    public let lowAccuracyCount: Int
    public let gapSegmentCount: Int
    public let sparseIntervalCount: Int
    /// 插值生成点数：本项目不插值，恒为 0（用于验收断言）。
    public let interpolatedPointCount: Int
    public let warnings: [String]

    public init(
        sessionId: String,
        dataOrigin: DataOrigin,
        totalPointCount: Int = 0,
        discardedByAccuracyGate: Int = 0,
        lowAccuracyCount: Int = 0,
        gapSegmentCount: Int = 0,
        sparseIntervalCount: Int = 0,
        interpolatedPointCount: Int = 0,
        warnings: [String] = []
    ) {
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
        self.totalPointCount = totalPointCount
        self.discardedByAccuracyGate = discardedByAccuracyGate
        self.lowAccuracyCount = lowAccuracyCount
        self.gapSegmentCount = gapSegmentCount
        self.sparseIntervalCount = sparseIntervalCount
        self.interpolatedPointCount = interpolatedPointCount
        self.warnings = warnings
    }

    /// 由采样点序列生成报告（真实统计逻辑）。
    public static func build(sessionId: String, points: [TrackPoint], discarded: Int = 0) -> DataQualityReport {
        let origin = points.first?.dataOrigin ?? .simulated
        var lowAccuracy = 0
        var gaps = 0
        var sparse = 0
        var segments = Set<Int>()
        var previousTimestamp: Date?
        var previousSegment: Int?
        for point in points {
            if point.qualityFlags.contains(.lowAccuracy) { lowAccuracy += 1 }
            if point.qualityFlags.contains(.gap) { gaps += 1 }
            segments.insert(point.segmentIndex)
            // 跨段不比较间隔：中断新建段，跨段不连线、不计距、不插值。
            if let previousTimestamp = previousTimestamp,
               let previousSegment = previousSegment,
               point.segmentIndex == previousSegment {
                let interval = point.timestamp.timeIntervalSince(previousTimestamp)
                if interval > AppConstants.maxPointIntervalSeconds { sparse += 1 }
            }
            previousTimestamp = point.timestamp
            previousSegment = point.segmentIndex
        }
        var warnings: [String] = []
        if discarded > 0 { warnings.append("被精度门限丢弃 \(discarded) 个点") }
        if sparse > 0 { warnings.append("存在 \(sparse) 处数据稀疏间隔，未插值冒充实测") }
        if gaps > 0 { warnings.append("存在 \(gaps) 处信号中断标记，已分段不连线") }
        return DataQualityReport(
            sessionId: sessionId,
            dataOrigin: origin,
            totalPointCount: points.count,
            discardedByAccuracyGate: discarded,
            lowAccuracyCount: lowAccuracy,
            gapSegmentCount: segments.count,
            sparseIntervalCount: sparse,
            interpolatedPointCount: 0,
            warnings: warnings
        )
    }

    /// 面向用户的摘要。
    public var summary: String {
        var lines = [
            "采样点总数：\(totalPointCount)",
            "精度门限丢弃：\(discardedByAccuracyGate)",
            "低精度点：\(lowAccuracyCount)",
            "分段数：\(gapSegmentCount)",
            "数据稀疏间隔：\(sparseIntervalCount)",
            "插值生成点：\(interpolatedPointCount)（本项目不插值）"
        ]
        lines.append(contentsOf: warnings)
        return lines.joined(separator: "\n")
    }
}

/// 分段统计（F37 `segmentStatistics` 输出）。
public struct SegmentStatistics: Codable, Sendable {
    public let sessionId: String
    public let startIndex: Int
    public let endIndex: Int
    public let pointCount: Int
    public let durationSeconds: TimeInterval
    public let distanceMeters: Double
    public let avgSpeedMps: Double
    public let avgPaceSecPerKm: Double
    public let avgCadenceSpm: Double
    public let avgStrideLengthM: Double
    public let minAltitudeM: Double
    public let maxAltitudeM: Double
    public let elevationGainM: Double
    public let elevationLossM: Double

    public init(
        sessionId: String = "",
        startIndex: Int = 0,
        endIndex: Int = 0,
        pointCount: Int = 0,
        durationSeconds: TimeInterval = 0,
        distanceMeters: Double = 0,
        avgSpeedMps: Double = 0,
        avgPaceSecPerKm: Double = 0,
        avgCadenceSpm: Double = 0,
        avgStrideLengthM: Double = 0,
        minAltitudeM: Double = 0,
        maxAltitudeM: Double = 0,
        elevationGainM: Double = 0,
        elevationLossM: Double = 0
    ) {
        self.sessionId = sessionId
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.pointCount = pointCount
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.avgSpeedMps = avgSpeedMps
        self.avgPaceSecPerKm = avgPaceSecPerKm
        self.avgCadenceSpm = avgCadenceSpm
        self.avgStrideLengthM = avgStrideLengthM
        self.minAltitudeM = minAltitudeM
        self.maxAltitudeM = maxAltitudeM
        self.elevationGainM = elevationGainM
        self.elevationLossM = elevationLossM
    }

    /// 由采样点区间生成统计（真实计算，空区间返回全零结构）。
    public static func build(
        sessionId: String,
        points: [TrackPoint],
        range: ClosedRange<Int>
    ) -> SegmentStatistics {
        guard !points.isEmpty else { return SegmentStatistics(sessionId: sessionId) }
        let lower = max(0, range.lowerBound)
        let upper = min(points.count - 1, range.upperBound)
        guard lower <= upper else { return SegmentStatistics(sessionId: sessionId) }
        let slice = Array(points[lower...upper])
        guard let first = slice.first, let last = slice.last else {
            return SegmentStatistics(sessionId: sessionId)
        }
        let duration = max(0, last.elapsedSeconds - first.elapsedSeconds)
        let distance = max(0, last.cumulativeDistanceM - first.cumulativeDistanceM)
        let altitudes = slice.map(\.altitudeM)
        let gainLoss = Units.elevationGainLoss(altitudes)
        let validSpeeds = slice.map(\.speedMps).filter { $0.isFinite && $0 >= 0 }
        let validCadences = slice.map(\.cadenceSpm).filter { $0.isFinite && $0 >= 0 }
        let validStrides = slice.map(\.strideLengthM).filter { $0.isFinite && $0 >= 0 }
        func average(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
        return SegmentStatistics(
            sessionId: sessionId,
            startIndex: lower,
            endIndex: upper,
            pointCount: slice.count,
            durationSeconds: duration,
            distanceMeters: distance,
            avgSpeedMps: average(validSpeeds),
            avgPaceSecPerKm: Units.averagePaceSecPerKm(totalSeconds: duration, totalMeters: distance),
            avgCadenceSpm: average(validCadences),
            avgStrideLengthM: average(validStrides),
            minAltitudeM: altitudes.min() ?? 0,
            maxAltitudeM: altitudes.max() ?? 0,
            elevationGainM: gainLoss.gain,
            elevationLossM: gainLoss.loss
        )
    }
}

// MARK: - 设置与权限状态

/// 单位制。
public enum UnitSystem: String, Codable, Sendable, CaseIterable {
    case metric
    case imperial

    public var localizedDescription: String {
        switch self {
        case .metric: return "公制（km / m）"
        case .imperial: return "英制（mi / ft）"
        }
    }
}

/// 配速展示格式。
public enum PaceFormat: String, Codable, Sendable, CaseIterable {
    case minPerKm
    case secPerKm

    public var localizedDescription: String {
        switch self {
        case .minPerKm: return "分/公里"
        case .secPerKm: return "秒/公里"
        }
    }
}

/// 外观偏好。
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    public var localizedDescription: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 随机种子策略。
public enum SeedPolicy: String, Codable, Sendable, CaseIterable {
    case fixed
    case generateIfMissing

    public var localizedDescription: String {
        switch self {
        case .fixed: return "使用固定种子"
        case .generateIfMissing: return "缺失时生成并持久化"
        }
    }
}

/// 全局设置（§B.8）。`healthKitWriteEnabled` 默认 `false`。
/// 合规：`healthKitWriteEnabled` **仅对 `.real` 生效**，测试数据永不写入健康 App。
public struct AppSettings: Codable, Sendable, Hashable {
    public let unitSystem: UnitSystem
    public let paceFormat: PaceFormat
    public let appearance: AppearanceMode
    public let dynamicTypeOverride: String?
    public let reduceMotion: Bool
    public let defaultSampleRateHz: Double
    public let seedPolicy: SeedPolicy
    public let defaultNoiseAmplitude: Double
    public let elevationDeadbandMeters: Double
    public let externalElevationEnabled: Bool
    /// 仅对 `.real` 生效；默认关闭，真实记录结束页需逐次显式勾选。
    public let healthKitWriteEnabled: Bool

    public init(
        unitSystem: UnitSystem = .metric,
        paceFormat: PaceFormat = .minPerKm,
        appearance: AppearanceMode = .system,
        dynamicTypeOverride: String? = nil,
        reduceMotion: Bool = false,
        defaultSampleRateHz: Double = AppConstants.defaultSampleRateHz,
        seedPolicy: SeedPolicy = .generateIfMissing,
        defaultNoiseAmplitude: Double = 0.02,
        elevationDeadbandMeters: Double = AppConstants.elevationDeadbandMeters,
        externalElevationEnabled: Bool = false,
        healthKitWriteEnabled: Bool = false
    ) {
        self.unitSystem = unitSystem
        self.paceFormat = paceFormat
        self.appearance = appearance
        self.dynamicTypeOverride = dynamicTypeOverride
        self.reduceMotion = reduceMotion
        self.defaultSampleRateHz = defaultSampleRateHz
        self.seedPolicy = seedPolicy
        self.defaultNoiseAmplitude = defaultNoiseAmplitude
        self.elevationDeadbandMeters = elevationDeadbandMeters
        self.externalElevationEnabled = externalElevationEnabled
        self.healthKitWriteEnabled = healthKitWriteEnabled
    }

    public static let `default` = AppSettings()

    /// 返回修改某个字段后的新设置（值类型，无 mutating）。
    public func withHealthKitWriteEnabled(_ enabled: Bool, origin: DataOrigin) -> AppSettings {
        // 合规守卫：对 simulated 数据永远不允许打开写入开关。
        let effective = origin == .real ? enabled : false
        return AppSettings(
            unitSystem: unitSystem,
            paceFormat: paceFormat,
            appearance: appearance,
            dynamicTypeOverride: dynamicTypeOverride,
            reduceMotion: reduceMotion,
            defaultSampleRateHz: defaultSampleRateHz,
            seedPolicy: seedPolicy,
            defaultNoiseAmplitude: defaultNoiseAmplitude,
            elevationDeadbandMeters: elevationDeadbandMeters,
            externalElevationEnabled: externalElevationEnabled,
            healthKitWriteEnabled: effective
        )
    }
}

/// 权限状态（§B.8 / §B.13.1）。
/// 读取权限不可判定统一为 `.unknown`，按「无数据」呈现，绝不提示「被拒绝」。
public enum PermissionStatus: String, Codable, Sendable, CaseIterable {
    case unknown
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways

    public var localizedDescription: String {
        switch self {
        case .unknown: return "无数据 / 不可判定"
        case .notDetermined: return "尚未请求"
        case .restricted: return "受限制"
        case .denied: return "已拒绝"
        case .authorizedWhenInUse: return "使用期间已授权"
        case .authorizedAlways: return "始终已授权"
        }
    }
}

/// 全局权限状态（§B.8）。
public struct PermissionState: Codable, Sendable, Hashable {
    public let locationStatus: PermissionStatus
    public let preciseLocationEnabled: Bool
    public let motionStatus: PermissionStatus
    public let healthKitReadRequested: Bool
    /// 读取权限不可判定 → `.unknown`「无数据」。
    public let healthKitReadStatus: PermissionStatus
    public let healthKitShareStatus: PermissionStatus
    public let lastCheckedAt: Date

    public init(
        locationStatus: PermissionStatus = .unknown,
        preciseLocationEnabled: Bool = false,
        motionStatus: PermissionStatus = .unknown,
        healthKitReadRequested: Bool = false,
        healthKitReadStatus: PermissionStatus = .unknown,
        healthKitShareStatus: PermissionStatus = .unknown,
        lastCheckedAt: Date = Date()
    ) {
        self.locationStatus = locationStatus
        self.preciseLocationEnabled = preciseLocationEnabled
        self.motionStatus = motionStatus
        self.healthKitReadRequested = healthKitReadRequested
        self.healthKitReadStatus = healthKitReadStatus
        self.healthKitShareStatus = healthKitShareStatus
        self.lastCheckedAt = lastCheckedAt
    }

    public static let unknownState = PermissionState()

    /// 是否需要显示权限异常横幅。
    public var hasDegradedPermission: Bool {
        switch locationStatus {
        case .denied, .restricted: return true
        default: break
        }
        if !preciseLocationEnabled && locationStatus == .authorizedWhenInUse { return true }
        if healthKitShareStatus == .denied { return true }
        return false
    }

    /// 由 `PermissionSnapshot` 生成持久化状态。
    public static func from(snapshot: PermissionSnapshot) -> PermissionState {
        PermissionState(
            locationStatus: snapshot.locationStatus,
            preciseLocationEnabled: snapshot.preciseLocationEnabled,
            motionStatus: snapshot.motionStatus,
            healthKitReadRequested: snapshot.healthKitReadStatus != .unknown,
            healthKitReadStatus: snapshot.healthKitReadStatus,
            healthKitShareStatus: snapshot.healthKitShareStatus,
            lastCheckedAt: snapshot.capturedAt
        )
    }
}
