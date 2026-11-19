import SwiftUI

/// Utterance and block stepping targets. Pure clamps, so tests pin the
/// edges without a session. Callers resolve the utterance to a word through
/// `firstWordOfUtterance` and the block to a word through `byBlock`.
public enum UnitNavigation {
    /// Target utterance stepping `delta` from `current`. Clamped to the
    /// spoken range. Nil only when there is nothing spoken.
    public static func clampedUtterance(current: Int, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(current + delta, 0), count - 1)
    }

    /// Target block id stepping `delta` through `orderedIDs`. An unknown
    /// current block jumps to the near end in the step direction, so a
    /// lookup tap cannot strand the stepper. Nil only when nothing speaks.
    public static func clampedBlock(currentID: Int?, delta: Int, orderedIDs: [Int]) -> Int? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let currentID, let index = orderedIDs.firstIndex(of: currentID) else {
            return delta > 0 ? orderedIDs.first : orderedIDs.last
        }
        return orderedIDs[min(max(index + delta, 0), orderedIDs.count - 1)]
    }
}

/// Sentence stepping with block jumps on swipe. A tap moves one sentence;
/// a horizontal swipe moves one spoken block. Tap-a-word stays
/// lookup-only: it collides with lookup, so it is not a seek.
public struct SentenceStepper: View {
    private let onStepUtterance: (Int) -> Void
    private let onStepBlock: (Int) -> Void

    public init(onStepUtterance: @escaping (Int) -> Void, onStepBlock: @escaping (Int) -> Void) {
        self.onStepUtterance = onStepUtterance
        self.onStepBlock = onStepBlock
    }

    public var body: some View {
        HStack(spacing: 8) {
            stepButton(title: "Previous sentence", short: "Prev", systemImage: "chevron.left", delta: -1)
            Spacer(minLength: 8)
            stepButton(title: "Next sentence", short: "Next", systemImage: "chevron.right", delta: 1)
        }
        .padding(.horizontal, Theme.screenGutter)
        .frame(minHeight: 44)
        .background(Theme.surface)
        .gesture(swipe)
    }

    private func stepButton(title: String, short: String, systemImage: String, delta: Int) -> some View {
        Button { onStepUtterance(delta) } label: {
            HStack(spacing: 4) {
                if delta < 0 {
                    Image(systemName: systemImage)
                    Text(short)
                } else {
                    Text(short)
                    Image(systemName: systemImage)
                }
            }
            .font(Theme.chip())
            .tracking(Theme.chipTracking)
            .foregroundStyle(Theme.ink)
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(delta < 0 ? AccessibilityID.readerStepBack : AccessibilityID.readerStepForward)
        .accessibilityHint("Swipe sideways for the next block")
        .accessibilityAction(named: Text(delta < 0 ? "Previous paragraph" : "Next paragraph")) {
            onStepBlock(delta)
        }
    }

    /// A swipe is the block jump. Long-press is deliberately not it: a
    /// press that also fires the tap on release would step twice.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.width < 0 {
                    onStepBlock(1)
                } else if value.translation.width > 0 {
                    onStepBlock(-1)
                }
            }
    }
}
