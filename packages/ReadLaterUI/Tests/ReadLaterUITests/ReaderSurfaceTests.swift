import ReadLaterCore
import ReadLaterUI
import XCTest

/// Pure logic for the reader surface. No view rendering assertions.
@MainActor
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
        let playing = PlaybackState(status: .playing)
        let paused = PlaybackState()
        XCTAssertEqual(WashState(wordIndex: 3).emphasis(for: 3, isPlaying: playing.isPlaying), .current)
        XCTAssertEqual(WashState(wordIndex: 3).emphasis(for: 3, isPlaying: paused.isPlaying), .paused)
        XCTAssertEqual(WashState(selectedWordIndex: 5).emphasis(for: 5, isPlaying: playing.isPlaying), .selected)
        XCTAssertEqual(
            WashState(wordIndex: 5, selectedWordIndex: 5).emphasis(for: 5, isPlaying: playing.isPlaying),
            .coincide
        )
        XCTAssertEqual(WashState(wordIndex: 3).emphasis(for: 4, isPlaying: playing.isPlaying), .none)
    }

    // MARK: - Reading order

    func testBodyBlocksExcludeNotes() {
        let note = Block(id: 3, kind: .footnoteBody, confidence: 0.9, reason: "test", text: "A note.", spoken: [])
        let doc = document(blocks: [proseBlock(id: 1, text: "Hello world."), note])
        XCTAssertEqual(doc.bodyBlocks.map(\.id), [1])
        XCTAssertEqual(doc.noteBlocks.map(\.id), [3])
    }

    // MARK: - Counts

    func testSpokenWordCountMatchesSpokenWordNumbering() {
        let doc = document(blocks: [
            proseBlock(id: 1, text: "Hello world."),
            skippedBlock(id: 2, kind: .code, text: "let x = 1"),
            proseBlock(id: 3, text: "One more sentence here."),
        ])
        XCTAssertEqual(doc.spokenWordCount, SpokenWordNumbering(plan: doc.plan).totalWords)
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

    // MARK: - Spoken word numbering gaps

    func testCodeBlockHasNoSpokenEntryAndGapTapReturnsNil() {
        let doc = document(blocks: [
            proseBlock(id: 1, text: "hello world"),
            skippedBlock(id: 2, kind: .code, text: "let x = 1"),
            proseBlock(id: 3, text: "goodbye world"),
        ])
        let index = SpokenWordNumbering(plan: doc.plan)
        XCTAssertNil(index.byBlock[2])
        XCTAssertNotNil(index.byBlock[1])
        XCTAssertNotNil(index.byBlock[3])
        // Index 5 is the space between "hello" and "world": inside no word range.
        XCTAssertNil(index.word(inBlock: 1, atUTF16Index: 5))
        XCTAssertEqual(index.word(inBlock: 1, atUTF16Index: 0)?.text, "hello")
    }

    // MARK: - Wash scroll target

    func testWashScrollTargetStaysInsideDeadBand() {
        XCTAssertNil(washScrollTarget(washMidY: 510, viewportOriginY: 400, viewportHeight: 200, maxOffset: 2000))
    }

    func testWashScrollTargetMovesWhenFar() {
        XCTAssertEqual(washScrollTarget(washMidY: 900, viewportOriginY: 400, viewportHeight: 200, maxOffset: 2000), 800)
    }

    func testWashScrollTargetClampsToBounds() {
        XCTAssertEqual(washScrollTarget(washMidY: 100, viewportOriginY: 400, viewportHeight: 200, maxOffset: 2000), 0)
        XCTAssertEqual(washScrollTarget(washMidY: 5000, viewportOriginY: 0, viewportHeight: 200, maxOffset: 1200), 1200)
    }

    // MARK: - Wash chip box

    func testWashChipBoxCoversTypeNotLineBox() {
        // A 19 pt word on a 31 pt line: the chip is the 23 pt type box, with
        // 2 pt of side air. TextKit puts the extra leading above the glyphs,
        // so the chip carries a 4 pt downward nudge to sit on the type box.
        let box = washChipBox(
            glyphBox: CGRect(x: 10, y: 100, width: 60, height: 31),
            origin: .zero,
            ascender: 18,
            descender: -5
        )
        XCTAssertEqual(box.height, 23)
        XCTAssertEqual(box.minY, 108)
        XCTAssertEqual(box.minX, 8)
        XCTAssertEqual(box.width, 64)
    }

    func testWashChipBoxNudgeMovesChipDown() {
        // The nudge is the whole fix for a chip that sits high. Pin it: the
        // default is 4 pt, and a 0 pt nudge is the old centred box.
        let glyphBox = CGRect(x: 10, y: 100, width: 60, height: 31)
        let centred = washChipBox(
            glyphBox: glyphBox,
            origin: .zero,
            ascender: 18,
            descender: -5,
            verticalNudge: 0
        )
        let nudged = washChipBox(
            glyphBox: glyphBox,
            origin: .zero,
            ascender: 18,
            descender: -5
        )
        XCTAssertEqual(centred.minY, 104)
        XCTAssertEqual(nudged.minY - centred.minY, 4)
        XCTAssertEqual(nudged.height, centred.height)
    }
}
