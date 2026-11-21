import ReadLaterCore
import SwiftUI

/// The hit state: the tapped word resolved to a gloss. The card owns no
/// playback; the caller supplies the flag and the word index.
public struct LookupCard: View {
    private let telemetry: TelemetryHub
    private let result: LookupResult
    private let wasPlayingBeforeLookup: Bool
    private let wordIndex: Int?
    private let isCurrentWashWord: Bool
    private let onClose: () -> Void
    @State private var didLogShown = false

    public init(
        telemetry: TelemetryHub,
        result: LookupResult,
        wasPlayingBeforeLookup: Bool,
        wordIndex: Int?,
        isCurrentWashWord: Bool,
        onClose: @escaping () -> Void
    ) {
        self.telemetry = telemetry
        self.result = result
        self.wasPlayingBeforeLookup = wasPlayingBeforeLookup
        self.wordIndex = wordIndex
        self.isCurrentWashWord = isCurrentWashWord
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(result.word)
                .font(Theme.lookupWord())
                .foregroundStyle(Theme.ink)
                .accessibilityIdentifier(AccessibilityID.lookupWord)
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

            if isCurrentWashWord {
                Text(CardCopy.coincidenceNote)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.holdInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.holdSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.holdBorder, lineWidth: 1))
                    .padding(.bottom, 12)
            }

            Divider()

            Text(CardCopy.hitSourceLine(for: result))
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 8)

            Divider()

            Text(CardCopy.pauseLine(wasPlayingBeforeLookup: wasPlayingBeforeLookup, wordIndex: wordIndex))
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 8)

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
                telemetry.record(
                    TelemetryName.cardShown,
                    fields: ["word": result.word, "kind": "hit"]
                )
            }
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let bits = [result.phonetic, result.partOfSpeech].compactMap { $0 }.filter { !$0.isEmpty }
        if !bits.isEmpty {
            Text(bits.joined(separator: " · "))
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}
