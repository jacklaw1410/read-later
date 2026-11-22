import CryptoKit
import Foundation
import GRDB
import Testing
import ReadLaterCore
@testable import ReadLaterStore

/// Sentence anchor and position migration (research `spec/library-identity.md`
/// §4, F38). Five sentences of ten words each: 50 spoken words, sentence
/// starts at 0, 10, 20, 30, 40. Every head is distinct.
@Suite("Anchor resolver")
struct AnchorResolverTests {
    let url = URL(string: "https://example.com/anchor")!

    let articleSentences = [
        "Alpha one two three four five six seven eight nine.",
        "Bravo one two three four five six seven eight nine.",
        "Charlie one two three four five six seven eight nine.",
        "Delta one two three four five six seven eight nine.",
        "Echo one two three four five six seven eight nine.",
    ]

    func makePlan(_ sentences: [String], sourceSHA256: String = "plan") -> BlockPlan {
        var offset = 0
        var spoken: [Sentence] = []
        for sentence in sentences {
            spoken.append(Sentence(offset: offset, length: sentence.count, text: sentence))
            offset += sentence.count + 1
        }
        let block = Block(
            id: 0, kind: .prose, confidence: 0.98, reason: "p",
            text: sentences.joined(separator: " "), spoken: spoken)
        return BlockPlan(source: "test", sourceSHA256: sourceSHA256, blocks: [block])
    }

    /// Records a position on `plan` and reads back the stored row, anchor included.
    func storedPosition(_ plan: BlockPlan, at wordIndex: Int, in store: Store) throws -> ReadingPosition {
        let document = Document(url: url, title: "Anchor fixture", plan: plan)
        try store.save(document: document)
        try store.recordPosition(of: document, wordIndex: wordIndex)
        return try #require(try store.position(contentHash: Store.resumeKey(for: document)))
    }

    /// Changes the seventh word ("seven" becomes "sevn"). Word count is unchanged.
    func typo(_ sentence: String) -> String {
        sentence.replacingOccurrences(of: "seven", with: "sevn")
    }

