import ReadLaterCore
import SwiftUI

public struct RailView: View {
    private let progress: PlayerProgress
    private let isPlaying: Bool
    private let onPlayPause: () -> Void
    private let onSpeed: (Float) -> Void
    private let onScrub: (Double) -> Void
    private let onPreviewScrub: (Double) -> Void
    private let onScrubbingChanged: (Bool) -> Void
    private let onStepSentence: (Int) -> Void

    @State private var scrubFraction: Double?
    @State private var lastFire = Date.distantPast

    public init(
        progress: PlayerProgress,
        isPlaying: Bool,
        onPlayPause: @escaping () -> Void,
        onSpeed: @escaping (Float) -> Void,
        onScrub: @escaping (Double) -> Void,
        onPreviewScrub: @escaping (Double) -> Void = { _ in },
        onScrubbingChanged: @escaping (Bool) -> Void,
        onStepSentence: @escaping (Int) -> Void
    ) {
        self.progress = progress
        self.isPlaying = isPlaying
        self.onPlayPause = onPlayPause
        self.onSpeed = onSpeed
        self.onScrub = onScrub
        self.onPreviewScrub = onPreviewScrub
        self.onScrubbingChanged = onScrubbingChanged
        self.onStepSentence = onStepSentence
    }

    public var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                Button { stepSpeed(-1) } label: { Text("-").font(.system(size: 16, weight: .bold)) }
                    .buttonStyle(.plain).frame(width: 44, height: 36)
                    .accessibilityLabel("Decrease speed")
                                    Button { stepSpeed(1) } label: { Text(Pace.speedLabel(progress.speed)).font(Theme.chip()) }
                    .buttonStyle(.plain).frame(width: 44, height: 36)
                    .accessibilityLabel("Speed \(String(format: "%g", progress.speed)) times")
                                        .accessibilityIdentifier(AccessibilityID.readerSpeed)
                Button { stepSpeed(1) } label: { Text("+").font(.system(size: 16, weight: .bold)) }
                    .buttonStyle(.plain).frame(width: 44, height: 36)
                    .accessibilityLabel("Increase speed")
                                }
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Capsule().fill(Theme.line).frame(width: 4)
                    Capsule().fill(Theme.brand).frame(width: 4, height: shownFraction * geo.size.height)
                    Circle().fill(Theme.brand).frame(width: 16, height: 16)
                        .offset(y: shownFraction * geo.size.height - 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(scrubGesture(height: geo.size.height))
            }
            .frame(width: 44, height: 120)
            .accessibilityLabel("Reading progress")
            .accessibilityValue(progress.timeLabel)
                        .accessibilityIdentifier(AccessibilityID.readerProgress)
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
                        .accessibilityIdentifier(AccessibilityID.readerPlayPause)
            VStack(spacing: 2) {
                Button { onStepSentence(-1) } label: { Text("<").font(.system(size: 16, weight: .bold)) }
                    .buttonStyle(.plain).frame(width: 44, height: 36)
                    .accessibilityLabel("Previous sentence")
                                        .accessibilityIdentifier(AccessibilityID.readerStepBack)
                Button { onStepSentence(1) } label: { Text(">").font(.system(size: 16, weight: .bold)) }
                    .buttonStyle(.plain).frame(width: 44, height: 36)
                    .accessibilityLabel("Next sentence")
                                        .accessibilityIdentifier(AccessibilityID.readerStepForward)
            }
        }
        .frame(width: 44)
        .padding(.vertical, 8)
            }

    private var shownFraction: Double { scrubFraction ?? progress.fraction }
    private var playGlyph: String {
        if progress.isFinished { return "arrow.counterclockwise" }
        return isPlaying ? "pause.fill" : "play.fill"
    }
    private var playLabel: String {
        if progress.isFinished { return "Replay" }
        return isPlaying ? "Pause" : "Play"
    }
    private func stepSpeed(_ delta: Int) {
        let idx = Pace.steps.firstIndex(of: progress.speed) ?? 0
        let next = min(Pace.steps.count - 1, max(0, idx + delta))
        onSpeed(Pace.steps[next])
    }
    private func scrubGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = clamped(value.location.y / max(height, 1))
                if scrubFraction == nil {
                    scrubFraction = fraction
                    onScrubbingChanged(true)
                    firePreview(fraction)
                } else {
                    scrubFraction = fraction
                    firePreviewThrottled(fraction)
                }
            }
            .onEnded { value in
                let fraction = clamped(value.location.y / max(height, 1))
                scrubFraction = nil
                onScrub(fraction)
                onScrubbingChanged(false)
            }
    }
    private func clamped(_ value: Double) -> Double { min(1, max(0, value)) }
    private func firePreviewThrottled(_ fraction: Double) {
        guard Date().timeIntervalSince(lastFire) >= 0.05 else { return }
        firePreview(fraction)
    }
    private func firePreview(_ fraction: Double) {
        lastFire = Date()
        onPreviewScrub(fraction)
    }
}
