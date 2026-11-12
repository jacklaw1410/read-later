import Foundation

/// The classifier's verdict for one block: the decided kind, the confidence
/// (0...1), and the signal that decided it (element name, class, or heuristic).
public struct Classification: Sendable {
    public var kind: BlockKind
    public var confidence: Double
    public var reason: String

    public init(kind: BlockKind, confidence: Double, reason: String) {
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
    }
}

/// Structural first, shape second, bias to speak.
///
/// Element identity decides. Class and role names only break ties between
/// shape readings and never override identity. When nothing decides, the
/// block is prose with low confidence (bias rule: false-speak costs one bad
/// sentence, false-skip loses content). Source of truth:
/// read-later-research/spec/non-prose-classification.md
public enum Classifier {
    static let navClasses: Set<String> = [
        "nav", "navbar", "menu", "menus", "breadcrumb", "breadcrumbs", "footer",
    ]
    static let asideClasses: Set<String> = [
        "infobox", "sidebar", "vcard", "navbox", "ambox",
    ]
    static let pullClasses: Set<String> = [
        "pullquote", "pull-quote", "pull_quote",
    ]
    static let codeClasses: Set<String> = [
        "code", "pre", "hljs", "highlight", "syntax", "sourcecode",
    ]

    /// One-word UI controls (plus the two two-word logins) that are never
    /// article prose. A block whose whole normalised text is one of these is
    /// chrome, not content. The list is fixed and reported with every sweep;
    /// a wider list is not safer (`Comment` is already the riskiest entry).
    static let uiControls: Set<String> = [
        "save", "share", "listen", "subscribe", "follow", "print",
        "comment", "sign in", "log in", "close",
        "like", "bookmark", "download", "menu", "search", "sign up",
    ]

    /// True when the block's whole normalised text is one fixed UI control.
    static func isUIControl(_ text: String) -> Bool {
        uiControls.contains(text.lowercased())
    }

    /// - Parameters:
    ///   - tag: Lowercased element name.
    ///   - classNames: The element's class list.
    ///   - role: The element's `role` attribute, if any.
    ///   - text: The block's own normalised text.
    ///   - linkTextChars: Characters of `text` that sit inside links.
    ///   - lines: Optional pre-split lines (from unnormalised text) for the
    ///     line-structure heuristics. Derived from `text` when absent.
    public static func classify(
        tag: String,
        classNames: [String] = [],
        role: String? = nil,
        text: String,
        linkTextChars: Int = 0,
        lines: [String]? = nil
    ) -> Classification {
        let tag = tag.lowercased()
        let classes = Set(classNames.map { $0.lowercased() })
        let role = (role ?? "").lowercased()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if role == "navigation" {
            return Classification(kind: .nav, confidence: 0.85, reason: "role=navigation")
        }
        if !classes.isDisjoint(with: pullClasses) {
            return Classification(kind: .pullQuote, confidence: 0.85, reason: "pullquote-class")
        }
        if tag != "table", let hit = classes.intersection(navClasses).first {
            return Classification(kind: .nav, confidence: 0.8, reason: "class=\(hit)")
        }

        switch tag {
        case "pre":
            return Classification(kind: .code, confidence: 0.99, reason: "pre")
        case "code":
            return Classification(kind: .code, confidence: 0.9, reason: "code")
        case "table":
            if role == "presentation" {
                return Classification(kind: .aside, confidence: 0.8, reason: "role=presentation")
            }
            if let hit = classes.intersection(asideClasses).first {
                return Classification(kind: .aside, confidence: 0.8, reason: "table.\(hit)")
            }
            return Classification(kind: .table, confidence: 0.95, reason: "table")
        case "figure":
            return Classification(kind: .figure, confidence: 0.95, reason: "figure")
        case "figcaption":
            return Classification(kind: .figure, confidence: 0.9, reason: "figcaption")
        case "img":
            return Classification(kind: .image, confidence: 0.99, reason: "img")
        case "math":
            return Classification(kind: .math, confidence: 0.95, reason: "math")
        case "iframe", "video", "audio", "object", "embed":
            return Classification(kind: .embed, confidence: 0.9, reason: tag)
        case "blockquote":
            return Classification(kind: .quote, confidence: 0.92, reason: "blockquote")
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return Classification(kind: .heading, confidence: 0.95, reason: tag)
        case "aside":
            return Classification(kind: .aside, confidence: 0.9, reason: "aside")
        case "nav":
            return Classification(kind: .nav, confidence: 0.85, reason: "nav")
        case "header", "footer":
            return Classification(kind: .nav, confidence: 0.75, reason: tag)
        case "ul", "ol":
            return Classification(kind: .list, confidence: 0.95, reason: tag)
        case "dl":
            return Classification(kind: .list, confidence: 0.8, reason: "dl")
        case "li":
            return Classification(kind: .list, confidence: 0.9, reason: "li")
        case "p", "dt", "dd":
            if isUIControl(trimmed) {
                return Classification(kind: .nav, confidence: 0.9, reason: "ui-control")
            }
            if cjkRatio(in: trimmed) >= 0.3 {
                return Classification(kind: .cjk, confidence: 0.85, reason: "cjk-ratio")
            }
            if wrapsCode(trimmed, lines: lines) {
                return Classification(kind: .code, confidence: 0.75, reason: "code-shape")
            }
            return Classification(kind: .prose, confidence: 0.98, reason: tag)
        default:
            return shape(tag: tag, classes: classes, text: trimmed, linkTextChars: linkTextChars, lines: lines)
        }
    }

    // MARK: - Shape heuristics (div-soup and unknown elements only)

