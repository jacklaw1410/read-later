import SwiftUI

/// Strip above the player during playback while auto-scroll is held. One
/// pill, one button.
public struct HoldResumeControl: View, Equatable {
    private let isHeld: Bool
    private let isPlaying: Bool
    private let onResume: () -> Void

    public init(isHeld: Bool, isPlaying: Bool, onResume: @escaping () -> Void) {
        self.isHeld = isHeld
        self.isPlaying = isPlaying
        self.onResume = onResume
    }

    /// Data-only: the action closure is ignored in equality, so a wash tick
    /// that rebuilds the parent must not re-evaluate this control (M7).
    nonisolated public static func == (lhs: HoldResumeControl, rhs: HoldResumeControl) -> Bool {
        lhs.isHeld == rhs.isHeld && lhs.isPlaying == rhs.isPlaying
    }

    public var body: some View {
        if isHeld && isPlaying {
            Button(action: onResume) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.fill")
                    Text("Auto-scroll held")
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Theme.holdBorder)
                        .frame(width: 1, height: 16)
                    Text("Resume")
                        .fontWeight(.semibold)
                }
                .font(Theme.chip())
                .tracking(Theme.chipTracking)
                .foregroundStyle(Theme.holdInk)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.holdSurface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.holdBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto-scroll held — resume")
            .padding(.vertical, 8)
            .padding(.horizontal, Theme.screenGutter)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
            .overlay(alignment: .top) {
                Theme.line.frame(height: 1)
            }
        }
    }
}

/// When the wash resume control shows: the wash is off-screen and the
/// reader is not following it (`!washVisible && (isHeld || !isPlaying)`).
/// Pure so tests cover the rule without a scroll view.
public func shouldShowWashResumeControl(washVisible: Bool, isHeld: Bool, isPlaying: Bool) -> Bool {
    !washVisible && (isHeld || !isPlaying)
}

/// Quiet wash resume control. Shown whenever the wash is off-screen while
/// paused or held. Same surface, ink, edge and chip type as the Hold resume
/// control, so the two read as one control. The tap is the explicit user
/// action that scrolls back; play alone never yanks.
public struct WashResumeControl: View, Equatable {
    private let onReturn: () -> Void

    public init(onReturn: @escaping () -> Void) {
        self.onReturn = onReturn
    }

    /// No data: every instance is identical. The parent gates visibility, so
    /// the control itself never distinguishes a tick (M7).
    nonisolated public static func == (lhs: WashResumeControl, rhs: WashResumeControl) -> Bool {
        true
    }

    public var body: some View {
        Button(action: onReturn) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                Text("Wash off-screen")
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Theme.holdBorder)
                    .frame(width: 1, height: 16)
                Text("Return")
                    .fontWeight(.semibold)
            }
            .font(Theme.chip())
            .tracking(Theme.chipTracking)
            .foregroundStyle(Theme.holdInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.holdSurface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.holdBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wash off-screen — return to wash")
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.screenGutter)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Theme.line.frame(height: 1)
        }
    }
}

/// Decides when a scroll gesture has moved the page far enough to enter Hold.
///
/// `scrollEvent` records the offset at the first event of a gesture. It holds
/// once the move from that baseline passes the tolerance, in either direction.
/// `endGesture` clears the baseline when the reader's scroll phase ends.
public struct HoldDetector: Sendable {
    private var baseline: CGFloat?

    public init() {}

    /// Clear the baseline when the gesture ends.
    public mutating func endGesture() {
        baseline = nil
    }

    /// Feed the current offset. Return true when this gesture should hold.
    public mutating func scrollEvent(
        offset: CGFloat,
        isDriving: Bool,
        isFollowing: Bool,
        isScrubbing: Bool
    ) -> Bool {
        guard isDriving else {
            baseline = nil
            return false
        }
        guard let baseline else {
            self.baseline = offset
            return false
        }
        guard isFollowing, !isScrubbing else { return false }
        return abs(offset - baseline) > ReaderMetrics.autoScrollTolerance
    }
}
