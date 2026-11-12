import CryptoKit
import Foundation
import ReadLaterCore

/// Splits pasted text into paragraphs. One paragraph becomes one prose block.
public enum PasteLoader {
    /// Splits text on one or more blank lines, collapses internal newlines to
    /// a space, and returns a document sourced as pasted text. Empty input
    /// returns nil.
    public static func document(from text: String, title: String?) -> Document? {
        let paragraphs = Self.paragraphs(from: text)
        guard !paragraphs.isEmpty else { return nil }
        var blocks: [Block] = []
        for (offset, paragraph) in paragraphs.enumerated() {
            blocks.append(Block(
                id: offset + 1,
                kind: .prose,
                confidence: 0.9,
                reason: "source: pasted text",
                text: paragraph
            ))
        }
        let plan = SpokenPlanBuilder.build(
            blocks: blocks,
            source: "pasted text",
            sourceSHA256: Self.sha256(text)
        )
        return Document(
            url: nil,
            title: title ?? Self.derivedTitle(from: text),
            plan: plan
        )
    }

    /// Splits on blank lines, trims each line, and joins wrapped lines with
    /// one space. Blank lines and stray spaces never produce empty blocks.
    public static func paragraphs(from text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            out.append(current.joined(separator: " "))
            current = []
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else {
                current.append(trimmed)
            }
        }
        flush()
        return out
    }

    /// The first words of the text, trimmed to six words with an ellipsis.
    /// Short text keeps its words with no ellipsis.
    public static func derivedTitle(from text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 6 else { return words.joined(separator: " ") }
        return words.prefix(6).joined(separator: " ") + "…"
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
