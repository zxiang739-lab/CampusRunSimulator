import Foundation

/// 一次跑步会话汇总（§3.2 / §B.8）。
/// `dataOrigin` 强制不可变 `let`；`isSimulated` 为只读计算属性；`originChain` 保留另存副本的原链。
public struct RunSession: Identifiable, Codable, Sendable {
    public let id: String
    public let dataOrigin: DataOrigin
    public let startTime: Date
    public let endTime: Date
    public let durationSeconds: TimeInterval
    public let totalDistanceMeters: Double
    public let avgSpeedMps: Double
    public let avgPaceSecPerKm: Double
    public let totalSteps: Double
    public let elevationGainM: Double
    public let elevationLossM: Double
    public let routeId: String?
    public let simulationProfileId: String?
    public let rulePresetId: String?
    public let note: String
    public let createdAt: Date
    public let schemaVersion: String
    public let originChain: [String]

    /// 只读计算属性（无 setter、无转换器）。
    public var isSimulated: Bool {
        dataOrigin == .simulated
    }

    public init(
        id: String,
        dataOrigin: DataOrigin,
        startTime: Date,
        endTime: Date,
        durationSeconds: TimeInterval,
        totalDistanceMeters: Double,
        avgSpeedMps: Double,
        avgPaceSecPerKm: Double,
        totalSteps: Double,
        elevationGainM: Double,
        elevationLossM: Double,
        routeId: String? = nil,
        simulationProfileId: String? = nil,
        rulePresetId: String? = nil,
        note: String = "",
        createdAt: Date = Date(),
        schemaVersion: String = AppConstants.schemaVersion,
        originChain: [String] = []
    ) {
        self.id = id
        self.dataOrigin = dataOrigin
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
        self.originChain = originChain.isEmpty
            ? OriginChain.root(dataOrigin).entries
            : originChain
    }

    /// id 是否属于本会话来源的独立 id 空间（脏数据校验）。
    public var hasValidOriginID: Bool {
        OriginID.isValid(id, for: dataOrigin)
    }

    /// UI / 导出使用的来源链文本。
    public var originChainText: String {
        OriginChain(entries: originChain).displayText
    }

    /// 生成「另存副本」的会话：新 id 仍带同源前缀，来源不变，原链保留并追加副本说明。
    /// **不存在任何 `simulated -> real` 的转换路径。**
    public func duplicate(newID: String = UUID().uuidString) -> RunSession {
        let normalizedID = OriginID.normalize(newID, for: dataOrigin)
        let chain = OriginChain(entries: originChain).duplicateNote(copyID: normalizedID)
        return RunSession(
            id: normalizedID,
            dataOrigin: dataOrigin,
            startTime: startTime,
            endTime: endTime,
            durationSeconds: durationSeconds,
            totalDistanceMeters: totalDistanceMeters,
            avgSpeedMps: avgSpeedMps,
            avgPaceSecPerKm: avgPaceSecPerKm,
            totalSteps: totalSteps,
            elevationGainM: elevationGainM,
            elevationLossM: elevationLossM,
            routeId: routeId,
            simulationProfileId: simulationProfileId,
            rulePresetId: rulePresetId,
            note: note,
            createdAt: Date(),
            schemaVersion: schemaVersion,
            originChain: chain.entries
        )
    }
}

/// 回放状态（§3.2）。`dataOrigin` 驱动回放页常驻来源徽标。
public struct ReplayState: Codable, Sendable {
    public let sessionId: String
    public let dataOrigin: DataOrigin
    public var currentElapsedSeconds: TimeInterval
    public var playbackRate: PlaybackRate
    public var isPlaying: Bool

    public init(
        sessionId: String,
        dataOrigin: DataOrigin,
        currentElapsedSeconds: TimeInterval = 0,
        playbackRate: PlaybackRate = .x1,
        isPlaying: Bool = false
    ) {
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
        self.currentElapsedSeconds = currentElapsedSeconds
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
    }
}

/// 回放倍速（只改播放时钟，不改 `TrackPoint.timestamp`）。
public enum PlaybackRate: Double, Codable, CaseIterable, Sendable {
    case x0_5 = 0.5
    case x1 = 1
    case x2 = 2
    case x4 = 4
    case x8 = 8

    public var label: String {
        switch self {
        case .x0_5: return "0.5×"
        case .x1: return "1×"
        case .x2: return "2×"
        case .x4: return "4×"
        case .x8: return "8×"
        }
    }
}

/// 三重标记的三个通道（§7.5 / §B.11.1）。
public enum MarkerKind: String, Codable, Sendable, CaseIterable {
    /// ① 导出文件名前缀。
    case fileName
    /// ② 文件内 metadata / 首行 / 顶层。
    case fileContent
    /// ③ UI 常驻徽标元数据。
    case uiBadge

    public var localizedDescription: String {
        switch self {
        case .fileName: return "文件名前缀"
        case .fileContent: return "文件内标记"
        case .uiBadge: return "界面徽标"
        }
    }
}

/// 导出审计记录（§B.8）。每次导出持久化，供 AC-C2 / AC-C7 追溯。
public struct ExportRecord: Identifiable, Codable, Sendable {
    public let id: String
    public let sessionId: String
    public let dataOrigin: DataOrigin
    /// 取值 `gpx` / `csv` / `json`，与 `ExportFormat.rawValue` 对应。
    public let format: String
    public let fileName: String
    public let createdAt: Date
    public let markersIncluded: [MarkerKind]
    public let schemaVersion: String

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        dataOrigin: DataOrigin,
        format: String,
        fileName: String,
        createdAt: Date = Date(),
        markersIncluded: [MarkerKind] = MarkerKind.allCases,
        schemaVersion: String = AppConstants.schemaVersion
    ) {
        self.id = id
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
        self.format = format
        self.fileName = fileName
        self.createdAt = createdAt
        self.markersIncluded = markersIncluded
        self.schemaVersion = schemaVersion
    }

    /// 三重标记是否齐全（缺一即拒绝导出）。
    public var hasAllThreeMarkers: Bool {
        Set(markersIncluded) == Set(MarkerKind.allCases)
    }

    /// 文件名前缀是否正确。
    public var hasFileNameMarker: Bool {
        OriginMarkers.hasFileNamePrefix(fileName, for: dataOrigin)
    }

    /// 供审计日志使用的标记摘要（不含任何坐标）。
    public var markerSummary: String {
        markersIncluded.map(\.localizedDescription).joined(separator: " + ")
    }
}

/// 错误事件（§B.8），用于问题排查与合规审计。
public struct ErrorEvent: Identifiable, Codable, Sendable {
    public let id: String
    public let sessionId: String?
    public let kind: String
    public let timestamp: Date
    public let messageKey: String
    public let recoverable: Bool

    public init(
        id: String = UUID().uuidString,
        sessionId: String? = nil,
        kind: String,
        timestamp: Date = Date(),
        messageKey: String,
        recoverable: Bool
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.timestamp = timestamp
        self.messageKey = messageKey
        self.recoverable = recoverable
    }

    /// 由 `AppError` 便捷构造（结果码即 messageKey）。
    public init(error: AppError, sessionId: String? = nil, recoverable: Bool = true) {
        self.init(
            sessionId: sessionId,
            kind: String(describing: error),
            messageKey: error.resultCode,
            recoverable: recoverable
        )
    }
}
