import Foundation
import GRDB
import ReadLaterCore

/// Failures the store itself can report. SQLite errors surface as `DatabaseError`.
public enum StoreError: Error, Sendable, Equatable {
    case planEncodingFailed
    case planDecodingFailed
    /// The raw page bytes are corrupt (bad zlib, non-UTF-8, bad URL) — not a
    /// corrupt plan. Distinct so the future re-plan slice can route
    /// "refetch the page" separately from "re-plan the bytes".
    case rawPageCorrupted
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

/// The fetched page one article was planned from: the HTML string the plan's
/// `sourceSHA256` covers, the HTTP status the extractor reads, and the URL
/// that answered. Headers and cookies are not kept.
public struct RawPage: Sendable, Equatable {
    public var html: String
    public var status: Int
    public var finalURL: URL
    public var fetchedAt: Date

    public init(html: String, status: Int, finalURL: URL, fetchedAt: Date = .now) {
        self.html = html
        self.status = status
        self.finalURL = finalURL
        self.fetchedAt = fetchedAt
    }
}

/// Where the reader stopped in one started article.
///
/// Keyed by content hash, not document id, so a re-pasted article resumes at
/// the same word. Local-only: position writes append no sync oplog row, so a
/// throttled write during reading never enters sync.
public struct ReadingPosition: Sendable, Hashable, Equatable {
    public var contentHash: String
    public var documentID: UUID
    public var title: String
    public var wordIndex: Int
    /// Mechanical end flag, derived from the clamped word — never read for
    /// UI. The checkmark and the launch offer read derived `reachedEnd` (or
    /// human `markedDone`); reaching for this field reintroduces the §6 bug
    /// where scrub-back-from-end disagrees with the offer list.
    public private(set) var finished: Bool
    /// Chosen by the reader, not a side effect of reading. A saved row
    /// survives a release; a visit row does not.
    public var saved: Bool
    /// The article URL, kept so the list can fetch the page again after a
    /// release, when the stored plan is gone.
    public var url: URL?
    /// The link as pasted, preferred for refetch. Nil for pasted text, the
    /// demo, and rows written before v9.
    public var originalURL: URL?
    /// Spoken length, so a row can say "word X of Y" with no store read.
    public var totalWords: Int
    /// Furthest word reached in this version. Monotonic: re-opening earlier
    /// never regresses it. Version-level signal (research
    /// `spec/library-identity.md` §5).
    public var furthest: Int
    /// Human done signal (tap Done). Placeholder now; learnings read this,
    /// never the mechanical flag. Version-level today: one row per content
    /// hash, so a changed article starts unmarked. Moves to the entry when
    /// the Entry split lands.
    public var markedDone: Bool
    /// Parser build that produced the plan. Same hash plus a new parser is a
    /// new version (research `spec/library-identity.md` §3).
    public var extractorVersion: Int
    /// Sentence under the reader: sha256-16 of its normalized text. Empty
    /// when no anchor was recorded (research `spec/library-identity.md` §4).
    public var anchorHash: String
    /// First five normalized words of the anchor sentence. Fuzzy key when the
    /// exact hash misses. Empty when no anchor was recorded.
    public var anchorHead: String
    public var updatedAt: Date

    public init(
        contentHash: String, documentID: UUID, title: String,
        wordIndex: Int, saved: Bool = false,
        url: URL? = nil, originalURL: URL? = nil, totalWords: Int = 0, furthest: Int? = nil,
        markedDone: Bool = false, extractorVersion: Int = 0,
        anchorHash: String = "", anchorHead: String = "", updatedAt: Date
    ) {
        // All three clamp together: the word bounds, furthest follows the
        // clamped word, and the mechanical flag derives from the clamped
        // word — so decode heals the whole row and every consumer can trust
        // the in-memory range. The only caller is `decodePosition` (plus
        // tests); writers compute the same values into SQL directly. The
        // total heals first: a negative renders "word 0 of -1" otherwise.
        let healedTotal = max(0, totalWords)
        let clampedWord = min(max(wordIndex, 0), max(healedTotal - 1, 0))
        self.contentHash = contentHash
        self.documentID = documentID
        self.title = title
        self.wordIndex = clampedWord
        self.finished = healedTotal > 0 && clampedWord >= healedTotal - 1
        self.saved = saved
        self.url = url
        self.originalURL = originalURL
        self.totalWords = healedTotal
        // No stored row clamps here: bound the furthest either way, so a
        // directly built row cannot overshoot the end.
        self.furthest = min(max(furthest ?? clampedWord, 0), max(healedTotal - 1, 0))
        self.markedDone = markedDone
        self.extractorVersion = extractorVersion
        self.anchorHash = anchorHash
        self.anchorHead = anchorHead
        self.updatedAt = updatedAt
    }

    /// Derived completion: furthest reached the last spoken word. Never
    /// stored (research `spec/library-identity.md` §6); redefinable later
    /// without a schema change. Navigation-only; learnings read `markedDone`.
    public var reachedEnd: Bool {
        Self.isReachedEnd(furthest: furthest, totalWords: totalWords)
    }

