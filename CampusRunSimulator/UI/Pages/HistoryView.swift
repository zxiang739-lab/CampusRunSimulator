import Foundation
import SwiftUI
import Observation

// MARK: - 历史页辅助行（F58 / §B.6.6）

/// 路线版本历史的可展示行；只包含 UI 展示所需的 id 与冻结 `RouteVersion`。
public struct HistoryRouteVersionRow: Identifiable, Sendable {
    public let id: String
    public let routeName: String
    public let version: RouteVersion

    public init(id: String, routeName: String, version: RouteVersion) {
        self.id = id
        self.routeName = routeName
        self.version = version
    }
}

// MARK: - 历史记录视图模型（F58 / §B.6.6）

/// 默认按「真实记录 / 测试数据 SIMULATED」两分区读取；不提供「全部记录」混排视图。
/// 筛选、搜索、排序、详情动作、批量删除、副本、导出、存储占用全部调 BATCH_3 真实服务。
@MainActor
@Observable
public final class HistoryViewModel {

    // MARK: 可编辑筛选条件

    public var searchText: String = ""
    public var usesFromDate: Bool = false
    public var fromDate: Date = Date().addingTimeInterval(-7 * 24 * 3_600)
    public var usesToDate: Bool = false
    public var toDate: Date = Date()
    public var routeFilterID: String? = nil
    public var sortKey: RunSortKey = .startTime
    public var ascending: Bool = false
    public var exportFormat: ExportFormat = .csv
    public var isMultiSelectMode: Bool = false
    public var selectedIDs: Set<String> = []

    // MARK: 真实读取状态

    public private(set) var realSessions: [RunSession] = []
    public private(set) var simulatedSessions: [RunSession] = []
    public private(set) var unclassifiedSessions: [RunSession] = []
    public private(set) var routes: [Route] = []
    public private(set) var presets: [RulePreset] = []
    public private(set) var profiles: [SimulationProfile] = []
    public private(set) var storageText: String = "正在统计…"
    public private(set) var errorMessage: String? = nil
    public private(set) var lastActionMessage: String = "尚未载入历史"
    public private(set) var isLoading: Bool = false

    public init() {}

    public var routeVersionRows: [HistoryRouteVersionRow] {
        routes.flatMap { route in
            route.versions.map { version in
                HistoryRouteVersionRow(
                    id: "\(route.id)_\(version.id)",
                    routeName: route.name,
                    version: version
                )
            }
        }
        .sorted { $0.version.createdAt > $1.version.createdAt }
    }

    public var selectedCountText: String {
        "已选择 \(selectedIDs.count) 条（按来源分区删除，绝不合并操作）"
    }

    /// 当前筛选条件：由冻结 `RunPredicate.apply(to:)` 在仓库层真实执行。
    private var currentPredicate: RunPredicate {
        RunPredicate(
            searchText: searchText,
            fromDate: usesFromDate ? fromDate : nil,
            toDate: usesToDate ? toDate : nil,
            routeId: routeFilterID,
            sortKey: sortKey,
            ascending: ascending,
            limit: nil
        )
    }

