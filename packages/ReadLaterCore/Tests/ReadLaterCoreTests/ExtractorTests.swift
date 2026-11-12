import Testing
import ReadLaterCore

/// Pages in the shape that broke the first walker: a table frame, a `<font>`
/// around the whole article, and paragraphs made with `<br><br>`.
private func page(_ body: String) -> String {
    """
    <html><head><title>Test</title></head><body>\(body)</body></html>
    """
}

private func longSentence(_ subject: String) -> String {
    "\(subject) is a sentence that is long enough to score as an article paragraph, "
        + "with commas, clauses, and enough words for the extractor to read it as prose."
}

@Test func headingBlockSpeaksEndToEnd() throws {
    let html = page(
        """
        <h2>Why calm software wins</h2>
        <p>\(longSentence("The opening paragraph of the article"))</p>
        <p>\(longSentence("The second paragraph of the article"))</p>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let headings = result.blocks.filter { $0.kind == .heading }
    #expect(headings.count == 1)
    #expect(headings[0].text == "Why calm software wins")
    let plan = SpokenPlanBuilder.build(blocks: result.blocks, source: "test", sourceSHA256: "abc")
    let spokenHeadings = plan.blocks.filter { $0.kind == .heading && !$0.spoken.isEmpty }
    #expect(spokenHeadings.count == 1)
    #expect(!plan.skipped.contains { $0.kind == .heading })
}

@Test func listKeepsOneBlockPerItem() throws {
    // F19 §1.13 shape: an ol of four items and a ul of five. The old
    // walker joined each list into one block with spaces; now every
    // item is its own block so the wash marks one item at a time.
    let html = page(
        """
        <p>\(longSentence("The opening paragraph of the article"))</p>
        <ol>
        <li>\(longSentence("First the reader opens the article"))</li>
        <li>\(longSentence("Then the voice starts at the top"))</li>
        <li>\(longSentence("Next the wash follows each word"))</li>
        <li>\(longSentence("Finally the place survives a relaunch"))</li>
        </ol>
        <ul>
        <li>Calm surfaces</li>
        <li>Spoken headings</li>
        <li>Honest tables</li>
        <li>Lazy images</li>
        <li>Kept places</li>
        </ul>
        <p>\(longSentence("The closing paragraph of the article"))</p>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let items = result.blocks.filter { $0.kind == .list }
    #expect(items.count == 9)
    #expect(items.contains { $0.text.hasPrefix("First the reader opens") })
    #expect(items.contains { $0.text.hasPrefix("Finally the place survives") })
    #expect(items.contains { $0.text == "Calm surfaces" })
    let plan = SpokenPlanBuilder.build(blocks: result.blocks, source: "test", sourceSHA256: "abc")
    let spokenItems = plan.blocks.filter { $0.kind == .list && !$0.spoken.isEmpty }
    #expect(spokenItems.count == 9)
    let index = SpokenIndex(blocks: plan.blocks)
    for item in spokenItems {
        #expect(index.byBlock[item.id] != nil)
    }
}

@Test func tableFramePageKeepsTheProse() throws {
    let html = page(
        """
        <table><tr><td><font size="2">
        \(longSentence("The first paragraph of the essay"))
        <br><br>
        \(longSentence("The second paragraph of the essay"))
        <br><br>
        \(longSentence("The third paragraph of the essay"))
        </font></td><td><a href="/x">Sidebar</a></td></tr></table>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    #expect(result.pageClass == .usable)
    let prose = result.blocks.filter { $0.kind == .prose }
    #expect(prose.count >= 3)
    #expect(!result.blocks.contains { $0.kind == .table })
}

@Test func brRunsSplitParagraphs() throws {
    let html = page(
        """
        <p>\(longSentence("Alpha"))<br><br>\(longSentence("Beta"))<br><br>\(longSentence("Gamma"))</p>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let prose = result.blocks.filter { $0.kind == .prose }
    #expect(prose.count == 3)
    #expect(prose.contains { $0.text.hasPrefix("Alpha") })
    #expect(prose.contains { $0.text.hasPrefix("Gamma") })
}

@Test func aSingleBreakStaysInsideTheParagraph() throws {
    let html = page("<p>\(longSentence("One line"))<br>and the next line.</p>")
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let prose = result.blocks.filter { $0.kind == .prose }
    #expect(prose.count == 1)
    #expect(prose[0].text.contains("and the next line"))
}

@Test func inlineTextIsNotEmittedTwice() throws {
    // A run of text, an inline link inside it, and a list after it. The old
    // walker put the text nodes in one block and the link text in a second.
    let html = page(
        """
        <div>
        <p>\(longSentence("The opening run of text"))
        <a href="/ref">a reference</a>
        \(longSentence("and the closing run of text"))</p>
        <ul><li>One item</li><li>Two item</li><li>Three item</li></ul>
        </div>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let all = result.blocks.map(\.text).joined(separator: " ")
    #expect(all.contains("a reference"))
    #expect(all.components(separatedBy: "a reference").count == 2)
    #expect(result.blocks.contains { $0.kind == .list })
}

@Test func theArticleRootDropsTheSidebar() throws {
    let html = page(
        """
        <div id="sidebar"><a href="/a">One</a><a href="/b">Two</a><a href="/c">Three</a></div>
        <div id="content">
        <p>\(longSentence("The article's first paragraph"))</p>
        <p>\(longSentence("The article's second paragraph"))</p>
        <p>\(longSentence("The article's third paragraph"))</p>
        </div>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let all = result.blocks.map(\.text).joined(separator: " ")
    #expect(all.contains("The article's first paragraph"))
    #expect(!all.contains("Three"))
}
