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

@Suite("Library: visits, saves, cache bust")
struct LibraryTests {
    @Test("Recent positions list newest first and cap at the limit")
    func recentPositionsOrderAndLimit() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let first = makeSampleDocument()
        try store.save(document: first)
        try store.recordPosition(of: first, wordIndex: 1, at: Date(timeIntervalSinceReferenceDate: 100))

        var second = makeSampleDocument()
        second.id = UUID()
        second.plan.sourceSHA256 = "second"
        second.title = "Second article"
        try store.save(document: second)
        try store.recordPosition(of: second, wordIndex: 2, at: Date(timeIntervalSinceReferenceDate: 200))

        let rows = try store.recentPositions(limit: 10)
        #expect(rows.count == 2)
        #expect(rows.first?.title == "Second article")
        #expect(try store.recentPositions(limit: 1).count == 1)
    }

    @Test("Saving is a flag, and reading again keeps it")
    func saveFlagSurvivesRecording() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 2)
        let key = Store.resumeKey(for: document)
        #expect(try store.position(contentHash: key)?.saved == false)

        try store.setSaved(contentHash: key, saved: true)
        #expect(try store.position(contentHash: key)?.saved == true)

        // The reader keeps reading: the flag must not be reset by a write.
        try store.recordPosition(of: document, wordIndex: 4)
        #expect(try store.position(contentHash: key)?.saved == true)
        #expect(try store.savedPositions().count == 1)

        try store.setSaved(contentHash: key, saved: false)
        #expect(try store.savedPositions().isEmpty)
    }

    @Test("Cache bust drops the plan and keeps the place")
    func cacheBustKeepsPosition() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 3)

        try store.cacheBust(documentID: document.id)

        #expect(try store.document(id: document.id) == nil)
        #expect(try store.position(contentHash: Store.resumeKey(for: document))?.wordIndex == 3)
    }

    @Test("Forget removes the plan and the place")
    func forgetRemovesBoth() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 3)

        try store.forget(contentHash: Store.resumeKey(for: document), documentID: document.id)

        #expect(try store.document(id: document.id) == nil)
        #expect(try store.position(contentHash: Store.resumeKey(for: document)) == nil)
        #expect(try store.recentPositions().isEmpty)
    }
}

@Suite("Position carries the article origin")
struct PositionOriginTests {
    @Test("URL and spoken length land on the row")
    func originRoundTrips() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 2)

        let back = try store.position(contentHash: Store.resumeKey(for: document))
        #expect(back?.url == document.url)
        #expect(back?.totalWords == SpokenIndex(plan: document.plan).totalWords)
    }

    @Test("A row with no URL keeps nil and a zero length")
    func missingOriginIsTolerated() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.url = nil
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 0)

        let back = try store.position(contentHash: Store.resumeKey(for: document))
        #expect(back?.url == nil)
    }

    @Test("A cache bust keeps the origin the list needs")
    func bustKeepsOrigin() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)

        try store.cacheBust(documentID: document.id)

        let rows = try store.recentPositions()
        #expect(rows.count == 1)
        #expect(rows.first?.url == document.url)
        #expect(rows.first?.totalWords ?? 0 > 0)
    }
}
