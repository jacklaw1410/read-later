import ReadLaterCore
import SwiftUI

/// Renders blocks in reading order. Body text is 19 pt serif on a 31 pt line.
/// The wash sits behind the current word; tapping a word reports its text.
public struct ReaderView: View {
    private let document: ReadLaterCore.Document
    private let wash: WashPosition?
    private let autoScroll: Bool
    private let onTapWord: (String, Int) -> Void

    public init(
        document: ReadLaterCore.Document,
        wash: WashPosition?,
        autoScroll: Bool,
        onTapWord: @escaping (String, Int) -> Void
    ) {
        self.document = document
        self.wash = wash
        self.autoScroll = autoScroll
        self.onTapWord = onTapWord
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.paragraphGap) {
                    Text(document.title)
                        .font(Theme.title())
                        .foregroundStyle(Theme.ink)
                        .padding(.bottom, 8)
                    ForEach(document.readingOrder) { block in
                        WashableParagraph(
                            text: block.text,
                            wash: washRange(for: block),
                            onTapWord: { word in onTapWord(word, block.id) }
                        )
                        .id(block.id)
                    }
                }
                .padding(.horizontal, Theme.screenGutter)
                .padding(.vertical, Theme.breathingRoom)
                .frame(maxWidth: Theme.maxLineWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: wash?.blockID) { _, newBlockID in
                guard autoScroll, let newBlockID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newBlockID, anchor: .center)
                }
            }
        }
        .background(Theme.paper)
    }

    private func washRange(for block: Block) -> NSRange? {
        guard let wash, wash.blockID == block.id else { return nil }
        let length = (block.text as NSString).length
        guard wash.range.location != NSNotFound,
              wash.range.location >= 0,
              NSMaxRange(wash.range) <= length
        else { return nil }
        return wash.range
    }
}
