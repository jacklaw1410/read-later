import Foundation
import ReadLaterCore

/// The ingest boundary: one fetched page in, one `Document` out.
///
/// The whole CPU path runs on a background task, never on the caller's
/// executor: extraction, the spoken-plan build, the plan invariant, the page
/// hash and the character count. The caller awaits one finished value, so
/// Entry keeps painting its Loadline while the page is prepared.
///
/// No UI state and no store call lives here. Telemetry is the process hub,
/// not a view model. Its event order is unchanged: extract start, parsed,
/// plan ready.
public enum Ingest {
    /// Reads one fetched page off the caller's executor. `original` is the
    /// link as pasted, kept beside the canonical URL for a refetch (§2 of
    /// research `spec/library-identity.md`); nil when the caller never saw it.
    public static func document(
        from page: FetchedPage,
        original: URL? = nil,
        telemetry: TelemetryHub,
        extractor: Extractor = SwiftSoupExtractor()
    ) async -> Result<Document, IngressError> {
        await Task.detached(priority: .userInitiated) {
            read(page, original: original, telemetry: telemetry, extractor: extractor)
        }.value
    }

    /// One page, read on the current executor. Only `document(from:)` calls
    /// this, so the public seam stays a single entry point.
    static func read(
        _ page: FetchedPage,
        original: URL?,
        telemetry: TelemetryHub,
        extractor: Extractor
    ) -> Result<Document, IngressError> {
        telemetry.record(TelemetryName.extractStart, fields: ["bytes": String(page.html.count)])
        do {
            let result = try extractor.extract(
                html: page.html,
                source: page.url.absoluteString,
                httpStatus: page.status
            )
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

    /// The page title, or the host when the page has none.
    static func title(for result: ExtractionResult, page: FetchedPage) -> String {
        if !result.title.isEmpty { return result.title }
        let host = page.url.host ?? ""
        return host.isEmpty ? "Untitled" : host
    }

    static func sha256(_ text: String) -> String {
        PasteLoader.sha256(text)
    }
}
