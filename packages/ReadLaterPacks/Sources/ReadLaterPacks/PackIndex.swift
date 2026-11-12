import Foundation
import SQLite3

/// One headword row read back from the on-disk index. Empty phonetic and
/// part-of-speech fields arrive as nil, the shape the cards expect.
public struct PackEntry: Sendable, Equatable {
    public var word: String
    public var phonetic: String?
    public var partOfSpeech: String?
    public var gloss: String

    public init(word: String, phonetic: String?, partOfSpeech: String?, gloss: String) {
        self.word = word
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.gloss = gloss
    }
}

public enum PackIndexError: Error, Sendable, Equatable {
    case gunzip(String)
    case read(String)
    case sqlite(String)
}

/// Builds the lookup index at install time. The archive is gzipped TSV, one
/// headword per line: `word \t phonetic \t pos \t gloss` (lexical) or
/// `word \t gloss` (gloss). The index is SQLite, one row per headword keyed
/// by the normalised form, so lookup seeks instead of loading 770,238
/// entries into memory.
public enum PackIndexBuilder {
    /// Unpacks `archiveURL` (`<id>.pack.gz`) and writes `<id>.sqlite` into
    /// `directory`. Returns the index URL. Throws `PackIndexError`, which the
    /// installer maps to `failedCorrupt`.
    public static func build(archiveURL: URL, directory: URL) throws -> URL {
        let base = archiveURL.lastPathComponent
        guard base.hasSuffix(".pack.gz") else {
            throw PackIndexError.read("unexpected archive name '\(base)'")
        }
        let id = String(base.dropLast(".pack.gz".count))
        guard !id.isEmpty else {
            throw PackIndexError.read("unexpected archive name '\(base)'")
        }
        let tsvURL = directory.appendingPathComponent("\(id).tsv.tmp")
        let sqliteURL = directory.appendingPathComponent("\(id).sqlite")
        try? FileManager.default.removeItem(at: tsvURL)
        try? FileManager.default.removeItem(at: sqliteURL)
        do {
            try Gzip.gunzip(archive: archiveURL, to: tsvURL)
        } catch let error as GzipError {
            throw PackIndexError.gunzip("\(error)")
        }
        do {
            try index(tsvURL: tsvURL, sqliteURL: sqliteURL)
        } catch {
            try? FileManager.default.removeItem(at: tsvURL)
            try? FileManager.default.removeItem(at: sqliteURL)
            throw error
        }
        try? FileManager.default.removeItem(at: tsvURL)
        return sqliteURL
    }

