import Foundation
import CoreLocation

/// 单位与量纲统一表（§7.1）。全部换算的唯一实现处。
/// 距离 m / 时间 s(UTC Date) / 速度 m·s⁻¹ / 配速 s·km⁻¹（展示 min·km⁻¹）
/// 步频 spm / 步幅 m·步⁻¹ / 海拔 m / 坡度 % / 经纬度 度 / 精度 m。
public enum Units {
    // MARK: 基础常数
    public static let metersPerKilometer: Double = 1_000
    public static let secondsPerMinute: Double = 60
    public static let secondsPerHour: Double = 3_600
    public static let metersPerSecondToKilometersPerHour: Double = 3.6
    public static let haversineEarthRadiusM: Double = 6_371_000
    public static let degreesToRadians: Double = .pi / 180
    public static let radiansToDegrees: Double = 180 / .pi

    // MARK: Core Motion 单位换算

    /// `CMPedometerData.currentPace` 为 s/m，转为展示用 min/km：s/m × 1000 / 60。
    public static func paceSecPerMeterToMinPerKm(_ paceSecPerMeter: Double) -> Double {
        guard paceSecPerMeter.isFinite, paceSecPerMeter > 0 else { return .infinity }
        return paceSecPerMeter * metersPerKilometer / secondsPerMinute
    }

    /// `CMPedometerData.currentCadence` 为 步/秒，转为 spm：步/秒 × 60。
    public static func cadenceStepsPerSecondToSpm(_ stepsPerSecond: Double) -> Double {
        guard stepsPerSecond.isFinite else { return 0 }
        return stepsPerSecond * secondsPerMinute
    }

    /// 展示用 min/km 转回内部 s/km。
    public static func minPerKmToSecPerKm(_ minPerKm: Double) -> Double {
        guard minPerKm.isFinite else { return .infinity }
        return minPerKm * secondsPerMinute
    }

    /// 内部 s/km 转展示用 min/km。
    public static func secPerKmToMinPerKm(_ secPerKm: Double) -> Double {
        guard secPerKm.isFinite else { return .infinity }
        return secPerKm / secondsPerMinute
    }

    /// m/s → km/h（仅展示层使用，禁止落盘）。
    public static func speedMpsToKmH(_ speedMps: Double) -> Double {
        guard speedMps.isFinite else { return 0 }
        return speedMps * metersPerSecondToKilometersPerHour
    }

    /// km/h → m/s（设置页单位切换后的回算）。
    public static func kmHToSpeedMps(_ kmh: Double) -> Double {
        guard kmh.isFinite else { return 0 }
        return kmh / metersPerSecondToKilometersPerHour
    }

    // MARK: 配速 / 步幅 / 步数

    /// 由 Δt 与 Δd 求瞬时配速（s/km）：1000·Δt / Δd。
    public static func paceSecPerKm(deltaSeconds: TimeInterval, deltaMeters: Double) -> Double {
        guard deltaMeters > 0, deltaSeconds.isFinite, deltaSeconds >= 0 else { return .infinity }
        return metersPerKilometer * deltaSeconds / deltaMeters
    }

    /// 由累计距离与累计时长求平均配速（s/km）。
    public static func averagePaceSecPerKm(totalSeconds: TimeInterval, totalMeters: Double) -> Double {
        paceSecPerKm(deltaSeconds: totalSeconds, deltaMeters: totalMeters)
    }

    /// 步幅反算：`L = 60·v/c`（v 为 m/s，c 为 spm）。派生量，禁止独立随机。
    public static func strideLength(speedMps: Double, cadenceSpm: Double) -> Double {
        guard speedMps.isFinite, cadenceSpm.isFinite, cadenceSpm > 0 else { return 0 }
        return secondsPerMinute * speedMps / cadenceSpm
    }

    /// 单帧步数增量：`Σ(c_i · Δt_i / 60)`。
    public static func stepIncrement(cadenceSpm: Double, deltaSeconds: TimeInterval) -> Double {
        guard cadenceSpm.isFinite, deltaSeconds.isFinite, deltaSeconds >= 0 else { return 0 }
        return cadenceSpm * deltaSeconds / secondsPerMinute
    }

    /// 由累计距离与平均步幅估算累计步数（用于一致性交叉检查）。
    public static func stepsFromDistance(_ meters: Double, averageStrideM: Double) -> Double {
        guard averageStrideM > 0, meters.isFinite else { return 0 }
        return meters / averageStrideM
    }

    // MARK: 海拔 / 坡度 / 爬升死区

    /// 坡度百分比：`100 · Δh / 水平距离`，水平距离必须 > 0，不得用斜距代替。
    public static func slopePercent(deltaAltitudeM: Double, horizontalDistanceM: Double) -> Double {
        guard horizontalDistanceM > 0, deltaAltitudeM.isFinite else { return 0 }
        return 100 * deltaAltitudeM / horizontalDistanceM
    }

    /// 累计爬升 / 下降（§7.1）：`Σ max(0, ±Δh)`，且 `|Δh| > ε` 死区，避免静止抖动虚增。
    /// - Parameters:
    ///   - altitudes: 按时间顺序的绝对海拔序列（m）。
    ///   - deadband: 死区 ε（m），默认取 `AppConstants.elevationDeadbandMeters`。
    /// - Returns: `(gain, loss)`，单位 m。
    public static func elevationGainLoss(
        _ altitudes: [Double],
        deadband: Double = AppConstants.elevationDeadbandMeters
    ) -> (gain: Double, loss: Double) {
        guard altitudes.count > 1 else { return (0, 0) }
        let epsilon = max(0, deadband)
        var gain = 0.0
        var loss = 0.0
        var index = 1
        while index < altitudes.count {
            let previous = altitudes[index - 1]
            let current = altitudes[index]
            if previous.isFinite, current.isFinite {
                let delta = current - previous
                if abs(delta) > epsilon {
                    if delta > 0 {
                        gain += delta
                    } else {
                        loss += -delta
                    }
                }
            }
            index += 1
        }
        return (gain, loss)
    }

