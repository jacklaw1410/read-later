import Foundation
import GRDB
import ReadLaterCore

/// One saved phrase matched by a full-text query, best match first.
public struct PhraseSearchResult: Sendable, Hashable {
    public var phrase: Phrase
    /// BM25 rank. Lower scores sort first.
    public var rank: Double

    public init(phrase: Phrase, rank: Double) {
        self.phrase = phrase
        self.rank = rank
    }
}

extension Store {
    /// Full-text search over saved phrases (word and gloss), ranked by BM25.
    ///
    /// Every term is treated as a prefix query, so `atten` and `atten*`
    /// both match `attention`. Input is reduced to alphanumeric tokens and
    /// each token is double-quoted, so FTS5 syntax characters in user input
    /// (quotes, `*`, `OR`, `:`) can never break or hijack the query.
    /// A query with no usable tokens returns no rows without touching FTS5.
    public func searchPhrases(matching query: String, limit: Int = 50) throws -> [PhraseSearchResult] {
        guard let match = ftsMatchExpression(for: query) else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS id, p.word AS word, p.gloss AS gloss,
                       p.source AS source, p.created_at AS created_at,
                       bm25(phrase_ft) AS rank
                FROM phrase_ft JOIN phrase p ON p.rowid = phrase_ft.rowid
                WHERE phrase_ft MATCH ?
                ORDER BY rank LIMIT ?
                """, arguments: [match, limit])
            return try rows.map { row in
                PhraseSearchResult(phrase: try Store.decodePhrase(row: row), rank: row["rank"])
            }
        }
    }
}

/// Builds a safe FTS5 MATCH expression: one double-quoted prefix term per
/// alphanumeric token, terms combined with AND. Returns nil when the query
/// holds no usable token.
func ftsMatchExpression(for query: String) -> String? {
    let terms = query.split(whereSeparator: \.isWhitespace).compactMap { part -> String? in
        let cleaned = String(String.UnicodeScalarView(
            part.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        guard !cleaned.isEmpty else { return nil }
        return "\"\(cleaned.replacingOccurrences(of: "\"", with: "\"\""))\"*"
    }
    guard !terms.isEmpty else { return nil }
    return terms.joined(separator: " ")
}
