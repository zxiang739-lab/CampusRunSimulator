import Foundation

// MARK: - CSV + JSON 编解码（F42 / §B.11.1）

/// CSV / JSON 编解码与规则预设 JSON 契约。
///
/// - CSV：首行注释含 `# dataOrigin=SIMULATED|REAL` 与免责声明，每行带 `dataOrigin` 列；
/// - JSON：顶层固定 `dataOrigin` / `isHypothetical` / `disclaimer` / `schemaVersion` / `generator`；
/// - 规则预设 JSON：委托 F38 `RuleValidator` 强制 `isHypothetical: true` 与免责声明；
/// - 导入缺 `dataOrigin` → 隔离为「未分类」，**绝不默认 real**。
public struct TabularCodec: Sendable {

    private let marker: DataMarker
    private let validator: RuleValidator

    /// 非有限浮点（如距离为 0 时配速 `.infinity`）编码为字符串，避免 JSONEncoder 抛错。
    /// 编 / 解码共用同一组字面量，保证 `.infinity` / `-.infinity` / `.nan` 往返一致。
    private enum NonConformingFloatLiteral {
        static let positiveInfinity = "Infinity"
        static let negativeInfinity = "-Infinity"
        static let nan = "NaN"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: NonConformingFloatLiteral.positiveInfinity,
            negativeInfinity: NonConformingFloatLiteral.negativeInfinity,
            nan: NonConformingFloatLiteral.nan
        )
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: NonConformingFloatLiteral.positiveInfinity,
            negativeInfinity: NonConformingFloatLiteral.negativeInfinity,
            nan: NonConformingFloatLiteral.nan
        )
        return decoder
    }()

    private static let csvHeader: [String] = [
        "id", "sessionId", "dataOrigin", "timestamp", "elapsedSeconds",
        "latitude", "longitude", "altitudeM", "horizontalAccuracyM", "verticalAccuracyM",
        "courseDegrees", "speedMps", "speedAccuracyMps", "instantPaceSecPerKm",
        "avgPaceSecPerKm", "cadenceSpm", "strideLengthM", "cumulativeSteps",
        "cumulativeDistanceM", "elevationGainSoFarM", "elevationLossSoFarM",
        "segmentIndex", "qualityFlags"
    ]

    public init() {
        self.marker = DataMarker()
        self.validator = RuleValidator()
    }

    // MARK: CSV

    public func encodeCSV(session: RunSession, points: [TrackPoint]) throws -> Data {
        guard points.allSatisfy({ $0.dataOrigin == session.dataOrigin }) else {
            throw AppError.mixedOriginExportForbidden
        }
        let origin = session.dataOrigin
        var lines: [String] = []
        // ② 文件内标记：首行注释
        lines.append(marker.firstLineComment(origin))
        lines.append(Self.csvHeader.map(Self.csvEscape).joined(separator: ","))
        for point in points {
            let values: [String] = [
                point.id,
                point.sessionId,
                point.dataOrigin.rawValue,
                point.timestamp.iso8601UTCString,
                Self.number(point.elapsedSeconds),
                Self.number(point.latitude),
                Self.number(point.longitude),
                Self.number(point.altitudeM),
                Self.number(point.horizontalAccuracyM),
                Self.number(point.verticalAccuracyM),
                Self.number(point.courseDegrees),
                Self.number(point.speedMps),
                Self.number(point.speedAccuracyMps),
                Self.number(point.instantPaceSecPerKm),
                Self.number(point.avgPaceSecPerKm),
                Self.number(point.cadenceSpm),
                Self.number(point.strideLengthM),
                Self.number(point.cumulativeSteps),
                Self.number(point.cumulativeDistanceM),
                Self.number(point.elevationGainSoFarM),
                Self.number(point.elevationLossSoFarM),
                String(point.segmentIndex),
                point.qualityFlags.map(\.rawValue).joined(separator: "|")
            ]
            lines.append(values.map(Self.csvEscape).joined(separator: ","))
        }
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else {
            throw AppError.exportFailed(reason: "CSV UTF-8 编码失败")
        }
        return data
    }

    // MARK: JSON

    public func encodeJSON(session: RunSession, points: [TrackPoint]) throws -> Data {
        guard points.allSatisfy({ $0.dataOrigin == session.dataOrigin }) else {
            throw AppError.mixedOriginExportForbidden
        }
        let origin = session.dataOrigin
        let sessionData = try Self.encoder.encode(session)
        let pointsData = try Self.encoder.encode(points)
        // ② 文件内标记：顶层字段（含 ③ UI 徽标元数据）
        var object: [String: Any] = [:]
        for (key, value) in marker.jsonTopLevel(origin) {
            object[key] = value
        }
        object["session"] = try JSONSerialization.jsonObject(with: sessionData)
        object["points"] = try JSONSerialization.jsonObject(with: pointsData)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AppError.exportFailed(reason: "JSON 顶层对象非法")
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .prettyPrinted]
        )
    }

    /// 规则预设 JSON 编码（强制 `isHypothetical: true` + 免责声明）。
    public func encodePresetJSON(_ preset: RulePreset) throws -> Data {
        try validator.encodePreset(preset)
    }

    /// 规则预设 JSON 解码（委托 F38 校验，拒绝 `isHypothetical=false` 与内置真实规则）。
    public func decodePresetJSON(_ data: Data) throws -> RulePreset {
        try validator.decodePreset(data)
    }

    /// 轨迹 JSON 解码：缺 / 非法 `dataOrigin` 时把原始数据隔离到「未分类」目录，
    /// 并抛 `AppError.unclassifiedDataIsolated`，**绝不默认真实记录**。
    public func decodeTrackJSON(_ data: Data) throws -> RunSession {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawOrigin = object[OriginMarkers.metadataKeyDataOrigin] as? String,
              let origin = DataOrigin(rawValue: rawOrigin) else {
            try isolateUnclassified(data)
            throw AppError.unclassifiedDataIsolated
        }
        guard let sessionObject = object["session"] else {
            try isolateUnclassified(data)
            throw AppError.unclassifiedDataIsolated
        }
        let sessionData = try JSONSerialization.data(withJSONObject: sessionObject)
        let session: RunSession
        do {
            session = try Self.decoder.decode(RunSession.self, from: sessionData)
        } catch {
            try isolateUnclassified(data)
            throw AppError.unclassifiedDataIsolated
        }
        // 顶层标记与会话来源必须一致，混合来源一律拒绝。
        guard session.dataOrigin == origin else {
            throw AppError.mixedOriginExportForbidden
        }
        return session
    }

    /// 轨迹点 JSON 解码（与 `decodeTrackJSON` 共用同一顶层标记校验）。
    public func decodeTrackPointsJSON(_ data: Data) throws -> [TrackPoint] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawOrigin = object[OriginMarkers.metadataKeyDataOrigin] as? String,
              let origin = DataOrigin(rawValue: rawOrigin),
              let pointsObject = object["points"] else {
            try isolateUnclassified(data)
            throw AppError.unclassifiedDataIsolated
        }
        let pointsData = try JSONSerialization.data(withJSONObject: pointsObject)
        let points = try Self.decoder.decode([TrackPoint].self, from: pointsData)
        guard points.allSatisfy({ $0.dataOrigin == origin }) else {
            throw AppError.mixedOriginExportForbidden
        }
        return points
    }

    // MARK: - 私有：脏数据隔离与格式化

    /// 把缺来源标记的原始文件落到独立的「未分类」隔离目录（本地文件，无网络上传）。
    private func isolateUnclassified(_ data: Data) throws {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("CampusRunSimulator/unclassified", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "unclassified_\(Date().utcFileNameStamp)_\(UUID().uuidString).json"
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// CSV 字段转义：含逗号 / 引号 / 换行时用双引号包裹并转义内部引号。
    private static func csvEscape(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 稳定数值文本（非有限值写空串，不输出 NaN / inf）。
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(value)
    }
}