    public static func isReachedEnd(furthest: Int, totalWords: Int) -> Bool {
        totalWords > 0 && furthest >= totalWords - 1
    }
}

/// Local-first SQLite store (GRDB, WAL, foreign keys on).
///
/// Every sync write appends exactly one row to the sync oplog in the same
/// transaction. Position writes stay local. The `device` identifier is
/// injected by the caller, never read from the machine.
///
/// Dates are stored as `timeIntervalSinceReferenceDate` REALs. `Date` keeps
/// that same value internally, so a save/read round-trips bit-exact. Unix
/// epoch storage would add and subtract 978307200 and drop the last bit.
public final class Store: Sendable {
    let dbQueue: DatabaseQueue
    public let syncOplog: SyncOplog
    let telemetry: TelemetryHub

    public init(databaseURL: URL, device: String, telemetry: TelemetryHub) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        let dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        let migrator = makeMigrator()
        // Migrations run once at open on the caller thread (main at launch):
        // time the whole pass like any other write so a heavy backfill (v11
        // re-hash, v13 canonicalization) shows in telemetry, not silence.
        let migrateStart = CFAbsoluteTimeGetCurrent()
        try migrator.migrate(dbQueue)
        let migrateMs = (CFAbsoluteTimeGetCurrent() - migrateStart) * 1000
        telemetry.record(TelemetryName.storeWrite, fields: [
            "write": "store.migrate",
            "ms": String(format: "%.2f", migrateMs),
            "copyMs": String(format: "%.2f", migrateMs),
            "encodeMs": "0.00",
            "main": Thread.isMainThread ? "1" : "0",
        ])
        self.dbQueue = dbQueue
        self.telemetry = telemetry
        self.syncOplog = SyncOplog(dbQueue: dbQueue, device: device, telemetry: telemetry)
    }

