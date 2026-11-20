import Foundation
import Observation

// MARK: - Wash state

/// Observable wash state for one open document.
@Observable
@MainActor
public final class WashState {
    public var wordIndex: Int?
    public var selectedWordIndex: Int?

    public init(wordIndex: Int? = nil, selectedWordIndex: Int? = nil) {
        self.wordIndex = wordIndex
        self.selectedWordIndex = selectedWordIndex
    }

    /// Snapshot for the existing text-surface helpers.
    public func snapshot(playback: PlaybackState) -> WashSnapshot {
        WashSnapshot(
            wordIndex: wordIndex,
            isPlaying: playback.isPlaying,
            selectedWordIndex: selectedWordIndex
        )
    }
}

// MARK: - Playback state

/// Playback status for one open document. `stopped(atEnd:)` covers idle,
/// paused, and end-of-article; `finished` is the `atEnd` case.
@Observable
@MainActor
public final class PlaybackState {
    public enum Status: Sendable, Equatable {
        case stopped(atEnd: Bool)
        case playing
        case scrubbing(previewWordIndex: Int?)
    }

    public var status: Status = .stopped(atEnd: false)
    public var speed: Float = 1
    public var isHeld: Bool = false

    public init(status: Status = .stopped(atEnd: false), speed: Float = 1, isHeld: Bool = false) {
        self.status = status
        self.speed = speed
        self.isHeld = isHeld
    }

    public var isPlaying: Bool {
        get { if case .playing = status { return true } else { return false } }
        set {
            if newValue {
                if case .playing = status { return }
                status = .playing
            } else {
                if case .playing = status {
                    status = .stopped(atEnd: false)
                }
            }
        }
    }

    public var isFinished: Bool {
        get { if case .stopped(let atEnd) = status { return atEnd } else { return false } }
        set {
            if newValue {
                status = .stopped(atEnd: true)
            } else if case .stopped = status {
                status = .stopped(atEnd: false)
            }
        }
    }

    public var isScrubbing: Bool {
        get { if case .scrubbing = status { return true } else { return false } }
        set {
            if newValue {
                if case .scrubbing = status { return }
                status = .scrubbing(previewWordIndex: nil)
            } else {
                if case .scrubbing = status {
                    status = .stopped(atEnd: false)
                }
            }
        }
    }
}

// MARK: - Lookup state

@Observable
@MainActor
public final class LookupState<CardValue, NoteValue> {
    public var card: CardValue?
    public var note: NoteValue?
    public var offerDeclined: Bool = false
    public var isOnline: Bool = true

    public init(card: CardValue? = nil, note: NoteValue? = nil, offerDeclined: Bool = false, isOnline: Bool = true) {
        self.card = card
        self.note = note
        self.offerDeclined = offerDeclined
        self.isOnline = isOnline
    }
}
