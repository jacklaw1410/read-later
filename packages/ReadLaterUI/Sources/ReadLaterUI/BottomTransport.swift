import SwiftUI

/// Play and sentence chevrons for the bottom bar. The chevrons point left and
/// right for previous and next sentence. The identifiers are the canonical
/// rail IDs, so each control keeps one identifier for the tests.
///
/// Data-only `Equatable`: the parent rebuilds per wash tick, but the glyphs
/// only change on play/finish transitions. The action closures are recreated
/// on every parent evaluation yet capture stable targets, so they never
/// distinguish a tick (M7 second cut).
public struct BottomTransport: View, Equatable {
    private let isPlaying: Bool
    private let isFinished: Bool
    private let onPlayPause: () -> Void
    private let onStepSentence: (Int) -> Void

    public init(
        isPlaying: Bool,
        isFinished: Bool,
        onPlayPause: @escaping () -> Void,
        onStepSentence: @escaping (Int) -> Void
    ) {
        self.isPlaying = isPlaying
        self.isFinished = isFinished
        self.onPlayPause = onPlayPause
        self.onStepSentence = onStepSentence
    }

    nonisolated public static func == (lhs: BottomTransport, rhs: BottomTransport) -> Bool {
        lhs.isPlaying == rhs.isPlaying && lhs.isFinished == rhs.isFinished
    }

    public var body: some View {
        HStack(spacing: 0) {
            IconButton(systemName: "chevron.left", label: "Previous sentence") { onStepSentence(-1) }
                .accessibilityIdentifier(AccessibilityID.railPrevSentence)
            IconButton(systemName: playGlyph, label: playLabel, variant: .circle, action: onPlayPause)
                .accessibilityIdentifier(AccessibilityID.railPlayPause)
            IconButton(systemName: "chevron.right", label: "Next sentence") { onStepSentence(1) }
                .accessibilityIdentifier(AccessibilityID.railNextSentence)
        }
    }

    private var playGlyph: String {
        if isFinished { return "arrow.counterclockwise" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private var playLabel: String {
        if isFinished { return "Replay" }
        return isPlaying ? "Pause" : "Play"
    }
}
