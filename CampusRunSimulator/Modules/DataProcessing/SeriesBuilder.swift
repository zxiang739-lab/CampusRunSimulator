import Foundation

// MARK: - 图表轴 / 降采样档位 / 指标种类

/// 曲线横轴：时间（s）或累计距离（m）（F36 / §3.2）。
public enum ChartAxis: String, Codable, Sendable, CaseIterable {
    case time
    case distance

    public var localizedDescription: String {
        switch self {
        case .time: return "时间轴（s）"
        case .distance: return "距离轴（m）"
        }
    }

    /// 轴标签（图例 / 无障碍摘要使用）。
    public var axisLabel: String {
        switch self {
        case .time: return "已用时间"
        case .distance: return "累计距离"
        }
    }
}

/// 3 档降采样（F36 / §3.2）。桶大小即每桶合并的原始采样点数。
public enum DownsamplingTier: String, Codable, Sendable, CaseIterable {
    case full
    case medium
    case coarse

    /// 每桶合并的采样点数。
    public var bucketSize: Int {
        switch self {
        case .full: return 1
        case .medium: return 4
        case .coarse: return 16
        }
    }

    public var localizedDescription: String {
        switch self {
        case .full: return "全量"
        case .medium: return "中等（每 4 点）"
        case .coarse: return "粗粒度（每 16 点）"
        }
    }
}

/// 4 类曲线指标（F36 / §B.9.1 / F50）。
public enum MetricKind: String, Codable, Sendable, CaseIterable {
    case pace
    case cadence
    case stride
    case altitude

    public var localizedDescription: String {
        switch self {
        case .pace: return "配速"
        case .cadence: return "步频"
        case .stride: return "步幅"
        case .altitude: return "海拔"
        }
    }

    public var unitText: String {
        switch self {
        case .pace: return "s/km"
        case .cadence: return "spm"
        case .stride: return "m/步"
        case .altitude: return "m"
        }
    }
}

// MARK: - 序列点

/// 单个曲线点。`sourceIndex` 为原始 `TrackPoint` 索引，供 4 类曲线联动游标同步；
/// `breakBefore = true` 表示跨 segment / 信号中断 / 暂停段，UI **不得连线**（§A.3.6 / F50）。
public struct SeriesPoint: Codable, Sendable, Hashable {
    public let x: Double
    public let y: Double
    /// 原始采样点索引（联动游标的唯一锚点）。
    public let sourceIndex: Int
    public let segmentIndex: Int
    /// 是否在此点之前断开折线（跨段不连线）。
    public let breakBefore: Bool

    public init(
        x: Double,
        y: Double,
        sourceIndex: Int,
        segmentIndex: Int,
        breakBefore: Bool = false
    ) {
        self.x = x
        self.y = y
        self.sourceIndex = sourceIndex
        self.segmentIndex = segmentIndex
        self.breakBefore = breakBefore
    }
}

// MARK: - 指标序列

/// 一类指标在给定轴 / 降采样档位下的序列（F36 / §3.2）。
/// `origin` 强制标注来源：SIMULATED / REAL **不得无标记混画**（§B.11.1）。
public struct MetricSeries: Identifiable, Codable, Sendable {
    public let id: String
    public let kind: MetricKind
    public let origin: DataOrigin
    public let axis: ChartAxis
    public let tier: DownsamplingTier
    public let points: [SeriesPoint]

    public init(
        id: String,
        kind: MetricKind,
        origin: DataOrigin,
        axis: ChartAxis,
        tier: DownsamplingTier,
        points: [SeriesPoint]
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.axis = axis
        self.tier = tier
        self.points = points
    }

    /// 图例文本：来源文字 + 指标名 + 单位（文字通道，不依赖颜色）。
    public var legendText: String {
        "\(origin.displayText) · \(kind.localizedDescription)（\(kind.unitText)）"
    }

    /// 数值摘要（无障碍 / 图表摘要文本）：最小 / 最大 / 均值。
    public var numericSummary: String {
        guard !points.isEmpty else { return "无数据" }
        let values = points.map(\.y).filter { $0.isFinite }
        guard !values.isEmpty else { return "无有效数值" }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 0
        let average = values.reduce(0, +) / Double(values.count)
        return String(
            format: "%@：最小 %.2f / 最大 %.2f / 平均 %.2f %@",
            kind.localizedDescription, minimum, maximum, average, kind.unitText
        )
    }

    /// 被断开的段数（跨段不连线计数，供 F57 展示）。
    public var breakCount: Int {
        points.filter { $0.breakBefore }.count
    }
}

// MARK: - 序列构建器

/// `TrackPoint[]` → 4 类曲线序列 + 时间/距离轴 + 3 档降采样 + 联动游标（F36 / §3.2）。
public struct SeriesBuilder: Sendable {

    public init() {}

