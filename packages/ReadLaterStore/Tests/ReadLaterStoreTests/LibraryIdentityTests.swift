import Foundation
import GRDB
import Testing
import ReadLaterCore
@testable import ReadLaterStore

/// Library-identity placeholder schema (research `spec/library-identity.md`
/// §§5-6, SCOPE §5 2026-11-16, F35 §1): Version holds `furthest` per version,
/// Entry holds human `markedDone`, `reachedEnd` derives and is never stored.
@Suite("Library identity placeholder schema")
struct LibraryIdentityTests {
    @Test("Furthest is monotonic across re-opens")
    func furthestNeverRegresses() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        let key = Store.resumeKey(for: document)
        try store.recordPosition(of: document, wordIndex: 5)
        #expect(try store.position(contentHash: key)?.furthest == 5)

        // Re-open earlier: current index moves back, furthest stays.
        try store.recordPosition(of: document, wordIndex: 2)
        let back = try store.position(contentHash: key)
        #expect(back?.wordIndex == 2)
        #expect(back?.furthest == 5)
    }

    @Test("ReachedEnd derives from furthest, never stored")
    func reachedEndIsDerived() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let total = SpokenWordNumbering(plan: document.plan).totalWords
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)

        let key = Store.resumeKey(for: document)
        #expect(try store.position(contentHash: key)?.reachedEnd == false)

        try store.recordPosition(of: document, wordIndex: total - 1)
        #expect(try store.position(contentHash: key)?.reachedEnd == true)

        // After reaching the end, an earlier re-open still reports reached:
        // furthest, not the current index, decides.
        try store.recordPosition(of: document, wordIndex: 0)
        #expect(try store.position(contentHash: key)?.reachedEnd == true)

        #expect(ReadingPosition.isReachedEnd(furthest: 0, totalWords: 0) == false)
    }

    @Test("MarkedDone defaults false and survives re-reads")
    func markedDoneDefaultSurvivesRereads() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        let key = Store.resumeKey(for: document)
        try store.recordPosition(of: document, wordIndex: 2)
        #expect(try store.position(contentHash: key)?.markedDone == false)

        // The reader keeps reading: re-reads never set the human mark.
        // (No setter: nothing in the app writes markedDone yet. The column
        // and migration stay so the placeholder needs no re-migration.)
        try store.recordPosition(of: document, wordIndex: 3)
        #expect(try store.position(contentHash: key)?.markedDone == false)
    }

    @Test("Extractor version lands on the row, default zero")
    func extractorVersionRecorded() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        #expect(try store.position(contentHash: Store.resumeKey(for: document))?.extractorVersion == 0)

        var upgraded = makeSampleDocument()
        upgraded.plan.extractorVersion = 7
        upgraded.plan.sourceSHA256 = "new-parser-same-text"
        try store.save(document: upgraded)
        try store.recordPosition(of: upgraded, wordIndex: 1)
        #expect(try store.position(contentHash: Store.resumeKey(for: upgraded))?.extractorVersion == 7)
    }

    @Test("Resolve keeps the word on the same hash, migrates on a new one")
    func resolveMigratesAcrossVersions() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Same bytes: the stored word survives, clamped.
        #expect(store.resolve(row: row, newPlan: document.plan).start == 5)

        // Same text under a new hash, typo in the other sentence: the anchor
        // of sentence 0 still hits, so resume lands at its start, 0.
        var edited = makeSamplePlan()
        edited.blocks[1].text = "The mind wandres, and that is normal."
        edited.blocks[1].spoken = [Sentence(offset: 0, length: edited.blocks[1].text.count, text: edited.blocks[1].text)]
        edited.sourceSHA256 = "new-hash-same-text"
        #expect(store.resolve(row: row, newPlan: edited).start == 0)
    }

    @Test("Same hash with a newer parser falls through to the anchor path")
    func resolveSameHashNewParserReanchors() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Same bytes, same parser: fast path keeps the word, no rewrite.
        #expect(store.resolve(row: row, newPlan: document.plan) == (5, false))

        // Same hash but a rebuilt parser with re-split text: the fast path
        // must not fire — the anchor path sees wholly new text at a much
        // greater length, so the gate trips and the reader restarts at top.
        var resplit = makeSamplePlan()
        resplit.sourceSHA256 = document.plan.sourceSHA256
        resplit.extractorVersion = document.plan.extractorVersion + 1
        let longText = "Completely rewritten filler sentence for the new parse."
        resplit.blocks = (0..<12).map { i in
            Block(id: i, kind: .prose, confidence: 0.9, reason: "p", text: longText,
                  spoken: [Sentence(offset: 0, length: longText.count, text: longText)])
        }
        #expect(store.resolve(row: row, newPlan: resplit) == (0, true))
    }

    @Test("Same hash with a newer parser keeps the word when totals agree")
    func resolveSameHashNewParserKeepsWord() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        // Word 5 sits mid-sentence (sentence 0 starts at 0): the anchor
        // path would return the sentence start, losing precision.
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Same bytes, same splits, newer parser build: totals agree, so the
        // precise word survives with no rewrite note.
        var rebuilt = document.plan
        rebuilt.extractorVersion = row.extractorVersion + 1
        #expect(store.resolve(row: row, newPlan: rebuilt) == (5, false))
    }

    @Test("Same version keeps the word without anchor proof (branch pin)")
    func resolveSameVersionKeepsWord() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Branch pin, not a production shape: the hash covers the bytes, so
        // reworded text with the same hash cannot occur outside a hand-made
        // row — and a nondeterministic same-version parser is untestable
        // without the parser. This locks the arm's behavior (keep, no
        // proof) so revisiting determinism revisits this test, not silence.
        var resplit = makeSamplePlan()
        let first = "Zebra quilt xenon jigsaw vivid orbit"
        let second = "Attention is a practice not repeatedly retold daily"
        resplit.blocks = [
            Block(id: 0, kind: .prose, confidence: 0.9, reason: "p", text: first,
                  spoken: [Sentence(offset: 0, length: first.count, text: first)]),
            Block(id: 1, kind: .prose, confidence: 0.9, reason: "p", text: second,
                  spoken: [Sentence(offset: 0, length: second.count, text: second)]),
        ]
        #expect(resplit.sourceSHA256 == row.contentHash)
        #expect(resplit.extractorVersion == row.extractorVersion)
        #expect(SpokenWordNumbering(plan: resplit).totalWords == row.totalWords)
        #expect(store.resolve(row: row, newPlan: resplit) == (5, false))
    }

    @Test("Same hash with truncated totals re-anchors instead of clamping")
    func resolveSameHashTruncatedReanchors() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        // Word 10 sits in the second sentence; the truncated plan drops
        // that sentence entirely.
        try store.recordPosition(of: document, wordIndex: 10)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Same hash, same parser, shorter totals: the blind clamp would
        // keep 6 and point at unrelated text. The anchor path sees the
        // anchor is gone with a 50 % delta, so the gate trips.
        var truncated = makeSamplePlan()
        truncated.blocks = [truncated.blocks[0]]
        #expect(truncated.sourceSHA256 == row.contentHash)
        #expect(truncated.extractorVersion == row.extractorVersion)
        #expect(store.resolve(row: row, newPlan: truncated) == (0, true))
    }

    @Test("Same total with a re-split parser re-anchors instead of keeping")
    func resolveSameTotalResplitReanchors() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Same bytes, same total, bumped parser — but the sentences were
        // re-split and reworded: the old anchor is gone, while its head
        // survives in the second sentence. A blind keep would return 5;
        // the anchor path follows the unique fuzzy head to 6.
        var resplit = makeSamplePlan()
        resplit.extractorVersion = row.extractorVersion + 1
        let first = "Zebra quilt xenon jigsaw vivid orbit"
        let second = "Attention is a practice not repeatedly retold daily"
        resplit.blocks = [
            Block(id: 0, kind: .prose, confidence: 0.9, reason: "p", text: first,
                  spoken: [Sentence(offset: 0, length: first.count, text: first)]),
            Block(id: 1, kind: .prose, confidence: 0.9, reason: "p", text: second,
                  spoken: [Sentence(offset: 0, length: second.count, text: second)]),
        ]
        #expect(resplit.sourceSHA256 == row.contentHash)
        #expect(SpokenWordNumbering(plan: resplit).totalWords == row.totalWords)
        #expect(store.resolve(row: row, newPlan: resplit) == (6, false))
    }

    @Test("Same total with a moved anchor follows the hit instead of keeping")
    func resolveSameTotalMovedAnchorFollowsHit() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Same bytes, same total, bumped parser — but the anchored sentence
        // moved: a new 7-word sentence leads, the verbatim anchor sentence
        // shifts 0..<7 to 7..<14. Word 5 sits outside the moved span, so the
        // keep would resume mid-wrong-sentence with no note; following the
        // hit returns its new start instead.
        let movedText = "Attention is a practice, not a talent."
        let leadText = "Zebra quilt xenon jigsaw vivid orbit today"
        var moved = makeSamplePlan()
        moved.extractorVersion = row.extractorVersion + 1
        moved.blocks = [
            Block(id: 0, kind: .prose, confidence: 0.9, reason: "p", text: leadText,
                  spoken: [Sentence(offset: 0, length: leadText.count, text: leadText)]),
            Block(id: 1, kind: .prose, confidence: 0.9, reason: "p", text: movedText,
                  spoken: [Sentence(offset: 0, length: movedText.count, text: movedText)]),
        ]
        #expect(moved.sourceSHA256 == row.contentHash)
        #expect(SpokenWordNumbering(plan: moved).totalWords == row.totalWords)
        #expect(store.resolve(row: row, newPlan: moved) == (7, false))
    }

    @Test("Anchorless legacy row keeps the exact word, not the proportion")
    func resolveAnchorlessLegacyKeepsExactWord() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // 100 one-word sentences: Double(29) / Double(100) * Double(100)
        // truncates to 28, so the float proportion demonstrably shifts.
        let words = (0..<100).map { "Word\($0)" }
        let blocks = words.enumerated().map { i, w in
            Block(id: i, kind: .prose, confidence: 0.9, reason: "p", text: w + ".",
                  spoken: [Sentence(offset: 0, length: w.count + 1, text: w + ".")])
        }
        var legacyPlan = BlockPlan(source: "legacy", sourceSHA256: "legacy-bytes", blocks: blocks)
        legacyPlan.extractorVersion = 0
        let document = Document(url: URL(string: "https://example.com/legacy"),
                                title: "Legacy", plan: legacyPlan)
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 29)
        let key = Store.resumeKey(for: document)
        var row = try #require(try store.position(contentHash: key))
        // Simulate the pre-v7 row: anchor never stamped, parser predates
        // the current build, totals agree.
        row.anchorHash = ""
        row.anchorHead = ""
        #expect(row.totalWords == 100)

        var rebuilt = legacyPlan
        rebuilt.extractorVersion = 1
        #expect(store.resolve(row: row, newPlan: rebuilt) == (29, false))
    }

    @Test("Same hash with lying stored counts resolves on computed totals")
    func lyingCountsResolveOnComputedTotals() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let key = Store.resumeKey(for: document)
        let row = try #require(try store.position(contentHash: key))

        // Valid blocks, lying field: the computed total agrees, so the
        // exact word survives — the lie never makes the article unreadable.
        var lying = document.plan
        lying.spokenWords = -1
        #expect(SpokenWordNumbering(plan: lying).totalWords == row.totalWords)
        #expect(store.resolve(row: row, newPlan: lying) == (5, false))
    }

    @Test("Empty plans start at zero")
    func resolveEmptyPlan() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 5)
        let row = try #require(try store.position(contentHash: Store.resumeKey(for: document)))

        let empty = BlockPlan(source: "x", sourceSHA256: "y", blocks: [])
        #expect(store.resolve(row: row, newPlan: empty).start == 0)
    }

    @Test("Reached end is not offered again after a re-open at word zero")
    func reachedEndNotOffered() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        let total = SpokenWordNumbering(plan: document.plan).totalWords
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: total - 1)
        // Re-open at the top: mechanical flag clears, furthest does not.
        try store.recordPosition(of: document, wordIndex: 0)
        let row = try #require(try store.position(contentHash: Store.resumeKey(for: document)))
        #expect(row.finished == false)
        #expect(row.reachedEnd == true)
        #expect(try store.latestUnfinishedPosition() == nil)

        // Control: an unread article under its own hash is still offered.
        var otherPlan = makeSamplePlan()
        otherPlan.sourceSHA256 = "other-article"
        let other = Document(url: URL(string: "https://example.com/other"), title: "Other", plan: otherPlan)
        try store.save(document: other)
        try store.recordPosition(of: other, wordIndex: 0)
        #expect(try store.latestUnfinishedPosition()?.contentHash == Store.resumeKey(for: other))
    }

    @Test("An empty plan derives unreached but is never offered")
    func emptyPlanNotOffered() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let empty = Document(
            url: URL(string: "https://example.com/empty"), title: "Empty",
            plan: BlockPlan(source: "x", sourceSHA256: "empty-hash", blocks: []))
        try store.save(document: empty)
        try store.recordPosition(of: empty, wordIndex: 0)
        let key = Store.resumeKey(for: empty)
        let row = try #require(try store.position(contentHash: key))
        #expect(row.totalWords == 0)
        #expect(row.reachedEnd == false)
        // Zero words is never "reached", but there is nothing to resume:
        // the offer skips it instead of opening an empty reader at 0.
        #expect(try store.latestUnfinishedPosition() == nil)
    }

    @Test("Same-hash re-record updates the extractor version")
    func sameHashUpdatesExtractorVersion() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)
        #expect(try store.position(contentHash: key)?.extractorVersion == 0)

        // Same bytes, new parser build: the row follows without a new version.
        var rebuilt = document
        rebuilt.plan.extractorVersion = 3
        try store.recordPosition(of: rebuilt, wordIndex: 2)
        #expect(try store.position(contentHash: key)?.extractorVersion == 3)
    }

    @Test("Original URL rides the position row and survives re-records")
    func originalURLRoundTrip() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://short.link/x?utm_source=feed")
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)
        #expect(try store.position(contentHash: key)?.originalURL?.absoluteString == "https://short.link/x?utm_source=feed")

        // Re-records without an original keep the first one: the paste
        // happened once, the ticks that follow carry no link. A nil never
        // wipes; a new non-nil replaces (last non-nil wins).
        var reread = document
        reread.originalURL = nil
        try store.recordPosition(of: reread, wordIndex: 2)
        #expect(try store.position(contentHash: key)?.originalURL?.absoluteString == "https://short.link/x?utm_source=feed")

        var repasted = document
        repasted.originalURL = URL(string: "https://short.link/y")
        try store.recordPosition(of: repasted, wordIndex: 3)
        #expect(try store.position(contentHash: key)?.originalURL?.absoluteString == "https://short.link/y")
    }

    @Test("A nil re-record keeps the canonical URL too")
    func nilRerecordKeepsCanonicalURL() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)
        let canonical = try #require(try store.position(contentHash: key)?.url)

        // Pasted text arrives with no URL. The row keeps the earlier link.
        var pasted = document
        pasted.url = nil
        try store.recordPosition(of: pasted, wordIndex: 2)
        #expect(try store.position(contentHash: key)?.url == canonical)
    }

    @Test("Negative stored index clamps to zero on the fast path")
    func negativeIndexClamps() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)
        var row = try #require(try store.position(contentHash: key))
        row.wordIndex = -5
        #expect(store.resolve(row: row, newPlan: document.plan).start == 0)
        #expect(store.resolve(row: row, newPlan: document.plan).rewrote == false)
    }

    @Test("Same hash never reports a rewrite")
    func sameHashNeverRewrites() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)
        var row = try #require(try store.position(contentHash: key))
        // Anchor wiped and text drifted in the plan object, but the bytes
        // key matches: no rewrite note either way. Totals disagree (a
        // corrupt count — same bytes imply same splits), so the fast path
        // yields to the anchor path, which lands on proportion for an
        // anchorless row rather than the blind clamp.
        row.anchorHash = ""
        row.anchorHead = ""
        var drifted = document.plan
        drifted.blocks = drifted.blocks + drifted.blocks + drifted.blocks
        #expect(SpokenWordNumbering(plan: drifted).totalWords > SpokenWordNumbering(plan: document.plan).totalWords)
        #expect(store.resolve(row: row, newPlan: drifted) == (3, false))
    }

    @Test("Document round-trips the pasted link with no tick yet")
    func documentKeepsOriginalURL() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://short.link/x?utm_source=feed")
        try store.save(document: document)
        // No recordPosition call: the open wrote no tick yet.
        let back = try #require(try store.document(id: document.id))
        #expect(back.originalURL?.absoluteString == "https://short.link/x?utm_source=feed")
        #expect(back.url?.absoluteString == "https://example.com/article")

        // A re-save without the link (canonical refetch path) keeps it.
        var reread = document
        reread.originalURL = nil
        try store.save(document: reread)
        #expect(try store.document(id: document.id)?.originalURL?.absoluteString == "https://short.link/x?utm_source=feed")

        // The rescue clear drops it from the document row too: a later
        // `document(id:)` read must not return the dead link.
        try store.clearDocumentOriginalURL(documentID: document.id)
        #expect(try store.document(id: document.id)?.originalURL == nil)
    }

    @Test("One rescue clear drops the link from both rows")
    func rescueClearDropsBothRows() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://short.link/x?utm_source=feed")
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)

        let recorder = PositionRecorder(store: store)
        recorder.clearRescuedLink(contentHash: key, documentID: document.id)
        recorder.wait()

        #expect(try store.position(contentHash: key)?.originalURL == nil)
        #expect(try store.document(id: document.id)?.originalURL == nil)
    }

    @Test("Changed-content refetch retires the old row and keeps one row")
    func supersedeOnRefetchKeepsOneRow() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://short.link/x")
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 3)
        let oldKey = Store.resumeKey(for: document)
        try store.setSaved(contentHash: oldKey, saved: true)
        let oldRow = try #require(try store.position(contentHash: oldKey))

        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "def"
        // Nil refetch (canonical retry): the old pasted link carries.
        let document2 = Document(url: document.url, title: "Sample v2", plan: plan2)
        try store.save(document: document2)
        try store.supersedeOnRefetch(oldRow: oldRow, newDocument: document2, startWord: 1)

        // Old row gone from both tables; new row seeded, saved and link carried.
        #expect(try store.position(contentHash: oldKey) == nil)
        #expect(try store.document(id: document.id) == nil)
        let newKey = Store.resumeKey(for: document2)
        let back = try #require(try store.position(contentHash: newKey))
        #expect(back.wordIndex == 1)
        #expect(back.saved == true)
        #expect(back.title == "Sample v2")
        #expect(back.originalURL?.absoluteString == "https://short.link/x")

        // The deleted document needs its oplog row or peers keep it forever.
        let deletes = try store.syncOplog.entries().filter { $0.op == "document.delete" }
        #expect(deletes.contains { $0.payload.contains(document.id.uuidString) })

        // Same hash is a no-op: the row survives.
        try store.recordPosition(of: document2, wordIndex: 2)
        let sameRow = try #require(try store.position(contentHash: newKey))
        try store.supersedeOnRefetch(oldRow: sameRow, newDocument: document2, startWord: 0)
        #expect(try store.position(contentHash: newKey)?.wordIndex == 2)

        // Production case: the document row is already gone (that is why the
        // row refetched) while the position row is present. A fresh article
        // is released — document gone, place kept — then refetched with
        // changed bytes. The retire seeds the new row carrying the live
        // flags and logs no delete for the already-missing document.
        var plan4 = makeSamplePlan()
        plan4.sourceSHA256 = "abc"
        let document4 = Document(url: document.url, title: "Sample v4", plan: plan4)
        try store.save(document: document4)
        try store.recordPosition(of: document4, wordIndex: 2)
        let key4 = Store.resumeKey(for: document4)
        try store.setSaved(contentHash: key4, saved: true)
        try store.releaseCopy(documentID: document4.id)
        #expect(try store.document(id: document4.id) == nil)
        let presentRow = try #require(try store.position(contentHash: key4))
        #expect(presentRow.saved == true)
        var plan5 = makeSamplePlan()
        plan5.sourceSHA256 = "456"
        let document5 = Document(url: document.url, title: "Sample v5", plan: plan5)
        try store.save(document: document5)
        // The release above logged for the row it removed (a gated log only
        // fires when a row actually goes); the retire below must not log,
        // because its document row is already gone.
        let deletesBeforeRetire = try store.syncOplog.entries().filter { $0.op == "document.delete" }.count
        try store.supersedeOnRefetch(oldRow: presentRow, newDocument: document5, startWord: 0)
        let key5 = Store.resumeKey(for: document5)
        let seeded = try #require(try store.position(contentHash: key5))
        #expect(try store.position(contentHash: key4) == nil)
        #expect(seeded.saved == true)
        #expect(seeded.wordIndex == 0)
        #expect(try store.syncOplog.entries().filter { $0.op == "document.delete" }.count == deletesBeforeRetire)
    }

    @Test("Negative totalWords heals to zero instead of rendering")
    func negativeTotalHeals() throws {
        let row = ReadingPosition(
            contentHash: "x", documentID: UUID(), title: "T", wordIndex: 0,
            totalWords: -1, updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        #expect(row.totalWords == 0)
        #expect(row.reachedEnd == false)
    }

    @Test("v14 creates the sibling-lookup index")
    func v14PositionURLIndexExists() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }
        let names: [String] = try store.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name = 'idx_reading_position_url'")
        }
        #expect(names == ["idx_reading_position_url"])
    }

    @Test("Sibling lookup finds same-URL rows with a different hash")
    func siblingRowsFindsSameURL() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)

        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "def"
        let document2 = Document(url: document.url, title: "Sample v2", plan: plan2)
        try store.save(document: document2)
        try store.recordPosition(of: document2, wordIndex: 0)
        let key2 = Store.resumeKey(for: document2)

        // Each row sees the other as a sibling, never itself.
        let siblings = try store.siblingRows(url: "https://example.com/article", excluding: key)
        #expect(siblings.map(\.contentHash) == [key2])
        #expect(try store.siblingRows(url: "https://example.com/article", excluding: key2).map(\.contentHash) == [key])
        // A different URL has no siblings.
        #expect(try store.siblingRows(url: "https://example.com/other", excluding: key).isEmpty)
        // Canonical drift still meets: tracking params and fragments are
        // the same resource.
        #expect(try store.siblingRows(url: "https://example.com/article?utm_source=x#s", excluding: key).map(\.contentHash) == [key2])
    }

    @Test("Sibling lookup never merges on the pasted link alone")
    func siblingIgnoresPastedLinkAlone() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Row A filed under its canonical URL with a pasted short link.
        var documentA = makeSampleDocument()
        documentA.originalURL = URL(string: "https://short.link/x")
        try store.save(document: documentA)
        try store.recordPosition(of: documentA, wordIndex: 1)

        // A different article whose canonical URL happens to equal A's
        // pasted link: SQL matches on original_url, but the canonical gate
        // drops it — same provenance, different entries.
        var planB = makeSamplePlan()
        planB.sourceSHA256 = "other-bytes"
        let documentB = Document(
            url: URL(string: "https://short.link/x"), title: "Other",
            plan: planB)
        try store.save(document: documentB)
        try store.recordPosition(of: documentB, wordIndex: 0)
        let keyB = Store.resumeKey(for: documentB)

        #expect(try store.siblingRows(url: "https://short.link/x", excluding: keyB).isEmpty)
    }

    @Test("Corrupt flag cannot hide an unreached row from the offer")
    func corruptFinishedHealsOnDecode() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // A corrupt row: mechanical flag says done, derived progress says
        // word 2 of 50. The launch offer derives from furthest alone, so the
        // flag cannot hide the row; decode agrees it is unreached.
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "corrupt", UUID().uuidString, "Corrupt", 2, 1, 0,
                    "https://example.com/article", nil, 50, 1, 2, 0, "", "",
                    1000.0,
                ])
        }
        let back = try #require(try store.position(contentHash: "corrupt"))
        #expect(back.wordIndex == 2)
        #expect(back.furthest == 2)
        #expect(back.finished == false)
        #expect(back.reachedEnd == false)
        #expect(try store.latestUnfinishedPosition()?.contentHash == "corrupt")
    }

    @Test("Explicit furthest cannot overshoot the length")
    func explicitFurthestClamps() {
        let row = ReadingPosition(
            contentHash: "x", documentID: UUID(), title: "T",
            wordIndex: 0, totalWords: 50, furthest: 999,
            updatedAt: .now)
        #expect(row.furthest == 49)
        #expect(row.reachedEnd == true)
        // Total zero: no length to reach, never reached.
        let empty = ReadingPosition(
            contentHash: "e", documentID: UUID(), title: "E",
            wordIndex: 5, totalWords: 0, furthest: 999,
            updatedAt: .now)
        #expect(empty.furthest == 0)
        #expect(empty.reachedEnd == false)
        // Negative furthest floors at zero.
        let negative = ReadingPosition(
            contentHash: "n", documentID: UUID(), title: "N",
            wordIndex: 3, totalWords: 50, furthest: -5,
            updatedAt: .now)
        #expect(negative.furthest == 0)
        // The word clamps too: decode heals the whole row.
        let wild = ReadingPosition(
            contentHash: "w", documentID: UUID(), title: "W",
            wordIndex: 999, totalWords: 50,
            updatedAt: .now)
        #expect(wild.wordIndex == 49)
        #expect(wild.furthest == 49)
        let before = ReadingPosition(
            contentHash: "b", documentID: UUID(), title: "B",
            wordIndex: -3, totalWords: 50,
            updatedAt: .now)
        #expect(before.wordIndex == 0)
        #expect(before.furthest == 0)
    }

    @Test("Same-hash shrink clamps furthest to the new length")
    func sameHashShrinkClampsFurthest() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Full-length plan first: furthest 8 on ~14 words.
        let document = makeSampleDocument()
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 8)
        let key = Store.resumeKey(for: document)
        #expect(try store.position(contentHash: key)?.furthest == 8)

        // Same bytes hash, shorter plan (parser rebuild, 3 words): the tick
        // clamps the word and must clamp furthest too, or `reachedEnd`
        // derives true from an overshoot and the article leaves the list.
        let shortText = "Hi there friend."
        let shortBlock = Block(
            id: 0, kind: .prose, confidence: 0.9, reason: "p", text: shortText,
            spoken: [Sentence(offset: 0, length: shortText.count, text: shortText)])
        var shortPlan = makeSamplePlan()
        shortPlan.blocks = [shortBlock]
        let shortDoc = Document(url: document.url, title: "Sample", plan: shortPlan)
        #expect(Store.resumeKey(for: shortDoc) == key)
        try store.save(document: shortDoc)
        try store.recordPosition(of: shortDoc, wordIndex: 10)

        let back = try #require(try store.position(contentHash: key))
        #expect(back.wordIndex == 2)
        #expect(back.furthest == 2)
        #expect(back.reachedEnd == true)
    }

    @Test("Supersede conflict clamps the kept word and bumps the timestamp")
    func supersedeConflictClampsWord() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Old row to retire.
        var oldPlan = makeSamplePlan()
        oldPlan.sourceSHA256 = "oldhash"
        let oldDoc = Document(url: URL(string: "https://example.com/article"), title: "Old", plan: oldPlan)
        try store.save(document: oldDoc)
        try store.recordPosition(of: oldDoc, wordIndex: 1)
        let oldRow = try #require(try store.position(contentHash: Store.resumeKey(for: oldDoc)))

        // Seed the new hash first (a tick that landed before the absorb):
        // same bytes hash, full-length plan, word 8.
        var planA = makeSamplePlan()
        planA.sourceSHA256 = "conflict"
        let docA = Document(url: URL(string: "https://example.com/article"), title: "New A", plan: planA)
        try store.save(document: docA)
        let early = Date(timeIntervalSinceReferenceDate: 1000)
        try store.recordPosition(of: docA, wordIndex: 8, at: early)
        let keyB = Store.resumeKey(for: docA)

        // A second seed for the same hash with a shorter plan (same SHA,
        // fewer blocks — artificial, but it drives the ON CONFLICT path
        // production races through) at a newer timestamp.
        let shortText = "Hi there friend."
        let shortBlock = Block(
            id: 0, kind: .prose, confidence: 0.9, reason: "p", text: shortText,
            spoken: [Sentence(offset: 0, length: shortText.count, text: shortText)])
        var planB = makeSamplePlan()
        planB.sourceSHA256 = "conflict"
        planB.blocks = [shortBlock]
        let docB = Document(url: URL(string: "https://example.com/article"), title: "New B", plan: planB)
        try store.save(document: docB)
        let late = Date(timeIntervalSinceReferenceDate: 2000)
        try store.supersedeOnRefetch(oldRow: oldRow, newDocument: docB, startWord: 10, at: late)

        // Kept the first seed's word, clamped to the shorter length (3
        // words → max index 2); finished recomputed; newest timestamp wins.
        // Furthest merges clamped too: an 8 on the 14-word plan must not
        // survive against a 3-word total.
        let back = try #require(try store.position(contentHash: keyB))
        #expect(back.wordIndex == 2)
        #expect(back.finished == true)
        #expect(back.furthest == 2)
        #expect(back.updatedAt == late)
        #expect(back.title == "New B")
    }

    @Test("Empty-hash identical plans keep the word without rewrite")
    func emptyHashIdenticalPlansKeepWord() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var plan = makeSamplePlan()
        plan.sourceSHA256 = ""
        let document = Document(url: URL(string: "https://example.com/article"), title: "Sample", plan: plan)
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)
        var row = try #require(try store.position(contentHash: key))
        row.wordIndex = 1
        // Anchors are sentence-grained: word 1 sits in the first sentence,
        // so the identical plan resolves to its first word with no rewrite.
        #expect(store.resolve(row: row, newPlan: plan) == (0, false))
    }

    @Test("v11 leaves existing documents readable with no pasted link")
    func v11MigrationLeavesOriginalURLEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let document = makeSampleDocument()
        let planData = try JSONEncoder().encode(document.plan)
        let planJSON = try #require(String(data: planData, encoding: .utf8))
        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v11_document_sha")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    document.id.uuidString, document.url?.absoluteString, document.title,
                    1000.0, planJSON, document.plan.sourceSHA256,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        #expect(try store.document(id: document.id)?.originalURL == nil)
        #expect(try store.document(id: document.id)?.url?.absoluteString == "https://example.com/article")
    }

    @Test("v12 canonicalizes stored URLs, keeps the pasted link")
    func v12MigrationCanonicalizesURLs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let document = makeSampleDocument()
        let planData = try JSONEncoder().encode(document.plan)
        let planJSON = try #require(String(data: planData, encoding: .utf8))
        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v12_document_original_url")
        let docID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, original_url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    docID, "https://Example.COM/article?utm_source=x#frag", "https://short.link/x",
                    "Pre-canonical", 1000.0, planJSON, document.plan.sourceSHA256,
                ])
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "precanonical", docID, "Pre-canonical", 1, 0, 0,
                    "https://Example.COM/article?utm_source=x#frag", "https://short.link/x",
                    50, 1, 1, 0, "", "", 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try #require(try store.position(contentHash: "precanonical"))
        #expect(back.url?.absoluteString == "https://example.com/article")
        #expect(back.originalURL?.absoluteString == "https://short.link/x")
        let docBack = try #require(try store.document(id: UUID(uuidString: docID)!))
        #expect(docBack.url?.absoluteString == "https://example.com/article")
        #expect(docBack.originalURL?.absoluteString == "https://short.link/x")
    }

    @Test("v13 backfills a pre-v5 NULL position URL from the document")
    func v13MigrationBackfillsNullPositionURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let document = makeSampleDocument()
        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v13_canonicalize_urls")
        // A pre-v5 row survived with NULL url and a zero total; its
        // document carries a plan whose stored `spoken_words` lies (999).
        // The heal computes the total from the blocks (14), never trusting
        // the stored field.
        var plan = document.plan
        plan.spokenWords = 999
        let healedData = try JSONEncoder().encode(plan)
        let healedJSON = try #require(String(data: healedData, encoding: .utf8))
        let docID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, original_url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    docID, "https://example.com/article", nil,
                    "Old row", 1000.0, healedJSON, document.plan.sourceSHA256,
                ])
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "oldnull", docID, "Old row", 3, 0, 1,
                    nil, nil,
                    0, 0, 0, 0, "", "", 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try #require(try store.position(contentHash: "oldnull"))
        #expect(back.url?.absoluteString == "https://example.com/article")
        #expect(back.totalWords == 14)
        // Furthest re-seeds from the word in the same pass (3 of 14):
        // the v6 backfill zeroed it positionally, so healing the total
        // alone would understate real progress until the next tick.
        #expect(back.furthest == 3)
        // The gate now sees it: same canonical URL, different hash.
        #expect(try store.siblingRows(url: "https://example.com/article", excluding: "other").map(\.contentHash).contains("oldnull"))
    }

    @Test("v13 keeps NULL url for a live nil-url document, heals the total")
    func v13MigrationLiveNilURLDocument() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        var plan = makeSamplePlan()
        plan.spokenWords = 999
        let healedJSON = try #require(String(data: try JSONEncoder().encode(plan), encoding: .utf8))
        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v13_canonicalize_urls")
        // Live document whose own URL is nil: nothing to backfill from,
        // so the row stays NULL — but the total still heals computed.
        let docID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, original_url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    docID, nil, "https://example.com/article",
                    "Nil URL", 1000.0, healedJSON, plan.sourceSHA256,
                ])
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "nilurllive", docID, "Nil URL", 3, 0, 0,
                    nil, "https://example.com/article",
                    0, 0, 0, 0, "", "", 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try #require(try store.position(contentHash: "nilurllive"))
        #expect(back.url == nil)
        #expect(back.totalWords == 14)
    }

    @Test("v13 keeps the stored total when the plan will not decode")
    func v13MigrationCorruptPlanKeepsTotal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v13_canonicalize_urls")
        // Corrupt plan_json: the URL still heals, the stored total stands
        // instead of zeroing — a wrong-but-present count beats a certain
        // "0 words" place line until the next tick recomputes it.
        let docID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, original_url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    docID, "https://example.com/article", nil,
                    "Corrupt", 1000.0, "not json", "zzz",
                ])
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "corruptplan", docID, "Corrupt", 3, 0, 0,
                    nil, nil,
                    9, 0, 0, 0, "", "", 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try #require(try store.position(contentHash: "corruptplan"))
        #expect(back.url?.absoluteString == "https://example.com/article")
        #expect(back.totalWords == 9)
    }

    @Test("v13 re-seeds furthest from the word it heals the total beside")
    func v13MigrationReseedsFurthest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let plan = makeSamplePlan()
        let healedJSON = try #require(String(data: try JSONEncoder().encode(plan), encoding: .utf8))
        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v13_canonicalize_urls")
        // Pre-v5 finished row: v5 left total 0, v6 then clamped furthest
        // to max(0 - 1, 0) = 0 positionally. Healing the total alone would
        // offer a finished article as resumable; the word re-seeds furthest
        // in the same pass (13 of 14 → reached, never offered).
        let docID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, original_url, title, added_at, plan_json, source_sha256)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    docID, "https://example.com/article", nil,
                    "Finished", 1000.0, healedJSON, plan.sourceSHA256,
                ])
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "oldfinish", docID, "Finished", 13, 1, 0,
                    nil, nil,
                    0, 0, 0, 0, "", "", 1000.0,
                ])
            // Hand-set overshoot beside it: furthest past the end ceilings
            // to the healed last word instead of persisting in SQL.
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "oldover", docID, "Overshoot", 5, 0, 0,
                    nil, nil,
                    0, 0, 100, 0, "", "", 500.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try #require(try store.position(contentHash: "oldfinish"))
        #expect(back.totalWords == 14)
        #expect(back.wordIndex == 13)
        #expect(back.furthest == 13)
        #expect(back.reachedEnd == true)
        #expect(try store.latestUnfinishedPosition() == nil)
        let over = try #require(try store.position(contentHash: "oldover"))
        #expect(over.totalWords == 14)
        #expect(over.wordIndex == 5)
        #expect(over.furthest == 13)
        #expect(over.reachedEnd == true)
        // Intentional §6 split: the mechanical flag derives from the word
        // (5 of 14, unfinished) while the offer derives from furthest —
        // pin both so a "fix the flag" edit cannot scrub back-from-end.
        #expect(over.finished == false)
    }

    @Test("Sibling lookup falls back to the pasted link for URL-less rows")
    func siblingFallsBackToPastedLink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v13_canonicalize_urls")
        // Released pre-v5 row: the document is gone, no URL was ever
        // backfilled, and the pasted link carries case/tracking/fragment
        // drift no exact SQL match can meet.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "released-old", UUID().uuidString, "Old row", 3, 0, 1,
                    nil, "HTTPS://EXAMPLE.COM/article?utm_source=x#frag",
                    14, 0, 3, 0, "", "", 1000.0,
                ])
        }

        // v13 keeps the NULL (no document to heal from); the re-added
        // fresh row still finds its released sibling by pasted link.
        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "new-bytes"
        let document2 = Document(
            url: URL(string: "https://example.com/article"), title: "Sample v2",
            plan: plan2)
        try store.save(document: document2)
        try store.recordPosition(of: document2, wordIndex: 0)
        let key2 = Store.resumeKey(for: document2)
        #expect(try store.siblingRows(url: "https://example.com/article", excluding: key2).map(\.contentHash) == ["released-old"])
    }

    @Test("Sibling fallback absorbs a released empty-string URL row")
    func siblingFallsBackForEmptyStringURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v13_canonicalize_urls")
        // Hand-edited `''` (not NULL) on a released row: decode normalizes
        // the empty string to nil, the widened gate fetches it, and the
        // pasted link absorbs it — no stranded duplicate.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, original_url, total_words,
                    extractor_version, furthest, marked_done, anchor_hash, anchor_head, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "released-empty", UUID().uuidString, "Old row", 3, 0, 1,
                    "", "HTTPS://EXAMPLE.COM/article?utm_source=x#frag",
                    14, 0, 3, 0, "", "", 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try #require(try store.position(contentHash: "released-empty"))
        #expect(back.url == nil)
        var plan2 = makeSamplePlan()
        plan2.sourceSHA256 = "new-bytes"
        let document2 = Document(
            url: URL(string: "https://example.com/article"), title: "Sample v2",
            plan: plan2)
        try store.save(document: document2)
        try store.recordPosition(of: document2, wordIndex: 0)
        let key2 = Store.resumeKey(for: document2)
        #expect(try store.siblingRows(url: "https://example.com/article", excluding: key2).map(\.contentHash) == ["released-empty"])
    }

    @Test("Sibling fallback never selects a live URL-less row")
    func siblingFallbackSkipsLiveNilURLRow() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Live document with no URL at all (nil straight to NULL), pasted
        // link exactly the lookup: provenance only, bytes present. The
        // fallback must not select it — only the release-only branch may.
        var liveDoc = makeSampleDocument()
        liveDoc.url = nil
        liveDoc.originalURL = URL(string: "https://example.com/article")
        try store.save(document: liveDoc)
        try store.recordPosition(of: liveDoc, wordIndex: 0)
        let liveRow = try #require(try store.position(contentHash: Store.resumeKey(for: liveDoc)))
        #expect(liveRow.url == nil)

        var other = makeSamplePlan()
        other.sourceSHA256 = "other-bytes"
        let otherDoc = Document(
            url: URL(string: "https://example.com/article"), title: "Other",
            plan: other)
        try store.save(document: otherDoc)
        try store.recordPosition(of: otherDoc, wordIndex: 0)
        let otherKey = Store.resumeKey(for: otherDoc)
        #expect(try store.siblingRows(url: "https://example.com/article", excluding: otherKey).isEmpty)
    }

    @Test("Clearing the original leaves the canonical URL for refetch")
    func clearOriginalURLKeepsCanonical() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var document = makeSampleDocument()
        document.originalURL = URL(string: "https://short.link/x")
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: 1)
        let key = Store.resumeKey(for: document)

        try store.clearOriginalURL(contentHash: key)
        let back = try #require(try store.position(contentHash: key))
        #expect(back.originalURL == nil)
        #expect(back.url != nil)
    }

    @Test("v9 leaves the original URL empty on an existing row")
    func v9MigrationLeavesOriginalURLEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v9_raw_page")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, total_words, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "v8hash", UUID().uuidString, "V8 article", 4, 0, 0,
                    "https://example.com/v8", 9, 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try store.position(contentHash: "v8hash")
        #expect(back?.wordIndex == 4)
        #expect(back?.originalURL == nil)
    }

    @Test("v10 backfills the source hash and keeps hash-scoped deletes")
    func v10MigrationBackfillsSourceSHA() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let first = makeSampleDocument()
        let planData = try JSONEncoder().encode(first.plan)
        let planJSON = try #require(String(data: planData, encoding: .utf8))
        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v10_original_url")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO document(id, url, title, added_at, plan_json)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    first.id.uuidString, first.url?.absoluteString, first.title,
                    1000.0, planJSON,
                ])
        }

        // Opening runs v9→v10: the old row gains its hash without re-planning.
        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let second = makeSampleDocument()
        try store.save(document: second)
        let page = RawPage(html: "<p>x</p>", status: 200, finalURL: URL(string: "https://example.com/a")!)
        try store.saveRawPage(page, for: first)
        let key = Store.resumeKey(for: first)

        try store.deleteDocument(id: first.id)
        #expect(try store.rawPage(contentHash: key) != nil)

        try store.deleteDocument(id: second.id)
        #expect(try store.rawPage(contentHash: key) == nil)
    }

    @Test("v6 migration backfills furthest on a v5 database")
    func v6MigrationBackfillsFurthest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let url = dir.appendingPathComponent("store.sqlite")

        // Build a v5-era database: run the migrator only up to v5, then write
        // a position row with the v5 columns.
        let queue = try DatabaseQueue(path: url.path)
        try makeMigrator().migrate(queue, upTo: "v5_position_origin")
        let docID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, total_words, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "v5hash", docID, "V5 article", 4, 0, 0,
                    "https://example.com/v5", 9, 1000.0,
                ])
        }

        // Opening through Store runs the v6 migration on the old file.
        let store = try Store(databaseURL: url, device: "test-device", telemetry: TelemetryHub())
        let back = try store.position(contentHash: "v5hash")
        #expect(back?.wordIndex == 4)
        #expect(back?.furthest == 4)
        #expect(back?.markedDone == false)
        #expect(back?.extractorVersion == 0)
        #expect(back?.reachedEnd == false)
    }
}
