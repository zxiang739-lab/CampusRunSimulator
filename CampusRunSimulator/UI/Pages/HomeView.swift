import Foundation
import SwiftUI
import Observation

// MARK: - 首页视图模型（F53 / §B.6.1）

/// 真实记录与测试数据**分别统计**，绝不把两者合并成一个「总里程」冒充成绩。
/// 全部数值来自双域仓库、真实权限快照与真实存储统计，无静态假数据。
@MainActor
@Observable
public final class HomeViewModel {

    public private(set) var allRealSessions: [RunSession] = []
    public private(set) var allSimulatedSessions: [RunSession] = []
    public private(set) var routeCount: Int = 0
    public private(set) var presetCount: Int = 0
    public private(set) var profileCount: Int = 0
    public private(set) var storageText: String = "正在统计…"
    public private(set) var permissionDegraded: Bool = false
    public private(set) var permissionSummary: String = ""
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String? = nil

    /// 真实权限提供者（只读状态，不启动定位更新）。
    private let locationProvider = CoreLocationProvider()

    public init() {}

    /// 最近 3 条真实 / 测试记录（分区展示，不混排）。
    public var recentReal: [RunSession] { Array(allRealSessions.prefix(3)) }
    public var recentSimulated: [RunSession] { Array(allSimulatedSessions.prefix(3)) }

    public var realTotalDistanceM: Double {
        allRealSessions.reduce(0) { $0 + $1.totalDistanceMeters }
    }

    public var simulatedTotalDistanceM: Double {
        allSimulatedSessions.reduce(0) { $0 + $1.totalDistanceMeters }
    }

