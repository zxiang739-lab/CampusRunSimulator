import Foundation

// MARK: - GPX 导入结果（F41 / §3.2）

/// GPX 1.1 解析结果。`trkseg` 数量写入 `segmentCount`，缺失字段分级放入 `missingFields` / `warnings`。
public struct GPXImportResult: Sendable {
    public let points: [TrackPoint]
    public let segmentCount: Int
    public let missingFields: [GPXMissingField]
    public let warnings: [String]
    public let dataOrigin: DataOrigin
    /// 来源无法判定时为 `true`：上层必须先隔离为「未分类」，**绝不默认真实记录**。
    public let isUnclassified: Bool
    /// 仅含 `<rte>` / `<wpt>` 时解析出的路线点（兼容路线导入，不作为运动轨迹）。
    public let routePoints: [GeoPoint]

    public init(
        points: [TrackPoint],
        segmentCount: Int,
        missingFields: [GPXMissingField],
        warnings: [String],
        dataOrigin: DataOrigin,
        isUnclassified: Bool = false,
        routePoints: [GeoPoint] = []
    ) {
        self.points = points
        self.segmentCount = segmentCount
        self.missingFields = missingFields
        self.warnings = warnings
        self.dataOrigin = dataOrigin
        self.isUnclassified = isUnclassified
        self.routePoints = routePoints
    }
}

// MARK: - GPX 1.1 编解码（F41 / §B.11.1 / §7.5）

/// 编码：手写 GPX 1.1 XML（`<metadata>` / `<extensions>` / `<trk><name>` / 逐点扩展字段含三重标记）。
/// 解码：**Foundation `XMLParser` delegate 真实解析**，不做字符串拼接假解析。
/// 缺 `<ele>` / `<time>` 分级提示且不臆造；多个 `<trkseg>` 映射为 `segmentIndex`，跨段不连线、不计距。
public struct GPXCodec: GPXCoding {

    private let marker: DataMarker

    public init() {
        self.marker = DataMarker()
    }

    // MARK: GPXCoding · 编码

    public func encode(session: RunSession, points: [TrackPoint]) throws -> Data {
        // 单一来源守卫：混合来源绝不产出文件。
        guard points.allSatisfy({ $0.dataOrigin == session.dataOrigin }) else {
            throw AppError.mixedOriginExportForbidden
        }
        let origin = session.dataOrigin
        let metadata = marker.metadataBlock(origin)
        let firstLine = marker.firstLineComment(origin)

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!-- \(Self.escape(firstLine)) -->\n"
        xml += "<gpx version=\"1.1\" creator=\"\(Self.escape(AppConstants.generator))\" "
        xml += "xmlns=\"http://www.topografix.com/GPX/1/1\" "
        xml += "xmlns:crs=\"http://www.campusrun.simulator/gpx/ext/1.0\">\n"
        // ② 文件内标记：<metadata><name>/<desc>
        xml += "  <metadata>\n"
        xml += "    <name>\(Self.escape(metadata.fileContentMarker)) / \(Self.escape(metadata.objectLabel))</name>\n"
        xml += "    <desc>\(Self.escape(metadata.disclaimer))</desc>\n"
        xml += "  </metadata>\n"
        // ② 文件内标记：<extensions>
        xml += "  <extensions>\n"
        xml += "    \(Self.extensionTag(OriginMarkers.metadataKeyDataOrigin, origin.rawValue))\n"
        xml += "    \(Self.extensionTag(OriginMarkers.metadataKeyIsHypothetical, metadata.isHypothetical ? "true" : "false"))\n"
        xml += "    \(Self.extensionTag(OriginMarkers.metadataKeyDisclaimer, Self.escape(metadata.disclaimer)))\n"
        xml += "    \(Self.extensionTag(OriginMarkers.metadataKeyGenerator, Self.escape(metadata.generator)))\n"
        xml += "    \(Self.extensionTag(OriginMarkers.metadataKeySchemaVersion, metadata.schemaVersion))\n"
        xml += "    \(Self.extensionTag("badgeText", Self.escape(metadata.badgeText)))\n"
        xml += "    \(Self.extensionTag("badgeSymbol", Self.escape(metadata.badgeSymbol)))\n"
        xml += "  </extensions>\n"
        // ② 文件内标记：<trk><name>
        xml += "  <trk>\n"
        xml += "    <name>\(Self.escape(metadata.fileContentMarker))_\(Self.escape(session.id))</name>\n"

        let segmentIndices = Array(Set(points.map(\.segmentIndex))).sorted()
        for segment in segmentIndices {
            xml += "    <trkseg>\n"
            for point in points where point.segmentIndex == segment {
                xml += "      <trkpt lat=\"\(Self.number(point.latitude))\" lon=\"\(Self.number(point.longitude))\">\n"
                if point.altitudeM.isFinite {
                    xml += "        <ele>\(Self.number(point.altitudeM))</ele>\n"
                }
                xml += "        <time>\(point.timestamp.iso8601UTCStringWithoutFraction)</time>\n"
                xml += "        <extensions>\n"
                xml += "          \(Self.extensionTag(OriginMarkers.metadataKeyDataOrigin, point.dataOrigin.rawValue))\n"
                xml += "          \(Self.extensionTag("speedMps", Self.number(point.speedMps)))\n"
                xml += "          \(Self.extensionTag("cadenceSpm", Self.number(point.cadenceSpm)))\n"
                xml += "          \(Self.extensionTag("strideLengthM", Self.number(point.strideLengthM)))\n"
                xml += "          \(Self.extensionTag("instantPaceSecPerKm", Self.number(point.instantPaceSecPerKm)))\n"
                xml += "          \(Self.extensionTag("cumulativeDistanceM", Self.number(point.cumulativeDistanceM)))\n"
                xml += "          \(Self.extensionTag("segmentIndex", String(point.segmentIndex)))\n"
                xml += "          \(Self.extensionTag("qualityFlags", point.qualityFlags.map(\.rawValue).joined(separator: ",")))\n"
                xml += "        </extensions>\n"
                xml += "      </trkpt>\n"
            }
            xml += "    </trkseg>\n"
        }
        xml += "  </trk>\n"
        xml += "</gpx>\n"

        guard let data = xml.data(using: .utf8) else {
            throw AppError.exportFailed(reason: "GPX UTF-8 编码失败")
        }
        return data
    }

