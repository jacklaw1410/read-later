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

    // v7 adds the library-identity placeholder signals (research
    // `spec/library-identity.md` §§5-6, SCOPE §5 2026-11-16, F35 §1).
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
    // Backfill: furthest = clamped word_index, so existing progress is kept
    // (the UPDATE below floors negatives and ceilings overruns).
    migrator.registerMigration("v7_library_identity") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN extractor_version INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN furthest INTEGER NOT NULL DEFAULT 0")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN marked_done INTEGER NOT NULL DEFAULT 0")
        // Clamped: a corrupt word (negative or past the end) must not
        // migrate into `furthest` and derive a false `reachedEnd` until the
        // next tick heals it.
        try db.execute(sql: "UPDATE reading_position SET furthest = min(max(word_index, 0), max(total_words - 1, 0))")
    }

    // v8 adds the sentence anchor the position resumes from (research
    // `spec/library-identity.md` §4, F38). `anchor_hash` is the sha256-16 of
    // the normalized sentence under the reader; `anchor_head` is its first
    // five normalized words. Empty means no anchor. No backfill: old rows
    // keep empty anchors and fall to the proportional path (the gate never
    // fires without an anchor); the next tick writes the anchor.
    migrator.registerMigration("v8_anchor") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN anchor_hash TEXT NOT NULL DEFAULT ''")
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN anchor_head TEXT NOT NULL DEFAULT ''")
    }

    // v9 keeps the fetched HTML an article was planned from, so a parser
    // change can re-plan it (research `spec/library-identity.md` §3). Local
    // only: no changelog row, so the page never syncs. Keyed by the content
    // hash, which is the hash of these exact bytes. Deleted with the article.
    migrator.registerMigration("v9_raw_page") { db in
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
    }

    // v10 keeps the link as pasted, next to the canonical URL (research
    // `spec/library-identity.md` §2). Refetch prefers it: stripping a site's
    // own `ref`/`source` key can fetch a different resource. No backfill:
    // old rows refetch from the canonical URL as before.
    migrator.registerMigration("v10_original_url") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN original_url TEXT")
    }

    // v11 indexes the source hash on the document row. The raw-page delete
    // used to find siblings by parsing every stored plan (`json_extract`, no
    // index): ~131 ms for 500 debug-build articles. The backfill parses once
    // at migration time; every write after that carries the hash in memory.
    migrator.registerMigration("v11_document_sha") { db in
        try db.execute(sql: "ALTER TABLE document ADD COLUMN source_sha256 TEXT")
        try db.execute(sql: "UPDATE document SET source_sha256 = json_extract(plan_json, '$.source_sha256')")
        try db.execute(sql: "CREATE INDEX idx_document_sha ON document(source_sha256)")
    }

    // v12 keeps the pasted link on the document row too. The position row
    // already owns `original_url` (v10), but a no-progress open writes no
    // tick yet — and `open()` saves the document first. Without this
    // column a relaunch between open and first tick drops provenance and
    // the row refetches the canonical URL. No backfill: pre-v12 documents
    // refetch from the canonical URL as before.
    migrator.registerMigration("v12_document_original_url") { db in
        try db.execute(sql: "ALTER TABLE document ADD COLUMN original_url TEXT")
    }

    // v13 backfills canonical URLs on rows written before canonicalization
    // on ingest. A pre-canonical `url` (case/tracking/fragment drift) never
    // equals the canonical input, so `siblingRows` would miss it and strand
    // a duplicate. One pass at migration time; `original_url` is provenance
    // and stays exactly as pasted. Only drifted rows are rewritten (the
    // canonical check skips the rest); the loop is Swift-side because plain
    // SQLite has no canonicalize function.
    migrator.registerMigration("v13_canonicalize_urls") { db in
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
    }

    // v14 backfills the position URL from the document row for pre-v5 rows.
    // v5 added `url` with no backfill, so those rows carry NULL — and the
    // canonical sibling gate needs a URL to compare, so without this they
    // would strand as duplicates forever. `total_words` heals from the
    // computed plan total in the same pass when the stored value is 0 (the
    // v5 shape: it renders the wrong place line). A nonzero-but-wrong
    // stored total is left alone — post-v5 writes are computed, so only a
    // hand edit could do that, and the next tick recomputes it anyway.
    // Negatives heal too (`<= 0`): writers never emit them, but a hand-set
    // -1 on a visited row must not survive in SQL. A decode failure still
    // writes 0 rather than the negative (clamped after the branch); rows
    // the loop never visits heal in memory at decode instead.
    // Computed, never the stored `spoken_words` field, which hand-made
    // plans can disagree with. `furthest` re-seeds from the word in the
    // same pass (never lowering a ticked value): the v7 backfill zeroed it
    // positionally (`max(total - 1, 0)` is 0 when total is 0), so without
    // this a finished pre-v5 row would offer as resumable until its next
    // tick.
    // The document URL is canonical post-v13. Rows whose document is gone
    // (released) keep NULL: they never had URL identity, and the sibling
    // filter falls back to their pasted link instead.
    // Swift-side loop like v13: totals need the plan decoder, which plain
    // SQLite has no access to. Only URL-less rows are visited (`''` counts:
    // ingest never writes it, but a hand edit could strand the row while
    // its NULL twin heals); a failed plan decode keeps the stored total
    // rather than zeroing it.
    migrator.registerMigration("v14_position_url_backfill") { db in
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
            // negative back. Heals the visited (URL-less) rows —
            // url/total/word/finished/furthest together, so SQL agrees with
            // what decode derives — except a live document with no URL of
            // its own (hand edit only): url stays NULL there and the row
            // relies on the pasted-link fallback. Rows the loop never
            // visits keep stored furthest until the next tick, and decode
            // clamps the word and derives finished/reachedEnd in memory. `min` ceilings a
            // hand-set overshoot; `max` keeps a ticked furthest a rewind
            // cannot lower.
            let healedTotal = max(0, healed)
            let clampedWord = min(max(word, 0), max(healedTotal - 1, 0))
            let seeded = min(max(furthest, clampedWord), max(healedTotal - 1, 0))
            let finished: Int = (healedTotal > 0 && clampedWord >= healedTotal - 1) ? 1 : 0
            try db.execute(sql: """
                UPDATE reading_position SET url = ?, total_words = ?, word_index = ?, finished = ?, furthest = ? WHERE content_hash = ?
                """, arguments: [url, healedTotal, clampedWord, finished, seeded, hash])
        }
    }

    // v15 indexes the sibling-lookup columns: `openAtPlace` runs
    // `siblingRows` (plus its COUNT gate) on every open, filtering on
    // unindexed `url`/`original_url`. Libraries are small, so this was
    // latency, not breakage — now a covered index instead of a full scan.
    migrator.registerMigration("v15_position_url_index") { db in
        try db.execute(sql: """
            CREATE INDEX idx_reading_position_url ON reading_position(url, original_url)
            """)
    }

    return migrator
}
