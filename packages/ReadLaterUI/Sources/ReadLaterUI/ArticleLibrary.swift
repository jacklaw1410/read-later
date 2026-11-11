import CryptoKit
import Foundation
import ReadLaterCore

/// The demo document behind the entry flow. One document, every block kind,
/// spoken filled by the builder so the invariant holds by construction.
///
/// Order: nav first as page chrome, then prose, heading, code, table, figure,
/// math, quote, pull quote, embed, list, aside, and the footnote body. The
/// fifth prose block carries the footnote marker that the footnote body
/// answers. The rare word susurrus and the accented word café exercise the
/// miss card and the accent path without editing data.
public enum ArticleLibrary {
    public static let title = "The Quiet Power of Slow Reading"
    public static let source = "theatlantic.com"
    public static let sampleURL = URL(string: "https://www.theatlantic.com/reading/slow")

    public static let demo: Document = {
        let blocks = Self.blocks()
        let plan = SpokenPlanBuilder.build(
            blocks: blocks,
            source: Self.source,
            sourceSHA256: Self.sha256(blocks.map(\.text).joined(separator: "\n"))
        )
        return Document(url: Self.sampleURL, title: Self.title, plan: plan)
    }()

    /// A document from pasted text, via the same loader the entry view uses.
    public static func pasted(from text: String) -> Document? {
        PasteLoader.document(from: text, title: nil)
    }

