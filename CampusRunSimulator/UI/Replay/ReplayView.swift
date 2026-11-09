import Foundation
import SwiftUI
import MapKit

// MARK: - 回放页面级视图（F51 / §B.6.6 / §4.3）

/// 跨页复用的第 8 个 View（非导航顶层页）：地图动态轨迹 + 实时数值 + 四类曲线 + 常驻来源徽标。
/// 播放 / 暂停 / 继续 / 快进 / 倍速 0.5×–8× / 拖动定位全部绑定 `ReplayController` 的真实时间轴。
/// **不重定义 `PlaybackRate`**，直接使用 BATCH_1 `RunSession.swift` 冻结的枚举。
@MainActor
public struct ReplayView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var controller: ReplayController
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var cursorSourceIndex: Int = 0
    @State private var axis: ChartAxis = .time
    @State private var tier: DownsamplingTier = .medium
    @State private var loadError: String? = nil
    @State private var isLoading: Bool = true

    public let sessionId: String
    public let previewPoints: [TrackPoint]?
    public let previewOrigin: DataOrigin
    public let startElapsed: TimeInterval

    public init(
        sessionId: String,
        previewPoints: [TrackPoint]? = nil,
        previewOrigin: DataOrigin = .simulated,
        startElapsed: TimeInterval = 0,
        stores: PersistentStores? = nil
    ) {
        self.sessionId = sessionId
        self.previewPoints = previewPoints
        self.previewOrigin = previewOrigin
        self.startElapsed = startElapsed
        _controller = StateObject(
            wrappedValue: ReplayController(repository: stores.map { DefaultRunRepository(stores: $0) }
                ?? AppServices.shared.repository)
        )
    }

    /// 无参构造（便于预览 / 复用）；真实使用请传入 `sessionId`。
    public init() {
        self.init(sessionId: "")
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                if isLoading {
                    ProgressView("正在读取采样点…")
                        .frame(maxWidth: .infinity)
                } else if let loadError {
                    ErrorStateView(
                        origin: controller.state.dataOrigin,
                        error: AppError.parameterConflict(reason: loadError),
                        primaryTitle: "重新读取",
                        primaryAction: { Task { await load() } },
                        secondaryTitle: "关闭回放",
                        secondaryAction: { controller.pause() }
                    )
                } else {
                    metricsGrid
                    mapSection
                    chartsSection
                }
                ReplayControls(controller: controller)
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle("轨迹回放")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .onChange(of: systemReduceMotion) { _, newValue in
            controller.reduceMotion = newValue || AppSettingsStore.shared.settings.reduceMotion
        }
        .onAppear {
            controller.reduceMotion = systemReduceMotion || AppSettingsStore.shared.settings.reduceMotion
        }
        .onDisappear {
            controller.pause()
        }
        .onChange(of: controller.state.currentElapsedSeconds) { _, _ in
            cursorSourceIndex = controller.currentSourceIndex()
        }
    }

    // MARK: 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                OriginBadge(controller.state.dataOrigin, style: .full)
                Spacer(minLength: 2)
                Text("记录 \(sessionId)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.secondary)
            }
            Text("本页数据与曲线均继承原始记录来源，测试数据与真实记录物理隔离")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var metricsGrid: some View {
        let frame = controller.currentFrame
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                         spacing: AppTheme.Spacing.md) {
            MetricCard(
                title: "已用时间",
                value: Units.formatDuration(controller.state.currentElapsedSeconds),
                origin: controller.state.dataOrigin
            )
            MetricCard(
                title: "累计距离",
                value: Units.formatDistanceKm(frame?.cumulativeDistanceM ?? 0),
                origin: controller.state.dataOrigin
            )
            MetricCard(
                title: "实时配速",
                value: Units.formatPaceMinPerKm(frame?.instantPaceSecPerKm ?? 0),
                detail: "平均 \(Units.formatPaceMinPerKm(frame?.avgPaceSecPerKm ?? 0))",
                origin: controller.state.dataOrigin
            )
            MetricCard(
                title: "步频 / 步幅",
                value: AppTheme.metricNumberFormat(frame?.cadenceSpm ?? 0, digits: 0),
                unit: "spm",
                detail: "步幅 \(AppTheme.metricNumberFormat(frame?.strideLengthM ?? 0, unit: "m"))",
                origin: controller.state.dataOrigin
            )
            MetricCard(
                title: "海拔 / 爬升",
                value: AppTheme.metricNumberFormat(frame?.altitudeM ?? 0, unit: "m", digits: 1),
                detail: "累计爬升 \(AppTheme.metricNumberFormat(frame?.elevationGainSoFarM ?? 0, unit: "m", digits: 1))",
                origin: controller.state.dataOrigin
            )
            MetricCard(
                title: "倍速",
                value: controller.state.playbackRate.label,
                detail: controller.state.isPlaying ? "正在播放" : "已暂停",
                origin: controller.state.dataOrigin
            )
        }
    }

    private var mapSection: some View {
        let all = controller.points.map(\.geoPoint)
        let progress = controller.durationSeconds > 0
            ? controller.state.currentElapsedSeconds / controller.durationSeconds
            : 0
        let annotations: [RouteMapAnnotation] = controller.currentFrame.map {
            [RouteMapAnnotation(
                id: "replay_head",
                label: "当前位置",
                coordinate: $0.geoPoint,
                symbolName: "figure.run.circle.fill"
            )]
        } ?? []
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("动态轨迹（绘制到当前时间戳）")
                .font(.caption.weight(.semibold))
            RouteMapView(
                points: all,
                cameraPosition: $cameraPosition,
                annotations: annotations,
                progress: progress
            )
            .animation(controller.reduceMotion ? nil : .linear(duration: 0.05), value: progress)
            Text("跨段不连线：\(controller.points.filter { $0.hasGap || $0.isPaused }.count) 处中断 / 暂停标记")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var chartsSection: some View {
        let series = AppServices.shared.seriesBuilder.build(controller.points, axis: axis, downsampling: tier)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("四类曲线")
                    .font(.headline)
                Spacer(minLength: 2)
                Picker("轴", selection: $axis) {
                    ForEach(ChartAxis.allCases, id: \.self) { item in
                        Text(item.localizedDescription).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Picker("降采样", selection: $tier) {
                    ForEach(DownsamplingTier.allCases, id: \.self) { item in
                        Text(item.localizedDescription).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }
            LinkedCursor(
                cursorSourceIndex: $cursorSourceIndex,
                pointCount: controller.points.count,
                summaryText: AppTheme.cursorSummary(
                    index: cursorSourceIndex,
                    elapsed: controller.points[safe: cursorSourceIndex]?.elapsedSeconds ?? 0,
                    distance: controller.points[safe: cursorSourceIndex]?.cumulativeDistanceM ?? 0
                ),
                onSeek: { index in
                    if let point = controller.points[safe: index] {
                        controller.seek(to: point.elapsedSeconds)
                    }
                }
            )
            ForEach(series) { item in
                SeriesChartView(
                    series: item,
                    cursorSourceIndex: $cursorSourceIndex,
                    onCursorChange: { sourceIndex in
                        if let point = controller.points[safe: sourceIndex] {
                            controller.seek(to: point.elapsedSeconds)
                        }
                    }
                )
            }
        }
    }

    private var footer: some View {
        Text(controller.state.dataOrigin == .simulated
             ? AppConstants.simulationFooter
             : AppConstants.realPageNotice)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 真实读取

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        do {
            if let previewPoints {
                controller.loadPreview(previewPoints, sessionId: sessionId, origin: previewOrigin)
            } else {
                try await controller.load(sessionId: sessionId)
            }
            if startElapsed > 0 {
                controller.seek(to: startElapsed)
            }
            cursorSourceIndex = controller.currentSourceIndex()
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - 回放控件（F51，全部真实生效）

/// 播放 / 暂停 / 继续 / 快进 / 倍速 0.5×–8× / 拖动定位，全部直接调用 `ReplayController`。
public struct ReplayControls: View {
    @ObservedObject public var controller: ReplayController

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(controller: ReplayController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if controller.state.isPlaying {
                    Button {
                        controller.pause()
                    } label: {
                        Label("暂停", systemImage: "pause.circle.fill")
                    }
                    .accessibilityLabel(AccessibilityLabels.pause)
                } else {
                    Button {
                        controller.resume()
                    } label: {
                        Label("继续", systemImage: "play.circle.fill")
                    }
                    .accessibilityLabel(AccessibilityLabels.resume)
                }
                Button {
                    controller.play()
                } label: {
                    Label("重新播放", systemImage: "arrow.counterclockwise.circle")
                }
                .accessibilityLabel(AccessibilityLabels.play)
                Button {
                    controller.fastForward(seconds: 10)
                } label: {
                    Label("快进", systemImage: "goforward.10")
                }
                .accessibilityLabel(AccessibilityLabels.fastForward)
                Button {
                    controller.rewind(seconds: 10)
                } label: {
                    Label("后退", systemImage: "gobackward.10")
                }
                .accessibilityLabel("后退 10 秒")
                Spacer(minLength: 2)
                Picker("倍速", selection: Binding(
                    get: { controller.state.playbackRate },
                    set: { controller.setRate($0) }
                )) {
                    ForEach(PlaybackRate.allCases, id: \.self) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel(AccessibilityLabels.playbackRate)
            }
            .buttonStyle(.bordered)
            .font(.caption)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Slider(
                    value: Binding(
                        get: { controller.state.currentElapsedSeconds },
                        set: { controller.seek(to: $0) }
                    ),
                    in: 0...max(1, controller.durationSeconds)
                ) {
                    Text("回放进度")
                } minimumValueLabel: {
                    Text("0:00").font(.caption2.monospacedDigit())
                } maximumValueLabel: {
                    Text(Units.formatDuration(controller.durationSeconds)).font(.caption2.monospacedDigit())
                }
                .accessibilityLabel(AccessibilityLabels.seek)
                Text("当前 \(Units.formatDuration(controller.state.currentElapsedSeconds)) / 总时长 \(Units.formatDuration(controller.durationSeconds))｜\(controller.state.playbackRate.label)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if systemReduceMotion || controller.reduceMotion {
                Text("已启用减少动态效果：回放以离散整秒帧呈现，所有控件仍可操作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }
}

// MARK: - 安全下标（仅本文件使用）

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
