import Foundation
import Testing
import ReadLaterCore

private func makeBlocks() -> [Block] {
    [
        Block(
            id: 0, kind: .prose, confidence: 0.99, reason: "p",
            text: "Slow reading calms the mind. It keeps one idea in view."
        ),
        Block(
            id: 1, kind: .code, confidence: 0.99, reason: "pre",
            text: "let pace = 140 // words per minute"
        ),
        Block(
            id: 2, kind: .prose, confidence: 0.99, reason: "p",
            text: "The wash follows the voice. Scrub to any word and listen."
        ),
    ]
}

private func makeQueue() -> (blocks: [Block], index: SpokenIndex, queue: SpeechQueue) {
    let plan = SpokenPlanBuilder.build(blocks: makeBlocks(), source: "test", sourceSHA256: "test")
    let index = SpokenIndex(plan: plan)
    let queue = SpeechQueue(index: index, blocks: plan.blocks)
    return (plan.blocks, index, queue)
}

@Test func utterancesSkipTheCodeBlock() {
    let (_, index, queue) = makeQueue()
    #expect(queue.utterances.count == 4)
    #expect(queue.utterances.map(\.sentenceIndex) == [0, 1, 2, 3])
    #expect(queue.utterances.map(\.blockID) == [0, 0, 2, 2])
    #expect(queue.utterances.allSatisfy { $0.blockID != 1 })
    #expect(queue.totalWords == index.totalWords)
}

@Test func utteranceForWordAtBounds() {
    let (_, index, queue) = makeQueue()
    #expect(queue.utterance(forWord: 0) == queue.utterances.first)
    #expect(queue.utterance(forWord: index.totalWords - 1) == queue.utterances.last)
    #expect(queue.utterance(forWord: index.totalWords) == nil)
    #expect(queue.utterance(forWord: -1) == nil)
}

@Test func startPositionAtSentenceStartIsZero() {
    let (_, index, queue) = makeQueue()
    let secondSentenceStart = index.firstWordOfSentence[1]
    let start = queue.startPosition(forWord: secondSentenceStart)
    #expect(start?.utterance == queue.utterances[1])
    #expect(start?.characterOffset == 0)
}

@Test func startPositionMidSentenceSlicesTheRemainder() {
    let (_, _, queue) = makeQueue()
    let utterance = queue.utterances[0]
    let expected = (utterance.text as NSString).range(of: "calms").location
    #expect(expected != NSNotFound)
    let start = queue.startPosition(forWord: 2)
    #expect(start?.utterance == utterance)
    #expect(start?.characterOffset == expected)
    #expect((utterance.text as NSString).substring(from: expected) == "calms the mind.")
}

@Test func wordIndexMapsMidSentenceRange() {
    let (_, _, queue) = makeQueue()
    let utterance = queue.utterances[0]
    let ns = utterance.text as NSString
    let wordRange = ns.range(of: "reading")
    #expect(wordRange.location != NSNotFound)
    #expect(queue.wordIndex(reportedRange: wordRange, in: utterance) == 1)
}

@Test func wordIndexOnFollowingSpaceStaysOnTheWord() {
    let (_, _, queue) = makeQueue()
    let utterance = queue.utterances[0]
    let ns = utterance.text as NSString
    let wordRange = ns.range(of: "reading")
    let spaceRange = NSRange(location: wordRange.location + wordRange.length, length: 1)
    #expect((ns.substring(with: spaceRange)) == " ")
    #expect(queue.wordIndex(reportedRange: spaceRange, in: utterance) == 1)
}

@Test func wordIndexOutsideTheUtteranceIsNil() {
    let (_, _, queue) = makeQueue()
    let utterance = queue.utterances[0]
    let length = (utterance.text as NSString).length
    #expect(queue.wordIndex(reportedRange: NSRange(location: length, length: 1), in: utterance) == nil)
    #expect(queue.wordIndex(reportedRange: NSRange(location: -1, length: 1), in: utterance) == nil)
}

@Test func shouldEnqueueNextHoldsTwoAhead() {
    let (_, _, queue) = makeQueue()
    #expect(queue.shouldEnqueueNext(afterFinished: 0, enqueuedAhead: 0))
    #expect(queue.shouldEnqueueNext(afterFinished: 3, enqueuedAhead: 1))
    #expect(!queue.shouldEnqueueNext(afterFinished: 0, enqueuedAhead: 2))
    #expect(!queue.shouldEnqueueNext(afterFinished: 3, enqueuedAhead: 5))
}

@Test func everyWordRoundTripsThroughStartPosition() {
    let (_, index, queue) = makeQueue()
    for global in 0 ..< index.totalWords {
        let slot = try! #require(index.word(at: global))
        let start = try! #require(queue.startPosition(forWord: global))
        let wordLength = (slot.text as NSString).length
        let ownRange = NSRange(location: start.characterOffset, length: wordLength)
        #expect(queue.wordIndex(reportedRange: ownRange, in: start.utterance) == global)
        let wash = try! #require(queue.spokenWordRange(reportedRange: ownRange, in: start.utterance))
        #expect(wash.range == slot.range)
        #expect(wash.sentenceIndex == start.utterance.sentenceIndex)
        #expect(wash.sentenceIndex == slot.sentenceIndex)
        #expect(wash.sentenceOffset == slot.range.location - start.characterOffset)
        #expect(queue.utterance(forWord: global)?.sentenceIndex == slot.sentenceIndex)
    }
}

@Test func sentencesInitMatchesBlocksInit() {
    let (blocks, index, queue) = makeQueue()
    let pairs = blocks.flatMap { block in block.spoken.map { (blockID: block.id, sentence: $0) } }
    #expect(pairs.count == queue.utterances.count)
    let regrouped = SpeechQueue(sentences: pairs)
    #expect(regrouped.utterances == queue.utterances)
    #expect(regrouped.totalWords == index.totalWords)
    for global in 0 ..< index.totalWords {
        let start = try! #require(queue.startPosition(forWord: global))
        let wordLength = ((index.word(at: global)?.text ?? "") as NSString).length
        let ownRange = NSRange(location: start.characterOffset, length: wordLength)
        let a = try! #require(queue.spokenWordRange(reportedRange: ownRange, in: start.utterance))
        let b = try! #require(regrouped.spokenWordRange(reportedRange: ownRange, in: start.utterance))
        #expect(a == b)
    }
}
