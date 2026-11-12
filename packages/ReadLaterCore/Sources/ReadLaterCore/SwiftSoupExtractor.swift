import Foundation
import SwiftSoup

/// Parses HTML with SwiftSoup and returns an `ExtractionResult`.
///
/// Page classes are detected in this order: failed (no body, unparseable),
/// unrendered (JS shell), walled (login/paywall markers), not-an-article
/// (index or landing page), usable. Non-usable pages throw the stopping
/// class, per the `Extractor` contract.
public struct SwiftSoupExtractor: Extractor {
    public init() {}

    public func extract(html: String, source: String, httpStatus: Int?) throws -> ExtractionResult {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.emptyDocument
        }
        let doc: SwiftSoup.Document
        do {
            doc = try SwiftSoup.parse(html)
        } catch {
            throw ExtractionError.emptyDocument
        }
        guard let body = doc.body() else {
            throw ExtractionError.emptyDocument
        }
        // Nodes that never produce blocks. Removed before measuring the body.
        if let stripped = try? body.select("script, style, noscript, form, iframe, svg") {
            _ = try? stripped.remove()
        }
        let bodyText = ((try? body.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (try? doc.title()) ?? ""
        let bodyChars = bodyText.count
        let bodyWords = SpokenPlanEngine.wordCount(in: bodyText)
        // The root-scoped counts below decide the class. Only one whole-body
        // count survives: the link characters the no-blocks fallback needs.
        let bodyLinkChars = ((try? body.select("a")) ?? Elements()).array()
            .reduce(0) { $0 + (((try? $1.text()) ?? "").count) }
        let lowered = html.lowercased()

        // A wall is decided by the response and the markup, not by the body text. A paywall
        // page often has no readable body once scripts are stripped, so this check runs
        // before the empty guard; otherwise the wall reports as `failed` and the class is
        // wrong in a way the card copy cannot fix.
        if let status = httpStatus, WallStatus.denied.contains(status) {
            throw ExtractionError.walled(reason: "http \(status)")
        }
        if let marker = Self.wallMarker(in: lowered, title: title.lowercased()) {
            throw ExtractionError.walled(reason: "wall marker: \(marker)")
        }
        // A login or app screen is `not-an-article`, not `unrendered`. The
        // js-shell check below fires on the same short-body shape (pin 64,
        // Tumblr login, 284 chars), so this runs first. Mirrors the gate's
        // `is_short_chrome` login/app prongs: body under 300 chars with login
        // or app words in the title and body together. The catalogue prong is
        // deliberately not mirrored; it needs its own measurement.
        if bodyChars < 300 {
            let combined = "\(title) \(bodyText)"
            if Self.matchesLoginChrome(combined) {
                throw ExtractionError.notAnArticle(
                    reason: "login-chrome: body \(bodyChars) chars"
                )
            }
            if Self.matchesAppChrome(combined) {
                throw ExtractionError.notAnArticle(
                    reason: "app-chrome: body \(bodyChars) chars"
                )
            }
        }
        if bodyChars < 200 && (html.count >= 8000 || Self.containsSPAMarker(lowered)) {
            throw ExtractionError.unrendered(
                reason: "js-shell: body \(bodyChars) chars, html \(html.count) chars"
            )
        }
        guard !bodyText.isEmpty else {
            throw ExtractionError.emptyDocument
        }
        // V1: choose the article roots before the index rule, and measure the
        // index shapes on the union of the roots, not the whole body. A
        // "related reads" rail must not turn a real article into
        // `not-an-article`. When a root is the body itself the numbers are
        // identical to the whole-body measure.
        func measure(_ roots: [Element]) -> (chars: Int, words: Int, links: Int, linkChars: Int, paragraphs: Int) {
            let text = roots.map { ((try? $0.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            var links = 0
            var linked = 0
            var paragraphs = 0
            for root in roots {
                let tag = root.tagNameNormal()
                let linkElements = (try? root.select("a")) ?? Elements()
                for link in linkElements.array() {
                    if link === root { continue }
                    links += 1
                    linked += ((try? link.text()) ?? "").count
                }
                if tag == "a", linkElements.isEmpty() {
                    if (((try? root.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).count > 0 {
                        links += 1
                        linked += ((try? root.text()) ?? "").count
                    }
                }
                for p in ((try? root.select("p")) ?? Elements()).array() {
                    if p === root { continue }
                    if (((try? p.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).count > 0 {
                        paragraphs += 1
                    }
                }
                if tag == "p",
                   (((try? root.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).count > 0
                {
                    paragraphs += 1
                }
            }
            return (text.count, SpokenPlanEngine.wordCount(in: text), links, linked, paragraphs)
        }

        // V1b: a root that holds almost no words is a bad root, not a bad page.
        // The words still exist on the page, so fall back to the body. Without
        // this, one pinned article (The Verge) loses 100% of its text.
        var roots = ContentRoot.roots(in: body)
        var metrics = measure(roots)
        if metrics.words < 20 && bodyWords >= 20 {
            roots = [body]
            metrics = measure(roots)
        }
        let linkCount = metrics.links
        let linkChars = metrics.linkChars
        let paragraphs = metrics.paragraphs
        let rootChars = metrics.chars
        let rootWords = metrics.words
        let linkDensity = Double(linkChars) / Double(max(rootChars, 1))
        // The index rule needs a short page. A 4,000-word article with fifteen links in it
        // is an article, and calling it an index loses the page for no gain.
        if (linkCount >= 15 && paragraphs <= 3 && rootWords < 600)
            || (paragraphs == 0 && rootWords < 100)
            || (rootWords < 40 && linkDensity >= 0.5)
        {
            throw ExtractionError.notAnArticle(
                reason: "index: \(linkCount) links, \(paragraphs) paragraphs, \(rootWords) words"
            )
        }
        guard rootWords >= 20 else {
            throw ExtractionError.emptyDocument
        }

        var walker = BlockWalker()
        // The article body first, not the page: chrome around it costs a reader
        // their place and teaches the classifier a false pattern.
        for root in roots {
            if root === body {
                try walker.run(body)
            } else {
                try walker.process(root)
            }
        }
        var blocks = walker.blocks
        if blocks.isEmpty {
            let verdict = Classifier.classify(
                tag: "body", classNames: [], role: nil,
                text: bodyText, linkTextChars: bodyLinkChars
            )
            blocks = [Block(
                id: 0,
                kind: verdict.kind,
                confidence: verdict.confidence,
                reason: verdict.reason.isEmpty ? "body" : verdict.reason,
                text: bodyText
            )]
        }
        return ExtractionResult(
            pageClass: .usable,
            blocks: blocks,
            reason: "usable: \(blocks.count) blocks from \(source)",
            title: title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        )
    }

    // MARK: - Gate markers

    /// The gate's `is_short_chrome` word lists, copied exactly
    /// (`read-later-research/gate/extraction_gate.py`).
    static func matchesLoginChrome(_ text: String) -> Bool {
        let pattern = #"\b(log in|login|sign up|register)\b"#
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
            .map { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            ?? false
    }

    static func matchesAppChrome(_ text: String) -> Bool {
        let pattern = #"(to run this app|whiteboard)"#
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
            .map { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            ?? false
    }

    /// A JS shell: tiny body text plus a large HTML payload or a known
    /// single-page-app marker. Checked before walls so a shell cannot pass.
    static func containsSPAMarker(_ loweredHTML: String) -> Bool {
        let markers = [
            "__next_data__", "data-reactroot", "ng-app", "ng-version",
            "data-nuxt", "__initial_state__", "id=\"root\"", "id='root'",
            "id=\"app\"", "id='app'",
            "enable javascript", "requires javascript", "javascript is disabled",
            "javascript is required", "please enable javascript",
            "you need to enable javascript",
        ]
        return markers.contains { loweredHTML.contains($0) }
    }

    /// The wall markers are the gate's markers, copied rather than invented.
    /// Each one fired on a walled page and on zero usable rows of the reader-like
    /// corpus and the pins (`read-later-research/gate/inputs/wall_rule.py`).
    ///
    /// A wider list is not safer. `metered` and a bare `paywall` appear in the
    /// scripts and metadata of ordinary articles: on the pinned corpus they
    /// refused two full articles that the gate passes.
    static func wallMarker(in loweredHTML: String, title: String) -> String? {
        let htmlMarkers = [
            "data-testid=\"paywall\"",
            "keep reading with a 7-day free trial",
            "already a paid subscriber?",
            "subscribe to continue",
            "you've read your last free article",
            "you have read your last free article",
        ]
        for marker in htmlMarkers where loweredHTML.contains(marker) {
            return marker
        }
        let titleMarkers = ["access denied", "log in or sign up"]
        for marker in titleMarkers where title.contains(marker) {
            return marker
        }
        return nil
    }
}

// MARK: - DOM walk

/// Walks the cleaned body in document order. Leaf blocks consume their
/// subtree (one block per element, text is the element's own normalised
/// text). Containers with block-level descendants recurse; their own direct
/// text becomes a shape-classified block.
private struct BlockWalker {
    var blocks: [Block] = []
    var nextID = 0

    static let leafTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote",
        "ul", "ol", "dl", "table", "figure", "figcaption", "aside", "nav",
        "li", "dt", "dd", "code", "img", "math", "video", "audio",
        "object", "embed",
    ]
    static let containerTags: Set<String> = [
        "div", "section", "article", "main", "header", "footer",
        // Table layout was the normal way to build a page until the late 2000s, and
        // old essays still ship that way. A layout table recurses, so the prose in
        // its cells becomes blocks instead of one skipped table. The rule that
        // picks it is `isLayoutTable`; a data table stays a leaf.
        "thead", "tbody", "tfoot", "tr", "td", "th",
    ]
    static let blockDescendantQuery = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote",
        "ul", "ol", "dl", "table", "figure", "figcaption", "aside", "nav",
        "div", "section", "article", "main", "li", "header", "footer", "code",
    ].joined(separator: ", ")

    mutating func run(_ body: Element) throws {
        try processContainer(body, tag: "body")
    }

    mutating func process(_ element: Element) throws {
        let tag = element.tagNameNormal()
        if tag == "table" {
            if Self.isLayoutTable(element) {
                try processContainer(element, tag: tag)
            } else {
                try processLeaf(element, tag: tag)
            }
            return
        }
        // F19 1.13: a list keeps its item boundaries. One block per item,
        // as siblings, so the wash marks one item at a time and a later
        // renderer can number ordinals without the voice saying them.
        // The old path took element.text() whole and joined every item
        // with spaces, losing ordinals, bullets and the boundaries.
        if tag == "ul" || tag == "ol" || tag == "dl" {
            try processList(element, tag: tag)
            return
        }
        if Self.containerTags.contains(tag) {
            try processContainer(element, tag: tag)
        } else if Self.leafTags.contains(tag) {
            try processLeaf(element, tag: tag)
        } else {
            // An inline element at block position that wraps block-level content
            // (`<font>` around a whole page, an anchor around a card) is a
            // container in disguise. Treating it as a leaf merges every paragraph
            // inside it into one block, which is how a 4,500-word essay became a
            // single block.
            let descendants = (try? element.select(Self.blockDescendantQuery)) ?? Elements()
            if !descendants.isEmpty() {
                try processContainer(element, tag: tag)
                return
            }
            // Inline or unknown element at block position: one block from
            // its combined text so no words are lost.
            let text = Self.normalise((try? element.text()) ?? "")
            guard !text.isEmpty else { return }
            emit(
                Classifier.classify(
                    tag: tag,
                    classNames: classes(of: element),
                    role: role(of: element),
                    text: text,
                    lines: Self.lines((try? element.text(trimAndNormaliseWhitespace: false)) ?? "")
                ),
                text: text
            )
        }
    }

    mutating func processLeaf(_ element: Element, tag: String) throws {
        let text = Self.normalise((try? element.text()) ?? "")
        guard !text.isEmpty else { return }
        if tag != "pre" && tag != "code" {
            // Older pages break paragraphs with `<br /><br />` inside one `<p>`, and
            // the text API turns each break into a space. Split on the breaks so each
            // paragraph is a block: the reader shows a paragraph, and a wash word
            // sits in one block instead of a 4,500-word wall.
            let chunks = Self.inlineChunks(of: element)
            if chunks.count > 1 {
                for chunk in chunks {
                    emit(
                        Classifier.classify(
                            tag: tag,
                            classNames: classes(of: element),
                            role: role(of: element),
                            text: chunk.text,
                            linkTextChars: chunk.linkChars
                        ),
                        text: chunk.text
                    )
                }
                return
            }
        }
        var linkChars = 0
        if let links = try? element.select("a") {
            for link in links {
                linkChars += ((try? link.text()) ?? "").count
            }
        }
        emit(
            Classifier.classify(
                tag: tag,
                classNames: classes(of: element),
                role: role(of: element),
                text: text,
                linkTextChars: linkChars,
                lines: Self.lines((try? element.text(trimAndNormaliseWhitespace: false)) ?? "")
            ),
            text: text
        )
    }

    /// One block per list item, as siblings in document order.
    ///
    /// An item's own text becomes its block; a nested list recurses after
    /// its parent item so reading order holds. Stray text directly inside
    /// the list (malformed markup) becomes one block from the run.
    mutating func processList(_ element: Element, tag: String) throws {
        var run = InlineRun()
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                run.add(textNode.text())
                continue
            }
            guard let child = node as? Element else { continue }
            let childTag = child.tagNameNormal()
            if childTag == "li" || childTag == "dt" || childTag == "dd" {
                emitRun(&run, element: element, tag: tag)
                try processListItem(child)
            } else if childTag == "ul" || childTag == "ol" || childTag == "dl" {
                emitRun(&run, element: element, tag: tag)
                try processList(child, tag: childTag)
            } else if Self.isBlockPosition(child) {
                emitRun(&run, element: element, tag: tag)
                try process(child)
            } else {
                run.add(inline: child)
            }
        }
        emitRun(&run, element: element, tag: tag)
    }

    /// One item: its own inline text first, then any nested list, in order.
    mutating func processListItem(_ element: Element) throws {
        let tag = element.tagNameNormal()
        var run = InlineRun()
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                run.add(textNode.text())
                continue
            }
            guard let child = node as? Element else { continue }
            let childTag = child.tagNameNormal()
            if childTag == "ul" || childTag == "ol" || childTag == "dl" {
                emitRun(&run, element: element, tag: tag)
                try processList(child, tag: childTag)
            } else if Self.isBlockPosition(child) {
                emitRun(&run, element: element, tag: tag)
                try process(child)
            } else {
                run.add(inline: child)
            }
        }
        emitRun(&run, element: element, tag: tag)
    }

    /// Walks a container in document order. Text and inline markup between block
    /// children gather into a run; each block child ends the run and is processed
    /// on its own.
    ///
    /// The old path walked only `children()` and emitted `ownText()` after them,
    /// which put every direct text node into one block and put the text of inline
    /// children into a second block. On a page whose body is one `<font>` that
    /// split a 5,000-word essay into a wall plus a handful of fragments.
    mutating func processContainer(_ element: Element, tag: String) throws {
        var run = InlineRun()
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                run.add(textNode.text())
                continue
            }
            guard let child = node as? Element else { continue }
            if Self.isBlockPosition(child) {
                emitRun(&run, element: element, tag: tag)
                try process(child)
            } else {
                run.add(inline: child)
            }
        }
        emitRun(&run, element: element, tag: tag)
    }

    mutating func emitRun(_ run: inout InlineRun, element: Element, tag: String) {
        for chunk in run.drain() {
            emit(
                Classifier.classify(
                    tag: tag,
                    classNames: classes(of: element),
                    role: role(of: element),
                    text: chunk.text,
                    linkTextChars: chunk.linkChars
                ),
                text: chunk.text
            )
        }
    }

    mutating func emit(_ verdict: Classification, text: String) {
        blocks.append(Block(
            id: nextID,
            kind: verdict.kind,
            confidence: verdict.confidence,
            reason: verdict.reason,
            text: text
        ))
        nextID += 1
    }

    // MARK: - Element helpers

    /// A table that holds block-level prose is a page frame, not data.
    ///
    /// Paul Graham's essays are one table: the sidebar, the column rule and the essay
    /// share it. Treated as a leaf it became a single `table` block, and the whole
    /// essay was skipped. The marker is paragraph-level content inside the table: a
    /// data table puts prose in its cells only in the rare caption, and that caption
    /// still reads correctly as part of the table.
    static func isLayoutTable(_ element: Element) -> Bool {
        let prose = (try? element.select("p, h1, h2, h3, h4, h5, h6, blockquote, pre")) ?? Elements()
        return !prose.isEmpty()
    }

    struct Chunk {
        var text: String
        var linkChars: Int
    }

    /// Gathers the inline content of one element into paragraph chunks.
    ///
    /// A run of two or more `<br>` ends a paragraph. A single break is a line
    /// break inside a paragraph and stays a space.
    struct InlineRun {
        private var chunks: [Chunk] = []
        private var buffer = ""
        private var linkBuffer = 0
        private var breaks = 0
        private var linkDepth = 0

        mutating func add(_ value: String) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Whitespace between two `<br>` tags does not end the run.
                if breaks == 0 { buffer += " " }
                return
            }
            beforeInline()
            buffer += value
            if linkDepth > 0 { linkBuffer += value.count }
        }

        mutating func add(inline element: Element) {
            let tag = element.tagNameNormal()
            if tag == "br" {
                breaks += 1
                return
            }
            if tag == "img" || tag == "wbr" { return }
            beforeInline()
            let isLink = tag == "a"
            if isLink { linkDepth += 1 }
            for node in element.getChildNodes() {
                if let textNode = node as? TextNode {
                    add(textNode.text())
                } else if let child = node as? Element {
                    add(inline: child)
                }
            }
            if isLink { linkDepth -= 1 }
        }

        /// Returns the finished chunks and starts a new run.
        mutating func drain() -> [Chunk] {
            flush()
            let done = chunks
            chunks = []
            return done
        }

        private mutating func beforeInline() {
            if breaks >= 2 {
                flush()
            } else if breaks == 1 {
                buffer += " "
            }
            breaks = 0
        }

        private mutating func flush() {
            let normalised = BlockWalker.normalise(buffer)
            if !normalised.isEmpty {
                chunks.append(Chunk(text: normalised, linkChars: linkBuffer))
            }
            buffer = ""
            linkBuffer = 0
        }
    }

    static func inlineChunks(of element: Element) -> [Chunk] {
        var run = InlineRun()
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                run.add(textNode.text())
            } else if let child = node as? Element {
                run.add(inline: child)
            }
        }
        return run.drain()
    }

