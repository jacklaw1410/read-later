import Foundation
import Observation

// MARK: - Wash state

/// Observable wash state for one open document.
///
/// `WashSnapshot` remains the value type used by `washMarks` and the text
/// surface. This model owns the mutable wash state and lets SwiftUI invalidate
/// only the views that read its properties. Playback owns `isPlaying`; pass the
/// playback model when a snapshot is needed for emphasis.
///
@Observable
@MainActor
public final class WashStateModel {
    public var wordIndex: Int?
    public var selectedWordIndex: Int?

    public init(wordIndex: Int? = nil, selectedWordIndex: Int? = nil) {
        self.wordIndex = wordIndex
        self.selectedWordIndex = selectedWordIndex
    }

    /// Snapshot for the existing text-surface helpers.
    public func snapshot(playback: PlaybackStateModel) -> WashSnapshot {
        WashSnapshot(
            wordIndex: wordIndex,
            isPlaying: playback.isPlaying,
            selectedWordIndex: selectedWordIndex
        )
    }
}

// MARK: - Playback state

@Observable
@MainActor
public final class PlaybackStateModel {
    public var isPlaying: Bool = false
    public var isFinished: Bool = false
    public var speed: Float = 1
    public var isHeld: Bool = false
    public var isScrubbing: Bool = false

    public init(
        isPlaying: Bool = false,
        isFinished: Bool = false,
        speed: Float = 1,
        isHeld: Bool = false,
        isScrubbing: Bool = false
    ) {
        self.isPlaying = isPlaying
        self.isFinished = isFinished
        self.speed = speed
        self.isHeld = isHeld
        self.isScrubbing = isScrubbing
    }
}

// MARK: - Lookup state

@Observable
@MainActor
public final class LookupStateModel<CardValue, NoteValue> {
    public var card: CardValue?
    public var note: NoteValue?
    public var offerDeclined: Bool = false
    public var isOnline: Bool = true

    public init(
        card: CardValue? = nil,
        note: NoteValue? = nil,
        offerDeclined: Bool = false,
        isOnline: Bool = true
    ) {
        self.card = card
        self.note = note
        self.offerDeclined = offerDeclined
        self.isOnline = isOnline
    }
}