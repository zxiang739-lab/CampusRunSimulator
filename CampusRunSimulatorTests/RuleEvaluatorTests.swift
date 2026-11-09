import Foundation
import XCTest
@testable import CampusRunSimulator

/// F63 · 规则评估测试（AC-C6 / AC-F8 / §B.7.4）。
///
/// 诚实边界：本文件只验证纯逻辑（三态评估、JSON 契约、无分数字段、REAL 拒绝评估），
/// 不初始化 HealthKit / 定位服务，不联网；规则预设全部为「示例假设值」，不内置任何真实平台规则。
/// 评估页 UI 的固定免责声明展示与多预设交互需 iOS 模拟器 / 真机验收，本地 Linux 未执行。
final class RuleEvaluatorTests: XCTestCase {

    // MARK: - 测试夹具

    private let baseTime = Date(timeIntervalSince1970: 1_767_232_800) // 2026-01-01T02:00:00Z

    private func makeSession(origin: DataOrigin, distance: Double = 3_000) -> RunSession {
        RunSession(
            id: OriginID.makeID(origin, suffix: "rule_\(origin.rawValue)"),
            dataOrigin: origin,
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(900),
            durationSeconds: 900,
            totalDistanceMeters: distance,
            avgSpeedMps: distance / 900,
            avgPaceSecPerKm: 300,
            totalSteps: 2_550,
            elevationGainM: 5,
            elevationLossM: 3,
            note: "规则评估测试记录",
            createdAt: baseTime,
            schemaVersion: AppConstants.schemaVersion
        )
    }

    private func makePoints(origin: DataOrigin, sessionID: String) -> [TrackPoint] {
        (0..<12).map { index in
            TrackPoint(
                id: OriginID.makeID(origin, suffix: "rule_point_\(index)"),
                sessionId: sessionID,
                dataOrigin: origin,
                timestamp: baseTime.addingTimeInterval(Double(index) * 30),
                elapsedSeconds: Double(index) * 30,
                latitude: 30.3010 + Double(index) * 0.0003,
                longitude: 120.0810 + Double(index) * 0.0003,
                altitudeM: 12 + Double(index) * 0.2,
                horizontalAccuracyM: 5,
                speedMps: 3.3,
                instantPaceSecPerKm: 300,
                avgPaceSecPerKm: 300,
                cadenceSpm: 170,
                strideLengthM: Units.strideLength(speedMps: 3.3, cadenceSpm: 170),
                cumulativeSteps: Double(index) * 85,
                cumulativeDistanceM: Double(index) * 250,
                segmentIndex: 0
            )
        }
    }

    /// 宽松预设：最低距离 1 km，其余取默认示例假设值。
    private func makeLenientPreset(id: String = "hypo_lenient") -> RulePreset {
        RulePreset(
            id: id,
            displayName: "宽松假设 A",
            distance: RuleDistance(minDistanceMeters: 1_000),
            validity: RecordValidity(conditions: RuleCondition.allCases),
            meta: RuleMeta(comparisonGroup: "课堂对比组 1")
        )
    }

    /// 严格预设：最低距离 50 km，必然产生「不通过」。
    private func makeStrictPreset(id: String = "hypo_strict") -> RulePreset {
        RulePreset(
            id: id,
            displayName: "严格假设 B",
            distance: RuleDistance(minDistanceMeters: 50_000),
            validity: RecordValidity(conditions: RuleCondition.allCases),
            meta: RuleMeta(comparisonGroup: "课堂对比组 1")
        )
    }

    // MARK: - [T11] 规则三态评估（补充测试类，覆盖 AC-C6 / AC-F8）

