import Foundation
import SwiftUI
import Observation
import MapKit

// MARK: - 实时运动记录状态（仅本页使用）

/// 真实记录生命周期：未开始 / 进行中 / 已暂停 / 已结束。
public enum LiveRunPhase: String, Sendable, CaseIterable {
    case idle
    case running
    case paused
    case finished

    public var localizedDescription: String {
        switch self {
        case .idle: return "未开始"
        case .running: return "正在记录"
        case .paused: return "已暂停"
        case .finished: return "已结束"
        }
    }
}

// MARK: - 真实记录视图模型（F56 / §B.6.4）

/// 全部动作调 F35 `LiveRunRecorder` / F32 `CoreLocationProvider` / F33 `CoreMotionProvider` / F34 健康服务。
/// **不构造任何虚拟定位、不读取任何 SIMULATED 数据、不提供仿真入口**。
@MainActor
@Observable
public final class LiveRunViewModel {

    public var note: String = ""
    public var writeToHealthKit: Bool = false
    public var selectedReferenceRouteId: String? = nil

    public private(set) var phase: LiveRunPhase = .idle
    public private(set) var points: [TrackPoint] = []
    public private(set) var permissionSummary: String = "正在自检权限…"
    public private(set) var motionSummary: String = ""
    public private(set) var healthSummary: String = ""
    public private(set) var canStart: Bool = false
    public private(set) var referenceRoutes: [Route] = []
    public private(set) var qualityText: String = "尚无数据"
    public private(set) var gapNotice: String? = nil
    public private(set) var finishedSession: RunSession? = nil
    public private(set) var errorMessage: String? = nil
    public private(set) var lastActionMessage: String = "尚未开始记录"
    public private(set) var isBusy: Bool = false

    private var recorder: LiveRunRecorder? = nil
    private var locationProvider: CoreLocationProvider? = nil
    private var motionProvider: CoreMotionProvider? = nil
    private var refreshTimer: Timer? = nil
    private let healthKitService = DefaultHealthKitService()

    public init() {}

    // MARK: 实时派生量（全部来自真实传感器采样点）

    public var elapsedSeconds: TimeInterval { points.last?.elapsedSeconds ?? 0 }
    public var distanceM: Double { points.last?.cumulativeDistanceM ?? 0 }
    public var instantPaceSecPerKm: Double { points.last?.instantPaceSecPerKm ?? 0 }
    public var avgPaceSecPerKm: Double { points.last?.avgPaceSecPerKm ?? 0 }
    public var speedMps: Double { points.last?.speedMps ?? 0 }
    public var cadenceSpm: Double { points.last?.cadenceSpm ?? 0 }
    public var altitudeM: Double { points.last?.altitudeM ?? 0 }
    public var elevationGainM: Double { points.last?.elevationGainSoFarM ?? 0 }
    public var elevationLossM: Double { points.last?.elevationLossSoFarM ?? 0 }
    public var horizontalAccuracyM: Double { points.last?.horizontalAccuracyM ?? -1 }
    public var mapPoints: [GeoPoint] { points.map(\.geoPoint) }

    public var headAnnotation: [RouteMapAnnotation] {
        guard let last = points.last else { return [] }
        return [RouteMapAnnotation(
            id: "live_head",
            label: "当前位置",
            coordinate: last.geoPoint,
            symbolName: "figure.run.circle.fill"
        )]
    }

    // MARK: 权限自检

