import Foundation
import OSLog

/// 一条结构化审计事件（§7.10）。
/// 隐私红线：日志只记 id / 来源 / 计数 / 结果码 / 时间，**绝不写经纬度、精确轨迹、健康样本值**。
public struct AuditEvent: Sendable, Hashable {
    public let eventId: String
    public let sessionId: String?
    public let dataOrigin: DataOrigin
    public let kind: String
    public let count: Int
    public let resultCode: String
    public let timestamp: Date

    public init(
        eventId: String = UUID().uuidString,
        sessionId: String? = nil,
        dataOrigin: DataOrigin,
        kind: String,
        count: Int = 0,
        resultCode: String = "ok",
        timestamp: Date = Date()
    ) {
        self.eventId = eventId
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
        self.kind = kind
        self.count = count
        self.resultCode = resultCode
        self.timestamp = timestamp
    }

    /// 合规事件种类常量（供各层统一引用，避免散落字符串）。
    public enum Kind {
        public static let appLaunch = "app_launch"
        public static let appBackground = "app_background"
        public static let appForeground = "app_foreground"
        public static let simulationGenerated = "simulation_generated"
        public static let generationRejected = "generation_rejected"
        public static let simulatedWriteForbidden = "simulated_write_forbidden"
        public static let exportCompleted = "export_completed"
        public static let mixedExportRejected = "mixed_export_rejected"
        public static let originMarkerMissing = "origin_marker_missing"
        public static let unclassifiedIsolated = "unclassified_isolated"
        public static let healthKitWriteSucceeded = "healthkit_write_succeeded"
        public static let healthKitWriteFailed = "healthkit_write_failed"
        public static let repositorySaved = "repository_saved"
        public static let repositoryDeleted = "repository_deleted"
        public static let repositoryCleared = "repository_cleared"
        public static let permissionChanged = "permission_changed"
        public static let persistenceFallback = "persistence_fallback"
        public static let ruleEvaluated = "rule_evaluated"
        public static let gpxImported = "gpx_imported"
    }

    /// 单行日志文本：仅含非敏感字段，禁止在此拼接任何坐标。
    public var logLine: String {
        let id = sessionId ?? "none"
        let time = timestamp.iso8601UTCString
        return "event=\(kind) eventId=\(eventId) sessionId=\(id) origin=\(dataOrigin.rawValue) count=\(count) result=\(resultCode) at=\(time)"
    }
}

/// 结构化日志与合规审计（OSLog）。`actor` 保证并发写入串行化。
public actor AuditLogger {
    /// 全局共享实例。
    public static let shared = AuditLogger()

    /// 按 category 缓存的 Logger。
    private var loggers: [String: Logger] = [:]
    private let subsystem: String
    /// 最近事件缓冲，供设置页「关于 / 合规」展示与测试断言。
    private var recentEvents: [AuditEvent] = []

    public init(subsystem: String = AppConstants.logSubsystem) {
        self.subsystem = subsystem
    }

    /// 按事件种类选择日志 category（§7.10 六种通道）。
    private func logger(for kind: String) -> Logger {
        let category = Self.category(for: kind)
        if let cached = loggers[category] {
            return cached
        }
        let created = Logger(subsystem: subsystem, category: category)
        loggers[category] = created
        return created
    }

    /// 事件种类 → category 映射。
    private static func category(for kind: String) -> String {
        switch kind {
        case AuditEvent.Kind.simulationGenerated,
             AuditEvent.Kind.generationRejected:
            return AppConstants.logCategorySimulation
        case AuditEvent.Kind.repositorySaved,
             AuditEvent.Kind.repositoryDeleted,
             AuditEvent.Kind.repositoryCleared,
             AuditEvent.Kind.unclassifiedIsolated:
            return AppConstants.logCategoryRepository
        case AuditEvent.Kind.exportCompleted,
             AuditEvent.Kind.mixedExportRejected,
             AuditEvent.Kind.originMarkerMissing,
             AuditEvent.Kind.gpxImported:
            return AppConstants.logCategoryExport
        case AuditEvent.Kind.healthKitWriteSucceeded,
             AuditEvent.Kind.healthKitWriteFailed,
             AuditEvent.Kind.simulatedWriteForbidden:
            return AppConstants.logCategoryHealthKit
        case AuditEvent.Kind.permissionChanged,
             AuditEvent.Kind.appBackground,
             AuditEvent.Kind.appForeground:
            return AppConstants.logCategorySensor
        default:
            return AppConstants.logCategoryCompliance
        }
    }

    /// 写入一条审计事件（OSLog 真实写日志，不写经纬度）。
    public func log(_ event: AuditEvent) {
        let line = event.logLine
        logger(for: event.kind).info("\(line, privacy: .public)")
        recentEvents.append(event)
        if recentEvents.count > AppConstants.maxRecentAuditEvents {
            let overflow = recentEvents.count - AppConstants.maxRecentAuditEvents
            recentEvents.removeFirst(overflow)
        }
    }

    /// 便捷方法：记录一次被拒绝的合规事件。
    public func logRejection(
        sessionId: String?,
        origin: DataOrigin,
        kind: String,
        error: AppError
    ) {
        log(AuditEvent(
            sessionId: sessionId,
            dataOrigin: origin,
            kind: kind,
            resultCode: error.resultCode
        ))
    }

    /// 导出审计：把 `ExportRecord.markersIncluded` 的三重标记结果写入日志。
    /// 只记录标记种类数量与结果码，绝不涉及坐标或文件内容。
    public func exportAudit(for record: ExportRecord) {
        let markersComplete = record.hasAllThreeMarkers
        let kind = markersComplete
            ? AuditEvent.Kind.exportCompleted
            : AuditEvent.Kind.originMarkerMissing
        let resultCode = markersComplete ? "ok" : AppError.missingOriginMarker.resultCode
        log(AuditEvent(
            eventId: record.id,
            sessionId: record.sessionId,
            dataOrigin: record.dataOrigin,
            kind: kind,
            count: record.markersIncluded.count,
            resultCode: resultCode,
            timestamp: record.createdAt
        ))
    }

    /// 读取最近审计事件（供设置页与测试使用，倒序：最新在前）。
    public func recentAuditEvents(limit: Int = AppConstants.maxRecentAuditEvents) -> [AuditEvent] {
        guard limit > 0 else { return [] }
        return Array(recentEvents.suffix(limit).reversed())
    }

    /// 按来源筛选最近事件（用于合规自检）。
    public func recentAuditEvents(origin: DataOrigin, limit: Int = 50) -> [AuditEvent] {
        guard limit > 0 else { return [] }
        let filtered = recentEvents.filter { $0.dataOrigin == origin }
        return Array(filtered.suffix(limit).reversed())
    }

    /// 清空内存中的最近事件缓冲（不影响已写入 OSLog 的记录）。
    public func clearRecentEvents() {
        recentEvents.removeAll()
    }
}
