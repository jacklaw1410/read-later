import Foundation
import GRDB
import ReadLaterCore

/// Failures the store itself can report. SQLite errors surface as `DatabaseError`.
public enum StoreError: Error, Sendable, Equatable {
    case planEncodingFailed
    case planDecodingFailed
    case payloadEncodingFailed
}

/// One saved sighting of a phrase inside a document block.
public struct PhraseOccurrence: Sendable, Hashable {
    public var id: Int64
    public var phraseID: UUID
    public var documentID: UUID
    public var blockID: Int
    public var charOffset: Int
    public var createdAt: Date

    public init(id: Int64, phraseID: UUID, documentID: UUID, blockID: Int, charOffset: Int, createdAt: Date) {
        self.id = id
        self.phraseID = phraseID
        self.documentID = documentID
        self.blockID = blockID
        self.charOffset = charOffset
        self.createdAt = createdAt
    }
}

/// Where the reader stopped in one started article.
///
/// Keyed by content hash, not document id, so a re-pasted article resumes at
/// the same word. Local-only: position writes append no changelog row, so a
/// throttled write during reading never enters sync.
public struct ReadingPosition: Sendable, Hashable, Equatable {
    public var contentHash: String
    public var documentID: UUID
    public var title: String
    public var wordIndex: Int
    public var finished: Bool
    public var updatedAt: Date

    public init(
        contentHash: String, documentID: UUID, title: String,
        wordIndex: Int, finished: Bool, updatedAt: Date
    ) {
        self.contentHash = contentHash
        self.documentID = documentID
        self.title = title
        self.wordIndex = wordIndex
        self.finished = finished
        self.updatedAt = updatedAt
    }
}

/// Local-first SQLite store (GRDB, WAL, foreign keys on).
///
/// Every write appends exactly one `changelog` row in the same transaction.
/// The `device` identifier is injected by the caller, never read from the machine.
///
/// Dates are stored as `timeIntervalSinceReferenceDate` REALs. `Date` keeps
/// that same value internally, so a save/read round-trips bit-exact. Unix
/// epoch storage would add and subtract 978307200 and drop the last bit.
public final class Store: Sendable {
    let dbQueue: DatabaseQueue
    public let oplog: Oplog

    public init(databaseURL: URL, device: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        let dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        let migrator = makeMigrator()
        try migrator.migrate(dbQueue)
        self.dbQueue = dbQueue
        self.oplog = Oplog(dbQueue: dbQueue, device: device)
    }

    // MARK: - Documents

