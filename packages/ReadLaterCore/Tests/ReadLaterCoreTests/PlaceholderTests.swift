import Testing
import ReadLaterCore

@Test func blockKindCoversTheContract() {
    #expect(BlockKind.allCases.count == 16)
    #expect(BlockKind.pullQuote.rawValue == "pull-quote")
    #expect(BlockKind.footnoteBody.rawValue == "footnote-body")
}

@Test func lowConfidenceDefaultsBelowPointEight() {
    let unsure = Block(id: 0, kind: .prose, confidence: 0.7, reason: "shape-unsure", text: "x")
    let sure = Block(id: 1, kind: .prose, confidence: 0.9, reason: "p", text: "x")
    #expect(unsure.lowConfidence)
    #expect(!sure.lowConfidence)
}