    func testThreeStateOnly() {
        // [T11] 逐条件只允许「通过 / 不通过 / 数据不足」三态，且三态都能真实出现。
        let session = makeSession(origin: .simulated)
        let points = makePoints(origin: .simulated, sessionID: session.id)
        let results = RuleEvaluator().evaluate(
            session: session,
            points: points,
            presets: [makeLenientPreset(), makeStrictPreset()]
        )
        XCTAssertEqual(results.count, 2)

        var observed = Set<EvaluationOutcome>()
        for result in results {
            XCTAssertFalse(result.conditionResults.isEmpty)
            for condition in result.conditionResults {
                observed.insert(condition.outcome)
                XCTAssertFalse(condition.hypotheticalThreshold.isEmpty,
                               "阈值文案必须显式标注为示例假设值")
                XCTAssertFalse(condition.displayText.isEmpty)
                XCTAssertTrue(condition.displayText.contains("示例假设值"))
                XCTAssertTrue(Set(EvaluationOutcome.allCases).contains(condition.outcome))
            }
            XCTAssertTrue(Set(EvaluationOutcome.allCases).contains(result.overallOutcome))
        }
        XCTAssertEqual(observed, Set(EvaluationOutcome.allCases),
                       "通过 / 不通过 / 数据不足三态必须都能由真实数据触发")

        // 「数据不足」必须由需要当日全量记录或点位详情的条件真实产生，不得臆造后判定。
        let insufficient = results.flatMap(\.conditionResults)
            .filter { $0.outcome == .insufficientData }
        XCTAssertFalse(insufficient.isEmpty)
        XCTAssertTrue(insufficient.contains { $0.condition == .dailyCap })
        XCTAssertTrue(insufficient.allSatisfy { $0.measuredValue == nil },
                      "数据不足不得给出臆造的实测值")

        // 宽松预设的最低距离应通过，严格预设应不通过。
        let lenient = results.first { $0.presetId == "hypo_lenient" }
        let minDistance = lenient?.conditionResults.first { $0.condition == .minDistance }
        if let minDistance = minDistance {
            XCTAssertEqual(minDistance.outcome, .passed)
        } else {
            XCTFail("宽松预设必须输出最低距离判定")
        }
        let strict = results.first { $0.presetId == "hypo_strict" }
        let strictMinDistance = strict?.conditionResults.first { $0.condition == .minDistance }
        if let strictMinDistance = strictMinDistance {
            XCTAssertEqual(strictMinDistance.outcome, .failed)
        } else {
            XCTFail("严格预设必须输出最低距离判定")
        }
        if let strict = strict {
            XCTAssertEqual(strict.overallOutcome, .failed)
        } else {
            XCTFail("严格预设必须产生评估结果")
        }
    }

    func testNoScoreInResult() throws {
        // [T11][AC-C6] 评估结果在类型系统与 JSON 两个层面都不存在 score / grade / rank。
        let session = makeSession(origin: .simulated)
        let points = makePoints(origin: .simulated, sessionID: session.id)
        let result = try XCTUnwrap(
            RuleEvaluator().evaluate(
                session: session, points: points, presets: [makeLenientPreset()]
            ).first
        )

        let forbidden = ["score", "grade", "rank", "validrecord"]
        let resultLabels = Mirror(reflecting: result).children.compactMap(\.label).map { $0.lowercased() }
        for word in forbidden {
            XCTAssertFalse(resultLabels.contains { $0.contains(word) },
                           "RuleEvaluationResult 不得含 \(word) 字段")
        }
        XCTAssertNil(resultLabels.first { $0.contains("score") || $0.contains("grade") })

        let jsonData = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )
        let keys = object.keys.map { $0.lowercased() }
        XCTAssertFalse(keys.contains { $0.contains("score") || $0.contains("grade") || $0.contains("rank") })
        XCTAssertEqual(object["disclaimer"] as? String, AppConstants.ruleDisclaimer)
        XCTAssertEqual(object["notice"] as? String, AppConstants.ruleEvaluationNotice)
        XCTAssertTrue(result.headerText.contains(AppConstants.evaluationObjectLabel))
        XCTAssertTrue(result.isEvaluable)

