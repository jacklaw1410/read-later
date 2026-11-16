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

    /// Enqueues one place write. Never blocks the caller.
    public func record(document: Document, wordIndex: Int, source: String) {
        queue.async { [store] in
            try? store.recordPosition(of: document, wordIndex: wordIndex, source: source)
        }
    }

    /// Waits until every enqueued write finished. The writes still run on
    /// the queue, so their thread tag stays off-main.
    public func wait() {
        queue.sync {}
    }
}