    /// 首次进入 / 下拉刷新 / 筛选后刷新：两个独立容器分别读取，脏数据单独读取。
    public func refresh() async {
        isLoading = true
        errorMessage = nil
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            lastActionMessage = "本地存储未就绪，无法读取历史"
            isLoading = false
            return
        }
        do {
            let predicate = currentPredicate
            async let realFetch = repository.fetch(origin: .real, predicate: predicate)
            async let simulatedFetch = repository.fetch(origin: .simulated, predicate: predicate)
            async let unclassifiedFetch = repository.unclassified()
            async let routeFetch = repository.routes()
            async let presetFetch = repository.presets()
            async let profileFetch = repository.profiles()

            let (realList, simulatedList, dirtyList, routeList, presetList, profileList) =
                try await (realFetch, simulatedFetch, unclassifiedFetch, routeFetch, presetFetch, profileFetch)

            realSessions = realList
            simulatedSessions = simulatedList
            unclassifiedSessions = dirtyList
            routes = mergeByID(AppServices.shared.loadRoutes(), routeList)
                .sorted { $0.updatedAt > $1.updatedAt }
            presets = mergeByID(AppServices.shared.loadPresets(), presetList)
                .sorted { $0.displayName < $1.displayName }
            profiles = mergeByID(AppServices.shared.loadProfiles(), profileList)
                .sorted { $0.name < $1.name }
            storageText = AppServices.shared.storageUsageText()
            lastActionMessage = "已读取真实 \(realList.count) 条、测试数据 \(simulatedList.count) 条、未分类 \(dirtyList.count) 条"
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "历史读取失败：\(error.localizedDescription)"
            isLoading = false
        }
    }

    public func resetFilters() {
        searchText = ""
        usesFromDate = false
        usesToDate = false
        routeFilterID = nil
        sortKey = .startTime
        ascending = false
        lastActionMessage = "已重置筛选，等待重新读取两个分区"
    }

    public func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        lastActionMessage = selectedCountText
    }

    /// 只选择当前可见分区；不提供「选择全部记录」的混排入口。
    public func selectVisible(_ origin: DataOrigin) {
        let ids = (origin == .real ? realSessions : simulatedSessions).map(\.id)
        selectedIDs.formUnion(ids)
        lastActionMessage = "已选择 \(origin.displayText) 分区可见的 \(ids.count) 条记录"
    }

    public func clearSelection() {
        selectedIDs.removeAll()
        lastActionMessage = "已清空选择，未删除任何记录"
    }

    public func cancelDelete() {
        lastActionMessage = "已取消删除，未改动任何数据"
    }

    /// 删除单条正常记录：按冻结来源路由到对应容器，并刷新分区。
    public func delete(_ session: RunSession) async {
        guard session.hasValidOriginID else {
            await deleteUnclassified(ids: [session.id])
            return
        }
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            try await repository.delete(ids: [session.id], origin: session.dataOrigin)
            selectedIDs.remove(session.id)
            lastActionMessage = "已删除 \(session.dataOrigin.displayText) 记录 \(session.id)"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    /// 批量删除：按 id 前缀分组，分别调用两次 `delete(ids:origin:)`；未分类对象两个容器都做安全清理。
    public func deleteSelected() async {
        guard !selectedIDs.isEmpty else {
            lastActionMessage = "没有选中任何记录，未执行删除"
            return
        }
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        var simulatedIDs: [String] = []
        var realIDs: [String] = []
        var dirtyIDs: [String] = []
        for id in selectedIDs {
            switch OriginID.domain(of: id) {
            case .simulated: simulatedIDs.append(id)
            case .real: realIDs.append(id)
            case nil: dirtyIDs.append(id)
            }
        }
        do {
            if !simulatedIDs.isEmpty {
                try await repository.delete(ids: simulatedIDs, origin: .simulated)
            }
            if !realIDs.isEmpty {
                try await repository.delete(ids: realIDs, origin: .real)
            }
            if !dirtyIDs.isEmpty {
                try await deleteUnclassifiedRaw(repository, ids: dirtyIDs)
            }
            let count = selectedIDs.count
            selectedIDs.removeAll()
            lastActionMessage = "已按来源分区删除 \(count) 条记录，未发生任何来源转换"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "批量删除失败：\(error.localizedDescription)"
        }
    }

    /// 删除未分类对象：占位 id 不属于任何来源域，按原始 id 在两个容器分别查找并删除。
    public func deleteUnclassified(ids: [String]) async {
        guard !ids.isEmpty else {
            lastActionMessage = "没有选中未分类对象，未执行删除"
            return
        }
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            try await deleteUnclassifiedRaw(repository, ids: ids)
            selectedIDs.subtract(ids)
            lastActionMessage = "已清理 \(ids.count) 个未分类对象，绝不默认显示为真实记录"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "未分类数据清理失败：\(error.localizedDescription)"
        }
    }

    /// 另存副本：调 `DefaultRunRepository.duplicate(_:)`，来源链与来源保持不变。
    public func duplicate(_ session: RunSession) async {
        guard session.hasValidOriginID else {
            errorMessage = AppError.unclassifiedDataIsolated.errorDescription
            return
        }
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            let copy = try await repository.duplicate(session)
            lastActionMessage = "已另存副本 \(copy.id)，来源保持为 \(copy.dataOrigin.displayText)"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "副本保存失败：\(error.localizedDescription)"
        }
    }

    /// 备注写入：以同一 id / 同一来源重建 `RunSession`，保留来源链，再写回同一容器。
    /// 不提供任何来源切换、不触碰另一容器。
    public func updateNote(for session: RunSession, note: String) async {
        guard session.hasValidOriginID else {
            errorMessage = AppError.unclassifiedDataIsolated.errorDescription
            return
        }
        guard let repository = AppServices.shared.repository else {
            errorMessage = AppError.persistenceMigrationFailed.errorDescription
            return
        }
        do {
            let points = try await repository.points(sessionId: session.id)
            let updated = RunSession(
                id: session.id,
                dataOrigin: session.dataOrigin,
                startTime: session.startTime,
                endTime: session.endTime,
                durationSeconds: session.durationSeconds,
                totalDistanceMeters: session.totalDistanceMeters,
                avgSpeedMps: session.avgSpeedMps,
                avgPaceSecPerKm: session.avgPaceSecPerKm,
                totalSteps: session.totalSteps,
                elevationGainM: session.elevationGainM,
                elevationLossM: session.elevationLossM,
                routeId: session.routeId,
                simulationProfileId: session.simulationProfileId,
                rulePresetId: session.rulePresetId,
                note: note,
                createdAt: session.createdAt,
                schemaVersion: session.schemaVersion,
                originChain: session.originChain
            )
            try await repository.delete(ids: [session.id], origin: session.dataOrigin)
            try await repository.save(updated, points: points)
            lastActionMessage = "已保存备注，记录来源仍为 \(session.dataOrigin.displayText)"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            lastActionMessage = "备注保存失败：\(error.localizedDescription)"
        }
    }

    /// 单记录导出：单一来源 + 三重标记，经 `ExportManager` 生成文件后交系统分享面板。
    public func export(_ session: RunSession, format: ExportFormat) async throws -> URL {
        guard session.hasValidOriginID else {
            throw AppError.unclassifiedDataIsolated
        }
        guard let repository = AppServices.shared.repository else {
            throw AppError.persistenceMigrationFailed
        }
        let points = try await repository.points(sessionId: session.id)
        let file = try await AppServices.shared.exporter.export(
            session: session,
            points: points,
            format: format
        )
        let url = try file.writeToTemporaryDirectory()
        lastActionMessage = "已生成 \(file.fileName)，含三重来源标记，仅写入本地临时目录"
        return url
    }

    public func openLiveRun() {
        AppNavigation.shared.openLiveRun()
    }

    public func openSimulation(profileId: String? = nil) {
        AppNavigation.shared.openSimulation(profileId: profileId)
    }

    public func openRoutePlanning(routeId: String? = nil) {
        AppNavigation.shared.openRoutePlanning(routeId: routeId)
    }

    public func openAnalytics(sessionId: String? = nil) {
        AppNavigation.shared.openAnalytics(sessionId: sessionId)
    }

    public func openSettings() {
        AppNavigation.shared.openSettings()
    }

    public func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
        lastActionMessage = "操作未完成：\(error.localizedDescription)"
    }

    // MARK: 私有实现

    private func mergeByID<T: Identifiable>(_ primary: [T], _ secondary: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        var result: [T] = []
        for value in primary + secondary where seen.insert(value.id).inserted {
            result.append(value)
        }
        return result
    }

    private static func rawID(from placeholderID: String) -> String {
        let prefix = "unclassified_"
        guard placeholderID.hasPrefix(prefix) else { return placeholderID }
        return String(placeholderID.dropFirst(prefix.count))
    }

    private func deleteUnclassifiedRaw(_ repository: DefaultRunRepository, ids: [String]) async throws {
        let rawIDs = ids.map(Self.rawID(from:))
        // 不推断来源：两个独立容器都尝试匹配原始 id，无法判断时保持物理隔离而非默认 real。
        try await repository.delete(ids: rawIDs, origin: .simulated)
        try await repository.delete(ids: rawIDs, origin: .real)
    }
}

