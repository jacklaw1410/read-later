import ReadLaterCore
import SwiftUI

/// Speed stack: minus, read-out, plus. Speed only changes on tap, so the
/// whole stack skips every wash tick even though the rail rebuilds per tick
/// (M7 second cut). Data-only `Equatable`: the tap closures read speed at
/// tap time and speed changes only through these controls, so a skipped
/// value never goes stale.
struct SpeedStepper: View, Equatable {
    let speed: Float
    let ladderOpen: Binding<Bool>
    let onStep: (Int) -> Void
    let onSpeed: (Float) -> Void

    nonisolated static func == (lhs: SpeedStepper, rhs: SpeedStepper) -> Bool {
        lhs.speed == rhs.speed
    }

    var body: some View {
        VStack(spacing: 0) {
            IconButton(systemName: "minus", label: "Decrease speed") { onStep(-1) }
                .accessibilityIdentifier(AccessibilityID.railSpeedMinus)

            Button { onStep(1) } label: {
                Text(Pace.speedLabel(speed)).font(Theme.chip())
            }
            .buttonStyle(.plain)
            .frame(width: Theme.minTarget, height: Theme.minTarget)
            .accessibilityLabel("Speed \(String(format: "%g", speed)) times")
            .accessibilityHint("Tap for next step. Long press for the speed ladder.")
            .accessibilityIdentifier(AccessibilityID.railSpeed)
            .onLongPressGesture(minimumDuration: 0.5) { ladderOpen.wrappedValue = true }
            .contextMenu {
                ForEach(RailView.ladder, id: \.self) { value in
                    Button(Pace.speedLabel(value)) {
                        onSpeed(value)
                        ladderOpen.wrappedValue = false
                    }
                }
            }

            IconButton(systemName: "plus", label: "Increase speed") { onStep(1) }
                .accessibilityIdentifier(AccessibilityID.railSpeedPlus)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.buttonRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).stroke(Theme.line, lineWidth: 1))
    }
}

/// Vertical right rail: speed stack and vertical scrub. The play and sentence
/// chevrons sit in the bottom bar, see `BottomTransport`.
///
/// Spec: spec/c1-revised-refined.md in read-later-research.
/// IDs are the canonical rail IDs; legacy `reader.*` constants alias to
/// them, so one identifier per view still satisfies old queries.
public struct RailView: View {
    private let progress: PlayerProgress
    private let onSpeed: (Float) -> Void
    private let onScrub: (Double) -> Void
    private let onPreviewScrub: (Double) -> Void
    private let onScrubbingChanged: (Bool) -> Void
    /// Arrow-key handler for the scrub track. Passed straight into
    /// `.onKeyPress` with no wrapping closure, so it never captures the
    /// tick-live `progress` (M7: a fresh capture per tick rewrites the
    /// KeyPress environment and re-evaluates the rail buttons).
    private let arrowHandler: (KeyPress) -> KeyPress.Result

    /// The 4-value speed ladder. Full 0.1-step range stays on +/-.
    public static let ladder: [Float] = [0.5, 1.0, 1.2, 1.5]

    /// Right margin. Keeps the play button off the window border.
    public static let trailingGutter: CGFloat = Theme.stackGap
    /// Smallest scrub height. The track never collapses to nothing.
    private static let scrubMinHeight: CGFloat = 80

    @State private var scrubFraction: Double?
    @State private var lastFire = Date.distantPast
    @State private var ladderOpen = false

    public init(
        progress: PlayerProgress,
        onSpeed: @escaping (Float) -> Void,
        onScrub: @escaping (Double) -> Void,
        onPreviewScrub: @escaping (Double) -> Void = { _ in },
        onScrubbingChanged: @escaping (Bool) -> Void,
        arrowHandler: @escaping (KeyPress) -> KeyPress.Result = { _ in .ignored }
    ) {
        self.progress = progress
        self.onSpeed = onSpeed
        self.onScrub = onScrub
        self.onPreviewScrub = onPreviewScrub
        self.onScrubbingChanged = onScrubbingChanged
        self.arrowHandler = arrowHandler
    }

