import Foundation

// MARK: - 多预设对比表（F39 / §B.7.3）

/// 并列对比表的一行（一个假设条件 × 每个预设的三态结论）。
/// 表格中**不存在任何 score / grade / rank / 有效成绩**字段。
public struct ComparisonRow: Codable, Sendable, Hashable {
    public let condition: RuleCondition
    public let label: String
    /// 与 `ComparisonTable.columns` 一一对应，取值为「通过 / 不通过 / 数据不足 / —」。
    public let cells: [String]

    public init(condition: RuleCondition, label: String, cells: [String]) {
        self.condition = condition
        self.label = label
        self.cells = cells
    }
}

/// 多预设并列对比表：**只显示用户自建预设名称**，不显示任何真实平台 / 学校名称作为默认。
public struct ComparisonTable: Codable, Sendable {
    public let sessionId: String
    public let dataOrigin: DataOrigin
    /// 用户自建预设显示名（已按 `maxRulePresetsInComparison` 截断）。
    public let columns: [String]
    public let rows: [ComparisonRow]
    public let disclaimer: String
    public let notice: String
    public let headerText: String
    public let presetCount: Int
    public let truncated: Bool

    public init(
        sessionId: String,
        dataOrigin: DataOrigin = .simulated,
        columns: [String],
        rows: [ComparisonRow],
        disclaimer: String = AppConstants.ruleDisclaimer,
        notice: String = AppConstants.ruleEvaluationNotice,
        presetCount: Int,
        truncated: Bool = false
    ) {
        self.sessionId = sessionId
        self.dataOrigin = dataOrigin
        self.columns = columns
        self.rows = rows
        self.disclaimer = disclaimer
        self.notice = notice
        self.headerText = "\(disclaimer)\n\(AppConstants.evaluationObjectLabel)\n\(notice)"
        self.presetCount = presetCount
        self.truncated = truncated
    }

    /// 空表（无预设或 REAL 记录被拒绝评估时）。
    public static func empty(sessionId: String = "") -> ComparisonTable {
        ComparisonTable(sessionId: sessionId, columns: [], rows: [], presetCount: 0)
    }

