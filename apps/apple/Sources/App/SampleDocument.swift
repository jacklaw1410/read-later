import Foundation
import ReadLaterCore

/// Fixed 4-paragraph English article. Runs with no network. Every spoken
/// sentence is an exact UTF-16 slice of its block text; offsets are computed
/// from the joined text so the invariant holds by construction.
enum SampleDocument {
    static func make() -> Document {
        let paragraphs: [[String]] = [
            [
                "Slow reading is a quiet rebellion against the endless scroll.",
                "It asks the reader to stay with one page, one paragraph, one sentence at a time.",
            ],
            [
                "When you listen while you read, the voice sets the pace.",
                "Each word arrives exactly when the wash lights it up, and your eyes learn to follow.",
            ],
            [
                "An unfamiliar word used to break the flow.",
                "You would leave the page, open a dictionary, and lose your place before the answer arrived.",
            ],
            [
                "Here the meaning appears where you stand.",
                "Tap the word, glance at the gloss, and return to the sentence without losing the thread.",
            ],
        ]

        var blocks: [Block] = []
        var sentenceCount = 0
        var spokenWords = 0
        for (index, sentences) in paragraphs.enumerated() {
            var text = ""
            var spoken: [Sentence] = []
            for sentence in sentences {
                if !text.isEmpty {
                    text += " "
                }
                let offset = text.utf16.count
                text += sentence
                spoken.append(Sentence(offset: offset, length: sentence.utf16.count, text: sentence))
                sentenceCount += 1
                spokenWords += sentence.split(separator: " ").count
            }
            blocks.append(Block(
                id: index,
                kind: .prose,
                confidence: 1.0,
                reason: "hand-authored sample",
                text: text,
                spoken: spoken
            ))
        }

        let plan = BlockPlan(
            version: 1,
            source: "sample://slow-reading",
            sourceSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
            sentenceCount: sentenceCount,
            spokenWords: spokenWords,
            blocks: blocks
        )
        return Document(url: nil, title: "The Quiet Art of Slow Reading", plan: plan)
    }
}
