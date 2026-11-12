import Foundation

/// Lookup-time gloss rules. The pack ships source data, not card copy: the
/// characters are right and the sense presentation is not
/// (read-later-research/spec/dictionary-packs.md §4, "Gloss rendering").
///
/// Three rules apply here, never in the card, and none of them changes the
/// pack or needs a new download:
///
/// 1. A gloss that holds only a pointer (`vi., vt. ovate的變形`) is resolved
///    by looking up the base word. The tapped spelling stays the headword and
///    the base word becomes the subtitle, the same shape as the accent
///    variant (`café` shown over `cafe`).
/// 2. When an entry holds untagged and domain-tagged lines (`us` ships
///    `pron. 我們` plus `[經] 美國`), the untagged lines come first and at
///    most one tagged line follows.
/// 3. A grammar parenthetical that names the base form (`摻奶的( milky的最高級 )`)
///    is drawn without the note.
///
/// The shipped text also carries literal `\n` escapes and inline
/// part-of-speech tags (`n.`, `vi., vt.`) in the ECDICT style. Neither may
/// reach the card raw. Sense order never changes: these rules remove noise,
/// they do not re-rank meaning.
public enum GlossRenderer {
    /// The card shows at most this many gloss lines. Four covers a mixed entry
    /// (untagged lines plus one tagged line) with headroom; longer entries
    /// are cut, not reordered.
    public static let maxLines = 4

    /// Inflection phrases that mark a pointer gloss or a grammar note.
    public static let pointerPhrases = [
        "的變形", "的最高級", "的比較級", "的複數", "的複數形式",
        "的過去式", "的過去分詞", "的現在分詞", "的第三人稱單數",
    ]

    /// Inline part-of-speech abbreviations in the ECDICT style.
    static let posTags: Set<String> = [
        "abbr", "adj", "adv", "art", "aux", "conj", "inf", "int", "interj",
        "num", "past", "pl", "pp", "pref", "pres", "prep", "pron", "suf",
        "a", "n", "v", "vi", "vt",
    ]

    /// Splits a stored gloss into sense lines. Handles both the real newlines
    /// the index builder writes and the literal `\n` escapes still carried by
    /// older indexes and the bundled demo.
    public static func splitLines(_ gloss: String) -> [String] {
        gloss.replacingOccurrences(of: "\\n", with: "\n").split(separator: "\n").map(String.init)
    }

    /// A domain-tagged line starts with a bracket tag such as `[經]` or
    /// `[計]`. The tag is at most six characters, matching the pack sweep.
    public static func isTagged(_ line: String) -> Bool {
        guard line.hasPrefix("[") else { return false }
        guard let close = line.firstIndex(of: "]") else { return false }
        let inner = line[line.index(after: line.startIndex) ..< close]
        return !inner.isEmpty && inner.count <= 6 && !inner.contains("[")
    }

    /// Removes a leading `n.`, `vi., vt.` or similar ECDICT tag. Consumes one
    /// run of abbreviations with their comma and semicolon separators, then
    /// stops: anything else at the line start is sense text.
    public static func stripInlinePOS(_ line: String) -> String {
        var rest = line[...]
        while true {
            var scan = rest
            while let first = scan.first, first == " " { scan = scan.dropFirst() }
            var letters = ""
            var cursor = scan.startIndex
            while cursor < scan.endIndex, scan[cursor].isLetter {
                letters.append(scan[cursor])
                cursor = scan.index(after: cursor)
            }
            guard !letters.isEmpty, posTags.contains(letters.lowercased()),
                  cursor < scan.endIndex, scan[cursor] == "."
            else { return String(rest).trimmingCharacters(in: .whitespaces) }
            rest = scan[scan.index(after: cursor)...]
            while let first = rest.first, first == " " || first == "," || first == ";" {
                rest = rest.dropFirst()
            }
        }
    }

