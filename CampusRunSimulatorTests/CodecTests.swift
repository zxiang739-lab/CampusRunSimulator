import Foundation
import XCTest
@testable import CampusRunSimulator

/// F62 · 编解码与三重标记测试（AC-C2 / AC-F2 / AC-F3 / AC-C7 / [T09]）。
///
/// 诚实边界：
/// - 本文件只验证纯数据层（GPX / CSV / JSON 文本与值类型），不初始化任何硬件服务、不联网；
/// - Fixtures 采用三级兜底（QA R3）：① test bundle ② `#filePath` 相对源码目录 ③ 与
///   `Fixtures/*.gpx` 逐字一致的内联常量；iOS Simulator 独立文件系统无法访问 macOS 主机路径，
///   且 Xcode 16 同步根组不保证把 `.gpx` 拷入 test bundle，故第三级保证 [T09] 在任意 CI 环境
///   都能执行；`loadFixture` 不再因资源未拷贝而 XCTFail；
/// - CSV 为**单向导出通道**（App 不提供 CSV 导入），因此「往返一致」在文本层逐列比对；
///   GPX 与 JSON 为真正的编解码双向往返。此处如实标注，不夸大为「三种格式都能导入」；
/// - 真机 GPX 导入、系统分享面板弹出等需真机 / CI 验收，本地 Linux 未执行。
final class CodecTests: XCTestCase {

    // MARK: - 测试夹具（纯值类型）

    /// 固定的 UTC 基准时间，保证时间戳断言可复现。
    private let baseTime = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    private func makeSession(origin: DataOrigin, note: String = "编解码测试记录") -> RunSession {
        RunSession(
            id: OriginID.makeID(origin, suffix: "codec_\(origin.rawValue)"),
            dataOrigin: origin,
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(60),
            durationSeconds: 60,
            totalDistanceMeters: 120,
            avgSpeedMps: 2.0,
            avgPaceSecPerKm: 500,
            totalSteps: 170,
            elevationGainM: 2.5,
            elevationLossM: 1.0,
            note: note,
            createdAt: baseTime,
            schemaVersion: AppConstants.schemaVersion
        )
    }

    /// 生成 6 个点，分 2 个 segment（0..2 → 段 0，3..5 → 段 1）。
    /// 段首点 `cumulativeDistanceM` 不递增，模拟「跨段不连线、不计距」。
    private func makePoints(origin: DataOrigin, sessionID: String) -> [TrackPoint] {
        var result: [TrackPoint] = []
        var cumulative = 0.0
        for index in 0..<6 {
            let segment = index < 3 ? 0 : 1
            if index > 0 && index != 3 {
                cumulative += 20
            }
            // 拆分子表达式，避免 22 个参数的大初始化触发类型检查超时。
            let idx = Double(index)
            let ts = baseTime.addingTimeInterval(idx * 10)
            let lat: Double = 30.3010 + idx * 0.0002
            let lon: Double = 120.0810 + idx * 0.0002
            let alt: Double = 12.5 + idx * 0.3
            let stride: Double = Units.strideLength(speedMps: 2.0, cadenceSpm: 170)
            let steps: Double = idx * 28
            let gainSoFar: Double = idx * 0.3
            let flags: [QualityFlag] = (segment == 1 && index == 3) ? [.gap] : []
            result.append(
                TrackPoint(
                    id: OriginID.makeID(origin, suffix: "codec_point_\(index)"),
                    sessionId: sessionID,
                    dataOrigin: origin,
                    timestamp: ts,
                    elapsedSeconds: idx * 10,
                    latitude: lat,
                    longitude: lon,
                    altitudeM: alt,
                    horizontalAccuracyM: 5,
                    verticalAccuracyM: 3,
                    courseDegrees: 90,
                    speedMps: 2.0,
                    speedAccuracyMps: 0.2,
                    instantPaceSecPerKm: 500,
                    avgPaceSecPerKm: 500,
                    cadenceSpm: 170,
                    strideLengthM: stride,
                    cumulativeSteps: steps,
                    cumulativeDistanceM: cumulative,
                    elevationGainSoFarM: gainSoFar,
                    elevationLossSoFarM: 0,
                    segmentIndex: segment,
                    qualityFlags: flags
                )
            )
        }
        return result
    }

