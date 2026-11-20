import ReadLaterCore
import SwiftUI

/// The hit state: the tapped word resolved to a gloss. The card owns no
/// playback; the caller supplies the flag.
public struct LookupCard: View {
    private let result: LookupResult
    private let wasPlayingBeforeLookup: Bool
    private let onPronounce: () -> Void
    private let onClose: () -> Void
    @State private var didLogShown = false

    public init(
        result: LookupResult,
        wasPlayingBeforeLookup: Bool,
        onPronounce: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.result = result
        self.wasPlayingBeforeLookup = wasPlayingBeforeLookup
        self.onPronounce = onPronounce
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(result.word)
                    .font(Theme.lookupWord())
                    .foregroundStyle(Theme.ink)
                    .accessibilityIdentifier(AccessibilityID.lookupWord)
                IconButton(systemName: "speaker.wave.2", label: "Pronounce \(result.word)", action: onPronounce)
                    .accessibilityIdentifier(AccessibilityID.lookupPronounce)
                    // The 44 pt box would grow the word row. These margins match the prototype's `.pronounce`.
                    .padding(.vertical, -10)
                    .padding(.leading, -2)
                    .padding(.trailing, -12)
                if let phonetic = result.phonetic, !phonetic.isEmpty {
                    Spacer(minLength: 8)
                    Text(phonetic)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            metaLine
            if let accentVariant = result.accentVariant {
                Text(accentVariant)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.inkSecondary)
            }

            Divider()
                .padding(.top, 12)

            if !result.gloss.isEmpty {
                Text(result.gloss)
                    .font(Theme.gloss())
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier(AccessibilityID.lookupGloss)
            }

            Divider()

            Text(CardCopy.hitSourceLine(for: result))
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 8)

            Button(CardCopy.closeLabel(wasPlayingBeforeLookup: wasPlayingBeforeLookup), action: onClose)
                .buttonStyle(SecondaryActionButtonStyle())
                .padding(.top, 8)
        }
        .padding(Theme.screenGutter)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        // A container, so the card, the word and the gloss each answer to
        // their own identifier. Without it SwiftUI copies the card identifier
        // onto every child, and `lookup.word` and `lookup.gloss` stop existing.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.lookupCard)
        .onAppear {
            // One main-loop turn past attach: past the current CATransaction
            // commit, within one runloop of first pixels. init/body run
            // before layout, so they would mark intent, not paint.
            DispatchQueue.main.async {
                guard !didLogShown else { return }
                didLogShown = true
                TelemetryHub.shared.record(
                    TelemetryName.cardShown,
                    fields: ["word": result.word, "kind": "hit"]
                )
            }
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        if let pos = result.partOfSpeech, !pos.isEmpty {
            Text(pos)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}
