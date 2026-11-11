import ReadLaterCore
import SwiftUI

/// Attachment for a footnote marker that follows this block in reading order.
public struct FootnoteAttachment: Sendable, Hashable {
    /// Marker text from the `footnoteMarker` block (for example "¹").
    public var marker: String
    /// Index into `Document.noteBlocks` for the paired note body.
    public var noteIndex: Int

    public init(marker: String, noteIndex: Int) {
        self.marker = marker
        self.noteIndex = noteIndex
    }
}

/// Renders one block. Spoken prose-family blocks wash; every other kind
/// renders the skip shell. Words in skipped text stay tappable for lookup
/// but carry no `WordSlot`, so the caller passes nil and the raw word.
public struct BlockView: View {
    private let block: ReadLaterCore.Block
    private let wash: WashState
    private let spoken: SpokenIndex
    private let footnote: FootnoteAttachment?
    private let followsWash: Bool
    private let onTapWord: (Int, WordSlot?, String) -> Void
    private let onTapNote: (Int) -> Void

    public init(
        block: ReadLaterCore.Block,
        wash: WashState,
        spoken: SpokenIndex,
        footnote: FootnoteAttachment? = nil,
        followsWash: Bool = false,
        onTapWord: @escaping (Int, WordSlot?, String) -> Void,
        onTapNote: @escaping (Int) -> Void
    ) {
        self.block = block
        self.wash = wash
        self.spoken = spoken
        self.footnote = footnote
        self.followsWash = followsWash
        self.onTapWord = onTapWord
        self.onTapNote = onTapNote
    }

    public var body: some View {
        blockContent
    }

    @ViewBuilder
    private var blockContent: some View {
        switch block.kind {
        case .footnoteMarker, .footnoteBody:
            EmptyView()
        case .code:
            SkipShell(label: BlockKind.code.skipChipLabel) { codeBody }
        case .table:
            SkipShell(label: BlockKind.table.skipChipLabel) { tableBody }
        case .figure, .image:
            SkipShell(label: BlockKind.figure.skipChipLabel) { figureBody }
        case .math:
            SkipShell(label: BlockKind.math.skipChipLabel) { mathBody }
        case .embed:
            SkipShell(label: BlockKind.embed.skipChipLabel) { embedBody }
        case .pullQuote:
            SkipShell(label: BlockKind.pullQuote.skipChipLabel) { pullQuoteBody }
        case .nav:
            SkipShell(label: BlockKind.nav.skipChipLabel) { navBody }
        case .heading:
            if block.isSkippedByAudio {
                SkipShell(label: BlockKind.heading.skipChipLabel) { skippedHeadingBody }
            } else {
                headingBody
            }
        case .quote:
            if block.isSkippedByAudio {
                SkipShell(label: BlockKind.quote.skipChipLabel) { skippedProseBody }
            } else {
                quoteBody
            }
        case .prose, .list, .aside, .cjk:
            if block.isSkippedByAudio {
                SkipShell(label: block.kind.skipChipLabel) { skippedProseBody }
            } else {
                proseBody
            }
        }
    }

    // MARK: - Spoken bodies

    private var spokenSlots: [WordSlot] {
        spoken.byBlock[block.id] ?? []
    }

    private func tap(_ slot: WordSlot?, _ word: String) {
        onTapWord(block.id, slot, word)
    }

    private var proseBody: some View {
        WashableText(
            text: block.text,
            slots: spokenSlots,
            wash: wash,
            marker: footnote?.marker,
            followsWash: followsWash
        ) { slot, word in
            tap(slot, word)
        } onTapMarker: {
            if let footnote { onTapNote(footnote.noteIndex) }
        }
    }

    private var headingBody: some View {
        WashableText(
            text: block.text,
            slots: spokenSlots,
            wash: wash,
            style: .heading,
            marker: footnote?.marker,
            followsWash: followsWash
        ) { slot, word in
            tap(slot, word)
        } onTapMarker: {
            if let footnote { onTapNote(footnote.noteIndex) }
        }
    }

