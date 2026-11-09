import Foundation
import SwiftUI
import Observation
import MapKit
import UIKit

// MARK: - 仿真页视图模型（F55 / §B.6.3）

/// 全参数可编辑；`preview()` 调引擎预览，`validate()` 调 I1–I10 校验器，
/// `generate()` 在一致性失败时**拒绝生成**并高亮违规项，`saveProfile()` 真实持久化。
@MainActor
@Observable
public final class SimulationViewModel {

    // MARK: 可编辑参数（绑定真实控件）

    public var profileName: String = "示例假设配置 A"
    public var modelType: SpeedModelType = .steady
    public var targetCadenceSpm: Double = 168
    public var referenceStrideLengthM: Double = 1.05
    public var noiseAmplitude: Double = 0.02
    public var slopeInfluence: Double = 0.1
    public var sampleRateHz: Double = AppConstants.defaultSampleRateHz
    public var seedText: String = "20261108"
    public var totalDurationSeconds: Double = 960
    public var useDistanceTarget: Bool = false
    public var totalDistanceMeters: Double = 3_000
    public var initialAltitudeM: Double = 12
    public var biasM: Double = 0
    public var driftMPerSecond: Double = 0
    public var elevationNoiseAmplitudeM: Double = 0
    public var deadbandMeters: Double = AppConstants.elevationDeadbandMeters
    public var phases: [SimulationPhase] = SimulationProfile.makeDefault().phases
    public var customSamples: [CustomSpeedSample] = [
        CustomSpeedSample(timeSeconds: 0, speedMps: 2.2),
        CustomSpeedSample(timeSeconds: 300, speedMps: 2.8),
        CustomSpeedSample(timeSeconds: 600, speedMps: 2.4)
    ]
    public var selectedRouteId: String? = nil
    public var selectedPresetIds: Set<String> = []

    // MARK: 快速入口用的只读展示（route 名称与摘要）

    /// 当前选中路线的名称；未选中时返回 nil，由界面回退到「选择路线」。
    public var selectedRouteName: String? {
        guard let id = selectedRouteId else { return nil }
        return routes.first(where: { $0.id == id })?.name
    }

    /// 当前选中路线的摘要（距离 · 形状），用于快速入口副标题。
    public var selectedRouteSummary: String {
        guard let id = selectedRouteId,
              let route = routes.first(where: { $0.id == id }) else { return "" }
        return "\(Units.formatDistanceKm(route.totalDistanceM)) · \(route.routeType.localizedDescription)"
    }

    // MARK: 只读状态

    public private(set) var routes: [Route] = []
    public private(set) var profiles: [SimulationProfile] = []
    public private(set) var presets: [RulePreset] = []
    public private(set) var previewPoints: [TrackPoint] = []
    public private(set) var previewFrames: [SimulationFrame] = []
    public private(set) var invariantReport: InvariantReport? = nil
    public private(set) var failedInvariantIDs: [InvariantID] = []
    public private(set) var generatedSessionId: String? = nil
    public private(set) var generatedPoints: [TrackPoint] = []
    public private(set) var evaluationResults: [RuleEvaluationResult] = []
    public private(set) var evaluationText: String = ""
    public private(set) var errorMessage: String? = nil
    public private(set) var lastActionMessage: String = "尚未生成"
    public private(set) var isBusy: Bool = false
    public private(set) var effectiveSeed: UInt64? = nil

    private let engine = DefaultSimulationEngine()
    private let validator = InvariantValidator()
    private let evaluator = RuleEvaluator()
    private let analysisBuilder = AnalysisBuilder()
    private let seriesBuilder = SeriesBuilder()
    private var profileId: String = UUID().uuidString

    public init() {}

    // MARK: 载入