    public var realTotalDuration: TimeInterval {
        allRealSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    public var simulatedTotalDuration: TimeInterval {
        allSimulatedSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    /// 下拉刷新 / 首次进入：并行读取两个独立容器，任一失败给出明确错误态。
    public func refreshStats() async {
        isLoading = true
        errorMessage = nil
        do {
            guard let repository = AppServices.shared.repository else {
                throw AppError.persistenceMigrationFailed
            }
            async let real = repository.fetch(origin: .real, predicate: RunPredicate())
            async let simulated = repository.fetch(origin: .simulated, predicate: RunPredicate())
            async let routes = repository.routes()
            async let presets = repository.presets()
            async let profiles = repository.profiles()
            let (realList, simulatedList, routeList, presetList, profileList) =
                try await (real, simulated, routes, presets, profiles)

            allRealSessions = realList
            allSimulatedSessions = simulatedList
            routeCount = routeList.count
            presetCount = presetList.count
            profileCount = profileList.count
            storageText = AppServices.shared.storageUsageText()

            let snapshot = locationProvider.authorizationSnapshot
            permissionDegraded = snapshot.hasDegradedPermission
            permissionSummary = snapshot.summary
            try? AppServices.shared.savePermissionState(PermissionState.from(snapshot: snapshot))
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// 四个主入口与菜单入口：通过冻结的跨页导航单例发出真实跳转请求。
    public func open(_ route: AppRoute) {
        AppNavigation.shared.route(to: route)
    }

    /// 最近记录 → 数据分析（携带 sessionId）。
    public func openAnalytics(sessionId: String) {
        AppNavigation.shared.openAnalytics(sessionId: sessionId)
    }

    /// 最近记录 → 历史详情。
    public func openHistory() {
        AppNavigation.shared.openHistory()
    }

    /// 权限异常横幅的真实修复动作。
    public func openSystemSettings() {
        AppServices.shared.openSystemSettings()
    }

    /// 重新自检权限（前台回到应用后调用）。
    public func recheckPermissions() {
        let snapshot = locationProvider.authorizationSnapshot
        permissionDegraded = snapshot.hasDegradedPermission
        permissionSummary = snapshot.summary
        try? AppServices.shared.savePermissionState(PermissionState.from(snapshot: snapshot))
    }
}

// MARK: - 首页总览（F53）

/// 一屏看清「我是谁的数据」：真实 / 模拟分别统计 + 4 主入口 + 最近记录 + 合规声明 + 权限横幅。
/// 所有按钮、卡片、列表项均绑定真实动作，不存在静态占位。
@MainActor
public struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var vm = HomeViewModel()
    @State private var showCompliance: Bool = false
    @State private var replaySessionId: String? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                complianceHeader
                permissionBanner
                errorSection
                entryGrid
                realSection
                simulatedSection
                inventorySection
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle(AppRoute.home.title)
        .refreshable { await vm.refreshStats() }
        .task { await vm.refreshStats() }
        .onReceive(NotificationCenter.default.publisher(for: .campusRunPermissionStateChanged)) { _ in
            vm.recheckPermissions()
        }
        .sheet(isPresented: $showCompliance) { complianceSheet }
        .sheet(isPresented: Binding(
            get: { replaySessionId != nil },
            set: { if !$0 { replaySessionId = nil } }
        )) {
            if let replaySessionId {
                ReplayView(sessionId: replaySessionId)
            }
        }
    }

    // MARK: 区块

    private var complianceHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "checkmark.shield")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(AppConstants.complianceStatement)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                OriginBadge(.simulated, style: .compact)
                OriginBadge(.real, style: .compact)
                Spacer(minLength: 2)
                Button {
                    showCompliance = true
                } label: {
                    Label("合规详情", systemImage: "info.circle")
                        .font(.caption)
                }
                .accessibilityLabel(AccessibilityLabels.complianceDetails)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    @ViewBuilder
    private var permissionBanner: some View {
        if vm.permissionDegraded {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("定位或运动权限受限，真实记录可能不完整")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 2)
                }
                Text(vm.permissionSummary)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: AppTheme.Spacing.sm) {
                    ActionButton(title: "前往系统设置", symbol: "gearshape", style: .prominent) {
                        vm.openSystemSettings()
                    }
                    ActionButton(title: "重新检查", symbol: "arrow.clockwise", style: .bordered) {
                        vm.recheckPermissions()
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .glassCard(role: .controlBar, interactive: true)
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = vm.errorMessage {
            ErrorStateView(
                origin: .simulated,
                error: AppError.persistenceMigrationFailed,
                primaryTitle: "重新加载",
                primaryAction: { Task { await vm.refreshStats() } },
                secondaryTitle: "查看设置",
                secondaryAction: { vm.open(.settings) }
            )
            .overlay(alignment: .bottomTrailing) {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
    }

    /// 四个主入口：每个按钮都发出真实跳转请求，无空 action。
    private var entryGrid: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("快捷入口")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Spacing.md)],
                spacing: AppTheme.Spacing.md
            ) {
                ActionButton(title: "开始真实跑步", symbol: "figure.run", style: .prominent) {
                    vm.open(.liveRun)
                }
                ActionButton(title: "新建仿真", symbol: "testtube.2", style: .bordered) {
                    vm.open(.simulation)
                }
                ActionButton(title: "路线规划", symbol: "map", style: .bordered) {
                    vm.open(.routePlanning)
                }
                ActionButton(title: "历史记录", symbol: "clock.arrow.circlepath", style: .bordered) {
                    vm.open(.history)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .buttonGroup, interactive: true)
    }

