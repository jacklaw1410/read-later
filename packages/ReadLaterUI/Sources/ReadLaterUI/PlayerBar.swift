import ReadLaterCore
import SwiftUI

/// Progress values for the transport bar. Pure data, so tests cover it.
public struct PlayerProgress: Sendable, Equatable {
    public var wordIndex: Int
    public var totalWords: Int
    public var speed: Float
    public var isFinished: Bool

    public init(wordIndex: Int, totalWords: Int, speed: Float, isFinished: Bool) {
        self.wordIndex = wordIndex
        self.totalWords = totalWords
        self.speed = speed
        self.isFinished = isFinished
    }

    /// Track position from 0 to 1. Past-the-end input clamps to 1.
    public var fraction: Double {
        guard totalWords > 0 else { return 0 }
        return min(1, max(0, Double(wordIndex) / Double(totalWords)))
    }

    /// Clock text for the bar, such as "04:12 left · 138/447".
    /// Finished and empty documents use fixed text.
    public var timeLabel: String {
        if isFinished {
            return "Finished · \(totalWords)/\(totalWords)"
        }
        guard totalWords > 0 else { return "00:00 left · 0/0" }
        let left = max(0, totalWords - wordIndex)
        let seconds = Pace.secondsRemaining(wordsLeft: left, speed: speed)
        return "\(clockLabel(seconds: seconds)) left · \(wordIndex)/\(totalWords)"
    }
}

/// Docked transport bar: play/pause, scrub track, speed, clock.
///
/// The bar reports gestures through `onScrub` and `onScrubbingChanged`.
/// It never moves the wash itself. While scrubbing, the caller holds the
/// wash still and seeks only the audio clock.
public struct PlayerBar: View {
    private let progress: PlayerProgress
    private let isPlaying: Bool
    private let onPlayPause: () -> Void
    private let onSpeed: (Float) -> Void
    private let onScrub: (Double) -> Void
    private let onScrubbingChanged: (Bool) -> Void

    /// Live drag position. Shown while the finger is down.
    @State private var scrubFraction: Double?
    @State private var lastFire = Date.distantPast
    @State private var lastFiredValue: Double?

    public init(
        progress: PlayerProgress,
        isPlaying: Bool,
        onPlayPause: @escaping () -> Void,
        onSpeed: @escaping (Float) -> Void,
        onScrub: @escaping (Double) -> Void,
        onScrubbingChanged: @escaping (Bool) -> Void
    ) {
        self.progress = progress
        self.isPlaying = isPlaying
        self.onPlayPause = onPlayPause
        self.onSpeed = onSpeed
        self.onScrub = onScrub
        self.onScrubbingChanged = onScrubbingChanged
    }

    public var body: some View {
        HStack(spacing: 10) {
            playButton
            scrubTrack
            speedButton
            Text(progress.timeLabel)
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(height: 58)
        .padding(.horizontal, Theme.screenGutter)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Theme.line.frame(height: 1)
        }
    }

    // MARK: - Play

    private var playButton: some View {
        Button(action: onPlayPause) {
            Image(systemName: playGlyph)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.actionInk)
                .frame(width: 44, height: 44)
                .background(Theme.actionFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playLabel)
    }

    private var playGlyph: String {
        if progress.isFinished { return "arrow.counterclockwise" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private var playLabel: String {
        if progress.isFinished { return "Replay" }
        return isPlaying ? "Pause" : "Play"
    }

    // MARK: - Scrub

    private var shownFraction: Double {
        scrubFraction ?? progress.fraction
    }

    private var scrubTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.line)
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.brand)
                    .frame(width: shownFraction * geo.size.width, height: 4)
                Circle()
                    .fill(Theme.brand)
                    .frame(width: 16, height: 16)
                    .offset(x: shownFraction * geo.size.width - 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
            .focusable()
            .onKeyPress(phases: .down) { press in
                switch press.key {
                case .leftArrow:
                    seekStep(press.modifiers.contains(.shift) ? -10 : -1)
                    return .handled
                case .rightArrow:
                    seekStep(press.modifiers.contains(.shift) ? 10 : 1)
                    return .handled
                default:
                    return .ignored
                }
            }
            .accessibilityLabel("Reading progress")
            .accessibilityValue(progress.timeLabel)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: seekStep(1)
                case .decrement: seekStep(-1)
                @unknown default: break
                }
            }
        }
        .frame(height: 44)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = clamped(value.location.x / max(width, 1))
                if scrubFraction == nil {
                    scrubFraction = fraction
                    onScrubbingChanged(true)
                    fire(fraction)
                } else {
                    scrubFraction = fraction
                    fireThrottled(fraction)
                }
            }
            .onEnded { value in
                let fraction = clamped(value.location.x / max(width, 1))
                scrubFraction = nil
                fireFinal(fraction)
                onScrubbingChanged(false)
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    /// Report at most every 50 ms during a drag.
    private func fireThrottled(_ fraction: Double) {
        guard Date().timeIntervalSince(lastFire) >= 0.05 else { return }
        fire(fraction)
    }

    private func fire(_ fraction: Double) {
        lastFire = Date()
        lastFiredValue = fraction
        onScrub(fraction)
    }

    /// Report the release position unless the drag already sent it.
    private func fireFinal(_ fraction: Double) {
        guard lastFiredValue != fraction else { return }
        fire(fraction)
    }

    /// Keyboard and VoiceOver step, in words. Seeks without scrub state.
    private func seekStep(_ delta: Int) {
        guard progress.totalWords > 0 else { return }
        let target = min(progress.totalWords, max(0, progress.wordIndex + delta))
        onScrub(Double(target) / Double(progress.totalWords))
    }

    // MARK: - Speed

    private var speedButton: some View {
        Button {
            onSpeed(Pace.next(after: progress.speed))
        } label: {
            Text(Pace.speedLabel(progress.speed))
                .font(Theme.chip())
                .tracking(Theme.chipTracking)
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed \(String(format: "%g", progress.speed)) times")
    }
}
