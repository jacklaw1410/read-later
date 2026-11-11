import SwiftUI

/// Strip above the player while auto-scroll is held. One pill, one button.
public struct HoldBadge: View {
    private let isHeld: Bool
    private let isPlaying: Bool
    private let onResume: () -> Void

    public init(isHeld: Bool, isPlaying: Bool, onResume: @escaping () -> Void) {
        self.isHeld = isHeld
        self.isPlaying = isPlaying
        self.onResume = onResume
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

/// Decides when a scroll counts as a deliberate move away from the wash.
///
/// Programmatic scrolls arrive as bursts, so one far event never holds.
/// Two consecutive far events hold. A near event resets the count.
public struct HoldDetector: Sendable {
    private var farCount = 0

    public init() {}

    /// Check one scroll event. Return true when this event holds the follow.
    public mutating func scrollEvent(
        distanceFromWash: CGFloat,
        isFollowing: Bool,
        isScrubbing: Bool
    ) -> Bool {
        if isScrubbing { return false }
        guard isFollowing else { return false }
        if abs(distanceFromWash) > ReaderMetrics.autoScrollTolerance {
            farCount += 1
            return farCount >= 2
        }
        farCount = 0
        return false
    }
}