    /// Fixture 定位（QA R3 三级兜底）：test bundle → `#filePath` 相对源码目录 → 内联常量。
    /// iOS Simulator 运行在独立文件系统，无法访问 macOS 主机的 `#filePath`；Xcode 16 同步根组
    /// 也不保证把 `.gpx` 拷入 test bundle。第三级内联常量与 `Fixtures/*.gpx` 逐字一致，
    /// 保证 [T09] 在任意 CI 环境都能执行，不再因资源未拷贝而 XCTFail。
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CodecTests.self)
        var candidates: [URL] = []
        if let url = bundle.url(forResource: name, withExtension: "gpx") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: name, withExtension: "gpx", subdirectory: "Fixtures") {
            candidates.append(url)
        }
        let sourceRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            sourceRoot.appendingPathComponent("CampusRunSimulatorTests/Fixtures/\(name).gpx")
        )
        // ① test bundle ② #filePath 相对源码目录：命中即返回真实文件字节。
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try Data(contentsOf: url)
        }
        // ③ 内联兜底：与 Fixtures/*.gpx 内容一致，脱离 bundle 资源与主机路径依赖。
        if let inline = Self.inlineFixture(named: name) {
            return Data(inline.utf8)
        }
        // 未知样例名属于测试代码错误，抛出明确错误，不静默返回空数据。
        throw FixtureLookupError.unknownFixture(name)
    }

    // MARK: - GPX 内联兜底常量（QA R3）

    /// F66：GPX 1.1 闭合环，两个 <trkseg>，ele/time 齐备，含 SIMULATED 三重标记（文件名 / metadata / extensions / trk/name）。
    /// 与 `CampusRunSimulatorTests/Fixtures/SIMULATED_sample_loop.gpx` 内容逐字一致。
    private static let inlineLoopGPX: String = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  F66 · 正常 GPX 1.1 基准样例（教学研究 / 个人自用 / 数据分析用测试数据）
  文件名带 SIMULATED_ 前缀；文件内三重标记齐全：
    ① 文件名 SIMULATED_  ② 文件内 metadata / extensions / trk/name 含 SIMULATED 与 dataOrigin
    ③ UI 徽标元数据（badgeText / badgeSymbol / badgeAccessibilityLabel）
  坐标取杭州某高校周边约 300 m 尺度的闭合环，仅作格式基准，不代表任何真实运动成绩。
  两个 <trkseg> 用于验证「跨段不连线、不计距」；首尾同点用于验证闭合环。