    // MARK: GPXCoding · 解码

    public func decode(_ data: Data) throws -> GPXImportResult {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), parser.parserError == nil else {
            let reason = parser.parserError?.localizedDescription ?? "未知 XML 错误"
            throw AppError.exportFailed(reason: "GPX XML 解析失败：\(reason)")
        }

        // 版本号必须先校验：非法 / 缺失直接拒绝，不做宽容解析。
        guard let version = delegate.version else {
            throw AppError.gpxMissingField(.version)
        }
        guard version == AppConstants.gpxSchemaVersion else {
            throw AppError.gpxInvalidVersion(version)
        }

        let originResolution = Self.resolveOrigin(delegate: delegate)
        var warnings: [String] = originResolution.warnings
        var missingFields: [GPXMissingField] = []

        // 仅 rte/wpt：兼容为「路线点」，不作为运动轨迹；不臆造时间戳与海拔。
        guard delegate.sawTrack else {
            if delegate.sawRouteOrWaypoint {
                warnings.append(AppError.gpxOnlyRte.errorDescription ?? "文件仅含路线点，不作为运动轨迹")
            } else {
                warnings.append("未发现 <trk> 轨迹段，也未发现 <rte>/<wpt> 路线点")
            }
            if delegate.routePoints.isEmpty {
                missingFields.append(.track)
            }
            return GPXImportResult(
                points: [],
                segmentCount: 0,
                missingFields: missingFields,
                warnings: warnings,
                dataOrigin: originResolution.origin,
                isUnclassified: originResolution.isUnclassified,
                routePoints: delegate.routePoints
            )
        }

        let rawPoints = delegate.segments.flatMap { $0 }
        if rawPoints.isEmpty {
            missingFields.append(.track)
            warnings.append("未解析到任何 <trkpt>，轨迹为空")
        }
        let missingElevationCount = rawPoints.filter { $0.elevation == nil }.count
        let missingTimeCount = rawPoints.filter { $0.time == nil }.count
        if missingElevationCount > 0 {
            missingFields.append(.elevation)
            warnings.append("\(missingElevationCount) 个点缺 <ele>，海拔按 0（不可用哨兵）处理，未臆造、未插值")
        }
        if missingTimeCount > 0 {
            missingFields.append(.time)
            warnings.append("\(missingTimeCount) 个点缺 <time>，未纳入轨迹（不臆造时间戳、不插值）")
        }

