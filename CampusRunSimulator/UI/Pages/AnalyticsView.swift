import Foundation
import SwiftUI
import Observation
import MapKit

// MARK: - 数据分析视图模型（F57 / §B.6.5）

/// 对**指定单一来源**的一条记录做 4 类曲线、区间统计、一致性 / 数据质量报告、
/// 假设规则评估、导出、回放到时间点；全部调 F36/F37/F39/F43/F44 的真实服务。
@MainActor
@Observable
public final class AnalyticsViewModel {

    public var axis: ChartAxis = .time
    public var tier: DownsamplingTier = .medium
    public var cursorSourceIndex: Int = 0
    public var rangeLower: Int = 0
    public var rangeUpper: Int = 0
    public var selectedPresetIds: Set<String> = []
    public var exportFormat: ExportFormat = .csv

    public private(set) var sessionId: String = ""
    public private(set) var session: RunSession? = nil
    public private(set) var points: [TrackPoint] = []
    public private(set) var availableReal: [RunSession] = []
    public private(set) var availableSimulated: [RunSession] = []
    public private(set) var presets: [RulePreset] = []
    public private(set) var series: [MetricSeries] = []
    public private(set) var segmentStatistics: SegmentStatistics? = nil
    public private(set) var invariantReport: InvariantReport? = nil
    public private(set) var qualityReport: DataQualityReport? = nil
    public private(set) var invariantNotice: String = ""
    public private(set) var evaluationResults: [RuleEvaluationResult] = []
    public private(set) var comparisonTable: ComparisonTable = .empty()
    public private(set) var evaluationText: String = ""
    public private(set) var errorMessage: String? = nil
    public private(set) var lastActionMessage: String = "尚未选择记录"
    public private(set) var isBusy: Bool = false

    private let seriesBuilder = SeriesBuilder()
    private let analysisBuilder = AnalysisBuilder()
    private let invariantValidator = InvariantValidator()
    private let ruleEvaluator = RuleEvaluator()

    public init() {}

    public var origin: DataOrigin { session?.dataOrigin ?? .simulated }
    public var pointCount: Int { points.count }
    public var seriesCount: Int { series.count }

    // MARK: 载入

    /// 载入指定 sessionId；为空时列出两分区候选（不混排）。
    public func load(sessionId: String) async {
        isBusy = true
        errorMessage = nil
        let passedTarget = sessionId
        let target = passedTarget.isEmpty ? (AppNavigation.shared.consumeSelectedSessionID() ?? "") : passedTarget
        await loadCandidates()
        if target.isEmpty {
            session = nil
            points = []
            series = []
            lastActionMessage = "请在下方按来源分区选择一条记录"
            isBusy = false
            return
        }
        await select(id: target)
        isBusy = false
    }

    /// 分别从两个独立容器读取候选记录，**绝不合并成一个列表**。
    public func loadCandidates() async {
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        availableReal = (try? await repository.fetch(origin: .real, predicate: RunPredicate())) ?? []
        availableSimulated = (try? await repository.fetch(origin: .simulated, predicate: RunPredicate())) ?? []
        presets = (try? await repository.presets()) ?? []
        let localPresets = AppServices.shared.loadPresets()
        for preset in localPresets where !presets.contains(where: { $0.id == preset.id }) {
            presets.append(preset)
        }
    }

