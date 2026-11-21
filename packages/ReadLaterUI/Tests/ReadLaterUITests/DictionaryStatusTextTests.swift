import ReadLaterCore
import ReadLaterUI
import XCTest

@MainActor
final class FakeCapabilityPacks: CapabilityPacks {
    var isInstalled = false
    var installedVersion: String?
    var isInstalling = false
    var isPaused = false
    var failure: String?
    var downloadedBytes = 0
    var totalBytes = 0
    var updateVersion: String?
    var updateSizeBytes: Int?
    var offerDeclined = false

    func startInstall() {}
    func cancelInstall() {}
    func install() async {}
    func remove() {}
    func removePartial() {}
    func declineOffer() {}
    func checkForUpdate() async {}
    func lookup(_ word: String) -> LookupResult? { nil }
}

@MainActor
final class DictionaryStatusTextTests: XCTestCase {
    private let mib = 1_048_576

    func testNotInstalled() {
        let status = DictionaryStatusText(packs: FakeCapabilityPacks())

        XCTAssertEqual(status.stateLine, "Not installed.")
        XCTAssertFalse(status.stateIsProblem)
        XCTAssertNil(status.updateLine)
    }

    func testInstalledShowsVersion() {
        let packs = FakeCapabilityPacks()
        packs.isInstalled = true
        packs.installedVersion = "2026.11.01"

        XCTAssertEqual(DictionaryStatusText(packs: packs).stateLine, "Installed · 2026.11.01")
    }

    func testFailureReplacesState() {
        let packs = FakeCapabilityPacks()
        packs.failure = "The dictionary could not be downloaded."

        let status = DictionaryStatusText(packs: packs)
        XCTAssertEqual(status.stateLine, "The dictionary could not be downloaded.")
        XCTAssertTrue(status.stateIsProblem)
    }

    func testPausedKeepsBytes() {
        let packs = FakeCapabilityPacks()
        packs.isPaused = true
        packs.downloadedBytes = 3 * mib

        XCTAssertEqual(DictionaryStatusText(packs: packs).stateLine, "Paused · 3.00 MiB kept")
    }

    func testDownloadingAndProgress() {
        let packs = FakeCapabilityPacks()
        packs.isInstalling = true
        packs.downloadedBytes = 5 * mib / 2
        packs.totalBytes = 10 * mib

        let status = DictionaryStatusText(packs: packs)
        XCTAssertEqual(status.stateLine, "Downloading…")
        XCTAssertEqual(status.percent, 25)
        XCTAssertEqual(status.progressLine, "2.50 MiB of 10.00 MiB · 25%")
    }

    func testPercentIsZeroBeforeTotalIsKnown() {
        let packs = FakeCapabilityPacks()
        packs.isInstalling = true
        packs.downloadedBytes = mib

        XCTAssertEqual(DictionaryStatusText(packs: packs).percent, 0)
    }

    func testUpdateLineWithSize() {
        let packs = FakeCapabilityPacks()
        packs.isInstalled = true
        packs.installedVersion = "1"
        packs.updateVersion = "2"
        packs.updateSizeBytes = 15 * mib

        let status = DictionaryStatusText(packs: packs)
        XCTAssertEqual(status.updateLine, "Update available · 2 · 15.00 MiB")
        XCTAssertEqual(status.updateButtonTitle, "Update to 2")
    }

    func testUpdateLineWithoutSize() {
        let packs = FakeCapabilityPacks()
        packs.updateVersion = "2"

        let status = DictionaryStatusText(packs: packs)
        XCTAssertEqual(status.updateLine, "Update available · 2")
    }

    func testUpdateButtonTitleWithoutVersion() {
        XCTAssertEqual(DictionaryStatusText(packs: FakeCapabilityPacks()).updateButtonTitle, "Update")
    }
}