    /// 开始前自检：定位 / 精确位置 / 运动传感器 / 健康数据写入，缺失项逐一说明。
    public func checkPermissions() async {
        let location = CoreLocationProvider()
        let motion = CoreMotionProvider()
        let locationSnapshot = location.authorizationSnapshot
        let motionAvailability = motion.availability()
        let healthSnapshot = await healthKitService.readStatus()

        canStart = locationSnapshot.canStartLiveRun
        permissionSummary = locationSnapshot.summary
        motionSummary = motionAvailability.summary
        healthSummary = healthSnapshot.summary
        referenceRoutes = AppServices.shared.loadRoutes().sorted { $0.updatedAt > $1.updatedAt }

        let merged = PermissionSnapshot(
            locationStatus: locationSnapshot.locationStatus,
            preciseLocationEnabled: locationSnapshot.preciseLocationEnabled,
            motionStatus: motionAvailability.pedometerAvailable ? .authorizedWhenInUse : .unknown,
            healthKitReadStatus: healthSnapshot.healthKitReadStatus,
            healthKitShareStatus: healthSnapshot.healthKitShareStatus,
            backgroundDeliveryAvailable: healthSnapshot.backgroundDeliveryAvailable,
            capturedAt: Date(),
            note: "真实记录页权限自检；健康读取不可判定按「无数据」呈现"
        )
        try? AppServices.shared.savePermissionState(PermissionState.from(snapshot: merged))
        if !canStart {
            lastActionMessage = "定位未授权，请先在下方请求授权或前往系统设置"
        } else {
            lastActionMessage = "权限自检完成，可以开始真实记录"
        }
    }

    /// 调起真实定位授权（F32 官方 API）。
    public func requestLocationAuthorization() {
        let provider = CoreLocationProvider()
        provider.requestAuthorization()
        lastActionMessage = "已发出定位授权请求，请在系统弹窗中确认"
        Task { await checkPermissions() }
    }

    /// 单独申请健康数据写入授权；仿真流程不会调用本方法。
    public func requestHealthKitAuthorization() async {
        do {
            try await healthKitService.requestShareAuthorization()
            lastActionMessage = "健康数据写入授权请求已处理"
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "健康写入授权未完成：\(error.localizedDescription)"
        }
        await checkPermissions()
    }

    public func openSystemSettings() {
        AppServices.shared.openSystemSettings()
    }

    public func selectReferenceRoute(_ route: Route) {
        selectedReferenceRouteId = route.id
        lastActionMessage = "参考路线已设为「\(route.name)」，不影响真实轨迹"
    }

    // MARK: 生命周期动作

    /// 开始：重建真实传感器提供者与 F35 编排器，失败直接透传 `AppError`。
    public func start() async {
        guard phase == .idle || phase == .finished else {
            errorMessage = "已有进行中的真实记录"
            return
        }
        guard canStart else {
            errorMessage = AppError.locationNotAuthorized.errorDescription
            return
        }
        isBusy = true
        errorMessage = nil
        let location = CoreLocationProvider()
        let motion = CoreMotionProvider(initialAltitudeM: altitudeM)
        let reference = referenceRoutes.first { $0.id == selectedReferenceRouteId }
        let newRecorder = LiveRunRecorder(
            locationProvider: location,
            motionProvider: motion,
            gapStream: location.gaps,
            healthKitService: healthKitService,
            repository: AppServices.shared.repository
        )
        locationProvider = location
        motionProvider = motion
        recorder = newRecorder
        do {
            try await newRecorder.start(referenceRoute: reference)
            phase = .running
            points = []
            gapNotice = nil
            finishedSession = nil
            note = ""
            writeToHealthKit = false
            qualityText = "正在采集真实传感器数据…"
            lastActionMessage = "真实记录已开始（REAL 分区）"
            startRefreshTimer()
            isBusy = false
        } catch {
            recorder = nil
            locationProvider = nil
            motionProvider = nil
            phase = .idle
            errorMessage = error.localizedDescription
            lastActionMessage = "无法开始真实记录：\(error.localizedDescription)"
            isBusy = false
        }
    }

    public func pause() async {
        guard phase == .running, let recorder else { return }
        await recorder.pause()
        phase = .paused
        stopRefreshTimer()
        lastActionMessage = "已暂停：暂停段不计距、不计时"
    }

    public func resume() async {
        guard phase == .paused, let recorder else { return }
        await recorder.resume()
        phase = .running
        startRefreshTimer()
        lastActionMessage = "已继续：恢复后新建分段，跨段不连线"
    }

