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

    return migrator
}
