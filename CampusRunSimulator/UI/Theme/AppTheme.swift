import Foundation
import SwiftUI
import Observation
import SwiftData
import UIKit

// MARK: - 主题（F47 / §1.6 / §B.12）

/// 全 App 统一的颜色、间距、圆角、数值格式与系统适配入口。
/// 说明：本文件除主题常量外，还承载 UI 层共享的「服务装配 / 导航 / 设置」三类基础设施，
/// 因为 T04 只允许落盘 15 个文件，且 F47 被所有页面依赖；这些类型是新增类型，
/// 不重复定义任何 BATCH_1/2/3 已冻结的 Domain / Reports / 协议 / 枚举。
public enum AppTheme {

    // MARK: 颜色

    public enum Colors {
        /// 模拟数据主色（文字 + 图标双通道用，颜色不是唯一区分手段）。
        public static func simulated(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.purple.opacity(0.85) : Color.purple
        }

        /// 真实记录主色。
        public static func real(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.green.opacity(0.85) : Color.green
        }

        public static func secondaryText(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.60)
        }

        public static func cardStroke(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10)
        }

        public static func chartGrid(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
        }

        public static func curve(_ kind: MetricKind, scheme: ColorScheme) -> Color {
            switch kind {
            case .pace: return .orange
            case .cadence: return .blue
            case .stride: return .teal
            case .altitude: return scheme == .dark ? .mint : .green
            }
        }
    }

    // MARK: 间距 / 圆角

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum CornerRadius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 14
        public static let large: CGFloat = 20
    }

    // MARK: 数值格式

    /// 统一数值格式：非有限值显示「—」，单位与数值之间留空格。
    public static func metricNumberFormat(_ value: Double, unit: String = "", digits: Int = 2) -> String {
        guard value.isFinite else { return "—" }
        let format = "%.\(max(0, min(6, digits)))f"
        let number = String(format: format, value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// 图表 / 地图游标处的通用摘要（图表数值摘要文本，满足 §B.12 无障碍要求）。
    public static func cursorSummary(index: Int, elapsed: TimeInterval, distance: Double) -> String {
        "第 \(index + 1) 个采样点｜用时 \(Units.formatDuration(elapsed))｜距离 \(Units.formatDistanceKm(distance))"
    }

    // MARK: Liquid Glass 可用性

    /// iOS 26 起官方 Liquid Glass 可用；低版本返回 false，界面显示「已启用兼容外观」，
    /// **不隐藏、不禁用任何功能**（§1.6 / §B.13.3-13）。
    public static func isLiquidGlassAvailable() -> Bool {
        if #available(iOS 26, *) {
            return true
        }
        return false
    }

    public static var liquidGlassStatusText: String {
        isLiquidGlassAvailable()
            ? "Liquid Glass 官方外观已启用"
            : AppConstants.liquidGlassFallbackNotice
    }

    // MARK: 深色 / 动态类型 / Reduce Motion 适配

    public static func colorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 把设置里的动态类型偏好字符串映射为 SwiftUI 的 `DynamicTypeSize`；无法识别时返回 nil（跟随系统）。
    public static func dynamicTypeSize(for raw: String?) -> DynamicTypeSize? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "xSmall": return .xSmall
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "xLarge": return .xLarge
        case "xxLarge": return .xxLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1": return .accessibility1
        case "accessibility2": return .accessibility2
        case "accessibility3": return .accessibility3
        case "accessibility4": return .accessibility4
        case "accessibility5": return .accessibility5
        default: return nil
        }
    }

    /// 系统 Reduce Motion 与用户在设置里的偏好二者取或；用于禁用回放 / 玻璃形变动画。
    public static func reduceMotionEnabled(systemReduceMotion: Bool, settings: AppSettings) -> Bool {
        systemReduceMotion || settings.reduceMotion
    }
}

/// 无障碍标签固定文案（单一来源，VoiceOver 可读）。
public enum AccessibilityLabels {
    public static let simulatedBadge = "测试数据 SIMULATED，App 内生成的测试数据，不代表真实运动"
    public static let realBadge = "真实记录，来自设备传感器"
    public static let play = "播放回放"
    public static let pause = "暂停回放"
    public static let resume = "继续回放"
    public static let fastForward = "快进 10 秒"
    public static let seek = "拖动定位到指定时间点"
    public static let playbackRate = "选择回放倍速"
    public static let chartCursor = "拖动图表联动游标，四条曲线与地图同步定位"
    public static let export = "导出记录文件"
    public static let delete = "删除记录"
    public static let save = "保存"
    public static let undo = "撤销上一步编辑"
    public static let redo = "重做上一步编辑"
    public static let openSettings = "前往系统设置"
    public static let complianceDetails = "查看合规声明与红线摘要"
    public static let refresh = "下拉刷新统计与最近记录"
    public static let mapAddPoint = "在地图上点击以新增路线点"
    public static let mapDragPoint = "长按选中点位后在地图上拖动以移动点位"
}