-->
<gpx version="1.1" creator="CampusRunSimulator"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:crs="http://www.campusrun.simulator/gpx/ext/1.0">
  <metadata>
    <name>SIMULATED / 测试数据 / SIMULATED · 闭合环样例</name>
    <desc>以下均为示例假设值，非任何平台真实规则，仅供本地模拟研究；本评估不产生、不上传任何成绩。 dataOrigin=SIMULATED isHypothetical=true generator=CampusRunSimulator schemaVersion=1.0</desc>
    <author>
      <name>CampusRunSimulator</name>
    </author>
  </metadata>
  <extensions>
    <crs:dataOrigin>simulated</crs:dataOrigin>
    <crs:isHypothetical>true</crs:isHypothetical>
    <crs:disclaimer>以下均为示例假设值，非任何平台真实规则，仅供本地模拟研究；本评估不产生、不上传任何成绩。</crs:disclaimer>
    <crs:generator>CampusRunSimulator</crs:generator>
    <crs:schemaVersion>1.0</crs:schemaVersion>
    <crs:badgeText>测试数据 / SIMULATED</crs:badgeText>
    <crs:badgeSymbol>testtube.2</crs:badgeSymbol>
    <crs:badgeAccessibilityLabel>测试数据 SIMULATED</crs:badgeAccessibilityLabel>
  </extensions>
  <wpt lat="30.30100" lon="120.08100">
    <ele>12.5</ele>
    <name>SIMULATED_起点 / 终点</name>
  </wpt>
  <trk>
    <name>SIMULATED_campus_loop_baseline</name>
    <desc>测试数据 / SIMULATED；闭合环，两个 trkseg，跨段不连线</desc>
    <trkseg>
      <trkpt lat="30.30100" lon="120.08100">
        <ele>12.5</ele>
        <time>2026-01-01T08:00:00Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.60</crs:speedMps>
          <crs:cadenceSpm>168</crs:cadenceSpm>
          <crs:strideLengthM>0.9285714286</crs:strideLengthM>
          <crs:instantPaceSecPerKm>384.6153846154</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>0</crs:cumulativeDistanceM>
          <crs:segmentIndex>0</crs:segmentIndex>
        </extensions>
      </trkpt>
      <trkpt lat="30.30180" lon="120.08100">
        <ele>13.1</ele>
        <time>2026-01-01T08:00:30Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.60</crs:speedMps>
          <crs:cadenceSpm>168</crs:cadenceSpm>
          <crs:strideLengthM>0.9285714286</crs:strideLengthM>
          <crs:instantPaceSecPerKm>384.6153846154</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>78.0</crs:cumulativeDistanceM>
          <crs:segmentIndex>0</crs:segmentIndex>
        </extensions>
      </trkpt>
      <trkpt lat="30.30260" lon="120.08190">
        <ele>14.6</ele>
        <time>2026-01-01T08:01:00Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.65</crs:speedMps>
          <crs:cadenceSpm>170</crs:cadenceSpm>
          <crs:strideLengthM>0.9352941176</crs:strideLengthM>
          <crs:instantPaceSecPerKm>377.3584905660</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>157.5</crs:cumulativeDistanceM>
          <crs:segmentIndex>0</crs:segmentIndex>
        </extensions>
      </trkpt>
      <trkpt lat="30.30260" lon="120.08320">
        <ele>15.0</ele>
        <time>2026-01-01T08:01:30Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.70</crs:speedMps>
          <crs:cadenceSpm>172</crs:cadenceSpm>
          <crs:strideLengthM>0.9418604651</crs:strideLengthM>
          <crs:instantPaceSecPerKm>370.3703703704</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>238.5</crs:cumulativeDistanceM>
          <crs:segmentIndex>0</crs:segmentIndex>
        </extensions>
      </trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="30.30260" lon="120.08320">
        <ele>15.0</ele>
        <time>2026-01-01T08:02:00Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>0</crs:speedMps>
          <crs:cadenceSpm>0</crs:cadenceSpm>
          <crs:strideLengthM>0</crs:strideLengthM>
          <crs:instantPaceSecPerKm>0</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>238.5</crs:cumulativeDistanceM>
          <crs:segmentIndex>1</crs:segmentIndex>
          <crs:qualityFlags>gap</crs:qualityFlags>
        </extensions>
      </trkpt>
      <trkpt lat="30.30180" lon="120.08410">
        <ele>14.2</ele>
        <time>2026-01-01T08:02:30Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.55</crs:speedMps>
          <crs:cadenceSpm>166</crs:cadenceSpm>
          <crs:strideLengthM>0.9216867470</crs:strideLengthM>
          <crs:instantPaceSecPerKm>392.1568627451</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>330.0</crs:cumulativeDistanceM>
          <crs:segmentIndex>1</crs:segmentIndex>
        </extensions>
      </trkpt>
      <trkpt lat="30.30100" lon="120.08320">
        <ele>13.0</ele>
        <time>2026-01-01T08:03:00Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.50</crs:speedMps>
          <crs:cadenceSpm>164</crs:cadenceSpm>
          <crs:strideLengthM>0.9146341463</crs:strideLengthM>
          <crs:instantPaceSecPerKm>400.0</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>417.0</crs:cumulativeDistanceM>
          <crs:segmentIndex>1</crs:segmentIndex>
        </extensions>
      </trkpt>
      <trkpt lat="30.30100" lon="120.08100">
        <ele>12.5</ele>
        <time>2026-01-01T08:03:30Z</time>
        <extensions>
          <crs:dataOrigin>simulated</crs:dataOrigin>
          <crs:speedMps>2.45</crs:speedMps>
          <crs:cadenceSpm>162</crs:cadenceSpm>
          <crs:strideLengthM>0.9074074074</crs:strideLengthM>
          <crs:instantPaceSecPerKm>408.1632653061</crs:instantPaceSecPerKm>
          <crs:cumulativeDistanceM>500.0</crs:cumulativeDistanceM>
          <crs:segmentIndex>1</crs:segmentIndex>
        </extensions>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
