import Foundation
import SwiftData

/// 双独立持久化域（§7.8 / AC-C7）。
/// `simulatedStore` 与 `realStore` 各自拥有独立 store URL、独立 `ModelConfiguration`、独立 id 空间，
/// **绝不共用一个 `ModelContainer`**；本期不启用 iCloud，避免两类数据同步汇合。
public struct PersistentStores {
    public let simulatedStore: ModelContainer
    public let realStore: ModelContainer
    public let simulatedStoreURL: URL?
    public let realStoreURL: URL?
    /// false 表示已降级到内存模式（仍保持两个独立容器，只是不持久化）。
    public let isPersistent: Bool

    public init(
        simulatedStore: ModelContainer,
        realStore: ModelContainer,
        simulatedStoreURL: URL? = nil,
        realStoreURL: URL? = nil,
        isPersistent: Bool = true
    ) {
        self.simulatedStore = simulatedStore
        self.realStore = realStore
        self.simulatedStoreURL = simulatedStoreURL
        self.realStoreURL = realStoreURL
        self.isPersistent = isPersistent
    }

    /// 按来源强制路由到对应容器（仓库层唯一入口）。
    public func container(for origin: DataOrigin) -> ModelContainer {
        switch origin {
        case .simulated: return simulatedStore
        case .real: return realStore
        }
    }

    /// 两个容器是否物理独立（不同对象；持久化时 store URL 还必须不同），供 V2.3 验收断言。
    public var arePhysicallySeparate: Bool {
        guard simulatedStore !== realStore else { return false }
        // 内存降级模式下两个 URL 均为 nil，仍以对象身份判定为分离。
        if simulatedStoreURL == nil && realStoreURL == nil { return true }
        return simulatedStoreURL != realStoreURL
    }
}

/// Schema V1：本期唯一的版本。
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    /// 全部 10 个 `SD*` 持久化类型。
    public static var models: [any PersistentModel.Type] {
        [
            SDRunSession.self,
            SDTrackPoint.self,
            SDRoute.self,
            SDRouteVersion.self,
            SDRulePreset.self,
            SDSimulationProfile.self,
            SDAppSettings.self,
            SDPermissionState.self,
            SDExportRecord.self,
            SDErrorEvent.self
        ]
    }
}

/// 迁移计划（§7.8）。
/// - 合规硬约束：**任何 stage 都不得改写 `dataOrigin`**、不得新增跨来源关联、不得合并两个容器。
/// - V1 是首个版本：`stages.count` 必须等于 `schemas.count - 1`，因此当前为 0 个 stage；
///   后续新增字段一律给默认值，走 lightweight 迁移，永不写自定义改写来源的 stage。
public enum AppMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        // V1 为首个版本（schemas = 1 个），Apple 约束 stage 数 = schemas 数 - 1 = 0。
        // 严禁在此处追加任何自定义 MigrationStage 来改写 dataOriginRaw / 合并容器 / 跨来源关联。
        []
    }
}

/// 容器工厂：持久化双容器、内存测试容器、内存降级双容器。
public enum ModelContainerFactory {
    /// 磁盘目录名（位于 Application Support 下）。
    private static let storeDirectoryName = "CampusRunSimulator"
    private static let simulatedStoreFileName = "simulated.store"
    private static let realStoreFileName = "real.store"

    /// 当前 schema（全部 SD 类型）。
    private static var schema: Schema {
        Schema(SchemaV1.models)
    }

    /// 构造一个持久化容器（独立 name + 独立 URL）。
    private static func persistentContainer(name: String, url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(name, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: configuration
        )
    }

    /// 构造一个纯内存容器（不触碰磁盘，不初始化任何硬件服务）。
    private static func inMemoryContainer(name: String) throws -> ModelContainer {
        let configuration = ModelConfiguration(name, isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: configuration
        )
    }

    /// 双独立持久化容器（F08 App 入口使用）。
    /// - Throws: 目录创建或容器初始化失败时抛出（App 层会降级到双内存容器）。
    public static func makePersistent() throws -> PersistentStores {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = baseURL.appendingPathComponent(storeDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let simulatedURL = directory.appendingPathComponent(simulatedStoreFileName)
        let realURL = directory.appendingPathComponent(realStoreFileName)

        // 两个独立 ModelConfiguration + 两个独立 ModelContainer，物理分域。
        let simulatedStore = try persistentContainer(name: "CampusRunSimulated", url: simulatedURL)
        let realStore = try persistentContainer(name: "CampusRunReal", url: realURL)

        return PersistentStores(
            simulatedStore: simulatedStore,
            realStore: realStore,
            simulatedStoreURL: simulatedURL,
            realStoreURL: realURL,
            isPersistent: true
        )
    }

    /// 单元测试容器（F60–F64 使用）：`isStoredInMemoryOnly: true`，不依赖真机硬件。
    public static func makeInMemory() throws -> ModelContainer {
        try inMemoryContainer(name: "CampusRunInMemoryTests")
    }

    /// 降级用的双独立内存容器：App 在持久化失败时使用。
    /// 即便降级，两个来源仍保持物理隔离（两个不同 `ModelContainer`、不同配置名）。
    public static func makeInMemoryPair() throws -> PersistentStores {
        let simulatedStore = try inMemoryContainer(name: "CampusRunSimulatedInMemory")
        let realStore = try inMemoryContainer(name: "CampusRunRealInMemory")
        return PersistentStores(
            simulatedStore: simulatedStore,
            realStore: realStore,
            simulatedStoreURL: nil,
            realStoreURL: nil,
            isPersistent: false
        )
    }

    /// 校验两容器物理分离的静态辅助（供测试与设置页自检）。
    public static func verifySeparation(_ stores: PersistentStores) -> Bool {
        guard stores.arePhysicallySeparate else { return false }
        guard let sim = stores.simulatedStoreURL, let real = stores.realStoreURL else {
            // 内存模式下 URL 均为 nil，改以对象身份与配置名区分。
            return stores.simulatedStore !== stores.realStore
        }
        return sim.lastPathComponent != real.lastPathComponent
    }
}