    @Test("Exact anchor hit survives a typo elsewhere in the article")
    func exactAnchorAfterTypoElsewhere() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)

        var edited = articleSentences
        edited[0] = typo(edited[0])
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(edited))
        #expect(resumed == 20)
    }

    @Test("Typo inside the anchor sentence falls to the unique head match")
    func uniqueHeadAfterTypoInsideAnchor() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)
        let expectedHash = SHA256.hash(data: Data("charlie one two three four five six seven eight nine".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        #expect(stored.anchorHash == expectedHash)
        #expect(stored.anchorHead == "charlie one two three four")

        var edited = articleSentences
        edited[2] = typo(edited[2])
        // Proportion would give 22. The head match gives the sentence start, 20.
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(edited))
        #expect(resumed == 20)
    }

    @Test("Ambiguous head match falls to proportion")
    func ambiguousHeadFallsToProportion() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)

        var edited = articleSentences
        edited[2] = typo(edited[2])
        // Second sentence with the same five-word head: two candidates, no unique match.
        edited.append("Charlie one two three four five six eight nine ten eleven twelve.")
        // 62 of 50 words: delta 0.24, under the gate.
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(edited))
        #expect(resumed == Int(Double(22) / Double(50) * Double(62)))
        #expect(resumed == 27)
    }

    @Test("Exact anchor wins before the gate; the gate fires only on anchor miss")
    func exactBeforeGate() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)

        // Growth: 65 of 50 words, delta 0.30. The anchored sentence is
        // verbatim, so resume stays at its start (20), not the top.
        var grown = articleSentences
        grown.append("Extra words here one two three four five six seven eight nine ten eleven twelve.")
        #expect(AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(grown)) == 20)

        // The anchored sentence is gone and 20 of 50 words remain, delta
        // 0.60: the gate fires and resume starts at the top.
        let truncated = Array(articleSentences.suffix(2))
        #expect(AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(truncated)) == 0)
    }

    @Test("Repeated anchor sentence resumes at the nearest copy")
    func repeatedAnchorPicksNearestCopy() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Sentence 4 repeats sentence 0. The reader stopped at word 43,
        // inside the second copy (starts at 40).
        var sentences = articleSentences
        sentences[4] = "Alpha one two three four five six seven eight nine."
        let stored = try storedPosition(makePlan(sentences), at: 43, in: store)

        // Sentence 1 grows by one word: 51 of 50 words, delta 0.02.
        // Copies now start at 0 and 41; proportion points at 43.
        var edited = sentences
        edited[1] += " extra."
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(edited))
        #expect(resumed == 41)
    }

    @Test("Repeated anchor plus heavy growth resumes at the nearest copy")
    func repeatedAnchorBeatsGate() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Sentence 4 repeats sentence 0. The reader stopped at word 43,
        // inside the second copy (starts at 40).
        var sentences = articleSentences
        sentences[4] = "Alpha one two three four five six seven eight nine."
        let stored = try storedPosition(makePlan(sentences), at: 43, in: store)

        // Growth: 65 of 50 words, delta 0.30 — past the gate. The anchored
        // sentence is verbatim twice, so resume lands at the nearer copy.
        // Copies stay at 0 and 40; proportion points at 55.
        var grown = sentences
        grown.append("Extra words here one two three four five six seven eight nine ten eleven twelve.")
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(grown))
        #expect(resumed == 40)
    }

    @Test("Gate fires before the fuzzy head when the anchor is gone")
    func gateBeatsFuzzyHead() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)

        // The anchored sentence is gone but its head survives verbatim at
        // the start of a rewritten second sentence; 20 of 50 words remain,
        // delta 0.60. The head would resume at 10; the gate fires first and
        // returns the top, so this pins gate-before-head.
        let rewritten = [
            "Delta one two three four five six seven eight nine.",
            "Charlie one two three four totally different words here now.",
        ]
        #expect(AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(rewritten)) == 0)
    }

    @Test("CJK sentences get a usable anchor")
    func cjkAnchorResumesByHash() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let sentences = [
            "春眠不觉晓处处闻啼鸟。",
            "夜来风雨声花落知多少。",
            "白日依山尽黄河入海流。",
            "欲穷千里目更上一层楼。",
            "床前明月光疑是地上霜。",
        ]
        let stored = try storedPosition(makePlan(sentences), at: 2, in: store)
        #expect(!stored.anchorHash.isEmpty)
        #expect(!stored.anchorHead.isEmpty)

        // Sentence 0 grows by one whitespace-separated word: 6 of 5 words,
        // delta 0.2. The stored sentence still matches exactly at its new
        // start, 3; proportion would give 2.
        var edited = sentences
        edited[0] += " 多"
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(edited))
        #expect(resumed == 3)
    }

    @Test("Three copies resolve to the nearest, not the first")
    func threeCopiesPickNearest() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Copies of one sentence at 10, 20 and 30. The reader stopped at 22,
        // inside the middle copy. Proportion points at 22, so nearest (20)
        // and last (30) disagree: a last-hit implementation fails here.
        var sentences = articleSentences
        sentences[1] = "Zulu one two three four five six seven eight nine."
        sentences[2] = "Zulu one two three four five six seven eight nine."
        sentences[3] = "Zulu one two three four five six seven eight nine."
        let stored = try storedPosition(makePlan(sentences), at: 22, in: store)

        // Sentence 4 grows by one word: 51 of 50 words, delta 0.02.
        // Copies stay at 10, 20, 30; proportion points at 22.
        var edited = sentences
        edited[4] += " extra."
        let resumed = AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(edited))
        #expect(resumed == 20)
    }

    @Test("NFC and NFD copies of one sentence share the anchor")
    func normalFormsShareAnchor() {
        // String == is already canonical; the anchor must be too: NFD input
        // normalizes to one token per word, identical to the NFC reading.
        let nfc = "caf\u{E9} au lait"
        let nfd = "cafe\u{301} au lait"
        #expect(AnchorResolver.normalizedWords(nfd) == ["caf\u{E9}", "au", "lait"])
        #expect(AnchorResolver.anchor(words: AnchorResolver.normalizedWords(nfc))
            == AnchorResolver.anchor(words: AnchorResolver.normalizedWords(nfd)))
    }

    @Test("Quote style alone does not move the anchor")
    func quoteStyleSharesAnchor() {
        #expect(AnchorResolver.normalizedWords("don\u{2019}t stop") == AnchorResolver.normalizedWords("don't stop"))
        #expect(AnchorResolver.normalizedWords("\u{2018}quoted\u{2019}") == ["'quoted'"])
    }

    @Test("Short heads fall through to proportion")
    func shortHeadSkipped() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        // Stored sentence (12 words, total 52): "Yes indeed and many words
        // to fill the sentence out now here." Edited keeps the head but
        // rewrites the tail, so the hash misses and the head is a unique
        // match at word 20. A 2-word head is below minHeadWords: skipped,
        // proportion wins (22/52*50 = 21). A 3-word head runs: 20.
        var sentences = articleSentences
        sentences[2] = "Yes indeed and many words to fill the sentence out now here."
        let stored = try storedPosition(makePlan(sentences), at: 22, in: store)

        var edited = sentences
        edited[2] = "Yes indeed and totally different ending words here now today."
        let newPlan = makePlan(edited)

        var twoWord = stored
        twoWord.anchorHead = "yes indeed"
        #expect(AnchorResolver.resolveWordIndex(old: twoWord, newPlan: newPlan) == 21)

        var threeWord = stored
        threeWord.anchorHead = "yes indeed and"
        #expect(AnchorResolver.resolveWordIndex(old: threeWord, newPlan: newPlan) == 20)
    }

    @Test("Legacy rows with no anchor fall to proportion, never the gate")
    func emptyAnchorSkipsGate() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)
        var legacy = stored
        legacy.anchorHash = ""
        legacy.anchorHead = ""
        // 100 words, delta 1.0: a gated row would return 0. Legacy rows
        // predate anchors, so they take proportion (22/50*100 = 44).
        let doubled = articleSentences + articleSentences
        #expect(AnchorResolver.resolveWordIndex(old: legacy, newPlan: makePlan(doubled)) == 44)
        #expect(AnchorResolver.isRewrite(old: legacy, newPlan: makePlan(doubled)) == false)
    }

    @Test("Rewrite flag fires only on anchor miss past the gate")
    func isRewriteFlagsGate() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        let stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)
        let rewritten = [
            "Delta one two three four five six seven eight nine.",
            "Charlie one two three four totally different words here now.",
        ]
        let newPlan = makePlan(rewritten)
        #expect(AnchorResolver.isRewrite(old: stored, newPlan: newPlan) == true)
        #expect(AnchorResolver.resolveWordIndex(old: stored, newPlan: newPlan) == 0)

        // Same plan, anchor present: no rewrite.
        #expect(AnchorResolver.isRewrite(old: stored, newPlan: makePlan(articleSentences)) == false)

        // Empty new plan: not a rewrite, just the top.
        #expect(AnchorResolver.isRewrite(old: stored, newPlan: makePlan([])) == false)
    }

    @Test("Huge stored index clamps instead of trapping")
    func hugeIndexClamps() throws {
        let (store, dir) = try makeTemporaryStore()
        defer { removeTemporaryStore(at: dir) }

        var stored = try storedPosition(makePlan(articleSentences), at: 22, in: store)
        stored.wordIndex = Int.max
        stored.anchorHash = ""
        stored.anchorHead = ""
        // Ratio clamps to 1 in Double: lands on the last word, no trap.
        #expect(AnchorResolver.resolveWordIndex(old: stored, newPlan: makePlan(articleSentences)) == 49)
    }

    @Test("Row without an anchor resumes by proportion, skipping the anchor steps")
    func noAnchorUsesProportion() {
        let legacy = ReadingPosition(
            contentHash: "legacy", documentID: UUID(), title: "Legacy",
            wordIndex: 22, totalWords: 50, updatedAt: .now)
        #expect(AnchorResolver.resolveWordIndex(old: legacy, newPlan: makePlan(articleSentences)) == 22)
    }

    @Test("v7 adds empty anchor columns to an existing row")
    func v7MigrationLeavesAnchorEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: dir) }
        let databaseURL = dir.appendingPathComponent("store.sqlite")

        let queue = try DatabaseQueue(path: databaseURL.path)
        try makeMigrator().migrate(queue, upTo: "v7_library_identity")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO reading_position(
                    content_hash, document_id, title, word_index, finished, saved, url, total_words, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "v6hash", UUID().uuidString, "V6 article", 4, 0, 0,
                    "https://example.com/v6", 9, 1000.0,
                ])
        }

        let store = try Store(databaseURL: databaseURL, device: "test-device", telemetry: TelemetryHub())
        let back = try store.position(contentHash: "v6hash")
        #expect(back?.wordIndex == 4)
        #expect(back?.anchorHash == "")
        #expect(back?.anchorHead == "")
    }
}
