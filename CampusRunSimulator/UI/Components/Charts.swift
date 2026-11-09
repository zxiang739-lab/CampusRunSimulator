import Foundation
import SwiftUI
import Charts

// MARK: - 分段折线分组（F50 / §B.6.5）

/// 一条曲线按 `breakBefore` 切成互不相连的分组；跨 segment / 信号中断 / 暂停段绝不连线。
public struct ChartSegmentGroup: Identifiable, Sendable {
    public let id: Int
    public let points: [SeriesPoint]

    public init(id: Int, points: [SeriesPoint]) {
        self.id = id
        self.points = points
    }

    /// Swift Charts 分段 series 名：不同分组不连线，但统一映射到同一来源颜色。
    public var seriesName: String {
        "分段 \(id + 1)"
    }
}

public enum ChartSegmenter {
    /// 真实切分：遇到 `breakBefore` 或 `segmentIndex` 变化即新建分组。
    public static func groups(_ points: [SeriesPoint]) -> [ChartSegmentGroup] {
        var result: [ChartSegmentGroup] = []
        var buffer: [SeriesPoint] = []
        var currentSegment: Int? = nil
        var groupID = 0
        for point in points {
            let shouldBreak: Bool
            if let currentSegment {
                shouldBreak = point.breakBefore || point.segmentIndex != currentSegment
            } else {
                shouldBreak = false
            }
            if shouldBreak, !buffer.isEmpty {
                result.append(ChartSegmentGroup(id: groupID, points: buffer))
                groupID += 1
                buffer = []
            }
            buffer.append(point)
            currentSegment = point.segmentIndex
        }
        if !buffer.isEmpty {
            result.append(ChartSegmentGroup(id: groupID, points: buffer))
        }
        return result
    }
}

// MARK: - 四类曲线（F50 / §B.6.5）

