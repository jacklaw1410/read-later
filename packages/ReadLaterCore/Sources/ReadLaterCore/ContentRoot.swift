import Foundation
import SwiftSoup

/// Picks the article body out of a page, so the block walk sees the article
/// and not the page around it.
///
/// The scoring is a port of Mozilla's Readability (`_grabArticle`), commit for
/// version 0.6.0. The upstream file is kept at `vendor/readability/Readability.js`
/// with its sha256, so a reader can compare a constant against its source.
/// Swift has no DOM, and Readability.js needs one, so the JS cannot run here:
/// the constants and the shape of the scoring are copied, and the DOM work is
/// done with SwiftSoup.
///
/// What is copied:
///
/// - a text score of `1 + commas + min(chars / 100, 3)`, added to the parent
///   and half of it to the grandparent;
/// - a class and id weight of +25 for a content word and -25 for a chrome word;
/// - the climb to a parent while its score is above a third of the best score;
/// - sibling inclusion at a fifth of the best score, plus long low-link
///   paragraphs.
///
/// What is not copied: Readability's DOM rewriting (it builds a new article
/// element), its image cleaning, and its retry passes. This code selects roots
/// only. The block walker still owns what becomes a block.
public enum ContentRoot {
    /// Class and id words that mark chrome. From `unlikelyCandidates` and
    /// `negativeRe` in the upstream file.
    static let chromeWords: [String] = [
        "combx", "comment", "community", "disqus", "extra", "footer", "foot",
        "gdpr", "header", "legends", "menu", "related", "remark", "replies",
        "rss", "shoutbox", "sidebar", "skyscraper", "social", "sponsor",
        "supplemental", "ad-break", "agegate", "pagination", "pager", "popup",
        "banner", "breadcrumb", "masthead", "nav", "share", "shopping", "tags",
        "tool", "widget", "promo", "outbrain", "hidden",
    ]

    /// Class and id words that mark content. From `positiveRe` upstream.
    static let contentWords: [String] = [
        "article", "body", "content", "entry", "main", "page", "post",
        "text", "blog", "story",
    ]

    /// Tag names Readability never scores. It removes them before scoring.
    static let skipTags: Set<String> = [
        "html", "body", "head", "title", "script", "style", "link", "meta",
        "nav", "aside", "footer", "header", "form", "iframe", "svg", "button",
        "input", "select", "textarea",
    ]

