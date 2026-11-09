import Foundation
import CoreLocation

// MARK: - 真实定位提供者（F32 / §A.1.1）

/// `CLLocationManager` 封装，**仅 REAL 链路**：绝不构造虚拟定位、绝不注入任何第三方 App 的位置。
/// `LocationSample` 的 `dataOrigin` 由 BATCH_1 冻结的初始化器内部强制为 `.real`。
/// 内部可变状态用 `NSLock` 保护，使非 `@MainActor` 的 delegate 回调与公共方法线程安全。
public final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate, @unchecked Sendable {

    private let manager = CLLocationManager()
    private let stream: AsyncStream<LocationSample>
    private let continuation: AsyncStream<LocationSample>.Continuation
    private let gapStream: AsyncStream<Date>
    private let gapContinuation: AsyncStream<Date>.Continuation
    private let lock = NSLock()

    private var isRunning = false
    private var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private var preciseLocation = false
    private var lastDeliveredTimestamp: Date?

    /// 系统暂停 / 恢复 / 失败产生的「中断事件」时间戳流（F35 据此新建 segment，跨段不连线）。
    public var gaps: AsyncStream<Date> {
        gapStream
    }

    /// 协议要求的定位采样流。
    public var samples: AsyncStream<LocationSample> {
        stream
    }

    /// 当前权限快照；读取不可判定的健康字段一律 `.unknown`「无数据」。
    public var authorizationSnapshot: PermissionSnapshot {
        lock.lock()
        let status = authorizationStatus
        let precise = preciseLocation
        lock.unlock()
        return PermissionSnapshot(
            locationStatus: Self.permissionStatus(from: status),
            preciseLocationEnabled: precise,
            motionStatus: .unknown,
            healthKitReadStatus: .unknown,
            healthKitShareStatus: .unknown,
            backgroundDeliveryAvailable: false,
            capturedAt: Date(),
            note: "真实链路定位状态；权限不可判定项按「无数据」呈现"
        )
    }

    public override init() {
        let samplePair = AsyncStream.makeStream(of: LocationSample.self)
        let gapPair = AsyncStream.makeStream(of: Date.self)
        self.stream = samplePair.stream
        self.continuation = samplePair.continuation
        self.gapStream = gapPair.stream
        self.gapContinuation = gapPair.continuation
        super.init()
        manager.delegate = self
        // 官方健身类最佳实践（§A.1.1）：BestForNavigation 需精确位置授权才真正生效。
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.activityType = .fitness
        // Info.plist 已含 UIBackgroundModes=location；前景启动后可持续后台记录。
        manager.allowsBackgroundLocationUpdates = true
        // 官方建议健身场景启用自动暂停，暂停回调触发 gap 分段（不插值）。
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true
        authorizationStatus = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
    }

    deinit {
        // 幂等收尾：正常流程由 stop() 显式 finish。
        continuation.finish()
        gapContinuation.finish()
    }

    // MARK: LocationProvider 协议

    /// 按当前状态区分 whenInUse / always：未确定先请求「使用期间」，已 whenInUse 可升级「始终」。
    public func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .denied, .restricted:
            // 已确定状态：由设置页引导用户到系统设置，不重复弹窗。
            break
        @unknown default:
            manager.requestWhenInUseAuthorization()
        }
    }

    /// 设置页按用户明确选择调用，区分两种授权范围。
    public func requestAuthorization(always: Bool) {
        if always {
            manager.requestAlwaysAuthorization()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    public func start() throws {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw AppError.locationNotAuthorized
        }
        lock.lock()
        // 精确位置关闭时不拒绝记录：所有点由 F35 TrackFilter 标注低精度，UI 明确提示。
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        isRunning = true
        lastDeliveredTimestamp = nil
        lock.unlock()
        manager.startUpdatingLocation()
    }

    public func pause() {
        manager.stopUpdatingLocation()
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        isRunning = true
        lock.unlock()
        manager.startUpdatingLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
        lock.lock()
        isRunning = false
        lock.unlock()
        continuation.finish()
        gapContinuation.finish()
    }

    // MARK: CLLocationManagerDelegate

    public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        for location in locations {
            // 精度门限（Apple《创建体能训练路线》）：负值或 > 50 m 的点不进入路线。
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= AppConstants.accuracyGateMeters else {
                continue
            }
            // 时间戳严格单调：乱序 / 重复点直接丢弃，防止 Δt = 0 除零。
            lock.lock()
            let previous = lastDeliveredTimestamp
            lock.unlock()
            if let previous = previous, location.timestamp.timeIntervalSince(previous) <= 0 {
                continue
            }
            let sample = LocationSample(
                coordinate: location.geoPoint,
                altitudeM: location.verticalAccuracy >= 0 ? location.altitude : 0,
                horizontalAccuracyM: location.horizontalAccuracy,
                verticalAccuracyM: location.verticalAccuracy,
                courseDegrees: location.course >= 0 ? location.course : 0,
                speedMps: location.speed >= 0 ? location.speed : 0,
                timestamp: location.timestamp
            )
            lock.lock()
            lastDeliveredTimestamp = location.timestamp
            lock.unlock()
            continuation.yield(sample)
        }
    }

    /// 系统自动暂停 → 发 gap 事件：F35 新建 segment，跨段不连线、不计距、不插值。
    public func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        gapContinuation.yield(Date())
    }

    /// 恢复后同样新建分段，绝不把中断前后的点连成一条直线。
    public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        gapContinuation.yield(Date())
    }

    public func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        lock.lock()
        authorizationStatus = status
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        lock.unlock()
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失败绝不臆造坐标：发 gap 事件让上层分段并给出明确错误态。
        gapContinuation.yield(Date())
    }

    // MARK: 私有映射

    /// `CLAuthorizationStatus` → 项目统一权限状态（读取不可判定归 `.unknown`）。
    private static func permissionStatus(from status: CLAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways: return .authorizedAlways
        @unknown default: return .unknown
        }
    }
}
