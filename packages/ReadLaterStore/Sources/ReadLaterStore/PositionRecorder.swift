import Foundation
import ReadLaterCore

/// Serial off-main writer for the reading place.
///
/// A `dbQueue.write` called on the main thread blocks it for the write
/// duration (M8). The recorder owns one background queue: `record` returns
/// at once, the write runs there, and `wait` drains the queue for
/// flush, close and background, so no place write is lost.
public final class PositionRecorder: Sendable {
    private let store: Store
    private let queue: DispatchQueue

    public init(store: Store, label: String = "app.readlater.position") {
        self.store = store
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Enqueues one place write. Never blocks the caller: no plan work runs
    /// here — the clamp and the key build on the queue inside `run`, so a
    /// per-tick `SpokenWordNumbering` never runs on the caller thread (M8). A failed
    /// write records its op with the error: ticks otherwise vanish with no
    /// trace and the lost place is undebuggable.
    public func record(document: Document, wordIndex: Int, source: String) {
        run("record.position", fields: {
            let total = SpokenWordNumbering(plan: document.plan).totalWords
            // Clamped like the success row (`recordPosition` logs the
            // clamped word), so error and success rows correlate on one value.
            let clamped = min(max(wordIndex, 0), max(total - 1, 0))
            return [
                "contentHash": Store.resumeKey(for: document),
                "word": String(clamped),
                "source": source,
            ]
        }) { store in
            try store.recordPosition(of: document, wordIndex: wordIndex, source: source)
        }
    }

    /// Enqueues one raw-page write. Same queue as the place, so a flush
    /// before close or backgrounding keeps both. Best-effort: a lost page
    /// only means a future re-plan refetches.
    public func persistRawPage(_ page: RawPage, for document: Document) {
        run("raw_page.save", fields: {
            // Exact compressed length like the success row: queue-side and
            // failure-only, so the zlib cost never touches the happy path.
            // Falls back to the uncompressed length if compression itself
            // threw — the join then misses, but the hash still identifies.
            let bytes: String
            if let compressed = try? (Data(page.html.utf8) as NSData).compressed(using: .zlib) as Data {
                bytes = String(compressed.count)
            } else {
                bytes = String(page.html.utf8.count)
            }
            return ["contentHash": Store.resumeKey(for: document), "bytes": bytes]
        }) { store in
            try store.saveRawPage(page, for: document)
        }
    }

    /// Enqueues the stale-link clear behind every queued tick. FIFO order
    /// is the guarantee: ticks carrying the dead link land first, the
    /// clear lands last, so no drain (`wait`) blocks the caller and no
    /// late tick writes the dead link back. Best-effort like the rest.
    /// One block clears both rows: two separate enqueues could split on a
    /// failure (position cleared, document kept), and the next open would
    /// read the dead link back from the document row into the tick.
    /// A partial failure self-heals: the dead link costs one double fetch
    /// and the next fallback retries the rescue.
    public func clearRescuedLink(contentHash: String, documentID: UUID) {
        run("rescued_link.clear", fields: { ["contentHash": contentHash, "documentID": documentID.uuidString] }) { store in
            try store.clearRescuedLink(contentHash: contentHash, documentID: documentID)
        }
    }

    /// Primitive for tests: clears the position row only. Production must
    /// use `clearRescuedLink` — clearing one row without the other splits
    /// them on failure and the dead link comes back via the next tick.
    public func clearOriginalURL(contentHash: String) {
        run("position.original_url.clear", fields: { ["contentHash": contentHash] }) { store in
            try store.clearOriginalURL(contentHash: contentHash)
        }
    }

    /// Primitive for tests: clears the document row only. Production must
    /// use `clearRescuedLink` (see above).
    public func clearDocumentOriginalURL(documentID: UUID) {
        run("document.original_url.clear", fields: { ["documentID": documentID.uuidString] }) { store in
            try store.clearDocumentOriginalURL(documentID: documentID)
        }
    }

    /// One async hop for every enqueued write: times the attempt and, on
    /// failure, logs the op with the error instead of swallowing it. The op
    /// names match the writes' own `store.write` events; the error row
    /// carries the call-site context plus the same `copyMs`/`encodeMs`
    /// shape (the attempt never split, so both collapse to its duration;
    /// `encodeMs` is `"0.00"` to mark the failure row — dashboards averaging
    /// encode time must filter `error`-carrying rows out). `fields` builds
    /// on the queue and runs only on failure, so a tick's plan encode never
    /// runs on the caller thread (M8) and the happy path pays exactly one
    /// encode inside the write itself; the failure path pays a second one
    /// for the clamped context. Every caller passes explicit fields:
    /// no default, so a future write cannot ship an identity-less error row.
    private func run(
        _ op: String,
        fields: @Sendable @escaping () -> [String: String],
        _ work: @Sendable @escaping (Store) throws -> Void
    ) {
        queue.async { [store] in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try work(store)
            } catch {
                let ms = String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
                var logged = fields()
                logged["op"] = op
                logged["ms"] = ms
                logged["copyMs"] = ms
                logged["encodeMs"] = "0.00"
                logged["main"] = Thread.isMainThread ? "1" : "0"
                logged["error"] = String(describing: error)
                store.telemetry.record(TelemetryName.storeWrite, fields: logged)
            }
        }
    }

    /// Waits until every enqueued write finished. The writes still run on
    /// the queue, so their thread tag stays off-main.
    public func wait() {
        queue.sync {}
    }
}
