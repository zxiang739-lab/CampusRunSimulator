import Foundation
import SwiftUI
import Observation
import MapKit
import UniformTypeIdentifiers

// MARK: - 路线编辑草稿快照（撤销 / 重做的真实状态）

/// 一次可撤销编辑的完整快照。私有类型，仅本文件使用，不引入新的冻结领域类型。
private struct RouteSnapshot: Sendable {
    let points: [RoutePoint]
    let routeType: RouteType
    let elevationSource: ElevationSource
    let initialAltitudeM: Double
    let elevationSegments: [ElevationSegment]
}

// MARK: - 路线规划视图模型（F54 / §B.6.2）

/// 地图选点 / 拖点 / 撤销重做 / 路线类型 / 版本历史 / GPX 往返 / 海拔剖面编辑全部真实生效。
/// 里程、方向、坡度、海拔均由 F27 `RouteArcLength`、F11 `Units`、F16 `ElevationProfile` 真实计算。
@MainActor
@Observable
public final class RoutePlanningViewModel {

    public var routeName: String = "校园路线（示例假设值）"
    public var routeType: RouteType = .loop
    public var elevationSource: ElevationSource = .userDefined
    public var initialAltitudeM: Double = 12
    public var elevationSegments: [ElevationSegment] = []
    public var draftPoints: [RoutePoint] = []
    public var waypoints: [Waypoint] = []
    public var selectedArcLengthM: Double = 0
    public var selectedPointIndex: Int? = nil
    public var exportOrigin: DataOrigin = .simulated

    public private(set) var versions: [RouteVersion] = []
    public private(set) var savedRoutes: [Route] = []
    public private(set) var currentRouteId: String = UUID().uuidString
    public private(set) var createdAt: Date = Date()
    public private(set) var importResult: GPXImportResult? = nil
    public private(set) var importWarnings: [String] = []
    public private(set) var errorMessage: String? = nil
    public private(set) var lastActionMessage: String = "尚未编辑"
    public private(set) var isLoading: Bool = false
    public private(set) var canUndo: Bool = false
    public private(set) var canRedo: Bool = false

    private var undoStack: [RouteSnapshot] = []
    private var redoStack: [RouteSnapshot] = []
    private let errorModel = ElevationErrorModel()
    private let gpxCodec = GPXCodec()
    private let marker = DataMarker()

    public init() {}

    // MARK: 真实派生量

