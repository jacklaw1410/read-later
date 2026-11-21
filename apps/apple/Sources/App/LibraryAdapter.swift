import ReadLaterCore
import ReadLaterStore
import ReadLaterUI

/// Feeds `LibraryView` from the app model. An action maps its row back to the
/// store position with the same content hash, so it reaches the article shown.
@MainActor
final class LibraryAdapter: LibraryProvider {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var rows: [LibraryRow] {
        model.library.map { position in
            LibraryRow(
                contentHash: position.contentHash,
                title: position.title,
                wordIndex: position.wordIndex,
                totalWords: position.totalWords,
                finished: position.finished,
                saved: position.saved
            )
        }
    }

    var message: String? { model.libraryMessage }

    func open(_ row: LibraryRow) async -> Bool {
        guard let position = storedPosition(for: row) else { return false }
        return await model.openFromLibrary(position)
    }

    func setSaved(_ row: LibraryRow, saved: Bool) {
        guard let position = storedPosition(for: row) else { return }
        model.setSaved(position, saved: saved)
    }

    func refresh(_ row: LibraryRow) {
        guard let position = storedPosition(for: row) else { return }
        model.cacheBust(position)
    }

    func forget(_ row: LibraryRow) {
        guard let position = storedPosition(for: row) else { return }
        model.forget(position)
    }

    private func storedPosition(for row: LibraryRow) -> ReadingPosition? {
        model.library.first { $0.contentHash == row.contentHash }
    }
}
