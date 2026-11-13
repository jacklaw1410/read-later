import GRDB

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
    // evictable; a saved row is chosen by the reader and must survive a cache
    // bust. One flag separates the two, and it decides the delete rule.
    migrator.registerMigration("v4_saved") { db in
        try db.execute(sql: "ALTER TABLE reading_position ADD COLUMN saved INTEGER NOT NULL DEFAULT 0")
    }

    return migrator
}
