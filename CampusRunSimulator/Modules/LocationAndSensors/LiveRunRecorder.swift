import Foundation

// MARK: - 真实运动记录编排器（F35 / §B.10 / §4.3）

/// 长生命周期 `actor`：消费 F32/F33 的 **REAL** 传感器流，产出 `.real` 的 `RunSession` + `[TrackPoint]`。
///
/// 硬约束：
/// - 不构造任何虚拟定位，不注入第三方 App，不读取 / 生成 SIMULATED 数据；
/// - 精度 `> 50 m` 丢弃、野值中值剔除、时间戳严格单调递增；
/// - 相邻间隔 `> 3 s` 标「数据稀疏 / 非插值」，**不插值冒充实测**；
/// - 中断与恢复 `segmentIndex += 1`，跨段不连线、不计距、不计时；
/// - 暂停段不计距、不计时；
/// - 结束页 `writeToHealthKit` 默认 `false`，仅在用户显式勾选后才调用 F34；
/// - 提供检查点，App 后台被杀后可恢复已落盘段。
public actor LiveRunRecorder {

    // MARK: - 恢复检查点

    /// 强杀后可恢复的快照（由上层落盘到 Application Support，`Data` 形式）。
    public struct RecoveryCheckpoint: Codable, Sendable {
        public let sessionId: String
        public let startTime: Date
        public let points: [TrackPoint]
        public let segmentIndex: Int
        public let activeElapsedSeconds: TimeInterval
        public let discardedByAccuracyGate: Int
        public let discardedByOutlier: Int
        public let sparseIntervalCount: Int
        public let referenceRoute: Route?
        public let createdAt: Date

        public init(
            sessionId: String,
            startTime: Date,
            points: [TrackPoint],
            segmentIndex: Int,
            activeElapsedSeconds: TimeInterval,
            discardedByAccuracyGate: Int,
            discardedByOutlier: Int,
            sparseIntervalCount: Int,
            referenceRoute: Route?,
            createdAt: Date = Date()
        ) {
            self.sessionId = sessionId
            self.startTime = startTime
            self.points = points
            self.segmentIndex = segmentIndex
            self.activeElapsedSeconds = activeElapsedSeconds
            self.discardedByAccuracyGate = discardedByAccuracyGate
            self.discardedByOutlier = discardedByOutlier
            self.sparseIntervalCount = sparseIntervalCount
            self.referenceRoute = referenceRoute
            self.createdAt = createdAt
        }
    }

    // MARK: - 内嵌 TrackFilter

    /// 精度门限 / 野值中值剔除 / 时间戳单调 / 稀疏间隔标记。
    /// 纯值类型 `Sendable`，所有派生量走 BATCH_1 冻结的 `Units`（唯一实现处）。
    public struct TrackFilter: Sendable {
        public var accuracyGateMeters: Double
        public var maxIntervalSeconds: TimeInterval
        /// 野值判定：允许跳距 = max(30, 倍数 × 水平精度)。
        public var outlierDistanceMultiplier: Double
        /// 低精度标注阈值（仍通过 50 m 门限，但标注 `.lowAccuracy`）。
        public var lowAccuracyThresholdMeters: Double

        public enum DiscardReason: String, Sendable {
            case origin
            case accuracy
            case timestamp
            case outlier
            case invalidCoordinate
        }

        public enum Decision: Sendable {
            case discard(DiscardReason)
            case accept(TrackPoint)
        }

        public init(
            accuracyGateMeters: Double = AppConstants.accuracyGateMeters,
            maxIntervalSeconds: TimeInterval = AppConstants.maxPointIntervalSeconds,
            outlierDistanceMultiplier: Double = 4,
            lowAccuracyThresholdMeters: Double = 20
        ) {
            self.accuracyGateMeters = accuracyGateMeters
            self.maxIntervalSeconds = maxIntervalSeconds
            self.outlierDistanceMultiplier = outlierDistanceMultiplier
            self.lowAccuracyThresholdMeters = lowAccuracyThresholdMeters
        }

        /// 把一条 REAL 定位采样转换为落盘点，或给出丢弃原因。
        /// - Parameters:
        ///   - sample: F32 产出的定位采样（来源恒 `.real`）。
        ///   - motion: 最近一条 F33 运动采样（字段可为 nil，不臆造）。
        ///   - previous: 已接受的采样点（取末点与最近 3 点用于中值）。
        ///   - sessionId: 本次真实记录 id。
        ///   - elapsedSeconds: 有效累计时长（暂停 / 中断不计）。
        ///   - elapsedDelta: 本点相对上一点的有效 Δt（跨段 / 首点为 0）。
        ///   - segmentIndex: 当前分段编号。
        public func evaluate(
            sample: LocationSample,
            motion: MotionSample?,
            previous: [TrackPoint],
            sessionId: String,
            elapsedSeconds: TimeInterval,
            elapsedDelta: TimeInterval,
            segmentIndex: Int
        ) -> Decision {
            guard sample.dataOrigin == .real else { return .discard(.origin) }
            guard sample.coordinate.isValid else { return .discard(.invalidCoordinate) }
            guard sample.passesAccuracyGate,
                  sample.horizontalAccuracyM <= accuracyGateMeters else {
                return .discard(.accuracy)
            }
            let previousPoint = previous.last
            if let previousPoint = previousPoint,
               sample.timestamp.timeIntervalSince(previousPoint.timestamp) <= 0 {
                return .discard(.timestamp)
            }

            // 野值中值剔除：以最近 3 点的经纬度中位数为参考，跳距超出精度允许范围即丢弃，
            // 不用中位数替代原值（不臆造坐标），只标记疑似漂移或丢弃。
            let median = medianCoordinate(Array(previous.suffix(3)))
            var driftSuspect = false
            if let median = median {
                let jump = Units.haversineMeters(median, sample.coordinate)
                let allowedJump = max(30, outlierDistanceMultiplier * max(1, sample.horizontalAccuracyM))
                if jump > allowedJump {
                    return .discard(.outlier)
                }
                driftSuspect = jump > allowedJump * 0.5
            }

            let sameSegment = previousPoint?.segmentIndex == segmentIndex
            let deltaDistance: Double
            if sameSegment, let previousPoint = previousPoint {
                deltaDistance = max(0, Units.distanceMeters(previousPoint.geoPoint, sample.coordinate))
            } else {
                // 跨段不连线、不计距：段首点不产生距离增量。
                deltaDistance = 0
            }
            let cumulativeDistance = max(0, (previousPoint?.cumulativeDistanceM ?? 0) + deltaDistance)
            let speedMps: Double
            if sample.speedMps.isFinite, sample.speedMps >= 0 {
                speedMps = sample.speedMps
            } else if elapsedDelta > 0 {
                speedMps = deltaDistance / elapsedDelta
            } else {
                speedMps = 0
            }
            let instantPace = Units.paceSecPerKm(deltaSeconds: elapsedDelta, deltaMeters: deltaDistance)
            let averagePace = Units.averagePaceSecPerKm(
                totalSeconds: elapsedSeconds,
                totalMeters: cumulativeDistance
            )
            let cadence = motion?.cadenceSpm ?? 0
            let stride = Units.strideLength(speedMps: speedMps, cadenceSpm: cadence)
            let cumulativeSteps = (previousPoint?.cumulativeSteps ?? 0)
                + Units.stepIncrement(cadenceSpm: cadence, deltaSeconds: elapsedDelta)

            let altitude = motion?.resolvedAltitude(initialAltitudeM: 0) ?? sample.altitudeM
            let previousAltitude = previousPoint?.altitudeM ?? altitude
            let deltaGainLoss = Units.elevationGainLoss([previousAltitude, altitude])
            let gainSoFar = (previousPoint?.elevationGainSoFarM ?? 0) + deltaGainLoss.gain
            let lossSoFar = (previousPoint?.elevationLossSoFarM ?? 0) + deltaGainLoss.loss

            var flags: [QualityFlag] = []
            if sample.horizontalAccuracyM < 0
                || sample.horizontalAccuracyM > lowAccuracyThresholdMeters {
                flags.append(.lowAccuracy)
            }
            if driftSuspect { flags.append(.driftSuspect) }
            if elapsedDelta > maxIntervalSeconds {
                // 「数据稀疏 / 非插值（实测）」：明确标注未插值冒充实测。
                flags.append(.interpolatedFalse)
            }
            if !sameSegment && previousPoint != nil { flags.append(.gap) }

            let point = TrackPoint(
                id: OriginID.makeID(.real, suffix: "\(sessionId)_\(previous.count)"),
                sessionId: sessionId,
                dataOrigin: .real,
                timestamp: sample.timestamp,
                elapsedSeconds: elapsedSeconds,
                latitude: sample.coordinate.latitude,
                longitude: sample.coordinate.longitude,
                altitudeM: altitude,
                horizontalAccuracyM: sample.horizontalAccuracyM,
                verticalAccuracyM: sample.verticalAccuracyM,
                courseDegrees: sample.courseDegrees,
                speedMps: speedMps,
                speedAccuracyMps: -1,
                instantPaceSecPerKm: instantPace,
                avgPaceSecPerKm: averagePace,
                cadenceSpm: cadence,
                strideLengthM: stride,
                cumulativeSteps: cumulativeSteps,
                cumulativeDistanceM: cumulativeDistance,
                elevationGainSoFarM: gainSoFar,
                elevationLossSoFarM: lossSoFar,
                segmentIndex: segmentIndex,
                qualityFlags: flags
            )
            return .accept(point)
        }

        /// 最近若干点经纬度的中位数（野值参考点）。
        private func medianCoordinate(_ points: [TrackPoint]) -> GeoPoint? {
            guard !points.isEmpty else { return nil }
            let latitudes = points.map(\.latitude).sorted()
            let longitudes = points.map(\.longitude).sorted()
            return GeoPoint(
                latitude: median(latitudes),
                longitude: median(longitudes)
            )
        }

        private func median(_ values: [Double]) -> Double {
            let count = values.count
            if count % 2 == 1 { return values[count / 2] }
            return (values[count / 2 - 1] + values[count / 2]) / 2
        }
    }

    // MARK: - 依赖与状态

    private let locationProvider: any LocationProvider & Sendable
    private let motionProvider: any MotionProvider & Sendable
    private let gapStream: AsyncStream<Date>?
    private let healthKitService: (any HealthKitService)?
    private let repository: (any RunRepository)?

    private var filter = TrackFilter()
    private var isRecording = false
    private var isPaused = false
    private var sessionId: String = OriginID.makeID(.real)
    private var startTime: Date = Date()
    private var referenceRoute: Route?
    private var points: [TrackPoint] = []
    private var segmentIndex: Int = 0
    private var activeElapsedSeconds: TimeInterval = 0
    private var discardedByAccuracyGate: Int = 0
    private var discardedByOutlier: Int = 0
    private var discardedByTimestamp: Int = 0
    private var sparseIntervalCount: Int = 0
    private var gapEventCount: Int = 0
    private var lastGapAt: Date?
    private var latestMotion: MotionSample?
    private var motionUnavailableNote: String = ""
    private var locationTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var gapTask: Task<Void, Never>?

    /// - Parameters:
    ///   - locationProvider: F32 真实定位提供者（`CoreLocationProvider` 已声明 `@unchecked Sendable`）。
    ///   - motionProvider: F33 真实运动传感器提供者。
    ///   - gapStream: F32 `gaps` 流（系统暂停 / 恢复 / 失败事件）；为 nil 时回退到基于时间戳的自动分段。
    ///   - healthKitService: F34，仅在结束页显式勾选且 `.real` 时调用。
    ///   - repository: F44，用于结束落盘与检查点恢复。
    public init(
        locationProvider: any LocationProvider & Sendable,
        motionProvider: any MotionProvider & Sendable,
        gapStream: AsyncStream<Date>? = nil,
        healthKitService: (any HealthKitService)? = nil,
        repository: (any RunRepository)? = nil
    ) {
        self.locationProvider = locationProvider
        self.motionProvider = motionProvider
        self.gapStream = gapStream
        self.healthKitService = healthKitService
        self.repository = repository
    }

    // MARK: - 生命周期

    /// 开始真实记录。定位授权失败时直接透传 `AppError.locationNotAuthorized`；
    /// 运动传感器全部不可用时保留 GPS 轨迹，字段按「不可用」处理，不臆造。
    public func start(referenceRoute: Route? = nil) async throws {
        guard !isRecording else {
            throw AppError.parameterConflict(reason: "已有进行中的真实记录，不能重复开始")
        }
        isRecording = true
        isPaused = false
        sessionId = OriginID.makeID(.real)
        startTime = Date()
        self.referenceRoute = referenceRoute
        points = []
        segmentIndex = 0
        activeElapsedSeconds = 0
        discardedByAccuracyGate = 0
        discardedByOutlier = 0
        discardedByTimestamp = 0
        sparseIntervalCount = 0
        gapEventCount = 0
        lastGapAt = nil
        latestMotion = nil
        motionUnavailableNote = ""

        locationProvider.requestAuthorization()
        do {
            try locationProvider.start()
        } catch {
            isRecording = false
            throw error
        }
        do {
            try motionProvider.start(from: startTime)
        } catch {
            motionUnavailableNote = "运动传感器不可用，相关字段按「不可用」处理：\(error.localizedDescription)"
        }
        startConsumers()
        await AuditLogger.shared.log(AuditEvent(
            sessionId: sessionId,
            dataOrigin: .real,
            kind: "live_run_started",
            count: 0,
            resultCode: "ok"
        ))
    }

    /// 用户主动暂停：暂停段不计距、不计时。
    public func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        locationProvider.pause()
        if let lastIndex = points.indices.last {
            points[lastIndex] = points[lastIndex].adding(flag: .paused)
        }
    }

    /// 恢复：新建分段，跨段不连线、不计距、不计时。
    public func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        segmentIndex += 1
        locationProvider.resume()
    }

    /// 结束并落盘。记录先经 `RunRepository.save` 写入 REAL 容器；
    /// `writeToHealthKit` 默认 `false`，只有显式勾选才调用 F34（其内部仍有 `guard .real`）。
    /// HealthKit 写入失败以 `AppError` 形式返回给 UI 展示明确失败态，不静默重试。
    public func finish(note: String = "", writeToHealthKit: Bool = false) async throws -> RunSession {
        guard isRecording else {
            throw AppError.parameterConflict(reason: "当前没有进行中的真实记录")
        }
        isRecording = false
        isPaused = false
        stopConsumers()
        locationProvider.stop()
        motionProvider.stop()

        let endTime = points.last?.timestamp ?? Date()
        let distance = max(0, points.last?.cumulativeDistanceM ?? 0)
        let duration = max(0, activeElapsedSeconds)
        let steps = max(0, points.last?.cumulativeSteps ?? Double(latestMotion?.steps ?? 0))
        let gain = max(0, points.last?.elevationGainSoFarM ?? 0)
        let loss = max(0, points.last?.elevationLossSoFarM ?? 0)
        let averageSpeed = duration > 0 ? distance / duration : 0
        let averagePace = Units.averagePaceSecPerKm(totalSeconds: duration, totalMeters: distance)

        let session = RunSession(
            id: sessionId,
            dataOrigin: .real,
            startTime: startTime,
            endTime: endTime,
            durationSeconds: duration,
            totalDistanceMeters: distance,
            avgSpeedMps: averageSpeed,
            avgPaceSecPerKm: averagePace,
            totalSteps: steps,
            elevationGainM: gain,
            elevationLossM: loss,
            routeId: referenceRoute?.id,
            simulationProfileId: nil,
            rulePresetId: nil,
            note: note,
            createdAt: Date(),
            schemaVersion: AppConstants.schemaVersion,
            originChain: []
        )

        if let repository = repository {
            try await repository.save(session, points: points)
        }
        if writeToHealthKit, let healthKitService = healthKitService {
            try await healthKitService.write(session: session, routePoints: points)
        }
        await AuditLogger.shared.log(AuditEvent(
            sessionId: session.id,
            dataOrigin: .real,
            kind: "live_run_finished",
            count: points.count,
            resultCode: "ok"
        ))
        return session
    }

    // MARK: - 检查点与质量报告

    /// 生成可落盘的恢复检查点（强杀后恢复用）。
    public func recoveryCheckpoint() -> RecoveryCheckpoint {
        RecoveryCheckpoint(
            sessionId: sessionId,
            startTime: startTime,
            points: points,
            segmentIndex: segmentIndex,
            activeElapsedSeconds: activeElapsedSeconds,
            discardedByAccuracyGate: discardedByAccuracyGate,
            discardedByOutlier: discardedByOutlier,
            sparseIntervalCount: sparseIntervalCount,
            referenceRoute: referenceRoute,
            createdAt: Date()
        )
    }

    /// 检查点序列化（由上层写入 Application Support；不使用任何网络）。
    /// 非有限浮点（如无距离时的 `.infinity` 配速）统一编码为字符串，避免 JSONEncoder 抛错。
    public func checkpointData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(recoveryCheckpoint())
    }

    /// 从检查点恢复：保留已落盘段与 `segmentIndex`，重启流消费。
    public func restore(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let checkpoint = try decoder.decode(RecoveryCheckpoint.self, from: data)
        restore(checkpoint)
    }

    /// 从已解码检查点恢复状态。
    public func restore(_ checkpoint: RecoveryCheckpoint) {
        stopConsumers()
        sessionId = checkpoint.sessionId
        startTime = checkpoint.startTime
        points = checkpoint.points.filter { $0.dataOrigin == .real }
        segmentIndex = checkpoint.segmentIndex
        activeElapsedSeconds = checkpoint.activeElapsedSeconds
        discardedByAccuracyGate = checkpoint.discardedByAccuracyGate
        discardedByOutlier = checkpoint.discardedByOutlier
        sparseIntervalCount = checkpoint.sparseIntervalCount
        referenceRoute = checkpoint.referenceRoute
        isPaused = false
        isRecording = true
        startConsumers()
    }

    /// 数据质量报告（丢弃数 / 稀疏间隔 / 分段数 / 恒为 0 的插值点数）。
    public func qualityReport() -> DataQualityReport {
        DataQualityReport.build(
            sessionId: sessionId,
            points: points,
            discarded: discardedByAccuracyGate + discardedByOutlier + discardedByTimestamp
        )
    }

    /// 当前已接受的采样点（供实时 UI 与回放使用）。
    public func currentPoints() -> [TrackPoint] {
        points
    }

    /// 运动传感器不可用说明（空串表示全部可用）。
    public func motionAvailabilityNote() -> String {
        motionUnavailableNote
    }

    // MARK: - 私有：流消费

    private func startConsumers() {
        let locationSamples = locationProvider.samples
        locationTask = Task { [weak self] in
            for await sample in locationSamples {
                if Task.isCancelled { return }
                guard let self = self else { return }
                await self.ingest(location: sample)
            }
        }
        let motionSamples = motionProvider.samples
        motionTask = Task { [weak self] in
            for await sample in motionSamples {
                if Task.isCancelled { return }
                guard let self = self else { return }
                await self.ingest(motion: sample)
            }
        }
        if let gapStream = gapStream {
            gapTask = Task { [weak self] in
                for await date in gapStream {
                    if Task.isCancelled { return }
                    guard let self = self else { return }
                    await self.handleGap(at: date)
                }
            }
        }
    }

    private func stopConsumers() {
        locationTask?.cancel()
        motionTask?.cancel()
        gapTask?.cancel()
        locationTask = nil
        motionTask = nil
        gapTask = nil
    }

    private func ingest(location sample: LocationSample) {
        guard isRecording, !isPaused else { return }
        guard sample.dataOrigin == .real else { return }
        let previousPoint = points.last
        let elapsedDelta: TimeInterval
        if let previousPoint = previousPoint, previousPoint.segmentIndex == segmentIndex {
            let raw = sample.timestamp.timeIntervalSince(previousPoint.timestamp)
            elapsedDelta = raw > 0 ? raw : 0
        } else {
            // 首点 / 跨段：不计距、不计中断时长。
            elapsedDelta = 0
        }
        let candidateElapsed = activeElapsedSeconds + elapsedDelta
        let decision = filter.evaluate(
            sample: sample,
            motion: latestMotion,
            previous: points,
            sessionId: sessionId,
            elapsedSeconds: candidateElapsed,
            elapsedDelta: elapsedDelta,
            segmentIndex: segmentIndex
        )
        switch decision {
        case .discard(let reason):
            switch reason {
            case .accuracy: discardedByAccuracyGate += 1
            case .outlier: discardedByOutlier += 1
            case .timestamp: discardedByTimestamp += 1
            case .origin, .invalidCoordinate: discardedByAccuracyGate += 1
            }
        case .accept(let point):
            points.append(point)
            activeElapsedSeconds = candidateElapsed
            if elapsedDelta > AppConstants.maxPointIntervalSeconds {
                sparseIntervalCount += 1
            }
        }
    }

    private func ingest(motion sample: MotionSample) {
        guard sample.dataOrigin == .real else { return }
        latestMotion = sample
    }

    /// 系统暂停 / 恢复 / 失败事件：新建分段，绝不把中断前后连成直线。
    private func handleGap(at date: Date) {
        guard isRecording else { return }
        segmentIndex += 1
        gapEventCount += 1
        lastGapAt = date
        if let lastIndex = points.indices.last {
            points[lastIndex] = points[lastIndex].adding(flag: .gap)
        }
    }
}