    /// Inline tags never end a paragraph, even where their text is long.
    static let inlineTags: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "dfn", "em",
        "font", "i", "kbd", "mark", "q", "rp", "rt", "ruby", "s", "samp",
        "small", "span", "strong", "sub", "sup", "time", "u", "var", "wbr",
    ]

    /// A child that ends the current inline run. An unknown wrapper counts as a
    /// block when it contains block-level content, so `<center>` around a table
    /// still recurses.
    static func isBlockPosition(_ element: Element) -> Bool {
        let tag = element.tagNameNormal()
        if tag == "img" || tag == "wbr" || tag == "br" { return false }
        if inlineTags.contains(tag) {
            let nested = (try? element.select(blockDescendantQuery)) ?? Elements()
            return !nested.isEmpty()
        }
        return true
    }

    func classes(of element: Element) -> [String] {
        Array((try? element.classNames()) ?? OrderedSet<String>())
    }

    func role(of element: Element) -> String? {
        guard element.hasAttr("role") else { return nil }
        let value = (try? element.attr("role")) ?? ""
        return value.isEmpty ? nil : value
    }

    static func normalise(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func lines(_ rawText: String) -> [String] {
        rawText.components(separatedBy: "\n")
            .map { normalise($0) }
            .filter { !$0.isEmpty }
    }
}
