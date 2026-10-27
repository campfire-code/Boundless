import Foundation

/// 按 NTP 的办法估两台的时钟差：取往返最短的一次，误差不超过往返时间的一半
public struct ClockOffset {
    /// 被控端时钟减主控端时钟（秒）
    public private(set) var offset: Double?
    public private(set) var bestRoundTrip = Double.infinity

    public init() {}

    /// sent/received 是主控端发出、收到回复的时刻，clientTime 是被控端回复时的时刻
    public mutating func add(sent: Double, clientTime: Double, received: Double) {
        let rtt = received - sent
        guard rtt >= 0, rtt < bestRoundTrip else { return }
        bestRoundTrip = rtt
        offset = clientTime - (sent + rtt / 2)
    }
}

/// 虚拟屏画面的流畅度统计：一段时间内的帧率、码率、帧间最大间隔和延迟分布。时间单位为秒
public struct FrameStats {
    public struct Snapshot: Equatable {
        public var frames: Int
        public var fps: Double
        public var mbps: Double
        /// 相邻两帧的最大间隔（毫秒），卡顿主要看它
        public var maxGapMs: Double
        public var latencyAvgMs: Double
        public var latencyP95Ms: Double
        public var latencyMaxMs: Double
        /// 额外计数（如因积压丢掉的帧）
        public var dropped: Int

        public var summary: String {
            String(format: "%d 帧 %.1f fps %.1f Mbps 最大间隔 %.0fms 延迟 平均 %.1f / P95 %.1f / 最大 %.1f ms 丢帧 %d",
                   frames, fps, mbps, maxGapMs, latencyAvgMs, latencyP95Ms, latencyMaxMs, dropped)
        }
    }

    private var start: Double?
    private var last: Double?
    private var frames = 0
    private var bytes = 0
    private var maxGap = 0.0
    private var latencies: [Double] = []
    private var dropped = 0

    public init() {}

    public mutating func record(at time: Double, bytes: Int, latency: Double? = nil) {
        if start == nil { start = time }
        if let last { maxGap = max(maxGap, time - last) }
        last = time
        frames += 1
        self.bytes += bytes
        if let latency { latencies.append(latency) }
    }

    public mutating func drop() {
        dropped += 1
    }

    /// 取出 [首次记录或上次取出, now] 这段的统计并清零，下一段从 now 接着算
    public mutating func take(now: Double) -> Snapshot {
        let span = max(now - (start ?? now), 0.001)
        let sorted = latencies.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let snapshot = Snapshot(
            frames: frames, fps: Double(frames) / span, mbps: Double(bytes) * 8 / span / 1_000_000,
            maxGapMs: maxGap * 1000,
            latencyAvgMs: sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count) * 1000,
            latencyP95Ms: p95 * 1000, latencyMaxMs: (sorted.last ?? 0) * 1000, dropped: dropped)
        start = now
        frames = 0
        bytes = 0
        maxGap = 0
        latencies.removeAll(keepingCapacity: true)
        dropped = 0
        return snapshot
    }
}
