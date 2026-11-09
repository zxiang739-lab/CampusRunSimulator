import Foundation

// MARK: - 文件内 metadata / UI 徽标元数据（F40 / §B.11.1）

/// 三重标记中「② 文件内 metadata」与「③ UI 徽标元数据」的载体。
/// `DataMarker.metadataBlock` 是唯一生成处，GPX / CSV / JSON 三种编码共用同一份字段。
public struct MarkerMetadata: Codable, Sendable, Hashable {
    public let dataOrigin: String
    public let isHypothetical: Bool
    public let disclaimer: String
    public let generator: String
    public let schemaVersion: String
    public let objectLabel: String
    /// ③ UI 徽标：文字 + SF Symbol + VoiceOver，不依赖颜色区分。
    public let badgeText: String
    public let badgeSymbol: String
    public let badgeAccessibilityLabel: String
    public let fileNamePrefix: String
    public let fileContentMarker: String

    public init(
        dataOrigin: String,
        isHypothetical: Bool,
        disclaimer: String,
        generator: String,
        schemaVersion: String,
        objectLabel: String,
        badgeText: String,
        badgeSymbol: String,
        badgeAccessibilityLabel: String,
        fileNamePrefix: String,
        fileContentMarker: String
    ) {
        self.dataOrigin = dataOrigin
        self.isHypothetical = isHypothetical
        self.disclaimer = disclaimer
        self.generator = generator
        self.schemaVersion = schemaVersion
        self.objectLabel = objectLabel
        self.badgeText = badgeText
        self.badgeSymbol = badgeSymbol
        self.badgeAccessibilityLabel = badgeAccessibilityLabel
        self.fileNamePrefix = fileNamePrefix
        self.fileContentMarker = fileContentMarker
    }

    /// 是否具备完整的 UI 徽标元数据（缺一即拒绝导出）。
    public var hasCompleteUIBadge: Bool {
        !badgeText.isEmpty && !badgeSymbol.isEmpty && !badgeAccessibilityLabel.isEmpty
    }
}

// MARK: - 三重标记生成与校验（F40 / §7.5）

/// 三重标记 = ① 文件名前缀 ② 文件内 metadata / 首行 / 顶层 ③ UI 徽标元数据。
/// **缺一即拒绝导出**（`AppError.missingOriginMarker`），且错误态下徽标不得隐藏。
public struct DataMarker: DataMarking {

    /// 导出文件内 metadata 使用的 schema 版本（唯一来源 `AppConstants`）。
    public let schemaVersion: String

    public init() {
        self.schemaVersion = AppConstants.schemaVersion
    }

    /// ① 文件名：`SIMULATED_YYYYMMDD_HHMMSS.<ext>` / `REAL_YYYYMMDD_HHMMSS.<ext>`（UTC）。
    public func fileName(_ origin: DataOrigin, format: ExportFormat, date: Date) -> String {
        OriginMarkers.prefix(for: origin) + date.utcFileNameStamp + "." + format.rawValue
    }

    /// ② 文件内 metadata（含 ③ UI 徽标元数据）。
    public func metadataBlock(_ origin: DataOrigin) -> MarkerMetadata {
        MarkerMetadata(
            dataOrigin: origin.rawValue,
            isHypothetical: origin == .simulated,
            disclaimer: AppConstants.disclaimer,
            generator: AppConstants.generator,
            schemaVersion: self.schemaVersion,
            objectLabel: origin == .simulated
                ? OriginMarkers.simulatedObjectLabel
                : OriginMarkers.realText,
            badgeText: OriginMarkers.text(for: origin),
            badgeSymbol: OriginMarkers.symbol(for: origin),
            badgeAccessibilityLabel: OriginMarkers.accessibilityLabel(for: origin),
            fileNamePrefix: OriginMarkers.prefix(for: origin),
            fileContentMarker: OriginMarkers.fileContentMarker(for: origin)
        )
    }

    /// ② CSV 首行注释（GPX/JSON 亦可作为文件内首行说明写入 XML 注释 / 不参与 JSON 语法）。
    public func firstLineComment(_ origin: DataOrigin) -> String {
        let metadata = metadataBlock(origin)
        return [
            "\(OriginMarkers.csvFirstLinePrefix)\(metadata.fileContentMarker)",
            "objectLabel=\(metadata.objectLabel)",
            "isHypothetical=\(metadata.isHypothetical)",
            "disclaimer=\(metadata.disclaimer)",
            "generator=\(metadata.generator)",
            "schemaVersion=\(metadata.schemaVersion)"
        ].joined(separator: " | ")
    }

    /// ② JSON 顶层标记字典（导出时合并到 envelope 根对象）。
    /// JSON 没有「首行注释」通道，因此必须显式写出大写文件内标记 `SIMULATED` / `REAL`，
    /// 否则 REAL 导出无法通过 `OriginMarkers.containsFileContentMarker`（小写 `real` 不算标记）。
    public func jsonTopLevel(_ origin: DataOrigin) -> [String: String] {
        let metadata = metadataBlock(origin)
        return [
            OriginMarkers.metadataKeyDataOrigin: metadata.dataOrigin,
            OriginMarkers.metadataKeyIsHypothetical: metadata.isHypothetical ? "true" : "false",
            OriginMarkers.metadataKeyDisclaimer: metadata.disclaimer,
            OriginMarkers.metadataKeyGenerator: metadata.generator,
            OriginMarkers.metadataKeySchemaVersion: metadata.schemaVersion,
            "fileContentMarker": metadata.fileContentMarker,
            "fileNamePrefix": metadata.fileNamePrefix,
            "objectLabel": metadata.objectLabel,
            "badgeText": metadata.badgeText,
            "badgeSymbol": metadata.badgeSymbol,
            "badgeAccessibilityLabel": metadata.badgeAccessibilityLabel
        ]
    }

