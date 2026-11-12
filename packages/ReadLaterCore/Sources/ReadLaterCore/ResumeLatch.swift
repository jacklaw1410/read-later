import Foundation

/// Stash for the word a paused scrub leaves behind.
///
/// The paused-scrub defect (F19 1.3) was a latch cleared before the start it
/// armed: `stop()` destroyed the queue `restart(fromWord:)` needed, and the
/// position was already gone. The rule this type enforces: peek first, clear
/// only after the start succeeds. A failed start leaves the stash intact, so
/// the next press retries the same word instead of restarting at zero.
public struct ResumeLatch: Sendable {
    private var word: Int?

    public init() {}

    public mutating func stash(_ wordIndex: Int) {
        word = wordIndex
    }

    public func peek() -> Int? {
        word
    }

    public mutating func clear() {
        word = nil
    }
}