"""# + "\n"

    /// F67：全部 trkpt 缺 <ele>，部分缺 <time>，含一处时间戳乱序点；合法 XML 但字段不全，无来源标记。
    /// 与 `CampusRunSimulatorTests/Fixtures/sample_missing_ele.gpx` 内容逐字一致。
    private static let inlineMissingEleGPX: String = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  F67 · GPX 1.1 容错样例：全部 <trkpt> 缺 <ele>，部分 <trkpt> 缺 <time>，
  另含一处时间戳乱序点。合法 XML，但字段不全。
  验收预期（AC-F3）：不臆造海拔与时间戳 —— 缺 ele 用 0 哨兵并标 lowAccuracy，
  缺 time / 乱序 time 的点直接跳过且不插值；来源无法判定时隔离为「未分类」，绝不默认 real。
  坐标取杭州某高校周边约 200 m 尺度，仅作格式基准。
-->
<gpx version="1.1" creator="CampusRunSimulator"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:crs="http://www.campusrun.simulator/gpx/ext/1.0">
  <metadata>
    <name>字段缺失容错样例（无来源标记）</name>
    <desc>用于验证缺 ele / 缺 time / 时间戳乱序时分级提示且不臆造数据</desc>
  </metadata>
  <trk>
    <name>missing_fields_case</name>
    <trkseg>
      <trkpt lat="30.30120" lon="120.08140">
        <time>2026-01-01T09:00:00Z</time>
      </trkpt>
      <trkpt lat="30.30160" lon="120.08140">
        <time>2026-01-01T09:00:30Z</time>
      </trkpt>
      <trkpt lat="30.30200" lon="120.08190">
        <!-- 故意缺 <time>：该点应被跳过，不臆造时间戳 -->
      </trkpt>
      <trkpt lat="30.30240" lon="120.08240">
        <time>2026-01-01T09:01:00Z</time>
      </trkpt>
      <trkpt lat="30.30280" lon="120.08290">
        <!-- 故意时间戳乱序（早于上一点）：该点应被丢弃，不重排 -->
        <time>2026-01-01T08:59:00Z</time>
      </trkpt>
      <trkpt lat="30.30320" lon="120.08340">
        <time>2026-01-01T09:01:30Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
"""# + "\n"

    /// F68：仅 <wpt>/<rte>/<rtept>，无 <trk>；extensions 内保留非法版本探针 <crs:illegalVersionSample>9.9。
    /// 与 `CampusRunSimulatorTests/Fixtures/sample_only_rte.gpx` 内容逐字一致。
    private static let inlineOnlyRteGPX: String = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  F68 · GPX 1.1 容错样例：仅 <wpt> / <rte> / <rtept>，完全没有 <trk>。
  本文件自身是合法 GPX 1.1（version="1.1"），因此 XMLParser 能真实解析并走到
  「仅含路线点」兼容分支：解析出 routePoints，points 为空，提示「不作为运动轨迹」，
  且因文件内无 SIMULATED / REAL 来源标记而隔离为「未分类」，绝不默认真实记录。

  关于「非法 version 段」：单个 XML 文档只能有一个 <gpx> 根元素与一个 version 属性；
  若把根 version 写成非法值，解析器会在版本校验处直接拒绝，反而测不到「仅 rte」兼容分支。
  因此本文件在 <extensions> 内保留 <crs:illegalVersionSample>9.9</crs:illegalVersionSample>
  作为非法版本探针（合法 XML 自定义扩展字段），由 CodecTests.testInvalidVersionRejected()
  读取该值并内联构造 version="9.9" 的 GPX 数据，断言抛出 AppError.gpxInvalidVersion。
  这样三个样例均为真实合法 XML，同时 AC-F3 的「仅 rte」「非法版本」两类容错都真实覆盖。
-->
<gpx version="1.1" creator="CampusRunSimulator"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:crs="http://www.campusrun.simulator/gpx/ext/1.0">
  <metadata>
    <name>仅有路线点样例（无来源标记）</name>
    <desc>用于验证无 trk 时兼容为路线点、不臆造轨迹；非法版本探针见 extensions</desc>
  </metadata>
  <extensions>
    <crs:illegalVersionSample>9.9</crs:illegalVersionSample>
    <crs:illegalVersionHint>非法 version 由 CodecTests 内联构造验证拒绝，本文件保持合法 GPX 1.1</crs:illegalVersionHint>
  </extensions>
  <wpt lat="30.30100" lon="120.08100">
    <ele>12.5</ele>
    <name>校园跑起点（示例）</name>
  </wpt>
  <wpt lat="30.30260" lon="120.08320">
    <ele>15.0</ele>
    <name>折返点（示例）</name>
  </wpt>
  <rte>
    <name>示例往返路线（不是运动轨迹）</name>
    <rtept lat="30.30100" lon="120.08100">
      <ele>12.5</ele>
    </rtept>
    <rtept lat="30.30180" lon="120.08190">
      <ele>13.4</ele>
    </rtept>
    <rtept lat="30.30260" lon="120.08320">
      <ele>15.0</ele>
    </rtept>
    <rtept lat="30.30180" lon="120.08410">
      <ele>14.2</ele>
    </rtept>
    <rtept lat="30.30100" lon="120.08100">
      <ele>12.5</ele>
    </rtept>
  </rte>
