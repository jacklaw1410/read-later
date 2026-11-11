import Foundation
import ReadLaterCore

/// Thread-safe box. UserDefaults is thread-safe but not marked Sendable.
private final class DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}

/// Persists the chosen playback speed across relaunches.
///
/// Only ladder values are stored. Anything else falls back to the reference.
public struct SpeedStore: Sendable {
    private let box: DefaultsBox
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "rl-speed") {
        self.box = DefaultsBox(defaults)
        self.key = key
    }

    /// Stored speed, or the reference pace when nothing valid is stored.
    public var speed: Float {
        guard let number = box.defaults.object(forKey: key) as? NSNumber else {
            return Pace.reference
        }
        let value = number.floatValue
        return Pace.steps.contains(value) ? value : Pace.reference
    }

    /// Store a ladder speed. Ignore anything off the ladder.
    public func save(_ speed: Float) {
        guard Pace.steps.contains(speed) else { return }
        box.defaults.set(speed, forKey: key)
    }
}