/// 运行时偏好键：用于让外观 / 动态类型 / Reduce Motion / 仿真默认值在页面间即时生效。
/// 这些键只保存显示偏好与仿真默认输入，不保存任何运动记录，更不改变 `DataOrigin`。
public enum AppPreferenceKey {
    public static let unitSystem = "campusrun.unitSystem"
    public static let paceFormat = "campusrun.paceFormat"
    public static let appearance = "campusrun.appearance"
    public static let dynamicTypeOverride = "campusrun.dynamicTypeOverride"
    public static let reduceMotion = "campusrun.reduceMotion"
    public static let defaultSampleRateHz = "campusrun.defaultSampleRateHz"
    public static let seedPolicy = "campusrun.seedPolicy"
    public static let defaultNoiseAmplitude = "campusrun.defaultNoiseAmplitude"
    public static let elevationDeadbandMeters = "campusrun.elevationDeadbandMeters"
    public static let externalElevationEnabled = "campusrun.externalElevationEnabled"
    public static let healthKitWriteEnabled = "campusrun.healthKitWriteEnabled"
    public static let defaultSpeedModel = "campusrun.defaultSpeedModel"
    public static let defaultSeed = "campusrun.defaultSeed"
    public static let permissionDegraded = "campusrun.permissionDegraded"
}

// MARK: - 主题修饰符（RootView 统一应用，设置即时生效）

/// 统一应用外观与动态类型覆盖；`dynamicTypeOverride == nil` 时完全跟随系统。
public struct AppThemeModifiers: ViewModifier {
    public let appearance: AppearanceMode
    public let dynamicTypeOverride: String?

    public init(appearance: AppearanceMode, dynamicTypeOverride: String?) {
        self.appearance = appearance
        self.dynamicTypeOverride = dynamicTypeOverride
    }

    public func body(content: Content) -> some View {
        content
            .preferredColorScheme(AppTheme.colorScheme(for: appearance))
            .modifier(DynamicTypeOverrideModifier(size: AppTheme.dynamicTypeSize(for: dynamicTypeOverride)))
    }
}

private struct DynamicTypeOverrideModifier: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        Group {
            if let size {
                content.dynamicTypeSize(size)
            } else {
                content
            }
        }
    }
}

// MARK: - 跨页导航（真实跳转，不改 AppRoute 枚举 case / route(to:) 签名）

/// 页面 VM 通过 `AppNavigation.shared.route(to:)` 发出跳转请求，
/// `RootView` 观察 `requestSequence` 后调用自身冻结的 `route(to:)` 完成真实 tab / 导航栈切换。
@MainActor
@Observable
public final class AppNavigation {
    public static let shared = AppNavigation()

    public private(set) var requestSequence: Int = 0
    public private(set) var selectedSessionID: String? = nil
    public private(set) var selectedRouteID: String? = nil
    public private(set) var selectedProfileID: String? = nil

    private var pendingRoute: AppRoute? = nil

    private init() {}

    /// 发出路由请求；同一序列递增保证连续两次同目标跳转也能被观察到。
    public func route(to target: AppRoute) {
        if case .analytics(sessionId: let sessionId) = target {
            selectedSessionID = sessionId
        }
        pendingRoute = target
        requestSequence += 1
    }

    /// RootView 消费一次请求；返回 nil 表示没有待处理跳转。
    public func consumePending() -> AppRoute? {
        let value = pendingRoute
        pendingRoute = nil
        return value
    }

    /// 目标页读取后清空跨页参数，避免后续无参进入时误用旧 session / route / profile。
    public func consumeSelectedSessionID() -> String? {
        let value = selectedSessionID
        selectedSessionID = nil
        return value
    }

    public func consumeSelectedRouteID() -> String? {
        let value = selectedRouteID
        selectedRouteID = nil
        return value
    }

    public func consumeSelectedProfileID() -> String? {
        let value = selectedProfileID
        selectedProfileID = nil
        return value
    }

    public func selectSession(_ id: String?) {
        selectedSessionID = id
    }

    public func selectRoute(_ id: String?) {
        selectedRouteID = id
    }

    public func selectProfile(_ id: String?) {
        selectedProfileID = id
    }

    public func openHome() {
        route(to: .home)
    }

    public func openLiveRun() {
        route(to: .liveRun)
    }

    public func openHistory() {
        route(to: .history)
    }

    public func openSettings() {
        route(to: .settings)
    }

    public func openRoutePlanning(routeId: String? = nil) {
        selectedRouteID = routeId
        route(to: .routePlanning)
    }

    public func openSimulation(profileId: String? = nil) {
        selectedProfileID = profileId
        route(to: .simulation)
    }

