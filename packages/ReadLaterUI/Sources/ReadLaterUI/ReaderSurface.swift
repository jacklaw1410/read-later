import Foundation
import ReadLaterCore

/// How one word is drawn. Four states, and the combination of two of them.
///
/// - `current`: the word the voice is saying, amber.
/// - `paused`: the word where playback stopped, grey-amber with a ring. Never
///   only a colour change: a paused wash must survive a screenshot in greyscale.
/// - `selected`: the word the reader tapped, blue.
/// - `coincide`: tapped and currently spoken, blue fill with an amber ring.
public enum WordEmphasis: Sendable, Hashable {
    case none
    case current
    case paused
    case selected
    case coincide

    public var isMarked: Bool { self != .none }
}




// MARK: - Block presentation

public extension BlockKind {
    /// The label on a reduced-ink block. Nil when the block speaks.
    var skipChipLabel: String? {
        switch self {
        case .heading: return nil
        case .code: return "code block · skipped by audio"
        case .table: return "table · skipped by audio"
        case .image: return "image · skipped by audio"
        case .figure: return "image · skipped by audio"
        case .math: return "math · skipped by audio"
        case .embed: return "embed · skipped by audio"
        case .pullQuote: return "pull quote · skipped by audio"
        case .aside: return "aside · skipped by audio"
        case .nav: return "navigation · skipped by audio"
        case .footnoteBody: return "note · not read aloud"
        case .footnoteMarker: return nil
        case .prose, .quote, .list, .cjk: return "skipped by audio"
        }
    }
}

public extension Block {
    /// A block is skipped when it has no utterances. That is the same
    /// test the voice uses, so the ink and the audio cannot disagree.
    var isSkippedByAudio: Bool {
        spoken.isEmpty && kind != .footnoteMarker && kind != .footnoteBody
    }

    /// Notes render below the body, never inline.
    var isNote: Bool { kind == .footnoteBody }
}

// MARK: - Reading order with notes removed

public extension Document {
    /// Blocks that appear in the scrolling body, in order. Notes are lifted
    /// out because the reader shows them in a section at the end.
    var bodyBlocks: [Block] {
        readingOrder.filter { !$0.isNote }
    }

    var noteBlocks: [Block] {
        readingOrder.filter { $0.isNote }
    }

    /// Word count the voice will speak. Used by the reader subhead.
    var spokenWordCount: Int {
        readingOrder.reduce(0) { total, block in
            total + block.spoken.reduce(0) { $0 + SpokenWordNumbering.wordRanges(in: $1.text, base: 0).count }
        }
    }

    /// Number of reduced-ink blocks, excluding notes and markers.
    var skippedRegionCount: Int {
        readingOrder.filter { $0.isSkippedByAudio }.count
    }
}

// MARK: - Reader-derived values

/// Values the reader draws from one document, computed once when the document
/// opens. The owner of the document builds it and passes it to `ReaderView`,
/// so a view body re-run (a wash tick, a scroll) reads these instead of
/// recomputing them. Add a field here for any article-wide value a view needs
/// per render, rather than computing it in the view body.
public struct ReaderDerived: Sendable {
    /// Body blocks the reader lays out, without footnote markers.
    public let readableBlocks: [Block]
    /// Note bodies, in reading order. Paired with markers by order.
    public let noteBlocks: [Block]
    /// Body block ID to the marker attached to it. A block with no marker is absent.
    public let footnotes: [Int: FootnoteAttachment]
    public let spokenWordCount: Int
    public let skippedRegionCount: Int

    public init(document: Document) {
        let body = document.bodyBlocks
        let notes = document.noteBlocks
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
        self.readableBlocks = body.filter { $0.kind != .footnoteMarker }
        self.noteBlocks = notes
        self.footnotes = attachments
        self.spokenWordCount = document.spokenWordCount
        self.skippedRegionCount = document.skippedRegionCount
    }
}

// MARK: - Reader metrics

/// The reader's line and type measurements, taken from the prototype so the
/// app and the prototype cannot drift apart on the thing a reader feels first.
public enum ReaderMetrics {
    // Type and target values come from `design/tokens.json`, so the reader and
    // the other platforms cannot drift. Only reader geometry stays local here:
    // it describes this surface, not the design language.
    public static let bodySize: CGFloat = Theme.bodySize
    public static let bodyLineHeight: CGFloat = Theme.bodyLine
    public static let bodyLeading: CGFloat = Theme.bodyLineSpacing
    public static let chipSize: CGFloat = Theme.chipSize
    public static let codeSize: CGFloat = Theme.codeSize
    public static let footnoteSize: CGFloat = Theme.captionSize
    public static let quoteInset: CGFloat = 14
    public static let quoteBorder: CGFloat = 3
    public static let paragraphGap: CGFloat = 14
    /// A footnote marker needs a 44 pt target without growing the line box.
    public static let footnoteHitTarget: CGFloat = Theme.minTarget
    /// Auto-scroll stops following once the wash is this far from centre.
    public static let autoScrollTolerance: CGFloat = 140
    /// The wash is drawn half a word ahead of the audio clock so the eye lands
    /// on the word as it is spoken, not after it.
    public static let washLeadWords: Double = 0.5
}
