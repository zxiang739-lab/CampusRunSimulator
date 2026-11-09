import Foundation
import XCTest
@testable import CampusRunSimulator

/// F60 · 仿真引擎纯逻辑测试（AC-D1–D8 / T01–T07）。
///
/// 诚实边界：
/// - 本文件只验证确定性数学与 in-memory 数据层，不初始化任何 `CLLocationManager` / `HKHealthStore` / `CMAltimeter`；
/// - 后台 30 min 连续记录（AC-F5）、HealthKit 真机写入、iOS 26 双路径 UI 等价均**需真机 / CI 验收，本地 Linux 未执行**，
///   见 README.md「真机验收清单」；本文件只断言后台配置常量与暂停回调的纯逻辑；
/// - `[T12] Xcode 完整编译` 由 F71 的 build-test job 承担，见 README 映射表。
final class SimulationEngineTests: XCTestCase {

    // MARK: - 测试夹具（纯值类型，不触碰硬件）

    /// 杭州某高校周边约 500 m 尺度的闭合环，首尾同点，供弧长参数化使用。
    private func makeLoopRoute() -> Route {
        Route(
            name: "测试闭环",
            routeType: .loop,
            points: [
                RoutePoint(orderIndex: 0, latitude: 30.3010, longitude: 120.0810),
                RoutePoint(orderIndex: 1, latitude: 30.3018, longitude: 120.0810),
                RoutePoint(orderIndex: 2, latitude: 30.3026, longitude: 120.0819),
                RoutePoint(orderIndex: 3, latitude: 30.3026, longitude: 120.0832),
                RoutePoint(orderIndex: 4, latitude: 30.3018, longitude: 120.0841),
                RoutePoint(orderIndex: 5, latitude: 30.3010, longitude: 120.0832),
                RoutePoint(orderIndex: 6, latitude: 30.3010, longitude: 120.0810)
            ],
            elevationSource: .userDefined
        )
    }

    private func makeShortProfile(seed: UInt64 = 20_261_108) -> SimulationProfile {
        SimulationProfile(
            name: "单测稳态配置",
            modelType: .steady,
            phases: [],
            targetCadenceSpm: 170,
            referenceStrideLengthM: 1.1,
            noiseAmplitude: 0.02,
            slopeInfluence: 0,
            sampleRateHz: 1,
            seed: seed,
            totalDurationSeconds: 60,
            totalDistanceMeters: nil,
            customCurve: nil
        )
    }

    private func generate(profile: SimulationProfile) async throws -> SimulationResult {
        try await DefaultSimulationEngine().generate(profile: profile, route: makeLoopRoute())
    }

    // MARK: - [T01] GPS 轨迹连续性

    /// 相邻点由弧长唯一决定：坐标有限、落在合法经纬度、每帧位移有界且无瞬移跳跃。
    func testTrackPointContinuity() async throws {
        // [T01] GPS 轨迹连续性
        let result = try await generate(profile: makeShortProfile())
        let points = result.points
        XCTAssertGreaterThanOrEqual(points.count, 60, "1 Hz × 60 s 应产生至少 61 个采样点")

        var previous: TrackPoint? = nil
        for point in points {
            XCTAssertTrue(point.latitude.isFinite && point.longitude.isFinite,
                          "采样点坐标必须有限，禁止 NaN / inf")
            XCTAssertGreaterThanOrEqual(point.latitude, -90)
            XCTAssertLessThanOrEqual(point.latitude, 90)
            XCTAssertGreaterThanOrEqual(point.longitude, -180)
            XCTAssertLessThanOrEqual(point.longitude, 180)
            XCTAssertEqual(point.dataOrigin, .simulated, "仿真点来源恒为 .simulated")
            if let previous = previous {
                let deltaT = point.elapsedSeconds - previous.elapsedSeconds
                XCTAssertGreaterThan(deltaT, 0, "时间戳严格单调，禁止 Δt = 0")
                let step = Units.haversineMeters(previous.geoPoint, point.geoPoint)
                // 3.2 m/s 附近 1 s 位移应远小于 30 m；闭环取模不得产生瞬移。
                XCTAssertLessThan(step, 30, "相邻帧出现瞬移跳跃，弧长参数化被破坏")
                XCTAssertGreaterThanOrEqual(
                    point.cumulativeDistanceM, previous.cumulativeDistanceM,
                    "累计距离不得倒退"
                )
            }
            previous = point
        }
    }

