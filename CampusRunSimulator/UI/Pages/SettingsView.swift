import Foundation
import SwiftUI
import Observation
import UniformTypeIdentifiers

// MARK: - 设置页辅助类型（F59 / §B.6.7）

/// 动态类型选项：把用户可读选项映射为 `AppTheme.dynamicTypeSize(for:)` 可识别的字符串。
public enum SettingsDynamicTypeOption: String, CaseIterable, Sendable, Identifiable {
    case system
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge
    case accessibility1
    case accessibility2
    case accessibility3
    case accessibility4
    case accessibility5

    public var id: String { rawValue }

    /// nil 表示跟随系统；与 `AppSettings.dynamicTypeOverride` 语义一致。
    public var selectionValue: String? {
        self == .system ? nil : rawValue
    }

    public var localizedDescription: String {
        switch self {
        case .system: return "跟随系统"
        case .xSmall: return "特小"
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        case .xLarge: return "特大"
        case .xxLarge: return "超大"
        case .xxxLarge: return "超大 +"
        case .accessibility1: return "辅助功能 1"
        case .accessibility2: return "辅助功能 2"
        case .accessibility3: return "辅助功能 3"
        case .accessibility4: return "辅助功能 4"
        case .accessibility5: return "辅助功能 5"
        }
    }
}

/// 引用来源行：来源与证据分级来自 PRD 附录 A，均为静态文献信息，不是运动记录假数据。
public struct SettingsReference: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let urlText: String
    public let evidence: String

    public init(id: String, title: String, urlText: String, evidence: String) {
        self.id = id
        self.title = title
        self.urlText = urlText
        self.evidence = evidence
    }

    public var url: URL? {
        URL(string: urlText)
    }
}

public enum SettingsReferences {
    public static let all: [SettingsReference] = [
        SettingsReference(
            id: "core_location",
            title: "Core Location · CLLocationManager",
            urlText: "https://developer.apple.com/documentation/corelocation/cllocationmanager",
            evidence: "官方 API 文档｜已证实"
        ),
        SettingsReference(
            id: "workout_route",
            title: "HealthKit · 创建体能训练路线",
            urlText: "https://developer.apple.com/documentation/healthkit/creating-a-workout-route",
            evidence: "官方技术文档｜已证实（含 >50 m 精度门限）"
        ),
        SettingsReference(
            id: "core_motion",
            title: "Core Motion · CMPedometerData",
            urlText: "https://developer.apple.com/documentation/coremotion/cmpedometerdata",
            evidence: "官方 API 文档｜已证实（单位语义）"
        ),
        SettingsReference(
            id: "healthkit_authorization",
            title: "HealthKit · 授权与隐私语义",
            urlText: "https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data",
            evidence: "官方技术文档｜已证实（读取权限不可判定）"
        ),
        SettingsReference(
            id: "mapkit_swiftui",
            title: "MapKit for SwiftUI",
            urlText: "https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui",
            evidence: "官方 API 文档｜已证实（iOS 17+）"
        ),
        SettingsReference(
            id: "swift_charts",
            title: "Swift Charts",
            urlText: "https://developer.apple.com/documentation/charts",
            evidence: "官方框架文档｜已证实（iOS 16+）"
        ),
        SettingsReference(
            id: "liquid_glass",
            title: "SwiftUI · GlassEffectContainer",
            urlText: "https://developer.apple.com/documentation/swiftui/glasseffectcontainer",
            evidence: "官方 API 文档｜iOS 26+ 路径，需 Xcode 26 编译验证"
        ),
        SettingsReference(
            id: "gpx",
            title: "GPX 1.1 Schema",
            urlText: "https://www.topografix.com/gpx/1/1/",
            evidence: "公开标准｜已证实（trkseg / ele / time 语义）"
        )
    ]
}

// MARK: - 设置页视图模型（F59 / §B.6.7）

/// 权限、单位、外观、仿真默认值、双域数据管理、高程来源、规则预设、关于页全部真实动作。
@MainActor
@Observable
public final class SettingsViewModel {

    // MARK: 可编辑设置