    /// 从真实持久化读取路线 / 模板 / 预设；无路线时提供可一键生成的示例假设路线。
    public func load() async {
        isBusy = true
        errorMessage = nil
        routes = AppServices.shared.loadRoutes()
        profiles = AppServices.shared.loadProfiles()
        presets = AppServices.shared.loadPresets()
        if let repository = AppServices.shared.repository {
            let remoteRoutes = (try? await repository.routes()) ?? []
            for route in remoteRoutes where !routes.contains(where: { $0.id == route.id }) {
                routes.append(route)
            }
            let remoteProfiles = (try? await repository.profiles()) ?? []
            for profile in remoteProfiles where !profiles.contains(where: { $0.id == profile.id }) {
                profiles.append(profile)
            }
            let remotePresets = (try? await repository.presets()) ?? []
            for preset in remotePresets where !presets.contains(where: { $0.id == preset.id }) {
                presets.append(preset)
            }
        }
        routes.sort { $0.updatedAt > $1.updatedAt }
        if selectedRouteId == nil { selectedRouteId = routes.first?.id }
        let settings = AppSettingsStore.shared.settings
        sampleRateHz = settings.defaultSampleRateHz
        noiseAmplitude = settings.defaultNoiseAmplitude
        deadbandMeters = settings.elevationDeadbandMeters
        let defaults = UserDefaults.standard
        if let rawModel = defaults.string(forKey: AppPreferenceKey.defaultSpeedModel),
           let model = SpeedModelType(rawValue: rawModel) {
            modelType = model
        }
        if settings.seedPolicy == .generateIfMissing {
            let storedSeed = defaults.string(forKey: AppPreferenceKey.defaultSeed)
            if let storedSeed, UInt64(storedSeed) != nil {
                seedText = storedSeed
            } else if UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                let generated = UInt64(max(1, Date().timeIntervalSince1970 * 1_000_000).rounded())
                seedText = String(generated)
                defaults.set(seedText, forKey: AppPreferenceKey.defaultSeed)
            }
        } else if let storedSeed = defaults.string(forKey: AppPreferenceKey.defaultSeed),
                  UInt64(storedSeed) != nil {
            seedText = storedSeed
        }
        isBusy = false
        if let profileId = AppNavigation.shared.consumeSelectedProfileID(),
           let template = profiles.first(where: { $0.id == profileId }) {
            apply(template: template)
        }
    }

    /// 生成一条可立即用于仿真的示例假设环线（真实构造，明确标注为假设值）。
    public func makeSampleRoute() {
        do {
            let id = UUID().uuidString
            let coordinates: [GeoPoint] = [
                GeoPoint(latitude: 31.2300, longitude: 121.4700),
                GeoPoint(latitude: 31.2318, longitude: 121.4704),
                GeoPoint(latitude: 31.2322, longitude: 121.4728),
                GeoPoint(latitude: 31.2302, longitude: 121.4726),
                GeoPoint(latitude: 31.2300, longitude: 121.4700)
            ]
            let points = coordinates.enumerated().map { index, point in
                RoutePoint(orderIndex: index, latitude: point.latitude, longitude: point.longitude)
            }
            let profile = ElevationProfile(
                routeId: id,
                initialAltitudeM: initialAltitudeM,
                segments: [],
                source: .userDefined,
                errorModel: currentErrorModel()
            )
            let draft = Route(
                id: id,
                name: "校园示例环线（假设值）",
                routeType: .loop,
                points: points,
                elevationProfile: profile,
                currentVersionId: "\(id)_v1",
                elevationSource: .userDefined
            )
            let length = RouteArcLength(route: draft).totalLength()
            let route = Route(
                id: id,
                name: draft.name,
                routeType: .loop,
                totalDistanceM: length,
                points: points,
                elevationProfile: profile,
                versions: [],
                currentVersionId: "\(id)_v1",
                elevationSource: .userDefined
            )
            try AppServices.shared.saveRoute(route)
            routes = AppServices.shared.loadRoutes().sorted { $0.updatedAt > $1.updatedAt }
            selectedRouteId = id
            errorMessage = nil
            lastActionMessage = "已生成示例假设环线：\(Units.formatDistanceKm(length))"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func apply(template: SimulationProfile) {
        profileId = template.id
        profileName = template.name
        modelType = template.modelType
        phases = template.phases
        targetCadenceSpm = template.targetCadenceSpm
        referenceStrideLengthM = template.referenceStrideLengthM
        noiseAmplitude = template.noiseAmplitude
        slopeInfluence = template.slopeInfluence
        sampleRateHz = template.sampleRateHz
        seedText = String(template.seed)
        totalDurationSeconds = template.totalDurationSeconds ?? 960
        useDistanceTarget = template.totalDurationSeconds == nil
        totalDistanceMeters = template.totalDistanceMeters ?? 3_000
        customSamples = template.customCurve?.samples ?? customSamples
        lastActionMessage = "已载入模板「\(template.name)」"
    }

    public func selectRoute(_ route: Route) {
        selectedRouteId = route.id
        lastActionMessage = "已选择路线「\(route.name)」"
    }

    // MARK: 参数构造

    /// 由当前全部可编辑控件构造冻结的 `SimulationProfile`（`dataOrigin` 由初始化器强制 `.simulated`）。
    public func makeProfile() throws -> SimulationProfile {
        guard let seed = UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)),
              seed > 0 else {
            throw AppError.seedMissing
        }
        guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.parameterConflict(reason: "请填写仿真模板名称")
        }
        let curve: CustomSpeedCurve? = modelType == .custom
            ? CustomSpeedCurve(samples: customSamples) : nil
        return SimulationProfile(
            id: profileId,
            name: profileName,
            modelType: modelType,
            phases: phases,
            targetCadenceSpm: targetCadenceSpm,
            referenceStrideLengthM: referenceStrideLengthM,
            noiseAmplitude: noiseAmplitude,
            slopeInfluence: slopeInfluence,
            sampleRateHz: sampleRateHz,
            seed: seed,
            totalDurationSeconds: useDistanceTarget ? nil : totalDurationSeconds,
            totalDistanceMeters: useDistanceTarget ? totalDistanceMeters : nil,
            customCurve: curve
        )
    }

    /// 当前选中路线；若无路线则按选中的路线数据重建带自定义海拔误差模型的副本。
    public func makeRoute() throws -> Route {
        guard let id = selectedRouteId, let route = routes.first(where: { $0.id == id }) else {
            throw AppError.parameterConflict(reason: "请先选择或生成一条至少含 2 个点的路线")
        }
        let profile = ElevationProfile(
            routeId: route.id,
            initialAltitudeM: initialAltitudeM,
            segments: route.elevationProfile.segments,
            source: route.elevationSource,
            errorModel: currentErrorModel()
        )
        return Route(
            id: route.id,
            name: route.name,
            routeType: route.routeType,
            totalDistanceM: route.totalDistanceM,
            points: route.points,
            waypoints: route.waypoints,
            elevationProfile: profile,
            versions: route.versions,
            currentVersionId: route.currentVersionId,
            elevationSource: route.elevationSource,
            externalServiceAttribution: route.externalServiceAttribution,
            createdAt: route.createdAt,
            updatedAt: route.updatedAt
        )
    }

    // MARK: 预览 / 校验 / 生成

    /// 预览：调 `DefaultSimulationEngine.preview`，产出真实 `[SimulationFrame]` 并转换为轨迹点。
    public func preview() async {
        isBusy = true
        errorMessage = nil
        do {
            let profile = try makeProfile()
            let route = try makeRoute()
            let frames = try await engine.preview(profile: profile, route: route)
            guard !frames.isEmpty else {
                throw AppError.parameterConflict(reason: "预览未产生采样帧，请检查时长与采样率")
            }
            previewFrames = frames
            previewPoints = frames.map {
                $0.trackPoint(sessionId: "sim_preview_\(profile.seed)", startTime: Date())
            }
            failedInvariantIDs = []
            lastActionMessage = "预览完成：\(frames.count) 帧，\(Units.formatDistanceKm(previewPoints.last?.cumulativeDistanceM ?? 0))"
            isBusy = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "预览失败：\(error.localizedDescription)"
            isBusy = false
        }
    }

    /// 一致性校验：调 `InvariantValidator` 逐项显示 I1–I10，不落盘。
    public func validate() async {
        isBusy = true
        errorMessage = nil
        do {
            let profile = try makeProfile()
            let route = try makeRoute()
            let frames = try await engine.preview(profile: profile, route: route)
            let points = frames.map {
                $0.trackPoint(sessionId: "sim_validate_\(profile.seed)", startTime: Date())
            }
            let session = Self.makeSession(from: points, profile: profile, route: route)
            let report = validator.validate(session: session, points: points, profile: profile)
            invariantReport = report
            failedInvariantIDs = report.failedIDs
            lastActionMessage = report.allPassed
                ? "I1–I10 全部通过" : "一致性校验未通过：\(report.failedIDs.map(\.rawValue).joined(separator: "、"))"
            isBusy = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "校验失败：\(error.localizedDescription)"
            isBusy = false
        }
    }

    /// 生成并保存：一致性失败**拒绝生成**（不落盘）并高亮违规项。
    public func generate() async {
        isBusy = true
        errorMessage = nil
        do {
            let profile = try makeProfile()
            let route = try makeRoute()
            let outcome = await engine.outcome(for: profile, route: route)
            switch outcome {
            case .accepted(let result, let seed):
                guard let repository = AppServices.shared.repository else {
                    throw AppError.persistenceMigrationFailed
                }
                try await repository.save(result.session, points: result.points)
                generatedSessionId = result.session.id
                generatedPoints = result.points
                previewPoints = result.points
                invariantReport = result.report
                failedInvariantIDs = []
                effectiveSeed = seed
                if seed != profile.seed { seedText = String(seed) }
                lastActionMessage = "已生成并保存 \(result.points.count) 点测试数据（SIMULATED 分区）"
            case .rejected(let error, let failed):
                // 失败即拒绝：不写仓库、不导出、不产生任何可当作成绩的数据。
                generatedSessionId = nil
                generatedPoints = []
                failedInvariantIDs = failed
                invariantReport = nil
                errorMessage = error.localizedDescription
                lastActionMessage = "已拒绝生成：\(error.localizedDescription)"
            }
            isBusy = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "生成失败：\(error.localizedDescription)"
            isBusy = false
        }
    }

    /// 保存为 `SimulationProfile` 模板（真实写入 simulated 容器）。
    public func saveProfile() {
        do {
            let profile = try makeProfile()
            try AppServices.shared.saveProfile(profile)
            profiles = AppServices.shared.loadProfiles()
            errorMessage = nil
            lastActionMessage = "已保存仿真模板「\(profile.name)」"
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "模板保存失败：\(error.localizedDescription)"
        }
    }

    /// 按当前规则预评估：调 `RuleEvaluator`，附固定免责声明与「评估对象：测试数据」。
    public func evaluateRules() async {
        isBusy = true
        do {
            let profile = try makeProfile()
            let route = try makeRoute()
            let points: [TrackPoint]
            if !generatedPoints.isEmpty {
                points = generatedPoints
            } else if !previewPoints.isEmpty {
                points = previewPoints
            } else {
                let frames = try await engine.preview(profile: profile, route: route)
                points = frames.map {
                    $0.trackPoint(sessionId: "sim_evaluate_\(profile.seed)", startTime: Date())
                }
                previewPoints = points
            }
            let session = Self.makeSession(from: points, profile: profile, route: route)
            let selected = presets.filter { selectedPresetIds.contains($0.id) }
            let results = evaluator.evaluate(session: session, points: points, presets: selected)
            evaluationResults = results
            if results.isEmpty {
                evaluationText = selected.isEmpty
                    ? "请先在设置页创建或选择至少一个用户自建假设规则预设。"
                    : "真实记录不参与假设规则评估；当前评估对象不是测试数据 / SIMULATED。"
            } else {
                evaluationText = results.map { analysisBuilder.ruleEvaluationText($0) }
                    .joined(separator: "\n\n——— 下一个预设 ———\n\n")
            }
            lastActionMessage = "本地模拟预评估完成：\(results.count) 份假设预设"
            isBusy = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "预评估失败：\(error.localizedDescription)"
            isBusy = false
        }
    }

    public func series(for points: [TrackPoint], axis: ChartAxis, tier: DownsamplingTier) -> [MetricSeries] {
        seriesBuilder.build(points, axis: axis, downsampling: tier)
    }

    public func openRoutePlanning() {
        AppNavigation.shared.openRoutePlanning(routeId: selectedRouteId)
    }

    public func openAnalytics() {
        AppNavigation.shared.openAnalytics(sessionId: generatedSessionId)
    }

    public func openHistory() {
        AppNavigation.shared.openHistory()
    }

    public func openSettings() {
        AppNavigation.shared.openSettings()
    }

    public func setPhaseDuration(_ index: Int, _ value: Double) {
        guard phases.indices.contains(index) else { return }
        let old = phases[index]
        phases[index] = SimulationPhase(
            id: old.id, kind: old.kind,
            durationSeconds: max(1, value),
            speedFromMps: old.speedFromMps, speedToMps: old.speedToMps,
            cadenceFromSpm: old.cadenceFromSpm, cadenceToSpm: old.cadenceToSpm,
            transitionSeconds: old.transitionSeconds
        )
    }

    public func setPhaseSpeed(_ index: Int, target: Double) {
        guard phases.indices.contains(index) else { return }
        let old = phases[index]
        phases[index] = SimulationPhase(
            id: old.id, kind: old.kind,
            durationSeconds: old.durationSeconds,
            speedFromMps: max(0, target), speedToMps: max(0, target),
            cadenceFromSpm: old.cadenceFromSpm, cadenceToSpm: old.cadenceToSpm,
            transitionSeconds: old.transitionSeconds
        )
    }

    public func addCustomSample() {
        let lastTime = customSamples.last?.timeSeconds ?? 0
        customSamples.append(CustomSpeedSample(timeSeconds: lastTime + 60, speedMps: 2.5))
    }

    public func setCustomSampleSpeed(_ index: Int, _ value: Double) {
        guard customSamples.indices.contains(index) else { return }
        let old = customSamples[index]
        customSamples[index] = CustomSpeedSample(timeSeconds: old.timeSeconds, speedMps: max(0, value))
    }

    public func removeCustomSample(at index: Int) {
        guard customSamples.indices.contains(index), customSamples.count > 2 else { return }
        customSamples.remove(at: index)
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
        lastActionMessage = "操作未完成：\(error.localizedDescription)"
    }

    // MARK: 私有实现

    private func currentErrorModel() -> ElevationErrorModel {
        ElevationErrorModel(
            biasM: biasM,
            driftMPerSecond: driftMPerSecond,
            noiseAmplitudeM: elevationNoiseAmplitudeM,
            deadbandMeters: deadbandMeters
        )
    }

    /// 由预览 / 生成点构造一个内存中的 SIMULATED 会话（不落盘），供 I1–I10 与规则评估使用。
    private static func makeSession(
        from points: [TrackPoint],
        profile: SimulationProfile,
        route: Route
    ) -> RunSession {
        let last = points.last
        let startTime = Date(timeIntervalSince1970: 1_767_225_600)
        let duration = last?.elapsedSeconds ?? 0
        let distance = last?.cumulativeDistanceM ?? 0
        return RunSession(
            id: OriginID.makeID(.simulated, suffix: "in_memory_\(profile.seed)"),
            dataOrigin: .simulated,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(duration),
            durationSeconds: duration,
            totalDistanceMeters: distance,
            avgSpeedMps: duration > 0 ? distance / duration : 0,
            avgPaceSecPerKm: Units.averagePaceSecPerKm(totalSeconds: duration, totalMeters: distance),
            totalSteps: last?.cumulativeSteps ?? 0,
            elevationGainM: last?.elevationGainSoFarM ?? 0,
            elevationLossM: last?.elevationLossSoFarM ?? 0,
            routeId: route.id,
            simulationProfileId: profile.id,
            note: "示例假设配置的本地模拟评估，不落盘、不产生成绩"
        )
    }
}