    // MARK: - [T02] 距离计算准确性

    /// Haversine 已知基线 + Σ相邻距离与会话总距离偏差 < 0.5%（AC-D3）。
    func testDistanceAccuracy() async throws {
        // [T02] 距离计算准确性
        let equatorA = GeoPoint(latitude: 0, longitude: 120)
        let equatorB = GeoPoint(latitude: 1, longitude: 120)
        let oneDegree = Units.haversineMeters(equatorA, equatorB)
        XCTAssertGreaterThan(oneDegree, 110_000)
        XCTAssertLessThan(oneDegree, 112_000)
        XCTAssertEqual(Units.haversineMeters(equatorA, equatorA), 0, accuracy: 1e-9)

        // 统一距离口径：CLLocation 椭球与 Haversine 球面在校园尺度下差异应 < 1%。
        let campusA = GeoPoint(latitude: 30.3010, longitude: 120.0810)
        let campusB = GeoPoint(latitude: 30.3018, longitude: 120.0810)
        let spherical = Units.haversineMeters(campusA, campusB)
        let ellipsoidal = Units.distanceMeters(campusA, campusB)
        XCTAssertGreaterThan(spherical, 0)
        XCTAssertGreaterThan(ellipsoidal, 0)
        XCTAssertLessThan(abs(spherical - ellipsoidal) / max(1, spherical), 0.01)

        let result = try await generate(profile: makeShortProfile())
        var accumulated = 0.0
        for index in 1..<result.points.count {
            accumulated += Units.distanceMeters(
                result.points[index - 1].geoPoint, result.points[index].geoPoint
            )
        }
        let declared = result.session.totalDistanceMeters
        XCTAssertGreaterThan(declared, 0)
        XCTAssertLessThan(abs(accumulated - declared) / max(1, declared),
                          AppConstants.toleranceDistance,
                          "Σ distance(P_i-1, P_i) 与 totalDistanceMeters 偏差须 < 0.5%")
        XCTAssertEqual(result.points.last?.cumulativeDistanceM ?? 0, declared,
                       accuracy: max(0.01, declared * AppConstants.toleranceDistance))
    }

    // MARK: - [T03] 步频与步幅一致性

    func testStrideDerivedFromSpeedAndCadence() async throws {
        // [T03] 步频与步幅一致性（L = 60v/c、ΣΔsteps·L = ΣΔd）
        let result = try await generate(profile: makeShortProfile())
        for point in result.points {
            let expected = Units.strideLength(speedMps: point.speedMps, cadenceSpm: point.cadenceSpm)
            XCTAssertEqual(point.strideLengthM, expected, accuracy: 1e-9,
                           "L 必须由 v/c 确定性派生，不得独立设定")
            XCTAssertTrue(point.strideLengthM.isFinite)
        }
        // ΣΔsteps·L 与 ΣΔd 偏差 < 1%（AC-D2）。
        var stepDistance = 0.0
        var distanceDelta = 0.0
        for index in 1..<result.points.count {
            let previous = result.points[index - 1]
            let current = result.points[index]
            let deltaT = current.elapsedSeconds - previous.elapsedSeconds
            let deltaSteps = current.cumulativeSteps - previous.cumulativeSteps
            stepDistance += deltaSteps * current.strideLengthM
            distanceDelta += current.cumulativeDistanceM - previous.cumulativeDistanceM
            XCTAssertEqual(deltaSteps,
                           Units.stepIncrement(cadenceSpm: current.cadenceSpm, deltaSeconds: deltaT),
                           accuracy: 1e-6, "单帧步数增量必须来自 c·Δt/60")
        }
        XCTAssertGreaterThan(distanceDelta, 0)
        XCTAssertLessThan(abs(stepDistance - distanceDelta) / max(1, distanceDelta),
                          AppConstants.toleranceStepDistance,
                          "ΣΔsteps·L 与累计距离偏差须 < 1%")
    }

    // MARK: - [T04] 配速计算