    public var unitSystem: UnitSystem = .metric
    public var paceFormat: PaceFormat = .minPerKm
    public var appearance: AppearanceMode = .system
    public var dynamicTypeSelection: String? = nil
    public var reduceMotion: Bool = false
    public var defaultSampleRateHz: Double = AppConstants.defaultSampleRateHz
    public var seedPolicy: SeedPolicy = .generateIfMissing
    public var defaultNoiseAmplitude: Double = 0.02
    public var elevationDeadbandMeters: Double = AppConstants.elevationDeadbandMeters
    public var externalElevationEnabled: Bool = false
    public var healthKitWriteEnabled: Bool = false
    public var defaultModelType: SpeedModelType = .steady
    public var fixedSeedText: String = "20261108"
    public var exportFormat: ExportFormat = .csv
    public var presetName: String = "用户自建假设预设"
    public var comparisonGroup: String = "未分组"

    // MARK: 真实读取状态

    public private(set) var presets: [RulePreset] = []
    public private(set) var storageText: String = "正在统计…"
    public private(set) var permissionSummary: String = "正在自检权限…"
    public private(set) var locationStatusText: String = "无数据"
    public private(set) var preciseLocationText: String = "无数据"
    public private(set) var motionStatusText: String = "无数据"
    public private(set) var healthReadStatusText: String = "无数据"
    public private(set) var healthWriteStatusText: String = "无数据"
    public private(set) var errorMessage: String? = nil
    public private(set) var lastActionMessage: String = "尚未载入设置"
    public private(set) var isBusy: Bool = false

    private let settingsStore = AppSettingsStore.shared
    private let healthKitService = DefaultHealthKitService()
    private let validator = RuleValidator()

    public init() {}

