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
        case .home, .routePlanning, .simulation, .liveRun, .settings: return true
        case .analytics, .history: return false
        }
    }
}

/// 根视图（重写版，iOS 26/27 专用）。
///
/// **设计原则：极简、稳定、零自绘玻璃。**
/// - 使用系统标准 `TabView`：iOS 26 会自动为 tab bar 应用原生 Liquid Glass，无需手写任何玻璃代码，
///   自然不掉帧、不吞触摸。
/// - 每个 tab 各自一个独立 `NavigationStack`，互不干扰，杜绝跨 tab 的导航栈串扰与重绘风暴。
/// - 不再有自定义顶部栏 / 底部栏 / `GlassEffectContainer` / `glassEffectID` / `onChange` 驱动的
///   自定义路由切换——这些曾是「进 App 卡死」表象的来源。
/// - 7 个页面全部真实可达：5 个主 tab + 首页导航栈内 push「历史 / 数据分析」。
@MainActor
public struct RootView: View {
    @Environment(\.persistentStores) private var stores
    @AppStorage("campusrun.permissionDegraded") private var permissionDegraded: Bool = false

    @State private var selection: AppRoute = .home
    @State private var homePath: [AppRoute] = []
    @State private var navigation = AppNavigation.shared
    @State private var settingsStore = AppSettingsStore.shared
    @State private var showPermissionBanner: Bool = false

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $homePath) {
                HomeView()
                    .navigationDestination(for: AppRoute.self) { destinationView($0) }
            }
            .tabItem { Label("首页", systemImage: "house") }
            .tag(AppRoute.home)

            NavigationStack {
                RoutePlanningView()
            }
            .tabItem { Label("路线", systemImage: "map") }
            .tag(AppRoute.routePlanning)

            NavigationStack {
                SimulationView()
            }
            .tabItem { Label("模拟", systemImage: "testtube.2") }
            .tag(AppRoute.simulation)

            NavigationStack {
                LiveRunView()
            }
            .tabItem { Label("实时", systemImage: "figure.run") }
            .tag(AppRoute.liveRun)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(AppRoute.settings)
        }
        .onAppear {
            // 容器已由 App 入口在后台创建完毕并注入环境；这里仅把它交给 UI 层服务。
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if showPermissionBanner {
                permissionBanner
            }
        }
    }

    /// 权限异常横幅（简洁版，真实动作绑定）。
    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text("定位或运动权限受限，真实记录可能不完整")
                .font(.caption)
            Spacer(minLength: 4)
            Button("设置") { AppServices.shared.openSystemSettings() }
                .font(.caption.bold())
                .accessibilityLabel("前往系统设置修复权限")
            Button("忽略") { showPermissionBanner = false }
                .font(.caption)
                .accessibilityLabel("忽略权限提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.18))
    }

    /// 路由到指定页面：主 tab 直接切换；历史 / 数据分析压入首页导航栈。
    public func route(to target: AppRoute) {
        switch target {
        case .home, .routePlanning, .simulation, .liveRun, .settings:
            selection = target
            homePath.removeAll()
        case .history, .analytics:
            selection = .home
            if homePath.last != target {
                homePath.append(target)
            }
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
}
