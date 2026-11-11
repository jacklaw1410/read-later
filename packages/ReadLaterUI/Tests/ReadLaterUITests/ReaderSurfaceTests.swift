import ReadLaterCore
import ReadLaterUI
import XCTest

/// Pure logic for the reader surface. No view rendering assertions.
final class ReaderSurfaceTests: XCTestCase {
    // MARK: - Helpers

    private func proseBlock(id: Int, text: String) -> Block {
        let sentence = Sentence(offset: 0, length: (text as NSString).length, text: text)
        return Block(id: id, kind: .prose, confidence: 0.95, reason: "test", text: text, spoken: [sentence])
    }

    private func skippedBlock(id: Int, kind: BlockKind, text: String) -> Block {
        Block(id: id, kind: kind, confidence: 0.95, reason: "test", text: text, spoken: [])
    }

    private func document(blocks: [Block], url: String? = "https://example.com/article") -> Document {
        let plan = BlockPlan(source: url ?? "test", sourceSHA256: "00", blocks: blocks)
        return Document(url: url.flatMap(URL.init(string:)), title: "Test", plan: plan)
    }

    // MARK: - Wash emphasis

    func testEmphasisReturnsAllFiveStates() {
        XCTAssertEqual(WashState(wordIndex: 3, isPlaying: true).emphasis(for: 3), .current)
        XCTAssertEqual(WashState(wordIndex: 3, isPlaying: false).emphasis(for: 3), .paused)
        XCTAssertEqual(WashState(selectedWordIndex: 5).emphasis(for: 5), .selected)
        XCTAssertEqual(
            WashState(wordIndex: 5, isPlaying: true, selectedWordIndex: 5).emphasis(for: 5),
            .coincide
        )
        XCTAssertEqual(WashState(wordIndex: 3, isPlaying: true).emphasis(for: 4), .none)
    }

    // MARK: - Reading order

    func testBodyBlocksExcludeNotes() {
        let note = Block(id: 3, kind: .footnoteBody, confidence: 0.9, reason: "test", text: "A note.", spoken: [])
        let doc = document(blocks: [proseBlock(id: 1, text: "Hello world."), note])
        XCTAssertEqual(doc.bodyBlocks.map(\.id), [1])
        XCTAssertEqual(doc.noteBlocks.map(\.id), [3])
    }

    // MARK: - Counts

    func testSpokenWordCountMatchesSpokenIndex() {
        let doc = document(blocks: [
            proseBlock(id: 1, text: "Hello world."),
            skippedBlock(id: 2, kind: .code, text: "let x = 1"),
            proseBlock(id: 3, text: "One more sentence here."),
        ])
        XCTAssertEqual(doc.spokenWordCount, SpokenIndex(plan: doc.plan).totalWords)
    }

    func testSkippedRegionCountCountsBlocksNotNotes() {
        let note = Block(id: 9, kind: .footnoteBody, confidence: 0.9, reason: "test", text: "A note.", spoken: [])
        let doc = document(blocks: [
            proseBlock(id: 1, text: "Hello world."),
            skippedBlock(id: 2, kind: .code, text: "let x = 1"),
            skippedBlock(id: 3, kind: .table, text: "a\tb"),
            skippedBlock(id: 4, kind: .figure, text: "A caption."),
            note,
        ])
        XCTAssertEqual(doc.skippedRegionCount, 3)
    }

    // MARK: - Spoken index gaps

    func testCodeBlockHasNoSpokenEntryAndGapTapReturnsNil() {
        let doc = document(blocks: [
            proseBlock(id: 1, text: "hello world"),
            skippedBlock(id: 2, kind: .code, text: "let x = 1"),
            proseBlock(id: 3, text: "goodbye world"),
        ])
        let index = SpokenIndex(plan: doc.plan)
        XCTAssertNil(index.byBlock[2])
        XCTAssertNotNil(index.byBlock[1])
        XCTAssertNotNil(index.byBlock[3])
        // Index 5 is the space between "hello" and "world": inside no word range.
        XCTAssertNil(index.word(inBlock: 1, atUTF16Index: 5))
        XCTAssertEqual(index.word(inBlock: 1, atUTF16Index: 0)?.text, "hello")
    }
}
