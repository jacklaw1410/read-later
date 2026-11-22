import CryptoKit
import Foundation
import ReadLaterCore

/// The sentence a position is anchored to: sha256-16 of its normalized text,
/// and its first five normalized words. Empty strings mean no anchor.
struct SentenceAnchor: Equatable {
    var hash: String
    var head: String

    static let none = SentenceAnchor(hash: "", head: "")
}

/// Maps a stored reading position onto a new plan of the same article
/// (research `spec/library-identity.md` §4, F38).
///
/// Pure: no store access. Resolution order: exact anchor hash (single hit),
/// nearest copy of a repeated anchor, rewrite gate, unique fuzzy head,
/// proportion, then entry start (0).
enum AnchorResolver {
    /// Dummy, non-blocking gate. Value 0.25 from synthetic trials on the
    /// unmerged research branch (`research/library-identity-build`:
    /// `findings/F38-library-anchor-recommendation.md`, SCOPE §5 2026-11-17 —
    /// 36 synthetic trials; "not a proven gate"). Confirm against real edit
    /// histories when that branch lands. A same-length rewrite evades any
    /// length gate; with no anchor hit it falls back to proportion instead.
    static let rewriteThreshold = 0.25
    /// Minimum normalized words for the fuzzy-head step. One- and two-word
    /// heads ("yes", "of the") match everywhere; below three the head step
    /// is noise, so those rows fall through to proportion.
    static let minHeadWords = 3

    static let headWords = 5
    static let headWindow = 12

    /// Word index to resume at in `newPlan`, or 0 for the entry start.
    ///
    /// Exact anchor match first (single hit, then nearest copy), then the
    /// rewrite gate, then the unique fuzzy head, then proportion, then entry
    /// start (0). A present anchor beats the length gate: verbatim sentences
    /// resume where they are no matter how much the rest of the article
    /// grew; the gate fires only when the anchor itself is gone. Exact and
    /// fuzzy hits return the first word of the matched sentence, because
    /// the anchor is sentence-grained.
    /// One build of the match field per call: candidates once, exact hits
    /// once, totals once. Nil when the totals cannot anchor (empty plan or
    /// empty row, divergent sentence lists). `resolve` builds it once for
    /// both the start and the flag; the `resolveWordIndex`/`isRewrite`
    /// wrappers below rebuild per call but stay consistent because the build
    /// is deterministic.
    private static func field(old: ReadingPosition, newPlan: BlockPlan)
        -> (newTotal: Int, candidates: [(words: [String], firstWord: Int)], hits: [(words: [String], firstWord: Int)])?
    {
        let index = SpokenWordNumbering(plan: newPlan)
        let newTotal = index.totalWords
        guard newTotal > 0, old.totalWords > 0 else { return nil }
        // Both lists derive from the same `flatten(blocks)`: one sentence
        // per entry in both. A divergence (same input, deterministic — should
        // not happen) falls to entry start, the safe default, instead of a
        // truncated wrong-sentence resume.
        let sentences = plannedSentences(newPlan)
        // Pure, so no telemetry handle: a debug trap plus the safe-default
        // fallthrough. Both derive from the same `flatten(blocks)`, so a
        // divergence means a real invariant break worth seeing in debug;
        // release still resumes at the entry instead of a wrong sentence.
        #if DEBUG
        if sentences.count != index.firstWordOfUtterance.count {
            assertionFailure("sentences (\(sentences.count)) vs index (\(index.firstWordOfUtterance.count))")
        }
        #endif
        guard sentences.count == index.firstWordOfUtterance.count else { return nil }
        let candidates = zip(sentences, index.firstWordOfUtterance).map { sentence, firstWord in
            (words: normalizedWords(sentence.text), firstWord: firstWord)
        }
        let hits = old.anchorHash.isEmpty ? [] : candidates.filter { anchor(words: $0.words).hash == old.anchorHash }
        return (newTotal, candidates, hits)
    }

    /// Full detail from one shared build of the match field: resume word,
    /// rewrite flag, exact-hit count (nil when the field cannot anchor:
    /// empty plan or row, divergent sentence lists), the new total, and the
    /// single-hit span (nil unless exactly one hit: hit start..<next
    /// sentence start, or newTotal for the last sentence). One build serves
    /// all five so the start and the flag cannot disagree, the fast-path
    /// gate reads the count without a second walk, and the caller reuses
    /// the total instead of walking the plan again.
    /// `resolve` below delegates.
    static func resolveDetailed(old: ReadingPosition, newPlan: BlockPlan)
        -> (start: Int, rewrote: Bool, exactHits: Int?, total: Int, hitSpan: Range<Int>?)
    {
        guard let (newTotal, candidates, hits) = field(old: old, newPlan: newPlan) else {
            return (0, false, nil, 0, nil)
        }
        // A single verbatim hit wins at any delta, including a 90 %
        // rewrite. Intentional per spec exact-first: the sentence the
        // reader stopped in is still there, word for word, so resume
        // stays with it. A one-off short sentence ("Advertisement.")
        // could pull the point mid-article in theory; no shipped rows
        // exist to collide with, and a minimum-length gate waits for
        // real drift data rather than synthetic guesses.
        if hits.count == 1 {
            // Single-hit span: hit start..<next sentence start (or the new
            // total for the last sentence). The fast-path keep in
            // `Store.resolve` needs it to tell a stationary sentence (keep
            // the precise word) from a moved one (follow the hit).
            let hitStart = hits[0].firstWord
            let after = candidates.first(where: { $0.firstWord > hitStart })?.firstWord ?? newTotal
            // `max` guards a zero-word sentence (span would be empty and
            // `contains` always false); the fallback returns hitStart either
            // way, so the guard changes nothing observable.
            return (hitStart, false, 1, newTotal, hitStart..<max(after, hitStart))
        }

        // Ratio clamped in Double before the Int conversion: a corrupt
        // row near Int.max with a small total would otherwise trap.
        let ratio = min(max(Double(max(old.wordIndex, 0)) / Double(old.totalWords), 0), 1)
        let proportional = Int(ratio * Double(newTotal))
        let clampedProportional = min(max(proportional, 0), newTotal - 1)

        if let nearest = hits.min(by: {
            abs($0.firstWord - clampedProportional) < abs($1.firstWord - clampedProportional)
        }) {
            return (nearest.firstWord, false, hits.count, newTotal, nil)
        }

        // Legacy rows predate anchors (v7 backfill left them empty): no
        // anchor means no gate. They fall through to proportion, per the
        // v7 migration note, and the flag stays false for the same input.
        guard !old.anchorHash.isEmpty else { return (clampedProportional, false, 0, newTotal, nil) }

        let delta = Double(abs(newTotal - old.totalWords)) / Double(old.totalWords)
        guard delta < rewriteThreshold else { return (0, true, 0, newTotal, nil) }

        let head = old.anchorHead.split(separator: " ").map(String.init)
        if head.count >= minHeadWords {
            let matches = candidates.filter { headMatches(head, in: $0.words) }
            if matches.count == 1 {
                return (matches[0].firstWord, false, 0, newTotal, nil)
            }
        }

        return (clampedProportional, false, 0, newTotal, nil)
    }

