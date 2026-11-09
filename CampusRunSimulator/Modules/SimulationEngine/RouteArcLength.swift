import Foundation

// MARK: - Haversine 与统一距离口径

/// 球面几何工具（F27 / §A.3.1）。
/// `meters` 用 Haversine（R = 6 371 000 m）生成坐标与离线自检；
/// `distance` 统一走 `CLLocation.distance(from:)` 口径（§7.1 / §7.12），
/// 作为弧长参数化与累计距离的**唯一距离口径**，保证 I3 与真实记录一致。
public enum Haversine {
    /// Haversine 大圆距离（m），R = 6 371 000 m。
    public static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        Units.haversineMeters(a, b)
    }

    /// 初始方位角（度，正北顺时针 0–360）。
    public static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        Units.bearingDegrees(from: a, to: b)
    }

    /// 统一距离口径：`CLLocation.distance(from:)`（经 BATCH_1 冻结的 `Units.distanceMeters`）。
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        Units.distanceMeters(a, b)
    }
}

// MARK: - 路线弧长参数化

/// 把用户自建路线按累计弧长参数化（F27 / §B.9.3 / I2 / I3）。
/// 累计弧长数组由统一距离口径累加，`point(atArcLength:)` 在段内按弧长线性插值，
/// 因此 `s(t) = ∫v dt` 唯一决定 GPS 坐标，且相邻点距离之和与累计距离一致。
public struct RouteArcLength: Sendable {
    /// 按 `orderIndex` 排序的原始路线点。
    private let points: [RoutePoint]
    /// `cumulative[i]` = 从起点到第 i 个点的累计弧长（m）。
    private let cumulative: [Double]
    private let routeType: RouteType
    private let closedLoop: Bool
    private let closureToleranceMeters: Double

    public init(route: Route) {
        let ordered = route.orderedPoints()
        let tolerance = 5.0
        self.points = ordered
        self.routeType = route.routeType
        self.closureToleranceMeters = tolerance
        var accumulated = [Double](repeating: 0, count: ordered.count)
        if ordered.count > 1 {
            var index = 1
            while index < ordered.count {
                let segment = Haversine.distance(ordered[index - 1].geoPoint, ordered[index].geoPoint)
                accumulated[index] = accumulated[index - 1] + max(0, segment)
                index += 1
            }
        }
        self.cumulative = accumulated
        if let first = ordered.first, let last = ordered.last, ordered.count > 2 {
            self.closedLoop = route.routeType == .loop
                && Haversine.distance(first.geoPoint, last.geoPoint) <= tolerance
        } else {
            self.closedLoop = false
        }
    }

    /// 路线单程总弧长（m）。
    public func totalLength() -> Double {
        cumulative.last ?? 0
    }

    /// 是否为闭合环形（首尾近似重合，容差 5 m）。
    public func isClosedLoop() -> Bool {
        closedLoop
    }

    /// 按弧长取路线上的插值点（§3.2 冻结签名）。
    /// 闭合环形取模重复铺圈；折返路线按三角波往返；自由路线钳制到终点，绝不外推臆造坐标。
    public func point(atArcLength s: Double) -> RoutePoint {
        guard let first = points.first else {
            // 退化路线：返回确定性原点，不臆造真实地理位置；F31 前置校验会拒绝此类输入。
            return RoutePoint(orderIndex: 0, latitude: 0, longitude: 0, arcLengthFromStartM: 0)
        }
        guard points.count > 1, totalLength() > 0 else {
            return RoutePoint(
                id: first.id,
                orderIndex: first.orderIndex,
                latitude: first.latitude,
                longitude: first.longitude,
                altitudeM: first.altitudeM,
                arcLengthFromStartM: 0
            )
        }

        let target = wrappedArc(s)
        let index = segmentIndex(for: target)
        let a = points[index]
        let b = points[index + 1]
        let segmentLength = cumulative[index + 1] - cumulative[index]
        let ratio = segmentLength > 0
            ? CurveMath.clamp((target - cumulative[index]) / segmentLength, lower: 0, upper: 1)
            : 0
        let latitude = a.latitude + (b.latitude - a.latitude) * ratio
        let longitude = a.longitude + (b.longitude - a.longitude) * ratio
        // 海拔仅在两端都有实测/自定义值时插值；缺一侧即返回 nil，绝不臆造。
        let altitude: Double?
        if let startAltitude = a.altitudeM, let endAltitude = b.altitudeM {
            altitude = startAltitude + (endAltitude - startAltitude) * ratio
        } else {
            altitude = nil
        }
        return RoutePoint(
            id: a.id,
            orderIndex: a.orderIndex,
            latitude: latitude,
            longitude: longitude,
            altitudeM: altitude,
            arcLengthFromStartM: target
        )
    }

    /// 按弧长取所在路段方位角（度，正北顺时针 0–360）。
    public func course(atArcLength s: Double) -> Double {
        guard points.count > 1, totalLength() > 0 else { return 0 }
        let target = wrappedArc(s)
        let index = segmentIndex(for: target)
        return Haversine.bearing(points[index].geoPoint, points[index + 1].geoPoint)
    }

    /// 由弧长反查所在路段索引（供诊断与测试）。
    public func segmentIndex(forArcLength s: Double) -> Int {
        segmentIndex(for: wrappedArc(s))
    }

    // MARK: 私有实现

    /// 把任意累计弧长映射回路线单程 `[0, totalLength]` 区间。
    private func wrappedArc(_ s: Double) -> Double {
        let total = totalLength()
        guard total > 0 else { return 0 }
        let value = max(0, s)
        if routeType == .loop && closedLoop {
            return value.truncatingRemainder(dividingBy: total)
        }
        if routeType == .outAndBack {
            let period = total * 2
            let phase = value.truncatingRemainder(dividingBy: period)
            return phase <= total ? phase : period - phase
        }
        return min(value, total)
    }

    /// 二分查找目标弧长所在段，结果钳制到 `[0, count-2]`。
    private func segmentIndex(for target: Double) -> Int {
        let lastIndex = points.count - 2
        guard lastIndex >= 0 else { return 0 }
        var lower = 0
        var upper = lastIndex
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if cumulative[middle] <= target {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return min(max(0, lower), lastIndex)
    }
}