        let points = Self.buildTrackPoints(
            segments: delegate.segments,
            origin: originResolution.origin,
            warnings: &warnings
        )
        warnings.append("共导入 \(points.count) 个点 / \(delegate.segments.count) 个 <trkseg> 分段")
        return GPXImportResult(
            points: points,
            segmentCount: delegate.segments.count,
            missingFields: missingFields,
            warnings: warnings,
            dataOrigin: originResolution.origin,
            isUnclassified: originResolution.isUnclassified,
            routePoints: delegate.routePoints
        )
    }

    // MARK: - 私有：来源判定

    private struct OriginResolution {
        let origin: DataOrigin
        let isUnclassified: Bool
        let warnings: [String]
    }

    /// 来源优先取 `<extensions>` 的文件级标记，其次取 `<metadata>` 文本标记；
    /// 均无法判定时**绝不默认 real**，标记为未分类并给出明确提示。
    private static func resolveOrigin(delegate: GPXParserDelegate) -> OriginResolution {
        switch delegate.extensionDataOrigin?.lowercased() {
        case "simulated":
            return OriginResolution(origin: .simulated, isUnclassified: false, warnings: [])
        case "real":
            return OriginResolution(origin: .real, isUnclassified: false, warnings: [])
        default:
            break
        }
        let upper = delegate.metadataText.uppercased()
        if upper.contains(OriginMarkers.simulatedFileContentMarker) {
            return OriginResolution(origin: .simulated, isUnclassified: false, warnings: [])
        }
        if upper.contains(OriginMarkers.realFileContentMarker) {
            return OriginResolution(origin: .real, isUnclassified: false, warnings: [])
        }
        return OriginResolution(
            origin: .simulated,
            isUnclassified: true,
            warnings: [
                "无法判定文件来源，已隔离为「\(AppConstants.unclassifiedSectionName)」，绝不默认真实记录",
                "导入真实记录须在文件内显式标注 REAL 标记（§8 Q10）"
            ]
        )
    }

    // MARK: - 私有：轨迹点构建

    /// 把解析出的分段转换为 `TrackPoint`。跨段不计距（段首点 delta = 0），
    /// 缺 `<time>` 的点直接跳过，缺 `<ele>` 的点用 0 哨兵并标 `.lowAccuracy`。
    private static func buildTrackPoints(
        segments: [[GPXParserDelegate.RawPoint]],
        origin: DataOrigin,
        warnings: inout [String]
    ) -> [TrackPoint] {
        let allTimes = segments.flatMap { $0 }.compactMap(\.time)
        guard let baseTime = allTimes.min() else { return [] }
        let sessionId = "gpx_import"
        var result: [TrackPoint] = []
        var cumulativeDistance = 0.0
        var cumulativeGain = 0.0
        var cumulativeLoss = 0.0

        for (segmentIndex, segment) in segments.enumerated() {
            var previous: TrackPoint?
            var lastValidTime: Date?
            for raw in segment {
                guard let timestamp = raw.time else { continue }
                if let lastValidTime = lastValidTime,
                   timestamp.timeIntervalSince(lastValidTime) <= 0 {
                    warnings.append("存在时间戳乱序 / 重复点，已丢弃（不重排、不臆造）")
                    continue
                }
                let coordinate = GeoPoint(latitude: raw.latitude, longitude: raw.longitude)
                guard coordinate.isValid else {
                    warnings.append("存在非法经纬度点，已丢弃")
                    continue
                }
                let delta: Double
                if let previous = previous {
                    delta = max(0, Units.distanceMeters(previous.geoPoint, coordinate))
                } else {
                    // 段首点：跨段不连线、不计距。
                    delta = 0
                }
                cumulativeDistance += delta
                let altitude = raw.elevation ?? 0
                let gainLoss = Units.elevationGainLoss([previous?.altitudeM ?? altitude, altitude])
                cumulativeGain += gainLoss.gain
                cumulativeLoss += gainLoss.loss
                let elapsed = max(0, timestamp.timeIntervalSince(baseTime))
                let flags: [QualityFlag] = raw.elevation == nil ? [.lowAccuracy] : []
                let point = TrackPoint(
                    id: OriginID.makeID(origin, suffix: "\(sessionId)_\(segmentIndex)_\(result.count)"),
                    sessionId: sessionId,
                    dataOrigin: origin,
                    timestamp: timestamp,
                    elapsedSeconds: elapsed,
                    latitude: raw.latitude,
                    longitude: raw.longitude,
                    altitudeM: altitude,
                    horizontalAccuracyM: -1,
                    verticalAccuracyM: raw.elevation == nil ? -1 : 0,
                    courseDegrees: 0,
                    speedMps: raw.speedMps,
                    speedAccuracyMps: -1,
                    instantPaceSecPerKm: raw.instantPaceSecPerKm,
                    avgPaceSecPerKm: Units.averagePaceSecPerKm(
                        totalSeconds: elapsed,
                        totalMeters: cumulativeDistance
                    ),
                    cadenceSpm: raw.cadenceSpm,
                    strideLengthM: raw.strideLengthM,
                    cumulativeSteps: 0,
                    cumulativeDistanceM: raw.cumulativeDistanceM > 0
                        ? raw.cumulativeDistanceM
                        : cumulativeDistance,
                    elevationGainSoFarM: cumulativeGain,
                    elevationLossSoFarM: cumulativeLoss,
                    segmentIndex: segmentIndex,
                    qualityFlags: flags
                )
                result.append(point)
                previous = point
                lastValidTime = timestamp
            }
        }
        return result
    }

    // MARK: - 私有：XML 工具

    /// 扩展字段标签（`crs:` 前缀由 `AppConstants.gpxExtensionNamespacePrefix` 统一提供）。
    private static func extensionTag(_ key: String, _ value: String) -> String {
        let prefix = AppConstants.gpxExtensionNamespacePrefix
        return "<\(prefix)\(key)>\(value)</\(prefix)\(key)>"
    }

    /// XML 文本 / 属性转义（避免元数据中的特殊字符破坏文档）。
    private static func escape(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    /// 稳定数值文本（非有限值写 0，不输出 NaN / inf）。
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(value)
    }
}