    /// Returns the roots to walk, in document order.
    ///
    /// Usually one element. When the article is split across siblings, several.
    /// Falls back to the whole body when nothing scores, because losing the page
    /// is worse than reading some chrome.
    public static func roots(in body: Element) -> [Element] {
        var scores: [ObjectIdentifier: Double] = [:]
        var elements: [ObjectIdentifier: Element] = [:]

        func addScore(_ element: Element, _ score: Double) throws {
            // Only content inside the body is a root candidate. Scored text that
            // sits above the body would let the climb leave the body and walk
            // `<head>`, which put the page title in as a prose block.
            if element === body || skipTags.contains(element.tagNameNormal()) { return }
            let key = ObjectIdentifier(element)
            let weight = classWeight(of: element)
            if scores[key] == nil {
                scores[key] = weight
                elements[key] = element
            }
            scores[key]! += score
        }

        let scored = (try? body.select("p, td, pre, div, section, article, blockquote")) ?? Elements()
        for node in scored {
            let tag = node.tagNameNormal()
            if skipTags.contains(tag) { continue }
            if isUnlikely(node) { continue }
            let text = normalise((try? node.text()) ?? "")
            let chars = text.count
            if chars < 25 { continue }
            let commas = text.filter { $0 == "," || $0 == "，" || $0 == "。" }.count
            let score = 1.0 + Double(commas) + Double(min(chars / 100, 3))
            try? addScore(node, score)
            if let parent = node.parent() { try? addScore(parent, score) }
            if let grandparent = node.parent()?.parent() { try? addScore(grandparent, score / 2) }
        }

        guard let best = scores.max(by: { $0.value < $1.value }),
              best.value > 0,
              var top = elements[best.key]
        else {
            return [body]
        }

        // Climb while the parent keeps most of the score: a wrapper div that
        // holds the article is a better root than the first paragraph's parent.
        var topScore = best.value
        let threshold = topScore / 3
        while let parent = top.parent(), parent != body, let parentScore = scores[ObjectIdentifier(parent)] {
            if parentScore < threshold { break }
            if parentScore > topScore {
                top = parent
                topScore = parentScore
                break
            }
            top = parent
            topScore = parentScore
        }

        var roots = [top]
        if let siblings = top.parent()?.children().array() {
            for sibling in siblings where sibling != top {
                if skipTags.contains(sibling.tagNameNormal()) { continue }
                if isUnlikely(sibling) { continue }
                let tag = sibling.tagNameNormal()
                // F19 1.9: headings speak, so a heading beside the article
                // root is a landmark, not chrome. Short text is expected;
                // the unlikely filter above still drops rail headings.
                if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
                    if !normalise((try? sibling.text()) ?? "").isEmpty {
                        roots.append(sibling)
                    }
                    continue
                }
                // F19 1.13: a list beside the article root is content, not
                // chrome. Link-dense menu lists stay out via the density
                // check; the unlikely filter above already drops classed rails.
                if ["ul", "ol", "dl"].contains(tag) {
                    let text = normalise((try? sibling.text()) ?? "")
                    let items = ((try? sibling.select("li, dt, dd")) ?? Elements())
                        .array()
                        .filter {
                            !normalise((try? $0.text()) ?? "").isEmpty
                        }
                        .count
                    if (items >= 2 || text.count >= 40) && linkDensity(of: sibling) < 0.5 {
                        roots.append(sibling)
                    }
                    continue
                }
                let siblingScore = scores[ObjectIdentifier(sibling)] ?? 0
                if siblingScore >= topScore * 0.2 {
                    roots.append(sibling)
                    continue
                }
                if sibling.tagNameNormal() == "p" {
                    let text = normalise((try? sibling.text()) ?? "")
                    if text.count > 80 && linkDensity(of: sibling) < 0.25 && endsSentence(text) {
                        roots.append(sibling)
                    }
                }
            }
            // Siblings iterate in document order but `top` was prepended, so
            // a heading before the first paragraph would read after it.
            // Restore document order: the wash and the voice follow this list.
            let order = siblings.map { ObjectIdentifier($0) }
            roots.sort {
                (order.firstIndex(of: ObjectIdentifier($0)) ?? 0)
                    < (order.firstIndex(of: ObjectIdentifier($1)) ?? 0)
            }
        }
        return roots
    }

    static func classWeight(of element: Element) -> Double {
        let signature = ["class", "id"].compactMap { try? element.attr($0) }.joined(separator: " ").lowercased()
        if signature.isEmpty { return 0 }
        var weight = 0.0
        for word in contentWords where signature.contains(word) { weight += 25 }
        for word in chromeWords where signature.contains(word) { weight -= 25 }
        return weight
    }

    /// A node whose class, id or attributes say it is not the article.
    static func isUnlikely(_ element: Element) -> Bool {
        let tag = element.tagNameNormal()
        if skipTags.contains(tag) { return true }
        if element.hasAttr("hidden") || element.hasAttr("aria-hidden") { return true }
        if let role = try? element.attr("role") {
            let lowered = role.lowercased()
            if lowered == "navigation" || lowered == "banner" || lowered == "complementary" { return true }
        }
        let signature = (["class", "id"].compactMap { try? element.attr($0) }.joined(separator: " ")).lowercased()
        guard !signature.isEmpty else { return false }
        return chromeWords.contains { signature.contains($0) }
    }

    static func linkDensity(of element: Element) -> Double {
        let text = normalise((try? element.text()) ?? "")
        guard !text.isEmpty else { return 0 }
        let links = (try? element.select("a")) ?? Elements()
        var linked = 0
        for link in links { linked += ((try? link.text()) ?? "").count }
        return Double(linked) / Double(text.count)
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "!" || last == "?" || last == ":" || last == "…"
    }

    static func normalise(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
