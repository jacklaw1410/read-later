import Testing
import ReadLaterCore

// MARK: - Classifier

@Test func elementIdentityDecidesKind() {
    #expect(Classifier.classify(tag: "h1", text: "Title").kind == .heading)
    #expect(Classifier.classify(tag: "p", text: "Some plain words here.").kind == .prose)
    #expect(Classifier.classify(tag: "pre", text: "x = 1").kind == .code)
    #expect(Classifier.classify(tag: "blockquote", text: "Quoted.").kind == .quote)
    #expect(Classifier.classify(tag: "ul", text: "one two three").kind == .list)
    #expect(Classifier.classify(tag: "table", text: "a b c").kind == .table)
    #expect(Classifier.classify(tag: "aside", text: "Side note.").kind == .aside)
    #expect(Classifier.classify(tag: "img", text: "").kind == .image)
    #expect(Classifier.classify(tag: "math", text: "x").kind == .math)
    #expect(Classifier.classify(tag: "iframe", text: "").kind == .embed)
    #expect(Classifier.classify(tag: "figcaption", text: "Caption.").kind == .figure)
}

@Test func navRoleAndClassWin() {
    #expect(Classifier.classify(tag: "div", classNames: [], role: "navigation", text: "Home About").kind == .nav)
    #expect(Classifier.classify(tag: "div", classNames: ["menu"], text: "Home About").kind == .nav)
}

@Test func pullquoteClassWins() {
    let verdict = Classifier.classify(tag: "blockquote", classNames: ["pull-quote"], text: "Quoted.")
    #expect(verdict.kind == .pullQuote)
}

@Test func infoboxTableIsAside() {
    let verdict = Classifier.classify(tag: "table", classNames: ["infobox"], text: "Born Died")
    #expect(verdict.kind == .aside)
}

@Test func cjkTextIsCjk() {
    let text = "这是中文测试内容，里面有很多汉字，足够触发比例阈值了，请继续阅读下去吧。"
    let verdict = Classifier.classify(tag: "div", text: text)
    #expect(verdict.kind == .cjk)
}

@Test func codeShapeIsCode() {
    let text = ">>> import json\n>>> print(json.dumps(x))\n>>> done here now"
    let verdict = Classifier.classify(tag: "div", text: text)
    #expect(verdict.kind == .code)
}

@Test func shapeUnsureIsProseWithLowConfidence() {
    let verdict = Classifier.classify(tag: "div", text: "Just some ordinary words here.")
    #expect(verdict.kind == .prose)
    #expect(verdict.confidence < 0.8)
}

@Test func singleLineWithInlineCodeStaysProse() {
    let verdict = Classifier.classify(
        tag: "p", text: "But remember to always use Array and Map for this simple task at hand today.")
    #expect(verdict.kind == .prose)
}

// MARK: - Extractor

private let extractor = SwiftSoupExtractor()

private func pageClass(of html: String) -> PageClass {
    do {
        return try extractor.extract(html: html, source: "test").pageClass
    } catch let error as ExtractionError {
        switch error {
        case .badURL, .emptyDocument:
            return .failed
        case .notAnArticle:
            return .notAnArticle
        case .walled:
            return .walled
        case .unrendered:
            return .unrendered
        }
    } catch {
        return .failed
    }
}

private let usableHTML = """
    <html><head><title>How rivers work</title></head><body>
    <article>
    <h1>How rivers work</h1>
    <p>Rivers carve valleys over long stretches of time, and they carry soil \
    from the hills down to the plains where farms can use the rich silt.</p>
    <p>The water moves faster in narrow bends, and slower where the bed \
    grows wide and flat near the mouth of the river valley floor.</p>
    <p>Fish return each spring to lay eggs in the cold clear water upstream, \
    far from the warm slow pools where birds gather every single day.</p>
    </article>
    </body></html>
    """

@Test func smallProsePageIsUsable() throws {
    let result = try extractor.extract(html: usableHTML, source: "test")
    #expect(result.pageClass == .usable)
    #expect(result.blocks.contains { $0.kind == .prose })
    let plan = SpokenPlanBuilder.build(blocks: result.blocks, source: "test", sourceSHA256: "abc")
    #expect(plan.sentenceCount > 0)
    #expect(plan.validationFailures == 0)
}

@Test func paywallPageIsWalled() {
    let html = """
        <html><head><title>Big story</title></head><body>
        <p>Reporters spent months digging through records and talking to \
        neighbours, and they found a pattern of quiet deals shaping the town.</p>
        <p>The full investigation names names and traces money across three \
        counties, with maps and timelines that took weeks to assemble.</p>
        <p>Subscribe to continue reading this story today.</p>
        <p>This article is for subscribers only.</p>
        </body></html>
        """
    #expect(pageClass(of: html) == .walled)
}

@Test func indexPageIsNotAnArticle() {
    var links = ""
    for i in 1...20 {
        links += "<div><a href=\"/story\(i)\">Story headline number \(i)</a></div>"
    }
    let html = "<html><head><title>Home</title></head><body>\(links)<p>Top stories today.</p></body></html>"
    #expect(pageClass(of: html) == .notAnArticle)
}

@Test func jsShellIsUnrendered() {
    let padding = String(repeating: "var data=\"xxxxxxxxxx\";", count: 600)
    let html = """
        <html><head><title>App</title></head><body>
        <div id="root"></div><p>Loading the application now</p>
        <script>\(padding)</script>
        </body></html>
        """
    #expect(pageClass(of: html) == .unrendered)
}

@Test func emptyHTMLIsFailed() {
    #expect(pageClass(of: "") == .failed)
    #expect(pageClass(of: "   \n  ") == .failed)
}
