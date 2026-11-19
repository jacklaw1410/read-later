import Foundation
import Testing

@testable import ReadLaterCore

/// Builds a document from block texts, filling `spoken` with the real splitter
/// so the fixture cannot disagree with the engine.
private func makeDocument(_ texts: [(BlockKind, String)]) -> Document {
    var blocks: [Block] = []
    for (id, entry) in texts.enumerated() {
        blocks.append(
            Block(
                id: id,
                kind: entry.0,
                confidence: 0.95,
                reason: "fixture",
                text: entry.1
            )
        )
    }
    let plan = SpokenPlanBuilder.build(blocks: blocks, source: "fixture", sourceSHA256: "0")
    return Document(url: nil, title: "Fixture", plan: plan)
}

private let twoParagraphs: [(BlockKind, String)] = [
    (.prose, "Slow reading asks for patience. It gives back attention."),
    (.code, "const pace = 140;"),
    (.prose, "The second paragraph has three words."),
]

@Test func wordOrderSkipsBlocksWithoutSpokenSentences() {
    let document = makeDocument(twoParagraphs)
    let index = SpokenWordNumbering(plan: document.plan)

    #expect(index.totalWords == 15)
    #expect(index.byBlock[1] == nil)
    #expect(index.byBlock[0]?.isEmpty == false)
    #expect(index.byBlock[2]?.isEmpty == false)
}

@Test func everySlotRangeIsTheWordItself() {
    let document = makeDocument(twoParagraphs)
    let index = SpokenWordNumbering(plan: document.plan)
    let textByBlock = Dictionary(uniqueKeysWithValues: document.readingOrder.map { ($0.id, $0.text) })

    for slot in index.words {
        let blockText = textByBlock[slot.blockID] ?? ""
        #expect(NSMaxRange(slot.range) <= (blockText as NSString).length)
        #expect((blockText as NSString).substring(with: slot.range) == slot.text)
    }
}

@Test func indicesAreDenseAndAscending() {
    let document = makeDocument(twoParagraphs)
    let index = SpokenWordNumbering(plan: document.plan)

    #expect(index.words.map(\.index) == Array(0 ..< index.words.count))
}

@Test func sentenceLookupFindsTheContainingSentence() {
    let document = makeDocument([(.prose, "One. Two two. Three three three.")])
    let index = SpokenWordNumbering(plan: document.plan)

    #expect(index.utteranceCount == 3)
    #expect(index.utteranceIndex(forWord: 0) == 0)
    #expect(index.utteranceIndex(forWord: 1) == 1)
    #expect(index.utteranceIndex(forWord: 3) == 2)
    #expect(index.utteranceIndex(forWord: 5) == 2)
    // Past the end clamps to the last sentence rather than trapping.
    #expect(index.utteranceIndex(forWord: 99) == 2)
    #expect(index.utteranceIndex(forWord: -4) == 0)
}

@Test func tapInsideAWordFindsItAndTapOnSpaceDoesNot() {
    let document = makeDocument([(.prose, "Attention is a practice.")])
    let index = SpokenWordNumbering(plan: document.plan)
    let blockID = 0

    let first = index.words[0]
    #expect(first.text == "Attention")
    #expect(index.word(inBlock: blockID, atUTF16Index: 3) == first)

    // Index 9 is the character just past "Attention", which is the space.
    #expect(index.word(inBlock: blockID, atUTF16Index: 9) == nil)
    #expect(index.word(inBlock: 42, atUTF16Index: 0) == nil)
}

@Test func tapOnTheLastCharacterOfAWordStillFindsIt() {
    let document = makeDocument([(.prose, "Attention.")])
    let index = SpokenWordNumbering(plan: document.plan)

    // The token runs to the end of the whitespace-delimited token, so the
    // full stop belongs to it. The lookup layer trims punctuation later.
    #expect(index.word(inBlock: 0, atUTF16Index: 8)?.text == "Attention.")
}

@Test func graphemeOffsetsConvertToUTF16() {
    // An emoji before the sentence pushes the Character count and the UTF-16
    // count apart, which is the case the conversion exists for.
    let text = "🎧 Attention is a practice."
    let characterOffset = text.distance(from: text.startIndex, to: text.firstIndex(of: "A")!)
    #expect(characterOffset == 2)
    #expect(SpokenWordNumbering.utf16Offset(ofCharacterOffset: characterOffset, in: text) == 3)
}

@Test func wordRangesTileTheSentenceWithoutGaps() {
    let ranges = SpokenWordNumbering.wordRanges(in: "One  two\tthree", base: 100)

    #expect(ranges.count == 3)
    #expect(ranges[0] == NSRange(location: 100, length: 3))
    #expect(ranges[1] == NSRange(location: 105, length: 3))
    #expect(ranges[2] == NSRange(location: 109, length: 5))
}

@Test func skipCrossingDetectsAReducedInkBlockBetweenTwoWords() {
    let document = makeDocument(twoParagraphs)
    let index = SpokenWordNumbering(plan: document.plan)
    guard let lastOfFirst = index.byBlock[0]?.last,
          let firstOfSecond = index.byBlock[2]?.first
    else {
        Issue.record("fixture blocks are missing")
        return
    }
    #expect(index.crossesSkippedBlock(from: lastOfFirst.index, to: firstOfSecond.index, blocks: document.readingOrder))
    #expect(!index.crossesSkippedBlock(from: firstOfSecond.index, to: firstOfSecond.index, blocks: document.readingOrder))
}

@Test func emptyPlanGivesAnEmptyIndex() {
    let index = SpokenWordNumbering(blocks: [])
    #expect(index.totalWords == 0)
    #expect(index.utteranceCount == 0)
    #expect(index.word(at: 0) == nil)
    #expect(index.utteranceIndex(forWord: 0) == 0)
}

// MARK: - Pace

@Test func secondsRemainingScalesWithSpeed() {
    #expect(Pace.secondsRemaining(wordsLeft: 0, speed: 1) == 0)
    #expect(Pace.secondsRemaining(wordsLeft: 140, speed: 1) == 61)
    #expect(Pace.secondsRemaining(wordsLeft: 140, speed: 2) == 31)
    #expect(Pace.secondsRemaining(wordsLeft: 140, speed: 0.5) == 121)
    #expect(Pace.secondsRemaining(wordsLeft: 140, speed: 0) == 0)
}

@Test func clockLabelPadsAndClamps() {
    #expect(clockLabel(seconds: 0) == "00:00")
    #expect(clockLabel(seconds: 9) == "00:09")
    #expect(clockLabel(seconds: 75) == "01:15")
    #expect(clockLabel(seconds: 3600) == "60:00")
    #expect(clockLabel(seconds: -5) == "00:00")
}

@Test func speedLadderWalksInTenthStepsAndCapsAtOneAndAHalf() {
    #expect(Pace.steps == [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5])
    #expect(Pace.steps.contains(Pace.reference))
    #expect(Pace.steps.max() == 1.5)
    #expect(Pace.next(after: 1) == 1.1)
    #expect(Pace.next(after: 1.5) == 0.5)
    #expect(Pace.next(after: 3) == Pace.reference)
    #expect(Pace.speedLabel(1) == "1×")
    #expect(Pace.speedLabel(1.1) == "1.1×")
    #expect(Pace.speedLabel(1.5) == "1.5×")
}