    func testPaceCalculation() async throws {
        // [T04] 配速计算（瞬时 / 平均 / 单位换算）
        XCTAssertEqual(Units.paceSecPerKm(deltaSeconds: 300, deltaMeters: 1000), 300, accuracy: 1e-9)
        XCTAssertEqual(Units.averagePaceSecPerKm(totalSeconds: 300, totalMeters: 1000), 300, accuracy: 1e-9)
        XCTAssertEqual(Units.minPerKmToSecPerKm(5), 300, accuracy: 1e-9)
        XCTAssertEqual(Units.secPerKmToMinPerKm(300), 5, accuracy: 1e-9)
        XCTAssertEqual(Units.speedMpsToKmH(2.5), 9, accuracy: 1e-9)

        let result = try await generate(profile: makeShortProfile())
        for index in 1..<result.points.count {
            let previous = result.points[index - 1]
            let current = result.points[index]
            let deltaT = current.elapsedSeconds - previous.elapsedSeconds
            let deltaD = current.cumulativeDistanceM - previous.cumulativeDistanceM
            let expectedInstant = deltaD > 0
                ? Units.paceSecPerKm(deltaSeconds: deltaT, deltaMeters: deltaD)
                : 0
            XCTAssertEqual(current.instantPaceSecPerKm, expectedInstant, accuracy: 1e-6)
            let expectedAverage = current.cumulativeDistanceM > 0
                ? Units.averagePaceSecPerKm(
                    totalSeconds: current.elapsedSeconds,
                    totalMeters: current.cumulativeDistanceM
                  )
                : 0
            XCTAssertEqual(current.avgPaceSecPerKm, expectedAverage, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(result.session.avgPaceSecPerKm, 0)
    }

    // MARK: - [T05] 海拔变化（gain/loss 死区、上下坡）

    func testElevationGainLossDeadband() async throws {
        // [T05] 海拔变化：死区生效、上下坡、gain − loss = h_end − h0
        let deadband = AppConstants.elevationDeadbandMeters
        let jitter = Units.elevationGainLoss([10, 10.5, 10.2, 10.8, 10.1], deadband: deadband)
        XCTAssertEqual(jitter.gain, 0, accuracy: 1e-9,
                       "死区内的微小抖动不得产生虚假爬升")
        XCTAssertEqual(jitter.loss, 0, accuracy: 1e-9)

        let climb = Units.elevationGainLoss([10, 15, 12], deadband: 0)
        XCTAssertEqual(climb.gain, 5, accuracy: 1e-9)
        XCTAssertEqual(climb.loss, 3, accuracy: 1e-9)
        XCTAssertEqual(climb.gain - climb.loss, 12 - 10, accuracy: 1e-9)
        XCTAssertEqual(Units.slopePercent(deltaAltitudeM: 5, horizontalDistanceM: 100), 5, accuracy: 1e-9)

        let result = try await generate(profile: makeShortProfile())
        let last = try XCTUnwrap(result.points.last)
        XCTAssertGreaterThanOrEqual(last.elevationGainSoFarM, 0)
        XCTAssertGreaterThanOrEqual(last.elevationLossSoFarM, 0)
        XCTAssertTrue(last.altitudeM.isFinite)
        XCTAssertEqual(result.session.elevationGainM, last.elevationGainSoFarM, accuracy: 1e-6)
        XCTAssertEqual(result.session.elevationLossM, last.elevationLossSoFarM, accuracy: 1e-6)
    }

    // MARK: - [T06] 长时间运动模拟（≥30 min / 1800+ 点，性能与内存断言）

    func testLongRunPerformance() async throws {
        // [T06] 长时间运动模拟：1800 s / 1 Hz，含耗时与内存驻留上界断言
        let profile = SimulationProfile(
            name: "30 分钟长时测试",
            modelType: .steady,
            phases: [],
            targetCadenceSpm: 170,
            referenceStrideLengthM: 1.1,
            noiseAmplitude: 0.02,
            slopeInfluence: 0,
            sampleRateHz: 1,
            seed: 30_000_001,
            totalDurationSeconds: 1800,
            totalDistanceMeters: nil,
            customCurve: nil
        )
        let engine = DefaultSimulationEngine()
        let started = Date()
        let frames = try await engine.preview(profile: profile, route: makeLoopRoute())
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(frames.count, 1801, "1 Hz × 1800 s 应恰好产生 1801 帧")
        XCTAssertEqual(frames.last?.t ?? 0, 1800, accuracy: 1e-9)
        XCTAssertLessThan(elapsed, 20.0, "30 min 仿真纯计算耗时应控制在 20 s 内（CI 模拟器放宽）")
        // 内存断言：帧数组驻留字节估算需有正下界且有明确上界。
        let residentBytes = frames.count * MemoryLayout<SimulationFrame>.stride
        XCTAssertGreaterThan(residentBytes, 0)
        XCTAssertLessThan(residentBytes, 20_000_000,
                          "1801 帧驻留内存应低于 20 MB；真机内存峰值仍需 Instruments 人工验收")
        for index in 1..<min(frames.count, 64) {
            XCTAssertGreaterThan(frames[index].t, frames[index - 1].t, "长时仿真时间戳严格单调")
        }
        XCTAssertTrue(frames.allSatisfy { $0.speedMps.isFinite && $0.arcLengthM.isFinite })
    }

    // MARK: - [T07] 后台运行（配置常量与自动暂停回调逻辑）

    func testBackgroundConfigurationConstants() throws {
        // [T07] 后台运行：只验证配置常量与暂停标记纯逻辑；
        // 真机后台 30 min 连续记录 AC-F5 需人工验收，本地 Linux 未执行，不在此声称已通过。
        let plist = try loadInfoPlist()
        let modes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String],
                                  "Info.plist 必须声明 UIBackgroundModes")
        XCTAssertTrue(modes.contains("location"), "真实记录需要后台定位模式")
        let purposeKeys = [
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSMotionUsageDescription",
            "NSHealthShareUsageDescription",
            "NSHealthUpdateUsageDescription"
        ]
        for key in purposeKeys {
            let text = try XCTUnwrap(plist[key] as? String, "缺少权限用途描述 \(key)")
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        let backgroundError = AppError.backgroundPaused
        XCTAssertFalse(backgroundError.errorDescription?.isEmpty ?? true)
        XCTAssertEqual(backgroundError.resultCode, "E_BACKGROUND_PAUSED")
        let pausedPoint = TrackPoint(
            id: OriginID.makeID(.real),
            sessionId: OriginID.makeID(.real),
            dataOrigin: .real,
            timestamp: Date(),
            elapsedSeconds: 10,
            latitude: 30.3010,
            longitude: 120.0810,
            altitudeM: 12,
            qualityFlags: [.paused]
        )
        XCTAssertTrue(pausedPoint.isPaused, "暂停标记应可由 TrackPoint 读取（暂停段不计距、不计时）")
        XCTAssertEqual(QualityFlag.paused.localizedDescription, "暂停（不计距）")
    }

    // MARK: - 同种子复现 / 6 模型 / 单位换算（AC-D5 / AC-D8）

    func testSameSeedReproducesByteIdentical() async throws {
        // [T01][T02] 同 seed + 同 profile 两次生成逐字段浮点全等（AC-D5）
        let profile = makeShortProfile(seed: 77_777)
        let first = try await generate(profile: profile)
        let second = try await generate(profile: profile)
        XCTAssertEqual(first.points.count, second.points.count)
        for index in 0..<first.points.count {
            let a = first.points[index]
            let b = second.points[index]
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.elapsedSeconds, b.elapsedSeconds)
            XCTAssertEqual(a.latitude, b.latitude)
            XCTAssertEqual(a.longitude, b.longitude)
            XCTAssertEqual(a.altitudeM, b.altitudeM)
            XCTAssertEqual(a.speedMps, b.speedMps)
            XCTAssertEqual(a.cadenceSpm, b.cadenceSpm)
            XCTAssertEqual(a.strideLengthM, b.strideLengthM)
            XCTAssertEqual(a.cumulativeSteps, b.cumulativeSteps)
            XCTAssertEqual(a.cumulativeDistanceM, b.cumulativeDistanceM)
            XCTAssertEqual(a.instantPaceSecPerKm, b.instantPaceSecPerKm)
            XCTAssertEqual(a.avgPaceSecPerKm, b.avgPaceSecPerKm)
            XCTAssertEqual(a.elevationGainSoFarM, b.elevationGainSoFarM)
            XCTAssertEqual(a.elevationLossSoFarM, b.elevationLossSoFarM)
            XCTAssertEqual(a.timestamp, b.timestamp)
        }
        let different = try await generate(profile: makeShortProfile(seed: 77_778))
        XCTAssertNotEqual(different.points.last?.cumulativeDistanceM,
                          first.points.last?.cumulativeDistanceM,
                          "不同种子应产生不同轨迹，证明未使用固定假数据")
    }

