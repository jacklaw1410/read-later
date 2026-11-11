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
        let linkElements = (try? body.select("a")) ?? Elements()
        var linkCount = 0
        var linkChars = 0
        for link in linkElements {
            linkCount += 1
            linkChars += ((try? link.text()) ?? "").count
        }
        let paragraphs = ((try? body.select("p")) ?? Elements()).array()
            .filter { (((try? $0.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).count > 0 }
            .count

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
        if bodyChars < 200 && (html.count >= 8000 || Self.containsSPAMarker(lowered)) {
            throw ExtractionError.unrendered(
                reason: "js-shell: body \(bodyChars) chars, html \(html.count) chars"
            )
        }
        guard !bodyText.isEmpty else {
            throw ExtractionError.emptyDocument
        }
        let linkDensity = Double(linkChars) / Double(max(bodyChars, 1))
        // The index rule needs a short page. A 4,000-word article with fifteen links in it
        // is an article, and calling it an index loses the page for no gain.
        if (linkCount >= 15 && paragraphs <= 3 && bodyWords < 600)
            || (paragraphs == 0 && bodyWords < 100)
            || (bodyWords < 40 && linkDensity >= 0.5)
        {
            throw ExtractionError.notAnArticle(
                reason: "index: \(linkCount) links, \(paragraphs) paragraphs, \(bodyWords) words"
            )
        }
        guard bodyWords >= 20 else {
            throw ExtractionError.emptyDocument
        }

        var walker = BlockWalker()
        try walker.run(body)
        var blocks = walker.blocks
        if blocks.isEmpty {
            let verdict = Classifier.classify(
                tag: "body", classNames: [], role: nil,
                text: bodyText, linkTextChars: linkChars
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
            reason: "usable: \(blocks.count) blocks from \(source)"
        )
    }

    // MARK: - Gate markers

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
    ]
    static let blockDescendantQuery = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote",
        "ul", "ol", "dl", "table", "figure", "figcaption", "aside", "nav",
        "div", "section", "article", "main", "li", "header", "footer", "code",
    ].joined(separator: ", ")

    mutating func run(_ body: Element) throws {
        for child in body.children() {
            try process(child)
        }
        let own = Self.normalise(body.ownText())
        if !own.isEmpty {
            emit(Classifier.classify(tag: "body", text: own), text: own)
        }
    }

    mutating func process(_ element: Element) throws {
        let tag = element.tagNameNormal()
        if Self.containerTags.contains(tag) {
            try processContainer(element, tag: tag)
        } else if Self.leafTags.contains(tag) {
            try processLeaf(element, tag: tag)
        } else {
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

    mutating func processContainer(_ element: Element, tag: String) throws {
        let descendants = (try? element.select(Self.blockDescendantQuery)) ?? Elements()
        if descendants.isEmpty() {
            // No block-level descendants: the container is all prose-shaped
            // text (plus inline markup). One block, nothing lost.
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
            return
        }
        for child in element.children() {
            try process(child)
        }
        let own = Self.normalise(element.ownText())
        if !own.isEmpty {
            emit(
                Classifier.classify(
                    tag: tag,
                    classNames: classes(of: element),
                    role: role(of: element),
                    text: own,
                    lines: Self.lines(element.ownText())
                ),
                text: own
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
