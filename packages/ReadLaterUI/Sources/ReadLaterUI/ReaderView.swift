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

    /// Where the scroll view should be, given the wash word.
    ///
    /// A short block is centred when the voice enters it. A long block cannot
    /// be centred without pushing its own start off screen, so the anchor walks
    /// with the word: the fraction of the block the word sits at becomes the
    /// fraction of the viewport it lands on. That keeps the wash on screen in a
    /// 250-word paragraph without a scroll on every word, because the value
    /// only changes when the word crosses an eight-word bucket.
    private var scrollTarget: ScrollTarget? {
        guard let index = wash.wordIndex,
              let slot = spoken.word(at: index),
              let words = spoken.byBlock[slot.blockID],
              !words.isEmpty
        else { return nil }

        guard words.count > 120 else {
            return ScrollTarget(blockID: slot.blockID, anchor: .center, bucket: -1, isFractional: false)
        }
        guard let position = words.firstIndex(where: { $0.index == index }) else { return nil }
        let bucket = position / 8
        let fraction = Double(position) / Double(max(words.count - 1, 1))
        let unitY = min(max(fraction, 0.3), 0.66)
        return ScrollTarget(
            blockID: slot.blockID,
            anchor: UnitPoint(x: 0.5, y: unitY),
            bucket: bucket,
            isFractional: true
        )
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
                ScrollViewReader { proxy in
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
                    .onChange(of: scrollTarget) { _, target in
                        guard autoScroll, let target else { return }
                        withAnimation(.easeInOut(duration: target.isFractional ? 0.45 : 0.25)) {
                            proxy.scrollTo(target.blockID, anchor: target.anchor)
                        }
                    }
                }
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

/// One computed scroll position. Equatable so the reader only animates when the
/// bucket, the block, or the kind of scroll changes.
struct ScrollTarget: Equatable {
    var blockID: Int
    var anchor: UnitPoint
    var bucket: Int
    var isFractional: Bool
}
