import Foundation
import HealthKit
import CoreLocation

// MARK: - 健康数据服务（F34 / §A.1.3 / §B.10）

/// `HKHealthStore` 真实封装，**仅 `.real` 会话可写**。
///
/// 合规硬约束（AC-C3 / §7.12-3）：
/// - `write(session:routePoints:)` 函数体第一条语句即 `guard session.dataOrigin == .real`；
/// - 不存在任何由 `.simulated` 数据到达 `HKWorkoutBuilder` / `HKWorkoutRouteBuilder` 的路径；
/// - 读授权与写授权分别申请，读取权限不可判定按 `.unknown`「无数据」呈现；
/// - 后台 delivery 使用 Apple 允许的最长间隔 `.hourly`，observer 回调**必须调用 completion**；
/// - `routePoints` 写入前过滤 `horizontalAccuracy > 50 m` 与相邻间隔 `> 3 s`。
public actor DefaultHealthKitService: HealthKitService {

    private let store: HKHealthStore
    /// 后台观察查询必须强引用，否则系统不会继续投递。
    private var observerQuery: HKObserverQuery?

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    // MARK: HealthKitService · 授权

    /// 只申请「读取」权限（写入权限由 `requestShareAuthorization()` 单独申请）。
    public func requestReadAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AppError.healthKitUnavailable
        }
        let readTypes = Self.readObjectTypes()
        let healthStore = store
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error = error {
                    continuation.resume(
                        throwing: AppError.healthKitWriteFailed(reason: "读授权失败：\(error.localizedDescription)")
                    )
                } else if !success {
                    continuation.resume(throwing: AppError.healthKitNotAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
        await Self.logAuthorization(kind: "healthkit_read_authorization")
    }

    /// 只申请「写入」权限。仿真流程不会调用本方法。
    public func requestShareAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AppError.healthKitUnavailable
        }
        let shareTypes = Self.shareSampleTypes()
        let healthStore = store
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: shareTypes, read: []) { success, error in
                if let error = error {
                    continuation.resume(
                        throwing: AppError.healthKitWriteFailed(reason: "写授权失败：\(error.localizedDescription)")
                    )
                } else if !success {
                    continuation.resume(throwing: AppError.healthKitNotAuthorized)
                } else {
                    continuation.resume()
                }
            }
        }
        await Self.logAuthorization(kind: "healthkit_share_authorization")
    }

    /// 读取权限状态在 HealthKit 隐私语义下不可判定，恒返回 `.unknown`「无数据」；
    /// 写入权限可通过 `authorizationStatus(for:)` 判定。
    public func readStatus() async -> PermissionSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else {
            return PermissionSnapshot(
                locationStatus: .unknown,
                preciseLocationEnabled: false,
                motionStatus: .unknown,
                healthKitReadStatus: .unknown,
                healthKitShareStatus: .unknown,
                backgroundDeliveryAvailable: false,
                capturedAt: Date(),
                note: "健康数据在当前设备不可用；读取权限不可判定按「无数据」呈现"
            )
        }
        let status = store.authorizationStatus(for: HKObjectType.workoutType())
        return PermissionSnapshot(
            locationStatus: .unknown,
            preciseLocationEnabled: false,
            motionStatus: .unknown,
            healthKitReadStatus: .unknown,
            healthKitShareStatus: Self.permissionStatus(from: status),
            backgroundDeliveryAvailable: true,
            capturedAt: Date(),
            note: "健康数据读取权限不可判定，按「无数据」呈现，不展示为「被拒绝」"
        )
    }

    // MARK: HealthKitService · 写入

    /// 把真实跑步记录写入健康 App。
    /// - 合规守卫：**函数体首行** `guard session.dataOrigin == .real`，
    ///   测试数据 / SIMULATED 一律抛 `AppError.simulatedWriteForbidden`，不产生任何 HK 对象。
    public func write(session: RunSession, routePoints: [TrackPoint]) async throws {
        guard session.dataOrigin == .real else {
            await AuditLogger.shared.logRejection(
                sessionId: session.id,
                origin: session.dataOrigin,
                kind: AuditEvent.Kind.simulatedWriteForbidden,
                error: AppError.simulatedWriteForbidden
            )
            throw AppError.simulatedWriteForbidden
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AppError.healthKitUnavailable
        }
        // 逐点二次校验：混合来源的输入同样拒绝，避免任何 simulated 点流入健康数据。
        guard routePoints.allSatisfy({ $0.dataOrigin == .real }) else {
            await AuditLogger.shared.logRejection(
                sessionId: session.id,
                origin: .real,
                kind: AuditEvent.Kind.simulatedWriteForbidden,
                error: AppError.simulatedWriteForbidden
            )
            throw AppError.simulatedWriteForbidden
        }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            throw AppError.healthKitNotAuthorized
        }
        guard let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
              let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw AppError.healthKitUnavailable
        }

        let healthStore = store
        let locations = Self.routeLocations(from: routePoints)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration)

        do {
            try await beginCollection(builder, at: session.startTime)
            let samples: [HKSample] = [
                HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: max(0, session.totalDistanceMeters)),
                    start: session.startTime,
                    end: session.endTime
                ),
                HKQuantitySample(
                    type: stepType,
                    quantity: HKQuantity(unit: .count(), doubleValue: max(0, session.totalSteps)),
                    start: session.startTime,
                    end: session.endTime
                )
            ]
            try await add(samples, to: builder)
            let workout = try await finishWorkout(builder)

            // 路线由 HKWorkoutRouteBuilder 单独写入；点位已经过 >50 m / >3 s 过滤。
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore)
            try await insert(locations, into: routeBuilder)
            try await finishRoute(routeBuilder, workout: workout)

            await AuditLogger.shared.log(AuditEvent(
                sessionId: session.id,
                dataOrigin: .real,
                kind: AuditEvent.Kind.healthKitWriteSucceeded,
                count: locations.count,
                resultCode: "ok"
            ))
        } catch let error as AppError {
            await Self.logWriteFailure(session: session, reason: error.errorDescription ?? error.resultCode)
            throw error
        } catch {
            await Self.logWriteFailure(session: session, reason: error.localizedDescription)
            throw AppError.healthKitWriteFailed(reason: error.localizedDescription)
        }
    }

    // MARK: HealthKitService · 后台 delivery

    /// 后台读取：`stepCount` 观察者查询，频率为 Apple 允许的最长间隔 `.hourly`。
    /// 模拟器不支持后台健康数据投递，明确提示在真机验收；`updateHandler` 结尾**必须调用 completion**。
    public func enableBackgroundDelivery() async throws {
        #if targetEnvironment(simulator)
        throw AppError.backgroundDeliveryUnsupported
        #else
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AppError.healthKitUnavailable
        }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw AppError.healthKitUnavailable
        }
        let healthStore = store
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.enableBackgroundDelivery(for: stepType, frequency: .hourly) { success, error in
                if let error = error {
                    continuation.resume(
                        throwing: AppError.healthKitWriteFailed(reason: "后台投递启用失败：\(error.localizedDescription)")
                    )
                } else if !success {
                    continuation.resume(throwing: AppError.backgroundDeliveryUnsupported)
                } else {
                    continuation.resume()
                }
            }
        }
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { _, completionHandler, _ in
            // Apple 要求：处理完必须调用 completionHandler，否则系统会停止后台投递。
            // 本项目不读取健康样本值、不写日志坐标，只完成投递握手。
            completionHandler()
        }
        observerQuery = query
        healthStore.execute(query)
        #endif
    }

    // MARK: - 私有：HKWorkoutBuilder 异步封装

    private func beginCollection(_ builder: HKWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(at: date) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: AppError.healthKitWriteFailed(reason: "beginCollection 返回失败"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func add(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        guard !samples.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: AppError.healthKitWriteFailed(reason: "addSamples 返回失败"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func finishWorkout(_ builder: HKWorkoutBuilder) async throws -> HKWorkout {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKWorkout, Error>) in
            builder.finishWorkout { workout, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let workout = workout {
                    continuation.resume(returning: workout)
                } else {
                    continuation.resume(throwing: AppError.healthKitWriteFailed(reason: "finishWorkout 未返回 workout"))
                }
            }
        }
    }

    private func insert(_ locations: [CLLocation], into builder: HKWorkoutRouteBuilder) async throws {
        guard !locations.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.insertRouteData(locations) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: AppError.healthKitWriteFailed(reason: "insertRouteData 返回失败"))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func finishRoute(_ builder: HKWorkoutRouteBuilder, workout: HKWorkout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.finishRoute(workout: workout, metadata: nil) { _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - 私有：类型集合、过滤与映射

    /// 读取类型集合（workout / route / stepCount / 跑步距离 / 活跃能量）。
    private static func readObjectTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        let identifiers: [HKQuantityTypeIdentifier] = [
            .stepCount, .distanceWalkingRunning, .activeEnergyBurned
        ]
        for identifier in identifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    /// 写入类型集合（workout / route）。
    private static func shareSampleTypes() -> Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
    }

    /// 把 `HKAuthorizationStatus` 映射到项目统一权限状态；未知值归 `.unknown`。
    private static func permissionStatus(from status: HKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .sharingDenied: return .denied
        case .sharingAuthorized: return .authorizedWhenInUse
        @unknown default: return .unknown
        }
    }

    /// 路线点过滤（§B.10 / Apple《创建体能训练路线》）：
    /// - `horizontalAccuracy < 0` 或 `> 50 m` 丢弃；
    /// - 与上一个保留点间隔 `> 3 s` 丢弃；
    /// - 跨 `segmentIndex` 不连线（段首点单独作为新起点，不计入上一段）。
    private static func routeLocations(from points: [TrackPoint]) -> [CLLocation] {
        var result: [CLLocation] = []
        var previousTimestamp: Date?
        var previousSegment: Int?
        for point in points {
            guard point.horizontalAccuracyM >= 0,
                  point.horizontalAccuracyM <= AppConstants.accuracyGateMeters,
                  point.geoPoint.isValid else {
                continue
            }
            let sameSegment = previousSegment == point.segmentIndex
            if let previousTimestamp = previousTimestamp, sameSegment {
                let interval = point.timestamp.timeIntervalSince(previousTimestamp)
                guard interval > 0, interval <= AppConstants.maxPointIntervalSeconds else {
                    continue
                }
            }
            result.append(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                altitude: point.altitudeM,
                horizontalAccuracy: point.horizontalAccuracyM,
                verticalAccuracy: point.verticalAccuracyM,
                timestamp: point.timestamp
            ))
            previousTimestamp = point.timestamp
            previousSegment = point.segmentIndex
        }
        return result
    }

    private static func logAuthorization(kind: String) async {
        await AuditLogger.shared.log(AuditEvent(
            dataOrigin: .real,
            kind: kind,
            count: 1,
            resultCode: "ok"
        ))
    }

    private static func logWriteFailure(session: RunSession, reason: String) async {
        let error = AppError.healthKitWriteFailed(reason: reason)
        await AuditLogger.shared.logRejection(
            sessionId: session.id,
            origin: .real,
            kind: AuditEvent.Kind.healthKitWriteFailed,
            error: error
        )
    }
}
