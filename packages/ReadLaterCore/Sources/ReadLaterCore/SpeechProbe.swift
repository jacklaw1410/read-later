import Foundation

// MARK: - Speech probe
//
// The voice reports what happened; a probe decides what to log. Stall
// evidence is research-only, so the controller carries no timer and no
// Debug conditional: it exposes one optional callback and one read-only
// sample. A platform target supplies the probe and turns it on for a Debug
// run. See `docs/telemetry-and-sync-oplog.md`.

/// Engine truth at one instant, for a probe that samples the voice.
public struct SpeechProbeSample: Equatable, Sendable {
    public var state: SpeechState
    /// The synthesizer's own view. A stall reads `state == .speaking` here
    /// while `isSpeaking` is false.
    public var isSpeaking: Bool
    public var isPaused: Bool
    /// Utterances still with the synthesizer.
    public var queued: Int
    /// Last word boundary reached, as a global word index.
    public var word: Int

    public init(
        state: SpeechState,
        isSpeaking: Bool,
        isPaused: Bool,
        queued: Int,
        word: Int
    ) {
        self.state = state
        self.isSpeaking = isSpeaking
        self.isPaused = isPaused
        self.queued = queued
        self.word = word
    }
}

/// Why the voice was held. The controller knows the call site, so the probe
/// does not have to infer it.
public enum SpeechHoldReason: Sendable, Equatable {
    case pause
    case scrub
    case interruption
}

/// One thing the voice did that a probe may want to record. Events carry only
/// what the controller already has; nothing here is stored by the voice.
public enum SpeechProbeEvent: Sendable, Equatable {
    /// An utterance started: the voice is audible for the first time in this
    /// train. The heartbeat starts here.
    case utteranceStarted(utterance: Int)
    /// A word boundary. The last one before silence names the stall point.
    case boundary(utterance: Int, word: Int)
    /// The voice was silenced at a word and stays paused. Reasons come from
    /// `SpeechHoldReason`.
    case held(reason: SpeechHoldReason)
    /// A paused synthesizer was told to continue without a restart.
    case resumed
    case cancelled(tracked: Bool, state: SpeechState)
    case interrupted(type: UInt, state: SpeechState)
    case finished
    case stopped
}