    /// 选中一条记录：读取采样点 → 4 类曲线 → 报告 → 评估预设。
    public func select(id: String) async {
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            let loadedPoints = try await repository.points(sessionId: id)
            guard !loadedPoints.isEmpty else {
                session = nil
                points = []
                series = []
                errorMessage = "该记录没有可分析的采样点"
                lastActionMessage = "无法分析采样点为空的记录"
                return
            }
            let candidate = availableReal.first(where: { $0.id == id })
                ?? availableSimulated.first(where: { $0.id == id })
            guard let found = candidate else {
                session = nil
                points = []
                series = []
                errorMessage = "未找到记录 \(id)，可能已被删除或归入未分类"
                return
            }
            sessionId = id
            session = found
            points = loadedPoints
            cursorSourceIndex = 0
            rangeLower = 0
            rangeUpper = max(0, loadedPoints.count - 1)
            rebuildSeries()
            rebuildReports()
            rebuildSegmentStatistics()
            evaluationResults = []
            comparisonTable = .empty()
            evaluationText = ""
            errorMessage = nil
            lastActionMessage = "已载入 \(loadedPoints.count) 点（\(found.dataOrigin.displayText)）"
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "载入失败：\(error.localizedDescription)"
        }
    }

    public func refresh() async {
        await load(sessionId: sessionId)
    }

    // MARK: 曲线与区间

    /// 时间 / 距离轴 + 3 档降采样，全部经 F36 `SeriesBuilder`（单一来源守卫）。
    public func rebuildSeries() {
        series = seriesBuilder.build(points, axis: axis, downsampling: tier)
    }

    public func setAxis(_ newAxis: ChartAxis) {
        axis = newAxis
        rebuildSeries()
        lastActionMessage = "横轴已切换为 \(newAxis.localizedDescription)，4 类曲线重建完成"
    }

    public func setTier(_ newTier: DownsamplingTier) {
        tier = newTier
        rebuildSeries()
        lastActionMessage = "降采样档位已切换为 \(newTier.localizedDescription)"
    }

    /// 区间统计：调 F37 `AnalysisBuilder.segmentStatistics`（真实计算）。
    public func selectRange(_ range: ClosedRange<Int>) {
        let lower = max(0, min(points.count - 1, range.lowerBound))
        let upper = max(lower, min(points.count - 1, range.upperBound))
        rangeLower = lower
        rangeUpper = upper
        rebuildSegmentStatistics()
    }

    public func rebuildSegmentStatistics() {
        guard !points.isEmpty else {
            segmentStatistics = nil
            return
        }
        segmentStatistics = analysisBuilder.segmentStatistics(
            points,
            range: rangeLower...rangeUpper
        )
        lastActionMessage = "区间统计：第 \(rangeLower + 1)–\(rangeUpper + 1) 点"
    }

    /// 报告：SIMULATED 显示 I1–I10；REAL 显示数据质量报告（不参与仿真一致性校验）。
    public func rebuildReports() {
        guard let session, !points.isEmpty else {
            invariantReport = nil
            qualityReport = nil
            invariantNotice = ""
            return
        }
        qualityReport = analysisBuilder.dataQualityReport(points)
        if session.dataOrigin == .simulated {
            Task { await buildInvariantReport(session: session) }
            invariantNotice = "正在按原始仿真模板复检 I1–I10…"
        } else {
            invariantReport = nil
            invariantNotice = "真实记录不参与仿真一致性校验 I1–I10；本页展示数据质量报告（精度门限 / 稀疏间隔 / 分段）"
        }
    }

    /// I1–I10：优先用记录绑定的原始 `SimulationProfile`，缺失时明确说明不可复现。
    private func buildInvariantReport(session: RunSession) async {
        guard let repository = AppServices.shared.repository else {
            invariantReport = nil
            invariantNotice = "本地存储未就绪，无法复检 I1–I10"
            return
        }
        let profiles = (try? await repository.profiles()) ?? []
        let localProfiles = AppServices.shared.loadProfiles()
        let all = profiles + localProfiles.filter { p in !profiles.contains(where: { $0.id == p.id }) }
        guard let profile = all.first(where: { $0.id == session.simulationProfileId }) else {
            invariantReport = nil
            invariantNotice = "未找到该记录绑定的原始仿真模板与种子，I10（同种子可复现）不可验证；"
                + "请查看数据质量报告，或前往模拟器重新生成带模板的数据集"
            return
        }
        let report = invariantValidator.validate(
            session: session,
            points: points,
            profile: profile
        )
        invariantReport = report
        invariantNotice = report.allPassed
            ? "I1–I10 全部通过（含 L = 60v/c 与同种子复现）"
            : "I1–I10 存在未通过项：\(report.failedIDs.map(\.rawValue).joined(separator: "、"))"
    }

    // MARK: 规则评估

    /// 三态评估 + 多预设并列对比；REAL 记录明确拒绝评估，附固定免责声明。
    public func evaluate(presets chosen: [RulePreset]) {
        guard let session else {
            errorMessage = "请先选择一条记录"
            return
        }
        guard session.dataOrigin == .simulated else {
            evaluationResults = []
            comparisonTable = .empty(sessionId: session.id)
            evaluationText = "真实记录不参与假设规则评估。规则评估对象只能是测试数据 / SIMULATED；"
                + "本评估不产生、不上传任何成绩。"
            lastActionMessage = "已拒绝评估：来源为真实记录"
            return
        }
        guard !chosen.isEmpty else {
            evaluationResults = []
            comparisonTable = .empty(sessionId: session.id)
            evaluationText = "请先在下方勾选至少一个用户自建假设规则预设（全部为示例假设值）。"
            lastActionMessage = "未选择预设，未产生任何评估结论"
            return
        }
        let results = ruleEvaluator.evaluate(session: session, points: points, presets: chosen)
        evaluationResults = results
        comparisonTable = ruleEvaluator.compare(results)
        evaluationText = results.isEmpty
            ? "无可评估的假设预设（非假设预设已按合规守卫排除）"
            : results.map { analysisBuilder.ruleEvaluationText($0) }
                .joined(separator: "\n\n——— 下一个预设 ———\n\n")
        lastActionMessage = "本地模拟评估完成：\(results.count) 份假设预设，无任何成绩输出"
    }

    // MARK: 导出 / 跳转

    /// 导出：单一来源守卫 + 三重标记，经 F43 `ExportManager`。
    public func export(format: ExportFormat) async throws -> URL {
        guard let session else {
            throw AppError.parameterConflict(reason: "请先选择一条记录再导出")
        }
        let file = try await AppServices.shared.exporter.export(
            session: session,
            points: points,
            format: format
        )
        let url = try file.writeToTemporaryDirectory()
        lastActionMessage = "已生成 \(file.fileName)（含三重来源标记）"
        return url
    }

    public func openHistory() {
        AppNavigation.shared.openHistory()
    }

    public func openSettings() {
        AppNavigation.shared.openSettings()
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
        lastActionMessage = "操作未完成：\(error.localizedDescription)"
    }
}