    /// ① 文件名前缀校验（由 `ExportManager` 在写出前调用）。
    public func verifyFileName(_ fileName: String, origin: DataOrigin) throws {
        guard OriginMarkers.hasFileNamePrefix(fileName, for: origin) else {
            throw AppError.missingOriginMarker
        }
        let other: DataOrigin = origin == .simulated ? .real : .simulated
        guard !OriginMarkers.hasFileNamePrefix(fileName, for: other) else {
            throw AppError.missingOriginMarker
        }
    }

    /// ② 文件内标记 + ③ UI 徽标元数据校验。缺失任一即抛 `.missingOriginMarker`。
    public func verifyMarkers(_ data: Data, origin: DataOrigin, format: ExportFormat) throws {
        // ③ UI 徽标元数据必须完整（文字 + 图标 + VoiceOver 三通道）。
        let metadata = metadataBlock(origin)
        guard metadata.hasCompleteUIBadge,
              !metadata.disclaimer.isEmpty,
              !metadata.generator.isEmpty,
              !metadata.schemaVersion.isEmpty else {
            throw AppError.missingOriginMarker
        }
        // ② 文件内标记：来源标记 + dataOrigin 键必须同时存在。
        guard OriginMarkers.containsFileContentMarker(data, for: origin) else {
            throw AppError.missingOriginMarker
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.missingOriginMarker
        }
        switch format {
        case .csv:
            try verifyCSV(text, origin: origin, metadata: metadata)
        case .json:
            try verifyJSON(data, origin: origin, metadata: metadata)
        case .gpx:
            try verifyGPX(text, origin: origin, metadata: metadata)
        }
    }

    // MARK: - 私有：按格式校验

    private func verifyCSV(_ text: String, origin: DataOrigin, metadata: MarkerMetadata) throws {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard firstLine.hasPrefix(OriginMarkers.csvFirstLinePrefix),
              firstLine.contains(metadata.fileContentMarker),
              firstLine.contains(OriginMarkers.metadataKeyDataOrigin),
              firstLine.contains(metadata.disclaimer) else {
            throw AppError.missingOriginMarker
        }
        // 每行必须带 dataOrigin 列值（表头 + 数据行双重校验）。
        guard text.contains("dataOrigin"),
              text.contains(origin.rawValue) else {
            throw AppError.missingOriginMarker
        }
    }

    private func verifyJSON(_ data: Data, origin: DataOrigin, metadata: MarkerMetadata) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.missingOriginMarker
        }
        let requiredKeys = [
            OriginMarkers.metadataKeyDataOrigin,
            OriginMarkers.metadataKeyIsHypothetical,
            OriginMarkers.metadataKeyDisclaimer,
            OriginMarkers.metadataKeySchemaVersion,
            OriginMarkers.metadataKeyGenerator,
            "fileContentMarker"
        ]
        for key in requiredKeys where object[key] == nil {
            throw AppError.missingOriginMarker
        }
        guard let fileMarker = object["fileContentMarker"] as? String,
              fileMarker == metadata.fileContentMarker else {
            throw AppError.missingOriginMarker
        }
        guard let rawOrigin = object[OriginMarkers.metadataKeyDataOrigin] as? String,
              rawOrigin == origin.rawValue else {
            throw AppError.missingOriginMarker
        }
        guard let disclaimer = object[OriginMarkers.metadataKeyDisclaimer] as? String,
              disclaimer == metadata.disclaimer else {
            throw AppError.missingOriginMarker
        }
        guard let hypothetical = object[OriginMarkers.metadataKeyIsHypothetical] as? String,
              hypothetical == (metadata.isHypothetical ? "true" : "false") else {
            throw AppError.missingOriginMarker
        }
    }

    private func verifyGPX(_ text: String, origin: DataOrigin, metadata: MarkerMetadata) throws {
        guard text.contains("<metadata>"),
              text.contains("<extensions>"),
              text.contains("<trk>"),
              text.contains("<name>"),
              text.contains(metadata.fileContentMarker),
              text.contains(OriginMarkers.metadataKeyDataOrigin),
              text.contains(metadata.disclaimer) else {
            throw AppError.missingOriginMarker
        }
        guard let rawOrigin = originMarkerValue(from: text, key: OriginMarkers.metadataKeyDataOrigin),
              rawOrigin == origin.rawValue else {
            throw AppError.missingOriginMarker
        }
    }

    /// 从 GPX `<extensions>` 文本中提取形如 `<crs:dataOrigin>simulated</crs:dataOrigin>` 的值。
    /// `shouldProcessNamespaces = false` 时标签名带 `crs:` 前缀，因此按 `key + ">"` 定位开标签尾部。
    private func originMarkerValue(from text: String, key: String) -> String? {
        let suffix = key + ">"
        guard let openRange = text.range(of: suffix) else { return nil }
        let searchStart = openRange.upperBound
        guard let closeRange = text.range(of: "</", range: searchStart..<text.endIndex) else {
            return nil
        }
        return String(text[searchStart..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
