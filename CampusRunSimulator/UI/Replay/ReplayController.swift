import Foundation
import SwiftUI
import Observation

// MARK: - 回放控制器（F52 / §4.3 / §B.6.6）

/// 真实时间轴驱动：`Timer` 按倍速推进 `currentElapsedSeconds`，
/// 地图位置、数值游标与四条曲线都由 `frame(at:)` 的同一时间戳派生（AC-F4）。
/// Reduce Motion 下改为离散整秒步进且不做插值动画，等价「静态呈现」。
@MainActor
public final class ReplayController: ReplayControlling, ObservableObject {

    @Published public private(set) var state: ReplayState
    @Published public private(set) var points: [TrackPoint] = []
    @Published public private(set) var durationSeconds: TimeInterval = 0
    @Published public private(set) var errorMessage: String? = nil
    /// 由页面注入系统 / 用户 Reduce Motion 偏好；true 时不使用连续插值动画。
    @Published public var reduceMotion: Bool = false

    private let repository: DefaultRunRepository?
    private var timer: Timer?
    private var lastTickDate: Date? = nil

    public init(
        sessionId: String = "",
        dataOrigin: DataOrigin = .simulated,
        repository: DefaultRunRepository? = nil
    ) {
        self.state = ReplayState(
            sessionId: sessionId,
            dataOrigin: dataOrigin,
            currentElapsedSeconds: 0,
            playbackRate: .x1,
            isPlaying: false
        )
        // 默认参数不访问 @MainActor 单例，改为在隔离域内解析，避免跨 actor 默认值求值。
        self.repository = repository ?? AppServices.shared.repository
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: ReplayControlling

    /// 从双域仓库按 `sessionId` 前缀自动路由到对应容器读取真实 / 测试采样点。
    public func load(sessionId: String) async throws {
        stopTimer()
        errorMessage = nil
        guard let repository else {
            throw AppError.persistenceMigrationFailed
        }
        let loaded = try await repository.points(sessionId: sessionId)
        guard !loaded.isEmpty else {
            throw AppError.parameterConflict(reason: "该记录没有可回放的采样点")
        }
        let origin = loaded.first?.dataOrigin
            ?? OriginID.domain(of: sessionId)
            ?? .simulated
        apply(points: loaded, sessionId: sessionId, origin: origin)
    }

    /// 预览帧 / 内存序列直接注入（F55 预览、F57 回放到时间点共用）。
    public func loadPreview(_ previewPoints: [TrackPoint], sessionId: String, origin: DataOrigin) {
        stopTimer()
        errorMessage = nil
        apply(points: previewPoints, sessionId: sessionId, origin: origin)
    }

    public func play() {
        guard !points.isEmpty else {
            errorMessage = "没有可播放的采样点"
            return
        }
        if state.currentElapsedSeconds >= durationSeconds {
            state.currentElapsedSeconds = 0
        }
        state.isPlaying = true
        startTimer()
    }

    public func pause() {
        state.isPlaying = false
        stopTimer()
    }

    public func resume() {
        guard !points.isEmpty else {
            errorMessage = "没有可继续播放的采样点"
            return
        }
        state.isPlaying = true
        startTimer()
    }

    public func seek(to elapsed: TimeInterval) {
        let clamped = min(max(0, elapsed.isFinite ? elapsed : 0), durationSeconds)
        state.currentElapsedSeconds = clamped
        lastTickDate = Date()
    }

    public func setRate(_ rate: PlaybackRate) {
        state.playbackRate = rate
        if state.isPlaying {
            startTimer()
        }
    }

    /// 同一时间戳的最近采样点（不会跨来源，因为 `points` 来自单一容器）。
    public func frame(at elapsed: TimeInterval) -> TrackPoint? {
        guard !points.isEmpty else { return nil }
        let target = min(max(0, elapsed), durationSeconds)
        var low = 0
        var high = points.count - 1
        while low < high {
            let middle = (low + high) / 2
            if points[middle].elapsedSeconds < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return points[low]
    }

    // MARK: 附加真实动作（快进 / 当前帧 / 时间轴推进）

    public func fastForward(seconds: TimeInterval = 10) {
        seek(to: state.currentElapsedSeconds + max(0, seconds))
    }

    public func rewind(seconds: TimeInterval = 10) {
        seek(to: state.currentElapsedSeconds - max(0, seconds))
    }

    /// 当前游标对应的原始采样点索引（四条曲线联动的唯一锚点）。
    public func currentSourceIndex() -> Int {
        guard !points.isEmpty else { return 0 }
        guard let frame = frame(at: state.currentElapsedSeconds) else { return 0 }
        return points.firstIndex { $0.id == frame.id } ?? 0
    }

    public var currentFrame: TrackPoint? {
        frame(at: state.currentElapsedSeconds)
    }

    /// 回放到指定时间点（F57「返回回放并定位到当前时间」的真实动作）。
    public func seekToTime(_ elapsed: TimeInterval, autoPlay: Bool = false) {
        seek(to: elapsed)
        if autoPlay {
            play()
        }
    }

    // MARK: 私有实现

    private func apply(points: [TrackPoint], sessionId: String, origin: DataOrigin) {
        let sorted = points.sorted { lhs, rhs in
            if lhs.elapsedSeconds == rhs.elapsedSeconds {
                return lhs.segmentIndex < rhs.segmentIndex
            }
            return lhs.elapsedSeconds < rhs.elapsedSeconds
        }
        self.points = sorted
        durationSeconds = max(0, sorted.last?.elapsedSeconds ?? 0)
        state = ReplayState(
            sessionId: sessionId,
            dataOrigin: origin,
            currentElapsedSeconds: 0,
            playbackRate: state.playbackRate,
            isPlaying: false
        )
        lastTickDate = nil
    }

    private func startTimer() {
        stopTimer()
        lastTickDate = Date()
        // Reduce Motion：0.5s 的离散整秒步进，不做插值，等价于静态帧呈现。
        let interval: TimeInterval = reduceMotion ? 0.5 : 0.05
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastTickDate = nil
    }

    private func tick() {
        guard state.isPlaying else { return }
        let now = Date()
        let delta = lastTickDate.map { now.timeIntervalSince($0) } ?? 0
        lastTickDate = now
        let advance = max(0, delta) * state.playbackRate.rawValue
        var next = state.currentElapsedSeconds + advance
        if reduceMotion {
            next = next.rounded(.down)
        }
        if next >= durationSeconds {
            state.currentElapsedSeconds = durationSeconds
            state.isPlaying = false
            stopTimer()
        } else {
            state.currentElapsedSeconds = next
        }
    }
}