// MARK: - 数据分析页（F57）

/// 来源徽标常驻；评估结果页固定免责声明；四类曲线联动、跨段不连线、无无标记混画。
@MainActor
public struct AnalyticsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var vm = AnalyticsViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showReplay: Bool = false
    @State private var showEvaluation: Bool = false
    @State private var shareURL: URL? = nil
    @State private var replayStartElapsed: TimeInterval = 0

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                selectionSection
                errorSection
                if let session = vm.session {
                    summarySection(session)
                    chartsSection
                    rangeSection
                    reportSection
                    ruleSection
                    mapSection
                    exportSection
                    navigationSection
                } else {
                    emptySection
                }
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle(AppRoute.analytics(sessionId: nil).title)
        .task { await vm.load(sessionId: "") }
        .sheet(isPresented: $showReplay) {
            ReplayView(sessionId: vm.sessionId, startElapsed: replayStartElapsed)
        }
        .sheet(isPresented: $showEvaluation) { evaluationSheet }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ShareSheet(items: [shareURL]) { self.shareURL = nil }
            }
        }
    }

    // MARK: 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                OriginBadge(vm.origin, style: .full)
                Spacer(minLength: 2)
                Text(vm.lastActionMessage)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            Text("一次只分析单一来源的一条记录；SIMULATED 与 REAL 曲线不在同一图表混画")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if vm.isBusy { ProgressView("正在读取记录…").font(.caption) }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    /// 两分区候选列表：禁止「全部记录」混排成绩单。
    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("选择记录（按来源分区）")
                .font(.headline)
            Button("刷新候选与预设") { Task { await vm.refresh() } }
                .font(.caption)
                .buttonStyle(.bordered)
                .accessibilityLabel(AccessibilityLabels.refresh)
            candidateGroup(title: "真实记录", sessions: vm.availableReal, origin: .real)
            candidateGroup(title: "测试数据 SIMULATED", sessions: vm.availableSimulated, origin: .simulated)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private func candidateGroup(title: String, sessions: [RunSession], origin: DataOrigin) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                OriginBadge(origin, style: .compact)
                Text("\(title)（\(sessions.count)）")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
            }
            if sessions.isEmpty {
                Text("该分区暂无记录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions.prefix(8)) { session in
                    Button {
                        Task { await vm.select(id: session.id) }
                    } label: {
                        HStack {
                            Text(session.startTime.iso8601UTCString)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(Units.formatDistanceKm(session.totalDistanceMeters))
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("选择 \(origin.displayText) 记录 \(session.id)")
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = vm.errorMessage {
            ErrorStateView(
                origin: vm.origin,
                error: AppError.parameterConflict(reason: message),
                primaryTitle: "重新载入",
                primaryAction: { Task { await vm.refresh() } },
                secondaryTitle: "前往历史",
                secondaryAction: { vm.openHistory() }
            )
        }
    }

    private func summarySection(_ session: RunSession) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                OriginBadge(session.dataOrigin, style: .full)
                Text(session.id)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                spacing: AppTheme.Spacing.md
            ) {
                MetricCard(title: "总距离", value: Units.formatDistanceKm(session.totalDistanceMeters),
                           origin: session.dataOrigin)
                MetricCard(title: "总时长", value: Units.formatDuration(session.durationSeconds),
                           origin: session.dataOrigin)
                MetricCard(title: "平均配速", value: Units.formatPaceMinPerKm(session.avgPaceSecPerKm),
                           origin: session.dataOrigin)
                MetricCard(title: "采样点", value: "\(vm.pointCount)", unit: "点",
                           detail: "曲线 \(vm.seriesCount) 条 / \(vm.tier.localizedDescription)",
                           origin: session.dataOrigin)
                MetricCard(title: "累计爬升", value: AppTheme.metricNumberFormat(session.elevationGainM, unit: "m", digits: 1),
                           origin: session.dataOrigin)
                MetricCard(title: "来源链", value: session.dataOrigin.displayText,
                           detail: session.originChainText, origin: session.dataOrigin)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("四类联动曲线")
                .font(.headline)
            Picker("曲线横轴", selection: Binding(
                get: { vm.axis },
                set: { vm.setAxis($0) }
            )) {
                ForEach(ChartAxis.allCases, id: \.self) { item in
                    Text(item.localizedDescription).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Picker("降采样档位", selection: Binding(
                get: { vm.tier },
                set: { vm.setTier($0) }
            )) {
                ForEach(DownsamplingTier.allCases, id: \.self) { item in
                    Text(item.localizedDescription).tag(item)
                }
            }
            .pickerStyle(.menu)
            LinkedCursor(
                cursorSourceIndex: $vm.cursorSourceIndex,
                pointCount: max(1, vm.pointCount),
                summaryText: AppTheme.cursorSummary(
                    index: vm.cursorSourceIndex,
                    elapsed: vm.points[safe: vm.cursorSourceIndex]?.elapsedSeconds ?? 0,
                    distance: vm.points[safe: vm.cursorSourceIndex]?.cumulativeDistanceM ?? 0
                ),
                onSeek: { index in
                    if let point = vm.points[safe: index] {
                        replayStartElapsed = point.elapsedSeconds
                    }
                }
            )
            ForEach(vm.series) { item in
                SeriesChartView(
                    series: item,
                    cursorSourceIndex: $vm.cursorSourceIndex,
                    onCursorChange: { _ in }
                )
            }
            Button("回放到当前游标时间点") {
                let index = min(max(0, vm.cursorSourceIndex), max(0, vm.pointCount - 1))
                replayStartElapsed = vm.points[safe: index]?.elapsedSeconds ?? 0
                showReplay = true
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .accessibilityLabel("回放到当前游标时间点")
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var rangeSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("区间统计（采样点索引闭区间）")
                .font(.headline)
            Stepper(value: $vm.rangeLower, in: 0...max(0, vm.pointCount - 1), step: 1) {
                Text("起点索引 \(vm.rangeLower + 1)").font(.caption)
            }
            .onChange(of: vm.rangeLower) { _, _ in
                vm.selectRange(min(vm.rangeLower, vm.rangeUpper)...vm.rangeUpper)
            }
            Stepper(value: $vm.rangeUpper, in: 0...max(0, vm.pointCount - 1), step: 1) {
                Text("终点索引 \(vm.rangeUpper + 1)").font(.caption)
            }
            .onChange(of: vm.rangeUpper) { _, _ in
                vm.selectRange(vm.rangeLower...max(vm.rangeLower, vm.rangeUpper))
            }
            ActionButton(title: "重算区间统计", symbol: "arrow.clockwise", style: .bordered) {
                vm.selectRange(vm.rangeLower...vm.rangeUpper)
            }
            if let stats = vm.segmentStatistics {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                    spacing: AppTheme.Spacing.md
                ) {
                    MetricCard(title: "区间点数", value: "\(stats.pointCount)", unit: "点", origin: vm.origin)
                    MetricCard(title: "区间时长", value: Units.formatDuration(stats.durationSeconds), origin: vm.origin)
                    MetricCard(title: "区间距离", value: Units.formatDistanceKm(stats.distanceMeters), origin: vm.origin)
                    MetricCard(title: "平均速度", value: AppTheme.metricNumberFormat(stats.avgSpeedMps, unit: "m/s", digits: 2),
                               origin: vm.origin)
                    MetricCard(title: "平均配速", value: Units.formatPaceMinPerKm(stats.avgPaceSecPerKm), origin: vm.origin)
                    MetricCard(title: "平均步频", value: AppTheme.metricNumberFormat(stats.avgCadenceSpm, unit: "spm", digits: 0),
                               origin: vm.origin)
                    MetricCard(title: "平均步幅", value: AppTheme.metricNumberFormat(stats.avgStrideLengthM, unit: "m", digits: 2),
                               origin: vm.origin)
                    MetricCard(title: "海拔区间",
                               value: AppTheme.metricNumberFormat(stats.minAltitudeM, unit: "m", digits: 0)
                                   + " – " + AppTheme.metricNumberFormat(stats.maxAltitudeM, unit: "m", digits: 0),
                               detail: "爬升 \(AppTheme.metricNumberFormat(stats.elevationGainM, unit: "m", digits: 1)) / "
                                    + "下降 \(AppTheme.metricNumberFormat(stats.elevationLossM, unit: "m", digits: 1))",
                               origin: vm.origin)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("一致性与数据质量报告")
                .font(.headline)
            Text(vm.invariantNotice.isEmpty ? "暂无报告" : vm.invariantNotice)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let report = vm.invariantReport {
                Text(report.summary)
                    .font(.caption2.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(report.checks, id: \.id.rawValue) { check in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                            .accessibilityHidden(true)
                        Text("\(check.id.rawValue) \(check.id.localizedDescription)：\(check.detail)")
                            .font(.caption2)
                        Spacer(minLength: 2)
                    }
                }
            }
            if let quality = vm.qualityReport {
                Text(quality.summary)
                    .font(.caption2.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                Text("插值生成点恒为 0：本项目不插值冒充实测")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var ruleSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("规则符合性评估（示例假设值）")
                .font(.headline)
            Text(AppConstants.ruleDisclaimer)
                .font(.caption2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(AppConstants.evaluationObjectLabel)
                .font(.caption2)
            if vm.presets.isEmpty {
                Text("尚无用户自建假设预设，请前往设置页创建")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.presets) { preset in
                    Button {
                        if vm.selectedPresetIds.contains(preset.id) {
                            vm.selectedPresetIds.remove(preset.id)
                        } else {
                            vm.selectedPresetIds.insert(preset.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: vm.selectedPresetIds.contains(preset.id)
                                  ? "checkmark.square.fill" : "square")
                                .accessibilityHidden(true)
                            Text(preset.displayName)
                                .font(.caption)
                            Spacer(minLength: 2)
                            Text(preset.meta.comparisonGroup)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择假设预设 \(preset.displayName)")
                }
            }
            ActionButton(title: "执行本地模拟评估", symbol: "list.bullet.rectangle", style: .prominent) {
                let chosen = vm.presets.filter { vm.selectedPresetIds.contains($0.id) }
                vm.evaluate(presets: chosen)
                showEvaluation = true
            }
            if !vm.evaluationResults.isEmpty {
                Text("并列预设：\(vm.comparisonTable.columns.joined(separator: " / "))")
                    .font(.caption2)
                Text("共 \(vm.evaluationResults.count) 份三态结论，无任何分数 / 成绩 / 上传")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("轨迹与当前游标位置")
                .font(.caption.weight(.semibold))
            RouteMapView(
                points: vm.points.map(\.geoPoint),
                cameraPosition: $cameraPosition,
                annotations: cursorAnnotation,
                progress: 1
            )
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var cursorAnnotation: [RouteMapAnnotation] {
        guard let point = vm.points[safe: vm.cursorSourceIndex] else { return [] }
        return [RouteMapAnnotation(
            id: "analysis_cursor",
            label: "游标位置",
            coordinate: point.geoPoint,
            symbolName: "scope"
        )]
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("导出（单一来源 + 三重标记）")
                .font(.headline)
            Picker("导出格式", selection: $vm.exportFormat) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.localizedDescription).tag(format)
                }
            }
            .pickerStyle(.segmented)
            Text(AppConstants.singleOriginExportNotice)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ActionButton(title: "导出并分享", symbol: "square.and.arrow.up", style: .prominent) {
                Task {
                    do { shareURL = try await vm.export(format: vm.exportFormat) }
                    catch { vm.reportError(error) }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    private var navigationSection: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ActionButton(title: "轨迹回放", symbol: "play.circle") { showReplay = true }
            ActionButton(title: "历史记录", symbol: "clock.arrow.circlepath") { vm.openHistory() }
            ActionButton(title: "规则预设设置", symbol: "gearshape") { vm.openSettings() }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    private var emptySection: some View {
        EmptyStateView(
            origin: .simulated,
            title: "还没有选中记录",
            message: "请先在上方的「真实记录」或「测试数据 SIMULATED」分区选择一条记录；两类数据永不混排。",
            actionTitle: "前往历史记录",
            action: { vm.openHistory() },
            secondaryTitle: "新建仿真",
            secondaryAction: { AppNavigation.shared.openSimulation() }
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AppConstants.ruleEvaluationNotice)
                .font(.caption2)
            Text("跨段不连线、不插值；图表提供数值摘要文本，颜色不是唯一区分手段")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 评估结果页：固定免责声明 + 逐条件三态 + 并列对比表。
    private var evaluationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    OriginBadge(.simulated, style: .full)
                    Text(AppConstants.ruleDisclaimer).font(.caption.weight(.semibold))
                    Text(AppConstants.evaluationObjectLabel).font(.caption)
                    Text(AppConstants.ruleEvaluationNotice).font(.caption)
                    Divider()
                    if vm.comparisonTable.columns.isEmpty {
                        Text("无可并列的假设预设；真实记录不参与评估")
                            .font(.caption)
                    } else {
                        Text(vm.comparisonTable.summaryText)
                            .font(.caption2.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(vm.evaluationResults, id: \.presetId) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(result.displayName)：\(result.overallOutcome.localizedDescription)")
                                .font(.caption.weight(.semibold))
                            ForEach(result.conditionResults, id: \.condition.rawValue) { condition in
                                Text("· \(condition.displayText)").font(.caption2)
                            }
                        }
                    }
                    if !vm.evaluationText.isEmpty {
                        Divider()
                        Text(vm.evaluationText)
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("本地模拟评估")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showEvaluation = false }
                }
            }
        }
    }
}

// MARK: - 安全下标（仅本文件使用）

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
