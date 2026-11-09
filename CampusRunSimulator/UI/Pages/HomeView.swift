import Foundation
import SwiftUI
import UIKit
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

    // MARK: 今日概览（按本地日历日筛选，只统计真实记录）

    public var todayRealSessions: [RunSession] {
        let calendar = Calendar.current
        return allRealSessions.filter { calendar.isDateInToday($0.startTime) }
    }

    public var todayRealDistanceM: Double {
        todayRealSessions.reduce(0) { $0 + $1.totalDistanceMeters }
    }

    public var todayRealDuration: TimeInterval {
        todayRealSessions.reduce(0) { $0 + $1.durationSeconds }
    }

    /// 最近一次真实记录的时间文案；没有记录时返回「暂无」。
    public var latestRealTimeText: String {
        guard let latest = allRealSessions.first else { return "暂无记录" }
        return latest.startTime.iso8601UTCString
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
    ///
    /// **绝不能在这里写库/发通知**：本方法由 `.onReceive(.campusRunPermissionStateChanged)` 触发，
    /// 而 `savePermissionState` 会再发同一个通知，二者叠加会形成无限通知循环、占满主线程，
    /// 表现为「UI 正常渲染但整体滑不动、点不了」。这里只刷新内存中的展示状态即可。
    public func recheckPermissions() {
        let snapshot = locationProvider.authorizationSnapshot
        permissionDegraded = snapshot.hasDegradedPermission
        permissionSummary = snapshot.summary
    }
}

// MARK: - 首页总览（F53，图形化重做 v0.1.7）

/// 设计目标：**一屏只做三件事**——看今天、开始跑、生成仿真。
/// - 顶部「今天」大数字卡：今日真实里程 / 时长 / 次数，按本地日历日统计。
/// - 两张渐变主操作卡：真实跑步（设备传感器）、仿真数据（SIMULATED 标记）。
/// - 一排统计小块 + 四个胶囊入口，不再用成段文字解释每件事。
/// - 合规与隐私信息压缩为一条小字提示 + 可点开的详情页。
@MainActor
public struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var vm = HomeViewModel()
    @State private var showCompliance: Bool = false
    @State private var replaySessionId: String? = nil

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                todayCard
                heroActions
                statGrid
                quickEntries
                privacyCard
                if vm.isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("正在读取本地数据…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let message = vm.errorMessage {
                    errorCard(message)
                }
                complianceFooter
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("校园跑")
        .navigationBarTitleDisplayMode(.large)
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

    // MARK: 今日概览

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: 6) {
                Text("今天")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 2)
                Text(vm.todayRealSessions.isEmpty ? "还没有真实记录" : "最近一次 \(vm.latestRealTimeText)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(distanceValue(vm.todayRealDistanceM))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("今日真实里程 km")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.82))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Units.formatDuration(vm.todayRealDuration))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("今日时长")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.82))
                }
                Spacer(minLength: 0)
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityHidden(true)
            }

            if vm.permissionDegraded {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text("定位或运动权限受限，真实记录可能不完整")
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    Button("修复") { vm.openSystemSettings() }
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.18), in: Capsule(style: .continuous))
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.55, blue: 0.42), Color(red: 0.09, green: 0.36, blue: 0.60)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 5)
        .accessibilityElement(children: .contain)
    }

    // MARK: 两个主操作

    private var heroActions: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HeroActionCard(
                title: "开始真实跑步",
                subtitle: "用设备 GPS 与运动传感器记录，写入真实分区",
                symbol: "figure.run",
                colors: [Color(red: 0.16, green: 0.62, blue: 0.42), Color(red: 0.09, green: 0.48, blue: 0.56)]
            ) {
                vm.open(.liveRun)
            }

            HeroActionCard(
                title: "生成仿真数据",
                subtitle: "在校园路线上生成带 SIMULATED 标记的研究数据",
                symbol: "testtube.2",
                colors: [Color(red: 0.38, green: 0.32, blue: 0.78), Color(red: 0.22, green: 0.48, blue: 0.86)]
            ) {
                vm.open(.simulation)
            }
        }
    }

    // MARK: 统计小块

    private var statGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: AppTheme.Spacing.sm)],
            spacing: AppTheme.Spacing.sm
        ) {
            StatChip(
                symbol: "checkmark.seal.fill",
                value: "\(vm.allRealSessions.count)",
                unit: "条",
                label: "真实记录",
                tint: Color(red: 0.16, green: 0.62, blue: 0.42)
            )
            StatChip(
                symbol: "flask.fill",
                value: "\(vm.allSimulatedSessions.count)",
                unit: "份",
                label: "测试数据集",
                tint: Color(red: 0.38, green: 0.32, blue: 0.78)
            )
            StatChip(
                symbol: "map.fill",
                value: "\(vm.routeCount)",
                unit: "条",
                label: "已存路线",
                tint: Color.orange
            )
        }
    }

    // MARK: 次级入口

    private var quickEntries: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
                      GridItem(.flexible(), spacing: AppTheme.Spacing.sm)],
            spacing: AppTheme.Spacing.sm
        ) {
            PillEntry(symbol: "clock.arrow.circlepath", title: "历史记录") { vm.openHistory() }
            PillEntry(symbol: "chart.xyaxis.line", title: "数据分析") {
                vm.open(.analytics(sessionId: vm.allRealSessions.first?.id))
            }
            PillEntry(symbol: "map", title: "路线规划") { vm.open(.routePlanning) }
            PillEntry(symbol: "gearshape", title: "设置") { vm.open(.settings) }
        }
    }

    // MARK: 隐私提示

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            PrivacyNote("地图只绘制你创建或记录下来的轨迹，不显示你的实时位置，也不在后台持续定位。")
            PrivacyNote("数据全部留在本机，不上传、不写入第三方平台。")
        }
        .padding(AppTheme.Spacing.md)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.04),
            in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.medium, style: .continuous)
        )
    }

    // MARK: 错误态

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("本地数据读取失败")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 2)
            }
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                Button("重新加载") { Task { await vm.refreshStats() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("前往设置") { vm.open(.settings) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    // MARK: 合规页脚

    private var complianceFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("真实记录与测试数据分区存储，永不互相转换")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            Button {
                showCompliance = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
            }
            .accessibilityLabel(AccessibilityLabels.complianceDetails)
        }
        .padding(.top, 4)
    }

    // MARK: 工具

    /// 米 → 不带单位的公里两位小数，供大字号展示（单位单独用 caption 显示）。
    private func distanceValue(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "0.00" }
        return String(format: "%.2f", meters / Units.metersPerKilometer)
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
