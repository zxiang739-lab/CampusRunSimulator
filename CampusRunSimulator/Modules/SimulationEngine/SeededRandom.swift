import Foundation

// MARK: - 唯一随机入口（§7.3 / F24）

/// SplitMix64 确定性 PRNG：本项目**唯一随机入口**。
/// 同 `seed` → `nextUnit()` 序列逐值完全一致（AC-D5 / I10）。
/// 全项目禁止 `Double.random` / `Int.random` / `arc4random` / `.shuffled()` /
/// `SystemRandomNumberGenerator`；`UUID()` 只允许用于实体 id，绝不参与任何数值生成。
public struct SeededRandom: Sendable {
    /// 64 位内部状态。
    private var state: UInt64

    /// SplitMix64 增量常数（黄金比例共轭）。
    private static let increment: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// 2^53，把 53 位整数映射到 `[0, 1)`。
    private static let unitScale: Double = 1.0 / 9_007_199_254_740_992.0

    public init(seed: UInt64) {
        // seed == 0 亦合法：用增量常数打散，避免前若干输出退化。
        state = seed &+ Self.increment
    }

    /// 下一个 64 位无符号整数（SplitMix64 核心）。
    public mutating func nextUInt64() -> UInt64 {
        state = state &+ Self.increment
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `[0, 1)` 均匀分布单元值，53 位精度，逐点可复现。
    public mutating func nextUnit() -> Double {
        Double(nextUInt64() >> 11) * Self.unitScale
    }

    /// `[-amplitude, amplitude)` 的有界扰动；amplitude ≤ 0 或非有限时返回 0。
    public mutating func nextBounded(_ amplitude: Double) -> Double {
        let bound = abs(amplitude)
        guard bound.isFinite, bound > 0 else { return 0 }
        return (nextUnit() * 2 - 1) * bound
    }

    /// `[lower, upper)` 区间内的确定性值（区间退化时返回下界）。
    public mutating func nextValue(in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        return range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }

    /// 由主种子确定性派生独立子种子（各噪声流互不相关，但全部只源于同一个 seed）。
    public static func derive(_ salt: UInt64, from seed: UInt64) -> UInt64 {
        var generator = SeededRandom(seed: seed)
        var result: UInt64 = 0
        for _ in 0..<4 {
            result ^= generator.nextUInt64()
        }
        return result ^ salt
    }

    /// 由种子派生的稳定相位（不消耗调用方序列，供纯函数型平滑扰动使用）。
    public static func phase(for seed: UInt64, salt: UInt64 = 0) -> Double {
        let derived = derive(salt, from: seed)
        return Double(derived >> 11) * unitScale * 2 * Double.pi
    }
}

// MARK: - 时间相关有界平滑噪声

/// 时间相关有界平滑噪声（OU / 一阶低通风格，F24 / §B.9.2）。
/// **不是逐点白噪声**：内部状态按 `exp(-Δt/τ)` 衰减并叠加有界创新项，
/// 输出恒定落在 `[-amplitude, amplitude]`，相邻时刻强相关；相关时间可配。
/// 引擎在同一帧用 `currentValue()` 把同一扰动共享给 `v` 与 `c`（相关扰动，C-03）。
public struct SmoothNoise: Sendable {
    private var rng: SeededRandom
    private let correlationSeconds: TimeInterval
    private let amplitude: Double
    private var state: Double
    private var lastTime: TimeInterval?

    public init(rng: SeededRandom, correlationSeconds: TimeInterval = 8, amplitude: Double = 1) {
        var generator = rng
        let tau = correlationSeconds.isFinite && correlationSeconds > 0 ? correlationSeconds : 8
        let amp = amplitude.isFinite && amplitude > 0 ? amplitude : 0
        // 初始状态也由同一种子确定性给出，避免 t=0 处出现固定偏置。
        let initial = generator.nextBounded(1)
        self.rng = generator
        self.correlationSeconds = tau
        self.amplitude = amp
        self.state = initial
        self.lastTime = nil
    }

    /// 在时刻 `t` 采样（可按任意时间步调用，按真实 Δt 计算衰减）。
    /// 同一 `t` 重复调用会消耗序列，因此每帧只调用一次，其余字段用 `currentValue()` 共享。
    public mutating func value(atTime t: TimeInterval) -> Double {
        guard amplitude > 0, t.isFinite else { return 0 }
        let delta: TimeInterval
        if let last = lastTime {
            delta = max(0, t - last)
        } else {
            delta = correlationSeconds
        }
        lastTime = t
        let decay = exp(-delta / correlationSeconds)
        // 稳态方差归一：创新项 ∝ sqrt(1 - decay²)，输出方差不随采样率漂移。
        let innovationScale = sqrt(max(0, 1 - decay * decay))
        let innovation = rng.nextBounded(1) * innovationScale
        state = state * decay + innovation
        return currentValue()
    }

    /// 读取当前状态（不消耗 RNG），供同一时刻多个字段共享同一扰动。
    public func currentValue() -> Double {
        guard amplitude > 0 else { return 0 }
        return (state / 2).clamped(to: -1...1) * amplitude
    }

    /// 相关时间（s），供诊断与测试读取。
    public var correlation: TimeInterval {
        correlationSeconds
    }

    /// 输出上界（绝对值），供诊断与测试读取。
    public var bound: Double {
        amplitude
    }
}
