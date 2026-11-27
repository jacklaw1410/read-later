import GRDB

/// Table and column names for the local-first store.
///
/// The schema holds saved documents, saved phrases, where each phrase was
/// seen, and an operation log. Sync replays the log; it never mirrors a store.
/// One file on disk, WAL mode, foreign keys on (see `Store`).
enum Schema {
    static let document = "document"
    static let phrase = "phrase"
    static let phraseOccurrence = "phrase_occurrence"
    static let syncOplog = "syncoplog"
    /// Pre-v6 table name. Only the v1 creation and the v6 rename use it.
    static let legacyChangelog = "changelog"
    static let phraseFTS = "phrase_ft"
    static let readingPosition = "reading_position"

    /// Creates the v1 tables. The block plan is stored as JSON (`plan_json`)
    /// because it is a versioned contract, not a set of columns.
    static func createBaseTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE document(
                id TEXT PRIMARY KEY,
                url TEXT,
                title TEXT,
                added_at REAL,
                plan_json TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE phrase(
                id TEXT PRIMARY KEY,
                word TEXT NOT NULL,
                gloss TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE phrase_occurrence(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                phrase_id TEXT NOT NULL REFERENCES phrase(id) ON DELETE CASCADE,
                document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
                block_id INTEGER NOT NULL,
                char_offset INTEGER NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE \(Schema.legacyChangelog)(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                device TEXT NOT NULL,
                "at" REAL NOT NULL,
                op TEXT NOT NULL,
                payload TEXT NOT NULL
            )
            """)
    }

    /// Creates the FTS5 index over `phrase.word` and `phrase.gloss`,
    /// content-linked to `phrase` and kept in sync by triggers.
    static func createPhraseFTS(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE phrase_ft USING fts5(
                word, gloss,
                content='phrase', content_rowid='rowid',
                tokenize='unicode61'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER phrase_ai AFTER INSERT ON phrase BEGIN
                INSERT INTO phrase_ft(rowid, word, gloss)
                VALUES (new.rowid, new.word, new.gloss);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER phrase_ad AFTER DELETE ON phrase BEGIN
                INSERT INTO phrase_ft(phrase_ft, rowid, word, gloss)
                VALUES ('delete', old.rowid, old.word, old.gloss);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER phrase_au AFTER UPDATE ON phrase BEGIN
                INSERT INTO phrase_ft(phrase_ft, rowid, word, gloss)
                VALUES ('delete', old.rowid, old.word, old.gloss);
                INSERT INTO phrase_ft(rowid, word, gloss)
                VALUES (new.rowid, new.word, new.gloss);
            END
            """)
    }

    /// One row per started article: where the reader stopped. Keyed by content
    /// hash so a re-pasted article resumes at the same word; the document id
    /// is kept alongside as fallback for plans with an empty hash.
    static func createReadingPositionTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reading_position(
                content_hash TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                title TEXT NOT NULL,
                word_index INTEGER NOT NULL,
                finished INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX idx_reading_position_updated
            ON reading_position(updated_at DESC)
            """)
    }
}
