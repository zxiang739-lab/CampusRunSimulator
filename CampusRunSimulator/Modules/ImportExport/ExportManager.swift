import Foundation
import SwiftData

// MARK: - 导出格式与导出结果（F43 / §4.4）

/// 导出格式。`rawValue` 同时作为文件扩展名，保证 `DataMarker.fileName` 与编解码一致。
public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case gpx
    case csv
    case json

    public var fileExtension: String {
        rawValue
    }

    public var localizedDescription: String {
        switch self {
        case .gpx: return "GPX 1.1 轨迹"
        case .csv: return "CSV 表格"
        case .json: return "JSON 数据"
        }
    }
}

/// 一次导出的本地文件结果，交给系统分享面板。
/// **本类型不提供任何网络上传能力**：只有本地 `Data` 与由它写出的临时文件 URL。
public struct ExportedFile: Sendable {
    public let fileName: String
    public let data: Data
    public let markersIncluded: [MarkerKind]
    public let dataOrigin: DataOrigin
    public let format: ExportFormat
    public let createdAt: Date

    public init(
        fileName: String,
        data: Data,
        markersIncluded: [MarkerKind] = MarkerKind.allCases,
        dataOrigin: DataOrigin,
        format: ExportFormat,
        createdAt: Date = Date()
    ) {
        self.fileName = fileName
        self.data = data
        self.markersIncluded = markersIncluded
        self.dataOrigin = dataOrigin
        self.format = format
        self.createdAt = createdAt
    }

    /// 三重标记是否齐全。
    public var hasAllThreeMarkers: Bool {
        Set(markersIncluded) == Set(MarkerKind.allCases)
    }

    /// 写出到临时目录并返回本地 file URL（供 `UIActivityViewController` / `ShareLink` 使用）。
    /// 不发起任何网络请求，不写入第三方平台。
    public func writeToTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - 导出管理器（F43 / §B.11.2 / §7.5）

/// `actor`：单一来源守卫 + 三重标记注入与校验 + `ExportRecord` 审计 + 系统分享面板出口。
///
/// 合规硬约束：
/// - 混合来源输入抛 `AppError.mixedOriginExportForbidden`，不产出文件；
/// - 三重标记（文件名 / 文件内 / UI 徽标元数据）缺一即抛 `AppError.missingOriginMarker`；
/// - 每次导出持久化 `ExportRecord` 并写 `AuditLogger`（日志不写经纬度）；
/// - **无任何网络上传方法**，不引入任何网络栈、不持有任何第三方服务器地址。
public actor ExportManager: ExportManaging {

    private let stores: PersistentStores?
    private let marker = DataMarker()
    private let gpxCodec = GPXCodec()
    private let tabularCodec = TabularCodec()

    /// - Parameter stores: 传入双容器时把 `ExportRecord` 写入对应来源容器；nil 时只写 OSLog（单测可用）。
    public init(stores: PersistentStores? = nil) {
        self.stores = stores
    }

    // MARK: ExportManaging · 导出

    public func export(
        session: RunSession,
        points: [TrackPoint],
        format: ExportFormat
    ) async throws -> ExportedFile {
        let origin = session.dataOrigin
        // 前置守卫：单一来源（session 与全部 points 一致，且 id 属于正确来源域）。
        guard session.hasValidOriginID,
              points.allSatisfy({ $0.dataOrigin == origin }) else {
            await AuditLogger.shared.logRejection(
                sessionId: session.id,
                origin: origin,
                kind: AuditEvent.Kind.mixedExportRejected,
                error: AppError.mixedOriginExportForbidden
            )
            throw AppError.mixedOriginExportForbidden
        }

        // ① 文件名标记
        let fileName = marker.fileName(origin, format: format, date: Date())
        try marker.verifyFileName(fileName, origin: origin)

        // ② 文件内标记：按格式编码
        let data: Data
        do {
            switch format {
            case .gpx:
                data = try gpxCodec.encode(session: session, points: points)
            case .csv:
                data = try tabularCodec.encodeCSV(session: session, points: points)
            case .json:
                data = try tabularCodec.encodeJSON(session: session, points: points)
            }
        } catch let error as AppError {
            switch error {
            case .missingOriginMarker, .mixedOriginExportForbidden,
                 .gpxInvalidVersion, .gpxMissingField, .gpxOnlyRte:
                throw error
            default:
                throw AppError.exportFailed(reason: error.localizedDescription)
            }
        } catch {
            throw AppError.exportFailed(reason: error.localizedDescription)
        }

        // ② + ③ 三重标记校验：缺一即拒绝产出文件。
        do {
            try marker.verifyMarkers(data, origin: origin, format: format)
        } catch {
            await AuditLogger.shared.logRejection(
                sessionId: session.id,
                origin: origin,
                kind: AuditEvent.Kind.originMarkerMissing,
                error: AppError.missingOriginMarker
            )
            throw AppError.missingOriginMarker
        }

        let record = ExportRecord(
            sessionId: session.id,
            dataOrigin: origin,
            format: format.rawValue,
            fileName: fileName,
            markersIncluded: MarkerKind.allCases
        )
        await audit(record)
        return ExportedFile(
            fileName: fileName,
            data: data,
            markersIncluded: record.markersIncluded,
            dataOrigin: origin,
            format: format,
            createdAt: record.createdAt
        )
    }

    // MARK: ExportManaging · 审计

    /// 持久化 `ExportRecord`（按来源路由到对应容器）+ 写 OSLog 审计事件。
    public func audit(_ record: ExportRecord) async {
        if let stores = stores {
            do {
                // 合规：审计记录写入与记录同来源的独立容器。
                let context = ModelContext(stores.container(for: record.dataOrigin))
                let object = try SDMapper.fromValue(record)
                context.insert(object)
                try context.save()
            } catch {
                await AuditLogger.shared.logRejection(
                    sessionId: record.sessionId,
                    origin: record.dataOrigin,
                    kind: AuditEvent.Kind.exportCompleted,
                    error: AppError.exportFailed(
                        reason: "ExportRecord 持久化失败：\(error.localizedDescription)"
                    )
                )
            }
        }
        // 日志只记 sessionId / origin / 标记计数 / 结果码，绝不写经纬度或文件内容。
        await AuditLogger.shared.exportAudit(for: record)
    }
}