        let table = RuleEvaluator().compare([result])
        let tableLabels = Mirror(reflecting: table).children.compactMap(\.label).map { $0.lowercased() }
        XCTAssertFalse(tableLabels.contains { $0.contains("score") || $0.contains("grade") })
        XCTAssertFalse(table.summaryText.lowercased().contains("score"))

        // RecordValidity 的「不产生成绩 / 不产生外部成绩」固定 false，且解码无法篡改。
        let validity = RecordValidity()
        XCTAssertFalse(validity.resultIsScore)
        XCTAssertFalse(validity.producesExternalRecord)
        var fake = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(validity)) as? [String: Any]
        )
        fake["resultIsScore"] = true
        fake["producesExternalRecord"] = true
        let restored = try JSONDecoder().decode(
            RecordValidity.self,
            from: JSONSerialization.data(withJSONObject: fake)
        )
        XCTAssertFalse(restored.resultIsScore, "JSON 声明 true 也必须被强制为 false")
        XCTAssertFalse(restored.producesExternalRecord)
    }

    func testHypotheticalForcedTrue() throws {
        // [T11][AC-C6] isHypothetical / disclaimer / dataOrigin 三处强制，JSON 篡改一律拒绝。
        let preset = RulePreset()
        XCTAssertTrue(preset.isHypothetical)
        XCTAssertEqual(preset.dataOrigin, .simulated)
        XCTAssertEqual(preset.disclaimer, AppConstants.ruleDisclaimer)
        XCTAssertEqual(preset.meta.source, AppConstants.documentSource)
        XCTAssertTrue(preset.isBasicallyValid)
        XCTAssertNoThrow(try RuleValidator().validate(preset))

        let validator = RuleValidator()
        let data = try validator.encodePreset(preset)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["isHypothetical"] as? Bool, true)
        XCTAssertEqual(object["dataOrigin"] as? String, DataOrigin.simulated.rawValue)
        XCTAssertEqual(object["disclaimer"] as? String, AppConstants.ruleDisclaimer)

        // 篡改 isHypothetical=false：三条解码入口都必须拒绝。
        var tampered = object
        tampered["isHypothetical"] = false
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        for decoder in [
            { try validator.decodePreset(tamperedData) },
            { try TabularCodec().decodePresetJSON(tamperedData) }
        ] {
            XCTAssertThrowsError(try decoder()) { error in
                guard case AppError.ruleHypotheticalViolation = error else {
                    return XCTFail("isHypothetical=false 必须抛 ruleHypotheticalViolation，实际 \(error)")
                }
            }
        }
        XCTAssertThrowsError(try JSONDecoder().decode(RulePreset.self, from: tamperedData),
                             "冻结解码器同样必须拒绝非假设预设")

        // 篡改 dataOrigin=real：解码后仍强制为 simulated（不信任文件声明）。
        var realTampered = object
        realTampered["dataOrigin"] = DataOrigin.real.rawValue
        let restored = try validator.decodePreset(
            try JSONSerialization.data(withJSONObject: realTampered)
        )
        XCTAssertEqual(restored.dataOrigin, .simulated)
        XCTAssertTrue(restored.isHypothetical)

        // 便捷构造同样强制合规字段。
        let made = try validator.makePreset(displayName: "课堂示例", comparisonGroup: "对比组 2")
        XCTAssertTrue(made.isHypothetical)
        XCTAssertEqual(made.dataOrigin, .simulated)
        XCTAssertEqual(made.meta.comparisonGroup, "对比组 2")
    }

    func testRealSessionRejected() throws {
        // [T11][AC-C6] REAL 记录不参与假设规则评估，前置守卫返回空数组。
        let realSession = makeSession(origin: .real)
        let realPoints = makePoints(origin: .real, sessionID: realSession.id)
        let presets = [makeLenientPreset(), makeStrictPreset(), makeLenientPreset(id: "hypo_third")]
        let evaluator = RuleEvaluator()

        XCTAssertTrue(evaluator.evaluate(
            session: realSession, points: realPoints, presets: presets
        ).isEmpty, "真实记录必须被前置守卫拒绝评估")
        let emptyTable = evaluator.compare([])
        XCTAssertTrue(emptyTable.columns.isEmpty)
        XCTAssertTrue(emptyTable.rows.isEmpty)
        XCTAssertEqual(emptyTable.presetCount, 0)

        let realResult = RuleEvaluationResult(
            presetId: "hypo_lenient",
            displayName: "宽松假设 A",
            sessionId: realSession.id,
            dataOrigin: .real,
            conditionResults: [],
            overallOutcome: .insufficientData
        )
        XCTAssertFalse(realResult.isEvaluable)
        XCTAssertTrue(evaluator.compare([realResult]).columns.isEmpty,
                      "REAL 结果不得进入并列对比表")

        // SIMULATED 记录：每个结果都带固定免责声明、评估对象标注与来源。
        let simulated = makeSession(origin: .simulated)
        let results = evaluator.evaluate(
            session: simulated,
            points: makePoints(origin: .simulated, sessionID: simulated.id),
            presets: presets
        )
        XCTAssertEqual(results.count, 3)
        for result in results {
            XCTAssertEqual(result.dataOrigin, .simulated)
            XCTAssertEqual(result.sessionId, simulated.id)
            XCTAssertEqual(result.disclaimer, AppConstants.ruleDisclaimer)
            XCTAssertEqual(result.notice, AppConstants.ruleEvaluationNotice)
            XCTAssertTrue(result.headerText.contains(AppConstants.disclaimer))
            XCTAssertTrue(result.headerText.contains(AppConstants.evaluationObjectLabel))
            XCTAssertTrue(result.isEvaluable)
        }
        XCTAssertTrue(evaluator.evaluate(session: simulated,
                                         points: makePoints(origin: .simulated, sessionID: simulated.id),
                                         presets: []).isEmpty, "无预设时不得臆造评估结果")
    }

    func testComparisonTableHasNoScoreAndDisclaimer() throws {
        // [T11][AC-F8] 多预设并列对比：只有用户自建预设名、三态文案、固定免责声明，无分数。
        let session = makeSession(origin: .simulated)
        let points = makePoints(origin: .simulated, sessionID: session.id)
        let evaluator = RuleEvaluator()
        let presets = (1...5).map { index in
            RulePreset(
                id: "hypo_compare_\(index)",
                displayName: "自建假设 \(index)",
                validity: RecordValidity(conditions: RuleCondition.allCases),
                meta: RuleMeta(comparisonGroup: "对比组 \(index)")
            )
        }
        let results = evaluator.evaluate(session: session, points: points, presets: presets)
        let table = evaluator.compare(results)

        XCTAssertEqual(table.dataOrigin, .simulated)
        XCTAssertEqual(table.sessionId, session.id)
        XCTAssertEqual(table.presetCount, AppConstants.maxRulePresetsInComparison)
        XCTAssertTrue(table.truncated, "超过上限的预设必须明确标注被截断")
        XCTAssertFalse(table.columns.isEmpty)
        XCTAssertTrue(table.columns.allSatisfy { $0.hasPrefix("自建假设") },
                      "并列对比只显示用户自建预设名称")
        XCTAssertFalse(table.rows.isEmpty)
        let allowedCells = Set(EvaluationOutcome.allCases.map(\.localizedDescription) + ["—"])
        for row in table.rows {
            XCTAssertEqual(row.cells.count, table.columns.count)
            XCTAssertTrue(row.cells.allSatisfy { allowedCells.contains($0) },
                          "单元格只能是三态文案或 —，不得出现分数")
            XCTAssertFalse(row.label.isEmpty)
        }
        XCTAssertTrue(table.headerText.contains(AppConstants.ruleDisclaimer))
        XCTAssertTrue(table.headerText.contains(AppConstants.evaluationObjectLabel))
        XCTAssertTrue(table.headerText.contains(AppConstants.ruleEvaluationNotice))
        XCTAssertTrue(table.summaryText.contains("预设数量超过"))
    }

    func testPresetJSONRoundTrip() throws {
        // [T11][AC-F8] 预设 JSON 导入导出往返一致，且合规字段不可被外部覆盖。
        let validator = RuleValidator()
        let original = try validator.makePreset(displayName: "往返预设", comparisonGroup: "对比组 R")
        let data = try validator.encodePreset(original)
        let restored = try validator.decodePreset(data)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.displayName, original.displayName)
        XCTAssertEqual(restored.schemaVersion, original.schemaVersion)
        XCTAssertEqual(restored.meta.comparisonGroup, original.meta.comparisonGroup)
        XCTAssertEqual(restored.distance.minDistanceMeters, original.distance.minDistanceMeters)
        XCTAssertEqual(restored.pace.maxPaceSecPerKm, original.pace.maxPaceSecPerKm)
        XCTAssertEqual(restored.validity.conditions, original.validity.conditions)
        XCTAssertTrue(restored.isHypothetical)
        XCTAssertEqual(restored.dataOrigin, .simulated)

        let tabular = TabularCodec()
        let tabularData = try tabular.encodePresetJSON(restored)
        let tabularRestored = try tabular.decodePresetJSON(tabularData)
        XCTAssertEqual(tabularRestored.id, original.id)
        XCTAssertEqual(tabularRestored.displayName, original.displayName)

        let copy = restored.duplicate(newID: "hypo_duplicated")
        XCTAssertEqual(copy.id, "hypo_duplicated")
        XCTAssertTrue(copy.displayName.contains("副本"))
        XCTAssertEqual(copy.meta.comparisonGroup, original.meta.comparisonGroup)
        XCTAssertTrue(copy.isHypothetical)
        XCTAssertEqual(copy.dataOrigin, .simulated)
    }

    func testRuleValidatorRejectsBadParameters() throws {
        // [T11][AC-C6] 非用户自建来源 / 配速倒挂 / 非法时段 / 错误 schema 一律拒绝。
        let validator = RuleValidator()
        let thirdParty = RulePreset(meta: RuleMeta(source: "third_party_platform_rule"))
        XCTAssertThrowsError(try validator.validate(thirdParty)) { error in
            guard case AppError.ruleHypotheticalViolation = error else {
                return XCTFail("内置 / 第三方真实规则必须被拒绝，实际 \(error)")
            }
        }

        let invertedPace = RulePreset(pace: RulePace(minPaceSecPerKm: 700, maxPaceSecPerKm: 300))
        XCTAssertThrowsError(try validator.validate(invertedPace)) { error in
            guard case AppError.ruleParameterConflict(let field) = error else {
                return XCTFail("配速倒挂应抛参数冲突，实际 \(error)")
            }
            XCTAssertEqual(field, "pace")
        }

        let badWindow = RulePreset(timeWindows: [TimeWindow(start: "25:00", end: "26:00")])
        XCTAssertFalse(badWindow.timeWindows.first?.isValid ?? true)
        XCTAssertThrowsError(try validator.validate(badWindow))

        let badSchema = RulePreset(schemaVersion: "9.9")
        XCTAssertThrowsError(try validator.validate(badSchema))

        let encoded = try JSONEncoder().encode(TimeWindow(start: "06:00", end: "22:00"))
        let window = try JSONDecoder().decode(TimeWindow.self, from: encoded)
        XCTAssertTrue(window.isValid)
        // 用 Calendar.current 构造本地中午，避免 CI Runner 时区差异影响时段判定。
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 12
        components.minute = 0
        let localNoon = try XCTUnwrap(Calendar.current.date(from: components))
        XCTAssertTrue(window.contains(localNoon))

        XCTAssertEqual(EvaluationOutcome.allCases.count, 3)
        XCTAssertEqual(AppError.ruleHypotheticalViolation.resultCode,
                       "E_RULE_HYPOTHETICAL_VIOLATION")
    }
}
