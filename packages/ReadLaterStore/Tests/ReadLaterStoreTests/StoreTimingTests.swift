import Foundation
import Testing
import ReadLaterCore
@testable import ReadLaterStore

/// M8 regression net: every store write logs one `store.write` event with
/// its op, duration and thread. A new write method with no event fails here.
@Suite("Store write timing (M8)")
struct StoreTimingTests {
    @Test("Every write op logs one store.write event")
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
        try store.save(phrase: phrase)
        try store.recordOccurrence(phraseID: phrase.id, documentID: document.id, blockID: 0, charOffset: 0)
        try store.oplog.append(op: "test.op", payload: "{}")
        try store.dismissPosition(contentHash: hash)
        try store.cacheBust(documentID: document.id)
        try store.forget(contentHash: hash, documentID: document.id)
        try store.deleteDocument(id: document.id)

        let events = hub.oplog.tail(50).filter { $0.event == TelemetryName.storeWrite }
        let ops = Set(events.compactMap { $0.fields["op"] })
        #expect(ops == [
            "save.document", "record.position", "position.saved", "phrase.save",
            "occurrence.record", "oplog.append", "position.dismiss",
            "document.delete",
        ])
        #expect(events.allSatisfy { $0.fields["ms"] != nil && $0.fields["main"] != nil })
        #expect(events.allSatisfy { $0.fields["main"] == "1" || $0.fields["main"] == "0" })
        let position = events.first { $0.fields["op"] == "record.position" }
        #expect(position?.fields["word"] == "3")
        #expect(position?.fields["source"] == "test")
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
        let events = hub.oplog.tail(10).filter { $0.event == TelemetryName.storeWrite }
        let position = events.first { $0.fields["op"] == "record.position" }
        #expect(position?.fields["word"] == "5")
        #expect(position?.fields["source"] == "pause")
    }
}
