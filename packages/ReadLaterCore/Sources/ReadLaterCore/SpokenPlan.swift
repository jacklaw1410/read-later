import Foundation

/// Sentence splitting and spoken-plan assembly.
///
/// The public surface lives in `Contracts.swift`; the three entry points there
/// delegate to this engine so the contract file keeps only signatures.
enum SpokenPlanEngine {
    /// Kinds that render reduced-ink and contribute zero utterances.
    ///
    /// F19 1.9 (2026-11-13, decided): headings speak, so `.heading` is not
    /// here. It was removed from this set in the same change that gave
    /// headings spoken slots; the research spec still lists headings as
    /// never-spoken and needs the amendment
    /// (`spec/inline-content-rules.md:30`,
    /// `spec/non-prose-classification.md` failure mode 6).
    ///
    /// Everything else speaks: prose, quote, list, cjk, heading.
    static let neverSpoken: Set<BlockKind> = [
        .code, .table, .image, .figure, .math, .embed, .nav,
        .pullQuote, .aside, .footnoteMarker, .footnoteBody,
    ]

    /// Abbreviations whose period never ends a sentence. Multi-part entries
    /// (containing a dot) still end a sentence when a new one visibly starts.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "no",
        "eg", "ie", "vs", "etc", "al", "ave", "blvd", "co", "inc", "ltd",
        "dept", "gen", "rep", "sen", "gov", "lt", "col", "capt", "rd",
        "fig", "eq", "ch", "sec", "vol", "cf",
        "am", "pm", "a.m", "p.m", "e.g", "i.e", "u.s", "u.k",
    ]

    /// Splits text into sentences at `.`, `!`, `?`, `…` (and doubled forms)
    /// plus paragraph breaks. Every returned sentence is an exact character
    /// slice of the source: `text[offset..<offset+length] == sentence.text`.
    static func sentences(in text: String) -> [Sentence] {
        let chars = Array(text)
        let end = chars.count
        var out: [Sentence] = []
        var start = 0
        var i = 0

        func isBreak(_ c: Character) -> Bool {
            c == "\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}"
        }

        func emit(_ from: Int, _ to: Int) {
            var a = from
            var b = to
            while a < b && chars[a].isWhitespace { a += 1 }
            while b > a && chars[b - 1].isWhitespace { b -= 1 }
            guard a < b else { return }
            out.append(Sentence(offset: a, length: b - a, text: String(chars[a..<b])))
        }

        while i < end {
            let c = chars[i]
            if isBreak(c) {
                var j = i + 1
                while j < end && isBreak(chars[j]) { j += 1 }
                emit(start, j)
                start = j
                i = j
                continue
            }
            if c == "." || c == "!" || c == "?" || c == "…" {
                var j = i + 1
                while j < end && (chars[j] == "." || chars[j] == "!" || chars[j] == "?" || chars[j] == "…") {
                    j += 1
                }
                let protectedDot = c == "." && isProtectedDot(chars, at: i, end: end)
                var k = j
                while k < end && isCloser(chars[k]) { k += 1 }
                let boundary: Bool
                if protectedDot {
                    boundary = false
                } else if k >= end {
                    boundary = true
                } else {
                    boundary = chars[k].isWhitespace
                }
                if boundary {
                    emit(start, k)
                    start = k
                    i = k
                } else {
                    i = j
                }
                continue
            }
            i += 1
        }
        emit(start, end)
        return out
    }

    /// Fills `spoken` on every block (recursively), then returns a plan with
    /// counts set. Skipped kinds keep empty `spoken` and are logged in
    /// `skipped`, matching the block-plan schema.
    static func build(blocks: [Block], source: String, sourceSHA256: String) -> BlockPlan {
        var filled = blocks
        for index in filled.indices {
            Self.fill(&filled[index])
        }
        var sentenceCount = 0
        var spokenWords = 0
        var skipped: [SkippedBlock] = []
        func visit(_ block: Block) {
            sentenceCount += block.spoken.count
            for sentence in block.spoken {
                spokenWords += wordCount(in: sentence.text)
            }
            if neverSpoken.contains(block.kind)
                && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                skipped.append(SkippedBlock(
                    blockID: block.id,
                    kind: block.kind,
                    confidence: block.confidence,
                    reason: block.reason,
                    words: wordCount(in: block.text)
                ))
            }
            for child in block.children { visit(child) }
        }
        for block in filled { visit(block) }
        return BlockPlan(
            version: 1,
            source: source,
            sourceSHA256: sourceSHA256,
            sentenceCount: sentenceCount,
            spokenWords: spokenWords,
            validationFailures: SpokenPlanCheck.violations(in: filled).count,
            blocks: filled,
            skipped: skipped
        )
    }

    // MARK: - Helpers (module-internal, shared with the invariant)

    /// Recursively fills `spoken`, leaving skipped kinds and empty texts empty.
    static func fill(_ block: inout Block) {
        for index in block.children.indices {
            fill(&block.children[index])
        }
        if neverSpoken.contains(block.kind) {
            block.spoken = []
            return
        }
        if block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block.spoken = []
            return
        }
        block.spoken = sentences(in: block.text)
    }

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Character-offset slice. Offsets throughout the plan count Characters
    /// (extended grapheme clusters), matching `String.count` and `Array(text)`.
    static func slice(_ text: String, offset: Int, length: Int) -> String? {
        guard offset >= 0, length > 0, offset + length <= text.count else { return nil }
        let a = text.index(text.startIndex, offsetBy: offset)
        let b = text.index(a, offsetBy: length)
        return String(text[a..<b])
    }

    static func isCloser(_ c: Character) -> Bool {
        c == "\"" || c == "'" || c == "\u{201C}" || c == "\u{201D}"
            || c == "\u{2018}" || c == "\u{2019}" || c == ")" || c == "]" || c == "}"
    }

    /// A period that must not split: decimals, initials, abbreviations.
    static func isProtectedDot(_ chars: [Character], at index: Int, end: Int) -> Bool {
        let prev: Character? = index > 0 ? chars[index - 1] : nil
        let next: Character? = index + 1 < end ? chars[index + 1] : nil
        if let p = prev, let n = next, p.isNumber && n.isNumber { return true }
        var t = index - 1
        while t >= 0 && (chars[t].isLetter || chars[t] == ".") { t -= 1 }
        let token = String(chars[(t + 1)..<index]).lowercased()
        guard !token.isEmpty else { return false }
        if token.count == 1 { return true }
        guard abbreviations.contains(token) else { return false }
        if token.contains(".") {
            // Multi-part abbreviation (U.S., e.g.): still a boundary when a
            // new sentence visibly starts after it.
            var k = index + 1
            while k < end && (chars[k] == " " || chars[k] == "\t") { k += 1 }
            if k >= end { return false }
            let d = chars[k]
            if d == "\n" || d == "\r" || d == "\u{2028}" || d == "\u{2029}" { return false }
            return !d.isUppercase
        }
        return true
    }
}