    public var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short)（\(build)）"
    }

    public var liquidGlassText: String {
        AppTheme.liquidGlassStatusText
    }

    public var minimumSystemText: String {
        "iOS 17.0"
    }

    /// 首次进入 / 下拉刷新：重载持久化设置并真实读取系统权限与存储占用。
    public func load() async {
        isBusy = true
        errorMessage = nil
        settingsStore.reload()
        apply(settingsStore.settings)
        await refreshPermissions()
        await loadPresets()
        storageText = AppServices.shared.storageUsageText()
        lastActionMessage = "设置已载入，外观与动态类型由根视图即时应用"
        isBusy = false
    }

    /// 持久化并提交当前全部设置；外观 / 动态类型 / Reduce Motion 通过根视图偏好即时生效。
    public func commitSettings() {
        let resolvedDynamicType = dynamicTypeSelection.flatMap {
            SettingsDynamicTypeOption(rawValue: $0)?.selectionValue
        }
        settingsStore.update { _ in
            AppSettings(
                unitSystem: unitSystem,
                paceFormat: paceFormat,
                appearance: appearance,
                dynamicTypeOverride: resolvedDynamicType,
                reduceMotion: reduceMotion,
                defaultSampleRateHz: defaultSampleRateHz,
                seedPolicy: seedPolicy,
                defaultNoiseAmplitude: defaultNoiseAmplitude,
                elevationDeadbandMeters: elevationDeadbandMeters,
                externalElevationEnabled: externalElevationEnabled,
                healthKitWriteEnabled: healthKitWriteEnabled
            )
        }
        apply(settingsStore.settings)
        lastActionMessage = "设置已写入本地并即时生效；运动记录量纲与来源不变"
    }

    public func setUnitSystem(_ value: UnitSystem) {
        unitSystem = value
        commitSettings()
    }

    public func setPaceFormat(_ value: PaceFormat) {
        paceFormat = value
        commitSettings()
    }

    public func setAppearance(_ value: AppearanceMode) {
        appearance = value
        commitSettings()
    }

    public func setDynamicType(_ value: String?) {
        dynamicTypeSelection = value
        commitSettings()
    }

    public func setReduceMotion(_ value: Bool) {
        reduceMotion = value
        commitSettings()
    }

    public func setSampleRate(_ value: Double) {
        defaultSampleRateHz = min(AppConstants.maximumSampleRateHz, max(0.5, value.isFinite ? value : 1))
        commitSettings()
    }

    public func setSeedPolicy(_ value: SeedPolicy) {
        seedPolicy = value
        commitSettings()
    }

    public func setNoiseAmplitude(_ value: Double) {
        defaultNoiseAmplitude = min(1, max(0, value.isFinite ? value : 0))
        commitSettings()
    }

    public func setElevationDeadband(_ value: Double) {
        elevationDeadbandMeters = min(50, max(0, value.isFinite ? value : AppConstants.elevationDeadbandMeters))
        commitSettings()
    }

    public func setExternalElevationEnabled(_ value: Bool) {
        externalElevationEnabled = value
        commitSettings()
        lastActionMessage = value
            ? "已显式开启外部高程来源同意标记；本期仍不发起联网请求"
            : "已关闭外部高程来源；路线页将使用自定义 / GPX / 设备来源"
    }

    /// 健康写入开关只对 REAL 生效，且真实记录结束页仍需要逐次显式勾选。
    public func setHealthKitWriteEnabled(_ value: Bool) {
        settingsStore.update { old in
            old.withHealthKitWriteEnabled(value, origin: .real)
        }
        apply(settingsStore.settings)
        lastActionMessage = healthKitWriteEnabled
            ? "已允许在真实记录结束页提供写入选项；每次仍需用户显式勾选"
            : "已关闭健康 App 写入偏好；测试数据永不写入健康 App"
    }

    public func setDefaultModelType(_ value: SpeedModelType) {
        defaultModelType = value
        persistSimulationExtras()
        lastActionMessage = "默认速度模型已设为 \(value.localizedDescription)，下次进入模拟器页生效"
    }

    public func setFixedSeed(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UInt64(trimmed) != nil else {
            errorMessage = AppError.seedMissing.errorDescription
            lastActionMessage = "固定种子必须是可解析的正整数，未写入偏好"
            return
        }
        fixedSeedText = trimmed
        persistSimulationExtras()
        errorMessage = nil
        lastActionMessage = "固定种子已写入本地偏好；仿真页按种子策略读取"
    }

    // MARK: 权限

    public func refreshPermissions() async {
        let locationProvider = CoreLocationProvider()
        let locationSnapshot = locationProvider.authorizationSnapshot
        let motionAvailability = CoreMotionProvider().availability()
        let healthSnapshot = await healthKitService.readStatus()

        let merged = PermissionSnapshot(
            locationStatus: locationSnapshot.locationStatus,
            preciseLocationEnabled: locationSnapshot.preciseLocationEnabled,
            motionStatus: motionAvailability.pedometerAvailable ? .authorizedWhenInUse : .unknown,
            healthKitReadStatus: healthSnapshot.healthKitReadStatus,
            healthKitShareStatus: healthSnapshot.healthKitShareStatus,
            backgroundDeliveryAvailable: healthSnapshot.backgroundDeliveryAvailable,
            capturedAt: Date(),
            note: "设置页权限自检；健康读取不可判定按「无数据」呈现"
        )
        permissionSummary = merged.summary
        locationStatusText = merged.locationStatus.localizedDescription
        preciseLocationText = merged.preciseLocationEnabled ? "已开启" : "未开启 / 受限"
        motionStatusText = motionAvailability.summary
        healthReadStatusText = merged.healthKitReadStatus == .unknown
            ? "无数据（Apple 隐私语义，不提示被拒绝）"
            : merged.healthKitReadStatus.localizedDescription
        healthWriteStatusText = merged.healthKitShareStatus.localizedDescription
        try? AppServices.shared.savePermissionState(PermissionState.from(snapshot: merged))
    }

    public func requestLocationAuthorization() async {
        let provider = CoreLocationProvider()
        provider.requestAuthorization()
        lastActionMessage = "已发出定位授权请求；若系统不再弹窗，请前往系统设置"
        await refreshPermissions()
    }

    public func requestHealthKitAuthorization() async {
        do {
            try await healthKitService.requestReadAuthorization()
            try await healthKitService.requestShareAuthorization()
            lastActionMessage = "健康数据读写授权请求已处理；读取状态仍按 Apple 隐私语义呈现"
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "健康授权未完成：\(error.localizedDescription)"
        }
        await refreshPermissions()
    }

    public func openSystemSettings() {
        AppServices.shared.openSystemSettings()
        lastActionMessage = "已打开系统设置，返回App后将重新自检权限"
    }

    // MARK: 数据管理

    public func clear(_ origin: DataOrigin) async {
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        isBusy = true
        do {
            try await repository.clear(origin: origin)
            storageText = AppServices.shared.storageUsageText()
            lastActionMessage = origin == .simulated
                ? "已仅清除测试数据分区；真实记录分区不受影响"
                : "已仅清除真实记录分区；测试数据分区不受影响"
            errorMessage = nil
            isBusy = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "清除失败：\(error.localizedDescription)"
            isBusy = false
        }
    }

    public func cancelClear() {
        lastActionMessage = "已取消清除操作，两类数据均未改动"
    }

    /// 按来源分别导出全部记录：每个文件单一来源、三重标记；绝不生成混合来源文件，也不上传。
    public func exportAll() async throws -> [URL] {
        guard let repository = AppServices.shared.repository else {
            throw AppError.persistenceMigrationFailed
        }
        var urls: [URL] = []
        for origin in [DataOrigin.simulated, DataOrigin.real] {
            let sessions = try await repository.fetch(origin: origin, predicate: RunPredicate())
            for session in sessions {
                let points = try await repository.points(sessionId: session.id)
                guard !points.isEmpty else { continue }
                let file = try await AppServices.shared.exporter.export(
                    session: session,
                    points: points,
                    format: exportFormat
                )
                urls.append(try file.writeToTemporaryDirectory())
            }
        }
        guard !urls.isEmpty else {
            throw AppError.exportFailed(reason: "两个分区都没有可导出的采样点记录")
        }
        lastActionMessage = "已按来源分别生成 \(urls.count) 个本地文件，可经系统分享面板保存"
        return urls
    }

    public func openHistory() {
        AppNavigation.shared.openHistory()
    }

    public func openLiveRun() {
        AppNavigation.shared.openLiveRun()
    }

    public func openSimulation() {
        AppNavigation.shared.openSimulation()
    }

    // MARK: 规则预设管理

    public func loadPresets() async {
        var merged = AppServices.shared.loadPresets()
        if let repository = AppServices.shared.repository {
            let remote = (try? await repository.presets()) ?? []
            merged = mergeByID(merged, remote)
        }
        if let presetStore = AppServices.shared.presetStore {
            let stored = await presetStore.list()
            merged = mergeByID(merged, stored)
        }
        presets = merged.sorted { $0.displayName < $1.displayName }
    }

    public func createPreset() async {
        guard let presetStore = AppServices.shared.presetStore else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            let preset = try validator.makePreset(
                displayName: presetName,
                comparisonGroup: comparisonGroup
            )
            try await presetStore.save(preset)
            await loadPresets()
            lastActionMessage = "已新建并保存假设规则预设「\(preset.displayName)」"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "预设创建失败：\(error.localizedDescription)"
        }
    }

    public func duplicatePreset(_ preset: RulePreset) async {
        guard let presetStore = AppServices.shared.presetStore else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            let copy = try await presetStore.duplicate(preset)
            await loadPresets()
            lastActionMessage = "已复制预设为「\(copy.displayName)」，isHypothetical 仍强制为 true"
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "预设复制失败：\(error.localizedDescription)"
        }
    }

    public func deletePreset(id: String) async {
        guard let presetStore = AppServices.shared.presetStore else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            try await presetStore.delete(id: id)
            await loadPresets()
            lastActionMessage = "已删除假设规则预设 \(id)"
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "预设删除失败：\(error.localizedDescription)"
        }
    }

    public func cancelPresetDelete() {
        lastActionMessage = "已取消预设删除，未改动任何假设规则"
    }

    public func importPreset(_ data: Data) async throws {
        guard let presetStore = AppServices.shared.presetStore else {
            throw AppError.persistenceMigrationFailed
        }
        let preset = try await presetStore.importJSON(data)
        await loadPresets()
        lastActionMessage = "已导入假设规则预设「\(preset.displayName)」；非假设值已被拒绝"
    }

    public func exportPreset(_ preset: RulePreset) async throws -> URL {
        guard let presetStore = AppServices.shared.presetStore else {
            throw AppError.persistenceMigrationFailed
        }
        let data = try await presetStore.exportJSON(preset)
        let fileName = "HYPOTHETICAL_PRESET_\(preset.id)_\(Date().utcFileNameStamp).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        lastActionMessage = "已生成预设 JSON：\(fileName)，含固定免责声明"
        return url
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
        lastActionMessage = "操作未完成：\(error.localizedDescription)"
    }

    // MARK: 私有实现

    private func apply(_ settings: AppSettings) {
        unitSystem = settings.unitSystem
        paceFormat = settings.paceFormat
        appearance = settings.appearance
        dynamicTypeSelection = settings.dynamicTypeOverride
        reduceMotion = settings.reduceMotion
        defaultSampleRateHz = settings.defaultSampleRateHz
        seedPolicy = settings.seedPolicy
        defaultNoiseAmplitude = settings.defaultNoiseAmplitude
        elevationDeadbandMeters = settings.elevationDeadbandMeters
        externalElevationEnabled = settings.externalElevationEnabled
        healthKitWriteEnabled = settings.healthKitWriteEnabled
        let defaults = UserDefaults.standard
        if let rawModel = defaults.string(forKey: AppPreferenceKey.defaultSpeedModel),
           let model = SpeedModelType(rawValue: rawModel) {
            defaultModelType = model
        } else {
            defaultModelType = .steady
        }
        fixedSeedText = defaults.string(forKey: AppPreferenceKey.defaultSeed) ?? "20261108"
    }

    private func persistSimulationExtras() {
        let defaults = UserDefaults.standard
        defaults.set(defaultModelType.rawValue, forKey: AppPreferenceKey.defaultSpeedModel)
        defaults.set(fixedSeedText, forKey: AppPreferenceKey.defaultSeed)
    }

    private func mergeByID<T: Identifiable>(_ primary: [T], _ secondary: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        var result: [T] = []
        for value in primary + secondary where seen.insert(value.id).inserted {
            result.append(value)
        }
        return result
    }
}

