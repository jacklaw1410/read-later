import Foundation
import ReadLaterCore
import Testing
@testable import ReadLaterStore

@Suite("Raw page keeps the fetched HTML")
struct RawPageTests {
    @Test("Saved page round-trips byte for byte, including non-ASCII")
    func roundTrip() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let html = "<html><body><p>讀後感 — café &amp; ünïcödé 🙂</p></body></html>"
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let page = RawPage(
            html: html, status: 200,
            finalURL: URL(string: "https://example.com/a")!, fetchedAt: fetchedAt)

        try store.saveRawPage(page, for: document)
        let back = try store.rawPage(contentHash: Store.resumeKey(for: document))
        #expect(back == page)
        #expect(back?.html.utf8.elementsEqual(html.utf8) == true)
    }

    @Test("Unknown hash returns nil")
    func missingPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }
        #expect(try store.rawPage(contentHash: "no-such-hash") == nil)
    }

    @Test("Deleting the article deletes its raw page")
    func deletedWithArticle() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.save(document: document)
        try store.saveRawPage(page, for: document)
        #expect(try store.rawPage(contentHash: Store.resumeKey(for: document)) != nil)

        try store.deleteDocument(id: document.id)
        #expect(try store.rawPage(contentHash: Store.resumeKey(for: document)) == nil)
    }

    @Test("Deleting one of two same-hash articles keeps the raw page")
    func sharedHashKeepsRawPageUntilLastDocument() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Same bytes, two ids: a re-fetch mints a new document row.
        let first = makeSampleDocument()
        let second = makeSampleDocument()
        try store.save(document: first)
        try store.save(document: second)
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(page, for: second)
        let key = Store.resumeKey(for: second)

        try store.deleteDocument(id: first.id)
        #expect(try store.rawPage(contentHash: key) != nil)

        try store.deleteDocument(id: second.id)
        #expect(try store.rawPage(contentHash: key) == nil)
    }

    @Test("Double delete sweeps the orphan raw page")
    func doubleDeleteSweepsOrphanRawPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(page, for: document)
        let key = Store.resumeKey(for: document)

        // Row already gone (double-tap release, retried refetch): the hash
        // lookup finds nothing, but the raw page filed under this id still
        // sweeps when no sibling reads the bytes.
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM document WHERE id = ?", arguments: [document.id.uuidString])
        }
        #expect(try store.rawPage(contentHash: key) != nil)
        try store.deleteDocument(id: document.id)
        #expect(try store.rawPage(contentHash: key) == nil)
    }

    @Test("Deleting a NULL-sha (corrupt-plan) document sweeps its raw page")
    func nullShaDeleteSweepsRawPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // v10 backfills source_sha256 = NULL when plan_json will not parse.
        // The delete falls back to `doc:<id>` for the hash scope, but the
        // id-scoped orphan sweep still finds the page filed under this id.
        let document = makeSampleDocument()
        try store.save(document: document)
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(page, for: document)
        let key = Store.resumeKey(for: document)
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE document SET plan_json = 'not json', source_sha256 = NULL WHERE id = ?",
                           arguments: [document.id.uuidString])
        }

        try store.deleteDocument(id: document.id)
        #expect(try store.rawPage(contentHash: key) == nil)
    }

    @Test("Normal delete sweeps a raw page filed under a mutated hash")
    func normalDeleteSweepsMismatchedRawPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Same id, mutated plan: the API permits it, and the raw page keys
        // the new hash while the stored row still carries the old one. Only
        // the id filing finds it on delete.
        let document = makeSampleDocument()
        try store.save(document: document)
        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "other"
        let mutated = Document(id: document.id, url: document.url, title: document.title, plan: plan2)
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(page, for: mutated)
        let mutatedKey = Store.resumeKey(for: mutated)
        #expect(mutatedKey != Store.resumeKey(for: document))

        try store.deleteDocument(id: document.id)
        #expect(try store.rawPage(contentHash: mutatedKey) == nil)
    }

    @Test("Supersede sweeps a raw page filed under a mutated hash")
    func supersedeSweepsMismatchedRawPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Old article with its raw page, plus a second raw page keyed by a
        // mutated plan filed under the same document id. Supersede retires
        // the old document row, so both pages must go — the hash-scoped
        // delete alone would strand the mismatched one.
        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 2)
        let oldKey = Store.resumeKey(for: document)
        let oldPage = RawPage(html: "<p>old</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(oldPage, for: document)
        var mutatedPlan = makeSamplePlan()
        mutatedPlan.sourceSHA256 = "mismatched"
        let mutated = Document(id: document.id, url: document.url, title: document.title, plan: mutatedPlan)
        let orphanPage = RawPage(html: "<p>orphan</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(orphanPage, for: mutated)
        let orphanKey = Store.resumeKey(for: mutated)
        #expect(orphanKey != oldKey)

        let oldRow = try #require(try store.position(contentHash: oldKey))
        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "def"
        let document2 = Document(url: document.url, title: "Sample v2", plan: plan2)
        try store.save(document: document2)
        try store.supersedeOnRefetch(oldRow: oldRow, newDocument: document2, startWord: 1)

        #expect(try store.rawPage(contentHash: oldKey) == nil)
        #expect(try store.rawPage(contentHash: orphanKey) == nil)
    }

    @Test("Same-id supersede sweeps the old-hash raw page and keeps the live row")
    func sameIDSupersedeSweepsOldHashPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Same id re-saved with changed bytes, then retired: the document
        // row is live (must survive), the old-hash page must go, the new
        // page stays.
        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 2)
        let oldKey = Store.resumeKey(for: document)
        try store.saveRawPage(
            RawPage(html: "<p>old</p>", status: 200, finalURL: URL(string: "https://example.com/a")!),
            for: document)
        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "v2"
        let mutated = Document(id: document.id, url: document.url, title: "Sample v2", plan: plan2)
        try store.save(document: mutated)
        try store.saveRawPage(
            RawPage(html: "<p>new</p>", status: 200, finalURL: URL(string: "https://example.com/a")!),
            for: mutated)
        let newKey = Store.resumeKey(for: mutated)
        #expect(newKey != oldKey)

        let oldRow = try #require(try store.position(contentHash: oldKey))
        // Save-before-supersede ordering (production: openAtPlace → open()
        // saves synchronously): the mutated row is live, so the sibling
        // guard keeps the new page while sweeping the old one.
        try store.supersedeOnRefetch(oldRow: oldRow, newDocument: mutated, startWord: 1)

        #expect(try store.rawPage(contentHash: oldKey) == nil)
        #expect(try store.rawPage(contentHash: newKey) != nil)
        #expect(try store.position(contentHash: oldKey) == nil)
        #expect(try store.position(contentHash: newKey)?.wordIndex == 1)
        #expect(try store.document(id: document.id)?.plan.sourceSHA256 == "v2")
    }

    @Test("Recorder persists the raw page once the queue drains")
    func recorderPersistsRawPage() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        let recorder = PositionRecorder(store: store)
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        recorder.persistRawPage(page, for: document)
        recorder.wait()
        #expect(try store.rawPage(contentHash: Store.resumeKey(for: document)) == page)
    }

    @Test("Recorder clears the original behind queued ticks")
    func recorderClearsOriginalURL() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://short.link/x")
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)

        let recorder = PositionRecorder(store: store)
        // A tick carrying the dead link lands first, the clear last: FIFO
        // keeps the row cleared without blocking the caller.
        recorder.record(document: document, wordIndex: 2, source: "test")
        recorder.clearOriginalURL(contentHash: key)
        recorder.wait()
        let back = try #require(try store.position(contentHash: key))
        #expect(back.originalURL == nil)
        #expect(back.wordIndex == 2)
    }
}
