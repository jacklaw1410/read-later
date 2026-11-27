import Foundation
import ReadLaterCore

/// Where an Entry request came from. The raw value is the `source` field on
/// Reader Telemetry; only these five values can be recorded.
public enum EntrySource: String, Sendable {
    /// A link typed into the field.
    case link
    /// A link put into the field by the clipboard button.
    case clipboard
    /// Article text entered in text mode.
    case rawText
    /// The bundled demo article.
    case sample
    /// A saved place opened from the Library.
    case library
}

/// What the entry screen accepts. The screen picks one case from its
/// segmented control, so one open never reads both fields.
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
        telemetry: TelemetryHub,
        fetcher: PageFetching? = nil,
        extractor: Extractor = SwiftSoupExtractor()
    ) async -> Result<Document, IngressError> {
        switch input {
        case .text(let text):
            return pasted(text, telemetry: telemetry)
        case .link(let raw):
            guard let url = linkURL(from: raw) else {
                return .failure(raw.isEmpty ? .empty : .badLink)
            }
            switch await fetch(url.absoluteString, telemetry: telemetry, fetcher: fetcher) {
            case .failure(let error):
                return .failure(error)
            case .success(let page):
                return read(page, telemetry: telemetry, original: url, extractor: extractor)
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
        telemetry: TelemetryHub,
        fetcher: PageFetching? = nil
    ) async -> Result<FetchedPage, IngressError> {
        guard let url = linkURL(from: raw) else {
            return .failure(raw.isEmpty ? .empty : .badLink)
        }
        guard url.scheme?.lowercased() == "https" else {
            return .failure(.notHTTPS)
        }
        let fetcher = fetcher ?? URLSessionPageFetcher(telemetry: telemetry)
        do {
            return .success(try await fetcher.fetch(url))
        } catch let error as PageFetchError {
            switch error {
            case .notHTTP:
                return .failure(.notHTTPS)
            case .tooLarge(let bytes):
                telemetry.record(TelemetryName.fetchFailed, fields: ["kind": "tooLarge", "bytes": String(bytes)])
                return .failure(.failed)
            case .notText:
                telemetry.record(TelemetryName.fetchFailed, fields: ["kind": "notText"])
                return .failure(.failed)
            case .offline:
                telemetry.record(TelemetryName.fetchFailed, fields: ["kind": "offline"])
                return .failure(.offline(""))
            }
        } catch {
            telemetry.record(TelemetryName.fetchFailed, fields: ["kind": "offline"])
            return .failure(.offline(""))
        }
    }

    /// Extracts one fetched page. The saved URL is the one that answered, so a
    /// redirect to a canonical address is recorded, not the link that was typed.
    /// It is normalized on the way in (research `spec/library-identity.md` §2).
    /// `original` is the link as pasted, kept alongside for refetch (§2);
    /// nil for callers that never saw the pasted string.
    /// Which pasted link a refetch carries. The request URL when it is not
    /// the canonical one (the pasted short link), else nil: the canonical
    /// retry must not re-stamp the dead link it just rescued, and a plain
    /// canonical open carries nothing to keep. Compared normalized with
    /// the query significant: scheme/host case, default port, fragment
    /// and `%XX` case never count as different, but any query difference
    /// does — stripping a tracking key can fetch a different resource
    /// (§2), so the pasted variant is always kept.
    public static func originalForRefetch(request: URL, canonical: URL?) -> URL? {
        guard let canonical else { return request }
        guard let req = normalizedForRefetch(request), let can = normalizedForRefetch(canonical)
        else { return request }
        return req == can ? nil : request
    }

    /// Normalizes for the refetch comparison only. Lowercases scheme and
    /// host, drops the default port and the fragment (both already
    /// dropped in the canonical identity), and runs the shared encoding
    /// normalizer so `%7E` vs `~` and `%2b` vs `%2B` never count as
    /// different. The query stays untouched and significant.
    private static func normalizedForRefetch(_ url: URL) -> URLComponents? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80)
            || (parts.scheme == "https" && parts.port == 443)
        {
            parts.port = nil
        }
        parts.fragment = nil
        if let path = parts.percentEncodedPath.isEmpty ? nil : parts.percentEncodedPath {
            parts.percentEncodedPath = CanonicalURL.normalizeEncoding(path)
        }
        if let query = parts.percentEncodedQuery {
            parts.percentEncodedQuery = CanonicalURL.normalizeEncoding(query)
        }
        return parts
    }
    public static func read(
        _ page: FetchedPage,
        telemetry: TelemetryHub,
        original: URL? = nil,
        extractor: Extractor = SwiftSoupExtractor()
    ) -> Result<Document, IngressError> {
        telemetry.record(TelemetryName.extractStart, fields: ["bytes": String(page.html.count)])
        do {
            let result = try extractor.extract(html: page.html, source: page.url.absoluteString, httpStatus: page.status)
            telemetry.record(TelemetryName.parsed, fields: ["blocks": String(result.blocks.count)])
            let plan = SpokenPlanBuilder.build(
                blocks: result.blocks,
                source: page.url.host ?? page.url.absoluteString,
                sourceSHA256: sha256(page.html)
            )
            guard !plan.blocks.isEmpty else { return .failure(.failed) }
            telemetry.record(TelemetryName.planReady, fields: [
                "sentences": String(plan.sentenceCount),
                "words": String(plan.spokenWords),
            ])
            return .success(Document(
                url: CanonicalURL.canonicalize(page.url),
                originalURL: original,
                title: title(for: result, page: page),
                plan: plan
            ))
        } catch let error as ExtractionError {
            switch error {
            case .walled:
                telemetry.record(TelemetryName.extractFailed, fields: ["kind": "walled"])
                return .failure(.walled)
            case .unrendered:
                telemetry.record(TelemetryName.extractFailed, fields: ["kind": "unrendered"])
                return .failure(.unrendered)
            case .notAnArticle:
                telemetry.record(TelemetryName.extractFailed, fields: ["kind": "notAnArticle"])
                return .failure(.notAnArticle)
            case .emptyDocument, .badURL:
                telemetry.record(TelemetryName.extractFailed, fields: ["kind": "failed"])
                return .failure(.failed)
            }
        } catch {
            telemetry.record(TelemetryName.extractFailed, fields: ["kind": "failed"])
            return .failure(.failed)
        }
    }

    /// Pasted text needs no page and no plan call beyond the paragraph split.
    public static func pasted(_ text: String, telemetry: TelemetryHub) -> Result<Document, IngressError> {
        guard let document = PasteLoader.document(from: text, title: nil) else {
            return .failure(.empty)
        }
        telemetry.record(TelemetryName.planReady, fields: [
            "source": EntrySource.rawText.rawValue,
            "words": String(document.plan.spokenWords),
        ])
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