    func testAllSixModelsGenerate() async throws {
        // [T01][T03] 6 种速度模型均可生成 / 预览（AC-D8）
        XCTAssertEqual(SpeedModelType.allCases.count, 6)
        for type in SpeedModelType.allCases {
            let profile = SimulationProfile(
                name: "模型 \(type.rawValue)",
                modelType: type,
                phases: [],
                targetCadenceSpm: 170,
                referenceStrideLengthM: 1.1,
                noiseAmplitude: 0.02,
                slopeInfluence: 0.1,
                sampleRateHz: 1,
                seed: 9_001,
                totalDurationSeconds: 40,
                totalDistanceMeters: nil,
                customCurve: type == .custom
                    ? CustomSpeedCurve(samples: [
                        CustomSpeedSample(timeSeconds: 0, speedMps: 2.4),
                        CustomSpeedSample(timeSeconds: 40, speedMps: 3.0)
                      ])
                    : nil
            )
            let frames = try await DefaultSimulationEngine().preview(
                profile: profile, route: makeLoopRoute()
            )
            XCTAssertEqual(frames.count, 41, "\(type.rawValue) 模型应生成 41 帧")
            XCTAssertTrue(frames.allSatisfy { $0.speedMps.isFinite && $0.speedMps >= 0 },
                          "\(type.rawValue) 模型速度不得为负或 NaN")
            XCTAssertTrue(frames.allSatisfy { $0.dataOrigin == .simulated })
        }
    }

