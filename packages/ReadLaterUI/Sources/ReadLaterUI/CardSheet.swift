import ReadLaterCore
import SwiftUI

/// The bottom card container. A `ZStack` layer: scrim plus a card anchored
/// above the player bar. Never a `.sheet` or a popover.
public struct CardSheet<Content: View>: View {
    private let onDismiss: () -> Void
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    public var body: some View {
        ZStack {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            VStack {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.line)
                        .frame(width: 36, height: 4)
                        .padding(.top, 8)
                    content
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .shadow(color: Color.black.opacity(0.18), radius: 40, x: 0, y: 12)
                .padding(.horizontal, 12)
                .padding(.bottom, 58)
            }
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }
}

/// Every reader-facing card string in one type, so tests read strings rather
/// than inspecting views. State lines stay with `LookupOutcome` and are never
/// duplicated here. Copy is owned by design/miss-state.md.
enum CardCopy {
    static let offerTitle = "English–Chinese dictionary (Traditional)"
    static let offerMeta = "14.47 MiB · downloads once · works offline"
    static let offerWayBack = "You can add it later in Settings › Dictionaries."
    static let installing = "Installing…"
    static let install = "Install"
    static let notNow = "Not now"
    static let close = "Close"
    static let closeAndResume = "Close & resume"
    static let searchWeb = "Web search ↗"

    /// Hit card provenance. Built from the result even when the gloss is empty,
    /// so an empty gloss never silences the source line.
    static func hitSourceLine(for result: LookupResult) -> String {
        "Source · \(result.source.rawValue)"
    }

    static func missSourceLine(packInstalled: Bool) -> String {
        if packInstalled {
            "Source · Apple 譯典通 (built-in) + English–Chinese pack · no entry"
        } else {
            "Source · Apple 譯典通 (built-in) · no entry"
        }
    }

    static func closeLabel(wasPlayingBeforeLookup: Bool) -> String {
        wasPlayingBeforeLookup ? closeAndResume : close
    }
}
