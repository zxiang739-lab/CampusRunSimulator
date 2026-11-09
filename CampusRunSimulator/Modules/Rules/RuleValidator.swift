import Foundation
import SwiftData

// MARK: - 规则预设校验与存储（F38 / §B.7.2 / §B.7.3）

/// 用户自建**假设**规则预设的校验与 JSON 契约实现。
///
/// 合规硬约束（AC-C6 / §7.12-11）：
/// - `isHypothetical` 必须为 `true`，`dataOrigin` 必须为 `.simulated`；
/// - `source` 必须为 `user_defined`，拒绝任何内置 / 真实平台规则；
/// - 任何包含 `isHypothetical: false` 的 JSON 一律拒绝；
/// - 评估结果类型中不存在 score / grade / rank 字段。
public struct RuleValidator: Sendable {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 允许导入的 schema 版本（来自 `AppConstants` 单一来源）。
    public let requiredSchemaVersion: String

    public init() {
        self.requiredSchemaVersion = AppConstants.schemaVersion
    }

    // MARK: 参数合法性

    /// 校验预设全部参数；返回冲突字段对应的 `AppError`。
    public func validate(_ preset: RulePreset) throws {
        guard preset.isHypothetical else {
            throw AppError.ruleHypotheticalViolation
        }
        guard preset.dataOrigin == .simulated else {
            throw AppError.ruleHypotheticalViolation
        }
        guard preset.meta.source == AppConstants.documentSource else {
            // 拒绝把内置 / 第三方真实规则当作本地假设预设导入。
            throw AppError.ruleHypotheticalViolation
        }
        guard preset.schemaVersion == requiredSchemaVersion else {
            throw AppError.ruleParameterConflict(field: "schemaVersion")
        }
        guard !preset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.ruleParameterConflict(field: "displayName")
        }
        // 最快配速（数值小）不得大于最慢配速（数值大）。
        guard preset.pace.minPaceSecPerKm > 0,
              preset.pace.maxPaceSecPerKm > 0,
              preset.pace.minPaceSecPerKm <= preset.pace.maxPaceSecPerKm else {
            throw AppError.ruleParameterConflict(field: "pace")
        }
        guard preset.distance.minDistanceMeters >= 0,
              preset.distance.maxDistanceMeters >= 0,
              preset.distance.dailyCapMeters >= 0 else {
            throw AppError.ruleParameterConflict(field: "distance")
        }
        guard preset.duration.minDurationSeconds >= 0,
              preset.duration.maxDurationSeconds >= 0,
              preset.duration.maxPauseSeconds >= 0 else {
            throw AppError.ruleParameterConflict(field: "duration")
        }
        guard preset.timeWindows.allSatisfy(\.isValid) else {
            throw AppError.ruleParameterConflict(field: "timeWindows")
        }
        guard preset.isBasicallyValid else {
            throw AppError.ruleParameterConflict(field: "parameters")
        }
    }

    // MARK: JSON 契约

    /// 解码预设：先做 JSON 顶层 `isHypothetical` / `schemaVersion` / `source` 预检，
    /// 再走 `RulePreset` 冻结解码器（其 `init(from:)` 同样拒绝 `false`），最后完整 `validate`。
    public func decodePreset(_ data: Data) throws -> RulePreset {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.ruleParameterConflict(field: "json")
        }
        guard let hypothetical = object["isHypothetical"] as? Bool, hypothetical else {
            throw AppError.ruleHypotheticalViolation
        }
        guard let version = object["schemaVersion"] as? String,
              version == requiredSchemaVersion else {
            throw AppError.ruleParameterConflict(field: "schemaVersion")
        }
        guard let meta = object["meta"] as? [String: Any],
              let source = meta["source"] as? String,
              source == AppConstants.documentSource else {
            throw AppError.ruleHypotheticalViolation
        }
        let preset: RulePreset
        do {
            preset = try Self.decoder.decode(RulePreset.self, from: data)
        } catch {
            if String(describing: error).contains("isHypothetical") {
                throw AppError.ruleHypotheticalViolation
            }
            throw AppError.ruleParameterConflict(field: "json: \(error.localizedDescription)")
        }
        try validate(preset)
        return preset
    }

    /// 编码预设：强制写出 `isHypothetical: true`、`disclaimer`、`dataOrigin: simulated`（由
    /// `RulePreset.encode(to:)` 保证），并在编码前执行完整校验。
    public func encodePreset(_ preset: RulePreset) throws -> Data {
        try validate(preset)
        return try Self.encoder.encode(preset)
    }

    // MARK: 便捷构造（供设置页新建预设使用）

    /// 生成一份合规的空预设（全部字段为示例假设值，非任何平台真实规则）。
    public func makePreset(displayName: String, comparisonGroup: String) throws -> RulePreset {
        let preset = RulePreset(
            id: "hypo_" + UUID().uuidString,
            displayName: displayName,
            meta: RuleMeta(comparisonGroup: comparisonGroup)
        )
        try validate(preset)
        return preset
    }
}

// MARK: - 多预设 CRUD 存储

/// 预设存储在 **simulated** 容器（规则预设恒 `.simulated`，与真实记录物理隔离）。
/// `duplicate` 复用 `RulePreset.duplicate()`，保留 `comparisonGroup` 与合规字段。
public actor RulePresetStore {

    private let container: ModelContainer
    private let validator: RuleValidator

    public init(stores: PersistentStores, validator: RuleValidator = RuleValidator()) {
        // 合规：预设恒 simulated，只写 simulatedStore，绝不触碰 realStore。
        self.container = stores.simulatedStore
        self.validator = validator
    }

    /// 列出全部合规预设（脏数据 / `isHypothetical=false` 的对象由 `SDMapper.toValue` 返回 nil 后丢弃）。
    public func list() -> [RulePreset] {
        let context = ModelContext(container)
        let models = (try? context.fetch(FetchDescriptor<SDRulePreset>())) ?? []
        let presets = models.compactMap { SDMapper.toValue($0) }
        return presets.sorted { $0.displayName < $1.displayName }
    }

    /// 新增或更新预设（先校验，再以 id 覆盖写入）。
    public func save(_ preset: RulePreset) throws {
        try validator.validate(preset)
        let context = ModelContext(container)
        let models = (try? context.fetch(FetchDescriptor<SDRulePreset>())) ?? []
        for model in models where model.id == preset.id {
            context.delete(model)
        }
        let object = try SDMapper.fromValue(preset)
        context.insert(object)
        try context.save()
    }

    /// 另存副本：新 id、保留 `comparisonGroup`、合规字段依旧强制。
    public func duplicate(_ preset: RulePreset) throws -> RulePreset {
        let copy = preset.duplicate()
        try save(copy)
        return copy
    }

    /// 按 id 删除预设。
    public func delete(id: String) throws {
        let context = ModelContext(container)
        let models = (try? context.fetch(FetchDescriptor<SDRulePreset>())) ?? []
        var changed = false
        for model in models where model.id == id {
            context.delete(model)
            changed = true
        }
        if changed {
            try context.save()
        }
    }

    /// 导入 JSON 预设并落盘。
    public func importJSON(_ data: Data) throws -> RulePreset {
        let preset = try validator.decodePreset(data)
        try save(preset)
        return preset
    }

    /// 导出预设 JSON（强制带 `isHypothetical: true` 与免责声明）。
    public func exportJSON(_ preset: RulePreset) throws -> Data {
        try validator.encodePreset(preset)
    }
}
