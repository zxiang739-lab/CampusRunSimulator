import Foundation
import SwiftData

// MARK: - 双存储域仓库（F44 / §7.8 / §B.11.2）

/// 按 `dataOrigin` 强制路由到两个独立 `ModelContainer`，所有 CRUD 都在对应域内完成。
///
/// 合规硬约束（AC-C7）：
/// - `save` 前置校验 session 与 points 的来源 / id 空间 / 容器域一致，脏数据不入库；
/// - `unclassified()` 隔离缺 `dataOrigin` 或非法 id 的对象，**绝不默认 real**；
/// - `clear(origin:)` 只作用于对应容器，两类数据可分别清除；
/// - `duplicate` 保留 `originChain` 且来源不变，**不存在任何 `simulated → real` 转换方法**。
public actor DefaultRunRepository: RunRepository {

    private let stores: PersistentStores

    public init(stores: PersistentStores) {
        self.stores = stores
    }

    /// 两个容器是否物理分离（供设置页 / 单测断言）。
    public func areStoresPhysicallySeparate() -> Bool {
        stores.arePhysicallySeparate
    }

    // MARK: RunRepository · 写入

    public func save(_ session: RunSession, points: [TrackPoint]) async throws {
        // 前置校验 1：session id 必须属于其来源的独立 id 空间。
        guard session.hasValidOriginID else {
            await logUnclassified(count: 1, origin: session.dataOrigin)
            throw AppError.unclassifiedDataIsolated
        }
        // 前置校验 2：全部采样点必须与 session 同源、同 sessionId，绝不跨容器写入。
        guard points.allSatisfy({
            $0.dataOrigin == session.dataOrigin && $0.sessionId == session.id
        }) else {
            await logUnclassified(count: points.count, origin: session.dataOrigin)
            throw AppError.unclassifiedDataIsolated
        }
        // 唯一路由入口：容器由 `PersistentStores.container(for:)` 决定，调用方无法指定错容器。
        let context = ModelContext(stores.container(for: session.dataOrigin))
        let existing = (try? context.fetch(FetchDescriptor<SDRunSession>())) ?? []
        for model in existing where model.id == session.id {
            context.delete(model)
        }
        let sessionObject = try SDMapper.fromValue(session)
        context.insert(sessionObject)
        for point in points {
            let pointObject = try SDMapper.fromValue(point)
            // 建立反向关系，保证 `SDRunSession.points` 的级联删除生效。
            pointObject.session = sessionObject
            context.insert(pointObject)
        }
        try context.save()
        await AuditLogger.shared.log(AuditEvent(
            sessionId: session.id,
            dataOrigin: session.dataOrigin,
            kind: AuditEvent.Kind.repositorySaved,
            count: points.count,
            resultCode: "ok"
        ))
    }

    // MARK: RunRepository · 读取

    public func fetch(origin: DataOrigin, predicate: RunPredicate) async throws -> [RunSession] {
        let context = ModelContext(stores.container(for: origin))
        let models = (try? context.fetch(FetchDescriptor<SDRunSession>())) ?? []
        var sessions: [RunSession] = []
        var dirtyCount = 0
        for model in models {
            guard let value = SDMapper.toValue(model), value.dataOrigin == origin else {
                // 脏数据不进入正常列表，交由 unclassified() 隔离。
                dirtyCount += 1
                continue
            }
            sessions.append(value)
        }
        if dirtyCount > 0 {
            await logUnclassified(count: dirtyCount, origin: origin)
        }
        return predicate.apply(to: sessions)
    }

    public func points(sessionId: String) async throws -> [TrackPoint] {
        // sessionId 前缀决定容器；无法识别的 id 属于脏数据，直接隔离，不混合两域结果。
        guard let origin = OriginID.domain(of: sessionId) else {
            await logUnclassified(count: 1, origin: .simulated)
            return []
        }
        let context = ModelContext(stores.container(for: origin))
        let models = (try? context.fetch(FetchDescriptor<SDTrackPoint>())) ?? []
        var result: [TrackPoint] = []
        for model in models where model.sessionId == sessionId {
            guard let value = SDMapper.toValue(model), value.dataOrigin == origin else {
                continue
            }
            result.append(value)
        }
        result.sort { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.segmentIndex < rhs.segmentIndex
            }
            return lhs.timestamp < rhs.timestamp
        }
        return result
    }

    public func routes() async throws -> [Route] {
        // Route 是用户自建中立对象（无 dataOrigin），两个容器均可存放，按 id 去重合并。
        var result: [Route] = []
        var seen = Set<String>()
        for container in [stores.simulatedStore, stores.realStore] {
            let context = ModelContext(container)
            let models = (try? context.fetch(FetchDescriptor<SDRoute>())) ?? []
            for model in models {
                guard let route = SDMapper.toValue(model), !seen.contains(route.id) else {
                    continue
                }
                seen.insert(route.id)
                result.append(route)
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    public func presets() async throws -> [RulePreset] {
        // 规则预设恒 `.simulated`，只从 simulatedStore 读取。
        let context = ModelContext(stores.simulatedStore)
        let models = (try? context.fetch(FetchDescriptor<SDRulePreset>())) ?? []
        return models.compactMap { SDMapper.toValue($0) }
            .sorted { $0.displayName < $1.displayName }
    }

    public func profiles() async throws -> [SimulationProfile] {
        // 仿真配置恒 `.simulated`，只从 simulatedStore 读取。
        let context = ModelContext(stores.simulatedStore)
        let models = (try? context.fetch(FetchDescriptor<SDSimulationProfile>())) ?? []
        return models.compactMap { SDMapper.toValue($0) }
    }

    /// 脏数据隔离：缺 `dataOrigin` / 非法 id 的持久化对象转为「未分类」占位会话。
    /// 占位 id 以 `unclassified_` 开头，不属任何来源 id 空间，因此不会进入 `fetch` 的正常列表；
    /// 占位来源固定 `.simulated`（安全占位），**绝不默认显示为真实记录**。
    public func unclassified() async throws -> [RunSession] {
        var result: [RunSession] = []
        for origin in [DataOrigin.simulated, DataOrigin.real] {
            let context = ModelContext(stores.container(for: origin))
            let models = (try? context.fetch(FetchDescriptor<SDRunSession>())) ?? []
            for model in models {
                let isDirty = SDMapper.toValue(model) == nil
                    || !OriginID.isValid(model.id, for: origin)
                if isDirty {
                    result.append(Self.makeUnclassifiedPlaceholder(model))
                }
            }
        }
        if !result.isEmpty {
            await AuditLogger.shared.log(AuditEvent(
                dataOrigin: .simulated,
                kind: AuditEvent.Kind.unclassifiedIsolated,
                count: result.count,
                resultCode: AppError.unclassifiedDataIsolated.resultCode
            ))
        }
        return result
    }

    // MARK: RunRepository · 删除

    public func delete(ids: [String], origin: DataOrigin) async throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let context = ModelContext(stores.container(for: origin))
        let sessions = (try? context.fetch(FetchDescriptor<SDRunSession>())) ?? []
        for model in sessions where idSet.contains(model.id) {
            context.delete(model)
        }
        let points = (try? context.fetch(FetchDescriptor<SDTrackPoint>())) ?? []
        for model in points where idSet.contains(model.sessionId) {
            context.delete(model)
        }
        try context.save()
        await AuditLogger.shared.log(AuditEvent(
            dataOrigin: origin,
            kind: AuditEvent.Kind.repositoryDeleted,
            count: ids.count,
            resultCode: "ok"
        ))
    }

    /// 只清除对应容器的历史记录（会话 / 采样点 / 导出审计记录），配置类对象保留。
    /// 两个容器绝不合并，清除一方不影响另一方。
    public func clear(origin: DataOrigin) async throws {
        let context = ModelContext(stores.container(for: origin))
        let sessions = (try? context.fetch(FetchDescriptor<SDRunSession>())) ?? []
        for model in sessions { context.delete(model) }
        let points = (try? context.fetch(FetchDescriptor<SDTrackPoint>())) ?? []
        for model in points { context.delete(model) }
        let records = (try? context.fetch(FetchDescriptor<SDExportRecord>())) ?? []
        for model in records { context.delete(model) }
        try context.save()
        await AuditLogger.shared.log(AuditEvent(
            dataOrigin: origin,
            kind: AuditEvent.Kind.repositoryCleared,
            count: sessions.count,
            resultCode: "ok"
        ))
    }

    // MARK: RunRepository · 另存副本

    /// 另存副本：复用 `RunSession.duplicate()` 保留 `originChain`，来源**保持不变**。
    /// 采样点重新映射到新 sessionId / 新 id，仍写入同一来源域的同一容器。
    /// **不存在任何 `simulated → real` 的转换 / 复制 / 导出方法。**
    public func duplicate(_ session: RunSession) async throws -> RunSession {
        guard session.hasValidOriginID else {
            throw AppError.unclassifiedDataIsolated
        }
        let copy = session.duplicate()
        let originalPoints = try await points(sessionId: session.id)
        let remapped = originalPoints.enumerated().map { index, point in
            Self.remap(point, to: copy, index: index)
        }
        try await save(copy, points: remapped)
        return copy
    }

    // MARK: - 私有：占位与重映射

    /// 把脏数据对象包装为「未分类」占位会话（来源取安全占位 `.simulated`，绝不默认 real）。
    private static func makeUnclassifiedPlaceholder(_ model: SDRunSession) -> RunSession {
        RunSession(
            id: "unclassified_" + model.id,
            dataOrigin: .simulated,
            startTime: model.startTime,
            endTime: model.endTime,
            durationSeconds: model.durationSeconds,
            totalDistanceMeters: model.totalDistanceMeters,
            avgSpeedMps: model.avgSpeedMps,
            avgPaceSecPerKm: model.avgPaceSecPerKm,
            totalSteps: model.totalSteps,
            elevationGainM: model.elevationGainM,
            elevationLossM: model.elevationLossM,
            routeId: model.routeId,
            simulationProfileId: model.simulationProfileId,
            rulePresetId: model.rulePresetId,
            note: "\(AppConstants.unclassifiedSectionName)：缺少或非法 dataOrigin，绝不默认真实记录",
            createdAt: model.createdAt,
            schemaVersion: model.schemaVersion,
            originChain: []
        )
    }

    /// 采样点重映射：所有 `let` 字段逐项复制，仅替换 id / sessionId，来源保持同源。
    private static func remap(_ point: TrackPoint, to session: RunSession, index: Int) -> TrackPoint {
        TrackPoint(
            id: OriginID.makeID(session.dataOrigin, suffix: "\(session.id)_\(index)"),
            sessionId: session.id,
            dataOrigin: session.dataOrigin,
            timestamp: point.timestamp,
            elapsedSeconds: point.elapsedSeconds,
            latitude: point.latitude,
            longitude: point.longitude,
            altitudeM: point.altitudeM,
            horizontalAccuracyM: point.horizontalAccuracyM,
            verticalAccuracyM: point.verticalAccuracyM,
            courseDegrees: point.courseDegrees,
            speedMps: point.speedMps,
            speedAccuracyMps: point.speedAccuracyMps,
            instantPaceSecPerKm: point.instantPaceSecPerKm,
            avgPaceSecPerKm: point.avgPaceSecPerKm,
            cadenceSpm: point.cadenceSpm,
            strideLengthM: point.strideLengthM,
            cumulativeSteps: point.cumulativeSteps,
            cumulativeDistanceM: point.cumulativeDistanceM,
            elevationGainSoFarM: point.elevationGainSoFarM,
            elevationLossSoFarM: point.elevationLossSoFarM,
            segmentIndex: point.segmentIndex,
            qualityFlags: point.qualityFlags
        )
    }

    private func logUnclassified(count: Int, origin: DataOrigin) async {
        await AuditLogger.shared.log(AuditEvent(
            dataOrigin: origin,
            kind: AuditEvent.Kind.unclassifiedIsolated,
            count: count,
            resultCode: AppError.unclassifiedDataIsolated.resultCode
        ))
    }
}
