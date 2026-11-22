import Foundation
import ReadLaterCore

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
    private let telemetry: TelemetryHub

    public init(
        telemetry: TelemetryHub,
        maximumBytes: Int = 8 << 20,
        timeout: TimeInterval = 20,
        session: URLSession = .shared
    ) {
        self.telemetry = telemetry
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

        telemetry.record(TelemetryName.fetchStart, fields: ["host": url.host ?? url.absoluteString])
        let (data, http): (Data, HTTPURLResponse)
        do {
            (data, http) = try await perform(request, url: url)
        } catch let error as PageFetchError {
            throw error
        } catch {
            throw PageFetchError.offline((error as NSError).localizedDescription)
        }
        telemetry.record(TelemetryName.bodyDone, fields: [
            "status": String(http.statusCode),
            "bytes": String(data.count),
        ])
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

    /// Runs the request on a per-fetch session so a delegate can stamp the
    /// header arrival (T2). The stored session's configuration is reused, so a
    /// custom configuration still applies; the delegate cannot live on a
    /// shared session.
    private func perform(_ request: URLRequest, url: URL) async throws -> (Data, HTTPURLResponse) {
        let delegate = FetchTimingDelegate(maximumBytes: maximumBytes, url: url, telemetry: telemetry)
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let taskSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { taskSession.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.begin(taskSession: taskSession, request: request, continuation: continuation)
        }
    }
}

/// Stamps T2 when the response headers arrive and accumulates the body.
/// One instance per fetch; all mutable state is lock-guarded because the
/// callbacks arrive off the caller's actor.
private final class FetchTimingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let url: URL
    private let telemetry: TelemetryHub
    private var received = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var done = false

    init(maximumBytes: Int, url: URL, telemetry: TelemetryHub) {
        self.maximumBytes = maximumBytes
        self.url = url
        self.telemetry = telemetry
    }

    func begin(
        taskSession: URLSession, request: URLRequest,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        lock.withLock { self.continuation = continuation }
        let dataTask = taskSession.dataTask(with: request)
        lock.withLock { task = dataTask }
        dataTask.resume()
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
            guard !done else { return nil }
            done = true
            let cont = continuation
            continuation = nil
            return cont
        }
        switch result {
        case .success(let value): cont?.resume(returning: value)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(PageFetchError.offline("no HTTP response")))
            return
        }
        telemetry.record(TelemetryName.headers, fields: [
            "status": String(http.statusCode),
            "host": url.host ?? url.absoluteString,
        ])
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Int? in
            received.append(data)
            return received.count > maximumBytes ? received.count : nil
        }
        if let count = overflow {
            task?.cancel()
            finish(.failure(PageFetchError.tooLarge(count)))
        }
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            finish(.failure(PageFetchError.offline((error as NSError).localizedDescription)))
            return
        }
        let (body, http) = lock.withLock { (received, response) }
        guard let http else {
            finish(.failure(PageFetchError.offline("no HTTP response")))
            return
        }
        finish(.success((body, http)))
    }
}