    public func openAnalytics(sessionId: String? = nil) {
        selectedSessionID = sessionId
        route(to: .analytics(sessionId: sessionId))
    }
}

// MARK: - 全局设置（真实持久化，所有页面即时生效）

@MainActor
@Observable
public final class AppSettingsStore {
    public static let shared = AppSettingsStore()

    public private(set) var settings: AppSettings = .default
    public private(set) var lastPersistenceError: String? = nil

    private init() {
        settings = AppServices.shared.loadSettings()
        applyRuntimePreferences(settings)
    }

    /// 在双容器注入完成后重新读取真实持久化设置。
    public func reload() {
        settings = AppServices.shared.loadSettings()
        applyRuntimePreferences(settings)
    }

    /// 值类型无 mutating：由调用方构造新设置后写入，并即时广播给所有页面。
    public func update(_ transform: (AppSettings) -> AppSettings) {
        let next = transform(settings)
        settings = next
        applyRuntimePreferences(next)
        do {
            try AppServices.shared.saveSettings(next)
            lastPersistenceError = nil
        } catch {
            // 写失败时仍保留内存中的新值，由设置页展示明确错误态。
            lastPersistenceError = error.localizedDescription
        }
    }

    /// 把会即时影响 UI / VM 默认值的偏好同步写入进程可读的偏好域。
    /// 只有显示偏好和仿真默认输入，不含任何轨迹点，也不触碰真实记录容器。
    private func applyRuntimePreferences(_ value: AppSettings) {
        let defaults = UserDefaults.standard
        defaults.set(value.unitSystem.rawValue, forKey: AppPreferenceKey.unitSystem)
        defaults.set(value.paceFormat.rawValue, forKey: AppPreferenceKey.paceFormat)
        defaults.set(value.appearance.rawValue, forKey: AppPreferenceKey.appearance)
        defaults.set(value.dynamicTypeOverride ?? "", forKey: AppPreferenceKey.dynamicTypeOverride)
        defaults.set(value.reduceMotion, forKey: AppPreferenceKey.reduceMotion)
        defaults.set(value.defaultSampleRateHz, forKey: AppPreferenceKey.defaultSampleRateHz)
        defaults.set(value.seedPolicy.rawValue, forKey: AppPreferenceKey.seedPolicy)
        defaults.set(value.defaultNoiseAmplitude, forKey: AppPreferenceKey.defaultNoiseAmplitude)
        defaults.set(value.elevationDeadbandMeters, forKey: AppPreferenceKey.elevationDeadbandMeters)
        defaults.set(value.externalElevationEnabled, forKey: AppPreferenceKey.externalElevationEnabled)
        defaults.set(value.healthKitWriteEnabled, forKey: AppPreferenceKey.healthKitWriteEnabled)
    }
}

// MARK: - UI 层服务装配（复用前 3 批冻结服务，禁止重复定义）

/// 集中构造 BATCH_2/3 的真实服务；`PersistentStores` 由 App 入口注入，
/// 尚未注入时降级到 `ModelContainerFactory.makeInMemoryPair()`（仍是两个独立容器，不是假数据）。
@MainActor
public final class AppServices {
    public static let shared = AppServices()

    private var cachedStores: PersistentStores? = nil

    private init() {}

    /// RootView 在 `.onAppear` 时把 App 入口注入的双容器交给 UI 层。
    public func configure(_ injected: PersistentStores?) {
        guard let injected else { return }
        cachedStores = injected
    }

    public var stores: PersistentStores? {
        if let cachedStores { return cachedStores }
        let fallback = try? ModelContainerFactory.makeInMemoryPair()
        cachedStores = fallback
        return fallback
    }

    // MARK: 冻结服务

    public var repository: DefaultRunRepository? {
        stores.map { DefaultRunRepository(stores: $0) }
    }

    public var exporter: ExportManager {
        ExportManager(stores: stores)
    }

    public var presetStore: RulePresetStore? {
        stores.map { RulePresetStore(stores: $0) }
    }

    public var engine: DefaultSimulationEngine { DefaultSimulationEngine() }
    public var gpxCodec: GPXCodec { GPXCodec() }
    public var seriesBuilder: SeriesBuilder { SeriesBuilder() }
    public var analysisBuilder: AnalysisBuilder { AnalysisBuilder() }
    public var invariantValidator: InvariantValidator { InvariantValidator() }
    public var ruleEvaluator: RuleEvaluator { RuleEvaluator() }
    public var ruleValidator: RuleValidator { RuleValidator() }
    public var dataMarker: DataMarker { DataMarker() }

    public func makeHealthKitService() -> any HealthKitService {
        DefaultHealthKitService()
    }

    public func makeLocationProvider() -> CoreLocationProvider {
        CoreLocationProvider()
    }

