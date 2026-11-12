import Foundation

/// Thread-safe box. UserDefaults is thread-safe but not marked Sendable.
private final class HandednessBox: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}

/// Persists which edge the play button sits on.
///
/// The default is the trailing (right) edge, the near corner for a right
/// thumb. A left-handed reader flips it once; the flip persists.
public struct HandednessStore: Sendable {
    private let box: HandednessBox
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "rl-play-trailing") {
        self.box = HandednessBox(defaults)
        self.key = key
    }

    /// True when play sits at the trailing edge. Defaults to true.
    public var playOnTrailing: Bool {
        guard let number = box.defaults.object(forKey: key) as? NSNumber else {
            return true
        }
        return number.boolValue
    }

    public func save(trailing: Bool) {
        box.defaults.set(trailing, forKey: key)
    }
}
