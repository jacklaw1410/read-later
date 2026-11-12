import Foundation

/// Coalesces rapid speed changes into one restart per gesture (F19 1.7).
///
/// The controller pushes every `rate` change and takes the pending value once
/// after the settle delay. Bursts collapse to the last value; a second take
/// without a new push yields nothing, so no tick restarts twice.
public struct RateSettler: Sendable {
    private var pending: Float?

    public init() {}

    public mutating func push(_ rate: Float) {
        pending = rate
    }

    public mutating func takePending() -> Float? {
        defer { pending = nil }
        return pending
    }
}
