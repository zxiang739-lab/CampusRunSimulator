import Foundation
import XCTest
@testable import CampusRunSimulator

/// F61 · I1–I10 一致性校验器测试（AC-D7 / T01–T06）。
///
/// 诚实边界：注入矛盾、拒绝生成均为纯逻辑断言，可在 iOS Simulator 下的 in-memory 环境执行；
/// 真机长时间录制后的恢复校验需真机 / CI 验收，本地 Linux 未执行。
final class InvariantValidatorTests: XCTestCase {

    private func makeLoopRoute() -> Route {
        Route(
            name: "校验器测试闭环",
            routeType: .loop,
            points: [
                RoutePoint(orderIndex: 0, latitude: 30.3010, longitude: 120.0810),
                RoutePoint(orderIndex: 1, latitude: 30.3018, longitude: 120.0810),
                RoutePoint(orderIndex: 2, latitude: 30.3026, longitude: 120.0819),
                RoutePoint(orderIndex: 3, latitude: 30.3026, longitude: 120.0832),
                RoutePoint(orderIndex: 4, latitude: 30.3010, longitude: 120.0832),
                RoutePoint(orderIndex: 5, latitude: 30.3010, longitude: 120.0810)
            ],
            elevationSource: .userDefined
        )
    }

    private func makeProfile(seed: UInt64 = 61_061) -> SimulationProfile {
        SimulationProfile(
            name: "校验器配置",
            modelType: .steady,
            phases: [],
            targetCadenceSpm: 168,
            referenceStrideLengthM: 1.05,
            noiseAmplitude: 0.02,
            slopeInfluence: 0,
            sampleRateHz: 1,
            seed: seed,
            totalDurationSeconds: 30,
            totalDistanceMeters: nil,
            customCurve: nil
        )
    }

    // MARK: - [T01]–[T06] I1–I10 逐项通过

    func testAllInvariantsPass() async throws {
        // [T01][T02][T03][T04][T05][T06] 引擎自洽数据应逐项通过 I1–I10
        let profile = makeProfile()
        let result = try await DefaultSimulationEngine().generate(
            profile: profile, route: makeLoopRoute()
        )
        let report = InvariantValidator().validate(
            session: result.session, points: result.points, profile: profile
        )
        XCTAssertEqual(report.checks.count, 10, "I1–I10 必须逐项输出，共 10 条")
        let ids = Set(report.checks.map(\.id))
        XCTAssertEqual(ids, Set(InvariantID.allCases), "不得漏检任一不变量")
        XCTAssertTrue(report.allPassed, "自洽数据应全部通过：\(report.summary)")
        XCTAssertTrue(report.isCompleteAndPassed, "完整且全部通过才允许生成")
        XCTAssertTrue(report.failedIDs.isEmpty)
        for check in report.checks {
            XCTAssertTrue(check.passed, "\(check.id.rawValue) 失败：\(check.detail)")
            XCTAssertFalse(check.detail.isEmpty, "每项必须给出可读结论")
        }
        XCTAssertTrue(result.report.isCompleteAndPassed, "引擎内部校验报告同样应通过")
    }

    // MARK: - [T01]–[T06] 逐 I 注入矛盾 → 对应项失败

    func testInjectedContradictionRejected() {
        // [T01] I1 时间单调 / [T02] I2 位置由弧长决定 / [T03] I3 距离 / [T04] I4 速度
        // [T05] I5 平均量 / [T06] I6 配速 / [T03] I7 步幅 / [T05] I8 海拔
        // [T06] I9 单一真值源 / [T01] I10 可复现
        let validator = InvariantValidator()
        for id in InvariantID.allCases {
            let dataset = InvariantValidator.injectContradiction(for: id)
            let report = validator.validate(
                session: dataset.session,
                points: dataset.points,
                profile: dataset.profile
            )
            XCTAssertEqual(report.checks.count, 10, "\(id.rawValue) 注入后仍须输出完整 10 项")
            XCTAssertFalse(report.isCompleteAndPassed,
                           "注入 \(id.rawValue) 矛盾后不得判定为可生成")
            XCTAssertTrue(report.failedIDs.contains(dataset.expectedFailedID),
                          "期望命中 \(dataset.expectedFailedID.rawValue)，实际失败项：\(report.failedIDs.map(\.rawValue))")
            let hit = report.checks.first { $0.id == dataset.expectedFailedID }
            XCTAssertEqual(hit?.passed, false, "\(id.rawValue) 对应检查项必须标记失败")
        }
    }

    /// 逐项单独断言（便于 CI 日志定位到具体 I 编号）。
    func testEachInvariantHasIndependentCheck() async throws {
        // [T01]–[T06] 每个 I 编号都有独立的检查函数与独立的失败详情
        let profile = makeProfile()
        let result = try await DefaultSimulationEngine().generate(
            profile: profile, route: makeLoopRoute()
        )
        let validator = InvariantValidator()
        for id in InvariantID.allCases {
            let tampered = InvariantValidator.injectContradiction(for: id, into: result.points)
            let report = validator.validate(
                session: result.session, points: tampered, profile: profile
            )
            let failed = report.checks.filter { !$0.passed }
            XCTAssertFalse(failed.isEmpty,
                           "\(id.rawValue) 注入矛盾后至少一项检查必须失败")
            XCTAssertTrue(failed.allSatisfy { !$0.detail.isEmpty },
                          "\(id.rawValue) 每个失败项都要给出原因")
        }
    }

    // MARK: - 失败拒绝生成（不是警告）

    func testGenerationRefusedOnFailure() async throws {
        // [T06] 一致性失败时引擎拒绝生成（AC-D7），不落盘、不返回可用结果
        let baseline = InvariantValidator.injectContradiction(for: .I5)
        let refused = InvariantValidator().validate(
            session: baseline.session, points: baseline.points, profile: baseline.profile
        )
        XCTAssertFalse(refused.isCompleteAndPassed)
        XCTAssertTrue(refused.failedIDs.contains(.I5))

        // 参数层面构造冲突：声明总距离与时长×速度估算明显不符 → validateParameters 抛错。
        let conflicting = SimulationProfile(
            name: "冲突配置",
            modelType: .steady,
            phases: [],
            targetCadenceSpm: 170,
            referenceStrideLengthM: 1.1,
            noiseAmplitude: 0,
            slopeInfluence: 0,
            sampleRateHz: 1,
            seed: 61_062,
            totalDurationSeconds: 60,
            totalDistanceMeters: 10,
            customCurve: nil
        )
        let engine = DefaultSimulationEngine()
        XCTAssertThrowsError(
            try engine.validateParameters(profile: conflicting, route: makeLoopRoute())
        ) { error in
            XCTAssertTrue(error is AppError, "参数冲突应抛出 AppError.parameterConflict")
        }
        let outcome = await engine.outcome(for: conflicting, route: makeLoopRoute())
        XCTAssertFalse(outcome.isAccepted, "冲突配置不得被接受")
        XCTAssertNil(outcome.effectiveSeed)
        XCTAssertNotNil(outcome.rejectionError)
    }

    // MARK: - 报告可读性

    func testInvariantReportSummaryIsReadable() {
        // [T06] 报告摘要与逐项结论均含简体中文说明
        let dataset = InvariantValidator.injectContradiction(for: .I7)
        let report = InvariantValidator().validate(
            session: dataset.session, points: dataset.points, profile: dataset.profile
        )
        XCTAssertFalse(report.summary.isEmpty)
        XCTAssertFalse(InvariantID.I7.localizedDescription.isEmpty)
        XCTAssertEqual(InvariantID.allCases.count, 10)
    }
}
