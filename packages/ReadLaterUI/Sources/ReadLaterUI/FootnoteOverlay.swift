import ReadLaterCore
import SwiftUI

/// Centred card for one footnote body. The note text stays tappable for
/// lookup; the caller supplies the pause line so the card never owns
/// playback state.
public struct FootnoteOverlay: View {
    private let marker: String
    private let text: String
    private let pauseLine: String
    private let onTapWord: (String) -> Void
    private let onClose: () -> Void

    public init(
        marker: String,
        text: String,
        pauseLine: String,
        onTapWord: @escaping (String) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.marker = marker
        self.text = text
        self.pauseLine = pauseLine
        self.onTapWord = onTapWord
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(marker) · footnote")
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)

            WashableText(text: text, slots: [], wash: .idle, style: .note) { _, word in
                onTapWord(word)
            }
            .padding(.vertical, 8)

            Text(pauseLine)
                .font(Theme.caption())
                .foregroundStyle(Theme.inkSecondary)
                .padding(.bottom, 8)

            Button("Close", action: onClose)
                .buttonStyle(SecondaryActionButtonStyle())
        }
        .padding(Theme.screenGutter)
        .frame(maxWidth: 400)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityIdentifier(AccessibilityID.readerFootnote)
    }
}
