import Foundation
import Testing
import ReadLaterCore
@testable import ReadLaterStore

@Suite("Operation log")
struct OplogTests {
    @Test("Every write appends exactly one entry with the expected op")
    func writesAppendOneEntryEach() throws {
        let (store, dir) = try makeTemporaryStore(device: "device-A")
        defer { removeTemporaryStore(at: dir) }

        #expect(try store.oplog.entries().isEmpty)

        let document = makeSampleDocument()
        try store.save(document: document)
        var entries = try store.oplog.entries()
        #expect(entries.count == 1)
        #expect(entries[0].op == "document.save")
        #expect(entries[0].device == "device-A")

        let phrase = Phrase(word: "attention", gloss: "the practice of focusing", source: "test")
        try store.save(phrase: phrase)
        entries = try store.oplog.entries()
        #expect(entries.count == 2)
        #expect(entries[1].op == "phrase.save")

        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 0, charOffset: 0)
        entries = try store.oplog.entries()
        #expect(entries.count == 3)
        #expect(entries[2].op == "occurrence.record")

        try store.deleteDocument(id: document.id)
        entries = try store.oplog.entries()
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

        try store.oplog.append(op: "probe.one", payload: "{}")
        try store.oplog.append(op: "probe.two", payload: "{}")
        try store.oplog.append(op: "probe.three", payload: "{}")

        let all = try store.oplog.entries()
        #expect(all.count == 3)

        let page = try store.oplog.entries(after: all[0].seq, limit: 1)
        #expect(page.count == 1)
        #expect(page[0].op == "probe.two")

        let tail = try store.oplog.entries(after: all[1].seq)
        #expect(tail.map(\.op) == ["probe.three"])
    }
}
