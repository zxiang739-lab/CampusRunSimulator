import SwiftUI
import UIKit

/// 根路由：7 个页面入口（§2.2 F09 / PRD §B.6.1–B.6.7）。
public enum AppRoute: Hashable, Sendable {
    case home
    case routePlanning
    case simulation
    case liveRun
    case analytics(sessionId: String?)
    case history
    case settings

    public var title: String {
        switch self {
        case .home: return "首页总览"
        case .routePlanning: return "地图与路线规划"
        case .simulation: return "运动模拟器"
        case .liveRun: return "实时运动"
        case .analytics: return "数据分析"
        case .history: return "历史记录"
        case .settings: return "设置"
        }
    }

    public var symbolName: String {
        switch self {
        case .home: return "house"
        case .routePlanning: return "map"
        case .simulation: return "testtube.2"
        case .liveRun: return "figure.run"
        case .analytics: return "chart.xyaxis.line"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    /// 是否为 TabView 的主 tab（其余页面通过 NavigationStack 路由进入）。
    public var isPrimaryTab: Bool {
        switch self {
        case .home, .routePlanning, .simulation, .liveRun: return true
        case .analytics, .history, .settings: return false
        }
    }
}

/// 首次启动强制合规确认视图（§8 A12 / PRD §B.6.1）。
private struct ComplianceConfirmationView: View {
    @Binding var isConfirmed: Bool
    let isPersistent: Bool
    /// 确认后的关闭回调：由 RootView 负责把 `showComplianceSheet` 置为 false。
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("使用前请先确认")
                        .font(.largeTitle.bold())
                    Text(AppConstants.complianceStatement)
                        .font(.headline)
                    Text("本项目为教学研究 / 个人自用 / 数据分析工具。仿真数据由 App 内独立数据源生成，"
                         + "不代表真实运动；真实记录来自设备传感器。两类数据物理隔离，永不互相转换。")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text("合规红线摘要（R1–R8）")
                        .font(.headline)
                    ForEach(AppConstants.complianceRedLines.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 10) {
                            Text("R\(index + 1)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(AppConstants.complianceRedLines[index])
                                .font(.subheadline)
                        }
                    }

                    Text("标记示例（文字 + 图标双通道，不依赖颜色）")
                        .font(.headline)
                    HStack(spacing: 12) {
                        OriginBadge(.simulated, style: .full)
                        OriginBadge(.real, style: .full)
                    }

                    Text("当前数据层：\(isPersistent ? "本地持久化（双独立存储域）" : "内存模式（数据不持久化，仍分域）")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        isConfirmed = true
                        onConfirm()
                    } label: {
                        Text("我已阅读并确认")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("我已阅读并确认合规声明")

                    Text("确认后即可进入 App，本次确认会被记住，不再重复弹出。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("合规声明")
        }
        .interactiveDismissDisabled(true)
    }
}

/// 根视图：自定义玻璃底部栏 + TabView（4 主入口）+ NavigationStack（7 页路由）
/// + 首次合规确认 + 权限异常横幅。所有玻璃材质均经 F45 唯一入口 `glassCard`。
@MainActor
public struct RootView: View {
    @Environment(\.persistentStores) private var stores
    @AppStorage("campusrun.complianceConfirmed") private var complianceConfirmed: Bool = false
    @AppStorage("campusrun.permissionDegraded") private var permissionDegraded: Bool = false

    @State private var selection: AppRoute = .home
    @State private var homePath: [AppRoute] = []
    @State private var showComplianceSheet: Bool = false
    @State private var showPermissionBanner: Bool = false
    @State private var navigation = AppNavigation.shared
    @State private var settingsStore = AppSettingsStore.shared

    /// 显式初始化全部路由状态，保证首次进入时落在首页且导航栈为空。
    public init() {
        _selection = State(initialValue: .home)
        _homePath = State(initialValue: [])
        _showComplianceSheet = State(initialValue: false)
        _showPermissionBanner = State(initialValue: false)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            TabView(selection: $selection) {
                NavigationStack(path: $homePath) {
                    HomeView()
                        .navigationDestination(for: AppRoute.self) { route in
                            destinationView(route)
                        }
                }
                .tag(AppRoute.home)

                NavigationStack {
                    RoutePlanningView()
                }
                .tag(AppRoute.routePlanning)

                NavigationStack {
                    SimulationView()
                }
                .tag(AppRoute.simulation)

                NavigationStack {
                    LiveRunView()
                }
                .tag(AppRoute.liveRun)
            }
            .toolbar(.hidden, for: .tabBar)
            bottomBar
        }
        .onAppear {
            AppServices.shared.configure(stores)
            settingsStore.reload()
            if !complianceConfirmed {
                showComplianceSheet = true
            }
            showPermissionBanner = permissionDegraded
        }
        .onReceive(NotificationCenter.default.publisher(for: .campusRunWillEnterForeground)) { _ in
            showPermissionBanner = permissionDegraded
        }
        .onReceive(NotificationCenter.default.publisher(for: .campusRunPermissionStateChanged)) { _ in
            showPermissionBanner = permissionDegraded
        }
        .onChange(of: navigation.requestSequence) { _, _ in
            if let target = navigation.consumePending() {
                route(to: target)
            }
        }
        .onChange(of: complianceConfirmed) { _, confirmed in
            // 双保险：任何路径把确认标记置为 true 时都关闭全屏页，避免用户卡在合规页。
            if confirmed {
                showComplianceSheet = false
            }
        }
        .fullScreenCover(isPresented: $showComplianceSheet) {
            ComplianceConfirmationView(
                isConfirmed: $complianceConfirmed,
                isPersistent: stores?.isPersistent ?? false,
                onConfirm: { showComplianceSheet = false }
            )
        }
        .modifier(AppThemeModifiers(
            appearance: settingsStore.settings.appearance,
            dynamicTypeOverride: settingsStore.settings.dynamicTypeOverride
        ))
    }

    /// 顶部常驻合规栏 + 7 页导航菜单 + 权限异常横幅（全部绑定真实动作）。
    @ViewBuilder
    private var headerBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .accessibilityHidden(true)
                Text(AppConstants.complianceStatement)
                    .font(.caption)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button {
                    showComplianceSheet = true
                } label: {
                    Label("合规详情", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("查看合规声明")
                Menu {
                    ForEach(allRoutes, id: \.self) { route in
                        Button {
                            self.route(to: route)
                        } label: {
                            Label(route.title, systemImage: route.symbolName)
                        }
                    }
                } label: {
                    Label("页面导航", systemImage: "line.3.horizontal")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("打开页面导航菜单")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showPermissionBanner {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text("定位或运动权限受限，真实记录可能不完整")
                        .font(.caption)
                    Spacer(minLength: 4)
                    Button("前往设置") { openSystemSettings() }
                        .font(.caption)
                        .accessibilityLabel("前往系统设置修复权限")
                    Button("忽略") { showPermissionBanner = false }
                        .font(.caption)
                        .accessibilityLabel("忽略权限提示")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
            }
        }
        .glassCard(role: .controlBar, interactive: true)
    }

    /// 自定义底部栏：完全经 `glassCard` 使用玻璃材质，4 个主入口与「更多」菜单均真实跳转。
    private var bottomBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(primaryRoutes, id: \.self) { route in
                Button {
                    self.route(to: route)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: route.symbolName)
                            .font(.subheadline)
                        Text(route.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .foregroundStyle(selection == route ? .blue : .primary)
                .accessibilityLabel("切换到 \(route.title)")
            }
            Menu {
                ForEach(secondaryRoutes, id: \.self) { route in
                    Button {
                        self.route(to: route)
                    } label: {
                        Label(route.title, systemImage: route.symbolName)
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline)
                    Text("更多")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .accessibilityLabel("打开更多页面菜单")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .glassCard(role: .controlBar, interactive: true)
    }

    /// 7 页路由表（顶部菜单使用，全部为真实可跳转目标）。
    private var allRoutes: [AppRoute] {
        [
            .home,
            .routePlanning,
            .simulation,
            .liveRun,
            .analytics(sessionId: nil),
            .history,
            .settings
        ]
    }

    private var primaryRoutes: [AppRoute] {
        [.home, .routePlanning, .simulation, .liveRun]
    }

    private var secondaryRoutes: [AppRoute] {
        [.analytics(sessionId: nil), .history, .settings]
    }

    /// 路由到指定页面：主 tab 直接切换，其余页面压入首页导航栈。
    public func route(to target: AppRoute) {
        switch target {
        case .analytics(sessionId: let sessionId):
            AppNavigation.shared.selectSession(sessionId)
        case .home, .routePlanning, .simulation, .liveRun, .history, .settings:
            break
        }
        if target.isPrimaryTab {
            selection = target
            homePath.removeAll()
        } else {
            selection = .home
            homePath.append(target)
        }
    }

    /// 路由目标视图（页面类型名由架构 §2.2 F53–F59 冻结，同 target 跨文件引用）。
    @ViewBuilder
    private func destinationView(_ route: AppRoute) -> some View {
        switch route {
        case .home:
            HomeView()
        case .routePlanning:
            RoutePlanningView()
        case .simulation:
            SimulationView()
        case .liveRun:
            LiveRunView()
        case .analytics:
            AnalyticsView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }

    /// 打开系统设置（权限修复的真实动作）。
    private func openSystemSettings() {
        AppServices.shared.openSystemSettings()
    }
}
