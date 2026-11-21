import ReadLaterUI
import XCTest

/// Cross-app board source: a second installed app (BoardWriter) writes the
/// board, then the entry paste line must fill the field. The in-app cut
/// journey covers a board written by the app itself; this covers a board
/// written by another process.
///
/// BoardWriter is an external fixture, not a repo target: bundle id
/// `app.readlater.boardwriter`, one screen that writes a link to the
/// board and shows "Board written". Install it on the simulator before
/// running these tests.
final class CrossAppPasteTests: XCTestCase {
    static let writerID = "app.readlater.boardwriter"

    /// Sets "Paste from Other Apps" to Allow in Settings first, so the field
    /// must fill whatever permission state ran before.
    func test_allowedBoardFillsField() throws {
        try XCTSkipIf(true, "Settings navigation adds about 60 s per test. Remove this line to run it.")
        Self.setPasteAccess(.allow)
        let writer = XCUIApplication(bundleIdentifier: Self.writerID)
        writer.launch()
        XCTAssertTrue(
            writer.wait(for: .runningForeground, timeout: 20),
            "BoardWriter did not launch"
        )
        XCTAssertTrue(
            writer.staticTexts["Board written"].waitForExistence(timeout: 5),
            "BoardWriter did not report its write"
        )
        writer.terminate()

        let app = AppLauncher.launch()
        let field = app.textViews[AccessibilityID.entryLinkField]
        XCTAssertTrue(field.waitForExistence(timeout: Waits.state), "the entry field did not appear")
        JourneySteps.tap(app, field)
        // Select all, then delete: clear the field without rewriting the
        // board (Cut would overwrite the cross-app item with the sample).
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: Waits.state), "no Select All menu")
        selectAll.tap()
        app.typeText("\u{8}")

        let sysPaste = app.buttons[AccessibilityID.entryPaste].firstMatch
        XCTAssertTrue(sysPaste.waitForExistence(timeout: Waits.state), "the paste line is missing")
        JourneySteps.dismissKeyboardIfPresent(app)
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: sysPaste
        )
        let result = XCTWaiter().wait(for: [enabled], timeout: Waits.state)
        XCTAssertTrue(
            result == .completed,
            "the paste button never enabled"
        )
        JourneySteps.tap(app, sysPaste)

        let filled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@", "example.com"
            ),
            object: field
        )
        let delivered = XCTWaiter().wait(for: [filled], timeout: 10)
        XCTAssertTrue(
            delivered == .completed,
            "the tap did not fill the field, got: \(JourneySteps.displayedValue(field))"
        )
    }

    private enum PasteAccess: String {
        case deny = "Deny"
        case allow = "Allow"
    }

    /// Sets ReadLater's "Paste from Other Apps" in Settings. XCUITest cannot
    /// reset this permission: XCUIProtectedResource has no pasteboard case.
    private static func setPasteAccess(_ access: PasteAccess) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let apps = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Apps'")).firstMatch
        for _ in 0..<8 where !apps.exists { settings.swipeUp() }
        apps.tap()
        let readLater = settings.buttons["app.readlater.reader"]
        for _ in 0..<8 where !readLater.exists { settings.swipeUp() }
        readLater.tap()
        let pasteRow = settings.buttons["Paste from Other Apps"]
        for _ in 0..<4 where !pasteRow.exists { settings.swipeUp() }
        pasteRow.tap()
        settings.cells.matching(NSPredicate(format: "label BEGINSWITH %@", access.rawValue)).firstMatch.tap()
        settings.terminate()
    }

    /// Sets "Paste from Other Apps" to Deny in Settings first. iOS then fails
    /// every read with PBErrorDomain 13 and never prompts again; the app must
    /// surface that instead of reading as a dead button.
    func test_deniedBoardShowsNote() throws {
        try XCTSkipIf(true, "Settings navigation adds about 60 s per test. Remove this line to run it.")
        Self.setPasteAccess(.deny)
        let writer = XCUIApplication(bundleIdentifier: Self.writerID)
        writer.launch()
        XCTAssertTrue(
            writer.wait(for: .runningForeground, timeout: 20),
            "BoardWriter did not launch"
        )
        XCTAssertTrue(
            writer.staticTexts["Board written"].waitForExistence(timeout: 5),
            "BoardWriter did not report its write"
        )
        writer.terminate()

        let app = AppLauncher.launch()
        let field = app.textViews[AccessibilityID.entryLinkField]
        XCTAssertTrue(field.waitForExistence(timeout: Waits.state), "the entry field did not appear")
        JourneySteps.tap(app, field)
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: Waits.state), "no Select All menu")
        selectAll.tap()
        app.typeText("\u{8}")

        let sysPaste = app.buttons[AccessibilityID.entryPaste].firstMatch
        XCTAssertTrue(sysPaste.waitForExistence(timeout: Waits.state), "the paste line is missing")
        JourneySteps.dismissKeyboardIfPresent(app)
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: sysPaste
        )
        XCTAssertTrue(
            XCTWaiter().wait(for: [enabled], timeout: Waits.state) == .completed,
            "the paste button never enabled"
        )
        JourneySteps.tap(app, sysPaste)

        let note = app.staticTexts[EntryCopy.pasteBlockedNote]
        XCTAssertTrue(
            note.waitForExistence(timeout: 12),
            "the blocked note never appeared; field holds: \(JourneySteps.displayedValue(field))"
        )
    }
}
