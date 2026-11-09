import Foundation

/// 数据来源。合规核心类型：只存在两个取值，没有任何 mutating / convert / toReal 能力。
/// 所有记录类实体的 `dataOrigin` 均为不可变 `let`，构造时注入后不可更改。
public enum DataOrigin: String, Codable, Sendable, Hashable {
    case simulated
    case real

    /// 是否为测试数据（只读派生，不改变来源）。
    public var isSimulated: Bool {
        self == .simulated
    }

    /// UI / 导出文字标记，不依赖颜色区分。
    public var displayText: String {
        OriginMarkers.text(for: self)
    }

    /// VoiceOver 可读标签，与可见文字一致。
    public var accessibilityLabel: String {
        OriginMarkers.accessibilityLabel(for: self)
    }

    /// SF Symbol 图标名，构成文字 + 图标双通道。
    public var symbolName: String {
        OriginMarkers.symbol(for: self)
    }

    /// 导出文件名前缀（`SIMULATED_` / `REAL_`）。
    public var fileNamePrefix: String {
        OriginMarkers.prefix(for: self)
    }

    /// 持久化 id 前缀（`sim_` / `real_`）。
    public var idPrefix: String {
        OriginID.prefix(self)
    }
}

/// 三重标记常量与文案的单一来源（F10）。
/// 三重标记 = ① 文件名前缀 ② 文件内 metadata / 首行 / 顶层 ③ UI 徽标，缺一即拒绝导出。
public enum OriginMarkers {
    // MARK: ① 文件名前缀
    public static let simulatedPrefix = "SIMULATED_"
    public static let realPrefix = "REAL_"

    // MARK: ② 文件内标记
    public static let simulatedFileContentMarker = "SIMULATED"
    public static let realFileContentMarker = "REAL"
    public static let metadataKeyDataOrigin = "dataOrigin"
    public static let metadataKeyIsHypothetical = "isHypothetical"
    public static let metadataKeyDisclaimer = "disclaimer"
    public static let metadataKeyGenerator = "generator"
    public static let metadataKeySchemaVersion = "schemaVersion"
    public static let csvFirstLinePrefix = "# dataOrigin="
    public static let gpxExtensionNamespace = "crs"
    public static let simulatedObjectLabel = "测试数据 / SIMULATED"

    // MARK: ③ UI 徽标
    public static let simulatedText = "测试数据 / SIMULATED"
    public static let realText = "真实记录"
    public static let simulatedSymbol = "testtube.2"
    public static let realSymbol = "figure.run"
    public static let simulatedAccessibilityLabel = "测试数据 SIMULATED"
    public static let realAccessibilityLabel = "真实记录"
    public static let evaluationObjectLabel = "评估对象：测试数据 / SIMULATED"

    /// 按来源返回文件名前缀。
    public static func prefix(for origin: DataOrigin) -> String {
        switch origin {
        case .simulated: return simulatedPrefix
        case .real: return realPrefix
        }
    }

    /// 按来源返回 UI 文字。
    public static func text(for origin: DataOrigin) -> String {
        switch origin {
        case .simulated: return simulatedText
        case .real: return realText
        }
    }

    /// 按来源返回 UI 图标名。
    public static func symbol(for origin: DataOrigin) -> String {
        switch origin {
        case .simulated: return simulatedSymbol
        case .real: return realSymbol
        }
    }

    /// 按来源返回 VoiceOver 标签。
    public static func accessibilityLabel(for origin: DataOrigin) -> String {
        switch origin {
        case .simulated: return simulatedAccessibilityLabel
        case .real: return realAccessibilityLabel
        }
    }

    /// 按来源返回文件内标记字符串。
    public static func fileContentMarker(for origin: DataOrigin) -> String {
        switch origin {
        case .simulated: return simulatedFileContentMarker
        case .real: return realFileContentMarker
        }
    }

    /// 判断文件名是否带有正确来源的前缀（导出校验用）。
    public static func hasFileNamePrefix(_ fileName: String, for origin: DataOrigin) -> Bool {
        (fileName as NSString).lastPathComponent.hasPrefix(prefix(for: origin))
    }

    /// 判断给定字节流的文件内标记是否齐全（导出校验用，绝不默认放行）。
    public static func containsFileContentMarker(_ data: Data, for origin: DataOrigin) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let marker = fileContentMarker(for: origin)
        return text.contains(marker) && text.contains(metadataKeyDataOrigin)
    }
}

/// 持久化 id 空间：两类数据物理分域，`sim_` / `real_` 前缀不可跨来源复用。
public enum OriginID {
    /// id 前缀，与 `DataOrigin` 一一对应。
    public static func prefix(_ origin: DataOrigin) -> String {
        switch origin {
        case .simulated: return "sim_"
        case .real: return "real_"
        }
    }

    /// 已知的全部前缀，用于识别并剥离错误来源的 id。
    private static let allPrefixes: [String] = ["sim_", "real_"]

    /// 生成一个带正确前缀的新 id。`UUID` 只允许用于 id，不参与任何数值生成。
    public static func makeID(_ origin: DataOrigin, suffix: String = UUID().uuidString) -> String {
        prefix(origin) + suffix
    }

    /// 校验 id 是否属于给定来源的 id 空间。
    public static func isValid(_ id: String, for origin: DataOrigin) -> Bool {
        id.hasPrefix(prefix(origin))
    }

    /// 把裸 id 规范化到指定来源的 id 空间。
    /// 若 id 已带另一来源前缀，先剥离再附加正确前缀，生成全新 id，绝不复用跨来源 id。
    public static func normalize(_ rawID: String, for origin: DataOrigin) -> String {
        let expected = prefix(origin)
        if rawID.hasPrefix(expected) {
            return rawID
        }
        var body = rawID
        for candidate in allPrefixes where rawID.hasPrefix(candidate) {
            body = String(rawID.dropFirst(candidate.count))
            break
        }
        return expected + body
    }

    /// 判断两个 id 是否处于同一来源域（用于混合来源守卫）。
    public static func isSameDomain(_ lhs: String, _ rhs: String) -> Bool {
        domain(of: lhs) == domain(of: rhs) && domain(of: lhs) != nil
    }

    /// 提取 id 所属来源域；无法识别返回 nil（脏数据）。
    public static func domain(of id: String) -> DataOrigin? {
        if id.hasPrefix(prefix(.simulated)) { return .simulated }
        if id.hasPrefix(prefix(.real)) { return .real }
        return nil
    }
}

/// 来源链：另存副本时保留原始来源链，绝不发生 `simulated -> real` 转换。
public struct OriginChain: Codable, Sendable, Hashable {
    public let entries: [String]

    public init(entries: [String] = []) {
        self.entries = entries
    }

    /// 以给定来源为根创建链。
    public static func root(_ origin: DataOrigin) -> OriginChain {
        OriginChain(entries: [OriginMarkers.text(for: origin)])
    }

    /// 追加一条链路记录，返回新值（值类型，不修改原链）。
    public func appending(_ note: String) -> OriginChain {
        OriginChain(entries: entries + [note])
    }

    /// 生成「另存副本」的链路：保留原链并追加副本说明，来源保持不变。
    public func duplicateNote(copyID: String) -> OriginChain {
        appending("另存副本 \(copyID)（来源保持不变）")
    }

    /// 链路的可读描述。
    public var displayText: String {
        entries.joined(separator: " → ")
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }
}