    /// 冻结签名：构建 4 类曲线。
    /// 单一来源守卫：仅保留与首点同源的采样点，绝不允许 SIMULATED / REAL 无标记混画。
    public func build(
        _ points: [TrackPoint],
        axis: ChartAxis,
        downsampling: DownsamplingTier
    ) -> [MetricSeries] {
        guard let first = points.first else { return [] }
        let origin = first.dataOrigin
        let filtered = points.filter { $0.dataOrigin == origin }
        guard !filtered.isEmpty else { return [] }

        let xValues = filtered.map { xValue($0, axis: axis) }
        return MetricKind.allCases.map { kind in
            let yValues = filtered.map { yValue($0, kind: kind) }
            let reduced = reduce(
                x: xValues,
                y: yValues,
                points: filtered,
                tier: downsampling
            )
            return MetricSeries(
                id: "\(origin.rawValue)_\(kind.rawValue)_\(axis.rawValue)_\(downsampling.rawValue)",
                kind: kind,
                origin: origin,
                axis: axis,
                tier: downsampling,
                points: reduced
            )
        }
    }

    /// 联动游标：给定任一曲线上的原始 `sourceIndex`，返回本序列内最接近的点的下标。
    /// 4 类曲线共享同一 `sourceIndex`，因此拖动任一曲线可直接同步其余三条。
    public func linkedCursorIndex(
        forSourceIndex sourceIndex: Int,
        in series: MetricSeries
    ) -> Int? {
        guard !series.points.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = Int.max
        for (offset, point) in series.points.enumerated() {
            let distance = abs(point.sourceIndex - sourceIndex)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = offset
            }
        }
        return bestIndex
    }

    /// 由轴坐标 `x` 反查最近的原始 `sourceIndex`（拖动游标 → 同步其余曲线 / 地图 / 数值卡片）。
    public func nearestSourceIndex(x: Double, in series: MetricSeries) -> Int? {
        guard !series.points.isEmpty else { return nil }
        var best = series.points[0].sourceIndex
        var bestDelta = Double.infinity
        for point in series.points where point.x.isFinite {
            let delta = abs(point.x - x)
            if delta < bestDelta {
                bestDelta = delta
                best = point.sourceIndex
            }
        }
        return best
    }

    /// 按指定档位重新构建单一序列（切换降采样档位时复用，避免重算其余曲线）。
    public func rebuild(
        _ series: MetricSeries,
        from points: [TrackPoint],
        downsampling: DownsamplingTier
    ) -> MetricSeries? {
        build(points, axis: series.axis, downsampling: downsampling)
            .first { $0.kind == series.kind }
    }

    // MARK: 私有实现

    private func xValue(_ point: TrackPoint, axis: ChartAxis) -> Double {
        switch axis {
        case .time: return point.elapsedSeconds
        case .distance: return point.cumulativeDistanceM
        }
    }

    private func yValue(_ point: TrackPoint, kind: MetricKind) -> Double {
        switch kind {
        case .pace: return point.instantPaceSecPerKm
        case .cadence: return point.cadenceSpm
        case .stride: return point.strideLengthM
        case .altitude: return point.altitudeM
        }
    }

    /// 全量档：逐点输出，并在跨段 / 中断 / 暂停处标记断线。
    private func rawPoints(
        x: [Double],
        y: [Double],
        points: [TrackPoint]
    ) -> [SeriesPoint] {
        var result: [SeriesPoint] = []
        result.reserveCapacity(x.count)
        var previousSegment: Int?
        var index = 0
        while index < x.count {
            let point = points[index]
            let breakBefore: Bool
            if let previous = previousSegment {
                breakBefore = point.segmentIndex != previous
                    || point.hasGap
                    || point.isPaused
            } else {
                breakBefore = false
            }
            result.append(SeriesPoint(
                x: x[index],
                y: y[index],
                sourceIndex: index,
                segmentIndex: point.segmentIndex,
                breakBefore: breakBefore
            ))
            previousSegment = point.segmentIndex
            index += 1
        }
        return result
    }

    /// 桶内均值降采样：保留首尾点，桶内跨段 / 含中断标记时强制断开连线。
    private func reduce(
        x: [Double],
        y: [Double],
        points: [TrackPoint],
        tier: DownsamplingTier
    ) -> [SeriesPoint] {
        let bucket = tier.bucketSize
        guard bucket > 1, x.count > 2 else {
            return rawPoints(x: x, y: y, points: points)
        }
        var result: [SeriesPoint] = []
        var previousSegment: Int?
        var start = 0
        while start < x.count {
            let end = min(start + bucket, x.count)
            let range = start..<end
            let finiteX = x[range].filter { $0.isFinite }
            let finiteY = y[range].filter { $0.isFinite }
            let meanX = finiteX.isEmpty ? x[start] : finiteX.reduce(0, +) / Double(finiteX.count)
            let meanY = finiteY.isEmpty ? y[start] : finiteY.reduce(0, +) / Double(finiteY.count)
            let firstSegment = points[start].segmentIndex
            var crossesSegment = false
            var hasQualityBreak = false
            for index in range {
                if points[index].segmentIndex != firstSegment { crossesSegment = true }
                if points[index].hasGap || points[index].isPaused { hasQualityBreak = true }
            }
            let breakBefore: Bool
            if let previous = previousSegment {
                breakBefore = previous != firstSegment || crossesSegment || hasQualityBreak
            } else {
                breakBefore = false
            }
            // 最后一桶用末点作为代表索引，保证终点被保留。
            let representative = end == x.count ? end - 1 : start + (end - start) / 2
            result.append(SeriesPoint(
                x: meanX,
                y: meanY,
                sourceIndex: representative,
                segmentIndex: firstSegment,
                breakBefore: breakBefore
            ))
            previousSegment = points[end - 1].segmentIndex
            start = end
        }
        return result
    }
}
