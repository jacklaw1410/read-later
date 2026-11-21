import ReadLaterCore
import ReadLaterUI
import XCTest

@MainActor
final class FakeLibraryProvider: LibraryProvider {
    var rows: [LibraryRow] = []
    var message: String?
    var openResult = true
    private(set) var openedRows: [LibraryRow] = []

    func open(_ row: LibraryRow) async -> Bool {
        openedRows.append(row)
        return openResult
    }

    func setSaved(_ row: LibraryRow, saved: Bool) {}
    func refresh(_ row: LibraryRow) {}
    func forget(_ row: LibraryRow) {}
}

@MainActor
final class LibraryOpenerTests: XCTestCase {
    private let row = LibraryRow(
        contentHash: "hash-1", title: "Essay", wordIndex: 4, totalWords: 100,
        finished: false, saved: false)

    func testSuccessfulOpenClosesSheet() async {
        let provider = FakeLibraryProvider()
        provider.openResult = true
        var closes = 0

        await LibraryOpener(provider: provider, onOpened: { closes += 1 }).open(row)

        XCTAssertEqual(provider.openedRows, [row])
        XCTAssertEqual(closes, 1)
    }

    func testFailedOpenKeepsSheetUp() async {
        let provider = FakeLibraryProvider()
        provider.openResult = false
        var closes = 0

        await LibraryOpener(provider: provider, onOpened: { closes += 1 }).open(row)

        XCTAssertEqual(provider.openedRows, [row])
        XCTAssertEqual(closes, 0)
    }
}