    /// 当前草稿重算弧长后的路线（弧长口径与 F27 一致：`Units.distanceMeters`）。
    public func currentRoute() -> Route {
        let points = normalizedPoints()
        let profile = currentProfile()
        let base = Route(
            id: currentRouteId,
            name: routeName,
            routeType: routeType,
            points: points,
            waypoints: waypoints,
            elevationProfile: profile,
            currentVersionId: versions.last?.id ?? "\(currentRouteId)_v1",
            elevationSource: elevationSource
        )
        let length = RouteArcLength(route: base).totalLength()
        return Route(
            id: currentRouteId,
            name: routeName,
            routeType: routeType,
            totalDistanceM: length,
            points: points,
            waypoints: waypoints,
            elevationProfile: profile,
            versions: versions,
            currentVersionId: versions.last?.id ?? "\(currentRouteId)_v1",
            elevationSource: elevationSource,
            externalServiceAttribution: elevationSource == .externalService
                ? "用户在设置中显式启用的外部高程服务" : nil,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    public var totalLengthM: Double { currentRoute().totalDistanceM }

    /// 选中弧长处的方位角（度，正北顺时针）。
    public var courseDegreesAtSelected: Double {
        RouteArcLength(route: currentRoute()).course(atArcLength: selectedArcLengthM)
    }

    /// 选中弧长处的坡度（%）：由剖面相邻采样真实差分得到。
    public var slopePercentAtSelected: Double {
        let step = max(1, totalLengthM / 100)
        let lower = max(0, selectedArcLengthM - step)
        let upper = min(totalLengthM, selectedArcLengthM + step)
        let profile = currentProfile()
        let delta = profile.altitude(atArcLength: upper) - profile.altitude(atArcLength: lower)
        return Units.slopePercent(deltaAltitudeM: delta, horizontalDistanceM: max(0, upper - lower))
    }

    public var altitudeAtSelected: Double {
        currentProfile().altitude(atArcLength: selectedArcLengthM)
    }

    public var selectedMapPoint: GeoPoint? {
        guard totalLengthM > 0 else { return draftPoints.first?.geoPoint }
        return RouteArcLength(route: currentRoute()).point(atArcLength: selectedArcLengthM).geoPoint
    }

    public var mapPoints: [GeoPoint] { normalizedPoints().map(\.geoPoint) }

    public var annotations: [RouteMapAnnotation] {
        var result: [RouteMapAnnotation] = normalizedPoints().enumerated().map { index, point in
            RouteMapAnnotation(
                id: point.id,
                label: "点 \(index + 1)",
                coordinate: point.geoPoint,
                symbolName: index == 0 ? "flag.circle.fill" : "mappin.circle.fill"
            )
        }
        if let selectedMapPoint {
            result.append(RouteMapAnnotation(
                id: "selected_arc",
                label: "剖面选中点",
                coordinate: selectedMapPoint,
                symbolName: "scope"
            ))
        }
        return result
    }

    // MARK: 载入已保存路线

    /// 从双域仓库与本地中性配置存储读取全部路线（去重后按更新时间倒序）。
    public func load() async {
        isLoading = true
        errorMessage = nil
        let local = AppServices.shared.loadRoutes()
        var merged = local
        if let repository = AppServices.shared.repository {
            let remote = (try? await repository.routes()) ?? []
            for route in remote where !merged.contains(where: { $0.id == route.id }) {
                merged.append(route)
            }
        }
        savedRoutes = merged.sorted { $0.updatedAt > $1.updatedAt }
        if let selectedRouteID = AppNavigation.shared.consumeSelectedRouteID(),
           let selected = savedRoutes.first(where: { $0.id == selectedRouteID }) {
            apply(saved: selected)
            lastActionMessage = "已载入导航指定路线「\(selected.name)」"
        } else if let first = savedRoutes.first {
            apply(saved: first)
        }
        isLoading = false
    }

    /// 选中一条已保存路线并真实恢复草稿与版本历史。
    public func selectSavedRoute(_ route: Route) {
        apply(saved: route)
        lastActionMessage = "已载入路线「\(route.name)」，共 \(route.versions.count) 个版本"
    }

    /// 回溯到某个历史版本的点位快照（真实解码 `RouteVersion.snapshot`）。
    public func selectVersion(_ version: RouteVersion) {
        pushUndo()
        draftPoints = version.decodedPoints()
        selectedPointIndex = nil
        selectedArcLengthM = 0
        lastActionMessage = "已回溯版本：\(version.changeNote.isEmpty ? version.id : version.changeNote)"
    }

    // MARK: 编辑动作（全部可撤销）

    public func addPoint(_ coordinate: GeoPoint) {
        guard coordinate.isValid else {
            errorMessage = "坐标越界，已忽略该点"
            return
        }
        pushUndo()
        draftPoints.append(RoutePoint(
            orderIndex: draftPoints.count,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitudeM: nil,
            arcLengthFromStartM: 0
        ))
        errorMessage = nil
        lastActionMessage = "新增第 \(draftPoints.count) 个点"
    }

    public func selectPoint(_ index: Int) {
        guard draftPoints.indices.contains(index) else { return }
        selectedPointIndex = index
        lastActionMessage = "已选中第 \(index + 1) 个点，可拖动调整"
    }

    public func movePoint(_ index: Int, _ coordinate: GeoPoint) {
        guard draftPoints.indices.contains(index), coordinate.isValid else { return }
        if selectedPointIndex != index { pushUndo() }
        selectedPointIndex = index
        let old = draftPoints[index]
        draftPoints[index] = RoutePoint(
            id: old.id,
            orderIndex: old.orderIndex,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitudeM: old.altitudeM,
            arcLengthFromStartM: 0
        )
        lastActionMessage = "正在移动第 \(index + 1) 个点"
    }

    public func removePoint(at index: Int) {
        guard draftPoints.indices.contains(index) else { return }
        pushUndo()
        draftPoints.remove(at: index)
        selectedPointIndex = nil
        lastActionMessage = "已删除第 \(index + 1) 个点"
    }

    public func clearPoints() {
        guard !draftPoints.isEmpty else { return }
        pushUndo()
        draftPoints = []
        selectedPointIndex = nil
        lastActionMessage = "已清空全部点位"
    }

    /// 切换路线类型时按类型约束首尾并即时重算（loop 自动闭合，折返按三角波往返）。
    public func setRouteType(_ type: RouteType) {
        pushUndo()
        routeType = type
        if type == .loop, draftPoints.count >= 3,
           let first = draftPoints.first, let last = draftPoints.last,
           Units.haversineMeters(first.geoPoint, last.geoPoint) > 5 {
            draftPoints.append(RoutePoint(
                orderIndex: draftPoints.count,
                latitude: first.latitude,
                longitude: first.longitude,
                altitudeM: first.altitudeM,
                arcLengthFromStartM: 0
            ))
            lastActionMessage = "已切换为环形并自动补齐闭合点"
        } else {
            lastActionMessage = "已切换路线类型为「\(type.localizedDescription)」，里程与方向已重算"
        }
    }

    public func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(snapshot)
        lastActionMessage = "已撤销上一步编辑"
    }

    public func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(snapshot)
        lastActionMessage = "已重做上一步编辑"
    }