// MARK: - 历史记录页（F58）

/// 默认两分区，禁止「全部记录」混排成绩单；所有列表来自 `DefaultRunRepository`。
@MainActor
public struct HistoryView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var vm = HistoryViewModel()
    @State private var showDetail: Bool = false
    @State private var detailSession: RunSession? = nil
    @State private var noteDraft: String = ""
    @State private var replaySessionId: String? = nil
    @State private var shareURL: URL? = nil
    @State private var showBatchDeleteConfirm: Bool = false
    @State private var showSingleDeleteConfirm: Bool = false
    @State private var pendingDeleteSession: RunSession? = nil
    @State private var showUnclassifiedDeleteConfirm: Bool = false
    @State private var pendingUnclassifiedIDs: [String] = []

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                filterSection
                batchSelectionSection
                errorSection
                realSection
                simulatedSection
                unclassifiedSection
                configurationsSection
                storageSection
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle(AppRoute.history.title)
        .refreshable { await vm.refresh() }
        .task { await vm.refresh() }
        .confirmationDialog("批量删除不可恢复", isPresented: $showBatchDeleteConfirm) {
            Button("确认按来源分区删除", role: .destructive) {
                Task { await vm.deleteSelected() }
            }
            Button("取消", role: .cancel) { vm.cancelDelete() }
        } message: {
            Text("删除按真实记录 / 测试数据分别写入对应容器；两类数据不会合并，也不会互相转换。")
        }
        .confirmationDialog("删除单条记录不可恢复", isPresented: $showSingleDeleteConfirm) {
            Button("确认删除", role: .destructive) {
                if let session = pendingDeleteSession {
                    Task { await vm.delete(session) }
                }
                pendingDeleteSession = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteSession = nil
                vm.cancelDelete()
            }
        } message: {
            Text(pendingDeleteSession.map { "将删除 \($0.dataOrigin.displayText) 记录 \($0.id)" } ?? "没有待删除记录")
        }
        .confirmationDialog("清理未分类对象", isPresented: $showUnclassifiedDeleteConfirm) {
            Button("确认清理", role: .destructive) {
                let ids = pendingUnclassifiedIDs
                pendingUnclassifiedIDs = []
                Task { await vm.deleteUnclassified(ids: ids) }
            }
            Button("取消", role: .cancel) {
                pendingUnclassifiedIDs = []
                vm.cancelDelete()
            }
        } message: {
            Text("未分类数据缺来源或 id 非法；清理时不会默认显示为真实记录。")
        }
        .sheet(isPresented: $showDetail) { detailSheet }
        .sheet(isPresented: Binding(
            get: { replaySessionId != nil },
            set: { if !$0 { replaySessionId = nil } }
        )) {
            if let replaySessionId {
                ReplayView(sessionId: replaySessionId)
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ShareSheet(items: [shareURL as Any]) { self.shareURL = nil }
            }
        }
    }

    // MARK: 区块

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                OriginBadge(.real, style: .compact)
                OriginBadge(.simulated, style: .compact)
                Spacer(minLength: 2)
                if vm.isLoading {
                    ProgressView("正在读取两个独立存储域…")
                        .font(.caption)
                }
            }
            Text("历史记录默认按来源分区：真实记录与测试数据 SIMULATED 永不混排")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(vm.lastActionMessage)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            ComplianceBanner { vm.openSettings() }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("筛选 / 搜索 / 排序")
                .font(.headline)
            TextField("搜索备注或记录 id", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await vm.refresh() } }
                .accessibilityLabel("搜索历史记录备注或记录 id")

            Toggle("限制开始日期", isOn: $vm.usesFromDate)
            if vm.usesFromDate {
                DatePicker("开始日期", selection: $vm.fromDate, displayedComponents: .date)
            }
            Toggle("限制结束日期", isOn: $vm.usesToDate)
            if vm.usesToDate {
                DatePicker("结束日期", selection: $vm.toDate, displayedComponents: .date)
            }

            Picker("路线", selection: $vm.routeFilterID) {
                Text("不限制路线").tag(nil as String?)
                ForEach(vm.routes) { route in
                    Text(route.name).tag(Optional(route.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("按路线筛选历史记录")

            Picker("排序", selection: $vm.sortKey) {
                ForEach(RunSortKey.allCases, id: \.self) { key in
                    Text(sortKeyText(key)).tag(key)
                }
            }
            .pickerStyle(.segmented)
            Toggle("升序", isOn: $vm.ascending)

            Picker("导出格式", selection: $vm.exportFormat) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Text(format.localizedDescription).tag(format)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "应用筛选", symbol: "line.3.horizontal.decrease.circle", style: .prominent) {
                    Task { await vm.refresh() }
                }
                ActionButton(title: "重置筛选", symbol: "arrow.counterclockwise") {
                    vm.resetFilters()
                    Task { await vm.refresh() }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var batchSelectionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Toggle("批量选择模式", isOn: $vm.isMultiSelectMode)
            Text(vm.selectedCountText)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "选择可见真实记录", symbol: "checkmark.circle") {
                    vm.selectVisible(.real)
                }
                ActionButton(title: "选择可见测试数据", symbol: "checkmark.circle") {
                    vm.selectVisible(.simulated)
                }
                ActionButton(title: "清空选择", symbol: "xmark.circle") {
                    vm.clearSelection()
                }
                ActionButton(
                    title: "批量删除",
                    symbol: "trash",
                    style: .destructive,
                    isDisabled: vm.selectedIDs.isEmpty
                ) {
                    showBatchDeleteConfirm = true
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = vm.errorMessage {
            ErrorStateView(
                origin: .simulated,
                error: AppError.parameterConflict(reason: message),
                primaryTitle: "重新读取",
                primaryAction: { Task { await vm.refresh() } },
                secondaryTitle: "数据管理",
                secondaryAction: { vm.openSettings() }
            )
        }
    }

    private var realSection: some View {
        sessionSection(title: "真实记录", origin: .real, sessions: vm.realSessions)
    }

    private var simulatedSection: some View {
        sessionSection(title: "测试数据 SIMULATED", origin: .simulated, sessions: vm.simulatedSessions)
    }

    private func sessionSection(title: String, origin: DataOrigin, sessions: [RunSession]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                OriginBadge(origin, style: .full)
                Text("\(title)（\(sessions.count)）")
                    .font(.headline)
                Spacer(minLength: 2)
            }
            if sessions.isEmpty {
                EmptyStateView(
                    origin: origin,
                    title: origin == .real ? "真实记录分区暂无数据" : "测试数据分区暂无数据",
                    message: origin == .real
                        ? "真实记录只来自设备传感器；测试数据永不写入此分区。请检查权限后开始一次真实跑步。"
                        : "在运动模拟器中配置路线与参数，生成带 SIMULATED 标记的本地测试数据集。",
                    actionTitle: origin == .real ? "开始真实跑步" : "新建仿真",
                    action: { origin == .real ? vm.openLiveRun() : vm.openSimulation() },
                    secondaryTitle: origin == .real ? "查看权限设置" : "规划路线",
                    secondaryAction: { origin == .real ? vm.openSettings() : vm.openRoutePlanning() }
                )
            } else {
                ForEach(sessions) { session in
                    sessionRow(session, origin: origin)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private func sessionRow(_ session: RunSession, origin: DataOrigin) -> some View {
        let isSelected = vm.selectedIDs.contains(session.id)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                if vm.isMultiSelectMode {
                    Button {
                        vm.toggleSelection(session.id)
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }
                    .accessibilityLabel(isSelected ? "取消选择记录 \(session.id)" : "选择记录 \(session.id)")
                }
                OriginBadge(origin, style: .compact)
                Text(session.startTime.iso8601UTCString)
                    .font(.caption2.monospaced())
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
            Text(session.note.isEmpty ? "无备注" : "备注：\(session.note)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("id \(session.id)｜来源链 \(session.originChainText)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("详情") {
                        detailSession = session
                        noteDraft = session.note
                        showDetail = true
                    }
                    Button("回放") { replaySessionId = session.id }
                    Button("分析") { vm.openAnalytics(sessionId: session.id) }
                    Button("导出") {
                        Task {
                            do { shareURL = try await vm.export(session, format: vm.exportFormat) }
                            catch { vm.reportError(error) }
                        }
                    }
                    Button("副本") { Task { await vm.duplicate(session) } }
                    Button("删除") {
                        pendingDeleteSession = session
                        showSingleDeleteConfirm = true
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardStroke(colorScheme).opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var unclassifiedSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Image(systemName: "questionmark.diamond")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("\(AppConstants.unclassifiedSectionName)（\(vm.unclassifiedSessions.count)）")
                    .font(.headline)
                Spacer(minLength: 2)
                OriginBadge(.simulated, style: .compact)
            }
            Text("来源标记缺失或 id 非法的对象安全隔离在此；占位来源为测试数据，绝不默认显示为真实记录")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if vm.unclassifiedSessions.isEmpty {
                Text("当前没有未分类对象")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.unclassifiedSessions) { session in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.id)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(session.note.isEmpty ? "无备注" : session.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Button("隔离删除") {
                            pendingUnclassifiedIDs = [session.id]
                            showUnclassifiedDeleteConfirm = true
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("删除未分类对象 \(session.id)")
                    }
                }
            }
            ActionButton(title: "前往数据管理", symbol: "gearshape") { vm.openSettings() }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var configurationsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("路线版本 / 规则预设 / 仿真模板")
                .font(.headline)
            Text("路线版本（\(vm.routeVersionRows.count)）")
                .font(.caption.weight(.semibold))
            if vm.routeVersionRows.isEmpty {
                Text("尚无路线版本；在路线规划页保存后会出现可回溯快照")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.routeVersionRows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.routeName)：\(row.version.changeNote.isEmpty ? row.version.id : row.version.changeNote)")
                                .font(.caption)
                            Text(row.version.createdAt.iso8601UTCString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Button("编辑路线") { vm.openRoutePlanning(routeId: row.version.routeId) }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                    }
                }
            }
            Text("假设规则预设（\(vm.presets.count)）")
                .font(.caption.weight(.semibold))
            if vm.presets.isEmpty {
                EmptyStateView(
                    origin: .simulated,
                    title: "没有用户自建假设规则预设",
                    message: "预设全部强制 isHypothetical = true，仅用于本地模拟评估；不产生、不上传任何成绩。",
                    actionTitle: "前往设置创建",
                    action: { vm.openSettings() }
                )
            } else {
                ForEach(vm.presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(preset.displayName)｜组：\(preset.meta.comparisonGroup)")
                                .font(.caption)
                            Text("假设值：\(preset.isHypothetical ? "是" : "否")｜\(preset.disclaimer)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 2)
                        Button("管理") { vm.openSettings() }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                    }
                }
            }
            Text("仿真模板（\(vm.profiles.count)）")
                .font(.caption.weight(.semibold))
            if vm.profiles.isEmpty {
                Text("尚无模板；在运动模拟器页保存模板后可从此再生成")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.caption)
                            Text("模型：\(profile.modelType.localizedDescription)｜种子：\(profile.seed)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Button("用模板再生成") { vm.openSimulation(profileId: profile.id) }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("存储占用")
                .font(.headline)
            Text(vm.storageText)
                .font(.subheadline.monospacedDigit())
            Text("两个来源分别存储；清除、导出、删除均按来源独立执行")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: AppTheme.Spacing.sm) {
                ActionButton(title: "刷新占用", symbol: "arrow.clockwise") {
                    Task { await vm.refresh() }
                }
                ActionButton(title: "查看数据管理", symbol: "gearshape") { vm.openSettings() }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("测试数据与真实记录物理隔离，永不互相转换；导出文件按来源分别生成并带三重标记")
                .font(.caption2)
            Text("本页不提供上传入口，不把任何记录提交到第三方平台")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 弹层

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if let session = detailSession {
                        HStack {
                            OriginBadge(session.dataOrigin, style: .full)
                            Spacer(minLength: 2)
                            Text(session.id)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 140), spacing: AppTheme.Spacing.md)],
                            spacing: AppTheme.Spacing.md
                        ) {
                            MetricCard(title: "距离", value: Units.formatDistanceKm(session.totalDistanceMeters), origin: session.dataOrigin)
                            MetricCard(title: "时长", value: Units.formatDuration(session.durationSeconds), origin: session.dataOrigin)
                            MetricCard(title: "平均配速", value: Units.formatPaceMinPerKm(session.avgPaceSecPerKm), origin: session.dataOrigin)
                            MetricCard(title: "累计爬升", value: AppTheme.metricNumberFormat(session.elevationGainM, unit: "m", digits: 1), origin: session.dataOrigin)
                        }
                        Text("来源链：\(session.originChainText)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("备注", text: $noteDraft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                            .accessibilityLabel("编辑记录备注")
                        ActionButton(title: "保存备注", symbol: "square.and.arrow.down", style: .prominent) {
                            Task {
                                await vm.updateNote(for: session, note: noteDraft)
                                showDetail = false
                            }
                        }
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ActionButton(title: "轨迹回放", symbol: "play.circle") {
                                replaySessionId = session.id
                                showDetail = false
                            }
                            ActionButton(title: "数据分析", symbol: "chart.xyaxis.line") {
                                vm.openAnalytics(sessionId: session.id)
                                showDetail = false
                            }
                        }
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ActionButton(title: "导出文件", symbol: "square.and.arrow.up") {
                                Task {
                                    do { shareURL = try await vm.export(session, format: vm.exportFormat) }
                                    catch { vm.reportError(error) }
                                }
                            }
                            ActionButton(title: "另存副本", symbol: "doc.on.doc") {
                                Task { await vm.duplicate(session) }
                            }
                        }
                        if let routeId = session.routeId {
                            ActionButton(title: "查看关联路线", symbol: "map") {
                                vm.openRoutePlanning(routeId: routeId)
                                showDetail = false
                            }
                        }
                        if session.dataOrigin == .simulated, let profileId = session.simulationProfileId {
                            ActionButton(title: "用模板再生成", symbol: "testtube.2") {
                                vm.openSimulation(profileId: profileId)
                                showDetail = false
                            }
                        }
                        ActionButton(title: "删除记录", symbol: "trash", style: .destructive) {
                            pendingDeleteSession = session
                            showDetail = false
                            showSingleDeleteConfirm = true
                        }
                    } else {
                        ErrorStateView(
                            origin: .simulated,
                            error: AppError.parameterConflict(reason: "详情记录已不存在，请返回列表刷新"),
                            primaryTitle: "重新读取",
                            primaryAction: { Task { await vm.refresh() } }
                        )
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .navigationTitle("记录详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showDetail = false }
                        .accessibilityLabel("关闭记录详情")
                }
            }
        }
    }

    // MARK: 文案辅助

    private func sortKeyText(_ key: RunSortKey) -> String {
        switch key {
        case .startTime: return "开始时间"
        case .createdAt: return "创建时间"
        case .durationSeconds: return "时长"
        case .totalDistanceMeters: return "距离"
        }
    }
}
