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

        // A missing row (double release, forget-after-release) logs nothing:
        // peers replaying a delete for a row they never saw just grow the log.
        try store.deleteDocument(id: document.id)
        try store.deleteDocument(id: UUID())
        #expect(try store.syncOplog.entries().count == 4)

        let seqs = entries.map(\.seq)
        #expect(seqs == seqs.sorted())
        #expect(Set(seqs).count == 4)
    }

    @Test("The document.save payload carries the one encoded plan")
    func documentSavePayloadSplicesThePlan() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://example.com/a?ref=paste")
        try store.save(document: document)

        let entry = try #require(try store.syncOplog.entries().first)
        #expect(entry.op == "document.save")
        // The payload still decodes as the full Document the log documents.
        let decoded = try JSONDecoder().decode(
            ReadLaterCore.Document.self, from: Data(entry.payload.utf8))
        #expect(decoded == document)
        // Both sinks use the same bytes, so a save encodes the plan once and
        // the stored plan cannot drift from the payload's. Compare against
        // the stored column, not a fresh encode: `JSONEncoder` does not
        // promise key order between encodes.
        let planJSON: String = try store.dbQueue.read { db in
            let value = try String.fetchOne(
                db, sql: "SELECT plan_json FROM document WHERE id = ?",
                arguments: [document.id.uuidString])
            return try #require(value)
        }
        #expect(entry.payload.contains(planJSON))
        #expect(try store.document(id: document.id) == document)
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

/// A database at v5, before the sync oplog was renamed. Built by the real
/// migrator, so every table the later migrations touch exists.
private func makeLegacyDatabase(at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try makeMigrator().migrate(queue, upTo: "v5_position_origin")
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO changelog(device, "at", op, payload) VALUES (?, ?, ?, ?)
            """, arguments: [
                "device-A", Date.now.timeIntervalSinceReferenceDate,
                "document.save", #"{"id":"abc"}"#,
            ])
    }
}
