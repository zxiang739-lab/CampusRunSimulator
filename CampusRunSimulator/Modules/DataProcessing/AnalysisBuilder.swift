import Foundation

// MARK: - 报告与分析构建器

/// 分段统计 / 极值均值 / 爬升死区 / 一致性报告 / 数据质量报告 / 规则评估文本（F37 / §3.2）。
/// 实现 BATCH_1 冻结的 `ReportBuilding` 协议，`range` 为**采样点索引闭区间**。
public struct AnalysisBuilder: ReportBuilding, Sendable {

    public init() {}

    // MARK: ReportBuilding 协议

    /// 区间统计（采样点索引闭区间），委托冻结的 `SegmentStatistics.build`（真实计算，越界自动钳制）。
    public func segmentStatistics(
        _ points: [TrackPoint],
        range: ClosedRange<Int>
    ) -> SegmentStatistics {
        SegmentStatistics.build(
            sessionId: points.first?.sessionId ?? "",
            points: points,
            range: range
        )
    }

    /// 一致性报告：补齐 I1–I10 缺失项（缺项按失败处理），
    /// 并独立复检「会话总距离 / 总步数 / 爬升下降 与末点累计」是否一致。
    public func invariantReport(_ result: SimulationResult) -> InvariantReport {
        var checks = result.report.checks
        let present = Set(checks.map(\.id))
        for id in InvariantID.allCases where !present.contains(id) {
            checks.append(.fail(id, detail: "一致性报告缺少该项，按失败处理（拒绝生成）"))
        }

        // 真实复检：会话汇总量必须由末点累计量派生，任何偏差都把对应 I 标为失败。
        if let last = result.points.last {
            if !isClose(
                result.session.totalDistanceMeters,
                last.cumulativeDistanceM,
                AppConstants.toleranceDistance
            ) {
                checks = checks.map { check in
                    guard check.id == .I3 else { return check }
                    return .fail(
                        .I3,
                        detail: "复检：会话总距离与末点累计距离不一致",
                        measured: result.session.totalDistanceMeters,
                        expected: last.cumulativeDistanceM
                    )
                }
            }
            if !isClose(
                result.session.totalSteps,
                last.cumulativeSteps,
                AppConstants.toleranceStepDistance
            ) {
                checks = checks.map { check in
                    guard check.id == .I7 else { return check }
                    return .fail(
                        .I7,
                        detail: "复检：会话总步数与末点累计步数不一致",
                        measured: result.session.totalSteps,
                        expected: last.cumulativeSteps
                    )
                }
            }
            // 复检会话汇总必须由末点累计派生（不依赖死区 ε 取值，保持误差模型可配）。
            if !isClose(
                result.session.elevationGainM,
                last.elevationGainSoFarM,
                AppConstants.toleranceDistance
            ) || !isClose(
                result.session.elevationLossM,
                last.elevationLossSoFarM,
                AppConstants.toleranceDistance
            ) {
                checks = checks.map { check in
                    guard check.id == .I8 else { return check }
                    return .fail(
                        .I8,
                        detail: "复检：会话累计爬升 / 下降与末点累计不一致",
                        measured: result.session.elevationGainM,
                        expected: last.elevationGainSoFarM
                    )
                }
            }
        } else if !result.points.isEmpty {
            // 空点数组但报告非空：把全部项标为失败，绝不误报通过。
            checks = InvariantID.allCases.map {
                .fail($0, detail: "缺少采样点，无法验证")
            }
        }

        // 按 I1 → I10 规范顺序输出，便于 UI 高亮与测试断言。
        let order = InvariantID.allCases
        checks.sort { lhs, rhs in
            let left = order.firstIndex(of: lhs.id) ?? 0
            let right = order.firstIndex(of: rhs.id) ?? 0
            return left < right
        }
        return InvariantReport(checks: checks)
    }

    /// 数据质量报告：统计精度门限丢弃数（> 50 m）、低精度、稀疏间隔、分段数；
    /// `interpolatedPointCount` 恒为 0（本项目绝不插值冒充实测）。
    public func dataQualityReport(_ points: [TrackPoint]) -> DataQualityReport {
        let discarded = points.filter { point in
            point.horizontalAccuracyM >= 0
                && point.horizontalAccuracyM > AppConstants.accuracyGateMeters
        }.count
        return DataQualityReport.build(
            sessionId: points.first?.sessionId ?? "",
            points: points,
            discarded: discarded
        )
    }

    /// 生成含**固定免责声明**的规则评估文本（§7.6 / §B.7.4）。
    /// 页首固定「示例假设值」声明 +「评估对象：测试数据 / SIMULATED」+ 三态结论，
    /// 全程无任何 score / 成绩 / 达标 / 上传断言。
    public func ruleEvaluationText(_ result: RuleEvaluationResult) -> String {
        var lines: [String] = []
        lines.append(result.disclaimer)
        lines.append(AppConstants.evaluationObjectLabel)
        lines.append(result.notice)
        lines.append("评估预设：\(result.displayName)（示例假设值，非任何平台真实规则）")
        lines.append("评估对象来源：\(result.dataOrigin.displayText)")
        lines.append("评估时间：\(result.evaluatedAt.iso8601UTCString)")
        lines.append("—— 逐条件结果 ——")
        if result.conditionResults.isEmpty {
            lines.append("（无可用条件，结论为数据不足）")
        } else {
            for condition in result.conditionResults {
                lines.append("· " + condition.displayText)
            }
        }
        lines.append("综合结论：\(result.overallOutcome.localizedDescription)")
        lines.append("本评估不产生、不上传任何成绩；不写入健康数据；不与真实运动记录混排。")
        return lines.joined(separator: "\n")
    }

    // MARK: 附加统计（极值 / 均值，供 F57 与报告复用）

    /// 全程平均速度（m/s）：由总距离 ÷ 总时长派生，不对逐点速度做独立平均。
    public func averageSpeed(_ points: [TrackPoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let duration = last.elapsedSeconds - first.elapsedSeconds
        let distance = last.cumulativeDistanceM - first.cumulativeDistanceM
        guard duration > 0, distance.isFinite else { return 0 }
        return max(0, distance / duration)
    }

    /// 海拔极值 (min, max)；空输入返回 (0, 0)。
    public func extremeAltitudes(_ points: [TrackPoint]) -> (min: Double, max: Double) {
        let values = points.map(\.altitudeM).filter { $0.isFinite }
        guard !values.isEmpty else { return (0, 0) }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    /// 累计爬升 / 下降（死区 ε 生效），委托 `Units.elevationGainLoss` 唯一实现处。
    public func totalElevationGainLoss(_ points: [TrackPoint]) -> (gain: Double, loss: Double) {
        Units.elevationGainLoss(points.map(\.altitudeM))
    }

    /// 逐点配速极值（s/km，仅统计有效配速）。
    public func extremePaces(_ points: [TrackPoint]) -> (fastest: Double, slowest: Double) {
        let values = points.map(\.instantPaceSecPerKm).filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else { return (0, 0) }
        return (values.min() ?? 0, values.max() ?? 0)
    }

    // MARK: 私有实现

    /// 相对容差比较（零值附近回退绝对容差）。
    private func isClose(_ measured: Double, _ expected: Double, _ tolerance: Double) -> Bool {
        guard measured.isFinite, expected.isFinite else { return false }
        let scale = max(abs(measured), abs(expected), 1)
        return abs(measured - expected) <= max(abs(tolerance) * scale, 1e-9)
    }
}