    /// 结束并落盘；HealthKit 写入**仅在用户显式勾选后**执行（默认关闭）。
    public func finish() async {
        guard let recorder else {
            errorMessage = "当前没有进行中的真实记录"
            return
        }
        isBusy = true
        do {
            let session = try await recorder.finish(
                note: note,
                writeToHealthKit: writeToHealthKit
            )
            finishedSession = session
            phase = .finished
            stopRefreshTimer()
            self.recorder = nil
            locationProvider = nil
            motionProvider = nil
            lastActionMessage = writeToHealthKit
                ? "已保存真实记录，并按勾选写入健康 App"
                : "已保存真实记录（未写入健康 App）"
            await refresh()
            isBusy = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "结束记录失败：\(error.localizedDescription)"
            isBusy = false
        }
    }

    /// 用户主动放弃：不调用 `finish`，不落盘，直接停止传感器并丢弃内存数据。
    public func discard() {
        stopRefreshTimer()
        locationProvider?.stop()
        motionProvider?.stop()
        recorder = nil
        locationProvider = nil
        motionProvider = nil
        points = []
        finishedSession = nil
        phase = .idle
        note = ""
        writeToHealthKit = false
        gapNotice = nil
        qualityText = "尚无数据"
        errorMessage = nil
        lastActionMessage = "已放弃本次记录，未写入任何数据"
    }

    /// 定时从 F35 拉取真实采样点、质量报告与运动可用性说明。
    public func refresh() async {
        guard let recorder else { return }
        let current = await recorder.currentPoints()
        points = current
        let report = await recorder.qualityReport()
        qualityText = report.summary
        let note = await recorder.motionAvailabilityNote()
        if !note.isEmpty {
            motionSummary = note
            gapNotice = note
        } else if report.gapSegmentCount > 1 || report.lowAccuracyCount > 0 {
            gapNotice = "检测到 \(max(0, report.gapSegmentCount - 1)) 处信号中断 / \(report.lowAccuracyCount) 个低精度点；已分段不连线、未插值"
        } else {
            gapNotice = nil
        }
    }

    public func openAnalytics() {
        AppNavigation.shared.openAnalytics(sessionId: finishedSession?.id)
    }

    public func openHistory() {
        AppNavigation.shared.openHistory()
    }

    public func openSettings() {
        AppNavigation.shared.openSettings()
    }

    /// 导出刚结束的真实记录（单一来源 + 三重标记）。
    public func export(format: ExportFormat) async throws -> URL {
        guard let session = finishedSession else {
            throw AppError.parameterConflict(reason: "请先结束一次真实记录再导出")
        }
        let points = (try? await AppServices.shared.repository?.points(sessionId: session.id)) ?? []
        let file = try await AppServices.shared.exporter.export(
            session: session,
            points: points,
            format: format
        )
        return try file.writeToTemporaryDirectory()
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
        lastActionMessage = "操作未完成：\(error.localizedDescription)"
    }

