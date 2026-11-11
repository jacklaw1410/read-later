import Foundation
import Testing
import ReadLaterCore
@testable import ReadLaterStore

@Suite("Store documents and phrases")
struct StoreTests {
    @Test("Document round-trips with its block plan intact")
    func documentRoundTrip() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        #expect(document.plan.blocks.count == 2)
        try store.save(document: document)

        let back = try store.document(id: document.id)
        #expect(back == document)
        #expect(back?.plan == document.plan)
        #expect(back?.plan.blocks.count == 2)

        #expect(try store.allDocuments() == [document])
    }

    @Test("Deleting a document removes its occurrences but keeps the phrase")
    func deleteDocumentCascadesOccurrences() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        let phrase = Phrase(word: "attention", gloss: "the practice of focusing", source: "test")
        try store.save(phrase: phrase)

        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 0, charOffset: 0)
        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 1, charOffset: 5)
        #expect(try store.occurrences(forPhrase: phrase.id).count == 2)

        try store.deleteDocument(id: document.id)

        #expect(try store.document(id: document.id) == nil)
        #expect(try store.occurrences(forPhrase: phrase.id).isEmpty)
        #expect(try store.phrases().map(\.id).contains(phrase.id))
    }

    @Test("Occurrence for a missing phrase or document throws (foreign keys on)")
    func occurrenceEnforcesForeignKeys() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        #expect(throws: (any Error).self) {
            try store.recordOccurrence(
                phraseID: UUID(), documentID: UUID(), blockID: 0, charOffset: 0)
        }
    }

    @Test("Reopening the same file keeps data without re-running migrations")
    func reopenKeepsData() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let phrase = Phrase(word: "attention", gloss: "the practice of focusing", source: "test")
        try store.save(document: document)
        try store.save(phrase: phrase)
        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 0, charOffset: 0)

        let url = dir.appendingPathComponent("store.sqlite")
        let reopened = try Store(databaseURL: url, device: "test-device")
        #expect(try reopened.document(id: document.id) == document)
        #expect(try reopened.phrases().map(\.id).contains(phrase.id))
        #expect(try reopened.occurrences(forPhrase: phrase.id).count == 1)
        #expect(try reopened.oplog.entries().count == 3)
    }
}