    public var body: some View {
        VStack(spacing: Theme.controlGap) {
            speedStack
            scrubTrack
        }
        .frame(width: 44)
        .padding(.vertical, Theme.controlGap)
        .padding(.trailing, Self.trailingGutter)
        .tint(Theme.brand)
        // A container identifier propagates to every descendant and hides
        // their own IDs. `children: .contain` keeps the rail as one group
        // while each control keeps the identifier the tests query.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.readerRail)
        .overlay(alignment: .topLeading) {
            if ladderOpen {
                ladderOverlay
            }
        }
    }

    // MARK: - Speed

    private var speedStack: some View {
        SpeedStepper(
            speed: progress.speed,
            ladderOpen: $ladderOpen,
            onStep: { stepSpeed($0) },
            onSpeed: onSpeed
        )
    }

    private var ladderOverlay: some View {
        VStack(spacing: 2) {
            ForEach(Self.ladder, id: \.self) { value in
                Button {
                    onSpeed(value)
                    ladderOpen = false
                } label: {
                    Text(Pace.speedLabel(value))
                        .font(Theme.chip())
                        .frame(width: 52, height: 36)
                        .background(value == progress.speed ? Theme.brand : Theme.surface)
                        .foregroundStyle(value == progress.speed ? Theme.actionInk : Theme.ink)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed \(Pace.speedLabel(value))")
            }
        }
        .padding(6)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        // Sit left of the rail, level with the speed stack. The top inset
        // cancels the rail's vertical padding.
        .offset(x: -64, y: 8)
        .accessibilityIdentifier(AccessibilityID.railSpeedLadder)
    }

    // MARK: - Scrub

    private var scrubTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Capsule().fill(Theme.line).frame(width: 4)
                Capsule().fill(Theme.brand).frame(width: 4, height: shownFraction * geo.size.height)
                Circle().fill(Theme.brand).frame(width: 16, height: 16)
                    .offset(y: shownFraction * geo.size.height - 8)
                if scrubFraction != nil {
                    Text(previewLabel)
                        .font(Theme.chip())
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                        .offset(x: -64, y: shownFraction * geo.size.height - 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrubGesture(height: geo.size.height))
        }
        .frame(width: 44)
        .padding(.vertical, Theme.controlGap)
        .frame(minHeight: Self.scrubMinHeight, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: arrowHandler)
        .accessibilityLabel("Reading progress")
        .accessibilityValue(progress.timeLabel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seekStep(1)
            case .decrement: seekStep(-1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(AccessibilityID.railScrub)
    }

    // MARK: - Helpers

    private var shownFraction: Double { scrubFraction ?? progress.fraction }

    /// Tooltip while scrubbing: word index plus time left.
    private var previewLabel: String {
        let fraction = shownFraction
        let total = max(progress.totalWords, 1)
        let index = min(total - 1, max(0, Int((fraction * Double(total)).rounded())))
        let left = max(0, total - index)
        let seconds = Pace.secondsRemaining(wordsLeft: left, speed: progress.speed)
        return "\(index)/\(total) · \(clockLabel(seconds: seconds)) left"
    }

    private func stepSpeed(_ delta: Int) {
        let idx = Pace.steps.firstIndex(of: progress.speed) ?? 0
        let next = min(Pace.steps.count - 1, max(0, idx + delta))
        onSpeed(Pace.steps[next])
    }

    /// Keyboard and VoiceOver step, in words. Seeks without scrub state.
    private func seekStep(_ delta: Int) {
        guard progress.totalWords > 0 else { return }
        let target = min(progress.totalWords, max(0, progress.wordIndex + delta))
        onScrub(Double(target) / Double(progress.totalWords))
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
