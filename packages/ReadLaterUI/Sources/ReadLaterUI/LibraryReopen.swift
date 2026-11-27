import Foundation
import ReadLaterCore

/// Rebuilds a stored plan when the parser build changed.
///
/// A library reopen normally hands the stored `Document` straight to the
/// reader: no fetch, no extraction, no page hash. Only a plan written by an
/// older parser takes this path, and it reads the saved page bytes rather
/// than the network. The stored plan is returned unchanged when the parser is
/// current, when the page is missing, when extraction fails, or when the
/// saved bytes do not match the plan's source hash. A caller cannot therefore
/// lose the old plan before a new one validates.
public enum LibraryReopen {
    public static func document(
        _ stored: Document,
        page: FetchedPage?,
        telemetry: TelemetryHub,
        extractor: Extractor = SwiftSoupExtractor()
    ) -> Document {
        guard stored.plan.extractorVersion < BlockPlan.currentExtractorVersion else {
            return stored
        }
        guard let page else { return stored }
        guard case .success(let fresh) = ArticleIngress.read(
            page, telemetry: telemetry, original: stored.originalURL, extractor: extractor
        ) else {
            return stored
        }
        // The saved page must be the page the plan was built from. A page
        // saved under another hash (stale cache, hand-edited row) cannot
        // replace the plan the reader already trusts.
        guard !stored.plan.sourceSHA256.isEmpty,
              fresh.plan.sourceSHA256 == stored.plan.sourceSHA256
        else {
            return stored
        }
        return Document(
            id: stored.id,
            url: stored.url,
            originalURL: stored.originalURL,
            title: fresh.title,
            plan: fresh.plan,
            addedAt: stored.addedAt
        )
    }
}