    /// 面向用户的可读摘要（含固定免责声明与评估对象标注）。
    public var summaryText: String {
        var lines: [String] = [headerText]
        if truncated {
            lines.append("预设数量超过 \(AppConstants.maxRulePresetsInComparison) 个，仅并列显示前 \(presetCount) 个")
        }
        lines.append("并列预设：" + columns.joined(separator: " / "))
        for row in rows {
            lines.append("\(row.label)：" + row.cells.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 规则评估器（F39 / §B.7.4）

/// 三态评估（通过 / 不通过 / 数据不足）+ 多预设并列对比，**无分数**。
///
/// 合规硬约束：
/// - 前置 `guard session.dataOrigin == .simulated`，REAL 记录不参与规则评估；
/// - 输出固定免责声明与「评估对象：测试数据 / SIMULATED」；
/// - `RuleEvaluationResult` / `ComparisonTable` 类型系统层面无 score / grade / rank。
public struct RuleEvaluator: RuleEvaluating {

    /// 逐条件结果附带的固定合规说明。
    public let evaluatorNote: String

    public init() {
        self.evaluatorNote = "仅本地模拟评估，不产生、不上传任何成绩"
    }

    /// 对一条 SIMULATED 记录套用 1..N 个用户自建假设预设。
    /// REAL 记录直接返回空数组（不参与评估），由 UI 显示「真实记录不参与假设规则评估」。
    public func evaluate(
        session: RunSession,
        points: [TrackPoint],
        presets: [RulePreset]
    ) -> [RuleEvaluationResult] {
        guard session.dataOrigin == .simulated else {
            return []
        }
        guard !presets.isEmpty else {
            return []
        }
        return presets.compactMap { preset in
            // 防御：非假设 / 非 simulated 预设不参与评估。
            guard preset.isHypothetical, preset.dataOrigin == .simulated else {
                return nil
            }
            let conditions = preset.validity.conditions.isEmpty
                ? RuleCondition.allCases
                : preset.validity.conditions
            let results = conditions.map { condition in
                evaluateCondition(condition, session: session, points: points, preset: preset)
            }
            let overall = overallOutcome(results, requireAll: preset.validity.requireAllConditions)
            return RuleEvaluationResult(
                presetId: preset.id,
                displayName: preset.displayName,
                sessionId: session.id,
                dataOrigin: .simulated,
                conditionResults: results,
                overallOutcome: overall,
                disclaimer: AppConstants.ruleDisclaimer,
                notice: AppConstants.ruleEvaluationNotice,
                evaluatedAt: Date()
            )
        }
    }

    /// 并列对比：只取用户自建预设显示名，最多 `maxRulePresetsInComparison` 个。
    public func compare(_ results: [RuleEvaluationResult]) -> ComparisonTable {
        let eligible = results.filter { $0.dataOrigin == .simulated }
        guard !eligible.isEmpty else {
            return ComparisonTable.empty()
        }
        let limited = Array(eligible.prefix(AppConstants.maxRulePresetsInComparison))
        // 只显示用户自建预设名称，不显示任何平台名称。
        let columns = limited.map(\.displayName)
        let conditions = RuleCondition.allCases.filter { condition in
            limited.contains { result in
                result.conditionResults.contains { $0.condition == condition }
            }
        }
        let rows: [ComparisonRow] = conditions.map { condition in
            let cells = limited.map { result -> String in
                guard let match = result.conditionResults.first(where: { $0.condition == condition }) else {
                    return "—"
                }
                return match.outcome.localizedDescription
            }
            return ComparisonRow(
                condition: condition,
                label: condition.localizedDescription,
                cells: cells
            )
        }
        return ComparisonTable(
            sessionId: limited.first?.sessionId ?? "",
            dataOrigin: .simulated,
            columns: columns,
            rows: rows,
            presetCount: limited.count,
            truncated: eligible.count > limited.count
        )
    }

    // MARK: - 私有：总体三态

    private func overallOutcome(
        _ results: [RuleConditionResult],
        requireAll: Bool
    ) -> EvaluationOutcome {
        guard !results.isEmpty else { return .insufficientData }
        if results.contains(where: { $0.outcome == .failed }) {
            return .failed
        }
        if requireAll {
            return results.allSatisfy { $0.outcome == .passed } ? .passed : .insufficientData
        }
        return results.contains { $0.outcome == .passed } ? .passed : .insufficientData
    }

    // MARK: - 私有：逐条件三态评估

    /// 逐条件给出「通过 / 不通过 / 数据不足」+ 实测值 + 示例假设阈值。
    /// 所有阈值文案都带「示例假设值」语义（由 `RuleConditionResult.displayText` 统一标注）。
    private func evaluateCondition(
        _ condition: RuleCondition,
        session: RunSession,
        points: [TrackPoint],
        preset: RulePreset
    ) -> RuleConditionResult {
        let hasData = !points.isEmpty
        switch condition {
        case .minDistance:
            let minimum = preset.distance.minDistanceMeters
            let threshold = "≥ \(Int(minimum)) m"
            guard hasData else { return insufficient(condition, threshold: threshold) }
            return verdict(
                condition,
                measured: session.totalDistanceMeters,
                passed: session.totalDistanceMeters >= minimum,
                threshold: threshold
            )

        case .maxDistance:
            let maximum = preset.distance.maxDistanceMeters
            let threshold = maximum == 0 ? "不限（0 = 不限制）" : "≤ \(Int(maximum)) m"
            guard hasData else { return insufficient(condition, threshold: threshold) }
            let passed = maximum == 0 || session.totalDistanceMeters <= maximum
            return verdict(condition, measured: session.totalDistanceMeters, passed: passed, threshold: threshold)

        case .duration:
            let minimum = preset.duration.minDurationSeconds
            let maximum = preset.duration.maxDurationSeconds
            let threshold = "\(Int(minimum))–\(maximum == 0 ? "不限" : "\(Int(maximum))") s"
            guard hasData else { return insufficient(condition, threshold: threshold) }
            let passed = session.durationSeconds >= minimum
                && (maximum == 0 || session.durationSeconds <= maximum)
            return verdict(condition, measured: session.durationSeconds, passed: passed, threshold: threshold)

        case .pace:
            let minimum = preset.pace.minPaceSecPerKm
            let maximum = preset.pace.maxPaceSecPerKm
            let threshold = "\(Int(minimum))–\(Int(maximum)) s/km（\(preset.pace.paceBasis.localizedDescription)）"
            let pace = session.avgPaceSecPerKm
            guard hasData, pace.isFinite, pace > 0 else {
                return insufficient(condition, threshold: threshold)
            }
            return verdict(condition, measured: pace, passed: pace >= minimum && pace <= maximum, threshold: threshold)

        case .cadence:
            let minimum = preset.cadence.minCadenceSpm
            let maximum = preset.cadence.maxCadenceSpm
            let threshold = "\(Int(minimum))–\(Int(maximum)) spm"
            let cadences = points.map(\.cadenceSpm).filter { $0.isFinite && $0 > 0 }
            guard !cadences.isEmpty else { return insufficient(condition, threshold: threshold) }
            let average = cadences.reduce(0, +) / Double(cadences.count)
            return verdict(condition, measured: average, passed: average >= minimum && average <= maximum, threshold: threshold)

        case .cadenceFluctuation:
            let threshold = "≤ \(preset.cadence.cadenceFluctuationThreshold)（自定义统计阈值）"
            guard preset.cadence.cadenceFluctuationCheck else {
                return RuleConditionResult(
                    condition: condition,
                    outcome: .insufficientData,
                    hypotheticalThreshold: threshold,
                    note: "该假设检查项未启用，不产生判定"
                )
            }
            let cadences = points.map(\.cadenceSpm).filter { $0.isFinite && $0 > 0 }
            guard cadences.count > 1 else { return insufficient(condition, threshold: threshold) }
            let mean = cadences.reduce(0, +) / Double(cadences.count)
            guard mean > 0 else { return insufficient(condition, threshold: threshold) }
            let variance = cadences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(cadences.count)
            let fluctuation = sqrt(variance) / mean
            return verdict(
                condition,
                measured: fluctuation,
                passed: fluctuation <= preset.cadence.cadenceFluctuationThreshold,
                threshold: threshold
            )

        case .maxPause:
            let maximum = preset.duration.maxPauseSeconds
            let threshold = "≤ \(Int(maximum)) s"
            guard hasData else { return insufficient(condition, threshold: threshold) }
            var pauseSeconds: TimeInterval = 0
            var previous: TrackPoint?
            for point in points {
                if let previous = previous, point.isPaused {
                    pauseSeconds += max(0, point.timestamp.timeIntervalSince(previous.timestamp))
                }
                previous = point
            }
            return verdict(condition, measured: pauseSeconds, passed: pauseSeconds <= maximum, threshold: threshold)

        case .timeWindow:
            let threshold = preset.timeWindows.map { "\($0.start)–\($0.end)" }.joined(separator: ", ")
            guard hasData, !preset.timeWindows.isEmpty else {
                return insufficient(condition, threshold: threshold)
            }
            let passed = preset.timeWindows.contains { $0.contains(session.startTime) }
            return RuleConditionResult(
                condition: condition,
                outcome: passed ? .passed : .failed,
                measuredValue: nil,
                hypotheticalThreshold: threshold,
                note: "按记录开始时间的本地时钟判定"
            )

        case .dateRange:
            let threshold = "可选日期范围"
            guard let range = preset.dateRange else {
                return RuleConditionResult(
                    condition: condition,
                    outcome: .passed,
                    hypotheticalThreshold: threshold,
                    note: "未设置日期范围，视为不限制"
                )
            }
            let passed = range.isValid && range.contains(session.startTime)
            return RuleConditionResult(
                condition: condition,
                outcome: passed ? .passed : .failed,
                hypotheticalThreshold: threshold,
                note: "按记录开始日期判定"
            )

        case .closedLoop:
            let threshold = "首尾 ≤ 5 m"
            guard points.count > 2,
                  let first = points.first,
                  let last = points.last else {
                return insufficient(condition, threshold: threshold)
            }
            let distance = Units.haversineMeters(first.geoPoint, last.geoPoint)
            return verdict(condition, measured: distance, passed: distance <= 5, threshold: threshold)

        case .geofence:
            let threshold = preset.route.geofencePolygon.isEmpty
                ? "不限制（空多边形）"
                : "\(preset.route.geofencePolygon.count) 顶点用户自定义多边形"
            guard hasData else { return insufficient(condition, threshold: threshold) }
            let passed = preset.route.geofencePolygon.isEmpty
                || points.allSatisfy { preset.route.contains($0.geoPoint) }
            return RuleConditionResult(
                condition: condition,
                outcome: passed ? .passed : .failed,
                hypotheticalThreshold: threshold,
                note: "多边形为用户自定义坐标，非任何平台围栏"
            )

        case .dailyCap, .dailyValidRecordCap, .routeType, .waypoints,
             .finishPoint, .orderStrict:
            // 这些条件需要「当日全部记录集」或「路线点位详情」，而评估输入只有一条会话 + 采样点，
            // 按三态规范返回「数据不足」，绝不臆造数据后给出通过 / 不通过。
            return insufficient(condition, threshold: threshold(for: condition, preset: preset))
        }
    }

    /// 若干条件的假设阈值文案。
    private func threshold(for condition: RuleCondition, preset: RulePreset) -> String {
        switch condition {
        case .dailyCap: return "≤ \(Int(preset.distance.dailyCapMeters)) m/日"
        case .dailyValidRecordCap: return "≤ \(preset.validity.dailyValidRecordCap) 条/日"
        case .routeType: return preset.route.routeType.localizedDescription
        case .waypoints: return "必经 \(preset.waypoints.requiredMandatoryCount) / 普通 \(preset.waypoints.requiredRandomCount) 点"
        case .finishPoint: return preset.waypoints.finishPointRequired ? "需要终点点" : "不要求终点点"
        case .orderStrict: return preset.waypoints.orderStrict ? "按序经过" : "不要求按序"
        default: return "示例假设值"
        }
    }

    /// 构造一条「数据不足」结果。
    private func insufficient(
        _ condition: RuleCondition,
        threshold: String
    ) -> RuleConditionResult {
        RuleConditionResult(
            condition: condition,
            outcome: .insufficientData,
            hypotheticalThreshold: threshold,
            note: "缺少可判定的实测数据，不臆造、不插值；\(evaluatorNote)"
        )
    }

    /// 构造一条带实测值的三态结果。
    private func verdict(
        _ condition: RuleCondition,
        measured: Double,
        passed: Bool,
        threshold: String
    ) -> RuleConditionResult {
        RuleConditionResult(
            condition: condition,
            outcome: passed ? .passed : .failed,
            measuredValue: measured.isFinite ? measured : nil,
            hypotheticalThreshold: threshold,
            note: evaluatorNote
        )
    }
}
