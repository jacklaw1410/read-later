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

@Test func figureKeepsImageReferenceAndCaption() throws {
    // F19 §1.14 shape: a figure wrapping an img plus a caption. The block
    // keeps src/alt; the caption text stays the caption well.
    let html = page(
        """
        <p>\(longSentence("The opening paragraph of the article"))</p>
        <figure><img src="https://example.com/chart.png" alt="Adoption curve, 2020 to 2026"><figcaption>\(longSentence("The caption under the chart"))</figcaption></figure>
        <p>\(longSentence("The closing paragraph of the article"))</p>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let figures = result.blocks.filter { $0.kind == .figure }
    #expect(figures.count == 1)
    #expect(figures[0].imageURL == "https://example.com/chart.png")
    #expect(figures[0].alt == "Adoption curve, 2020 to 2026")
    #expect(figures[0].text.contains("The caption under the chart"))
}

@Test func bareImgBecomesImageBlockWithSrcsetFallback() throws {
    let html = page(
        """
        <p>\(longSentence("The opening paragraph of the article"))</p>
        <img srcset="https://example.com/small.png 480w, https://example.com/big.png 1024w" alt="A small diagram">
        <p>\(longSentence("The closing paragraph of the article"))</p>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let images = result.blocks.filter { $0.kind == .image }
    #expect(images.count == 1)
    #expect(images[0].imageURL == "https://example.com/small.png")
    #expect(images[0].alt == "A small diagram")
}

@Test func dataTableKeepsRowsAsUnits() throws {
    // F19 §1.15: a results table degrades to rows, never to prose. Each
    // row is a unit, cells joined with a voice-readable separator.
    let html = page(
        """
        <p>\(longSentence("The opening paragraph of the article"))</p>
        <table><tr><th>Year</th><th>Sales</th></tr><tr><td>2024</td><td>Twelve thousand units moved in spring.</td></tr><tr><td>2025</td><td>Fifteen thousand units moved in spring.</td></tr></table>
        <p>\(longSentence("The closing paragraph of the article"))</p>
        """
    )
    let result = try SwiftSoupExtractor().extract(html: html, source: "test", httpStatus: 200)
    let tables = result.blocks.filter { $0.kind == .table && $0.text.contains("Sales") }
    #expect(tables.count == 1)
    #expect(tables[0].children.count == 3)
    #expect(tables[0].children[0].text == "Year, Sales")
    #expect(tables[0].children[1].text == "2024, Twelve thousand units moved in spring.")
    let plan = SpokenPlanBuilder.build(blocks: result.blocks, source: "test", sourceSHA256: "abc")
    let spokenTables = plan.blocks.flatMap { [$0] + $0.children }.filter { $0.kind == .table && !$0.spoken.isEmpty }
    #expect(spokenTables.isEmpty)
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