    func testUnitConversions() throws {
        // [T02][T04] 单位与量纲唯一实现处（F11）交叉校验
        XCTAssertEqual(Units.metersPerKilometer, 1000, accuracy: 1e-9)
        XCTAssertEqual(Units.secondsPerMinute, 60, accuracy: 1e-9)
        XCTAssertEqual(Units.strideLength(speedMps: 3, cadenceSpm: 180), 1, accuracy: 1e-9)
        XCTAssertEqual(Units.strideLength(speedMps: 3, cadenceSpm: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(Units.stepIncrement(cadenceSpm: 180, deltaSeconds: 2), 6, accuracy: 1e-9)
        XCTAssertEqual(Units.kmHToSpeedMps(Units.speedMpsToKmH(2.75)), 2.75, accuracy: 1e-9)
        XCTAssertEqual(Units.absoluteAltitude(relativeM: 5, initialAltitudeM: 12), 17, accuracy: 1e-9)
        XCTAssertFalse(Units.formatDistanceKm(1500).isEmpty)
        XCTAssertFalse(Units.formatDuration(65).isEmpty)
        XCTAssertFalse(Units.formatPaceMinPerKm(300).isEmpty)
    }

    // MARK: - 辅助：读取 App 的 Info.plist

    /// 优先取宿主 App bundle；CI 下若资源未被拷贝，则退回 `#filePath` 相对源码目录读取。
    private func loadInfoPlist() throws -> [String: Any] {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Info", withExtension: "plist") {
            candidates.append(bundled)
        }
        if let testBundled = Bundle(for: SimulationEngineTests.self)
            .url(forResource: "Info", withExtension: "plist") {
            candidates.append(testBundled)
        }
        // 兜底：#filePath = <repo>/CampusRunSimulatorTests/SimulationEngineTests.swift
        let sourceRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            sourceRoot.appendingPathComponent("CampusRunSimulator/Resources/Info.plist")
        )
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] {
                return plist
            }
        }
        XCTFail("无法定位 CampusRunSimulator/Resources/Info.plist（Bundle 与 #filePath 兜底均失败）")
        return [:]
    }
}