    public func makeMotionProvider(initialAltitudeM: Double = 0) -> CoreMotionProvider {
        CoreMotionProvider(initialAltitudeM: initialAltitudeM)
    }

    /// 打开系统设置（权限修复的真实动作）。
    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: 中性配置对象的真实持久化

    /// `RunRepository` 冻结协议只提供 `routes()` / `profiles()` 读取，没有写入方法；
    /// 用户自建路线 / 仿真模板 / 全局设置是无 `dataOrigin` 的中性对象，
    /// 因此这里通过 BATCH_1 冻结的 `SDMapper` + SwiftData 写入 **simulated 容器**（不触碰 real 容器）。
    private func configContext() throws -> ModelContext {
        guard let stores else { throw AppError.persistenceMigrationFailed }
        return ModelContext(stores.container(for: .simulated))
    }

    public func saveRoute(_ route: Route) throws {
        let context = try configContext()
        let existing = (try? context.fetch(FetchDescriptor<SDRoute>())) ?? []
        for model in existing where model.id == route.id {
            context.delete(model)
        }
        let object = try SDMapper.fromValue(route)
        context.insert(object)
        for version in route.versions {
            let versionObject = try SDMapper.fromValue(version, routeId: route.id)
            versionObject.route = object
            context.insert(versionObject)
        }
        try context.save()
    }

    public func loadRoutes() -> [Route] {
        guard let context = try? configContext() else { return [] }
        let models = (try? context.fetch(FetchDescriptor<SDRoute>())) ?? []
        return models.compactMap { SDMapper.toValue($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveProfile(_ profile: SimulationProfile) throws {
        let context = try configContext()
        let existing = (try? context.fetch(FetchDescriptor<SDSimulationProfile>())) ?? []
        for model in existing where model.id == profile.id {
            context.delete(model)
        }
        context.insert(try SDMapper.fromValue(profile))
        try context.save()
    }

    public func loadProfiles() -> [SimulationProfile] {
        guard let context = try? configContext() else { return [] }
        let models = (try? context.fetch(FetchDescriptor<SDSimulationProfile>())) ?? []
        return models.compactMap { SDMapper.toValue($0) }
    }

    public func loadPresets() -> [RulePreset] {
        guard let context = try? configContext() else { return [] }
        let models = (try? context.fetch(FetchDescriptor<SDRulePreset>())) ?? []
        return models.compactMap { SDMapper.toValue($0) }
            .sorted { $0.displayName < $1.displayName }
    }

    public func saveSettings(_ value: AppSettings) throws {
        let context = try configContext()
        let existing = (try? context.fetch(FetchDescriptor<SDAppSettings>())) ?? []
        for model in existing where model.id == AppConstants.globalSettingsID {
            context.delete(model)
        }
        context.insert(try SDMapper.fromValue(value))
        try context.save()
    }

    public func loadSettings() -> AppSettings {
        guard let context = try? configContext() else { return .default }
        let models = (try? context.fetch(FetchDescriptor<SDAppSettings>())) ?? []
        for model in models where model.id == AppConstants.globalSettingsID {
            return SDMapper.toValue(model) ?? .default
        }
        return .default
    }

    public func savePermissionState(_ state: PermissionState) throws {
        let context = try configContext()
        let existing = (try? context.fetch(FetchDescriptor<SDPermissionState>())) ?? []
        for model in existing where model.id == AppConstants.globalPermissionStateID {
            context.delete(model)
        }
        context.insert(try SDMapper.fromValue(state))
        try context.save()
        // 与 RootView 的 @AppStorage 键保持一致，并广播真实状态变化。
        UserDefaults.standard.set(state.hasDegradedPermission, forKey: AppPreferenceKey.permissionDegraded)
        NotificationCenter.default.post(name: .campusRunPermissionStateChanged, object: nil)
    }

    public func loadPermissionState() -> PermissionState {
        guard let context = try? configContext() else { return .unknownState }
        let models = (try? context.fetch(FetchDescriptor<SDPermissionState>())) ?? []
        for model in models where model.id == AppConstants.globalPermissionStateID {
            return SDMapper.toValue(model) ?? .unknownState
        }
        return .unknownState
    }

    /// 真实读取两个 store 文件（含 -wal / -shm）占用，按来源分区显示。
    public func storageUsageText() -> String {
        let urls: [URL] = [stores?.simulatedStoreURL, stores?.realStoreURL].compactMap { $0 }
        guard !urls.isEmpty else { return "当前为内存模式（仍为两个独立容器），无磁盘占用" }
        var total: Int64 = 0
        for url in urls {
            for candidate in [url, url.appendingPathExtension("wal"), url.appendingPathExtension("shm")] {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                   let size = attributes[.size] as? NSNumber {
                    total += size.int64Value
                }
            }
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }
}
