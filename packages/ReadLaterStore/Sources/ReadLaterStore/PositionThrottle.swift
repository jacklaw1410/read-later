import Foundation

/// Write-during-reading gate. An OS kill sends no callback, so the place must
/// land while reading; a write per word would churn the disk ~2.3 times a
/// second at 140 wpm, so the recorder writes at most once per interval, plus
/// an immediate write on pause, scrub and background.
///
/// Check `shouldWrite` on every wash tick; call `recordNow` for the
/// out-of-band writes, which always pass and reset the interval.
public struct PositionWriteThrottle: Sendable {
    public var interval: TimeInterval
    private var lastWrite: Date?

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    public mutating func shouldWrite(now: Date = .now) -> Bool {
        guard lastWrite.map({ now.timeIntervalSince($0) >= interval }) ?? true else {
            return false
        }
        lastWrite = now
        return true
    }

    public mutating func recordNow(at date: Date = .now) {
        lastWrite = date
    }
}
