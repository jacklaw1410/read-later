import Foundation
import ReadLaterCore
import Testing

@testable import ReadLaterUI

private struct StubFetcher: PageFetching {
    var result: Result<FetchedPage, PageFetchError>

    func fetch(_ url: URL) async throws -> FetchedPage {
        try result.get()
    }
}

private func page(_ body: String, status: Int = 200, title: String = "A Test Article") -> FetchedPage {
    let html = """
    <html><head><title>\(title)</title></head><body>\(body)</body></html>
    """
    return FetchedPage(html: html, status: status, url: URL(string: "https://example.com/article")!)
}

private func prose(_ subject: String) -> String {
    "<p>\(subject) is a sentence with commas, clauses, and enough words for the extractor "
        + "to read it as prose. It continues for a second sentence so the paragraph is long.</p>"
}

@Test func pastedTextBecomesADocument() throws {
    let text = "First paragraph.\n\nSecond paragraph."
    let result = ArticleIngress.pasted(text, telemetry: TelemetryHub())
    let document = try result.get()
    #expect(document.plan.blocks.count == 2)
    #expect(document.title == "First paragraph. Second paragraph.")
    #expect(document.url == nil)
}

@Test func emptyTextIsRefusedWithThePromptToPaste() {
    let result = ArticleIngress.pasted("   \n\n  ", telemetry: TelemetryHub())
    #expect(result == .failure(.empty))
    #expect(IngressError.empty.message == "nothing to open — paste a link or text")
}

@Test func aFieldThatIsNotALinkIsRefused() async {
    let result = await ArticleIngress.document(from: .link("just some words"), telemetry: TelemetryHub())
    #expect(result == .failure(.badLink))
}

@Test func httpIsRefusedBeforeTheRequest() async {
    let result = await ArticleIngress.document(from: .link("http://example.com/x"), telemetry: TelemetryHub())
    #expect(result == .failure(.notHTTPS))
    #expect(IngressError.notHTTPS.message == "https links only")
}

@Test func aWallIsNamedAsAWall() async {
    let fetcher = StubFetcher(result: .success(page("<p>Subscribe to continue</p>", status: 403)))
    let result = await ArticleIngress.document(from: .link("https://example.com/a"), telemetry: TelemetryHub(), fetcher: fetcher)
    #expect(result == .failure(.walled))
    #expect(IngressError.walled.message == "login wall — paste text instead")
}

@Test func aJavaScriptShellIsNamed() async {
    let body = "<div id=\"root\"></div><script src=\"/app.js\"></script>"
    let fetcher = StubFetcher(result: .success(page(body)))
    let result = await ArticleIngress.document(from: .link("https://example.com/a"), telemetry: TelemetryHub(), fetcher: fetcher)
    #expect(result == .failure(.unrendered))
}

@Test func anIndexIsNamed() async {
    let links = (1...20).map { "<a href=\"/p/\($0)\">Post number \($0) is here</a>" }.joined()
    let fetcher = StubFetcher(result: .success(page("<div>\(links)</div>")))
    let result = await ArticleIngress.document(from: .link("https://example.com/a"), telemetry: TelemetryHub(), fetcher: fetcher)
    #expect(result == .failure(.notAnArticle))
}

@Test func aUsablePageKeepsItsTitleAndURL() async throws {
    let body = prose("Alpha") + prose("Beta") + prose("Gamma")
    let fetcher = StubFetcher(result: .success(page(body, title: "The Real Title")))
    let result = await ArticleIngress.document(from: .link("https://example.com/a"), telemetry: TelemetryHub(), fetcher: fetcher)
    let document = try result.get()
    #expect(document.title == "The Real Title")
    #expect(document.url?.absoluteString == "https://example.com/article")
    #expect(document.plan.blocks.count >= 3)
}

@Test func aPageWithNoTitleFallsBackToTheHost() async throws {
    let body = prose("Alpha") + prose("Beta") + prose("Gamma")
    let html = "<html><head></head><body>\(body)</body></html>"
    let fetched = FetchedPage(html: html, status: 200, url: URL(string: "https://example.com/a")!)
    let result = ArticleIngress.read(fetched, telemetry: TelemetryHub())
    let document = try result.get()
    #expect(document.title == "example.com")
}

@Test func aTransportFailureIsNamedAsOffline() async {
    let fetcher = StubFetcher(result: .failure(.offline("The Internet connection appears to be offline.")))
    let result = await ArticleIngress.document(from: .link("https://example.com/a"), telemetry: TelemetryHub(), fetcher: fetcher)
    #expect(result == .failure(.offline("")))
}

@Test func theFetcherRefusesAFileURL() async {
    let fetcher = URLSessionPageFetcher(telemetry: TelemetryHub())
    await #expect(throws: PageFetchError.notHTTP) {
        try await fetcher.fetch(URL(fileURLWithPath: "/tmp/x.html"))
    }
}

@Test func everyRefusalNamesAStepTheReaderCanTake() {
    let errors: [IngressError] = [.empty, .badLink, .notHTTPS, .walled, .unrendered, .notAnArticle, .failed, .offline("")]
    for error in errors {
        #expect(!error.message.isEmpty)
        #expect(!error.message.hasSuffix("."))
    }
}

/// A live check, off by default. Run it with `RLIVE=1 swift test --filter liveFetch`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RLIVE"] != nil))
func liveFetchOfOneArticle() async throws {
    let result = await ArticleIngress.document(
        from: .link("https://en.wikipedia.org/wiki/Bayes%27_theorem"),
        telemetry: TelemetryHub()
    )
    let document = try result.get()
    #expect(document.url?.host == "en.wikipedia.org")
    #expect(!document.title.isEmpty)
    #expect(document.plan.blocks.count > 10)
    #expect(document.plan.spokenWords > 300)
}
