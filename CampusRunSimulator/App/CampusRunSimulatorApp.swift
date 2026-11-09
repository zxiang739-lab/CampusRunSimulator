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

// MARK: - @main 入口

/// App 入口：注入双 `ModelContainer`，承接生命周期，挂载根视图。
@main
public struct CampusRunSimulatorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var stores: PersistentStores?
    @State private var loadError: AppError?
    @State private var reloadCount: Int = 0

    public init() {
        let result = CampusRunSimulatorApp.loadStores()
        switch result {
        case .success(let loaded):
            _stores = State(initialValue: loaded)
            _loadError = State(initialValue: nil)
        case .failure(let error):
            _stores = State(initialValue: nil)
            _loadError = State(initialValue: error)
        }
        _reloadCount = State(initialValue: 0)
    }

    public var body: some Scene {
        WindowGroup {
            Group {
                if let stores {
                    RootView()
                        // 默认环境注入模拟域容器，供 @Query 使用；真实域容器经自定义 Key 注入。
                        .modelContainer(stores.simulatedStore)
                        .environment(\.persistentStores, stores)
                } else {
                    StorageRecoveryView(
                        error: loadError ?? .persistenceMigrationFailed,
                        retry: { reload() }
                    )
                }
            }
            .id(reloadCount)
        }
    }

    /// 重试创建双容器（真实动作，不静默吞错）。
    private func reload() {
        let result = CampusRunSimulatorApp.loadStores()
        switch result {
        case .success(let loaded):
            stores = loaded
            loadError = nil
        case .failure(let error):
            stores = nil
            loadError = error
        }
        reloadCount += 1
    }

    /// 加载双容器：优先持久化；失败时降级为双独立内存容器；再失败才返回错误。
    /// 降级路径同样保持两个物理独立的 `ModelContainer`，绝不合并两类数据。
    private static func loadStores() -> Result<PersistentStores, AppError> {
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