// MARK: - 设置页（F59）

/// 低版本 Liquid Glass 显示「已启用兼容外观」；所有按钮均绑定权限、持久化、导出或页面跳转真实动作。
@MainActor
public struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var vm = SettingsViewModel()
    @State private var showClearSimulated: Bool = false
    @State private var showClearReal: Bool = false
    @State private var showAbout: Bool = false
    @State private var showCompliance: Bool = false
    @State private var showReferences: Bool = false
    @State private var showPresetImporter: Bool = false
    @State private var showPresetDeleteConfirm: Bool = false
    @State private var pendingPresetDeleteID: String? = nil
    @State private var shareURLs: [URL] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                permissionSection
                unitsSection
                appearanceSection
                simulationDefaultsSection
                elevationSection
                dataManagementSection
                presetSection
                aboutSection
                errorSection
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle(AppRoute.settings.title)
        .refreshable { await vm.load() }
        .task { await vm.load() }
        .confirmationDialog("确认清除全部测试数据", isPresented: $showClearSimulated) {
            Button("仅清除测试数据", role: .destructive) {
                Task { await vm.clear(.simulated) }
            }
            Button("取消", role: .cancel) { vm.cancelClear() }
        } message: {
            Text("操作不可恢复。只清除 SIMULATED 容器的会话、采样点与导出审计；真实记录不受影响，配置类对象保留。")
        }
        .confirmationDialog("确认清除全部真实记录", isPresented: $showClearReal) {
            Button("仅清除真实记录", role: .destructive) {
                Task { await vm.clear(.real) }
            }
            Button("取消", role: .cancel) { vm.cancelClear() }
        } message: {
            Text("操作不可恢复。只清除 REAL 容器的会话、采样点与导出审计；测试数据不受影响，配置类对象保留。")
        }
        .confirmationDialog("删除假设规则预设", isPresented: $showPresetDeleteConfirm) {
            Button("确认删除", role: .destructive) {
                if let id = pendingPresetDeleteID {
                    Task { await vm.deletePreset(id: id) }
                }
                pendingPresetDeleteID = nil
            }
            Button("取消", role: .cancel) {
                pendingPresetDeleteID = nil
                vm.cancelPresetDelete()
            }
        } message: {
            Text("仅删除用户自建假设预设；不会删除任何运动记录，也不影响真实记录分区。")
        }
        .fileImporter(
            isPresented: $showPresetImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handlePresetImport(result)
        }
        .sheet(isPresented: $showAbout) { aboutSheet }
        .sheet(isPresented: $showCompliance) { complianceSheet }
        .sheet(isPresented: $showReferences) { referencesSheet }
        .sheet(isPresented: Binding(
            get: { !shareURLs.isEmpty },
            set: { if !$0 { shareURLs = [] } }
        )) {
            ShareSheet(items: shareURLs.map { $0 as Any }) { shareURLs = [] }
        }
    }

    // MARK: 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                OriginBadge(.simulated, style: .compact)
                OriginBadge(.real, style: .compact)
                Spacer(minLength: 2)
                if vm.isBusy {
                    ProgressView("正在读取权限与本地存储…")
                        .font(.caption)
                }
            }
            Text("权限、单位、外观、数据管理与合规说明")
                .font(.headline)
            Text(vm.lastActionMessage)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ComplianceBanner { showCompliance = true }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("权限状态")
                .font(.headline)
            permissionRow(title: "定位", status: vm.locationStatusText, actionTitle: "请求授权") {
                Task { await vm.requestLocationAuthorization() }
            }
            permissionRow(title: "精确位置", status: vm.preciseLocationText, actionTitle: "系统设置") {
                vm.openSystemSettings()
            }
            permissionRow(title: "运动传感器", status: vm.motionStatusText, actionTitle: "重新检测") {
                Task { await vm.refreshPermissions() }
            }
            permissionRow(title: "HealthKit 读取", status: vm.healthReadStatusText, actionTitle: "请求授权") {
                Task { await vm.requestHealthKitAuthorization() }
            }
            permissionRow(title: "HealthKit 写入", status: vm.healthWriteStatusText, actionTitle: "请求授权") {
                Task { await vm.requestHealthKitAuthorization() }
            }
            Text(vm.permissionSummary)
                .font(.caption2)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(
                get: { vm.healthKitWriteEnabled },
                set: { vm.setHealthKitWriteEnabled($0) }
            )) {
                Text("允许真实记录结束页提供健康 App 写入选项（默认关）")
                    .font(.caption)
            }
            Text("测试数据永不写入健康 App；即使开启本偏好，真实记录结束页仍需逐次显式勾选。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "重新自检", symbol: "arrow.clockwise") {
                    Task { await vm.refreshPermissions() }
                }
                ActionButton(title: "前往系统设置", symbol: "gearshape") { vm.openSystemSettings() }
                ActionButton(title: "前往实时运动", symbol: "figure.run") { vm.openLiveRun() }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private func permissionRow(title: String, status: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            Button(actionTitle) { action() }
                .font(.caption2)
                .buttonStyle(.bordered)
                .accessibilityLabel("\(title)：\(actionTitle)")
        }
    }

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("单位")
                .font(.headline)
            Picker("距离单位", selection: Binding(
                get: { vm.unitSystem },
                set: { vm.setUnitSystem($0) }
            )) {
                ForEach(UnitSystem.allCases, id: \.self) { unit in
                    Text(unit.localizedDescription).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            Picker("配速格式", selection: Binding(
                get: { vm.paceFormat },
                set: { vm.setPaceFormat($0) }
            )) {
                ForEach(PaceFormat.allCases, id: \.self) { format in
                    Text(format.localizedDescription).tag(format)
                }
            }
            .pickerStyle(.segmented)
            Text("内部量纲恒为 m / s / s·km⁻¹ / spm；单位偏好只影响展示，不改写落盘数据，不合并两类来源。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("外观与无障碍")
                .font(.headline)
            Picker("深浅色", selection: Binding(
                get: { vm.appearance },
                set: { vm.setAppearance($0) }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.localizedDescription).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Picker("动态类型", selection: Binding(
                get: { vm.dynamicTypeSelection },
                set: { vm.setDynamicType($0) }
            )) {
                ForEach(SettingsDynamicTypeOption.allCases) { option in
                    Text(option.localizedDescription).tag(option.selectionValue)
                }
            }
            .pickerStyle(.menu)
            Toggle(isOn: Binding(
                get: { vm.reduceMotion },
                set: { vm.setReduceMotion($0) }
            )) {
                Text("减少动态效果（回放改离散帧，玻璃形变关闭）")
                    .font(.caption)
            }
            Text("深浅色、动态类型与减少动态效果由根视图统一应用；来源徽标始终位于玻璃 / 材质层之上。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var simulationDefaultsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("仿真默认值")
                .font(.headline)
            Stepper(value: Binding(
                get: { vm.defaultSampleRateHz },
                set: { vm.setSampleRate($0) }
            ), in: 0.5...10, step: 0.5) {
                Text("默认采样率 \(AppTheme.metricNumberFormat(vm.defaultSampleRateHz, unit: "Hz", digits: 1))")
                    .font(.caption)
            }
            Picker("种子策略", selection: Binding(
                get: { vm.seedPolicy },
                set: { vm.setSeedPolicy($0) }
            )) {
                ForEach(SeedPolicy.allCases, id: \.self) { policy in
                    Text(policy.localizedDescription).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            TextField("固定种子", text: Binding(
                get: { vm.fixedSeedText },
                set: { vm.fixedSeedText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .keyboardType(.numberPad)
            .onSubmit { vm.setFixedSeed(vm.fixedSeedText) }
            .accessibilityLabel("固定随机种子输入")
            Stepper(value: Binding(
                get: { vm.defaultNoiseAmplitude },
                set: { vm.setNoiseAmplitude($0) }
            ), in: 0...0.2, step: 0.01) {
                Text("默认噪声幅度 \(AppTheme.metricNumberFormat(vm.defaultNoiseAmplitude, digits: 2))")
                    .font(.caption)
            }
            Stepper(value: Binding(
                get: { vm.elevationDeadbandMeters },
                set: { vm.setElevationDeadband($0) }
            ), in: 0...10, step: 0.5) {
                Text("高程死区 ε \(AppTheme.metricNumberFormat(vm.elevationDeadbandMeters, unit: "m", digits: 1))")
                    .font(.caption)
            }
            Picker("默认速度模型", selection: Binding(
                get: { vm.defaultModelType },
                set: { vm.setDefaultModelType($0) }
            )) {
                ForEach(SpeedModelType.allCases, id: \.self) { model in
                    Text(model.localizedDescription).tag(model)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "保存仿真默认值", symbol: "square.and.arrow.down", style: .prominent) {
                    vm.setFixedSeed(vm.fixedSeedText)
                    vm.commitSettings()
                }
                ActionButton(title: "前往模拟器", symbol: "testtube.2") { vm.openSimulation() }
            }
            Text("默认模型、种子、采样率、噪声幅度与 ε 会写入本地偏好；运动模拟器页载入时读取。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var elevationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("高程数据来源")
                .font(.headline)
            Toggle(isOn: Binding(
                get: { vm.externalElevationEnabled },
                set: { vm.setExternalElevationEnabled($0) }
            )) {
                Text("显式开启外部 DEM 同意标记（默认关）")
                    .font(.caption)
            }
            Text("本期不实现第三方 DEM 联网服务；开启只记录用户同意状态，路线页仍使用自定义 / GPX / 设备实测来源。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("若将来启用外部服务，必须先显示将发送的坐标范围并取得再次同意；当前版本不发送任何坐标。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var dataManagementSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("数据管理")
                .font(.headline)
            Text("测试数据与真实记录分别存储、不可互相转换；清除和导出均按来源独立执行。")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text("存储占用：\(vm.storageText)")
                .font(.subheadline.monospacedDigit())
            Picker("导出格式", selection: $vm.exportFormat) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.localizedDescription).tag(format)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "清除全部测试数据", symbol: "trash", style: .destructive) {
                    showClearSimulated = true
                }
                ActionButton(title: "清除全部真实记录", symbol: "trash", style: .destructive) {
                    showClearReal = true
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "分别导出全部数据", symbol: "square.and.arrow.up", style: .prominent) {
                    Task {
                        do { shareURLs = try await vm.exportAll() }
                        catch { vm.reportError(error) }
                    }
                }
                ActionButton(title: "查看历史记录", symbol: "clock.arrow.circlepath") { vm.openHistory() }
            }
            Text("导出全部数据会按来源分别生成多个本地文件，每个文件包含三重来源标记；不会生成混合来源文件，也不会上传。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("规则预设管理")
                .font(.headline)
            Text("所有预设强制 isHypothetical = true；仅用于用户自建假设规则差异对比，不还原任何平台规则。")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            TextField("预设名称", text: $vm.presetName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("假设规则预设名称")
            TextField("对比组", text: $vm.comparisonGroup)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("假设规则对比组")
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "新建假设预设", symbol: "plus", style: .prominent) {
                    Task { await vm.createPreset() }
                }
                ActionButton(title: "导入 JSON", symbol: "square.and.arrow.up") {
                    showPresetImporter = true
                }
            }
            if vm.presets.isEmpty {
                EmptyStateView(
                    origin: .simulated,
                    title: "尚无假设规则预设",
                    message: "创建或导入一个用户自建假设预设；JSON 中 isHypothetical=false 会被强制拒绝。",
                    actionTitle: "新建假设预设",
                    action: { Task { await vm.createPreset() } },
                    secondaryTitle: "导入 JSON",
                    secondaryAction: { showPresetImporter = true }
                )
            } else {
                ForEach(vm.presets) { preset in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            OriginBadge(.simulated, style: .compact)
                            Text(preset.displayName)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 2)
                        }
                        Text("对比组：\(preset.meta.comparisonGroup)｜假设值：\(preset.isHypothetical ? "是" : "否")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(preset.disclaimer)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Button("导出 JSON") {
                                Task {
                                    do { shareURLs = [try await vm.exportPreset(preset)] }
                                    catch { vm.reportError(error) }
                                }
                            }
                            Button("复制") { Task { await vm.duplicatePreset(preset) } }
                            Button("删除") {
                                pendingPresetDeleteID = preset.id
                                showPresetDeleteConfirm = true
                            }
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                    }
                    .padding(AppTheme.Spacing.sm)
                    .background(AppTheme.Colors.cardStroke(colorScheme).opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("关于与合规")
                .font(.headline)
            Text("版本：\(vm.appVersionText)｜最低支持系统：\(vm.minimumSystemText)")
                .font(.caption)
            Text("Liquid Glass：\(vm.liquidGlassText)")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "关于", symbol: "info.circle") { showAbout = true }
                ActionButton(title: "合规声明", symbol: "checkmark.shield") { showCompliance = true }
                ActionButton(title: "引用来源", symbol: "books.vertical") { showReferences = true }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = vm.errorMessage {
            ErrorStateView(
                origin: .simulated,
                error: AppError.parameterConflict(reason: message),
                primaryTitle: "重新载入",
                primaryAction: { Task { await vm.load() } },
                secondaryTitle: "系统设置",
                secondaryAction: { vm.openSystemSettings() }
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(AppConstants.complianceStatement)
                .font(.caption2)
            Text("低版本系统无官方 Liquid Glass 时显示「当前系统不支持，已启用兼容外观」，全部功能仍可使用。")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 弹层

    private var aboutSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("CampusRunSimulator")
                        .font(.largeTitle.bold())
                    Text("版本：\(vm.appVersionText)")
                    Text("最低支持系统：\(vm.minimumSystemText)")
                    Text("Liquid Glass：\(vm.liquidGlassText)")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("本 App 为教学研究 / 个人自用 / 数据分析工具；测试数据由 App 内独立数据源生成，不代表真实运动。")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        OriginBadge(.simulated, style: .full)
                        OriginBadge(.real, style: .full)
                    }
                    Text(AppConstants.simulationFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("关于")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showAbout = false }
                        .accessibilityLabel("关闭关于页")
                }
            }
        }
    }

    private var complianceSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(AppConstants.complianceStatement)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
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
                    Text("数据管理明确说明：测试数据与真实记录分别存储、不可互相转换；导出不混合来源，不上传任何平台。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("合规声明")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showCompliance = false }
                        .accessibilityLabel("关闭合规声明")
                }
            }
        }
    }

    private var referencesSheet: some View {
        NavigationStack {
            List(SettingsReferences.all) { reference in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(reference.title)
                        .font(.subheadline.weight(.medium))
                    Text(reference.evidence)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let url = reference.url {
                        Link(reference.urlText, destination: url)
                            .font(.caption2)
                            .lineLimit(2)
                    } else {
                        Text(reference.urlText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, AppTheme.Spacing.xs)
            }
            .navigationTitle("引用来源与证据分级")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showReferences = false }
                        .accessibilityLabel("关闭引用来源")
                }
            }
        }
    }

    // MARK: 文件导入

    private func handlePresetImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                vm.reportError(AppError.parameterConflict(reason: "未选择预设 JSON 文件"))
                return
            }
            let needsSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if needsSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                Task {
                    do { try await vm.importPreset(data) }
                    catch { vm.reportError(error) }
                }
            } catch {
                vm.reportError(error)
            }
        case .failure(let error):
            vm.reportError(error)
        }
    }
}