    /// Word index to resume at in `newPlan` plus whether the rewrite gate
    /// fired. Order: exact single hit, nearest copy, rewrite gate, unique
    /// fuzzy head, proportion, entry start (0). A present anchor beats the
    /// length gate; the gate fires only when the anchor itself is gone.
    /// Nil field falls to entry start with no rewrite, the safe default.
    /// Thin wrapper over `resolveDetailed`, kept for the existing tests and
    /// callers. Drops the count and total; they agree with the start and
    /// flag by construction.
    static func resolve(old: ReadingPosition, newPlan: BlockPlan) -> (start: Int, rewrote: Bool) {
        let detailed = resolveDetailed(old: old, newPlan: newPlan)
        return (detailed.start, detailed.rewrote)
    }

    static func resolveWordIndex(old: ReadingPosition, newPlan: BlockPlan) -> Int {
        resolve(old: old, newPlan: newPlan).start
    }

    /// True when the rewrite gate fired: the anchor is gone (no single hit,
    /// no repeated copy) and the length delta reached the threshold. The
    /// caller starts at the top and shows the "article updated" note
    /// (research `spec/library-identity.md` §4); history stays on the row.
    /// Thin wrapper over `resolve`, kept for the existing tests and callers.
    static func isRewrite(old: ReadingPosition, newPlan: BlockPlan) -> Bool {
        resolve(old: old, newPlan: newPlan).rewrote
    }

    /// The anchor for the sentence that contains a global word index.
    static func anchor(wordIndex: Int, index: SpokenWordNumbering, plan: BlockPlan) -> SentenceAnchor {
        guard index.totalWords > 0 else { return .none }
        let sentences = plannedSentences(plan)
        let utteranceIndex = index.utteranceIndex(forWord: wordIndex)
        guard sentences.indices.contains(utteranceIndex) else { return .none }
        return anchor(words: normalizedWords(sentences[utteranceIndex].text))
    }

    /// Unicode letters and digits, lowercased, plus the ASCII apostrophe.
    /// Locale-independent: `lowercased()` without a locale follows the
    /// Unicode default, so the same text anchors the same everywhere.
    /// Canonical-composed first, so NFC and NFD copies of one article share
    /// anchors. Alphabetic-property marks (including Mn like U+0941) stay
    /// inside the token; other combining marks split it. Curly single quotes
    /// (U+2018/2019) fold to the ASCII apostrophe: quote style alone must
    /// not move the anchor.
    static func normalizedWords(_ text: String) -> [String] {
        var words: [String] = []
        var token = ""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.value == 0x2018 || scalar.value == 0x2019 {
                token.unicodeScalars.append(Unicode.Scalar(0x27))
            } else if scalar.properties.isAlphabetic {
                token.unicodeScalars.append(scalar)
            } else if scalar.properties.numericValue != nil || scalar.value == 0x27 {
                token.unicodeScalars.append(scalar)
            } else if !token.isEmpty {
                words.append(token.lowercased())
                token = ""
            }
        }
        if !token.isEmpty {
            words.append(token.lowercased())
        }
        return words
    }

    static func anchor(words: [String]) -> SentenceAnchor {
        guard !words.isEmpty else { return .none }
        let digest = SHA256.hash(data: Data(words.joined(separator: " ").utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return SentenceAnchor(hash: hash, head: words.prefix(headWords).joined(separator: " "))
    }

    /// True when the head words appear in order within the first
    /// `headWindow` words of the candidate. Gaps are allowed.
    static func headMatches(_ head: [String], in words: [String]) -> Bool {
        guard !head.isEmpty else { return false }
        var next = 0
        for word in words.prefix(headWindow) where word == head[next] {
            next += 1
            if next == head.count { return true }
        }
        return false
    }

    /// Spoken sentences in reading order. Same order as `SpokenWordNumbering`
    /// sentence indices and `Document.spokenSentences`.
    static func plannedSentences(_ plan: BlockPlan) -> [Sentence] {
        SpokenWordNumbering.flatten(plan.blocks).flatMap(\.spoken)
    }
}
