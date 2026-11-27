import Foundation
import GRDB
import ReadLaterCore

/// Ordered, named migrations. `eraseDatabaseOnSchemaChange` stays false:
/// user phrases must survive an app update.
func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.eraseDatabaseOnSchemaChange = false

    migrator.registerMigration("v1_initial") { db in
        try Schema.createBaseTables(db)
    }

    // v2 adds the FTS5 index in its own step so the pattern for later
    // index changes is visible. The rebuild covers phrases saved by v1.
    migrator.registerMigration("v2_fts") { db in
        try Schema.createPhraseFTS(db)
        try db.execute(sql: "INSERT INTO phrase_ft(phrase_ft) VALUES('rebuild')")
    }

    // v3 adds the reading-position table. Visit rows are local-only, so no
    // backfill: only articles opened after this build record a place.
    migrator.registerMigration("v3_positions") { db in
        try Schema.createReadingPositionTable(db)
    }

    // v4 adds the saved flag. A visit row is a side effect of reading and is
    // evictable; a saved row is chosen by the reader and must survive a
    // release. One flag separates the two, and it decides the delete rule.
    migrator.registerMigration("v4_saved") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN saved INTEGER NOT NULL DEFAULT 0")
    }

    // v5 keeps the article URL and its spoken length on the position row. The
    // browse list needs both without a store read per render, and a release
    // leaves the row behind while the stored plan is gone.
    migrator.registerMigration("v5_position_origin") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN url TEXT")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN total_words INTEGER NOT NULL DEFAULT 0")
    }

    // v6 renames the sync operation log. SQLite keeps every row and its seq
    // order. Fresh databases create the old name in v1 and rename here, so one
    // path serves both upgrades and new installs.
    migrator.registerMigration("v6_syncoplog") { db in
        try db.execute(sql: "ALTER TABLE \(Schema.legacyChangelog) RENAME TO \(Schema.syncOplog)")
    }

    // v7 adds library identity in one pass: the signals that survive a
    // re-plan, the sentence anchor, the raw page, the provenance links, the
    // canonical-URL backfill, and the sibling-lookup indexes.
    //
    // Nine migrations became one because no install ever applied them: every
    // checked database was at v6 or older. The order below is the order the
    // chain ran in, and it is load-bearing:
    //   1. columns and tables
    //   2. furthest seed from the stored word
    //   3. document source hash from the stored plan
    //   4. canonical URLs (positions, then documents)
    //   5. the URL-less heal, which copies a document URL onto its row
    //   6. indexes
    //
    // Schema choice: columns on `reading_position`, not new
    // `library_entry`/`library_version` tables. Each position row already is
    // one version (keyed by content hash): `furthest` and `extractor_version`
    // are per-version, `marked_done` is the human Entry-level signal kept on
    // the row until a canonical-URL entry table exists. The full Entry/Version
    // table split is deferred: it needs paste identity and an Entry key (the
    // canonical URL, `CanonicalURL`, is already stored on ingest). Columns
    // satisfy "Entry holds markedDone, Version holds furthest, reachedEnd
    // derived never stored" without breaking queries.
    migrator.registerMigration("v7_library_identity") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN extractor_version INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN furthest INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN marked_done INTEGER NOT NULL DEFAULT 0")
        // The sentence anchor the position resumes from (research
        // `spec/library-identity.md` §4, F43): `anchor_hash` is the sha256-16
        // of the normalized sentence under the reader, `anchor_head` its
        // first five normalized words. Empty means no anchor. No backfill:
        // old rows fall to the proportional path and the next tick writes
        // one.
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN anchor_hash TEXT NOT NULL DEFAULT ''")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN anchor_head TEXT NOT NULL DEFAULT ''")
        // The link as pasted, beside the canonical URL (research
        // `spec/library-identity.md` §2). Refetch prefers it: stripping a
        // site's own `ref`/`source` key can fetch a different resource. No
        // backfill: old rows refetch from the canonical URL as before.
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN original_url TEXT")
        try db.execute(sql: "ALTER TABLE document ADD COLUMN source_sha256 TEXT")
        try db.execute(sql: "ALTER TABLE document ADD COLUMN original_url TEXT")
        // The fetched HTML an article was planned from, so a parser change
        // can re-plan it (research `spec/library-identity.md` §3). Local
        // only: no sync row, so the page never leaves the device. Keyed by
        // the content hash, which is the hash of these exact bytes.
        try db.execute(sql: """
            CREATE TABLE raw_page(
                content_hash TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                html_zlib BLOB NOT NULL,
                status INTEGER NOT NULL,
                final_url TEXT NOT NULL,
                fetched_at REAL NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_raw_page_document ON raw_page(document_id)")

        // Furthest = clamped word_index, so existing progress is kept. The
        // clamp matters: a corrupt word (negative or past the end) must not
        // migrate into `furthest` and derive a false `reachedEnd` until the
        // next tick heals it.
        try db.execute(sql: "UPDATE reading_position SET furthest = min(max(word_index, 0), max(total_words - 1, 0))")

        // The raw-page delete finds siblings by `source_sha256`. Reading
        // every stored plan was ~131 ms for 500 debug-build articles, so the
        // backfill reads the hash once here and every later write carries it
        // in memory. A plan that is not JSON leaves NULL, and the delete
        // falls back to the document id. Swift-side and tolerant: a corrupt
        // row must not abort the migration and wedge the app shut.
        let documentsToHash = try Row.fetchAll(db, sql: "SELECT id, plan_json FROM document")
        for row in documentsToHash {
            let id: String = row["id"]
            guard let planJSON: String = row["plan_json"],
                  let data = planJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hash = object["source_sha256"] as? String
            else { continue }
            try db.execute(sql: "UPDATE document SET source_sha256 = ? WHERE id = ?", arguments: [hash, id])
        }
        try db.execute(sql: "CREATE INDEX idx_document_sha ON document(source_sha256)")

        // Backfill canonical URLs on rows written before canonicalization
        // on ingest. A pre-canonical `url` (case/tracking/fragment drift)
        // never equals the canonical input, so `siblingRows` would miss it
        // and strand a duplicate. Only drifted rows are rewritten (the
        // canonical check skips the rest); the loop is Swift-side because
        // plain SQLite has no canonicalize function. `original_url` is
        // provenance and stays exactly as pasted.
        let positions = try Row.fetchAll(db, sql: "SELECT content_hash, url FROM reading_position WHERE url IS NOT NULL")
        for row in positions {
            let hash: String = row["content_hash"]
            let url: String = row["url"]
            let canonical = CanonicalURL.canonicalize(url)
            if canonical != url {
                try db.execute(sql: "UPDATE reading_position SET url = ? WHERE content_hash = ?",
                               arguments: [canonical, hash])
            }
        }
        let documents = try Row.fetchAll(db, sql: "SELECT id, url FROM document WHERE url IS NOT NULL")
        for row in documents {
            let id: String = row["id"]
            let url: String = row["url"]
            let canonical = CanonicalURL.canonicalize(url)
            if canonical != url {
                try db.execute(sql: "UPDATE document SET url = ? WHERE id = ?",
                               arguments: [canonical, id])
            }
        }

        // Backfill the position URL from its document for pre-v5 rows. v5
        // added `url` with no backfill, so those rows carry NULL — and the
        // canonical sibling gate needs a URL to compare, so without this
        // they would strand as duplicates forever.
        //
        // `total_words` heals from the computed plan total in the same pass
        // when the stored value is 0 (the v5 shape: it renders the wrong
        // place line). A nonzero-but-wrong stored total is left alone —
        // post-v5 writes are computed, so only a hand edit could do that,
        // and the next tick recomputes it anyway. Computed, never the stored
        // `spoken_words` field, which hand-made plans can disagree with.
        // Negatives heal too (`<= 0`), and a decode failure keeps the stored
        // total rather than zeroing it: a wrong-but-present count beats a
        // certain "0 words".
        //
        // `furthest` re-seeds from the word in the same pass (never lowering
        // a ticked value): the seed above zeroed it positionally when the
        // stored total was 0, so without this a finished pre-v5 row would
        // offer as resumable until its next tick.
        //
        // The document URL is canonical by now. Rows whose document is gone
        // (released) keep NULL: they never had URL identity, and the sibling
        // filter falls back to their pasted link instead. Only URL-less rows
        // are visited (`''` counts: ingest never writes it, but a hand edit
        // could strand the row while its NULL twin heals).
        let rows = try Row.fetchAll(db, sql: """
            SELECT content_hash, document_id, total_words, word_index, furthest FROM reading_position WHERE url IS NULL OR url = ''
            """)
        for row in rows {
            let hash: String = row["content_hash"]
            let docID: String = row["document_id"]
            // Default-then-clamp: a NULL from a hand edit or foreign tool
            // must not abort the whole migration and wedge the app shut.
            let total: Int = (row["total_words"] as Int?) ?? 0
            let word: Int = (row["word_index"] as Int?) ?? 0
            let furthest: Int = (row["furthest"] as Int?) ?? 0
            guard let doc = try Row.fetchOne(db, sql: """
                SELECT url, plan_json FROM document WHERE id = ?
                """, arguments: [docID]) else { continue }
            let url: String? = doc["url"]
            var healed = total
            if total <= 0,
               let planJSON: String = doc["plan_json"],
               let data = planJSON.data(using: .utf8),
               let plan = try? JSONDecoder().decode(BlockPlan.self, from: data) {
                healed = SpokenWordNumbering(plan: plan).totalWords
            }
            // Clamp after the branch: a decode failure must not write the
            // negative back. Heals the visited rows together —
            // url/total/word/finished/furthest — so SQL agrees with what
            // decode derives. A live document with no URL of its own (hand
            // edit only) keeps NULL and relies on the pasted-link fallback.
            // `min` ceilings a hand-set overshoot; `max` keeps a ticked
            // furthest a rewind cannot lower.
            let healedTotal = max(0, healed)
            let clampedWord = min(max(word, 0), max(healedTotal - 1, 0))
            let seeded = min(max(furthest, clampedWord), max(healedTotal - 1, 0))
            let finished: Int = (healedTotal > 0 && clampedWord >= healedTotal - 1) ? 1 : 0
            try db.execute(sql: """
                UPDATE reading_position SET url = ?, total_words = ?, word_index = ?, finished = ?, furthest = ? WHERE content_hash = ?
                """, arguments: [url, healedTotal, clampedWord, finished, seeded, hash])
        }

        // Sibling lookup runs on every open, filtering on `url` and
        // `original_url`. Libraries are small, so this was latency, not
        // breakage — a covered index replaces the full scan.
        try db.execute(sql: """
            CREATE INDEX idx_reading_position_url ON reading_position(url, original_url)
            """)
    }

    return migrator
}