// MARK: - 运动模拟器页（F55）

/// 页顶常驻「测试数据 / SIMULATED」，页脚固定合规文案；全参数可编辑、无假按钮。
@MainActor
public struct SimulationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var vm = SimulationViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var axis: ChartAxis = .time
    @State private var tier: DownsamplingTier = .medium
    @State private var cursorSourceIndex: Int = 0
    @State private var showReplay: Bool = false
    @State private var showEvaluation: Bool = false
    @State private var showAdvanced: Bool = false
    @State private var showPhases: Bool = false
    /// 详细参数折叠区（v0.1.7 默认收起，一屏只留三个核心滑杆）。
    @State private var showAdvancedParameters: Bool = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                quickStartCard
                actionSection
                invariantSection
                previewSection
                navigationSection
                advancedParameters
                footer
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("仿真")
        .navigationBarTitleDisplayMode(.large)
        .task { await vm.load() }
        .sheet(isPresented: $showReplay) {
            if let sessionId = vm.generatedSessionId {
                ReplayView(
                    sessionId: sessionId,
                    previewPoints: vm.generatedPoints.isEmpty ? nil : vm.generatedPoints,
                    previewOrigin: .simulated
                )
            } else {
                ReplayView(
                    sessionId: "预览_\(vm.seedText)",
                    previewPoints: vm.previewPoints,
                    previewOrigin: .simulated
                )
            }
        }
        .sheet(isPresented: $showEvaluation) { evaluationSheet }
    }

    // MARK: 三步快速生成（v0.1.7 图形化入口）

    /// 一屏完成「选路线 → 调三个值 → 生成」，其余参数全部收进下方折叠区。
    private var quickStartCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            StepIndicator(steps: ["选路线", "定强度", "出数据"], current: vm.routes.isEmpty ? 0 : (vm.previewPoints.isEmpty ? 1 : 2))

            // 第 1 步：路线
            if vm.routes.isEmpty {
                Button {
                    vm.makeSampleRoute()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("生成一条示例校园环线")
                                .font(.subheadline.weight(.semibold))
                            Text("需要一条闭环路线才能做弧长参数化")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .padding(AppTheme.Spacing.md)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.medium, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.medium, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(vm.routes) { route in
                        Button {
                            vm.selectRoute(route)
                        } label: {
                            Text("\(route.name) · \(Units.formatDistanceKm(route.totalDistanceM))")
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "map.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vm.selectedRouteName ?? "选择路线")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(vm.selectedRouteSummary.isEmpty ? "点按切换路线" : vm.selectedRouteSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(AppTheme.Spacing.sm)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.medium, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.medium, style: .continuous))
                }
                .accessibilityLabel("选择仿真路线")
            }

            Divider()

            // 第 2 步：三个核心值（滑杆，实时显示派生配速）
            VStack(alignment: .leading, spacing: 10) {
                sliderRow(
                    title: "步频",
                    value: "\(Int(vm.targetCadenceSpm.rounded())) spm",
                    binding: Binding(
                        get: { vm.targetCadenceSpm },
                        set: { vm.targetCadenceSpm = $0 }
                    ),
                    range: 120...200,
                    step: 1
                )
                sliderRow(
                    title: "步幅",
                    value: String(format: "%.2f m", vm.referenceStrideLengthM),
                    binding: Binding(
                        get: { vm.referenceStrideLengthM },
                        set: { vm.referenceStrideLengthM = $0 }
                    ),
                    range: 0.60...1.80,
                    step: 0.01
                )

                HStack(spacing: 10) {
                    Toggle(isOn: $vm.useDistanceTarget) {
                        Text("按距离")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text(vm.useDistanceTarget ? "目标距离" : "总时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(vm.useDistanceTarget
                         ? Units.formatDistanceKm(vm.totalDistanceMeters)
                         : Units.formatDuration(vm.totalDurationSeconds))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if vm.useDistanceTarget {
                    Slider(value: $vm.totalDistanceMeters, in: 1_000...21_000, step: 500)
                        .accessibilityLabel("目标距离")
                } else {
                    Slider(value: $vm.totalDurationSeconds, in: 300...7_200, step: 60)
                        .accessibilityLabel("总时长")
                }
            }

            // 派生配速：完全由步频 × 步幅推出，不是独立随机量
            HStack(spacing: AppTheme.Spacing.sm) {
                RingProgressView(
                    progress: derivedSpeedMps / 6.0,
                    centerValue: derivedPaceText,
                    centerUnit: "",
                    caption: "预计配速 /km",
                    tint: Color(red: 0.38, green: 0.32, blue: 0.78)
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("配速由步频 × 步幅推出")
                        .font(.caption.weight(.semibold))
                    Text("速度 = 步频 ÷ 60 × 步幅，配速 = 1000 ÷ 速度。改上面两个滑杆，这里会立刻变化。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(vm.lastActionMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // 第 3 步：一键生成
            Button {
                Task { await vm.generate() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vm.isBusy ? "hourglass" : "wand.and.stars")
                        .font(.headline)
                    Text(vm.isBusy ? "正在生成…" : "一键生成仿真数据")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.38, green: 0.32, blue: 0.78), Color(red: 0.22, green: 0.48, blue: 0.86)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.large, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(vm.isBusy || vm.routes.isEmpty)

            PrivacyNote("生成的数据全部标记为 SIMULATED，只存本机，不会写入健康 App，也不代表真实运动。")
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    /// 带标题与数值的滑杆行。
    private func sliderRow(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Slider(value: binding, in: range, step: step)
                .accessibilityLabel(Text(title))
        }
    }

    /// 由步频与步幅推出的速度（m/s），与引擎使用的 L = 60·v/c 同一口径。
    private var derivedSpeedMps: Double {
        guard vm.referenceStrideLengthM > 0 else { return 0 }
        return vm.targetCadenceSpm / 60 * vm.referenceStrideLengthM
    }

    private var derivedPaceSecPerKm: Double {
        guard derivedSpeedMps > 0 else { return 0 }
        return 1_000 / derivedSpeedMps
    }

    /// 环形中心只放 "5'30\"" 这样的短文本（去掉 /km 后缀，后缀放在 caption）。
    private var derivedPaceText: String {
        let full = Units.formatPaceMinPerKm(derivedPaceSecPerKm)
        return full.replacingOccurrences(of: "/km", with: "")
    }

    /// 高级参数折叠区：保留原有全部真实控件，只是默认收起。
    private var advancedParameters: some View {
        DisclosureGroup(isExpanded: $showAdvancedParameters) {
            VStack(spacing: AppTheme.Spacing.md) {
                complianceHeader
                routeSection
                modelSection
                coreParameters
                phaseSection
                customCurveSection
                advancedSection
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("详细参数")
                        .font(.headline)
                    Text("路线 / 速度模型 / 五阶段 / 海拔误差（默认值即可直接用）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    // MARK: 区块

    private var complianceHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                OriginBadge(.simulated, style: .full)
                Spacer(minLength: 2)
                Text("本地模拟研究")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
            }
            Text("全部参数为示例假设值；生成的数据集仅用于本地一致性与数据分析研究")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(vm.lastActionMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("① 选择路线")
                .font(.headline)
            if vm.routes.isEmpty {
                EmptyStateView(
                    origin: .simulated,
                    title: "还没有可用路线",
                    message: "仿真需要至少 2 个有序点做弧长参数化。可生成一条示例假设环线，或前往路线规划页自行绘制。",
                    actionTitle: "生成示例假设路线",
                    action: { vm.makeSampleRoute() },
                    secondaryTitle: "前往路线规划",
                    secondaryAction: { vm.openRoutePlanning() }
                )
            } else {
                Picker("路线", selection: Binding(
                    get: { vm.selectedRouteId ?? "" },
                    set: { newValue in
                        if let route = vm.routes.first(where: { $0.id == newValue }) {
                            vm.selectRoute(route)
                        }
                    }
                )) {
                    ForEach(vm.routes) { route in
                        Text("\(route.name) · \(Units.formatDistanceKm(route.totalDistanceM))")
                            .tag(route.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("选择仿真使用的路线")
                ActionButton(title: "生成示例假设路线", symbol: "plus.map", style: .bordered) {
                    vm.makeSampleRoute()
                }
            }
            if !vm.profiles.isEmpty {
                Picker("仿真模板", selection: Binding(
                    get: { "" },
                    set: { newValue in
                        if let template = vm.profiles.first(where: { $0.id == newValue }) {
                            vm.apply(template: template)
                        }
                    }
                )) {
                    Text("选择已保存模板").tag("")
                    ForEach(vm.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("② 速度模型（6 种）")
                .font(.headline)
            Picker("速度模型", selection: $vm.modelType) {
                ForEach(SpeedModelType.allCases, id: \.self) { type in
                    Text(type.localizedDescription).tag(type)
                }
            }
            .pickerStyle(.segmented)
            TextField("模板名称", text: $vm.profileName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("仿真模板名称")
            Text("自定义曲线模型下可逐点编辑速度采样；其余模型由阶段调度与坡度反馈确定性生成")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var coreParameters: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("③ 主干参数")
                .font(.headline)
            Group {
                Stepper(value: $vm.targetCadenceSpm, in: 60...240, step: 1) {
                    Text("目标步频 \(AppTheme.metricNumberFormat(vm.targetCadenceSpm, unit: "spm", digits: 0))")
                        .font(.caption)
                }
                Stepper(value: $vm.referenceStrideLengthM, in: 0.4...2.2, step: 0.01) {
                    Text("参考步幅 \(AppTheme.metricNumberFormat(vm.referenceStrideLengthM, unit: "m", digits: 2))")
                        .font(.caption)
                }
                Stepper(value: $vm.noiseAmplitude, in: 0...0.2, step: 0.005) {
                    Text("时间相关噪声幅度 \(AppTheme.metricNumberFormat(vm.noiseAmplitude, digits: 3))")
                        .font(.caption)
                }
                Stepper(value: $vm.slopeInfluence, in: 0...0.5, step: 0.01) {
                    Text("坡度影响系数 \(AppTheme.metricNumberFormat(vm.slopeInfluence, digits: 2))")
                        .font(.caption)
                }
                Stepper(value: $vm.sampleRateHz, in: 0.2...10, step: 0.2) {
                    Text("采样率 \(AppTheme.metricNumberFormat(vm.sampleRateHz, unit: "Hz", digits: 1))")
                        .font(.caption)
                }
                TextField("随机种子（正整数）", text: $vm.seedText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("随机种子输入框")
                Toggle("按总距离生成（否则按总时长）", isOn: $vm.useDistanceTarget)
                    .font(.caption)
                if vm.useDistanceTarget {
                    Stepper(value: $vm.totalDistanceMeters, in: 500...42_195, step: 100) {
                        Text("目标距离 \(Units.formatDistanceKm(vm.totalDistanceMeters))").font(.caption)
                    }
                } else {
                    Stepper(value: $vm.totalDurationSeconds, in: 60...7_200, step: 30) {
                        Text("总时长 \(Units.formatDuration(vm.totalDurationSeconds))").font(.caption)
                    }
                }
            }
            Text("步幅由 L = 60·v/c 派生，不独立随机；全部派生量来自 6 个主干量 + 单一种子")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var phaseSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("④ 五阶段连续过渡（\(vm.phases.count) 段）")
                    .font(.headline)
                Spacer(minLength: 2)
                Button(showPhases ? "收起" : "展开") { showPhases.toggle() }
                    .font(.caption)
            }
            if showPhases {
                ForEach(vm.phases.indices, id: \.self) { index in
                    let phase = vm.phases[index]
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(phase.kind.localizedDescription)｜过渡 \(AppTheme.metricNumberFormat(phase.transitionSeconds, unit: "s", digits: 0))")
                            .font(.caption.weight(.medium))
                        Stepper(value: Binding(
                            get: { vm.phases[index].durationSeconds },
                            set: { vm.setPhaseDuration(index, $0) }
                        ), in: 10...3_600, step: 10) {
                            Text("时长 \(Units.formatDuration(vm.phases[index].durationSeconds))")
                                .font(.caption2)
                        }
                        Stepper(value: Binding(
                            get: { vm.phases[index].speedToMps },
                            set: { vm.setPhaseSpeed(index, target: $0) }
                        ), in: 0.5...8, step: 0.1) {
                            Text("目标速度 \(AppTheme.metricNumberFormat(vm.phases[index].speedToMps, unit: "m/s", digits: 1))")
                                .font(.caption2)
                        }
                    }
                    .padding(AppTheme.Spacing.xs)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    @ViewBuilder
    private var customCurveSection: some View {
        if vm.modelType == .custom {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("⑤ 自定义速度曲线（时间严格递增，端点钳制，不外推）")
                    .font(.headline)
                ForEach(vm.customSamples.indices, id: \.self) { index in
                    let sample = vm.customSamples[index]
                    HStack {
                        Text("t=\(AppTheme.metricNumberFormat(sample.timeSeconds, unit: "s", digits: 0))")
                            .font(.caption.monospacedDigit())
                        Stepper(value: Binding(
                            get: { vm.customSamples[index].speedMps },
                            set: { vm.setCustomSampleSpeed(index, $0) }
                        ), in: 0...8, step: 0.1) {
                            Text(AppTheme.metricNumberFormat(vm.customSamples[index].speedMps, unit: "m/s", digits: 1))
                                .font(.caption)
                        }
                        Button("删除") { vm.removeCustomSample(at: index) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
                ActionButton(title: "追加曲线采样点", symbol: "plus", style: .bordered) {
                    vm.addCustomSample()
                }
            }
            .padding(AppTheme.Spacing.md)
            .glassCard(role: .card, interactive: true)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("⑥ 初始海拔与误差模型（示例假设值）")
                    .font(.headline)
                Spacer(minLength: 2)
                Button(showAdvanced ? "收起" : "展开") { showAdvanced.toggle() }
                    .font(.caption)
            }
            if showAdvanced {
                Stepper(value: $vm.initialAltitudeM, in: -200...4_000, step: 1) {
                    Text("初始海拔 h0 \(AppTheme.metricNumberFormat(vm.initialAltitudeM, unit: "m", digits: 0))")
                        .font(.caption)
                }
                Stepper(value: $vm.biasM, in: -20...20, step: 0.5) {
                    Text("偏置 \(AppTheme.metricNumberFormat(vm.biasM, unit: "m", digits: 1))").font(.caption)
                }
                Stepper(value: $vm.driftMPerSecond, in: -0.1...0.1, step: 0.005) {
                    Text("漂移 \(AppTheme.metricNumberFormat(vm.driftMPerSecond, unit: "m/s", digits: 3))").font(.caption)
                }
                Stepper(value: $vm.elevationNoiseAmplitudeM, in: 0...5, step: 0.1) {
                    Text("噪声幅度 \(AppTheme.metricNumberFormat(vm.elevationNoiseAmplitudeM, unit: "m", digits: 1))").font(.caption)
                }
                Stepper(value: $vm.deadbandMeters, in: 0...10, step: 0.5) {
                    Text("爬升死区 ε \(AppTheme.metricNumberFormat(vm.deadbandMeters, unit: "m", digits: 1))").font(.caption)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("⑦ 生成与保存")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.sm)],
                spacing: AppTheme.Spacing.sm
            ) {
                ActionButton(title: "预览", symbol: "eye", isDisabled: vm.isBusy) {
                    Task { await vm.preview() }
                }
                ActionButton(title: "一致性校验", symbol: "checkmark.shield", isDisabled: vm.isBusy) {
                    Task { await vm.validate() }
                }
                ActionButton(title: "生成并保存", symbol: "square.and.arrow.down", style: .prominent, isDisabled: vm.isBusy) {
                    Task { await vm.generate() }
                }
                ActionButton(title: "保存模板", symbol: "doc.badge.plus", isDisabled: vm.isBusy) {
                    vm.saveProfile()
                }
                ActionButton(title: "按当前规则预评估", symbol: "list.bullet.rectangle", isDisabled: vm.isBusy) {
                    Task { await vm.evaluateRules(); showEvaluation = true }
                }
                ActionButton(title: "进入回放", symbol: "play.circle", isDisabled: vm.previewPoints.isEmpty) {
                    showReplay = true
                }
            }
            if vm.isBusy { ProgressView("正在确定性生成与校验…").font(.caption) }
            if let message = vm.errorMessage {
                ErrorStateView(
                    origin: .simulated,
                    error: AppError.parameterConflict(reason: message),
                    primaryTitle: "重新校验",
                    primaryAction: { Task { await vm.validate() } },
                    secondaryTitle: "修改路线",
                    secondaryAction: { vm.openRoutePlanning() }
                )
            }
            if let effectiveSeed = vm.effectiveSeed {
                Text("引擎实际使用种子：\(effectiveSeed)（已回写以保持可复现）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    /// I1–I10 逐项结果；失败项高亮并给出明确拒绝原因。
    private var invariantSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("I1–I10 一致性报告")
                .font(.headline)
            if let report = vm.invariantReport {
                Text(report.allPassed ? "全部通过，可生成测试数据" : "存在未通过项，已拒绝生成")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(report.allPassed ? .green : .red)
                ForEach(report.checks, id: \.id.rawValue) { check in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(check.id.rawValue) \(check.id.localizedDescription)")
                                .font(.caption.weight(check.passed ? .regular : .semibold))
                            Text(check.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                    }
                    .padding(.vertical, 2)
                    .background(vm.failedInvariantIDs.contains(check.id)
                                ? Color.red.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            } else if !vm.failedInvariantIDs.isEmpty {
                Text("违规项：\(vm.failedInvariantIDs.map(\.rawValue).joined(separator: "、"))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text("按架构 §7.7，一致性失败时拒绝生成，不产出任何可当作成绩的数据")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("点击「一致性校验」查看 I1–I10 逐项结果；点击「生成并保存」时引擎会再次强制校验")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    /// 预览曲线 + 地图：真实数据来自 `DefaultSimulationEngine.preview`。
    @ViewBuilder
    private var previewSection: some View {
        if !vm.previewPoints.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("实时预览（\(vm.previewPoints.count) 帧）")
                    .font(.headline)
                OriginBadge(.simulated, style: .compact)
                RouteMapView(
                    points: vm.previewPoints.map(\.geoPoint),
                    cameraPosition: $cameraPosition,
                    progress: 1
                )
                Picker("曲线横轴", selection: $axis) {
                    ForEach(ChartAxis.allCases, id: \.self) { item in
                        Text(item.localizedDescription).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Picker("降采样", selection: $tier) {
                    ForEach(DownsamplingTier.allCases, id: \.self) { item in
                        Text(item.localizedDescription).tag(item)
                    }
                }
                .pickerStyle(.menu)
                LinkedCursor(
                    cursorSourceIndex: $cursorSourceIndex,
                    pointCount: vm.previewPoints.count,
                    summaryText: AppTheme.cursorSummary(
                        index: cursorSourceIndex,
                        elapsed: vm.previewPoints[safe: cursorSourceIndex]?.elapsedSeconds ?? 0,
                        distance: vm.previewPoints[safe: cursorSourceIndex]?.cumulativeDistanceM ?? 0
                    )
                )
                ForEach(vm.series(for: vm.previewPoints, axis: axis, tier: tier)) { item in
                    SeriesChartView(
                        series: item,
                        cursorSourceIndex: $cursorSourceIndex,
                        onCursorChange: { _ in }
                    )
                }
            }
            .padding(AppTheme.Spacing.md)
            .glassCard(role: .card, interactive: false)
        }
    }

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("跳转")
                .font(.headline)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "改路线", symbol: "map") { vm.openRoutePlanning() }
                ActionButton(title: "数据分析", symbol: "chart.xyaxis.line") { vm.openAnalytics() }
                ActionButton(title: "历史记录", symbol: "clock.arrow.circlepath") { vm.openHistory() }
                ActionButton(title: "默认参数", symbol: "gearshape") { vm.openSettings() }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    private var footer: some View {
        Text(AppConstants.simulationFooter)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 规则预评估结果：固定免责声明 + 三态结论，绝无成绩 / 上传字样。
    private var evaluationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    OriginBadge(.simulated, style: .full)
                    Text(AppConstants.ruleDisclaimer).font(.caption.weight(.semibold))
                    Text(AppConstants.evaluationObjectLabel).font(.caption)
                    Text(AppConstants.ruleEvaluationNotice).font(.caption)
                    Divider()
                    Text(vm.evaluationText.isEmpty ? "暂无评估结果" : vm.evaluationText)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(vm.evaluationResults, id: \.presetId) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.displayName).font(.caption.weight(.semibold))
                            ForEach(result.conditionResults, id: \.condition.rawValue) { condition in
                                Text("· \(condition.displayText)")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("本地模拟预评估")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showEvaluation = false }
                }
            }
        }
    }
}

// MARK: - 安全下标（仅本文件使用）

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
