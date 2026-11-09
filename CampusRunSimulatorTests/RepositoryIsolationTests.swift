import Foundation
import SwiftData
import XCTest
@testable import CampusRunSimulator

/// F64 · 双存储域隔离 / dataOrigin 不可变 / SwiftData in-memory CRUD / 定位中断恢复（[T08] [T10]）。
///
/// 诚实边界：
/// - 全部 SwiftData 操作使用 `ModelContainerFactory.makeInMemoryPair()` / `makeInMemory()`
///   （`isStoredInMemoryOnly: true`），不触碰磁盘、不初始化 `CLLocationManager` / `HKHealthStore` / `CMAltimeter`；
/// - 「无 HealthKit 写入路径」用值类型守卫 + 源码级静态检查验证，**不实例化 `HKHealthStore`**；
///   真机 HealthKit 写入（AC-F6）需真机验收，本地 Linux 未执行；
/// - 后台 30 min 连续记录（AC-F5）、强杀后 App 重启（AC-F11）真机流程需真机 / CI 验收，
///   本文件只验证 `RecoveryCheckpoint` 的序列化 / 恢复与 `TrackFilter` 的纯逻辑分段；
/// - 用于替代硬件的定位 / 运动提供者是纯内存 `AsyncStream` 桩，不发起任何系统定位。
final class RepositoryIsolationTests: XCTestCase {

    // MARK: - 测试夹具

    private let baseTime = Date(timeIntervalSince1970: 1_767_225_600)

    private func makeSession(origin: DataOrigin, suffix: String, note: String = "") -> RunSession {
        RunSession(
            id: OriginID.makeID(origin, suffix: suffix),
            dataOrigin: origin,
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(60),
            durationSeconds: 60,
            totalDistanceMeters: 200,
            avgSpeedMps: 3.33,
            avgPaceSecPerKm: 300,
            totalSteps: 170,
            elevationGainM: 2,
            elevationLossM: 1,
            note: note,
            createdAt: baseTime
        )
    }

    private func makePoints(origin: DataOrigin, sessionID: String, count: Int = 5) -> [TrackPoint] {
        (0..<count).map { index in
            TrackPoint(
                id: OriginID.makeID(origin, suffix: "\(sessionID)_p\(index)"),
                sessionId: sessionID,
                dataOrigin: origin,
                timestamp: baseTime.addingTimeInterval(Double(index)),
                elapsedSeconds: Double(index),
                latitude: 30.3010 + Double(index) * 0.0001,
                longitude: 120.0810 + Double(index) * 0.0001,
                altitudeM: 12,
                horizontalAccuracyM: 5,
                speedMps: 3.3,
                cadenceSpm: 170,
                cumulativeDistanceM: Double(index) * 40,
                segmentIndex: 0
            )
        }
    }

    private func locationSample(at seconds: TimeInterval, lat: Double, lon: Double) -> LocationSample {
        LocationSample(
            coordinate: GeoPoint(latitude: lat, longitude: lon),
            altitudeM: 12,
            horizontalAccuracyM: 5,
            verticalAccuracyM: 3,
            courseDegrees: 90,
            speedMps: 2.5,
            timestamp: baseTime.addingTimeInterval(seconds)
        )
    }