    private var quoteBody: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.brand)
                .frame(width: ReaderMetrics.quoteBorder)
            WashableText(
                text: block.text,
                slots: spokenSlots,
                wash: wash,
                marker: footnote?.marker
            ) { slot, word in
                tap(slot, word)
            } onTapMarker: {
                if let footnote { onTapNote(footnote.noteIndex) }
            }
            .padding(.leading, ReaderMetrics.quoteInset)
        }
    }

    // MARK: - Skip shell bodies

    private var skippedProseBody: some View {
        WashableText(text: block.text, slots: [], wash: .idle, tone: .skip) { _, word in
            tap(nil, word)
        }
    }

    private var skippedHeadingBody: some View {
        WashableText(text: block.text, slots: [], wash: .idle, style: .heading, tone: .skip) { _, word in
            tap(nil, word)
        }
    }

    private var codeBody: some View {
        // Wrapped, not horizontally scrolled. A scroll view with hidden
        // indicators hides code with no cue that more exists, and the reader
        // is on a 430 pt window. Line breaks inside a string are visible; a
        // line that is silently cut is not.
        Text(block.text)
            .font(Theme.code())
            .foregroundStyle(Theme.skipInk)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tableBody: some View {
        VStack(spacing: 0) {
            ForEach(Array(tableRows().enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        WashableText(text: cell, slots: [], wash: .idle, style: .small, tone: .skip) { _, word in
                            tap(nil, word)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
                .background(rowIndex == 0 ? Theme.chipSurface : Color.clear)
                .fontWeight(rowIndex == 0 ? .bold : .regular)
                if rowIndex < tableRows().count - 1 {
                    Divider()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var figureBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                LinearGradient(
                    colors: [Theme.line, Theme.skipSurface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Image")
            WashableText(text: block.text, slots: [], wash: .idle, style: .note, tone: .skip) { _, word in
                tap(nil, word)
            }
        }
    }

    private var mathBody: some View {
        Text(block.text)
            .font(Theme.body())
            .foregroundStyle(Theme.skipInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var embedBody: some View {
        Text("\(block.text) · audio skips")
            .font(Theme.caption())
            .foregroundStyle(Theme.skipInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    private var pullQuoteBody: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.skipBorder)
                .frame(width: ReaderMetrics.quoteBorder)
            Text(block.text)
                .font(.system(size: 16, weight: .regular, design: .serif).italic())
                .foregroundStyle(Theme.skipInk)
                .padding(.leading, 10)
        }
    }

    private var navBody: some View {
        Text(block.text)
            .font(Theme.caption())
            .foregroundStyle(Theme.inkSecondary)
    }

    // MARK: - Table rows

    /// Splits table text into rows and cells. Child blocks are rows when
    /// present; otherwise non-empty lines are rows. Cells split on tabs,
    /// then on markdown pipes, then stay whole.
    func tableRows() -> [[String]] {
        let sources: [String]
        if block.children.isEmpty {
            sources = block.text.components(separatedBy: .newlines)
        } else {
            sources = block.children.map(\.text)
        }
        return sources.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.contains("\t") {
                return trimmed.components(separatedBy: "\t")
            }
            if trimmed.contains("|") {
                var inner = Substring(trimmed)
                if inner.hasPrefix("|") { inner = inner.dropFirst() }
                if inner.hasSuffix("|") { inner = inner.dropLast() }
                return inner.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return [trimmed]
        }
    }
}

/// Reduced-ink shell for a block the audio skips. Never plain grey and never
/// alpha-only: it keeps its own surface, border and chip.
struct SkipShell<Content: View>: View {
    var label: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                SkipChip(text: label)
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.skipSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.skipBorder, lineWidth: 1))
    }
}

struct SkipChip: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.chip())
            .foregroundStyle(Theme.chipInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.chipSurface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.chipBorder, lineWidth: 1))
    }
}
