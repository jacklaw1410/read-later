import Foundation

/// Checks the spoken plan invariant: every utterance must be an exact
/// character slice of its block's text. Returns every violation, not the
/// first, so one load reports the full damage.
enum SpokenPlanCheck {
    static func violations(in blocks: [Block]) -> [InvariantViolation] {
        var out: [InvariantViolation] = []
        func visit(_ block: Block) {
            let count = block.text.count
            for sentence in block.spoken {
                let rangeBad = sentence.offset < 0
                    || sentence.length <= 0
                    || sentence.offset + sentence.length > count
                if rangeBad {
                    out.append(InvariantViolation(
                        blockID: block.id,
                        sentenceOffset: sentence.offset,
                        sentenceLength: sentence.length,
                        expected: sentence.text,
                        actual: SpokenPlanEngine.slice(
                            block.text,
                            offset: sentence.offset,
                            length: sentence.length
                        ) ?? ""
                    ))
                    continue
                }
                let actual = SpokenPlanEngine.slice(
                    block.text,
                    offset: sentence.offset,
                    length: sentence.length
                ) ?? ""
                if actual != sentence.text {
                    out.append(InvariantViolation(
                        blockID: block.id,
                        sentenceOffset: sentence.offset,
                        sentenceLength: sentence.length,
                        expected: sentence.text,
                        actual: actual
                    ))
                }
            }
            for child in block.children { visit(child) }
        }
        for block in blocks { visit(block) }
        return out
    }
}