/// 单类指标曲线：`LineMark` / `AreaMark` + `RuleMark` 联动游标 + 拖动改游标 + 时间/距离轴 + 降采样档位。
/// **单一来源守卫**：`MetricSeries.origin` 决定文字图例，一个 Chart 只画一个来源，禁止无标记混画。
public struct SeriesChartView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let series: MetricSeries
    @Binding public var cursorSourceIndex: Int
    public let onCursorChange: (Int) -> Void
    public let showsLegend: Bool

    private let builder = SeriesBuilder()

    public init(
        series: MetricSeries,
        cursorSourceIndex: Binding<Int>,
        onCursorChange: @escaping (Int) -> Void,
        showsLegend: Bool = true
    ) {
        self.series = series
        self._cursorSourceIndex = cursorSourceIndex
        self.onCursorChange = onCursorChange
        self.showsLegend = showsLegend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if showsLegend {
                ChartLegend(series: series)
            }
            let groups = ChartSegmenter.groups(series.points)
            let curveColor = AppTheme.Colors.curve(series.kind, scheme: colorScheme)
            let scaleDomain: [String] = groups.isEmpty ? ["分段 1"] : groups.map(\.seriesName)
            let scaleRange: [Color] = Array(repeating: curveColor, count: max(1, groups.count))
            Chart {
                ForEach(groups) { group in
                    ForEach(group.points.indices, id: \.self) { index in
                        let point = group.points[index]
                        if series.kind == .altitude {
                            AreaMark(
                                x: .value(series.axis.axisLabel, point.x),
                                y: .value(series.kind.localizedDescription, point.y)
                            )
                            .foregroundStyle(by: .value("分段", group.seriesName))
                            .opacity(0.3)
                            LineMark(
                                x: .value(series.axis.axisLabel, point.x),
                                y: .value(series.kind.localizedDescription, point.y)
                            )
                            .foregroundStyle(by: .value("分段", group.seriesName))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        } else {
                            LineMark(
                                x: .value(series.axis.axisLabel, point.x),
                                y: .value(series.kind.localizedDescription, point.y)
                            )
                            .foregroundStyle(by: .value("分段", group.seriesName))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .symbolSize(series.tier == .full ? CGFloat(12) : CGFloat(0))
                        }
                    }
                }
                if let cursorX = cursorXValue {
                    RuleMark(x: .value(series.axis.axisLabel, cursorX))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center) {
                            Text(cursorText)
                                .font(.caption2)
                                .padding(4)
                                .background(AppTheme.Colors.cardStroke(colorScheme).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
            // 所有分组映射到同一曲线色（颜色不是区分来源的手段），
            // 但按 `foregroundStyle(by:)` 拆成独立 series，保证断点两侧绝不连线。
            .chartForegroundStyleScale(domain: scaleDomain, range: scaleRange)
            .chartXAxisLabel(series.axis.axisLabel)
            .chartYAxisLabel("\(series.kind.localizedDescription)（\(series.kind.unitText)）")
            .chartLegend(.hidden)
            .chartOverlay { _ in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard !series.points.isEmpty else { return }
                                    let width = max(1, geometry.size.width)
                                    let fraction = min(1, max(0, value.location.x / width))
                                    let index = Int((fraction * Double(series.points.count - 1)).rounded())
                                    let clamped = min(series.points.count - 1, max(0, index))
                                    let sourceIndex = series.points[clamped].sourceIndex
                                    cursorSourceIndex = sourceIndex
                                    onCursorChange(sourceIndex)
                                }
                        )
                }
            }
            .frame(height: 170)
            .accessibilityLabel(Text("\(series.legendText)曲线"))
            .accessibilityHint(Text(AccessibilityLabels.chartCursor))
            .accessibilityValue(Text(series.numericSummary))

            Text(series.numericSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if series.breakCount > 0 {
                Text("跨段不连线：\(series.breakCount) 处断点（信号中断 / 暂停段）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var cursorXValue: Double? {
        guard let index = builder.linkedCursorIndex(forSourceIndex: cursorSourceIndex, in: series) else {
            return nil
        }
        return series.points[index].x
    }

    private var cursorText: String {
        guard let x = cursorXValue else { return "无数据" }
        return series.axis == .time
            ? Units.formatDuration(x)
            : Units.formatDistanceKm(x)
    }
}

// MARK: - 双通道文字图例（F50 / §B.11.1）

/// 文字 + 图标 + VoiceOver 三通道；颜色不是唯一区分手段。
/// 如需对比两个来源，必须显式并排两个 `ChartLegend` + 两个 Chart，禁止无标记混画。
public struct ChartLegend: View {
    public let series: MetricSeries

    public init(series: MetricSeries) {
        self.series = series
    }

    public var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            OriginBadge(series.origin, style: .compact)
            VStack(alignment: .leading, spacing: 2) {
                Text(series.legendText)
                    .font(.caption.weight(.semibold))
                Text("轴：\(series.axis.localizedDescription)｜档位：\(series.tier.localizedDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Image(systemName: series.kind == .altitude ? "mountain.2" : "chart.xyaxis.line")
                .foregroundStyle(AppTheme.Colors.curve(series.kind, scheme: .light))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(series.origin.accessibilityLabel)，\(series.legendText)"))
    }
}

// MARK: - 联动游标（F50）

/// 四条曲线共享同一个 `cursorSourceIndex`；拖动滑块或任一曲线，其余曲线 / 地图 / 数值卡片同步。
public struct LinkedCursor: View {
    @Binding public var cursorSourceIndex: Int
    public let pointCount: Int
    public let summaryText: String
    public let onSeek: ((Int) -> Void)?

    public init(
        cursorSourceIndex: Binding<Int>,
        pointCount: Int,
        summaryText: String,
        onSeek: ((Int) -> Void)? = nil
    ) {
        self._cursorSourceIndex = cursorSourceIndex
        self.pointCount = pointCount
        self.summaryText = summaryText
        self.onSeek = onSeek
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text("联动游标")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Text("\(min(max(0, cursorSourceIndex), max(0, pointCount - 1)) + 1) / \(pointCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(cursorSourceIndex) },
                    set: { newValue in
                        let index = Int(newValue.rounded())
                        cursorSourceIndex = min(max(0, pointCount - 1), max(0, index))
                        onSeek?(cursorSourceIndex)
                    }
                ),
                in: 0...Double(max(1, pointCount - 1)),
                step: 1
            )
            .accessibilityLabel(AccessibilityLabels.chartCursor)
            Text(summaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }
}

// MARK: - 海拔剖面图（F50 / §B.6.2）

/// 由 `ElevationProfile.altitude(atArcLength:)` 真实采样；拖动选中弧长并联动地图位置。
public struct ElevationProfileChart: View {
    @Environment(\.colorScheme) private var colorScheme

    public let profile: ElevationProfile
    public let totalLengthM: Double
    @Binding public var selectedArcLengthM: Double
    public let onSelectArcLength: (Double) -> Void

    public init(
        profile: ElevationProfile,
        totalLengthM: Double,
        selectedArcLengthM: Binding<Double>,
        onSelectArcLength: @escaping (Double) -> Void
    ) {
        self.profile = profile
        self.totalLengthM = totalLengthM
        self._selectedArcLengthM = selectedArcLengthM
        self.onSelectArcLength = onSelectArcLength
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("海拔剖面")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 2)
                Text(profile.source.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(samples.indices, id: \.self) { index in
                    let sample = samples[index]
                    AreaMark(
                        x: .value("弧长（m）", sample.arcLength),
                        y: .value("海拔（m）", sample.altitude)
                    )
                    .foregroundStyle(AppTheme.Colors.curve(.altitude, scheme: colorScheme).opacity(0.3))
                    LineMark(
                        x: .value("弧长（m）", sample.arcLength),
                        y: .value("海拔（m）", sample.altitude)
                    )
                    .foregroundStyle(AppTheme.Colors.curve(.altitude, scheme: colorScheme))
                }
                RuleMark(x: .value("弧长（m）", min(max(0, selectedArcLengthM), length)))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .chartXAxisLabel("弧长（m）")
            .chartYAxisLabel("海拔（m）")
            .chartLegend(.hidden)
            .frame(height: 150)
            .chartOverlay { _ in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let width = max(1, geometry.size.width)
                                    let fraction = min(1, max(0, value.location.x / width))
                                    let arc = length * fraction
                                    selectedArcLengthM = arc
                                    onSelectArcLength(arc)
                                }
                        )
                }
            }
            .accessibilityLabel(Text("海拔剖面图，来源 \(profile.source.localizedDescription)"))
            Stepper(value: $selectedArcLengthM, in: 0...max(1, length), step: max(1, length / 40)) {
                Text("选中弧长 \(AppTheme.metricNumberFormat(selectedArcLengthM, unit: "m", digits: 0))")
                    .font(.caption2)
            }
            .onChange(of: selectedArcLengthM) { _, newValue in
                onSelectArcLength(newValue)
            }
            Text("初始海拔 \(AppTheme.metricNumberFormat(profile.initialAltitudeM, unit: "m"))｜剖面段 \(profile.segments.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var length: Double {
        max(1, totalLengthM.isFinite ? totalLengthM : profile.coveredLengthM)
    }

    private struct Sample {
        let arcLength: Double
        let altitude: Double
    }

    /// 确定性采样：64 个等弧长点，全部由冻结的 `ElevationProfile.altitude(atArcLength:)` 计算，不臆造。
    private var samples: [Sample] {
        let count = 64
        return (0...count).map { index in
            let arc = length * Double(index) / Double(count)
            return Sample(arcLength: arc, altitude: profile.altitude(atArcLength: arc))
        }
    }
}
