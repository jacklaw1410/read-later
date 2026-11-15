import SwiftUI

/// Play and sentence chevrons for the bottom bar. The chevrons point left and
/// right for previous and next sentence. The identifiers are the canonical
/// rail IDs, so each control keeps one identifier for the tests.
public struct BottomTransport: View {
    private let progress: PlayerProgress
    private let isPlaying: Bool
    private let onPlayPause: () -> Void
    private let onStepSentence: (Int) -> Void

    public init(
        progress: PlayerProgress,
        isPlaying: Bool,
        onPlayPause: @escaping () -> Void,
        onStepSentence: @escaping (Int) -> Void
    ) {
        self.progress = progress
        self.isPlaying = isPlaying
        self.onPlayPause = onPlayPause
        self.onStepSentence = onStepSentence
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
        if progress.isFinished { return "arrow.counterclockwise" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private var playLabel: String {
        if progress.isFinished { return "Replay" }
        return isPlaying ? "Pause" : "Play"
    }
}