// MARK: - XMLParser delegate（真实解析，不拼接假解析）

/// GPX 1.1 解析状态机。`shouldProcessNamespaces = false`，因此标签名可能带 `crs:` 前缀，
/// 统一用 `localName` 取末段比较。
private final class GPXParserDelegate: NSObject, XMLParserDelegate {

    /// 一个 `<trkpt>` 的原始字段（缺 ele/time 时保持 nil，不臆造）。
    struct RawPoint {
        var latitude: Double = 0
        var longitude: Double = 0
        var elevation: Double?
        var time: Date?
        var speedMps: Double = 0
        var cadenceSpm: Double = 0
        var strideLengthM: Double = 0
        var instantPaceSecPerKm: Double = 0
        var cumulativeDistanceM: Double = 0
    }

    var version: String?
    var sawTrack = false
    var sawRouteOrWaypoint = false
    var segments: [[RawPoint]] = []
    var routePoints: [GeoPoint] = []
    var metadataText = ""
    /// 文件级 `<extensions>` 中的 `dataOrigin`（逐点扩展字段不覆盖它）。
    var extensionDataOrigin: String?

    private var currentText = ""
    private var currentPoint: RawPoint?
    private var currentSegmentIndex = -1

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentText = ""
        let name = localName(elementName)
        switch name {
        case "gpx":
            version = attributeDict["version"]
        case "trk":
            sawTrack = true
        case "trkseg":
            segments.append([])
            currentSegmentIndex = segments.count - 1
        case "trkpt":
            var point = RawPoint()
            point.latitude = Double(attributeDict["lat"] ?? "") ?? 0
            point.longitude = Double(attributeDict["lon"] ?? "") ?? 0
            currentPoint = point
        case "rte":
            sawRouteOrWaypoint = true
        case "wpt", "rtept":
            sawRouteOrWaypoint = true
            if let lat = Double(attributeDict["lat"] ?? ""),
               let lon = Double(attributeDict["lon"] ?? "") {
                let point = GeoPoint(latitude: lat, longitude: lon)
                if point.isValid { routePoints.append(point) }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "ele":
            if let elevation = Double(value) { currentPoint?.elevation = elevation }
        case "time":
            if let date = Date.fromISO8601(value) { currentPoint?.time = date }
        case OriginMarkers.metadataKeyDataOrigin:
            if currentPoint == nil {
                extensionDataOrigin = value
            }
        case "speedMps":
            if let number = Double(value) { currentPoint?.speedMps = number }
        case "cadenceSpm":
            if let number = Double(value) { currentPoint?.cadenceSpm = number }
        case "strideLengthM":
            if let number = Double(value) { currentPoint?.strideLengthM = number }
        case "instantPaceSecPerKm":
            if let number = Double(value) { currentPoint?.instantPaceSecPerKm = number }
        case "cumulativeDistanceM":
            if let number = Double(value) { currentPoint?.cumulativeDistanceM = number }
        case "name", "desc":
            if currentPoint == nil { metadataText += value }
        case "trkpt":
            if let point = currentPoint, currentSegmentIndex >= 0 {
                segments[currentSegmentIndex].append(point)
            }
            currentPoint = nil
        default:
            break
        }
        currentText = ""
    }
}