    static func index(tsvURL: URL, sqliteURL: URL) throws {
        let text: String
        do {
            text = try String(contentsOf: tsvURL, encoding: .utf8)
        } catch {
            throw PackIndexError.read("cannot read unpacked pack: \(error.localizedDescription)")
        }
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path, &db) == SQLITE_OK, let db else {
            throw PackIndexError.sqlite("cannot open index")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE words(key TEXT PRIMARY KEY, word TEXT NOT NULL, phonetic TEXT, pos TEXT, gloss TEXT NOT NULL)")
        try exec(db, "BEGIN")
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO words(key, word, phonetic, pos, gloss) VALUES(?, ?, ?, ?, ?)", -1, &insert, nil) == SQLITE_OK, let insert else {
            throw PackIndexError.sqlite(lastError(db))
        }
        defer { sqlite3_finalize(insert) }
        var rows = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = parse(line: line) else { continue }
            bindText(insert, 1, row.key)
            bindText(insert, 2, row.word)
            bindNullOrText(insert, 3, row.phonetic)
            bindNullOrText(insert, 4, row.partOfSpeech)
            bindText(insert, 5, row.gloss)
            guard sqlite3_step(insert) == SQLITE_DONE else {
                throw PackIndexError.sqlite(lastError(db))
            }
            sqlite3_reset(insert)
            rows += 1
        }
        guard rows > 0 else {
            throw PackIndexError.sqlite("no headwords in pack")
        }
        try exec(db, "COMMIT")
        committed = true
    }

    /// Parses one TSV record. Returns nil for blank or unusable lines, which
    /// are skipped, not fatal: one bad line is not a corrupt pack.
    static func parse(line: Substring) -> (key: String, word: String, phonetic: String?, partOfSpeech: String?, gloss: String)? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let word = parts[0]
        let key = PackIndexStore.normalize(word)
        guard !key.isEmpty else { return nil }
        let phonetic: String?
        let partOfSpeech: String?
        let gloss: String
        if parts.count >= 4 {
            phonetic = parts[1].isEmpty ? nil : parts[1]
            partOfSpeech = parts[2].isEmpty ? nil : parts[2]
            gloss = parts[3...].joined(separator: "\t")
        } else {
            phonetic = nil
            partOfSpeech = nil
            gloss = parts[1...].joined(separator: "\t")
        }
        // ECDICT senses arrive with literal backslash-n escapes; the card
        // renders real line breaks.
        let cleanGloss = gloss.replacingOccurrences(of: "\\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGloss.isEmpty else { return nil }
        return (key, word, phonetic, partOfSpeech, cleanGloss)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw PackIndexError.sqlite(lastError(db))
        }
    }

    private static func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { ptr in
            sqlite3_bind_text(stmt, index, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private static func bindNullOrText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}

/// What the card shows for one tapped word. The tapped spelling is always
/// the headword; `subtitle` carries the stored headword when it differs
/// (accent normalisation) or the base word a pointer gloss resolves to.
public struct DisplayEntry: Sendable, Equatable {
    public var tapped: String
    public var subtitle: String?
    public var gloss: String
    public var phonetic: String?
    public var partOfSpeech: String?

    public init(tapped: String, subtitle: String?, gloss: String, phonetic: String?, partOfSpeech: String?) {
        self.tapped = tapped
        self.subtitle = subtitle
        self.gloss = gloss
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
    }
}

/// Reads one headword at a time from the installed SQLite index. The struct
/// holds only the file URL; every lookup opens, seeks, and closes, so the
/// reader thread never carries the pack and nothing on this path touches the
/// network.
public struct PackIndexStore: Sendable {
    public let sqliteURL: URL

    public init(sqliteURL: URL) {
        self.sqliteURL = sqliteURL
    }

    public func entry(for word: String) -> PackEntry? {
        let key = Self.normalize(word)
        guard !key.isEmpty else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path, &db) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT word, phonetic, pos, gloss FROM words WHERE key = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        _ = key.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let wordPtr = sqlite3_column_text(stmt, 0),
              let glossPtr = sqlite3_column_text(stmt, 3)
        else { return nil }
        return PackEntry(
            word: String(cString: wordPtr),
            phonetic: columnString(stmt, 1),
            partOfSpeech: columnString(stmt, 2),
            gloss: String(cString: glossPtr)
        )
    }

    private func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index)
        else { return nil }
        let text = String(cString: ptr)
        return text.isEmpty ? nil : text
    }

    /// Lowercase, accent-folded, apostrophe-normalised. `café` and `CAFE`
    /// both reach the `cafe` row.
    public static func normalize(_ word: String) -> String {
        let nfkd = word.decomposedStringWithCompatibilityMapping
        let stripped = nfkd.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        return text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored headword to show under the tapped spelling, or nil when no
    /// subtitle is needed: identical, or differing only in case. The card
    /// shows the tapped spelling as the headword either way.
    public static func accentSubtitle(tapped: String, stored: String) -> String? {
        if tapped == stored { return nil }
        if tapped.lowercased() == stored.lowercased() { return nil }
        guard normalize(tapped) == normalize(stored) else { return nil }
        return stored
    }

    /// The card-ready entry for a tapped word. Applies the three gloss rules
    /// (spec/dictionary-packs.md §4): a pointer gloss resolves through the
    /// base word with the tapped spelling kept as the headword, mixed entries
    /// show untagged lines first with at most one tagged line, and grammar
    /// parentheticals never reach the card. Pointer resolution follows at
    /// most four hops and stops on a loop; when the base word is missing, the
    /// tapped word's own gloss is shown cleaned.
    public func displayEntry(for word: String) -> DisplayEntry? {
        guard let stored = entry(for: word) else { return nil }
        if GlossRenderer.isPointerOnly(stored.gloss),
           let resolved = resolvePointer(from: stored, seen: [Self.normalize(word)])
        {
            return DisplayEntry(
                tapped: word,
                subtitle: resolved.word,
                gloss: GlossRenderer.render(gloss: resolved.gloss),
                phonetic: resolved.phonetic,
                partOfSpeech: resolved.partOfSpeech
            )
        }
        return DisplayEntry(
            tapped: word,
            subtitle: Self.accentSubtitle(tapped: word, stored: stored.word),
            gloss: GlossRenderer.render(gloss: stored.gloss),
            phonetic: stored.phonetic,
            partOfSpeech: stored.partOfSpeech
        )
    }

    private func resolvePointer(from entry: PackEntry, seen: Set<String>, hops: Int = 4) -> PackEntry? {
        guard hops > 0, let base = GlossRenderer.pointerBaseWord(in: entry.gloss) else { return nil }
        let key = Self.normalize(base)
        guard !key.isEmpty, !seen.contains(key), let next = self.entry(for: base) else { return nil }
        if GlossRenderer.isPointerOnly(next.gloss) {
            return resolvePointer(from: next, seen: seen.union([key]), hops: hops - 1)
        }
        return next
    }
}