    // MARK: 私有：刷新定时器

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - 实时运动页（F56）

/// 页面常驻「真实记录」，与模拟器页视觉明确区分；无虚拟定位入口、无 SIMULATED→HealthKit 路径。
@MainActor
public struct LiveRunView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var vm = LiveRunViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showFinishConfirm: Bool = false
    @State private var showDiscardConfirm: Bool = false
    @State private var exportFormat: ExportFormat = .gpx
    @State private var shareURL: URL? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                complianceHeader
                permissionSection
                gapSection
                metricsSection
                mapSection
                referenceRouteSection
                controlSection
                finishSection
                errorSection
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle(AppRoute.liveRun.title)
        .task { await vm.checkPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: .campusRunWillEnterForeground)) { _ in
            Task { await vm.checkPermissions() }
        }
        .confirmationDialog("结束本次真实记录", isPresented: $showFinishConfirm) {
            Button("结束并保存") { Task { await vm.finish() } }
            Button("取消", role: .cancel) { showFinishConfirm = false }
        } message: {
            Text("结束后写入 REAL 分区。健康 App 写入仅在您勾选时执行。")
        }
        .confirmationDialog("放弃本次记录", isPresented: $showDiscardConfirm) {
            Button("放弃且不保存", role: .destructive) { vm.discard() }
            Button("继续记录", role: .cancel) { showDiscardConfirm = false }
        } message: {
            Text("放弃后本次已采集的采样点不会写入任何存储域。")
        }
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

    private var complianceHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                OriginBadge(.real, style: .full)
                Spacer(minLength: 2)
                Text(vm.phase.localizedDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
            }
            Text(AppConstants.realPageNotice)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(vm.lastActionMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("本页不使用任何虚拟定位，也不提供仿真入口；测试数据永不写入健康 App")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("开始前权限自检")
                .font(.headline)
            Text(vm.permissionSummary)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            if !vm.motionSummary.isEmpty {
                Text(vm.motionSummary)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !vm.healthSummary.isEmpty {
                Text(vm.healthSummary)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "请求定位授权", symbol: "location", style: .bordered) {
                    vm.requestLocationAuthorization()
                }
                ActionButton(title: "健康写入授权", symbol: "heart", style: .bordered) {
                    Task { await vm.requestHealthKitAuthorization() }
                }
                ActionButton(title: "系统设置", symbol: "gearshape", style: .bordered) {
                    vm.openSystemSettings()
                }
            }
            ActionButton(title: "重新自检", symbol: "arrow.clockwise", style: .bordered) {
                Task { await vm.checkPermissions() }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    @ViewBuilder
    private var gapSection: some View {
        if let notice = vm.gapNotice {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("中断 / 漂移提示")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 2)
                }
                Text(notice)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("中断段单独分段，跨段不连线、不计距、不插值；数据质量报告见下方")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(AppTheme.Spacing.md)
            .glassCard(role: .controlBar, interactive: false)
        }
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("实时数值（来自设备传感器）")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                spacing: AppTheme.Spacing.md
            ) {
                MetricCard(title: "已用时长", value: Units.formatDuration(vm.elapsedSeconds), origin: .real)
                MetricCard(title: "累计距离", value: Units.formatDistanceKm(vm.distanceM), origin: .real)
                MetricCard(title: "实时配速", value: Units.formatPaceMinPerKm(vm.instantPaceSecPerKm),
                           detail: "平均 \(Units.formatPaceMinPerKm(vm.avgPaceSecPerKm))", origin: .real)
                MetricCard(title: "速度", value: AppTheme.metricNumberFormat(vm.speedMps, unit: "m/s", digits: 2),
                           origin: .real)
                MetricCard(title: "步频", value: AppTheme.metricNumberFormat(vm.cadenceSpm, unit: "spm", digits: 0),
                           detail: "不可用字段按「不可用」处理", origin: .real)
                MetricCard(title: "海拔", value: AppTheme.metricNumberFormat(vm.altitudeM, unit: "m", digits: 1),
                           detail: "爬升 \(AppTheme.metricNumberFormat(vm.elevationGainM, unit: "m", digits: 1)) / "
                                + "下降 \(AppTheme.metricNumberFormat(vm.elevationLossM, unit: "m", digits: 1))",
                           origin: .real)
                MetricCard(title: "GPS 水平精度",
                           value: vm.horizontalAccuracyM >= 0
                               ? AppTheme.metricNumberFormat(vm.horizontalAccuracyM, unit: "m", digits: 1)
                               : "不可用",
                           detail: "> 50 m 的点被丢弃，不臆造坐标", origin: .real)
            }
            Text(vm.qualityText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("实时轨迹（真实 GPS）")
                .font(.caption.weight(.semibold))
            RouteMapView(
                points: vm.mapPoints,
                cameraPosition: $cameraPosition,
                annotations: vm.headAnnotation,
                progress: 1
            )
            Text("点位不足或精度超限时不会补点；跨段不连线")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var referenceRouteSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("参考路线（仅作背景，不改变真实轨迹）")
                .font(.headline)
            if vm.referenceRoutes.isEmpty {
                Text("暂无已保存路线；可继续直接记录，或前往路线规划页创建")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("参考路线", selection: Binding(
                    get: { vm.selectedReferenceRouteId ?? "" },
                    set: { newValue in
                        if let route = vm.referenceRoutes.first(where: { $0.id == newValue }) {
                            vm.selectReferenceRoute(route)
                        }
                    }
                )) {
                    Text("不使用参考路线").tag("")
                    ForEach(vm.referenceRoutes) { route in
                        Text(route.name).tag(route.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("记录控制")
                .font(.headline)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(
                    title: "开始",
                    symbol: "record.circle",
                    style: .prominent,
                    isDisabled: !vm.canStart || vm.phase == .running || vm.phase == .paused || vm.isBusy
                ) { Task { await vm.start() } }
                ActionButton(
                    title: "暂停",
                    symbol: "pause.circle",
                    isDisabled: vm.phase != .running
                ) { Task { await vm.pause() } }
                ActionButton(
                    title: "继续",
                    symbol: "play.circle",
                    isDisabled: vm.phase != .paused
                ) { Task { await vm.resume() } }
                ActionButton(
                    title: "结束",
                    symbol: "stop.circle",
                    style: .destructive,
                    isDisabled: vm.phase != .running && vm.phase != .paused
                ) { showFinishConfirm = true }
            }
            if !vm.canStart {
                Text("定位未授权时「开始」保持禁用：请先请求授权，这是真实原因而非占位")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ActionButton(
                title: "放弃本次记录（不落盘）",
                symbol: "xmark.circle",
                style: .bordered,
                isDisabled: vm.phase != .running && vm.phase != .paused
            ) { showDiscardConfirm = true }
            if vm.isBusy { ProgressView("正在写入 REAL 分区…").font(.caption) }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    private var finishSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("结束与导出")
                .font(.headline)
            TextField("本次记录备注（可选）", text: $vm.note)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("真实记录备注输入框")
            Toggle(isOn: $vm.writeToHealthKit) {
                Text("写入健康 App（默认关闭，需逐次显式勾选）")
                    .font(.caption)
            }
            .accessibilityLabel("是否把真实记录写入健康 App，默认关闭")
            if vm.writeToHealthKit {
                Text("仅当前这条 REAL 记录会被写入；测试数据 / SIMULATED 永不写入健康 App")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let session = vm.finishedSession {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已保存：\(Units.formatDistanceKm(session.totalDistanceMeters))｜\(Units.formatDuration(session.durationSeconds))")
                        .font(.caption.weight(.medium))
                    Text("记录 ID：\(session.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Picker("导出格式", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.localizedDescription).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: AppTheme.Spacing.sm) {
                    ActionButton(title: "导出记录", symbol: "square.and.arrow.up") {
                        Task {
                            do { shareURL = try await vm.export(format: exportFormat) }
                            catch { vm.reportError(error) }
                        }
                    }
                    ActionButton(title: "数据分析", symbol: "chart.xyaxis.line") { vm.openAnalytics() }
                    ActionButton(title: "历史记录", symbol: "clock.arrow.circlepath") { vm.openHistory() }
                }
            } else {
                Text("结束一次真实记录后，可在此导出带 REAL 三重标记的本地文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ActionButton(title: "权限与默认设置", symbol: "gearshape", style: .bordered) {
                vm.openSettings()
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = vm.errorMessage {
            ErrorStateView(
                origin: .real,
                error: AppError.locationNotAuthorized,
                primaryTitle: "重新自检",
                primaryAction: { Task { await vm.checkPermissions() } },
                secondaryTitle: "前往系统设置",
                secondaryAction: { vm.openSystemSettings() }
            )
            .overlay(alignment: .bottomTrailing) {
                Text(message).font(.caption2).foregroundStyle(.secondary).padding(4)
            }
        }
    }

    private var footer: some View {
        Text("此页数据来自设备传感器，与测试数据物理隔离；定位失败时绝不臆造坐标，健康写入失败明确提示且不静默重试")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