    private static func blocks() -> [Block] {
        var blocks: [Block] = [
            Block(
                id: 1,
                kind: .nav,
                confidence: 0.95,
                reason: "element: nav",
                text: "Sections · Reading · Science · Saved"
            ),
            Block(
                id: 2,
                kind: .prose,
                confidence: 0.98,
                reason: "element: p",
                text: "In a world that rewards speed, choosing to read slowly is a radical act of attention. We skim messages, headlines, and sometimes entire books, then wonder why nothing stays with us. The fault is rarely memory. It is pace. Slow reading returns the reader to the sentence itself, one clause at a time, and asks only that we stay a little longer than feels efficient. Attention is the rarest courtesy we pay, and the page is patient enough to receive it. A slow reader is not a slow thinker. The two are different arts, and the second depends on the first more than school ever admitted. What follows is a case for lingering, and a set of small practices that make lingering possible in an ordinary week."
            ),
            Block(
                id: 3,
                kind: .prose,
                confidence: 0.98,
                reason: "element: p",
                text: "A fast reader harvests conclusions. A slow reader keeps the whole field. Give a paragraph unhurried time and secondary meanings surface: the hesitation in a reply, the edge under a polite editorial, the faint susurrus of pages turning in a quiet room. None of this is decoration. Comprehension research keeps finding the same pattern, which is that readers who pause to paraphrase remember more a week later than readers who push on. Speed gets you through the text. Slowness lets the text get through to you, and the difference shows the next time someone asks what the piece actually claimed. Teachers see it every term: the student who read twice, slowly, out-argues the student who skimmed five sources. Depth beats coverage when the test is understanding rather than recall of headlines."
            ),
            Block(
                id: 4,
                kind: .prose,
                confidence: 0.98,
                reason: "element: p",
                text: "Setting matters more than we admit. A phone buzzes, while a café hums, and the hum is kinder because it asks for nothing. Slow readers choose their rooms the way cooks choose their knives, with care and without apology. Put the phone in another room. Make tea. Sit where the light falls on the page instead of the screen. These are not rituals of nostalgia. They are load-bearing walls, small structures that hold attention up when willpower sags. Build the room first, and the reading follows, in any language and at any age. Noise is not the enemy; demand is. A room that asks nothing of you gives everything back, page after page, until the chapter ends and the tea is cold."
            ),
            Block(
                id: 5,
                kind: .prose,
                confidence: 0.98,
                reason: "element: p",
                text: "Consider what a week of slow reading actually changes. First, stamina returns. A reader who finishes one long essay without checking a feed discovers the muscle still exists, and muscles remember being used. Second, taste sharpens. When every sentence gets its full second, weak transitions show and strong ones sing, so the reader starts to notice craft instead of merely consuming conclusions. Third, memory deepens, because elaboration is the engine of recall and slowness is elaboration with the brakes off. None of this requires a cabin, a sabbatical, or a new device. It requires twenty minutes, a chair, and a willingness to be unreachable for a little while. Start smaller than you think. Ten pages a day is a book a month, and a book a month is twelve books a year, which is more than most shelves hold of books actually finished. The arithmetic of patience is generous and it compounds quietly. Keep a pencil nearby, not to annotate for posterity but to slow the hand to the speed of the eye. Underline one true sentence per page. Copy it out if it earns the ink. Months later the notebook becomes a second book, shorter than the first and entirely yours, built sentence by sentence from other writers’ best lines. A paragraph reread is not a paragraph repeated. It is a paragraph met twice, under different light, by a slightly different reader, and the second meeting is usually the one that keeps."
            ),
            Block(
                id: 6,
                kind: .prose,
                confidence: 0.97,
                reason: "element: p",
                text: "Begin tonight. Read one page slowly, then close the book and say back what it claimed. Linger on the last line, and let it keep its echo.",
                children: [
                    Block(
                        id: 7,
                        kind: .footnoteMarker,
                        confidence: 0.9,
                        reason: "element: sup",
                        text: "¹"
                    )
                ]
            ),
            Block(
                id: 8,
                kind: .heading,
                confidence: 0.96,
                reason: "element: h2",
                text: "Why the pace matters"
            ),
            Block(
                id: 9,
                kind: .code,
                confidence: 0.99,
                reason: "element: pre",
                text: "const pace = 140; // words per minute\nconst msPerWord = 60000 / pace; // about 429 ms per word"
            ),
            Block(
                id: 10,
                kind: .table,
                confidence: 0.94,
                reason: "element: table",
                text: "Pace | WPM | Feel\nSlow | 120 | dwelling\nSteady | 140 | even\nFast | 200 | skimming"
            ),
            Block(
                id: 11,
                kind: .figure,
                confidence: 0.92,
                reason: "element: figcaption",
                text: "A reader at a wooden desk, page held at eye level in the late light."
            ),
            Block(
                id: 12,
                kind: .math,
                confidence: 0.93,
                reason: "element: math",
                text: "x = (−b ± √(b² − 4ac)) / 2a"
            ),
            Block(
                id: 13,
                kind: .quote,
                confidence: 0.95,
                reason: "element: blockquote",
                text: "Attention is a practice, not a talent."
            ),
            Block(
                id: 14,
                kind: .pullQuote,
                confidence: 0.9,
                reason: "element: aside",
                text: "To read slowly is to refuse the attention economy."
            ),
            Block(
                id: 15,
                kind: .embed,
                confidence: 0.91,
                reason: "element: iframe",
                text: "Embedded video player · audio skips"
            ),
            Block(
                id: 16,
                kind: .list,
                confidence: 0.93,
                reason: "element: li",
                text: "Keep the phone in another room while you read.\nGive each essay twenty unbroken minutes before judging it.\nReread the passage that resisted you; resistance marks the place where the meaning lives."
            ),
            Block(
                id: 17,
                kind: .aside,
                confidence: 0.9,
                reason: "element: aside",
                text: "A note on difficulty: hard passages are not broken passages. Law, science, and poetry all ask for rereading, and the rereading is the reading. Confusion is often the feeling of comprehension arriving early."
            ),
            Block(
                id: 18,
                kind: .footnoteBody,
                confidence: 0.9,
                reason: "element: fn",
                text: "A 2024 study of sustained attention found that readers who held to 140 words per minute recalled 31 percent more detail after one week than readers who skimmed at twice the pace."
            ),
        ]
        return blocks
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
