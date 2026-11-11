import ReadLaterCore
import SwiftUI

/// Reads a document in order. The body renders `document.bodyBlocks`; notes
/// render in a `Notes` section at the end. The caller owns the player and any
/// overlay: the player sits below the scroll view, the overlay layers on top.
public struct ReaderView<Player: View, Overlay: View>: View {
    private let document: ReadLaterCore.Document
    private let wash: WashState
    private let spoken: SpokenIndex
    private let autoScroll: Bool
    private let onTapWord: (Int, WordSlot?, String) -> Void
    private let onTapNote: (Int) -> Void
    private let player: () -> Player
    private let overlay: () -> Overlay

    public init(
        document: ReadLaterCore.Document,
        wash: WashState,
        spoken: SpokenIndex,
        autoScroll: Bool,
        onTapWord: @escaping (_ blockID: Int, _ slot: WordSlot?, _ word: String) -> Void,
        onTapNote: @escaping (Int) -> Void,
        @ViewBuilder player: @escaping () -> Player,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.document = document
        self.wash = wash
        self.spoken = spoken
        self.autoScroll = autoScroll
        self.onTapWord = onTapWord
        self.onTapNote = onTapNote
        self.player = player
        self.overlay = overlay
    }

    /// True when this block holds the word the voice is on.
    private func holdsWash(_ blockID: Int) -> Bool {
        guard let index = wash.wordIndex else { return false }
        return spoken.byBlock[blockID]?.contains { $0.index == index } ?? false
    }

    /// Marker blocks attached to the preceding body block, paired with note
    /// bodies by order. Maps body block ID to its attachment.
    private var footnoteAttachments: [Int: FootnoteAttachment] {
        let notes = document.noteBlocks
        let body = document.bodyBlocks
        var attachments: [Int: FootnoteAttachment] = [:]
        var markerIndex = 0
        for position in body.indices {
            guard body[position].kind == .footnoteMarker else { continue }
            defer { markerIndex += 1 }
            guard markerIndex < notes.count, position > 0 else { continue }
            let preceding = body[position - 1]
            guard preceding.kind != .footnoteMarker else { continue }
            attachments[preceding.id] = FootnoteAttachment(
                marker: body[position].text,
                noteIndex: markerIndex
            )
        }
        return attachments
    }

    private var readableBlocks: [ReadLaterCore.Block] {
        document.bodyBlocks.filter { $0.kind != .footnoteMarker }
    }

    private var metaLine: String {
        let host = document.url?.host() ?? "pasted text"
        // Short enough for one line at the narrowest window. The counts are
        // the voice's own numbers, so the subhead cannot claim a word the
        // reader will not hear.
        return "\(host) · \(document.spokenWordCount) words · \(document.skippedRegionCount) skipped"
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(document.title)
                                .font(Theme.title())
                                .foregroundStyle(Theme.ink)
                                .padding(.bottom, 8)
                            Text(metaLine)
                                .font(Theme.caption())
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.bottom, 12)
                            ForEach(readableBlocks) { block in
                                BlockView(
                                    block: block,
                                    wash: wash,
                                    spoken: spoken,
                                    footnote: footnoteAttachments[block.id],
                                    followsWash: autoScroll && holdsWash(block.id),
                                    onTapWord: onTapWord,
                                    onTapNote: onTapNote
                                )
                                .id(block.id)
                            }
                            if !document.noteBlocks.isEmpty {
                                notesSection
                            }
                        }
                        .padding(.horizontal, Theme.screenGutter)
                        .padding(.vertical, Theme.breathingRoom)
                        .frame(maxWidth: Theme.maxLineWidth)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    // No `ScrollViewReader` here on purpose: `scrollTo` takes
                    // a view id, and a word is not a view. The block holding
                    // the wash word scrolls its own enclosing scroll view, so
                    // the page follows within a paragraph as well as between
                    // paragraphs.
                player()
            }
            overlay()
        }
        .background(Theme.paper)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)
            Divider()
            ForEach(document.noteBlocks) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    WashableText(text: note.text, slots: [], wash: .idle, style: .note) { _, word in
                        onTapWord(note.id, nil, word)
                    }
                }
                .id(note.id)
            }
        }
        .padding(.top, 18)
    }
}