    /// Single path for every write. Times the block and logs the write kind,
    /// duration and thread (M8: no main-thread writes). No write may call
    /// `dbQueue.write` direct.
    ///
    /// Encode/copy split: `copyMs` is the `dbQueue.write` itself (row bytes
    /// copied into the pager/WAL and committed) — the whole of the old `ms`,
    /// which keeps that meaning for backward compat. `encodeMs` is the
    /// caller-side pre-write preparation, passed in via `fields` (for
    /// `record.position`: the plan-to-words encode below); callers that
    /// report none get the row-prep (fields build/format) cost, which is
    /// ~microseconds. The telemetry dispatch itself (ISO format, JSON
    /// encode, buffer copy; disk flush stays async) is excluded from both.
    @discardableResult
    func timedWrite<T>(_ op: String, fields: [String: String] = [:], _ work: (Database) throws -> T) throws -> T {
        let copyStart = CFAbsoluteTimeGetCurrent()
        let value = try dbQueue.write(work)
        let copyMs = (CFAbsoluteTimeGetCurrent() - copyStart) * 1000
        let encodeStart = CFAbsoluteTimeGetCurrent()
        var logged = fields
        logged["write"] = op
        logged["ms"] = String(format: "%.2f", copyMs)
        logged["copyMs"] = String(format: "%.2f", copyMs)
        if logged["encodeMs"] == nil {
            logged["encodeMs"] = String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000)
        }
        logged["main"] = Thread.isMainThread ? "1" : "0"
        telemetry.record(TelemetryName.storeWrite, fields: logged)
        return value
    }

    // MARK: - Documents

    public func save(document: Document) throws {
        let planData = try JSONEncoder().encode(document.plan)
        guard let planJSON = String(data: planData, encoding: .utf8) else {
            throw StoreError.planEncodingFailed
        }
        // The changelog carries the full document JSON, including
        // `originalURL` when set. The pasted link (possibly with tracking
        // or session params) is provenance, kept for refetch and display
        // (spec §2, silent on sync). Whether sync strips it is a sync-slice
        // call; the local store keeps it either way.
        guard let payload = encodedJSON(document) else {
            throw StoreError.payloadEncodingFailed
        }
        // Op name is legacy `verb.noun` while every other write is
        // `noun.verb`; kept because the M8 net pins the 14-op set. New
        // writes use the `document.*` form.
        try timedWrite("save.document") { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, original_url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    url = excluded.url,
                    original_url = COALESCE(excluded.original_url, document.original_url),
                    title = excluded.title,
                    added_at = excluded.added_at,
                    plan_json = excluded.plan_json,
                    source_sha256 = excluded.source_sha256
                """, arguments: [
                    document.id.uuidString,
                    document.url?.absoluteString,
                    document.originalURL?.absoluteString,
                    document.title,
                    document.addedAt.timeIntervalSinceReferenceDate,
                    planJSON,
                    document.plan.sourceSHA256,
                ])
            try SyncOplog.insert(in: db, device: syncOplog.device, op: "document.save", payload: payload)
        }
    }

    public func document(id: UUID) throws -> Document? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, url, original_url, title, added_at, plan_json FROM document WHERE id = ?
                """, arguments: [id.uuidString]) else { return nil }
            return try Self.decodeDocument(row: row)
        }
    }

    public func allDocuments() throws -> [Document] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, url, original_url, title, added_at, plan_json FROM document ORDER BY added_at ASC
                """)
            return try rows.map(Self.decodeDocument(row:))
        }
    }

    public func deleteDocument(id: UUID) throws {
        let payload = encodedJSON(["id": id.uuidString]) ?? "{}"
        try timedWrite("document.delete") { db in
            let hash: String? = try Row.fetchOne(db, sql: """
                SELECT source_sha256 FROM document WHERE id = ?
                """, arguments: [id.uuidString]).flatMap { row -> String? in
                    let sha: String? = row["source_sha256"]
                    guard let sha, !sha.isEmpty else { return "doc:\(id.uuidString)" }
                    return sha
                }
            // Raw pages filed under this document id, read before the
            // delete: if the row is already gone (double release) the hash
            // above is unknown, but orphans still sweep below.
            let orphanHashes: [String] = try Row.fetchAll(db, sql: """
                SELECT content_hash FROM raw_page WHERE document_id = ?
                """, arguments: [id.uuidString]).map { row in row["content_hash"] }
            try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [id.uuidString])
            // No row went (double release, forget-after-release): nothing to
            // sync — peers replaying a delete for a row they never saw would
            // just grow the log. Still sweep orphan raw pages filed under
            // this id whose bytes no remaining document reads.
            guard db.changesCount > 0 else {
                for orphan in orphanHashes {
                    try db.execute(sql: """
                        DELETE FROM raw_page WHERE content_hash = ?
                        AND NOT EXISTS (SELECT 1 FROM document WHERE source_sha256 = ?)
                        """, arguments: [orphan, orphan])
                }
                return
            }
            // One article can have several document rows under one hash
            // (re-fetch mints a new id). The raw page belongs to the hash, so
            // it goes only when no remaining document reads the same bytes.
            // Both lookups ride the v11 `source_sha256` index: no plan parsing.
            // The id-scoped loop runs too: a raw page saved with a mutated
            // plan under this id keys a different hash than the stored row,
            // and only the id filing finds it. Each delete is a no-op for
            // hashes the other already removed. Serial `timedWrite`:
            // pre-multi-user, no interleave to race.
            if let hash {
                try db.execute(sql: """
                    DELETE FROM raw_page WHERE content_hash = ?
                    AND NOT EXISTS (SELECT 1 FROM document WHERE source_sha256 = ?)
                    """, arguments: [hash, hash])
            }
            for orphan in orphanHashes {
                try db.execute(sql: """
                    DELETE FROM raw_page WHERE content_hash = ?
                    AND NOT EXISTS (SELECT 1 FROM document WHERE source_sha256 = ?)
                    """, arguments: [orphan, orphan])
            }
            try SyncOplog.insert(in: db, device: syncOplog.device, op: "document.delete", payload: payload)
        }
    }

    /// Keeps the page one article was planned from. Local only: no changelog
    /// row. Upserts on the resume key, like the position row.
    public func saveRawPage(_ page: RawPage, for document: Document) throws {
        let compressed = try (Data(page.html.utf8) as NSData).compressed(using: .zlib) as Data
        try timedWrite("raw_page.save", fields: [
            "contentHash": Self.resumeKey(for: document),
            "bytes": String(compressed.count),
        ]) { db in
            try db.execute(sql: """
                INSERT INTO raw_page(content_hash, document_id, html_zlib, status, final_url, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    document_id = excluded.document_id,
                    html_zlib = excluded.html_zlib,
                    status = excluded.status,
                    final_url = excluded.final_url,
                    fetched_at = excluded.fetched_at
                """, arguments: [
                    Self.resumeKey(for: document),
                    document.id.uuidString,
                    compressed,
                    page.status,
                    page.finalURL.absoluteString,
                    page.fetchedAt.timeIntervalSinceReferenceDate,
                ])
        }
    }

    public func rawPage(contentHash: String) throws -> RawPage? {
        // Single-user local store: keyed by hash alone, not scoped to a
        // document id. The orphan sweep relies on the same correspondence
        // (one hash, one set of bytes); pre-multi-user this holds.
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT html_zlib, status, final_url, fetched_at FROM raw_page WHERE content_hash = ?
                """, arguments: [contentHash]) else { return nil }
            let compressed: Data = row["html_zlib"]
            guard let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
                  let html = String(data: data, encoding: .utf8),
                  let finalURL = URL(string: row["final_url"]) else {
                throw StoreError.rawPageCorrupted
            }
            let status: Int = row["status"]
            let fetchedAt: Double = row["fetched_at"]
            return RawPage(
                html: html, status: status, finalURL: finalURL,
                fetchedAt: Date(timeIntervalSinceReferenceDate: fetchedAt))
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
    /// Changed bytes hash differently and seed a second row: the refetch path
    /// retires the old one via `supersedeOnRefetch`, so the library still
    /// shows one row per article.
    ///
    /// Paste/link separation (research `spec/library-identity.md` §3: even
    /// byte-identical text makes two independent entries) is NOT yet enforced
    /// here: the resume key is the content hash, so a re-paste of identical
    /// text still upserts one shared row and shares progress. True separation
    /// needs the Entry table keyed by canonical URL plus paste identity, and
    /// is deferred with the Entry/Version table split. No hash-sharing change
    /// is made here; this comment records the gap.
    ///
    /// Finish rule: the wash reached the last spoken word. Speech `.finished`
    /// lands on that same word, so the pause path and the finish path agree
    /// with no manual mark.
    ///
    /// DEPRECATED toward `reachedEnd`: `finished` stays mechanical
    /// (`clamped >= total - 1`) for compat. New reads use the derived
    /// `reachedEnd` (from monotonic `furthest`); learnings use `markedDone`.
    public func recordPosition(of document: Document, wordIndex: Int, at date: Date = .now, source: String = "record") throws {
        // Encode half of the tick cost: turning the plan into positioned
        // words (index build + clamp + resume key + anchor) before the
        // write. Timed here because it runs on the writer thread per
        // throttled tick but outside `timedWrite`, so the old single `ms`
        // never covered it. Per-tick rather than pause-only: a pause-only
        // anchor loses the place on an OS kill. Cost unmeasured; if the
        // timing harness flags `record.position`, measure before moving it.
        let encodeStart = CFAbsoluteTimeGetCurrent()
        let index = SpokenWordNumbering(plan: document.plan)
        let total = index.totalWords
        let clamped = min(max(wordIndex, 0), max(total - 1, 0))
        let finished = total > 0 && clamped >= total - 1
        let hash = Self.resumeKey(for: document)
        let anchor = AnchorResolver.anchor(wordIndex: clamped, index: index, plan: document.plan)
        let encodeMs = (CFAbsoluteTimeGetCurrent() - encodeStart) * 1000
        try timedWrite("record.position", fields: [
            "contentHash": hash,
            "source": source,
            "word": String(clamped),
            "encodeMs": String(format: "%.2f", encodeMs),
        ]) { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    document_id = excluded.document_id,
                    title = excluded.title,
                    word_index = excluded.word_index,
                    finished = excluded.finished,
                    -- Last non-nil wins for both URLs: pasted ticks carry no
                    -- URL, and must never wipe the link an earlier open set.
                    url = COALESCE(excluded.url, reading_position.url),
                    original_url = COALESCE(excluded.original_url, reading_position.original_url),
                    total_words = excluded.total_words,
                    extractor_version = excluded.extractor_version,
                    -- `furthest` merges clamped like the supersede seed: a
                    -- same-hash shrink (parser rebuild, fewer words) must not
                    -- leave `furthest` past the new end, or `reachedEnd`
                    -- derives true from an overshoot.
                    furthest = min(max(reading_position.furthest, excluded.word_index), max(excluded.total_words - 1, 0)),
                    anchor_hash = excluded.anchor_hash,
                    anchor_head = excluded.anchor_head,
                    updated_at = excluded.updated_at
                """, arguments: [
                    hash,
                    document.id.uuidString,
                    document.title,
                    clamped,
                    finished,
                    document.url?.absoluteString,
                    document.originalURL?.absoluteString,
                    total,
                    document.plan.extractorVersion,
                    clamped,
                    anchor.hash,
                    anchor.head,
                    date.timeIntervalSinceReferenceDate,
                ])
        }
    }

    public func position(contentHash: String) throws -> ReadingPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words, extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at
                FROM reading_position WHERE content_hash = ?
                """, arguments: [contentHash]) else { return nil }
            return try Self.decodePosition(row: row)
        }
    }

    /// Where to start a plan that replaced the row's version, plus whether
    /// the rewrite gate tripped. Same hash and agreeing totals keep the
    /// stored word (clamped) and never rewrite: identical bytes read through
    /// identical splits, so a "starting at the top" note would contradict
    /// the resume. Anything else — new bytes, re-split text, truncated or
    /// corrupt counts — migrates through the anchor (exact single hit,
    /// nearest copy, rewrite gate, unique head, proportion, top). Pure: no
    /// database access. One function so the start and the flag cannot
    /// disagree.
    /// Same-total re-split asymmetry is intentional: an anchorless legacy
    /// row keeps the exact word (nothing to disprove the stream with),
    /// while an anchored row with a dead anchor re-anchors through the
    /// fuzzy head — same bytes, different outcomes by anchor presence.
    /// Empty-hash plans (hand-made, tests) skip the fast path by design:
    /// their key is the document id (`resumeKey`), never the empty hash, so
    /// equality here would be meaningless; identical empty-hash bytes still
    /// meet at the exact anchor with no rewrite.
    /// `extractorVersion` is consulted only to pick the cheap path, never
    /// the outcome: agreeing totals with a matching version keep the word
    /// directly, as do anchorless legacy rows (pre-v7: nothing to prove the
    /// stream with, so same bytes plus agreeing totals keep the exact word
    /// instead of a float proportion that can truncate one low). A bumped
    /// parser with agreeing totals must still prove the word stream survived
    /// — a re-split keeps the same total — so it keeps the word only on a
    /// single exact anchor hit; otherwise it re-anchors below. The column
    /// stays as provenance for the re-plan slice (research
    /// `spec/library-identity.md` §3).
    public func resolve(row: ReadingPosition, newPlan: BlockPlan) -> (start: Int, rewrote: Bool) {
        // One field build serves the gate and the fallback: `detailed`
        // carries the exact-hit count and the new total, so neither the
        // gate nor the caller pays for a second plan walk. (The field
        // itself walks blocks twice — index plus sentences — a pre-existing
        // shape covered by the DEBUG count assert, not something this gate
        // can fix without restructuring the index.)
        let detailed = AnchorResolver.resolveDetailed(old: row, newPlan: newPlan)
        let total = detailed.total
        guard total > 0 else { return (0, false) }
        // Same bytes, same splits: keep the precise word — the anchor path
        // would only return the sentence start, losing intra-sentence
        // precision on every parser bump. Same hash with different totals
        // (re-split, truncated, corrupt) falls through to re-anchor, even
        // when the extractor version matches: a blind clamp would point at
        // unrelated text. Same totals with a bumped parser need a single
        // exact anchor hit first: identical bytes usually mean an identical
        // word stream, but a new skip rule can re-split sentences at the
        // same total, and then the absolute index points at the wrong word.
        // Either arm skips the count (already built above, just unread):
        // both field lists derive from the same `flatten`, so a divergent
        // build is impossible in practice. Anchorless legacy rows (pre-v7,
        // version 0) keep the word for the same reason: there is no anchor
        // to prove a re-split with, and the
        // proportion fallback would only truncate (pinned: 29 survives where
        // proportion gives 28).
        // The exact-hit arm keeps the word only inside the hit span: a
        // stationary sentence keeps intra-sentence precision, but a moved
        // sentence (compensating re-split, same total) follows the hit to
        // its new start instead of resuming mid-wrong-sentence. Same-version
        // splits are deterministic, so the span always contains the word.
        if !newPlan.sourceSHA256.isEmpty, newPlan.sourceSHA256 == row.contentHash,
           total == row.totalWords {
            let clampedWord = min(max(row.wordIndex, 0), total - 1)
            if newPlan.extractorVersion == row.extractorVersion || row.anchorHash.isEmpty {
                return (clampedWord, false)
            }
            if detailed.exactHits == 1 {
                if let span = detailed.hitSpan, span.contains(clampedWord) {
                    return (clampedWord, false)
                }
                return (detailed.start, false)
            }
        }
        return (detailed.start, detailed.rewrote)
    }

    /// Fallback for plans with an empty hash, where the key is the document id.
    /// Test and debug helper: callers with a hash must prefer
    /// `position(contentHash:)`. Two hashes can share one document id after
    /// a mutated-plan save, and this returns the newest (`ORDER BY
    /// updatedAt`), which may be the sibling's row.
    public func position(documentID: UUID) throws -> ReadingPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words, extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at
                FROM reading_position WHERE document_id = ?
                ORDER BY updated_at DESC LIMIT 1
                """, arguments: [documentID.uuidString]) else { return nil }
            return try Self.decodePosition(row: row)
        }
    }

    /// Rows filed under the same canonical URL but a different hash:
    /// leftovers from a retire that threw halfway, or a release the user
    /// re-added fresh. The newest open absorbs the ones whose bytes are
    /// gone (their only value is the carried flags); the caller skips rows
    /// whose document still exists, so live entries are never touched and
    /// this filter only selects candidates. Matches the exact URL, its
    /// canonical form, and either column holding the pasted link, so
    /// pre-canonical rows and tracking-param drift still meet — then keeps
    /// only rows whose own URL canonicalizes the same, falling back to the
    /// pasted link when the row has no URL at all. That fallback heals
    /// released-then-re-added rows (release keeps the position row with
    /// its pasted link but no URL). The fallback is release-only,
    /// enforced twice: the filter itself returns a URL-less row only when
    /// its document is gone, and the caller skips live documents too.
    /// Live rows with a URL never take the fallback, so the
    /// re-pointed-short-link guard still holds for them: a re-pointed link
    /// shares only provenance with a different article, and absorbing on
    /// the pasted link alone would merge two unrelated entries and delete
    /// one from the shelf.
    public func siblingRows(url: String, excluding contentHash: String) throws -> [ReadingPosition] {
        try dbQueue.read { db in
            let canonical = CanonicalURL.canonicalize(url)
            // The last OR-branch fetches URL-less candidates the exact
            // matches miss (a drifted pasted link never equals the lookup
            // at SQL level); the Swift filter below decides, including a
            // release-only check the SQL cannot express alone. Most
            // libraries have no NULL-url rows left (v13 backfilled every
            // row with a live document), so the COUNT gate keeps the widened
            // branch — a full scan plus one doc lookup per candidate — off
            // the common path without changing the result. The gate counts
            // a superset the filter then narrows (live URL-less rows fire
            // the gate but are filtered out); released rows without any
            // link keep NULL forever and correctly never trigger it.
            let nullCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM reading_position WHERE (url IS NULL OR url = '') AND original_url IS NOT NULL
                """) ?? 0
            let wide = nullCount > 0 ? " OR ((url IS NULL OR url = '') AND original_url IS NOT NULL)" : ""
            let rows = try Row.fetchAll(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words, extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at
                FROM reading_position
                WHERE content_hash != ?
                AND (url = ? OR url = ? OR original_url = ? OR original_url = ?\(wide))
                """, arguments: [contentHash, url, canonical, url, canonical])
            return try rows.map(Self.decodePosition(row:)).filter { row in
                if let rowURL = row.url?.absoluteString,
                   CanonicalURL.canonicalize(rowURL) == canonical {
                    return true
                }
                // URL-less fallback: the pasted link is the only identity
                // left, so it must also be release-only — a live nil-url
                // row shares only provenance, never identity. `save` and
                // `recordPosition` write nil URLs straight to NULL, so the
                // filter checks the document is gone itself instead of
                // garbage that parses as a relative URL (no spaces, no host)
                // skips this branch with a non-nil URL, then fails the
                // canonical compare above instead — same exclusion, other
                // path. A stored URL that will not parse decodes to nil
                // and takes this branch too: live garbage heals nothing (only hand edits can write it —
                // ingest canonicalizes), released garbage still heals via
                // the pasted link when that parses.
                guard row.url == nil, let pasted = row.originalURL?.absoluteString,
                      CanonicalURL.canonicalize(pasted) == canonical else { return false }
                return try Row.fetchOne(db, sql: "SELECT 1 FROM document WHERE id = ?",
                                        arguments: [row.documentID.uuidString]) == nil
            }
        }
    }

    /// Drops a stale pasted link after the canonical fallback rescued it.
    /// A dead short link would otherwise force every later open to fetch
    /// twice. The canonical URL stays: refetch falls back to it directly.
    public func clearOriginalURL(contentHash: String) throws {
        try timedWrite("position.original_url.clear", fields: ["contentHash": contentHash]) { db in
            try db.execute(
                sql: "UPDATE reading_position SET original_url = NULL WHERE content_hash = ?",
                arguments: [contentHash])
        }
    }

    /// Drops a rescued dead link from the document row. The position clear
    /// alone leaves `document(id:).originalURL` returning the dead short
    /// link on every later read (round-11 finding): a no-tick open never
    /// touches the position row. Called alongside the position clear.
    public func clearDocumentOriginalURL(documentID: UUID) throws {
        try timedWrite("document.original_url.clear", fields: ["documentID": documentID.uuidString]) { db in
            try db.execute(
                sql: "UPDATE document SET original_url = NULL WHERE id = ?",
                arguments: [documentID.uuidString])
        }
    }

    /// Clears the rescued dead link from both rows in one transaction, so a
    /// crash between two separate clears cannot split them (round-15
    /// finding). The recorder's production path; the single-row methods
    /// above stay as test primitives. Unlike `save`/`delete`, which sync,
    /// this clear writes no changelog row: peers keep the dead link until
    /// they fetch and rescue independently — each device meets the dead
    /// link on its own fetch, and the retry is one cheap fetch, not shared
    /// state.
    public func clearRescuedLink(contentHash: String, documentID: UUID) throws {
        try timedWrite("rescued_link.clear", fields: [
            "contentHash": contentHash, "documentID": documentID.uuidString,
        ]) { db in
            try db.execute(
                sql: "UPDATE reading_position SET original_url = NULL WHERE content_hash = ?",
                arguments: [contentHash])
            try db.execute(
                sql: "UPDATE document SET original_url = NULL WHERE id = ?",
                arguments: [documentID.uuidString])
        }
    }

    /// Retires the old row after a changed-content refetch. A refetch mints
    /// a new document id and changed bytes hash differently, so without this
    /// the library keeps two rows for one article (round-15 finding). Runs
    /// after `openAtPlace`: the start word is already resolved from the old
    /// row. One transaction: drops the old position row and the superseded
    /// document row (when it still exists under a different id, with the
    /// same sibling-guarded raw-page cleanup as `deleteDocument`), and seeds
    /// the new row at the resolved start, carrying `saved`/`markedDone`
    /// forward — a first tick would reset them. `furthest` restarts from the
    /// resolved start: the old furthest measured old bytes and could falsely
    /// mark the new bytes reached. New-session ticks upsert onto the seed.
    /// The old link carries like a tick (`COALESCE`): a nil refetch keeps
    /// the pasted link, and the caller clears the seeded row when the link
    /// was the dead one being rescued. Empty-hash plans key by document id,
    /// so different ids always differ and any empty-hash refetch retires the
    /// row — production plans always hash, so this only fires in tests.
    public func supersedeOnRefetch(oldRow: ReadingPosition, newDocument: Document, startWord: Int, at date: Date = .now) throws {
        let newHash = Self.resumeKey(for: newDocument)
        guard newHash != oldRow.contentHash else { return }
        let index = SpokenWordNumbering(plan: newDocument.plan)
        let total = index.totalWords
        let clamped = min(max(startWord, 0), max(total - 1, 0))
        let finished = total > 0 && clamped >= total - 1
        let anchor = AnchorResolver.anchor(wordIndex: clamped, index: index, plan: newDocument.plan)
        let deletePayload = encodedJSON(["id": oldRow.documentID.uuidString]) ?? "{}"
        try timedWrite("position.supersede") { db in
            try db.execute(
                sql: "DELETE FROM reading_position WHERE content_hash = ?",
                arguments: [oldRow.contentHash])
            // Id-filed pages read before any delete: a raw page saved with a
            // mutated plan under the old id keys a different hash than the
            // stored row, and only the id filing finds it — the same orphan
            // case `deleteDocument` sweeps. Read outside the id guard so a
            // same-id retire (re-save under one id, then supersede) still
            // sweeps the old-hash page; the sibling guard below makes each
            // delete a no-op for live hashes. Callers save the new document
            // (open saves synchronously) before superseding, so the guard
            // sees the live hash. Serial `timedWrite`, like the
            // delete path: pre-multi-user, no interleave to race.
            let orphanHashes: [String] = try Row.fetchAll(db, sql: """
                SELECT content_hash FROM raw_page WHERE document_id = ?
                """, arguments: [oldRow.documentID.uuidString]).map { row in row["content_hash"] }
            if oldRow.documentID != newDocument.id {
                try db.execute(
                    sql: "DELETE FROM document WHERE id = ?",
                    arguments: [oldRow.documentID.uuidString])
                // Sync replays the log, never the store: a deleted document
                // needs its `document.delete` row like any other delete, or
                // peers keep the superseded row forever. Only when a row
                // actually went: the refetch path usually finds it already
                // gone (that is why it refetched).
                if db.changesCount > 0 {
                    try SyncOplog.insert(in: db, device: syncOplog.device, op: "document.delete", payload: deletePayload)
                }
            }
            try db.execute(sql: """
                DELETE FROM raw_page WHERE content_hash = ?
                AND NOT EXISTS (SELECT 1 FROM document WHERE source_sha256 = ?)
                -- Guard compares the position key to the document hash:
                -- for normal rows both are the source SHA-256. Empty-hash
                -- rows key by `doc:<uuid>`, which no source_sha256 ever
                -- equals, so the guard is vacuously true — correct, since
                -- a `doc:<uuid>` key is unique and has no sibling.
                """, arguments: [oldRow.contentHash, oldRow.contentHash])
            // Id-scoped sweep for the mutated-plan case above: each
            // delete is a no-op for hashes the other already removed.
            for orphan in orphanHashes {
                try db.execute(sql: """
                    DELETE FROM raw_page WHERE content_hash = ?
                    AND NOT EXISTS (SELECT 1 FROM document WHERE source_sha256 = ?)
                    """, arguments: [orphan, orphan])
            }
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                    saved = max(reading_position.saved, excluded.saved),
                    marked_done = max(reading_position.marked_done, excluded.marked_done),
                    -- A raced seed (absorb vs tick, two stale siblings) must
                    -- not wipe the live row: links merge, flags merge,
                    -- metadata follows the newer seed, but the live word
                    -- stays with the first seed, clamped to the new length
                    -- so it can never point past the end, with `finished`
                    -- recomputed from the clamped word and the newest
                    -- timestamp ordering the list.
                    url = COALESCE(excluded.url, reading_position.url),
                    original_url = COALESCE(excluded.original_url, reading_position.original_url),
                    title = excluded.title,
                    word_index = min(max(reading_position.word_index, 0), max(excluded.total_words - 1, 0)),
                    finished = CASE WHEN excluded.total_words > 0
                        AND min(max(reading_position.word_index, 0), max(excluded.total_words - 1, 0)) >= excluded.total_words - 1
                        THEN 1 ELSE 0 END,
                    total_words = excluded.total_words,
                    extractor_version = excluded.extractor_version,
                    -- `furthest` merges like the word: it can never point
                    -- past the new length, or `reachedEnd` derives true from
                    -- an overshoot instead of a real finish.
                    furthest = min(max(reading_position.furthest, excluded.furthest), max(excluded.total_words - 1, 0)),
                    anchor_hash = excluded.anchor_hash,
                    anchor_head = excluded.anchor_head,
                    updated_at = excluded.updated_at
                """, arguments: [
                    newHash,
                    newDocument.id.uuidString,
                    newDocument.title,
                    clamped,
                    finished,
                    oldRow.saved ? 1 : 0,
                    newDocument.url?.absoluteString,
                    newDocument.originalURL?.absoluteString ?? oldRow.originalURL?.absoluteString,
                    total,
                    newDocument.plan.extractorVersion,
                    clamped,
                    oldRow.markedDone ? 1 : 0,
                    anchor.hash,
                    anchor.head,
                    date.timeIntervalSinceReferenceDate,
                ])
        }
    }

    /// The newest reachable article, for the launch affordance. Finished
    /// articles are skipped: there is nothing to resume. Driven by derived
    /// `reachedEnd` (furthest), not the mechanical `finished` flag, so an
    /// article read to the end but re-opened at word 0 is not offered again.
    /// The predicate mirrors `isReachedEnd` exactly, including the
    /// `total_words = 0` edge: an empty plan is never "reached" — and with
    /// no words there is nothing to resume, so it is not offered either.
    /// Consistent writes keep `finished` and `furthest` in agreement, so
    /// the stored flag adds no signal — and a corrupt flag must not hide
    /// an unreached row the derived value would offer.
    public func latestUnfinishedPosition() throws -> ReadingPosition? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words, extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at
                FROM reading_position WHERE total_words > 0 AND NOT (furthest >= total_words - 1)
                ORDER BY updated_at DESC LIMIT 1
                """) else { return nil }
            return try Self.decodePosition(row: row)
        }
    }

    /// Dismisses the launch affordance. The next pause re-records, so this
    /// only silences the current offer.
    public func dismissPosition(contentHash: String) throws {
        try timedWrite("position.dismiss") { db in
            try db.execute(sql: "DELETE FROM reading_position WHERE content_hash = ?", arguments: [contentHash])
        }
    }

    /// The browse list: every started article, newest first. A visit row is a
    /// side effect of reading, so the list needs no consent and no save.
    public func recentPositions(limit: Int = 50) throws -> [ReadingPosition] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words, extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at
                FROM reading_position ORDER BY updated_at DESC LIMIT ?
                """, arguments: [limit])
            return try rows.map(Self.decodePosition(row:))
        }
    }

    /// The saved queue: rows the reader chose. These survive a release.
    public func savedPositions() throws -> [ReadingPosition] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words, extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at
                FROM reading_position WHERE saved = 1 ORDER BY updated_at DESC
                """)
            return try rows.map(Self.decodePosition(row:))
        }
    }

    /// Sets or clears the saved flag. The flag is local-only, like the rest of
    /// the position row, so no sync oplog entry is appended.
    public func setSaved(contentHash: String, saved: Bool) throws {
        try timedWrite("position.saved") { db in
            try db.execute(
                sql: "UPDATE reading_position SET saved = ? WHERE content_hash = ?",
                arguments: [saved, contentHash])
        }
    }

    /// Releases the derived bytes for one article and keeps its place. The
    /// next open refetches the page; an unchanged page keeps the same resume
    /// key. The document delete syncs (`document.delete`); the kept place
    /// stays local-only. (Research `spec/library-identity.md` §8: save/release/forget.)
    public func releaseCopy(documentID: UUID) throws {
        try deleteDocument(id: documentID)
    }

    /// Forgets one article completely: the plan and the place. Used by the
    /// library's remove action, and safe on a missing row.
    public func forget(contentHash: String, documentID: UUID) throws {
        try releaseCopy(documentID: documentID)
        try dismissPosition(contentHash: contentHash)
    }

    public func save(phrase: Phrase) throws {
        guard let payload = encodedJSON(phrase) else {
            throw StoreError.payloadEncodingFailed
        }
        try timedWrite("phrase.save") { db in
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
            try SyncOplog.insert(in: db, device: syncOplog.device, op: "phrase.save", payload: payload)
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
        return try timedWrite("occurrence.record") { db in
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
            try SyncOplog.insert(in: db, device: syncOplog.device, op: "occurrence.record", payload: payload)
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
        let originalURLString: String? = row["original_url"]
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
        let originalURL: URL? = originalURLString.flatMap(URL.init(string:))
        return Document(id: id, url: url, originalURL: originalURL, title: title, plan: plan, addedAt: Date(timeIntervalSinceReferenceDate: addedAt))
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
        // `finished` is selected for schema-compat but never read: the flag
        // derives in `init` from the clamped word, so a corrupt stored value
        // cannot leak into memory (spec §6: completion derives, never stored).
        let hash: String = row["content_hash"]
        let documentString: String = row["document_id"]
        let title: String = row["title"]
        let wordIndex: Int = row["word_index"]
        let saved: Bool = row["saved"]
        let urlString: String? = row["url"]
        let originalURLString: String? = row["original_url"]
        let totalWords: Int = row["total_words"]
        let extractorVersion: Int = row["extractor_version"]
        let furthest: Int = row["furthest"]
        let markedDone: Bool = row["marked_done"]
        let anchorHash: String = row["anchor_hash"]
        let anchorHead: String = row["anchor_head"]
        let updatedAt: Double = row["updated_at"]
        guard let documentID = UUID(uuidString: documentString) else {
            throw StoreError.planDecodingFailed
        }
        return ReadingPosition(
            contentHash: hash, documentID: documentID, title: title,
            wordIndex: wordIndex, saved: saved,
            // A stored `''` (hand edit only; ingest writes nil as NULL)
            // normalizes to nil: empty is no identity, so the row takes the
            // URL-less fallback below instead of stranding on a compare
            // that can never match.
            url: urlString.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            originalURL: originalURLString.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            totalWords: totalWords,
            furthest: furthest, markedDone: markedDone,
            extractorVersion: extractorVersion,
            anchorHash: anchorHash, anchorHead: anchorHead,
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt))
    }
}

private func encodedJSON<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}
