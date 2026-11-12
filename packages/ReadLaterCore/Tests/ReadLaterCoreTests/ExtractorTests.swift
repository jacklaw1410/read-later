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
