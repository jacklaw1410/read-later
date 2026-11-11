import ReadLaterCore
import SwiftUI

/// The hit state: the tapped word resolved to a gloss.
public struct LookupCard: View {
    private let result: LookupResult
    private let onClose: () -> Void

    public init(result: LookupResult, onClose: @escaping () -> Void) {
        self.result = result
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.word)
                    .font(Theme.lookupWord())
                    .foregroundStyle(Theme.ink)
                metaLine
                if let accentVariant = result.accentVariant {
                    Text(accentVariant)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(.bottom, 12)

            Divider()

            if !result.gloss.isEmpty {
                Text(result.gloss)
                    .font(Theme.gloss())
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 12)
            }

            Divider()

            Text("Source · \(result.source.rawValue)")
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.vertical, 8)

            Divider()

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .frame(minWidth: 120, minHeight: Theme.minTarget)
            }
            .frame(minHeight: Theme.minTarget)
        }
        .padding(Theme.screenGutter)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
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
