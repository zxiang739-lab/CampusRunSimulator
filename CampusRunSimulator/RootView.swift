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

/// 根视图：自定义玻璃底部栏 + TabView（4 主入口）+ NavigationStack（7 页路由）
/// + 权限异常横幅。所有玻璃材质均经 F45 唯一入口 `glassCard`。
@MainActor
public struct RootView: View {
    @Environment(\.persistentStores) private var stores
    @AppStorage("campusrun.permissionDegraded") private var permissionDegraded: Bool = false

    @State private var selection: AppRoute = .home
    @State private var homePath: [AppRoute] = []
    @State private var showPermissionBanner: Bool = false
    @State private var navigation = AppNavigation.shared
    @State private var settingsStore = AppSettingsStore.shared

    /// 显式初始化全部路由状态，保证首次进入时落在首页且导航栈为空。
    public init() {
        _selection = State(initialValue: .home)
        _homePath = State(initialValue: [])
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
        .modifier(AppThemeModifiers(
            appearance: settingsStore.settings.appearance,
            dynamicTypeOverride: settingsStore.settings.dynamicTypeOverride
        ))
    }

    /// 顶部常驻 7 页导航菜单 + 权限异常横幅（全部绑定真实动作）。
    @ViewBuilder
    private var headerBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .accessibilityHidden(true)
                Text("Campus Run Simulator")
                    .font(.headline)
                Spacer(minLength: 4)
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