    // MARK: 海拔剖面编辑

    /// 切换高程来源；外部服务须先在设置页显式启用（合规：需联网同意）。
    public func setElevationSource(_ source: ElevationSource) throws {
        if source == .externalService,
           !AppSettingsStore.shared.settings.externalElevationEnabled {
            throw AppError.externalElevationConsentRequired
        }
        pushUndo()
        elevationSource = source
        lastActionMessage = "海拔来源已切换为「\(source.localizedDescription)」"
    }

    public func setInitialAltitude(_ value: Double) {
        pushUndo()
        initialAltitudeM = value.isFinite ? value : 0
        lastActionMessage = "初始海拔已设为 \(AppTheme.metricNumberFormat(initialAltitudeM, unit: "m", digits: 1))"
    }

    public func addElevationSegment(kind: ElevationSegmentKind, slopePercent: Double, lengthM: Double) {
        pushUndo()
        let start = elevationSegments.reduce(0) { $0 + $1.lengthM }
        elevationSegments.append(ElevationSegment(
            startArcLengthM: start,
            endArcLengthM: start + max(1, lengthM),
            slopePercent: slopePercent,
            kind: kind
        ))
        lastActionMessage = "已新增「\(kind.localizedDescription)」剖面段"
    }

    public func removeElevationSegment(id: String) {
        guard elevationSegments.contains(where: { $0.id == id }) else { return }
        pushUndo()
        elevationSegments.removeAll { $0.id == id }
        lastActionMessage = "已删除一段海拔剖面"
    }

    public func selectArcLength(_ value: Double) {
        selectedArcLengthM = max(0, min(totalLengthM, value.isFinite ? value : 0))
    }

    // MARK: 保存 / 副本 / 版本