    public func save(document: Document) throws {
        let planData = try JSONEncoder().encode(document.plan)
        guard let planJSON = String(data: planData, encoding: .utf8) else {
            throw StoreError.planEncodingFailed
        }
        guard let payload = encodedJSON(document) else {
            throw StoreError.payloadEncodingFailed
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, title, added_at, plan_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    url = excluded.url,
                    title = excluded.title,
                    added_at = excluded.added_at,
                    plan_json = excluded.plan_json
                """, arguments: [
                    document.id.uuidString,
                    document.url?.absoluteString,
                    document.title,
                    document.addedAt.timeIntervalSinceReferenceDate,
                    planJSON,
                ])
            try Oplog.insert(in: db, device: oplog.device, op: "document.save", payload: payload)
        }
    }

    public func document(id: UUID) throws -> Document? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, url, title, added_at, plan_json FROM document WHERE id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return try Self.decodeDocument(row: row)
        }
    }

    public func allDocuments() throws -> [Document] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, url, title, added_at, plan_json FROM document ORDER BY added_at ASC
                """)
            return try rows.map(Self.decodeDocument(row:))
        }
    }

    public func deleteDocument(id: UUID) throws {
        let payload = encodedJSON(["id": id.uuidString]) ?? "{}"
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [id.uuidString])
            try Oplog.insert(in: db, device: oplog.device, op: "document.delete", payload: payload)
        }
    }

    // MARK: - Reading position

    /// The resume key for a document. The plan hash survives a re-paste that
    /// mints a new document id; the id fallback covers hand-made plans with
    /// an empty hash (tests, fixtures).
    public static func resumeKey(for document: Document) -> String {
        document.plan.sourceSHA256.isEmpty ? "doc:\(document.id.uuidString)" : document.plan.sourceSHA256
    }

    // MARK: - Phrases

    // MARK: - Reading position

    /// Records where reading stands. Upserts on the resume key, so one article
    /// keeps one row no matter how often it is re-pasted.
    ///
    /// Finish rule: the wash reached the last spoken word. Speech `.finished`
    /// lands on that same word, so the pause path and the finish path agree
    /// with no manual mark.
    public func recordPosition(of document: Document, wordIndex: Int, at date: Date = .now) throws {
        let total = SpokenIndex(plan: document.plan).totalWords
        let clamped = min(max(wordIndex, 0), max(total - 1, 0))
        let finished = total > 0 && clamped >= total - 1
        let hash = Self.resumeKey(for: document)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(content_hash, document_id, title, word_index, finished, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    document_id = excluded.document_id,
                    title = excluded.title,
                    word_index = excluded.word_index,
                    finished = excluded.finished,
                    updated_at = excluded.updated_at
                """, arguments: [
                    hash,
                    document.id.uuidString,
                    document.title,
                    clamped,
                    finished,
                    date.timeIntervalSinceReferenceDate,
                ])
        }
    }

    public func position(contentHash: String) throws -> ReadingPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, updated_at
                FROM reading_position WHERE content_hash = ?
                """, arguments: [contentHash]) else { return nil }
            return try Self.decodePosition(row: row)
        }
    }

    /// Fallback for plans with an empty hash, where the key is the document id.
    public func position(documentID: UUID) throws -> ReadingPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, updated_at
                FROM reading_position WHERE document_id = ?
                ORDER BY updated_at DESC LIMIT 1
                """, arguments: [documentID.uuidString]) else { return nil }
            return try Self.decodePosition(row: row)
        }
    }

    /// The newest unfinished article, for the launch affordance. Finished
    /// articles are skipped: there is nothing to resume.
    public func latestUnfinishedPosition() throws -> ReadingPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, updated_at
                FROM reading_position WHERE finished = 0
                ORDER BY updated_at DESC LIMIT 1
                """) else { return nil }
            return try Self.decodePosition(row: row)
        }
    }

    /// Dismisses the launch affordance. The next pause re-records, so this
    /// only silences the current offer.
    public func dismissPosition(contentHash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM reading_position WHERE content_hash = ?", arguments: [contentHash])
        }
    }

    public func save(phrase: Phrase) throws {
        guard let payload = encodedJSON(phrase) else {
            throw StoreError.payloadEncodingFailed
        }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO phrase(id, word, gloss, source, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    word = excluded.word,
                    gloss = excluded.gloss,
                    source = excluded.source,
                    created_at = excluded.created_at
                """, arguments: [
                    phrase.id.uuidString,
                    phrase.word,
                    phrase.gloss,
                    phrase.source,
                    phrase.createdAt.timeIntervalSinceReferenceDate,
                ])
            try Oplog.insert(in: db, device: oplog.device, op: "phrase.save", payload: payload)
        }
    }

    public func phrases() throws -> [Phrase] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, word, gloss, source, created_at FROM phrase ORDER BY created_at ASC
                """)
            return try rows.map(Self.decodePhrase(row:))
        }
    }

    // MARK: - Occurrences

    @discardableResult
    public func recordOccurrence(
        phraseID: UUID,
        documentID: UUID,
        blockID: Int,
        charOffset: Int,
        at date: Date = .now
    ) throws -> Int64 {
        let payload = encodedJSON([
            "phrase_id": phraseID.uuidString,
            "document_id": documentID.uuidString,
            "block_id": String(blockID),
            "char_offset": String(charOffset),
        ]) ?? "{}"
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO phrase_occurrence(phrase_id, document_id, block_id, char_offset, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    phraseID.uuidString,
                    documentID.uuidString,
                    blockID,
                    charOffset,
                    date.timeIntervalSinceReferenceDate,
                ])
            let rowID = db.lastInsertedRowID
            try Oplog.insert(in: db, device: oplog.device, op: "occurrence.record", payload: payload)
            return rowID
        }
    }

    public func occurrences(forPhrase id: UUID) throws -> [PhraseOccurrence] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, phrase_id, document_id, block_id, char_offset, created_at
                FROM phrase_occurrence WHERE phrase_id = ? ORDER BY id ASC
                """, arguments: [id.uuidString])
            return try rows.map(Self.decodeOccurrence(row:))
        }
    }

    // MARK: - Decoding

    static func decodeDocument(row: Row) throws -> Document {
        let idString: String = row["id"]
        let urlString: String? = row["url"]
        let title: String = row["title"]
        let addedAt: Double = row["added_at"]
        let planJSON: String = row["plan_json"]
        guard let data = planJSON.data(using: .utf8),
              let plan = try? JSONDecoder().decode(BlockPlan.self, from: data)
        else {
            throw StoreError.planDecodingFailed
        }
        guard let id = UUID(uuidString: idString) else {
            throw StoreError.planDecodingFailed
        }
        let url: URL? = urlString.flatMap(URL.init(string:))
        return Document(id: id, url: url, title: title, plan: plan, addedAt: Date(timeIntervalSinceReferenceDate: addedAt))
    }

    static func decodePhrase(row: Row) throws -> Phrase {
        let idString: String = row["id"]
        let word: String = row["word"]
        let gloss: String = row["gloss"]
        let source: String = row["source"]
        let createdAt: Double = row["created_at"]
        guard let id = UUID(uuidString: idString) else {
            throw StoreError.planDecodingFailed
        }
        return Phrase(id: id, word: word, gloss: gloss, source: source, createdAt: Date(timeIntervalSinceReferenceDate: createdAt))
    }

    static func decodeOccurrence(row: Row) throws -> PhraseOccurrence {
        let id: Int64 = row["id"]
        let phraseString: String = row["phrase_id"]
        let documentString: String = row["document_id"]
        let blockID: Int = row["block_id"]
        let charOffset: Int = row["char_offset"]
        let createdAt: Double = row["created_at"]
        guard let phraseID = UUID(uuidString: phraseString),
              let documentID = UUID(uuidString: documentString)
        else {
            throw StoreError.planDecodingFailed
        }
        return PhraseOccurrence(
            id: id, phraseID: phraseID, documentID: documentID,
            blockID: blockID, charOffset: charOffset,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt))
    }

    static func decodePosition(row: Row) throws -> ReadingPosition {
        let hash: String = row["content_hash"]
        let documentString: String = row["document_id"]
        let title: String = row["title"]
        let wordIndex: Int = row["word_index"]
        let finished: Bool = row["finished"]
        let updatedAt: Double = row["updated_at"]
        guard let documentID = UUID(uuidString: documentString) else {
            throw StoreError.planDecodingFailed
        }
        return ReadingPosition(
            contentHash: hash, documentID: documentID, title: title,
            wordIndex: wordIndex, finished: finished,
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt))
    }
}

private func encodedJSON<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}