    private var realSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                OriginBadge(.real, style: .full)
                Text("真实记录概览")
                    .font(.headline)
                Spacer(minLength: 2)
            }
            if vm.allRealSessions.isEmpty {
                EmptyStateView(
                    origin: .real,
                    title: "还没有真实记录",
                    message: "真实记录只来自设备传感器；测试数据永不写入此分区。请先检查定位权限后开始一次真实跑步。",
                    actionTitle: "开始真实跑步",
                    action: { vm.open(.liveRun) },
                    secondaryTitle: "查看历史",
                    secondaryAction: { vm.openHistory() }
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                    spacing: AppTheme.Spacing.md
                ) {
                    MetricCard(title: "记录数", value: "\(vm.allRealSessions.count)", unit: "条", origin: .real)
                    MetricCard(title: "累计距离", value: Units.formatDistanceKm(vm.realTotalDistanceM),
                               detail: "仅统计真实记录分区", origin: .real)
                    MetricCard(title: "累计时长", value: Units.formatDuration(vm.realTotalDuration),
                               detail: "不含暂停与中断段", origin: .real)
                }
                recentList(vm.recentReal, origin: .real)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var simulatedSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                OriginBadge(.simulated, style: .full)
                Text("模拟研究概览")
                    .font(.headline)
                Spacer(minLength: 2)
            }
            Text("以下均为 App 内生成的测试数据，不代表真实运动，不参与任何成绩统计")
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if vm.allSimulatedSessions.isEmpty {
                EmptyStateView(
                    origin: .simulated,
                    title: "还没有测试数据",
                    message: "在运动模拟器中配置路线与参数，生成一份带 SIMULATED 标记的测试数据集用于本地研究。",
                    actionTitle: "新建仿真",
                    action: { vm.open(.simulation) },
                    secondaryTitle: "规划路线",
                    secondaryAction: { vm.open(.routePlanning) }
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                    spacing: AppTheme.Spacing.md
                ) {
                    MetricCard(title: "数据集", value: "\(vm.allSimulatedSessions.count)", unit: "份", origin: .simulated)
                    MetricCard(title: "累计距离", value: Units.formatDistanceKm(vm.simulatedTotalDistanceM),
                               detail: "仅统计测试数据分区", origin: .simulated)
                    MetricCard(title: "累计时长", value: Units.formatDuration(vm.simulatedTotalDuration),
                               detail: "示例假设配置生成", origin: .simulated)
                }
                recentList(vm.recentSimulated, origin: .simulated)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    /// 最近记录列表：每行提供「分析」与「回放」两个真实动作。
    private func recentList(_ sessions: [RunSession], origin: DataOrigin) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("最近记录（\(origin.displayText)）")
                .font(.caption.weight(.semibold))
            ForEach(sessions) { session in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack {
                        OriginBadge(origin, style: .compact)
                        Text(session.startTime.iso8601UTCString)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                    }
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text(Units.formatDistanceKm(session.totalDistanceMeters))
                        Text(Units.formatDuration(session.durationSeconds))
                        Text(Units.formatPaceMinPerKm(session.avgPaceSecPerKm))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button("数据分析") { vm.openAnalytics(sessionId: session.id) }
                        Button("轨迹回放") { replaySessionId = session.id }
                        Button("历史详情") { vm.openHistory() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                .padding(AppTheme.Spacing.sm)
                .background(AppTheme.Colors.cardStroke(colorScheme).opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("本地资源")
                .font(.headline)
            HStack(spacing: AppTheme.Spacing.md) {
                MetricCard(title: "已保存路线", value: "\(vm.routeCount)", unit: "条")
                MetricCard(title: "假设规则预设", value: "\(vm.presetCount)", unit: "份")
                MetricCard(title: "仿真模板", value: "\(vm.profileCount)", unit: "份")
            }
            HStack {
                Text("存储占用：\(vm.storageText)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                Spacer(minLength: 2)
                Button("刷新") { Task { await vm.refreshStats() } }
                    .font(.caption)
                    .accessibilityLabel(AccessibilityLabels.refresh)
            }
            if vm.isLoading {
                ProgressView("正在读取两个独立存储域…")
                    .font(.caption)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("测试数据与真实记录分别存储于两个独立容器，永不互相转换")
                .font(.caption2)
            Text("本 App 不上传任何数据，不写入第三方平台；测试数据永不写入健康 App")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 合规声明弹层：§0 红线摘要 + 双来源徽标 + 真实关闭动作。
    private var complianceSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(AppConstants.complianceStatement)
                        .font(.headline)
                    HStack(spacing: AppTheme.Spacing.sm) {
                        OriginBadge(.simulated, style: .full)
                        OriginBadge(.real, style: .full)
                    }
                    ForEach(AppConstants.complianceRedLines.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                            Text("R\(index + 1)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(AppConstants.complianceRedLines[index])
                                .font(.subheadline)
                        }
                    }
                    Text(AppConstants.simulationFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("合规声明")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showCompliance = false }
                }
            }
        }
    }
}
