import Foundation
import ReadLaterCore

/// What the entry screen accepts. Raw text wins over a link, because a reader
/// who pastes text has already decided that the link does not work.
public enum IngressInput: Equatable, Sendable {
    case link(String)
    case text(String)
}

/// Why an ingress stopped, in the terms the entry screen shows.
public enum IngressError: Error, Equatable, Sendable {
    case empty
    case badLink
    case notHTTPS
    case walled
    case unrendered
    case notAnArticle
    case failed
    case offline(String)

    /// The line under the progress rule. No line tells the reader to do
    /// something the screen cannot do.
    public var message: String {
        switch self {
        case .empty: return "nothing to open — paste a link or text"
        case .badLink: return "that is not a link — check the address"
        case .notHTTPS: return "https links only"
        case .walled: return "login wall — paste text instead"
        case .unrendered: return "this page needs JavaScript — paste text instead"
        case .notAnArticle: return "not an article — this looks like an index or an app screen"
        case .failed: return "could not read this page — paste text instead"
        case .offline: return "no connection — check the network, or paste text"
        }
    }

    /// True when the page answered but the answer is a wall. The entry screen
    /// keeps the URL in the field so the reader can paste text instead.
    public var isWall: Bool {
        if case .walled = self { return true }
        return false
    }
}

/// Turns a link or pasted text into a document, or into the reason it stopped.
///
/// The order is the entry screen's order: fetch, then extract, then build the
/// spoken plan. Raw text skips the fetch.
public enum ArticleIngress {
    /// The whole path, for a caller that does not show progress.
    public static func document(
        from input: IngressInput,
        fetcher: PageFetching = URLSessionPageFetcher(),
        extractor: Extractor = SwiftSoupExtractor()
    ) async -> Result<Document, IngressError> {
        switch input {
        case .text(let text):
            return pasted(text)
        case .link(let raw):
            guard let url = linkURL(from: raw) else {
                return .failure(raw.isEmpty ? .empty : .badLink)
            }
            switch await fetch(url.absoluteString, fetcher: fetcher) {
            case .failure(let error):
                return .failure(error)
            case .success(let page):
                return read(page, extractor: extractor)
            }
        }
    }

    /// The URL a link field holds, or nil when the field is not a link.
    public static func linkURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    /// Fetches a link. HTTP is refused before the request: App Transport
    /// Security blocks it, and a clear refusal costs less than a silent stall.
    public static func fetch(
        _ raw: String,
        fetcher: PageFetching = URLSessionPageFetcher()
    ) async -> Result<FetchedPage, IngressError> {
        guard let url = linkURL(from: raw) else {
            return .failure(raw.isEmpty ? .empty : .badLink)
        }
        guard url.scheme?.lowercased() == "https" else {
            return .failure(.notHTTPS)
        }
        do {
            return .success(try await fetcher.fetch(url))
        } catch let error as PageFetchError {
            switch error {
            case .notHTTP:
                return .failure(.notHTTPS)
            case .tooLarge:
                return .failure(.failed)
            case .notText:
                return .failure(.failed)
            case .offline:
                return .failure(.offline(""))
            }
        } catch {
            return .failure(.offline(""))
        }
    }

    /// Extracts one fetched page. The saved URL is the one that answered, so a
    /// redirect to a canonical address is recorded, not the link that was typed.
    public static func read(
        _ page: FetchedPage,
        extractor: Extractor = SwiftSoupExtractor()
    ) -> Result<Document, IngressError> {
        do {
            let result = try extractor.extract(html: page.html, source: page.url.absoluteString, httpStatus: page.status)
            let plan = SpokenPlanBuilder.build(
                blocks: result.blocks,
                source: page.url.host ?? page.url.absoluteString,
                sourceSHA256: sha256(page.html)
            )
            guard !plan.blocks.isEmpty else { return .failure(.failed) }
            return .success(Document(
                url: page.url,
                title: title(for: result, page: page),
                plan: plan
            ))
        } catch let error as ExtractionError {
            switch error {
            case .walled:
                return .failure(.walled)
            case .unrendered:
                return .failure(.unrendered)
            case .notAnArticle:
                return .failure(.notAnArticle)
            case .emptyDocument, .badURL:
                return .failure(.failed)
            }
        } catch {
            return .failure(.failed)
        }
    }

    /// Pasted text needs no page and no plan call beyond the paragraph split.
    public static func pasted(_ text: String) -> Result<Document, IngressError> {
        guard let document = PasteLoader.document(from: text, title: nil) else {
            return .failure(.empty)
        }
        return .success(document)
    }

    static func title(for result: ExtractionResult, page: FetchedPage) -> String {
        if !result.title.isEmpty { return result.title }
        let host = page.url.host ?? ""
        return host.isEmpty ? "Untitled" : host
    }

    static func sha256(_ text: String) -> String {
        PasteLoader.sha256(text)
    }
}
