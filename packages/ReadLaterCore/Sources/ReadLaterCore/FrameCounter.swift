import Foundation

/// Display-frame timestamps for one measurement window.
///
/// The latency plan (`device-verification-latency.md` M1/M5) needs the pixel
/// side of an interaction: how many display frames passed, and how far apart
/// they were. This type is the pure accumulator. It knows nothing about
/// `CADisplayLink`; the DEBUG-only driver in the app feeds it vsync times and
/// writes the summary to the oplog. Inert unless fed, so Release builds that
/// never call it behave exactly as before.
public struct FrameCounter: Sendable {
    private var stamps: [TimeInterval] = []

    public init() {}

    /// Records one frame time, on the `ProcessInfo.systemUptime` basis.
    public mutating func record(at t: TimeInterval) {
        stamps.append(t)
    }

    /// Recorded frames so far.
    public var count: Int { stamps.count }

    /// Drops all frames, keeping the buffer.
    public mutating func reset() {
        stamps.removeAll(keepingCapacity: true)
    }

    /// Summarizes the window. Nil with fewer than two frames, or when time
    /// does not advance: there is no rate to report.
    public func summary() -> FrameWindowSummary? {
        guard stamps.count >= 2, let first = stamps.first, let last = stamps.last else { return nil }
        let duration = last - first
        guard duration > 0 else { return nil }
        var longest: TimeInterval = 0
        for i in stamps.indices.dropFirst() {
            longest = max(longest, stamps[i] - stamps[i - 1])
        }
        let frames = stamps.count
        return FrameWindowSummary(
            frames: frames,
            duration: duration,
            fps: Double(frames - 1) / duration,
            longestGap: longest
        )
    }
}

/// One closed measurement window: frame count, span, mean rate, worst gap.
///
/// M5 reads `fps` and `longestGap` straight off this. M1 reads the frame
/// count between the tap stamp and the state-change stamp, which the driver
/// attaches as extra fields.
public struct FrameWindowSummary: Sendable, Hashable {
    /// Frames in the window.
    public var frames: Int
    /// Seconds from first to last frame.
    public var duration: TimeInterval
    /// `(frames - 1) / duration`.
    public var fps: Double
    /// Worst adjacent-frame gap, seconds.
    public var longestGap: TimeInterval

    public init(frames: Int, duration: TimeInterval, fps: Double, longestGap: TimeInterval) {
        self.frames = frames
        self.duration = duration
        self.fps = fps
        self.longestGap = longestGap
    }

    /// Oplog-ready fields. Times in milliseconds; `extra` overrides nothing,
    /// it only adds caller keys such as the tap-to-state gap.
    public func fields(extra: [String: String] = [:]) -> [String: String] {
        var out = extra
        out["frames"] = String(frames)
        out["durationMs"] = Self.ms(duration)
        out["fps"] = String(format: "%.1f", fps)
        out["longestGapMs"] = Self.ms(longestGap)
        return out
    }

    public static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds * 1_000)
    }
}
