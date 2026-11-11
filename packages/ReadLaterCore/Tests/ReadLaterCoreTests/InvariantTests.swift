import Testing
import ReadLaterCore

private func smallPlan() -> BlockPlan {
    let blocks = [
        Block(id: 0, kind: .prose, confidence: 0.98, reason: "p",
              text: "First sentence. Second sentence."),
        Block(id: 1, kind: .quote, confidence: 0.92, reason: "blockquote", text: "", children: [
            Block(id: 2, kind: .prose, confidence: 0.9, reason: "p",
                  text: "Quoted words here."),
        ]),
    ]
    return SpokenPlanBuilder.build(blocks: blocks, source: "test", sourceSHA256: "abc")
}

@Test func invariantPassesOnBuiltPlan() {
    let plan = smallPlan()
    #expect(SpokenPlanInvariant.violations(in: plan.blocks).isEmpty)
}

@Test func shiftedOffsetFailsAndReportsBlockID() {
    var plan = smallPlan()
    plan.blocks[0].spoken[0].offset += 1
    let violations = SpokenPlanInvariant.violations(in: plan.blocks)
    #expect(violations.count == 1)
    #expect(violations[0].blockID == 0)
}

@Test func zeroLengthSentenceFails() {
    let blocks = [
        Block(id: 7, kind: .prose, confidence: 0.98, reason: "p",
              text: "Some words here.", spoken: [Sentence(offset: 0, length: 0, text: "")]),
    ]
    let violations = SpokenPlanInvariant.violations(in: blocks)
    #expect(violations.count == 1)
    #expect(violations[0].blockID == 7)
}

@Test func outOfRangeSentenceFails() {
    let blocks = [
        Block(id: 8, kind: .prose, confidence: 0.98, reason: "p",
              text: "Short.", spoken: [Sentence(offset: 0, length: 50, text: "Short.")]),
    ]
    let violations = SpokenPlanInvariant.violations(in: blocks)
    #expect(violations.count == 1)
    #expect(violations[0].blockID == 8)
}

@Test func childViolationReportsChildID() {
    var plan = smallPlan()
    plan.blocks[1].children[0].spoken[0].length += 1
    let violations = SpokenPlanInvariant.violations(in: plan.blocks)
    #expect(violations.count == 1)
    #expect(violations[0].blockID == 2)
}
