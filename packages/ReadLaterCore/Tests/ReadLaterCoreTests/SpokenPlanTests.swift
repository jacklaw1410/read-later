import Testing
import ReadLaterCore

private func slicesAreExact(_ text: String, _ sentences: [Sentence]) -> Bool {
    sentences.allSatisfy { sentence in
        guard sentence.offset >= 0, sentence.length > 0,
            sentence.offset + sentence.length <= text.count
        else { return false }
        let a = text.index(text.startIndex, offsetBy: sentence.offset)
        let b = text.index(a, offsetBy: sentence.length)
        return String(text[a..<b]) == sentence.text
    }
}

@Test func threeSentencesGiveExactSlices() {
    let text = "First sentence here. Second sentence here! Third sentence here?"
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 3)
    #expect(sentences[0].text == "First sentence here.")
    #expect(sentences[1].text == "Second sentence here!")
    #expect(sentences[2].text == "Third sentence here?")
    #expect(slicesAreExact(text, sentences))
}

@Test func abbreviationDoesNotSplit() {
    let text = "Mr. Smith went home. He slept well."
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 2)
    #expect(sentences[0].text == "Mr. Smith went home.")
    #expect(slicesAreExact(text, sentences))
}

@Test func egAndIeDoNotSplit() {
    let text = "Add fruit, e.g. apples, to the list. Then serve."
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 2)
    #expect(sentences[0].text == "Add fruit, e.g. apples, to the list.")
    #expect(slicesAreExact(text, sentences))
}

@Test func decimalNumberDoesNotSplit() {
    let text = "The value is 3.14. That is all."
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 2)
    #expect(sentences[0].text == "The value is 3.14.")
    #expect(slicesAreExact(text, sentences))
}

@Test func leadingWhitespaceIsTrimmedButSliceStaysExact() {
    let text = "   Hello world. Bye now.  "
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 2)
    #expect(sentences[0].offset == 3)
    #expect(sentences[0].text == "Hello world.")
    #expect(slicesAreExact(text, sentences))
}

@Test func paragraphBreakSplits() {
    let text = "First line\nSecond line"
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 2)
    #expect(sentences[0].text == "First line")
    #expect(sentences[1].text == "Second line")
    #expect(slicesAreExact(text, sentences))
}

@Test func doubledPunctuationSplits() {
    let text = "Wait... what happened? Nothing."
    let sentences = SpokenPlanBuilder.sentences(in: text)
    #expect(sentences.count == 3)
    #expect(slicesAreExact(text, sentences))
}

@Test func headingSpeaksAndLeavesSkipped() {
    let blocks = [
        Block(id: 0, kind: .heading, confidence: 0.95, reason: "h2",
              text: "Why calm software wins."),
        Block(id: 1, kind: .code, confidence: 0.99, reason: "pre",
              text: ">>> import json\n>>> print(x)"),
    ]
    let plan = SpokenPlanBuilder.build(blocks: blocks, source: "test", sourceSHA256: "abc")
    #expect(plan.blocks[0].spoken.count == 1)
    #expect(plan.blocks[0].spoken[0].text == "Why calm software wins.")
    #expect(plan.blocks[1].spoken.isEmpty)
    #expect(plan.sentenceCount == 1)
    #expect(plan.spokenWords == 4)
    #expect(plan.skipped.count == 1)
    #expect(plan.skipped[0].blockID == 1)
    #expect(!plan.skipped.contains { $0.kind == .heading })
}

@Test func buildFillsSpokenRecursivelyAndCounts() {
    let blocks = [
        Block(id: 0, kind: .prose, confidence: 0.98, reason: "p",
              text: "First sentence. Second sentence."),
        Block(id: 1, kind: .code, confidence: 0.99, reason: "pre",
              text: ">>> import json\n>>> print(x)"),
        Block(id: 2, kind: .figure, confidence: 0.95, reason: "figure", text: "", children: [
            Block(id: 3, kind: .prose, confidence: 0.9, reason: "figcaption",
                  text: "A caption with one sentence."),
        ]),
        Block(id: 4, kind: .prose, confidence: 0.98, reason: "p", text: "   "),
    ]
    let plan = SpokenPlanBuilder.build(blocks: blocks, source: "test", sourceSHA256: "abc")
    #expect(plan.blocks[0].spoken.count == 2)
    #expect(plan.blocks[1].spoken.isEmpty)
    #expect(plan.blocks[2].spoken.isEmpty)
    #expect(plan.blocks[2].children[0].spoken.count == 1)
    #expect(plan.blocks[3].spoken.isEmpty)
    #expect(plan.sentenceCount == 3)
    #expect(plan.spokenWords == 9)
    #expect(plan.validationFailures == 0)
    #expect(plan.skipped.count == 1)
    #expect(plan.skipped[0].blockID == 1)
}
