import SwiftUI
import SwiftData
import UIKit

// MARK: - 环境注入：双容器

/// 把双独立容器注入 SwiftUI 环境（`.modelContainer` 只能注入一个，另一个通过自定义 EnvironmentKey 传递）。
public struct PersistentStoresEnvironmentKey: EnvironmentKey {
    public static let defaultValue: PersistentStores? = nil
}

public extension EnvironmentValues {
    /// 双存储域（App 入口注入；nil 表示数据层尚未就绪）。
    var persistentStores: PersistentStores? {
        get { self[PersistentStoresEnvironmentKey.self] }
        set { self[PersistentStoresEnvironmentKey.self] = newValue }
    }
}

/// 生命周期通知（AppDelegate → RootView / 各页面）。
public extension Notification.Name {
    static let campusRunDidEnterBackground = Notification.Name("campusRunDidEnterBackground")
    static let campusRunWillEnterForeground = Notification.Name("campusRunWillEnterForeground")
    static let campusRunPermissionStateChanged = Notification.Name("campusRunPermissionStateChanged")
}

// MARK: - AppDelegate

/// 承接后台 / 前台 / 权限变更生命周期；只写审计日志与发通知，不触碰任何轨迹数据。
public final class AppDelegate: NSObject, UIApplicationDelegate {
    public override init() {
        super.init()
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task {
            await AuditLogger.shared.log(AuditEvent(
                dataOrigin: .simulated,
                kind: AuditEvent.Kind.appLaunch,
                resultCode: "ok"
            ))
        }
        return true
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        Task {
            await AuditLogger.shared.log(AuditEvent(
                dataOrigin: .real,
                kind: AuditEvent.Kind.appBackground,
                resultCode: "ok"
            ))
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .campusRunDidEnterBackground, object: nil)
        }
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        Task {
            await AuditLogger.shared.log(AuditEvent(
                dataOrigin: .real,
                kind: AuditEvent.Kind.appForeground,
                resultCode: "ok"
            ))
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .campusRunWillEnterForeground, object: nil)
        }
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .campusRunPermissionStateChanged, object: nil)
        }
    }

    public func applicationWillTerminate(_ application: UIApplication) {
        Task {
            await AuditLogger.shared.log(AuditEvent(
                dataOrigin: .simulated,
                kind: "app_terminate",
                resultCode: "ok"
            ))
        }
    }
}

// MARK: - 存储恢复视图（数据层初始化失败时的真实降级出口）

/// 持久化容器创建失败时展示：提供「重试」真实动作，不显示静态内容、不触发崩溃。
private struct StorageRecoveryView: View {
    let error: AppError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 48))
                .accessibilityHidden(true)
            Text("本地数据初始化失败")
                .font(.title2.bold())
            Text(error.localizedDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(error.recoverySuggestion ?? "")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Divider()
            Text(AppConstants.complianceStatement)
                .font(.footnote)
                .multilineTextAlignment(.center)
            Text("测试数据与真实记录始终使用两个独立存储域，失败时也不会合并")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: retry) {
                Text("重试初始化")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("重试初始化本地数据")
        }
        .padding(24)
    }
}

// MARK: - @main 入口（重写版：启动阶段绝不在主线程创建 SwiftData 容器）

/// App 入口。
///
/// **关键根治点**：`ModelContainer(for:migrationPlan:configurations:)` 会同步打开 SQLite、
/// 加载 10 个 `@Model` 的 schema 并跑迁移计划，是重量级阻塞操作。此前把它放在 `App.init()`
/// 里、在主线程执行两次（双容器），再叠加 `AppSettingsStore.init` 里的同步 `loadSettings()`，
/// 直接把主线程堵死 —— 表现为「进入 App 整体卡死、点不动」。这也是为何 v0.1.0 的合规全屏页
/// 「关不掉」：底层 RootView 早已卡死，dismiss 永远无法完成。
///
/// 现改为：`init()` 不做任何 IO；先显示占位 `ProgressView`；用 `.task` 在**后台线程**创建双容器，
/// 完成后再切到 `RootView`。主线程全程只做轻量渲染，绝不阻塞。
@main
public struct CampusRunSimulatorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var stores: PersistentStores? = nil
    @State private var loadError: AppError? = nil
    /// 递增触发重新 bootstrap（存储恢复页的「重试」真实动作）。
    @State private var attempt: Int = 0

    public init() {
        // 空实现：不创建任何 ModelContainer、不读磁盘、不碰 SwiftData。
    }

    public var body: some Scene {
        WindowGroup {
            #if CAMPUSRUN_TEST_HOST
            // 仅测试编译条件（CI 单元测试步骤传入 CAMPUSRUN_TEST_HOST）：
            // 快速启动路径，跳过完整 UI 与数据层，避免 XCTest 宿主连接超时。
            Group {
                Text("TestHost").accessibilityIdentifier("testHost")
            }
            #else
            Group {
                if let stores {
                    RootView()
                        // 默认环境注入模拟域容器，供 @Query 使用；真实域容器经自定义 Key 注入。
                        .modelContainer(stores.simulatedStore)
                        .environment(\.persistentStores, stores)
                } else if let loadError {
                    StorageRecoveryView(
                        error: loadError,
                        retry: {
                            self.loadError = nil
                            self.attempt += 1
                        }
                    )
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在准备本地数据…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: attempt) { await bootstrap() }
            #endif
        }
    }

    /// 后台创建双容器；完成后再回主线程赋值。
    private func bootstrap() async {
        guard stores == nil, loadError == nil else { return }
        // 在后台线程执行同步的容器构建，绝不占用主线程。
        let result = await Task.detached(priority: .userInitiated) {
            Self.loadStores()
        }.value
        switch result {
        case .success(let loaded):
            // 先交给 UI 层服务，再切换视图，保证任何页面 .task 首次访问时容器已就绪。
            AppServices.shared.configure(loaded)
            stores = loaded
            loadError = nil
        case .failure(let error):
            stores = nil
            loadError = error
        }
    }

    /// 加载双容器：优先持久化；失败时降级为双独立内存容器；再失败才返回错误。
    /// 降级路径同样保持两个物理独立的 `ModelContainer`，绝不合并两类数据。
    /// 说明：本方法为同步阻塞实现，**只允许在后台线程调用**（见 `bootstrap()`）。
    nonisolated private static func loadStores() -> Result<PersistentStores, AppError> {
        do {
            let stores = try ModelContainerFactory.makePersistent()
            return .success(stores)
        } catch {
            // 降级：两个独立 in-memory 容器（仍分域，只是不持久化）。
            if let fallback = try? ModelContainerFactory.makeInMemoryPair() {
                Task {
                    await AuditLogger.shared.log(AuditEvent(
                        dataOrigin: .simulated,
                        kind: AuditEvent.Kind.persistenceFallback,
                        resultCode: "in_memory_pair"
                    ))
                }
                return .success(fallback)
            }
            if let appError = error as? AppError {
                return .failure(appError)
            }
            return .failure(.persistenceMigrationFailed)
        }
    }
}