    /// 相对海拔（气压计首事件为 0）叠加用户给定 `h0` 得到绝对海拔。
    public static func absoluteAltitude(relativeM: Double, initialAltitudeM: Double) -> Double {
        guard relativeM.isFinite, initialAltitudeM.isFinite else { return initialAltitudeM }
        return initialAltitudeM + relativeM
    }

    // MARK: Haversine 与方位角（仿真生成坐标、离线导出自检；累计距离统一走 CLLocation.distance(from:)）

    /// Haversine 大圆距离（m），R = 6 371 000 m，球面误差约 0.3%。
    public static func haversineMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat1 = a.latitude * degreesToRadians
        let lat2 = b.latitude * degreesToRadians
        let deltaLat = (b.latitude - a.latitude) * degreesToRadians
        let deltaLon = (b.longitude - a.longitude) * degreesToRadians
        let sinLat = sin(deltaLat / 2)
        let sinLon = sin(deltaLon / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let clamped = min(1, max(0, h))
        return 2 * haversineEarthRadiusM * asin(sqrt(clamped))
    }

    /// 两点间方位角（度，正北顺时针 0–360）。
    public static func bearingDegrees(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * degreesToRadians
        let lat2 = b.latitude * degreesToRadians
        let deltaLon = (b.longitude - a.longitude) * degreesToRadians
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let radians = atan2(y, x)
        let degrees = radians * radiansToDegrees
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 统一距离口径：`CLLocation.distance(from:)`。
    public static func distanceMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let locationA = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let locationB = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return locationA.distance(from: locationB)
    }

    // MARK: 展示格式化

    /// s/km → `m'ss"` 风格 min/km 文案；无效配速返回「—」。
    public static func formatPaceMinPerKm(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0, secPerKm < 3_600 else { return "—" }
        let totalSeconds = Int(secPerKm.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d'%02d\"/km", minutes, seconds)
    }

    /// 米 → 公里文案（保留两位小数）。
    public static func formatDistanceKm(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        return String(format: "%.2f km", meters / metersPerKilometer)
    }

    /// 秒 → `HH:MM:SS` 或 `MM:SS`。
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let whole = Int(seconds.rounded())
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let secs = whole % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Double 扩展：四舍五入与容差比较

public extension Double {
    /// 四舍五入到指定小数位。
    func rounded(toPlaces places: Int) -> Double {
        guard places >= 0, self.isFinite else { return self }
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }

    /// 绝对容差比较。
    func isApproximatelyEqual(to other: Double, absoluteTolerance: Double) -> Bool {
        guard self.isFinite, other.isFinite else { return false }
        return abs(self - other) <= abs(absoluteTolerance)
    }

    /// 相对容差比较（按较大绝对值缩放，零值附近回退到绝对容差）。
    func isApproximatelyEqual(to other: Double, relativeTolerance: Double) -> Bool {
        guard self.isFinite, other.isFinite else { return false }
        let scale = max(abs(self), abs(other), 1)
        return abs(self - other) <= abs(relativeTolerance) * scale
    }

    /// 夹取到闭区间。
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard self.isFinite else { return range.lowerBound }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Date 扩展：UTC ISO 8601

public extension Date {
    /// 共享的 UTC ISO 8601 格式化器（`ISO8601DateFormatter` 为线程安全的可复用实例）。
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// UTC ISO 8601 字符串（含小数秒），用于时间戳落盘 / 导出。
    var iso8601UTCString: String {
        Date.iso8601Formatter.string(from: self)
    }

    /// UTC ISO 8601 字符串（不含小数秒），用于 GPX `<time>`。
    var iso8601UTCStringWithoutFraction: String {
        Date.iso8601FallbackFormatter.string(from: self)
    }

    /// 从 ISO 8601 字符串解析（兼容含/不含小数秒两种写法）。
    static func fromISO8601(_ text: String) -> Date? {
        if let date = Date.iso8601Formatter.date(from: text) {
            return date
        }
        return Date.iso8601FallbackFormatter.date(from: text)
    }

    /// 导出文件名用的 UTC 时间戳 `YYYYMMDD_HHMMSS`。
    var utcFileNameStamp: String {
        var calendar = Calendar(identifier: .gregorian)
        // 固定 UTC（GMT+0）；绝不回落到设备本地时区。
        calendar.timeZone = TimeZone(secondsFromGMT: 0)
            ?? TimeZone(identifier: "GMT")
            ?? calendar.timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: self
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        return String(format: "%04d%02d%02d_%02d%02d%02d", year, month, day, hour, minute, second)
    }
}

// MARK: - CLLocation 扩展：值对象互转（仿真只构造 CLLocation 值对象，不持有 CLLocationManager）

public extension CLLocation {
    /// 由 `GeoPoint` 构造值对象（可选海拔与精度）。
    convenience init(point: GeoPoint, altitudeM: Double? = nil, horizontalAccuracyM: Double = -1) {
        if let altitudeM = altitudeM {
            self.init(
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                altitude: altitudeM,
                horizontalAccuracy: horizontalAccuracyM,
                verticalAccuracy: -1,
                timestamp: Date()
            )
        } else {
            self.init(latitude: point.latitude, longitude: point.longitude)
        }
    }

    /// 转为领域值对象 `GeoPoint`（不携带任何来源信息）。
    var geoPoint: GeoPoint {
        GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
