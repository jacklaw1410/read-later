import Foundation
import Testing
import GRDB
import ReadLaterCore
@testable import ReadLaterStore

@Suite("Sync oplog")
struct SyncOplogTests {
    @Test("Every write appends exactly one entry with the expected op")
    func writesAppendOneEntryEach() throws {
        let (store, dir) = try makeTemporaryStore(device: "device-A")
        defer { removeTemporaryStore(at: dir) }

        #expect(try store.syncOplog.entries().isEmpty)

        let document = makeSampleDocument()
        try store.save(document: document)
        var entries = try store.syncOplog.entries()
        #expect(entries.count == 1)
        #expect(entries[0].op == "document.save")
        #expect(entries[0].device == "device-A")

        let phrase = Phrase(word: "attention", gloss: "the practice of focusing", source: "test")
        try store.save(phrase: phrase)
        entries = try store.syncOplog.entries()
        #expect(entries.count == 2)
        #expect(entries[1].op == "phrase.save")

        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 0, charOffset: 0)
        entries = try store.syncOplog.entries()
        #expect(entries.count == 3)
        #expect(entries[2].op == "occurrence.record")

        try store.deleteDocument(id: document.id)
        entries = try store.syncOplog.entries()
        #expect(entries.count == 4)
        #expect(entries[3].op == "document.delete")

        let seqs = entries.map(\.seq)
        #expect(seqs == seqs.sorted())
        #expect(Set(seqs).count == 4)
    }

    @Test("Entries page after a cursor with a limit")
    func entriesPageAfterCursor() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        try store.syncOplog.append(op: "probe.one", payload: "{}")
        try store.syncOplog.append(op: "probe.two", payload: "{}")
        try store.syncOplog.append(op: "probe.three", payload: "{}")

        let all = try store.syncOplog.entries()
        #expect(all.count == 3)

        let page = try store.syncOplog.entries(after: all[0].seq, limit: 1)
        #expect(page.count == 1)
        #expect(page[0].op == "probe.two")

        let tail = try store.syncOplog.entries(after: all[1].seq)
        #expect(tail.map(\.op) == ["probe.three"])
    }

    @Test("The v6 migration keeps rows, seq, device and payload")
    func v6RenamePreservesEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreV6Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.sqlite")
        try makeLegacyDatabase(at: url)

        let store = try Store(databaseURL: url, device: "device-B", telemetry: TelemetryHub())
        let entries = try store.syncOplog.entries()
        #expect(entries.count == 1)
        #expect(entries[0].seq == 1)
        #expect(entries[0].device == "device-A")
        #expect(entries[0].op == "document.save")
        #expect(entries[0].payload == #"{"id":"abc"}"#)
    }
}

/// A database at v5, before the sync oplog was renamed. Migration v6 must
/// rename the table without rewriting its rows.
private func makeLegacyDatabase(at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY)")
        for name in ["v1_initial", "v2_fts", "v3_positions", "v4_saved", "v5_position_origin"] {
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)", arguments: [name])
        }
        try db.execute(sql: """
            CREATE TABLE changelog(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                device TEXT NOT NULL,
                "at" REAL NOT NULL,
                op TEXT NOT NULL,
                payload TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            INSERT INTO changelog(device, "at", op, payload) VALUES (?, ?, ?, ?)
            """, arguments: [
                "device-A", Date.now.timeIntervalSinceReferenceDate,
                "document.save", #"{"id":"abc"}"#,
            ])
    }
}
