import Foundation

/// One fetched page: the bytes the extractor reads, the status that decides a
/// wall, and the URL that answered after redirects.
public struct FetchedPage: Sendable, Equatable {
    public var html: String
    public var status: Int
    public var url: URL

    public init(html: String, status: Int, url: URL) {
        self.html = html
        self.status = status
        self.url = url
    }
}

/// What can stop a fetch. A page that answers `403` is not an error here: the
/// extractor needs the status to call it a wall, so the status travels with the
/// body and only the transport fails.
public enum PageFetchError: Error, Equatable, Sendable {
    case notHTTP
    case tooLarge(Int)
    case notText(String)
    case offline(String)
}

public protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

/// The app's only network call in the MVP: one page, over HTTPS, with a size
/// cap and a timeout. No cookies are kept between loads, and no account exists.
public struct URLSessionPageFetcher: PageFetching {
    public var maximumBytes: Int
    public var timeout: TimeInterval
    private let session: URLSession

    public init(maximumBytes: Int = 8 << 20, timeout: TimeInterval = 20, session: URLSession = .shared) {
        self.maximumBytes = maximumBytes
        self.timeout = timeout
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> FetchedPage {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw PageFetchError.notHTTP
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Publishers answer a request from a real reader. A bare URLSession
        // agent gets a bot page from some of them, and a bot page is a wall.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15 ReadLater/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8,*/*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("en,zh-HK;q=0.8", forHTTPHeaderField: "Accept-Language")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PageFetchError.offline((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PageFetchError.offline("no HTTP response")
        }
        if data.count > maximumBytes {
            throw PageFetchError.tooLarge(data.count)
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !type.isEmpty, !type.contains("text/"), !type.contains("html"), !type.contains("xml") {
            throw PageFetchError.notText(type)
        }
        // Latin-1 and GB18030 pages exist, and UTF-8 decoding of them gives
        // replacement characters that read as no prose. The fallbacks keep the
        // text that a browser would show.
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return FetchedPage(html: html, status: http.statusCode, url: http.url ?? url)
    }
}
