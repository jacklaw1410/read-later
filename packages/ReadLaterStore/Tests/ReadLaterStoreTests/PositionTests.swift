import Foundation
import Testing
import ReadLaterCore
@testable import ReadLaterStore

@Suite("Reading position and write throttle")
struct PositionTests {
    @Test("Position round-trips by content hash")
    func roundTripByHash() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 3)

        let back = try store.position(contentHash: Store.resumeKey(for: document))
        #expect(back?.wordIndex == 3)
        #expect(back?.finished == false)
        #expect(back?.title == document.title)
        #expect(back?.documentID == document.id)
    }

    @Test("Re-pasted article keeps one row under the same hash")
    func repasteKeepsOneRow() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let first = makeSampleDocument()
        try store.save(document: first)
        try store.recordPosition(of: first, wordIndex: 2)

        var second = makeSampleDocument()
        second.id = UUID()
        try store.save(document: second)
        try store.recordPosition(of: second, wordIndex: 5)

        let back = try store.position(contentHash: Store.resumeKey(for: first))
        #expect(back?.wordIndex == 5)
        #expect(back?.documentID == second.id)
    }

    @Test("Empty plan hash falls back to the document id")
    func emptyHashFallsBackToDocumentID() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.plan.sourceSHA256 = ""
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)

        #expect(Store.resumeKey(for: document) == "doc:\(document.id.uuidString)")
        #expect(try store.position(documentID: document.id)?.wordIndex == 1)
    }

    @Test("Last spoken word marks the article finished and hides the offer")
    func finishRuleIsLastWord() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let total = SpokenIndex(plan: document.plan).totalWords
        #expect(total > 1)
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: total - 1)

        let back = try store.position(contentHash: Store.resumeKey(for: document))
        #expect(back?.finished == true)
        #expect(try store.latestUnfinishedPosition() == nil)
    }

    @Test("Latest unfinished offer is the newest unfinished article")
    func latestUnfinishedSkipsFinished() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let old = makeSampleDocument()
        try store.save(document: old)
        try store.recordPosition(of: old, wordIndex: 1, at: Date(timeIntervalSinceReferenceDate: 100))

        var finished = makeSampleDocument()
        finished.plan.sourceSHA256 = "deadbeef"
        try store.save(document: finished)
        let finishedTotal = SpokenIndex(plan: finished.plan).totalWords
        try store.recordPosition(
            of: finished, wordIndex: finishedTotal - 1,
            at: Date(timeIntervalSinceReferenceDate: 200))

        var fresh = makeSampleDocument()
        fresh.plan.sourceSHA256 = "cafe"
        try store.save(document: fresh)
        try store.recordPosition(of: fresh, wordIndex: 2, at: Date(timeIntervalSinceReferenceDate: 300))

        #expect(try store.latestUnfinishedPosition()?.contentHash == Store.resumeKey(for: fresh))
    }

    @Test("Dismiss removes the offer until the next pause re-records")
    func dismissRemovesOffer() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 4)
        try store.dismissPosition(contentHash: Store.resumeKey(for: document))

        #expect(try store.latestUnfinishedPosition() == nil)
    }

    @Test("Positions survive a reopen without re-running migrations")
    func reopenKeepsPositions() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 6)

        let url = dir.appendingPathComponent("store.sqlite")
        let reopened = try Store(databaseURL: url, device: "test-device")
        #expect(try reopened.position(contentHash: Store.resumeKey(for: document))?.wordIndex == 6)
        #expect(try reopened.oplog.entries().count == 1)
    }

    @Test("Throttle writes once per interval and always on demand")
    func throttleGatesWrites() {
        var throttle = PositionWriteThrottle(interval: 5)
        let start = Date(timeIntervalSinceReferenceDate: 1000)

        let first = throttle.shouldWrite(now: start)
        let tooSoon = throttle.shouldWrite(now: start.addingTimeInterval(1))
        let due = throttle.shouldWrite(now: start.addingTimeInterval(5))
        #expect(first)
        #expect(!tooSoon)
        #expect(due)

        throttle.recordNow(at: start.addingTimeInterval(10))
        let afterForced = throttle.shouldWrite(now: start.addingTimeInterval(11))
        #expect(!afterForced)
    }
}
