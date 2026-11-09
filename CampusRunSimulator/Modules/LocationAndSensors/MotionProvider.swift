import Foundation
import CoreMotion

// MARK: - 真实运动传感器提供者（F33 / §A.1.2）

/// `CMPedometer` + `CMAltimeter` + `CMMotionActivityManager` 真实实现，**仅 REAL 链路**。
/// 全部单位换算走 BATCH_1 冻结的 `Units`（唯一实现处）；不可用字段一律 `nil` 表示「不可用」，
/// **绝不臆造数值**。`MotionSample.dataOrigin` 由冻结初始化器内部强制为 `.real`。
public final class CoreMotionProvider: MotionProvider, @unchecked Sendable {

    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private let activityManager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "com.campusrun.simulator.motion"
        operationQueue.maxConcurrentOperationCount = 1
        return operationQueue
    }()

    private let stream: AsyncStream<MotionSample>
    private let continuation: AsyncStream<MotionSample>.Continuation
    private let lock = NSLock()

    /// 用户给定的初始绝对海拔基准 `h0`（相对海拔 + h0 得到绝对海拔）。
    private let initialAltitudeM: Double
    private var running = false

    // 各数据源最新快照；不可用时保持 nil，绝不填假值。
    private var latestSteps: Int?
    private var latestDistanceM: Double?
    private var latestPaceMinPerKm: Double?
    private var latestCadenceSpm: Double?
    private var latestRelativeAltitudeM: Double?
    private var latestAbsoluteAltitudeM: Double?
    private var latestActivity: MotionActivityKind?

    public var samples: AsyncStream<MotionSample> {
        stream
    }

    public init(initialAltitudeM: Double = 0) {
        let pair = AsyncStream.makeStream(of: MotionSample.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
        self.initialAltitudeM = initialAltitudeM.isFinite ? initialAltitudeM : 0
    }

    deinit {
        continuation.finish()
    }

    // MARK: MotionProvider 协议

    /// 能力分支：计步 / 相对海拔 / 绝对海拔 / 运动状态分别探测。
    /// 绝对海拔 API 需设备支持（§A.1.2），本实现把该分支暴露给 UI；
    /// 实际海拔统一由相对量 + 用户给定 `h0` 推导，避免依赖设备相关 API 造成臆造。
    public func availability() -> MotionAvailability {
        MotionAvailability(
            pedometerAvailable: CMPedometer.isStepCountingAvailable(),
            relativeAltitudeAvailable: CMAltimeter.isRelativeAltitudeAvailable(),
            absoluteAltitudeAvailable: CMAltimeter.isAbsoluteAltitudeAvailable(),
            activityAvailable: CMMotionActivityManager.isActivityAvailable(),
            note: "不可用字段按「不可用」处理，绝不臆造数值；步幅由 L = 60v/c 推算"
        )
    }

    public func start(from date: Date) throws {
        let state = availability()
        guard state.pedometerAvailable || state.relativeAltitudeAvailable || state.activityAvailable else {
            throw AppError.motionSensorUnavailable(field: "全部运动传感器")
        }
        lock.lock()
        running = true
        lock.unlock()

        if state.pedometerAvailable {
            pedometer.startUpdates(from: date) { [weak self] data, error in
                guard let self = self, error == nil, let data = data else {
                    // 计步器数据不可用：不填假值，等待下一次回调。
                    return
                }
                self.ingestPedometer(data, timestamp: data.endDate)
            }
        }
        if state.relativeAltitudeAvailable {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                guard let self = self, error == nil, let data = data else {
                    // 气压计不可用：海拔字段保持「不可用」。
                    return
                }
                self.ingestAltimeter(relativeMeters: data.relativeAltitude.doubleValue,
                                     timestamp: data.timestamp)
            }
        }
        if state.activityAvailable {
            let status = CMMotionActivityManager.authorizationStatus()
            guard status != .restricted, status != .denied else {
                // 未授权时不启动状态流，activity 字段保持「不可用」。
                return
            }
            activityManager.startActivityUpdates(to: queue) { [weak self] activity in
                guard let self = self else { return }
                // 兼容不同 SDK 版本的 handler 参数形态（可能为可选值）。
                self.ingestActivity(activity as? CMMotionActivity, timestamp: Date())
            }
        }
    }

    public func stop() {
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        activityManager.stopActivityUpdates()
        lock.lock()
        running = false
        lock.unlock()
        continuation.finish()
    }

    // MARK: 单位换算与快照合并

    /// `CMPedometerData`：`currentPace` s/m → min/km；`currentCadence` 步/秒 → spm。
    private func ingestPedometer(_ data: CMPedometerData, timestamp: Date) {
        let pace: Double?
        if let currentPace = data.currentPace {
            pace = Units.paceSecPerMeterToMinPerKm(currentPace.doubleValue)
        } else if let averageActivePace = data.averageActivePace {
            pace = Units.paceSecPerMeterToMinPerKm(averageActivePace.doubleValue)
        } else {
            pace = nil
        }
        let cadence: Double? = data.currentCadence.map {
            Units.cadenceStepsPerSecondToSpm($0.doubleValue)
        }
        lock.lock()
        latestPaceMinPerKm = pace
        latestCadenceSpm = cadence
        latestSteps = data.numberOfSteps?.intValue
        latestDistanceM = data.distance?.doubleValue
        lock.unlock()
        emit(timestamp: timestamp)
    }

    /// `CMAltitudeData.relativeAltitude` 为相对首事件的变化量（m），叠加用户给定 `h0` 得绝对海拔。
    private func ingestAltimeter(relativeMeters: Double, timestamp: Date) {
        guard relativeMeters.isFinite else { return }
        let absolute = Units.absoluteAltitude(
            relativeM: relativeMeters,
            initialAltitudeM: initialAltitudeM
        )
        lock.lock()
        latestRelativeAltitudeM = relativeMeters
        latestAbsoluteAltitudeM = absolute
        lock.unlock()
        emit(timestamp: timestamp)
    }

    /// `CMMotionActivity` 分类结果映射到领域枚举；各布尔量不互斥时按优先级取其一。
    private func ingestActivity(_ activity: CMMotionActivity?, timestamp: Date) {
        let kind: MotionActivityKind
        if let activity = activity {
            if activity.running {
                kind = .running
            } else if activity.cycling {
                kind = .cycling
            } else if activity.walking {
                kind = .walking
            } else if activity.automotive {
                kind = .automotive
            } else if activity.stationary {
                kind = .stationary
            } else {
                kind = .unknown
            }
        } else {
            kind = .unknown
        }
        lock.lock()
        latestActivity = kind
        lock.unlock()
        emit(timestamp: timestamp)
    }

    /// 每次任一数据源更新，yield 一份「当前所有已知字段」的快照；未知字段保持 nil。
    private func emit(timestamp: Date) {
        lock.lock()
        let snapshot = MotionSample(
            timestamp: timestamp,
            steps: latestSteps,
            distanceM: latestDistanceM,
            paceMinPerKm: latestPaceMinPerKm,
            cadenceSpm: latestCadenceSpm,
            relativeAltitudeM: latestRelativeAltitudeM,
            absoluteAltitudeM: latestAbsoluteAltitudeM,
            activity: latestActivity
        )
        let active = running
        lock.unlock()
        guard active else { return }
        continuation.yield(snapshot)
    }
}