</gpx>
"""# + "\n"

    /// 按 fixture 名返回内联 GPX 文本；3 个已知样例全部命中，未知名返回 nil。
    private static func inlineFixture(named name: String) -> String? {
        switch name {
        case "SIMULATED_sample_loop": return Self.inlineLoopGPX
        case "sample_missing_ele": return Self.inlineMissingEleGPX
        case "sample_only_rte": return Self.inlineOnlyRteGPX
        default: return nil
        }
    }

    /// 未知 fixture 名的明确错误（loadFixture 三级兜底都未命中且无内联常量时抛出）。
    private enum FixtureLookupError: Error, LocalizedError {
        case unknownFixture(String)

        var errorDescription: String? {
            switch self {
            case .unknownFixture(let name):
                return "未知的 GPX 样例 \(name)：既不在 test bundle，也无对应内联常量"
            }
        }
    }

    // MARK: - [T09] GPX / CSV / JSON 编解码往返

    func testGPXRoundTrip() throws {
        // [T09] GPX 1.1 导入导出往返：几何 / 时间 / 逐点派生量逐字段一致，多 trkseg 保留。
        let origin = DataOrigin.simulated
        let session = makeSession(origin: origin)
        let points = makePoints(origin: origin, sessionID: session.id)
        let codec = GPXCodec()

        let data = try codec.encode(session: session, points: points)
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(xml.contains("version=\"1.1\""), "必须输出 GPX 1.1 版本")
        XCTAssertTrue(xml.contains("<metadata>") && xml.contains("<extensions>"))
        XCTAssertEqual(xml.components(separatedBy: "<trkseg>").count - 1, 2,
                       "两个 segment 必须映射为两个 <trkseg>")

        let result = try codec.decode(data)
        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertEqual(result.points.count, points.count)
        XCTAssertEqual(result.dataOrigin, origin)
        XCTAssertFalse(result.isUnclassified, "带文件级 SIMULATED 标记的文件不得被隔离为未分类")
        XCTAssertTrue(result.missingFields.isEmpty, "编码产物不应缺 ele / time")
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("2 个 <trkseg>") }))

        for index in 0..<points.count {
            let source = points[index]
            let restored = result.points[index]
            XCTAssertEqual(restored.dataOrigin, origin)
            XCTAssertEqual(restored.latitude, source.latitude, accuracy: 1e-9)
            XCTAssertEqual(restored.longitude, source.longitude, accuracy: 1e-9)
            XCTAssertEqual(restored.altitudeM, source.altitudeM, accuracy: 1e-6)
            XCTAssertEqual(restored.timestamp.timeIntervalSinceReferenceDate,
                           source.timestamp.timeIntervalSinceReferenceDate, accuracy: 1e-6)
            XCTAssertEqual(restored.speedMps, source.speedMps, accuracy: 1e-9)
            XCTAssertEqual(restored.cadenceSpm, source.cadenceSpm, accuracy: 1e-9)
            XCTAssertEqual(restored.strideLengthM, source.strideLengthM, accuracy: 1e-9)
            XCTAssertEqual(restored.instantPaceSecPerKm, source.instantPaceSecPerKm, accuracy: 1e-6)
            XCTAssertEqual(restored.cumulativeDistanceM, source.cumulativeDistanceM, accuracy: 1e-6)
            XCTAssertEqual(restored.segmentIndex, source.segmentIndex)
        }

        // 跨段不连线：段 1 首点累计距离与段 0 末点相同，不得虚增。
        let segmentBoundary = result.points.firstIndex { $0.segmentIndex == 1 }
        let boundary = try XCTUnwrap(segmentBoundary)
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertEqual(result.points[boundary].cumulativeDistanceM,
                       result.points[boundary - 1].cumulativeDistanceM, accuracy: 1e-6,
                       "跨 segment 不得连线计入距离")
        XCTAssertEqual(Set(result.points.map(\.segmentIndex)), Set([0, 1]))
    }

    func testJSONRoundTrip() throws {
        // [T09] JSON 双向往返：会话全部字段与采样点全部字段由 JSON 通道完整恢复。
        let origin = DataOrigin.simulated
        let session = makeSession(origin: origin, note: "JSON 往返记录")
        let points = makePoints(origin: origin, sessionID: session.id)
        let codec = TabularCodec()

        let data = try codec.encodeJSON(session: session, points: points)
        let restoredSession = try codec.decodeTrackJSON(data)
        let restoredPoints = try codec.decodeTrackPointsJSON(data)

        XCTAssertEqual(restoredSession.id, session.id)
        XCTAssertEqual(restoredSession.dataOrigin, origin)
        XCTAssertEqual(restoredSession.note, session.note)
        XCTAssertEqual(restoredSession.totalDistanceMeters, session.totalDistanceMeters, accuracy: 1e-9)
        XCTAssertEqual(restoredSession.startTime.timeIntervalSinceReferenceDate,
                       session.startTime.timeIntervalSinceReferenceDate, accuracy: 1e-6)
        XCTAssertEqual(restoredSession.originChain, session.originChain)
        XCTAssertEqual(restoredPoints.count, points.count)
        for index in 0..<points.count {
            XCTAssertEqual(restoredPoints[index].id, points[index].id)
            XCTAssertEqual(restoredPoints[index].sessionId, session.id)
            XCTAssertEqual(restoredPoints[index].dataOrigin, origin)
            XCTAssertEqual(restoredPoints[index].latitude, points[index].latitude, accuracy: 1e-9)
            XCTAssertEqual(restoredPoints[index].cumulativeDistanceM,
                           points[index].cumulativeDistanceM, accuracy: 1e-9)
            XCTAssertEqual(restoredPoints[index].segmentIndex, points[index].segmentIndex)
            XCTAssertEqual(restoredPoints[index].qualityFlags, points[index].qualityFlags)
        }
    }

    func testCSVExportColumnsAndMarkers() throws {
        // [T09] CSV 单向导出：首行标记 + 表头 + 逐行字段，文本层逐列比对（不做假「CSV 导入」）。
        let origin = DataOrigin.real
        let session = makeSession(origin: origin)
        let points = makePoints(origin: origin, sessionID: session.id)
        let data = try TabularCodec().encodeCSV(session: session, points: points)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        XCTAssertEqual(lines.count, points.count + 2, "首行注释 + 表头 + 6 行数据")
        let firstLine = lines[0]
        XCTAssertTrue(firstLine.hasPrefix(OriginMarkers.csvFirstLinePrefix))
        XCTAssertTrue(firstLine.contains(OriginMarkers.realFileContentMarker))
        XCTAssertTrue(firstLine.contains(OriginMarkers.metadataKeyDataOrigin))
        XCTAssertTrue(firstLine.contains(AppConstants.disclaimer))
        XCTAssertTrue(lines[1].contains("dataOrigin"), "表头必须含 dataOrigin 列")

        for (offset, line) in lines.dropFirst(2).enumerated() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(columns.count, 23, "每行 23 列，与 TabularCodec.csvHeader 一致")
            let point = points[offset]
            XCTAssertEqual(columns[2], origin.rawValue, "每行 dataOrigin 列必须与会话同源")
            XCTAssertEqual(columns[0], point.id)
            XCTAssertEqual(columns[1], session.id)
            XCTAssertEqual(Double(columns[5]) ?? -1, point.latitude, accuracy: 1e-9)
            XCTAssertEqual(Double(columns[6]) ?? -1, point.longitude, accuracy: 1e-9)
            XCTAssertEqual(Double(columns[18]) ?? -1, point.cumulativeDistanceM, accuracy: 1e-9)
            XCTAssertEqual(Int(columns[21]) ?? -1, point.segmentIndex)
        }
    }

    // MARK: - [T09] 三重标记（AC-C2）

    func testAllThreeMarkersPresent() async throws {
        // [T09] ① 文件名 ② 文件内 ③ UI 徽标，simulated / real × gpx / csv / json 共 6 组闭环。
        let manager = ExportManager(stores: nil)
        let marker = DataMarker()
        for origin in [DataOrigin.simulated, DataOrigin.real] {
            for format in ExportFormat.allCases {
                let session = makeSession(origin: origin)
                let points = makePoints(origin: origin, sessionID: session.id)
                let file = try await manager.export(session: session, points: points, format: format)

                // ① 文件名前缀
                XCTAssertTrue(OriginMarkers.hasFileNamePrefix(file.fileName, for: origin),
                              "\(origin.rawValue)/\(format.rawValue) 文件名缺少来源前缀")
                XCTAssertTrue(file.fileName.hasSuffix(".\(format.rawValue)"))
                XCTAssertNoThrow(try marker.verifyFileName(file.fileName, origin: origin))
                XCTAssertEqual(file.dataOrigin, origin)
                XCTAssertEqual(file.format, format)

                // ③ UI 徽标元数据 + 三通道齐全
                XCTAssertTrue(file.hasAllThreeMarkers)
                XCTAssertEqual(Set(file.markersIncluded), Set(MarkerKind.allCases))
                let metadata = marker.metadataBlock(origin)
                XCTAssertTrue(metadata.hasCompleteUIBadge)
                XCTAssertFalse(metadata.badgeText.isEmpty)
                XCTAssertFalse(metadata.badgeSymbol.isEmpty)
                XCTAssertFalse(metadata.badgeAccessibilityLabel.isEmpty)
                XCTAssertEqual(metadata.isHypothetical, origin == .simulated)

                // ② 文件内标记 + 免责声明
                XCTAssertTrue(OriginMarkers.containsFileContentMarker(file.data, for: origin))
                XCTAssertNoThrow(try marker.verifyMarkers(file.data, origin: origin, format: format))
                let content = try XCTUnwrap(String(data: file.data, encoding: .utf8))
                XCTAssertTrue(content.contains(metadata.fileContentMarker))
                XCTAssertTrue(content.contains(AppConstants.disclaimer))
                XCTAssertTrue(content.contains(AppConstants.generator))

                // 本地导出出口真实可写（无网络栈），并清理临时文件。
                let url = try file.writeToTemporaryDirectory()
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func testFileNameAndMarkerVerificationRejectsWrongOrigin() throws {
        // [T09] ①/② 校验必须拒绝错配来源，绝不默认放行。
        let marker = DataMarker()
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let simulatedName = marker.fileName(.simulated, format: .csv, date: date)
        let realName = marker.fileName(.real, format: .gpx, date: date)
        XCTAssertTrue(simulatedName.hasPrefix(OriginMarkers.simulatedPrefix))
        XCTAssertTrue(realName.hasPrefix(OriginMarkers.realPrefix))
        XCTAssertThrowsError(try marker.verifyFileName(realName, origin: .simulated))
        XCTAssertThrowsError(try marker.verifyFileName(simulatedName, origin: .real))

        let plain = Data("latitude,longitude\n30.3,120.08\n".utf8)
        XCTAssertThrowsError(try marker.verifyMarkers(plain, origin: .simulated, format: .csv))
        XCTAssertFalse(OriginMarkers.containsFileContentMarker(plain, for: .simulated))
    }

    func testMixedOriginExportRejected() async throws {
        // [T09][AC-C7] 混合来源一律拒绝产出文件（三种编码 + 导出管理器四处守卫）。
        let session = makeSession(origin: .simulated)
        var points = makePoints(origin: .simulated, sessionID: session.id)
        let intruder = TrackPoint(
            id: OriginID.makeID(.real, suffix: "intruder"),
            sessionId: session.id,
            dataOrigin: .real,
            timestamp: baseTime.addingTimeInterval(70),
            elapsedSeconds: 70,
            latitude: 30.3020,
            longitude: 120.0820,
            altitudeM: 13
        )
        points.append(intruder)

        XCTAssertThrowsError(try GPXCodec().encode(session: session, points: points))
        XCTAssertThrowsError(try TabularCodec().encodeCSV(session: session, points: points))
        XCTAssertThrowsError(try TabularCodec().encodeJSON(session: session, points: points))

        do {
            _ = try await ExportManager(stores: nil).export(
                session: session, points: points, format: .gpx
            )
            XCTFail("混合来源必须被 ExportManager 拒绝")
        } catch let error as AppError {
            guard case .mixedOriginExportForbidden = error else {
                return XCTFail("错误类型应为 mixedOriginExportForbidden，实际 \(error)")
            }
            XCTAssertEqual(error.resultCode, "E_MIXED_ORIGIN_FORBIDDEN")
        } catch {
            XCTFail("应抛出 AppError，实际 \(error)")
        }
    }

    // MARK: - [T09] GPX 四类容错（AC-F3，读取 F66–F68）

    func testSampleLoopMarkersAndMultiSegment() throws {
        // [T09] F66 正常闭合环：三重标记齐全、2 个 trkseg、跨段不连线、无缺失字段。
        let data = try loadFixture("SIMULATED_sample_loop")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("version=\"1.1\""))
        XCTAssertTrue(text.contains(OriginMarkers.simulatedFileContentMarker))
        XCTAssertTrue(text.contains("dataOrigin"))
        XCTAssertTrue(text.contains("badgeText") && text.contains("badgeAccessibilityLabel"))

        let result = try GPXCodec().decode(data)
        XCTAssertEqual(result.dataOrigin, .simulated)
        XCTAssertFalse(result.isUnclassified, "F66 带文件级 SIMULATED 标记，应判定为测试数据")
        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertEqual(result.points.count, 8)
        XCTAssertTrue(result.missingFields.isEmpty)
        XCTAssertTrue(result.points.allSatisfy { $0.dataOrigin == .simulated })
        XCTAssertEqual(Set(result.points.map(\.segmentIndex)), Set([0, 1]))
        XCTAssertTrue(result.points.allSatisfy { $0.geoPoint.isValid })
        XCTAssertTrue(result.points.allSatisfy { $0.latitude != 0 && $0.longitude != 0 },
                      "坐标必须是真实校园尺度，不得用 0,0 占位")

        let quality = DataQualityReport.build(sessionId: "f66", points: result.points)
        XCTAssertEqual(quality.gapSegmentCount, 2)
        XCTAssertEqual(quality.interpolatedPointCount, 0, "本项目不插值，恒为 0")
        XCTAssertEqual(quality.totalPointCount, result.points.count)
    }

    func testMissingEleDoesNotFabricate() throws {
        // [T09][AC-F3] F67 缺 <ele> / 部分缺 <time> / 时间戳乱序：分级提示且不臆造。
        let result = try GPXCodec().decode(try loadFixture("sample_missing_ele"))
        XCTAssertTrue(result.missingFields.contains(.elevation))
        XCTAssertTrue(result.missingFields.contains(.time))
        XCTAssertTrue(result.isUnclassified, "无来源标记必须隔离为未分类，绝不默认真实记录")
        XCTAssertEqual(result.dataOrigin, .simulated, "未分类的安全占位来源为测试数据")
        XCTAssertEqual(result.segmentCount, 1)

        // 6 个原始 trkpt 中：1 个缺 time、1 个乱序被丢弃 → 4 个有效点。
        XCTAssertEqual(result.points.count, 4,
                       "缺 time 与乱序点必须跳过，不得插值或重排")
        for point in result.points {
            XCTAssertEqual(point.altitudeM, 0, accuracy: 1e-9,
                           "缺 ele 用 0 哨兵，不得臆造海拔")
            XCTAssertTrue(point.qualityFlags.contains(.lowAccuracy))
        }
        for index in 1..<result.points.count {
            XCTAssertGreaterThan(result.points[index].timestamp.timeIntervalSince(
                result.points[index - 1].timestamp), 0, "时间戳必须严格单调递增")
        }
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("未臆造") }))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("乱序") }))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("绝不默认真实记录") }))
    }

    func testOnlyRteCompatible() throws {
        // [T09][AC-F3] F68 仅 <rte>/<wpt>：兼容为路线点，不作为运动轨迹。
        let result = try GPXCodec().decode(try loadFixture("sample_only_rte"))
        XCTAssertTrue(result.points.isEmpty, "无 <trk> 时不得臆造轨迹点")
        XCTAssertEqual(result.segmentCount, 0)
        XCTAssertEqual(result.routePoints.count, 7, "2 个 wpt + 5 个 rtept")
        XCTAssertTrue(result.isUnclassified)
        XCTAssertTrue(result.routePoints.allSatisfy { $0.isValid && $0.latitude != 0 })
        let rteNotice = try XCTUnwrap(AppError.gpxOnlyRte.errorDescription)
        XCTAssertTrue(result.warnings.contains(rteNotice))
    }

    func testInvalidVersionRejected() throws {
        // [T09][AC-F3] 非法版本：从 F68 的探针字段读取 9.9，内联构造 version="9.9" 的 GPX，
        // 断言 XMLParser 走真实版本校验并抛 AppError.gpxInvalidVersion。
        let fixtureText = try XCTUnwrap(
            String(data: loadFixture("sample_only_rte"), encoding: .utf8)
        )
        let openTag = "<crs:illegalVersionSample>"
        let closeTag = "</crs:illegalVersionSample>"
        let start = try XCTUnwrap(fixtureText.range(of: openTag)?.upperBound)
        let end = try XCTUnwrap(fixtureText.range(of: closeTag, range: start..<fixtureText.endIndex)?.lowerBound)
        let illegalVersion = String(fixtureText[start..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(illegalVersion, "9.9")

        let invalidGPX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="\(illegalVersion)" creator="CampusRunSimulator"
             xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>非法版本样例</name><trkseg>
            <trkpt lat="30.3010" lon="120.0810"><ele>12.5</ele>
              <time>2026-01-01T08:00:00Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let data = try XCTUnwrap(invalidGPX.data(using: .utf8))
        XCTAssertThrowsError(try GPXCodec().decode(data)) { error in
            guard case AppError.gpxInvalidVersion(let version) = error else {
                return XCTFail("应抛 gpxInvalidVersion，实际 \(error)")
            }
            XCTAssertEqual(version, "9.9")
        }

        // 缺 version 同样拒绝（明确提示，不宽容解析）。
        let noVersion = Data("<gpx xmlns=\"http://www.topografix.com/GPX/1/1\"></gpx>".utf8)
        XCTAssertThrowsError(try GPXCodec().decode(noVersion)) { error in
            guard case AppError.gpxMissingField(let field) = error else {
                return XCTFail("应抛 gpxMissingField，实际 \(error)")
            }
            XCTAssertEqual(field, .version)
        }
    }

    func testUnclassifiedJSONIsRejected() throws {
        // [T09][AC-C7] JSON 缺 / 错配 dataOrigin 一律隔离为「未分类」，绝不默认真实记录。
        let session = makeSession(origin: .simulated)
        let points = makePoints(origin: .simulated, sessionID: session.id)
        let encoded = try TabularCodec().encodeJSON(session: session, points: points)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var tampered = object
        tampered.removeValue(forKey: OriginMarkers.metadataKeyDataOrigin)
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)

        let codec = TabularCodec()
        XCTAssertThrowsError(try codec.decodeTrackJSON(tamperedData)) { error in
            guard case AppError.unclassifiedDataIsolated = error else {
                return XCTFail("缺 dataOrigin 应抛 unclassifiedDataIsolated，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try codec.decodeTrackPointsJSON(tamperedData))

        var mismatched = object
        mismatched[OriginMarkers.metadataKeyDataOrigin] = DataOrigin.real.rawValue
        let mismatchedData = try JSONSerialization.data(withJSONObject: mismatched)
        XCTAssertThrowsError(try codec.decodeTrackJSON(mismatchedData)) { error in
            guard case AppError.mixedOriginExportForbidden = error else {
                return XCTFail("顶层来源与会话不一致应抛 mixedOriginExportForbidden，实际 \(error)")
            }
        }
    }
}
