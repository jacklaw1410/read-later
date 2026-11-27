import Foundation
import Testing
import ReadLaterCore
@testable import ReadLaterStore

/// M8 regression net: every store write logs one `store.write` event with
/// its write kind, duration and thread. A new write method with no event fails here.
@Suite("Store write timing (M8)")
struct StoreTimingTests {
    @Test("Every write kind logs one store.write event")
    func everyWriteOpLogsStoreWrite() throws {
        let hub = TelemetryHub()
        let (store, dir) = try makeTemporaryStore(telemetry: hub)
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let hash = Store.resumeKey(for: document)
        let phrase = Phrase(word: "attention", gloss: "the practice of focusing", source: "test")

        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 3, source: "test")
        try store.setSaved(contentHash: hash, saved: true)
        // Changed-content refetch retires the old row and seeds the new one.
        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "def"
        let document2 = Document(url: document.url, title: "Sample v2", plan: plan2)
        let oldRow = try #require(try store.position(contentHash: hash))
        try store.save(phrase: phrase)
        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 0, charOffset: 0)
        try store.syncOplog.append(op: "test.op", payload: "{}")
        try store.saveRawPage(
            RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!),
            for: document)
        try store.clearRescuedLink(contentHash: hash, documentID: document.id)
        try store.dismissPosition(contentHash: hash)
        try store.releaseCopy(documentID: document.id)
        try store.forget(contentHash: hash, documentID: document.id)
        try store.deleteDocument(id: document.id)
        // Last: the old row is already dismissed above, so this only seeds
        // the new hash row (saved carried from the captured old row).
        try store.supersedeOnRefetch(oldRow: oldRow, newDocument: document2, startWord: 1)
        // The single-row primitives stay covered: production routes through
        // the combined clear, but the primitives still log their own ops.
        try store.clearOriginalURL(contentHash: Store.resumeKey(for: document2))
        try store.clearDocumentOriginalURL(documentID: document2.id)

        let events = hub.telemetryLog.tail(60).filter { $0.event == TelemetryName.storeWrite }
        let ops = Set(events.compactMap { $0.fields["write"] })
        #expect(ops == [
            "store.migrate", "save.document", "record.position", "position.saved", "phrase.save",
            "occurrence.record", "oplog.append", "raw_page.save", "rescued_link.clear",
            "position.original_url.clear", "document.original_url.clear",
            "position.dismiss", "document.delete", "position.supersede",
        ])
        #expect(events.allSatisfy { $0.fields["ms"] != nil && $0.fields["main"] != nil })
        // The `main` flag only ever carries "1" (caller thread) or "0"
        // (recorder queue): any other value means the tag broke.
        #expect(events.allSatisfy { $0.fields["main"] == "1" || $0.fields["main"] == "0" })
        let position = events.first { $0.fields["write"] == "record.position" }
        #expect(position?.fields["word"] == "3")
        #expect(position?.fields["source"] == "test")
        // Encode/copy split: copy is the SQLite write (equals ms), encode is
        // the caller-side plan-to-words prep. Both parse as milliseconds.
        #expect(position?.fields["copyMs"] == position?.fields["ms"])
        #expect(Double(position?.fields["encodeMs"] ?? "") != nil)
        #expect(Double(position?.fields["copyMs"] ?? "") != nil)
    }

    @Test("Recorder writes the place and drains on wait")
    func recorderWritesPlaceAndDrains() throws {
        let hub = TelemetryHub()
        let (store, dir) = try makeTemporaryStore(telemetry: hub)
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        let recorder = PositionRecorder(store: store)
        recorder.record(document: document, wordIndex: 5, source: "pause")
        recorder.wait()

        let hash = Store.resumeKey(for: document)
        #expect(try store.position(contentHash: hash)?.wordIndex == 5)
        let events = hub.telemetryLog.tail(10).filter { $0.event == TelemetryName.storeWrite }
        let position = events.first { $0.fields["write"] == "record.position" }
        #expect(position?.fields["word"] == "5")
        #expect(position?.fields["source"] == "pause")
        // The recorder queue is off-main: its writes carry main == "0".
        #expect(position?.fields["main"] == "0")
    }
}