    /// 真实持久化：写入中性配置域（simulated 容器），并追加一个可回溯的版本快照。
    public func save() {
        guard draftPoints.count >= 2 else {
            errorMessage = "至少需要 2 个有序点才能保存路线"
            return
        }
        guard !routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请填写路线名称"
            return
        }
        do {
            let version = try RouteVersion(
                routeId: currentRouteId,
                points: normalizedPoints(),
                changeNote: "手动保存 · \(routeType.localizedDescription) · \(draftPoints.count) 点"
            )
            versions.append(version)
            let route = currentRoute()
            try AppServices.shared.saveRoute(route)
            savedRoutes = AppServices.shared.loadRoutes().sorted { $0.updatedAt > $1.updatedAt }
            errorMessage = nil
            lastActionMessage = "已保存「\(route.name)」：\(Units.formatDistanceKm(route.totalDistanceM))，版本 \(versions.count)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 另存副本：新 id、新名称，来源语义不变，版本链重新起算。
    public func duplicate() {
        guard draftPoints.count >= 2 else {
            errorMessage = "至少需要 2 个点才能另存副本"
            return
        }
        do {
            let original = currentRoute()
            let newId = UUID().uuidString
            let copy = Route(
                id: newId,
                name: original.name + "（副本）",
                routeType: original.routeType,
                totalDistanceM: original.totalDistanceM,
                points: original.points,
                waypoints: original.waypoints,
                elevationProfile: ElevationProfile(
                    routeId: newId,
                    initialAltitudeM: original.elevationProfile.initialAltitudeM,
                    segments: original.elevationProfile.segments,
                    source: original.elevationSource,
                    errorModel: original.elevationProfile.errorModel
                ),
                versions: [],
                currentVersionId: "\(newId)_v1",
                elevationSource: original.elevationSource,
                externalServiceAttribution: original.externalServiceAttribution,
                createdAt: Date(),
                updatedAt: Date()
            )
            try AppServices.shared.saveRoute(copy)
            savedRoutes = AppServices.shared.loadRoutes().sorted { $0.updatedAt > $1.updatedAt }
            lastActionMessage = "已另存副本「\(copy.name)」"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: GPX 导入 / 导出（真实闭环）

    /// 用 F41 `GPXCodec.decode`（真实 `XMLParser`）解析，并把分级提示完整交给用户确认。
    public func importGPX(_ data: Data) {
        do {
            let result = try gpxCodec.decode(data)
            importResult = result
            importWarnings = result.warnings
                + result.missingFields.map { $0.localizedDescription }
            if result.isUnclassified {
                importWarnings.append("来源无法判定，已隔离为「\(AppConstants.unclassifiedSectionName)」，绝不默认真实记录")
            }
            errorMessage = nil
            lastActionMessage = "GPX 解析完成：\(result.points.count) 个轨迹点 / \(result.routePoints.count) 个路线点"
        } catch {
            importResult = nil
            errorMessage = error.localizedDescription
        }
    }

    /// 用户确认后把导入的点位真实写入编辑器（路线点优先；轨迹点按 geoPoint 降级）。
    public func applyImport() {
        guard let result = importResult else {
            errorMessage = "没有可应用的导入结果"
            return
        }
        let coordinates: [GeoPoint]
        if !result.routePoints.isEmpty {
            coordinates = result.routePoints
        } else {
            coordinates = result.points.map(\.geoPoint)
        }
        guard coordinates.count >= 2 else {
            errorMessage = "导入文件中可用点位不足 2 个，无法生成路线"
            return
        }
        pushUndo()
        draftPoints = coordinates.enumerated().map { index, point in
            RoutePoint(orderIndex: index, latitude: point.latitude, longitude: point.longitude)
        }
        selectedPointIndex = nil
        selectedArcLengthM = 0
        importResult = nil
        errorMessage = nil
        lastActionMessage = "已应用 \(coordinates.count) 个导入点位，里程与方向已重算"
    }

    public func cancelImport() {
        importResult = nil
        importWarnings = []
        lastActionMessage = "已取消 GPX 导入"
    }

    /// 导出带三重标记的路线 GPX（`<rte>`/`<rtept>`），写出本地临时文件后交系统分享面板。
    public func exportGPX() throws -> URL {
        guard draftPoints.count >= 2 else {
            throw AppError.parameterConflict(reason: "至少需要 2 个点才能导出路线")
        }
        let metadata = marker.metadataBlock(exportOrigin)
        let fileName = marker.fileName(exportOrigin, format: .gpx, date: Date())
        try marker.verifyFileName(fileName, origin: exportOrigin)
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<!-- \(Self.xmlEscape(marker.firstLineComment(exportOrigin))) -->\n"
        xml += "<gpx version=\"1.1\" creator=\"\(Self.xmlEscape(AppConstants.generator))\" "
        xml += "xmlns=\"http://www.topografix.com/GPX/1/1\" "
        xml += "xmlns:crs=\"http://www.campusrun.simulator/gpx/ext/1.0\">\n"
        xml += "  <metadata>\n"
        xml += "    <name>\(Self.xmlEscape(metadata.fileContentMarker)) / \(Self.xmlEscape(routeName))</name>\n"
        xml += "    <desc>\(Self.xmlEscape(metadata.disclaimer))</desc>\n"
        xml += "  </metadata>\n"
        xml += "  <extensions>\n"
        xml += "    <crs:dataOrigin>\(exportOrigin.rawValue)</crs:dataOrigin>\n"
        xml += "    <crs:isHypothetical>\(metadata.isHypothetical)</crs:isHypothetical>\n"
        xml += "    <crs:generator>\(Self.xmlEscape(metadata.generator))</crs:generator>\n"
        xml += "    <crs:schemaVersion>\(metadata.schemaVersion)</crs:schemaVersion>\n"
        xml += "    <crs:badgeText>\(Self.xmlEscape(metadata.badgeText))</crs:badgeText>\n"
        xml += "  </extensions>\n"
        xml += "  <rte>\n    <name>\(Self.xmlEscape(routeName))</name>\n"
        for (index, point) in normalizedPoints().enumerated() {
            let altitude = currentProfile().altitude(atArcLength: point.arcLengthFromStartM)
            xml += "    <rtept lat=\"\(Self.number(point.latitude))\" lon=\"\(Self.number(point.longitude))\">\n"
            xml += "      <ele>\(Self.number(altitude))</ele>\n"
            xml += "      <name>点 \(index + 1)</name>\n"
            xml += "    </rtept>\n"
        }
        xml += "  </rte>\n</gpx>\n"
        guard let data = xml.data(using: .utf8) else {
            throw AppError.exportFailed(reason: "路线 GPX 的 UTF-8 编码失败")
        }
        guard OriginMarkers.containsFileContentMarker(data, for: exportOrigin),
              metadata.hasCompleteUIBadge else {
            throw AppError.missingOriginMarker
        }
        let file = ExportedFile(
            fileName: fileName,
            data: data,
            markersIncluded: MarkerKind.allCases,
            dataOrigin: exportOrigin,
            format: .gpx
        )
        let url = try file.writeToTemporaryDirectory()
        lastActionMessage = "已生成 \(fileName)（\(Units.formatDistanceKm(totalLengthM))）"
        return url
    }

    /// 把当前路线交给③仿真页（真实跳转 + 真实持久化）。
    public func useForSimulation() {
        save()
        AppNavigation.shared.openSimulation()
    }

    /// 把当前路线交给④真实记录页作为参考路线。
    public func useForLiveRun() {
        save()
        AppNavigation.shared.openLiveRun()
    }

    public func openHistory() {
        AppNavigation.shared.openHistory()
    }

    public func openSettings() {
        AppNavigation.shared.openSettings()
    }

    // MARK: 私有实现

    private func currentProfile() -> ElevationProfile {
        ElevationProfile(
            routeId: currentRouteId,
            initialAltitudeM: initialAltitudeM,
            segments: elevationSegments,
            source: elevationSource,
            errorModel: errorModel
        )
    }

    /// 逐点用统一距离口径重算 `arcLengthFromStartM`（与 F27 一致），不臆造坐标。
    private func normalizedPoints() -> [RoutePoint] {
        var result: [RoutePoint] = []
        var accumulated = 0.0
        for (index, point) in draftPoints.enumerated() {
            if index > 0 {
                accumulated += Units.distanceMeters(draftPoints[index - 1].geoPoint, point.geoPoint)
            }
            result.append(RoutePoint(
                id: point.id,
                orderIndex: index,
                latitude: point.latitude,
                longitude: point.longitude,
                altitudeM: point.altitudeM,
                arcLengthFromStartM: accumulated
            ))
        }
        return result
    }

    private func currentSnapshot() -> RouteSnapshot {
        RouteSnapshot(
            points: draftPoints,
            routeType: routeType,
            elevationSource: elevationSource,
            initialAltitudeM: initialAltitudeM,
            elevationSegments: elevationSegments
        )
    }

    private func pushUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoFlags()
    }

    private func restore(_ snapshot: RouteSnapshot) {
        draftPoints = snapshot.points
        routeType = snapshot.routeType
        elevationSource = snapshot.elevationSource
        initialAltitudeM = snapshot.initialAltitudeM
        elevationSegments = snapshot.elevationSegments
        selectedPointIndex = nil
        syncUndoFlags()
    }

    private func syncUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func apply(saved route: Route) {
        currentRouteId = route.id
        routeName = route.name
        routeType = route.routeType
        elevationSource = route.elevationSource
        initialAltitudeM = route.elevationProfile.initialAltitudeM
        elevationSegments = route.elevationProfile.segments
        draftPoints = route.orderedPoints()
        waypoints = route.waypoints
        versions = route.versions
        createdAt = route.createdAt
        undoStack.removeAll()
        redoStack.removeAll()
        syncUndoFlags()
    }

    private static func xmlEscape(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(value) : "0"
    }
}

// MARK: - 地图与路线规划页（F54）

/// 真实 MapKit SwiftUI 地图 + 全功能编辑器。所有控件绑定 VM 的真实动作，无静态占位。
@MainActor
public struct RoutePlanningView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var vm = RoutePlanningViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showImporter: Bool = false
    @State private var showImportConfirm: Bool = false
    @State private var shareURL: URL? = nil
    @State private var showElevationEditor: Bool = false
    @State private var newSegmentKind: ElevationSegmentKind = .uphill
    @State private var newSegmentSlope: Double = 3
    @State private var newSegmentLength: Double = 200

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                header
                mapSection
                metricsSection
                editorControls
                routeTypeSection
                elevationSection
                versionSection
                savedRoutesSection
                errorSection
                footer
            }
            .padding(AppTheme.Spacing.lg)
        }
        .navigationTitle(AppRoute.routePlanning.title)
        .task { await vm.load() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .confirmationDialog("确认应用 GPX 导入结果", isPresented: $showImportConfirm) {
            Button("应用到当前路线") { vm.applyImport() }
            Button("取消", role: .cancel) { vm.cancelImport() }
        } message: {
            Text(vm.importWarnings.joined(separator: "\n"))
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

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("路线编辑")
                    .font(.headline)
                Spacer(minLength: 2)
                Text(vm.lastActionMessage)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            Text("点位由地图点击 / 拖动产生；海拔为用户自定义假设值，绝不臆造真实高程")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            TextField("路线名称", text: $vm.routeName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("路线名称输入框")
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("地图（主要视觉背景）")
                .font(.caption.weight(.semibold))
            RouteMapView(
                points: vm.mapPoints,
                cameraPosition: $cameraPosition,
                annotations: vm.annotations,
                progress: 1,
                onAddPoint: { coordinate in vm.addPoint(coordinate) },
                onSelectPoint: { index in vm.selectPoint(index) },
                onMovePoint: { index, coordinate in vm.movePoint(index, coordinate) }
            )
            if let index = vm.selectedPointIndex {
                HStack {
                    Text("已选中第 \(index + 1) 个点")
                        .font(.caption)
                    Spacer(minLength: 2)
                    Button("删除该点") { vm.removePoint(at: index) }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("删除选中的路线点")
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("真实计算的路线指标")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: AppTheme.Spacing.md)],
                spacing: AppTheme.Spacing.md
            ) {
                MetricCard(title: "路线长度", value: Units.formatDistanceKm(vm.totalLengthM),
                           detail: "Haversine / CLLocation 统一口径")
                MetricCard(title: "选中处方向",
                           value: AppTheme.metricNumberFormat(vm.courseDegreesAtSelected, unit: "°", digits: 1),
                           detail: "正北顺时针")
                MetricCard(title: "选中处坡度",
                           value: AppTheme.metricNumberFormat(vm.slopePercentAtSelected, unit: "%", digits: 2),
                           detail: "Δh / 水平距离")
                MetricCard(title: "选中处海拔",
                           value: AppTheme.metricNumberFormat(vm.altitudeAtSelected, unit: "m", digits: 1),
                           detail: vm.elevationSource.localizedDescription)
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var editorControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("编辑与文件")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: AppTheme.Spacing.sm)],
                spacing: AppTheme.Spacing.sm
            ) {
                ActionButton(title: "撤销", symbol: "arrow.uturn.backward", isDisabled: !vm.canUndo) { vm.undo() }
                ActionButton(title: "重做", symbol: "arrow.uturn.forward", isDisabled: !vm.canRedo) { vm.redo() }
                ActionButton(title: "清空点位", symbol: "trash", style: .destructive) { vm.clearPoints() }
                ActionButton(title: "保存路线", symbol: "square.and.arrow.down", style: .prominent) { vm.save() }
                ActionButton(title: "另存副本", symbol: "doc.on.doc") { vm.duplicate() }
                ActionButton(title: "导入 GPX", symbol: "square.and.arrow.up") { showImporter = true }
                ActionButton(title: "导出 GPX", symbol: "arrow.up.doc") {
                    do { shareURL = try vm.exportGPX() } catch { vm.reportError(error) }
                }
                ActionButton(title: "用此路线仿真", symbol: "testtube.2") { vm.useForSimulation() }
                ActionButton(title: "参考此路线实跑", symbol: "figure.run") { vm.useForLiveRun() }
            }
            Picker("导出来源标记", selection: $vm.exportOrigin) {
                ForEach([DataOrigin.simulated, DataOrigin.real], id: \.self) { origin in
                    Text(origin.displayText).tag(origin)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("选择导出文件的来源标记")
            Text("导出的仿真路线默认带 SIMULATED 标记；文件仅写入本地临时目录，不上传")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .controlBar, interactive: true)
    }

    private var routeTypeSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("路线类型")
                .font(.headline)
            Picker("路线类型", selection: Binding(
                get: { vm.routeType },
                set: { vm.setRouteType($0) }
            )) {
                ForEach(RouteType.allCases, id: \.self) { type in
                    Text(type.localizedDescription).tag(type)
                }
            }
            .pickerStyle(.segmented)
            Text("环形自动补齐闭合点；折返按三角波往返；自由路线钳制到终点，不外推坐标")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var elevationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("海拔剖面编辑")
                    .font(.headline)
                Spacer(minLength: 2)
                Button(showElevationEditor ? "收起" : "展开编辑") {
                    showElevationEditor.toggle()
                }
                .font(.caption)
            }
            Picker("海拔来源", selection: Binding(
                get: { vm.elevationSource },
                set: { newValue in
                    do { try vm.setElevationSource(newValue) } catch { vm.reportError(error) }
                }
            )) {
                ForEach(ElevationSource.allCases, id: \.self) { source in
                    Text(source.localizedDescription).tag(source)
                }
            }
            .pickerStyle(.menu)

            ElevationProfileChart(
                profile: vm.currentRoute().elevationProfile,
                totalLengthM: vm.totalLengthM,
                selectedArcLengthM: $vm.selectedArcLengthM,
                onSelectArcLength: { vm.selectArcLength($0) }
            )

            if showElevationEditor {
                Stepper(value: $vm.initialAltitudeM, in: -200...4_000, step: 1) {
                    Text("初始海拔 h0 \(AppTheme.metricNumberFormat(vm.initialAltitudeM, unit: "m", digits: 0))")
                        .font(.caption)
                }
                .onChange(of: vm.initialAltitudeM) { _, newValue in vm.setInitialAltitude(newValue) }

                Picker("新增剖面段类型", selection: $newSegmentKind) {
                    ForEach(ElevationSegmentKind.allCases, id: \.self) { kind in
                        Text(kind.localizedDescription).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Stepper(value: $newSegmentSlope, in: -15...15, step: 0.5) {
                    Text("坡度 \(AppTheme.metricNumberFormat(newSegmentSlope, unit: "%", digits: 1))")
                        .font(.caption)
                }
                Stepper(value: $newSegmentLength, in: 50...2_000, step: 50) {
                    Text("段长 \(AppTheme.metricNumberFormat(newSegmentLength, unit: "m", digits: 0))")
                        .font(.caption)
                }
                ActionButton(title: "新增剖面段", symbol: "plus", style: .bordered) {
                    vm.addElevationSegment(
                        kind: newSegmentKind,
                        slopePercent: newSegmentSlope,
                        lengthM: newSegmentLength
                    )
                }
                ForEach(vm.elevationSegments) { segment in
                    HStack {
                        Text("\(segment.kind.localizedDescription)："
                             + "\(AppTheme.metricNumberFormat(segment.slopePercent, unit: "%", digits: 1))，"
                             + "\(AppTheme.metricNumberFormat(segment.lengthM, unit: "m", digits: 0))")
                            .font(.caption)
                        Spacer(minLength: 2)
                        Button("删除") { vm.removeElevationSegment(id: segment.id) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .accessibilityLabel("删除该海拔剖面段")
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: true)
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("版本历史（\(vm.versions.count)）")
                .font(.headline)
            if vm.versions.isEmpty {
                Text("尚无版本，点击「保存路线」后自动生成可回溯快照")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.versions) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.changeNote.isEmpty ? version.id : version.changeNote)
                                .font(.caption)
                            Text(version.createdAt.iso8601UTCString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Button("回溯") { vm.selectVersion(version) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    private var savedRoutesSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("已保存路线（\(vm.savedRoutes.count)）")
                .font(.headline)
            if vm.savedRoutes.isEmpty {
                EmptyStateView(
                    origin: .simulated,
                    title: "还没有保存的路线",
                    message: "在地图上点击至少 2 个点并保存，路线会写入本地中性配置域，可随时回溯版本。",
                    actionTitle: "查看历史记录",
                    action: { vm.openHistory() },
                    secondaryTitle: "海拔来源设置",
                    secondaryAction: { vm.openSettings() }
                )
            } else {
                ForEach(vm.savedRoutes) { route in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.name).font(.caption.weight(.medium))
                            Text("\(Units.formatDistanceKm(route.totalDistanceM))｜\(route.routeType.localizedDescription)｜版本 \(route.versions.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Button("载入") { vm.selectSavedRoute(route) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .glassCard(role: .card, interactive: false)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = vm.errorMessage {
            ErrorStateView(
                origin: vm.exportOrigin,
                error: AppError.parameterConflict(reason: message),
                primaryTitle: "重新载入路线",
                primaryAction: { Task { await vm.load() } },
                secondaryTitle: "前往设置",
                secondaryAction: { vm.openSettings() }
            )
        }
    }

    private var footer: some View {
        Text("路线为用户自建的中性对象，不含任何第三方平台点位生成逻辑；导入来源与采集时间在导入确认框中标注")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 文件导入

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                vm.reportError(AppError.exportFailed(reason: "未选择任何文件"))
                return
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                vm.importGPX(data)
                showImportConfirm = vm.importResult != nil
                if vm.importResult == nil, let message = vm.errorMessage {
                    vm.reportError(AppError.exportFailed(reason: message))
                }
            } catch {
                vm.reportError(error)
            }
        case .failure(let error):
            vm.reportError(error)
        }
    }
}

// MARK: - VM 错误入口（避免视图层重复构造错误对象）

private extension RoutePlanningViewModel {
    func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
        lastActionMessage = "操作未完成：\(error.localizedDescription)"
    }
}