    /// Removes a balanced parenthetical that names the base form, e.g.
    /// `( milky的最高級 )` or `(a-frame 的複數)`. A parenthetical without one
    /// of the pointer phrases stays: `(very best)` and `(Acome)人名` are
    /// sense text, not grammar notes.
    public static func stripGrammarParenthetical(_ line: String) -> String {
        var out = ""
        var rest = line[...]
        while let open = rest.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            let closer: Character = rest[open] == "(" ? ")" : "）"
            guard let close = rest[rest.index(after: open)...].firstIndex(of: closer) else {
                break
            }
            let inner = rest[rest.index(after: open) ..< close]
            out += rest[..<open]
            if !pointerPhrases.contains(where: { inner.contains($0) }) {
                out += rest[open ... close]
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return collapseSpaces(out).trimmingCharacters(in: .whitespaces)
    }

    /// One line as the card shows it: grammar note out, inline POS out, a
    /// leading `=` cross-reference marker out, whitespace tidy.
    public static func cleanLine(_ line: String) -> String {
        var text = stripGrammarParenthetical(line).trimmingCharacters(in: .whitespaces)
        text = stripInlinePOS(text)
        while text.hasPrefix("=") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return collapseSpaces(text).trimmingCharacters(in: .whitespaces)
    }

    /// The base word a pointer gloss points at, or nil when the gloss is not
    /// a pointer. `vi., vt. ovate的變形` gives `ovate`; `(a-frame 的複數)`
    /// gives `a-frame`. Case is kept: the lookup normalises it.
    public static func pointerBaseWord(in gloss: String) -> String? {
        let text = removeBracketTags(gloss).replacingOccurrences(of: "\\n", with: " ")
        guard let hit = pointerPhrases.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        var head = stripInlinePOS(String(text[..<hit.lowerBound]).trimmingCharacters(in: .whitespaces))
        while head.hasSuffix("(") || head.hasSuffix("（") || head.hasSuffix(" ") {
            head = String(head.dropLast())
        }
        var token = ""
        for scalar in head.unicodeScalars.reversed() {
            let c = Character(scalar)
            let isBaseChar = (c.isASCII && c.isLetter) || c == "'" || c == "-"
            if isBaseChar {
                token.append(c)
            } else if !token.isEmpty {
                break
            }
        }
        let base = String(token.reversed())
        return base.isEmpty ? nil : base
    }

    /// True when the gloss holds only a pointer: it names a base word and
    /// carries no Chinese characters of its own. `ovated` qualifies;
    /// `a-frames` does not, because `(a-frame 的複數) [機] A型架` also ships
    /// the sense `A型架`, which the card then shows instead.
    public static func isPointerOnly(_ gloss: String) -> Bool {
        guard pointerBaseWord(in: gloss) != nil else { return false }
        var core = removeBracketTags(gloss)
        core = removePointerParentheticals(core)
        for phrase in pointerPhrases { core = core.replacingOccurrences(of: phrase, with: "") }
        return !containsCJK(core)
    }

    /// The gloss lines as the card shows them: cleaned, untagged first with
    /// at most one tagged line after, capped at `maxLines`. Sense order
    /// otherwise stays as the source gives it.
    public static func renderLines(gloss: String) -> [String] {
        let lines = splitLines(gloss).map(cleanLine).filter { !$0.isEmpty }
        let untagged = lines.filter { !isTagged($0) }
        let tagged = lines.filter(isTagged)
        // A tagged line that repeats an untagged sense word for word adds no
        // meaning, and the card has four lines to spend: `算盤` plus
        // `[計] 算盤` is one sense shown twice. Skip those and take the next.
        let seen = Set(untagged.map(senseKey))
        let fresh = tagged.filter { !seen.contains(senseKey($0)) }
        let ordered = untagged.isEmpty ? tagged : untagged + fresh.prefix(1)
        return Array(ordered.prefix(maxLines))
    }

    /// The sense text with the domain tag, spacing and punctuation removed,
    /// so two spellings of one sense compare equal.
    static func senseKey(_ line: String) -> String {
        removeBracketTags(line)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
            .lowercased()
    }

    /// The exact string the card shows for one gloss.
    public static func render(gloss: String) -> String {
        renderLines(gloss: gloss).joined(separator: "\n")
    }

    // MARK: - Private

    static func removeBracketTags(_ text: String) -> String {
        var out = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[rest.index(after: open)...].firstIndex(of: "]") else { break }
            out += rest[..<open]
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    static func removePointerParentheticals(_ text: String) -> String {
        var out = ""
        var rest = text[...]
        while let open = rest.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            let closer: Character = rest[open] == "(" ? ")" : "）"
            guard let close = rest[rest.index(after: open)...].firstIndex(of: closer) else { break }
            out += rest[..<open]
            let inner = rest[rest.index(after: open) ..< close]
            if !pointerPhrases.contains(where: { inner.contains($0) }) {
                out += rest[open ... close]
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.value {
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2A6DF:
                return true
            default:
                return false
            }
        }
    }

    static func collapseSpaces(_ text: String) -> String {
        var out = ""
        var inSpace = false
        for c in text {
            if c == " " || c == "\t" {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(c)
                inSpace = false
            }
        }
        return out
    }
}