    static func shape(
        tag: String,
        classes: Set<String>,
        text: String,
        linkTextChars: Int,
        lines: [String]?
    ) -> Classification {
        guard !text.isEmpty else {
            return Classification(kind: .prose, confidence: 0.5, reason: "empty")
        }
        if isUIControl(text) {
            return Classification(kind: .nav, confidence: 0.9, reason: "ui-control")
        }
        let resolved = lines ?? splitLines(text)
        if hasPromptPrefix(resolved) {
            return Classification(kind: .code, confidence: 0.8, reason: "prompt-prefix")
        }
        let (density, symbols) = symbolDensity(in: text)
        if resolved.count >= 2 && density >= 0.08 && symbols >= 6 {
            return Classification(kind: .code, confidence: 0.75, reason: "symbol-density")
        }
        if resolved.count >= 3 && trailingSemicolonRatio(resolved) >= 0.5 {
            return Classification(kind: .code, confidence: 0.75, reason: "trailing-semicolons")
        }
        if resolved.count >= 3 && lineLengthVariance(resolved) >= 0.6 {
            return Classification(kind: .code, confidence: 0.7, reason: "line-variance")
        }
        if cjkRatio(in: text) >= 0.3 {
            return Classification(kind: .cjk, confidence: 0.85, reason: "cjk-ratio")
        }
        let total = text.filter({ !$0.isWhitespace }).count
        if total > 0 && Double(linkTextChars) / Double(total) >= 0.5 {
            return Classification(kind: .nav, confidence: 0.75, reason: "link-density")
        }
        if isShortLineList(resolved) {
            if !classes.intersection(navClasses).isEmpty {
                return Classification(kind: .nav, confidence: 0.7, reason: "short-lines")
            }
            return Classification(kind: .list, confidence: 0.7, reason: "short-lines")
        }
        if !classes.intersection(codeClasses).isEmpty && symbols >= 3 {
            return Classification(kind: .code, confidence: 0.8, reason: "class-code")
        }
        return Classification(kind: .prose, confidence: 0.6, reason: "shape-unsure")
    }

    /// A `<p>` that genuinely wraps a code block has multiple lines or a
    /// prompt prefix. A single line with inline code is prose.
    static func wrapsCode(_ text: String, lines: [String]?) -> Bool {
        let resolved = lines ?? splitLines(text)
        if hasPromptPrefix(resolved) { return true }
        guard resolved.count >= 2 else { return false }
        let (density, symbols) = symbolDensity(in: text)
        if density >= 0.08 && symbols >= 6 { return true }
        if resolved.count >= 3 && trailingSemicolonRatio(resolved) >= 0.5 { return true }
        return false
    }

    static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Any line starts with `>>>`, `...`, `def `, `class `, `SELECT `,
    /// `function `, or `$ ` (dollar-space: `$5` is prose, not a prompt).
    static func hasPromptPrefix(_ lines: [String]) -> Bool {
        lines.contains { line in
            line.hasPrefix(">>>") || line.hasPrefix("...")
                || line.hasPrefix("def ") || line.hasPrefix("class ")
                || line.hasPrefix("SELECT ") || line.hasPrefix("function ")
                || line.hasPrefix("$ ") || line == "$"
        }
    }

    /// Ratio and raw count of `{}();=<>:` characters over non-whitespace text.
    public static func symbolDensity(in text: String) -> (ratio: Double, count: Int) {
        let symbols: Set<Character> = ["{", "}", "(", ")", ";", "=", "<", ">", ":"]
        var count = 0
        var total = 0
        for c in text {
            if c.isWhitespace { continue }
            total += 1
            if symbols.contains(c) { count += 1 }
        }
        guard total > 0 else { return (0, 0) }
        return (Double(count) / Double(total), count)
    }

    static func trailingSemicolonRatio(_ lines: [String]) -> Double {
        guard !lines.isEmpty else { return 0 }
        let hit = lines.filter { $0.hasSuffix(";") }.count
        return Double(hit) / Double(lines.count)
    }

    /// Stddev(line lengths) / mean. Ragged short lines over prose score low;
    /// code with one long line among short ones scores high.
    static func lineLengthVariance(_ lines: [String]) -> Double {
        guard lines.count >= 3 else { return 0 }
        let lengths = lines.map { Double($0.count) }
        let mean = lengths.reduce(0, +) / Double(lengths.count)
        guard mean > 0 else { return 0 }
        let variance = lengths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lengths.count)
        return variance.squareRoot() / mean
    }

    /// CJK characters over non-whitespace characters. Hiragana, katakana,
    /// Han (all planes), and Hangul count; fullwidth Latin does not.
    public static func cjkRatio(in text: String) -> Double {
        var cjk = 0
        var total = 0
        for scalar in text.unicodeScalars {
            if scalar == " " || CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            total += 1
            let v = scalar.value
            switch v {
            case 0x3040...0x30FF, // hiragana + katakana
                 0x3400...0x4DBF, // CJK extension A
                 0x4E00...0x9FFF, // CJK unified
                 0x20000...0x2A6DF, // CJK extension B
                 0x2A6E0...0x2EBEF, // CJK extensions C-E
                 0x30000...0x3134F, // CJK extensions G-I
                 0x1100...0x11FF, // hangul jamo
                 0xAC00...0xD7AF: // hangul syllables
                cjk += 1
            default:
                break
            }
        }
        guard total > 0 else { return 0 }
        return Double(cjk) / Double(total)
    }

    /// Three or more short lines with no sentence-final punctuation.
    static func isShortLineList(_ lines: [String]) -> Bool {
        guard lines.count >= 3 else { return false }
        let sorted = lines.map { $0.count }.sorted()
        let median = sorted[sorted.count / 2]
        guard median <= 40 else { return false }
        return lines.allSatisfy { line in
            guard let last = line.last else { return false }
            return last != "." && last != "!" && last != "?" && last != "…"
        }
    }
}