    /// 读取仓库源码做静态守卫检查（`#filePath` 兜底，CI checkout 后一定存在）。
    private func sourceText(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "缺少源码 \(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func forbiddenConversionPatterns(_ text: String) -> [String] {
        let patterns = [
            "func toReal", "func convertToReal", "func makeReal", "func promoteToReal",
            "mutating func", "func setDataOrigin", "func convertOrigin"
        ]
        var hits: [String] = patterns.filter { text.contains($0) }
        // `dataOrigin` 是不可变 let；构造时 `self.dataOrigin = .real` 是合法且必要的来源强制，
        // 只拒绝「把已有来源改写为 real」的赋值行。
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.contains("dataOrigin"),
               line.contains("= .real"),
               !line.contains("self.dataOrigin = .real") {
                hits.append("来源改写嫌疑：\(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return hits
    }

    // MARK: - [T10] 双容器物理隔离

    func testSeparateStores() throws {
        // [T10][AC-C7] 两个 ModelContainer 物理独立，id 空间与容器路由一一对应。
        let stores = try ModelContainerFactory.makeInMemoryPair()
        XCTAssertTrue(stores.arePhysicallySeparate)
        XCTAssertTrue(ModelContainerFactory.verifySeparation(stores))
        XCTAssertFalse(stores.isPersistent, "内存模式不得伪装为持久化")
        XCTAssertNil(stores.simulatedStoreURL)
        XCTAssertNil(stores.realStoreURL)
        XCTAssertTrue(stores.container(for: .simulated) === stores.simulatedStore)
        XCTAssertTrue(stores.container(for: .real) === stores.realStore)
        XCTAssertFalse(stores.container(for: .simulated) === stores.container(for: .real),
                       "两个来源绝不能共用同一个容器")

        let single = try ModelContainerFactory.makeInMemory()
        XCTAssertFalse(single === stores.simulatedStore)
        // `DefaultRunRepository.areStoresPhysicallySeparate()` 是 actor 方法，
        // 在异步 CRUD 测试中再以真实读写行为验证两个容器互不影响。
    }

    func testIDSpacesDisjoint() {
        // [T10][AC-C7] sim_ / real_ 前缀构成不相交 id 空间，跨来源 id 绝不复用。
        let simID = OriginID.makeID(.simulated, suffix: "abc")
        let realID = OriginID.makeID(.real, suffix: "abc")
        XCTAssertNotEqual(simID, realID)
        XCTAssertTrue(OriginID.isValid(simID, for: .simulated))
        XCTAssertFalse(OriginID.isValid(simID, for: .real))
        XCTAssertTrue(OriginID.isValid(realID, for: .real))
        XCTAssertFalse(OriginID.isSameDomain(simID, realID))
        XCTAssertEqual(OriginID.domain(of: simID), .simulated)
        XCTAssertEqual(OriginID.domain(of: realID), .real)
        XCTAssertNil(OriginID.domain(of: "dirty_no_prefix"))
        XCTAssertEqual(OriginID.normalize(realID, for: .simulated), "sim_abc",
                       "跨来源 id 必须先剥离再附加正确前缀，生成全新 id")
        XCTAssertEqual(OriginID.normalize(simID, for: .simulated), simID)
        XCTAssertEqual(DataOrigin.simulated.idPrefix, "sim_")
        XCTAssertEqual(DataOrigin.real.idPrefix, "real_")
    }

    // MARK: - [T10] in-memory SwiftData CRUD / 持久化等价

    func testCRUDInMemoryContainers() async throws {
        // [T10][AC-F11] 双容器 save / fetch / points / delete / clear 全链路，且互不影响。
        let stores = try ModelContainerFactory.makeInMemoryPair()
        let repository = DefaultRunRepository(stores: stores)
        let separated = await repository.areStoresPhysicallySeparate()
        XCTAssertTrue(separated, "仓库层同样必须报告两个容器物理隔离")
        let sim = makeSession(origin: .simulated, suffix: "crud_sim", note: "仅模拟记录")
        let real = makeSession(origin: .real, suffix: "crud_real", note: "真实记录")
        let simPoints = makePoints(origin: .simulated, sessionID: sim.id)
        let realPoints = makePoints(origin: .real, sessionID: real.id, count: 3)

        try await repository.save(sim, points: simPoints)
        try await repository.save(real, points: realPoints)

        let simList = try await repository.fetch(origin: .simulated, predicate: RunPredicate())
        let realList = try await repository.fetch(origin: .real, predicate: RunPredicate())
        XCTAssertEqual(simList.count, 1)
        XCTAssertEqual(realList.count, 1)
        XCTAssertEqual(simList.first?.id, sim.id)
        XCTAssertEqual(realList.first?.id, real.id)
        XCTAssertTrue(simList.allSatisfy { $0.dataOrigin == .simulated })
        XCTAssertTrue(realList.allSatisfy { $0.dataOrigin == .real })

        let fetchedSimPoints = try await repository.points(sessionId: sim.id)
        let fetchedRealPoints = try await repository.points(sessionId: real.id)
        XCTAssertEqual(fetchedSimPoints.count, simPoints.count)
        XCTAssertEqual(fetchedRealPoints.count, realPoints.count)
        XCTAssertTrue(fetchedSimPoints.allSatisfy { $0.dataOrigin == .simulated && $0.sessionId == sim.id })
        XCTAssertTrue(fetchedRealPoints.allSatisfy { $0.dataOrigin == .real && $0.sessionId == real.id })

        let filtered = try await repository.fetch(
            origin: .simulated, predicate: RunPredicate(searchText: "仅模拟")
        )
        XCTAssertEqual(filtered.count, 1)
        let noMatch = try await repository.fetch(
            origin: .simulated, predicate: RunPredicate(searchText: "不存在的备注")
        )
        XCTAssertTrue(noMatch.isEmpty)
        let limited = try await repository.fetch(
            origin: .simulated, predicate: RunPredicate(limit: 0)
        )
        XCTAssertTrue(limited.isEmpty)

        // 删除一方不影响另一方；clear 只清除对应容器。
        try await repository.delete(ids: [sim.id], origin: .simulated)
        XCTAssertTrue(try await repository.fetch(origin: .simulated, predicate: RunPredicate()).isEmpty)
        XCTAssertEqual(try await repository.fetch(origin: .real, predicate: RunPredicate()).count, 1)
        XCTAssertTrue(try await repository.points(sessionId: sim.id).isEmpty)

        try await repository.clear(origin: .real)
        XCTAssertTrue(try await repository.fetch(origin: .real, predicate: RunPredicate()).isEmpty)
        XCTAssertTrue(try await repository.points(sessionId: real.id).isEmpty)
    }

    func testDirtyDataIsolatedAsUnclassified() async throws {
        // [T10][AC-C7] 脏数据（非法 id / 非法来源）归入「未分类」，绝不默认真实记录。
        let stores = try ModelContainerFactory.makeInMemoryPair()
        let repository = DefaultRunRepository(stores: stores)
        let context = ModelContext(stores.container(for: .simulated))
        let dirty = SDRunSession(
            id: "dirty_no_origin_prefix",
            dataOriginRaw: "unknown",
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(10),
            durationSeconds: 10,
            totalDistanceMeters: 10,
            avgSpeedMps: 1,
            avgPaceSecPerKm: 1000,
            totalSteps: 0,
            elevationGainM: 0,
            elevationLossM: 0,
            routeId: nil,
            simulationProfileId: nil,
            rulePresetId: nil,
            note: "脏数据",
            createdAt: baseTime,
            schemaVersion: AppConstants.schemaVersion,
            originChainJSON: Data("[]".utf8)
        )
        context.insert(dirty)
        try context.save()

        let normal = try await repository.fetch(origin: .simulated, predicate: RunPredicate())
        XCTAssertTrue(normal.isEmpty, "脏数据不得进入正常成绩单列表")
        let unclassified = try await repository.unclassified()
        XCTAssertEqual(unclassified.count, 1)
        let placeholder = try XCTUnwrap(unclassified.first)
        XCTAssertTrue(placeholder.id.hasPrefix("unclassified_"))
        XCTAssertEqual(placeholder.dataOrigin, .simulated, "安全占位来源为测试数据，绝不默认真实记录")
        XCTAssertTrue(placeholder.note.contains(AppConstants.unclassifiedSectionName))
        XCTAssertTrue(try await repository.fetch(origin: .real, predicate: RunPredicate()).isEmpty)
    }

    // MARK: - [T10] dataOrigin 不可变 / 无转换路径 / 无 HealthKit 写入路径

    func testOriginImmutable() {
        // [T10][AC-C3][AC-C7] 值类型来源字段在构造后不可变，且初始化器强制来源。
        let profile = SimulationProfile.makeDefault(seed: 9_999)
        XCTAssertEqual(profile.dataOrigin, .simulated)
        let changedSeed = profile.withSeed(12_345)
        XCTAssertEqual(changedSeed.dataOrigin, .simulated)
        XCTAssertEqual(changedSeed.seed, 12_345)

        let sample = locationSample(at: 0, lat: 30.3010, lon: 120.0810)
        XCTAssertEqual(sample.dataOrigin, .real, "定位采样恒为 REAL，不接受外部来源参数")
        let motion = MotionSample(timestamp: baseTime, cadenceSpm: 170)
        XCTAssertEqual(motion.dataOrigin, .real)

        let point = makePoints(origin: .simulated, sessionID: "sim_immutable", count: 1)[0]
        XCTAssertEqual(point.dataOrigin, .simulated)
        XCTAssertEqual(point.adding(flag: .gap).dataOrigin, .simulated,
                       "追加质量标记必须重新构造值类型，来源不变")
        XCTAssertEqual(point.adding(flag: .gap).id, point.id)

        let session = makeSession(origin: .simulated, suffix: "immutable")
        XCTAssertEqual(session.duplicate(newID: "real_attempt").dataOrigin, .simulated)
        XCTAssertTrue(session.duplicate(newID: "real_attempt").id.hasPrefix("sim_"),
                      "即便传入 real_ 前缀的新 id，也必须规范化回同源 id 空间")
    }

    func testDuplicatePreservesOrigin() async throws {
        // [T10][AC-C7] 另存副本保留来源链、来源不变、采样点重新映射到同一容器。
        let stores = try ModelContainerFactory.makeInMemoryPair()
        let repository = DefaultRunRepository(stores: stores)
        let session = makeSession(origin: .simulated, suffix: "dup_original")
        let points = makePoints(origin: .simulated, sessionID: session.id)
        try await repository.save(session, points: points)

        let copy = try await repository.duplicate(session)
        XCTAssertNotEqual(copy.id, session.id)
        XCTAssertEqual(copy.dataOrigin, .simulated)
        XCTAssertTrue(copy.hasValidOriginID)
        XCTAssertTrue(copy.originChain.contains { $0.contains("另存副本") })
        XCTAssertTrue(copy.originChain.contains(OriginMarkers.text(for: .simulated)))

        let copiedPoints = try await repository.points(sessionId: copy.id)
        XCTAssertEqual(copiedPoints.count, points.count)
        XCTAssertTrue(copiedPoints.allSatisfy { $0.dataOrigin == .simulated && $0.sessionId == copy.id })
        XCTAssertEqual(try await repository.fetch(origin: .simulated, predicate: RunPredicate()).count, 2)
        XCTAssertTrue(try await repository.fetch(origin: .real, predicate: RunPredicate()).isEmpty)
    }

    func testNoSimulatedToRealConversionPath() throws {
        // [T10][AC-C7] 仓库 / 来源 / 会话 / 采样点源码中不存在任何来源转换或 mutating 入口。
        let files = [
            "CampusRunSimulator/Modules/Repository/RunRepository.swift",
            "CampusRunSimulator/Core/DataOrigin.swift",
            "CampusRunSimulator/Models/Domain/RunSession.swift",
            "CampusRunSimulator/Models/Domain/TrackPoint.swift",
            "CampusRunSimulator/Models/Persistence/ModelContainerFactory.swift"
        ]
        for file in files {
            let text = try sourceText(file)
            let hits = forbiddenConversionPatterns(text)
            XCTAssertTrue(hits.isEmpty, "\(file) 出现禁止的来源转换/改写模式：\(hits)")
            // 说明：源码注释中「不存在 simulated -> real 路径」是合规声明文本，
            // 不是实现；此处只扫描可调用的函数 / 赋值模式，不误伤注释。
        }
        let repositoryText = try sourceText(files[0])
        XCTAssertTrue(repositoryText.contains("container(for: session.dataOrigin)"),
                      "写入必须经唯一容器路由入口")
        XCTAssertTrue(repositoryText.contains("func clear(origin:"))

        // 行为断言：脏 id 的会话会被 RunPredicate 过滤，不进入任一来源的正常列表。
        let invalidID = RunSession(
            id: "real_wrong_domain",
            dataOrigin: .simulated,
            startTime: baseTime,
            endTime: baseTime,
            durationSeconds: 0,
            totalDistanceMeters: 0,
            avgSpeedMps: 0,
            avgPaceSecPerKm: 0,
            totalSteps: 0,
            elevationGainM: 0,
            elevationLossM: 0
        )
        XCTAssertFalse(invalidID.hasValidOriginID)
        XCTAssertTrue(RunPredicate().apply(to: [invalidID]).isEmpty)
    }

    func testNoHealthKitWriteFromSimulated() throws {
        // [T10][AC-C3] 不存在 simulated → HealthKit 路径：值类型守卫 + 源码级静态检查。
        // 本方法不实例化 HKHealthStore（真机写入 AC-F6 需真机验收，本地 Linux 未执行）。
        let settings = AppSettings.default
        XCTAssertFalse(settings.healthKitWriteEnabled, "默认必须关闭健康写入")
        XCTAssertFalse(settings.withHealthKitWriteEnabled(true, origin: .simulated).healthKitWriteEnabled,
                       "对测试数据永远不允许打开健康写入开关")
        XCTAssertTrue(settings.withHealthKitWriteEnabled(true, origin: .real).healthKitWriteEnabled,
                      "仅真实记录在显式勾选后才允许打开")

        let service = try sourceText(
            "CampusRunSimulator/Modules/LocationAndSensors/HealthKitService.swift"
        )
        XCTAssertTrue(service.contains("guard session.dataOrigin == .real"),
                      "write 函数体首行必须是 REAL 守卫")
        XCTAssertTrue(service.contains("throw AppError.simulatedWriteForbidden"))
        XCTAssertTrue(service.contains("routePoints.allSatisfy({ $0.dataOrigin == .real })"),
                      "逐点二次校验必须存在，防止混合来源流入健康数据")
        let contract = try sourceText("CampusRunSimulator/Contracts/SensorContracts.swift")
        XCTAssertTrue(contract.contains("guard session.dataOrigin == .real"),
                      "协议注释必须固化 REAL 守卫契约")

        let recorder = try sourceText(
            "CampusRunSimulator/Modules/LocationAndSensors/LiveRunRecorder.swift"
        )
        XCTAssertTrue(recorder.contains("writeToHealthKit: Bool = false"),
                      "结束页健康写入开关默认必须为 false")
        XCTAssertTrue(recorder.contains("guard sample.dataOrigin == .real"))

        XCTAssertEqual(AppError.simulatedWriteForbidden.resultCode, "E_SIMULATED_WRITE_FORBIDDEN")
        let description = try XCTUnwrap(AppError.simulatedWriteForbidden.errorDescription)
        XCTAssertTrue(description.contains("测试数据"))
    }

    // MARK: - [T08] 定位中断恢复 / 跨段不连线 / 稀疏间隔不插值

    func testTrackFilterGapCreatesNewSegment() {
        // [T08][AC-F5] gap 后 segmentIndex 变化，跨段不连线、不计距，段首标 .gap。
        let filter = LiveRunRecorder.TrackFilter()
        let sessionID = OriginID.makeID(.real, suffix: "gap_test")

        let first = filter.evaluate(
            sample: locationSample(at: 0, lat: 30.3010, lon: 120.0810),
            motion: nil,
            previous: [],
            sessionId: sessionID,
            elapsedSeconds: 0,
            elapsedDelta: 0,
            segmentIndex: 0
        )
        guard case .accept(let p0) = first else {
            return XCTFail("首点应被接受")
        }
        XCTAssertEqual(p0.dataOrigin, .real)
        XCTAssertEqual(p0.segmentIndex, 0)
        XCTAssertEqual(p0.cumulativeDistanceM, 0, accuracy: 1e-9)

        // 同段第二点间隔 10 s（> 3 s 稀疏门限）；坐标步进 0.0001° 约 11 m，
        // 低于野值门限 max(30, 4×精度) = 30 m，确保该点被真实接受而非误判丢弃。
        let second = filter.evaluate(
            sample: locationSample(at: 10, lat: 30.3011, lon: 120.0810),
            motion: nil,
            previous: [p0],
            sessionId: sessionID,
            elapsedSeconds: 10,
            elapsedDelta: 10,
            segmentIndex: 0
        )
        guard case .accept(let p1) = second else {
            return XCTFail("同段第二点应被接受")
        }
        XCTAssertGreaterThan(p1.cumulativeDistanceM, p0.cumulativeDistanceM)

        // 模拟 GPS 中断恢复：新建 segment 1，间隔 70 s，坐标仍在野值门限内。
        let recovered = filter.evaluate(
            sample: locationSample(at: 80, lat: 30.3012, lon: 120.0810),
            motion: nil,
            previous: [p0, p1],
            sessionId: sessionID,
            elapsedSeconds: 80,
            elapsedDelta: 70,
            segmentIndex: 1
        )
        guard case .accept(let p2) = recovered else {
            return XCTFail("中断恢复后的段首点应被接受（野值门限内）")
        }
        XCTAssertEqual(p2.segmentIndex, 1)
        XCTAssertTrue(p2.hasGap, "跨段首点必须标 .gap")
        XCTAssertTrue(p2.qualityFlags.contains(.interpolatedFalse),
                      "稀疏间隔必须标注「非插值（实测）」")
        XCTAssertEqual(p2.cumulativeDistanceM, p1.cumulativeDistanceM, accuracy: 1e-9,
                       "跨段不连线、不计距，累计距离不得虚增")
        XCTAssertTrue(p2.dataOrigin == .real)
        XCTAssertTrue(p2.id.hasPrefix("real_"))

        // 时间戳早于段内上一点（5 s < 10 s）必须丢弃，绝不重排或插值。
        let outOfOrder = filter.evaluate(
            sample: locationSample(at: 5, lat: 30.30115, lon: 120.0810),
            motion: nil,
            previous: [p0, p1],
            sessionId: sessionID,
            elapsedSeconds: 5,
            elapsedDelta: 4,
            segmentIndex: 1
        )
        guard case .discard(let reason) = outOfOrder else {
            return XCTFail("乱序时间戳必须被丢弃")
        }
        XCTAssertEqual(reason, .timestamp)

        // 稀疏间隔只出现在同段的 p0→p1；p1→p2 跨段不比较，故计数为 1。
        let quality = DataQualityReport.build(sessionId: sessionID, points: [p0, p1, p2])
        XCTAssertEqual(quality.gapSegmentCount, 2)
        XCTAssertEqual(quality.interpolatedPointCount, 0, "本项目不插值，恒为 0")
        XCTAssertEqual(quality.sparseIntervalCount, 1)
        XCTAssertTrue(quality.warnings.contains(where: { $0.contains("未插值") }))
    }

    func testCheckpointSerializationAndRestore() async throws {
        // [T08][AC-F11] 检查点序列化 / 恢复：强杀重启后已落盘段与 segmentIndex 完整保留。
        // 使用纯内存 AsyncStream 桩，不触碰 CoreLocation / CoreMotion 硬件。
        let sessionID = OriginID.makeID(.real, suffix: "checkpoint_test")
        let points = [
            makePoints(origin: .real, sessionID: sessionID, count: 3),
            [
                TrackPoint(
                    id: OriginID.makeID(.real, suffix: "checkpoint_seg1"),
                    sessionId: sessionID,
                    dataOrigin: .real,
                    timestamp: baseTime.addingTimeInterval(100),
                    elapsedSeconds: 100,
                    latitude: 30.3020,
                    longitude: 120.0820,
                    altitudeM: 13,
                    horizontalAccuracyM: 5,
                    speedMps: 2.5,
                    cumulativeDistanceM: 80,
                    segmentIndex: 1,
                    qualityFlags: [.gap]
                )
            ]
        ].flatMap { $0 }
        let checkpoint = LiveRunRecorder.RecoveryCheckpoint(
            sessionId: sessionID,
            startTime: baseTime,
            points: points,
            segmentIndex: 1,
            activeElapsedSeconds: 100,
            discardedByAccuracyGate: 2,
            discardedByOutlier: 1,
            sparseIntervalCount: 3,
            referenceRoute: nil,
            createdAt: baseTime
        )

        let original = LiveRunRecorder(
            locationProvider: StubLocationProvider(samples: finishedStream(of: LocationSample.self)),
            motionProvider: StubMotionProvider(samples: finishedStream(of: MotionSample.self))
        )
        await original.restore(checkpoint)
        let data = try await original.checkpointData()
        XCTAssertGreaterThan(data.count, 0, "检查点必须能真实序列化为非空 Data")

        // 新实例模拟 App 被强杀后重启。
        let restarted = LiveRunRecorder(
            locationProvider: StubLocationProvider(samples: finishedStream(of: LocationSample.self)),
            motionProvider: StubMotionProvider(samples: finishedStream(of: MotionSample.self))
        )
        try await restarted.restore(from: data)
        let recovered = await restarted.currentPoints()
        XCTAssertEqual(recovered.count, points.count)
        XCTAssertTrue(recovered.allSatisfy { $0.dataOrigin == .real },
                      "恢复时只接受 REAL 点，测试数据绝不流入真实记录")
        XCTAssertEqual(Set(recovered.map(\.segmentIndex)), Set([0, 1]))
        XCTAssertEqual(recovered.last?.segmentIndex, 1)
        XCTAssertTrue(recovered.contains { $0.hasGap })
        XCTAssertEqual(recovered.map(\.cumulativeDistanceM), points.map(\.cumulativeDistanceM))

        let report = await restarted.qualityReport()
        XCTAssertEqual(report.sessionId, sessionID)
        XCTAssertEqual(report.dataOrigin, .real)
        XCTAssertEqual(report.totalPointCount, points.count)
        XCTAssertEqual(report.gapSegmentCount, 2)
        XCTAssertEqual(report.interpolatedPointCount, 0)
        XCTAssertEqual(report.discardedByAccuracyGate, 3, "精度门限 + 野值丢弃数应随检查点保留")
    }

    func testSparseIntervalNotInterpolated() {
        // [T08] 稀疏间隔只标注不插值；低精度 / 越界精度点按守卫丢弃或标注。
        let filter = LiveRunRecorder.TrackFilter()
        let sessionID = OriginID.makeID(.real, suffix: "sparse_test")
        let accurate = locationSample(at: 0, lat: 30.3010, lon: 120.0810)
        guard case .accept(let p0) = filter.evaluate(
            sample: accurate, motion: nil, previous: [],
            sessionId: sessionID, elapsedSeconds: 0, elapsedDelta: 0, segmentIndex: 0
        ) else { return XCTFail("首点应被接受") }

        let sparse = locationSample(at: 10, lat: 30.3011, lon: 120.0810)
        guard case .accept(let p1) = filter.evaluate(
            sample: sparse, motion: nil, previous: [p0],
            sessionId: sessionID, elapsedSeconds: 10, elapsedDelta: 10, segmentIndex: 0
        ) else { return XCTFail("稀疏点仍应作为实测点保留") }
        XCTAssertTrue(p1.qualityFlags.contains(.interpolatedFalse))
        XCTAssertFalse(p1.qualityFlags.contains(.gap), "同段稀疏不等于中断")

        let badAccuracy = LocationSample(
            coordinate: GeoPoint(latitude: 30.3012, longitude: 120.0810),
            altitudeM: 12,
            horizontalAccuracyM: 120,
            verticalAccuracyM: 3,
            courseDegrees: 90,
            speedMps: 2.5,
            timestamp: baseTime.addingTimeInterval(11)
        )
        guard case .discard(let reason) = filter.evaluate(
            sample: badAccuracy, motion: nil, previous: [p0, p1],
            sessionId: sessionID, elapsedSeconds: 11, elapsedDelta: 1, segmentIndex: 0
        ) else { return XCTFail("超过 50 m 精度门限的点必须丢弃") }
        XCTAssertEqual(reason, .accuracy)

        let quality = DataQualityReport.build(sessionId: sessionID, points: [p0, p1], discarded: 1)
        XCTAssertEqual(quality.sparseIntervalCount, 1)
        XCTAssertEqual(quality.interpolatedPointCount, 0)
        XCTAssertEqual(quality.discardedByAccuracyGate, 1)
        XCTAssertTrue(quality.summary.contains("本项目不插值"))
    }
}

// MARK: - 纯内存传感器桩（不初始化任何系统定位 / 运动硬件）

private func finishedStream<T: Sendable>(of type: T.Type) -> AsyncStream<T> {
    _ = type
    return AsyncStream { continuation in
        continuation.finish()
    }
}

private final class StubLocationProvider: LocationProvider, @unchecked Sendable {
    let samples: AsyncStream<LocationSample>
    let authorizationSnapshot: PermissionSnapshot = .unknown

    init(samples: AsyncStream<LocationSample>) {
        self.samples = samples
    }

    func requestAuthorization() {}
    func start() throws {}
    func pause() {}
    func resume() {}
    func stop() {}
}

private final class StubMotionProvider: MotionProvider, @unchecked Sendable {
    let samples: AsyncStream<MotionSample>

    init(samples: AsyncStream<MotionSample>) {
        self.samples = samples
    }

    func availability() -> MotionAvailability { .fullyUnavailable }
    func start(from: Date) throws {}
    func stop() {}
}
