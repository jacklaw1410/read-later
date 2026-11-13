import ReadLaterUI
import XCTest

/// Feature: Library
/// Ticket: [e2e] Save, refresh and remove from the library
///
/// Scenario: Save keeps, refresh keeps, remove drops
///   Given the sample article is open
///   When I exit to the entry screen
///   And I open the library
///   And I save the article
///   Then the row is showing
///   When I refresh the article
///   Then the row is still showing
///   When I remove the article and confirm
///   Then the row is gone
final class LibraryTests: XCTestCase {
    func test_saveRefreshRemove() {
        let app = AppLauncher.launch()
        let title = ArticleLibrary.title

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        open.tap()

        XCTAssertTrue(
            app.staticTexts[AccessibilityID.readerTitle].waitForExistence(timeout: Waits.screen),
            "the article did not open"
        )

        app.buttons[AccessibilityID.readerBack].tap()
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "exit did not return to entry")

        app.buttons[AccessibilityID.entryLibrary].tap()
        let actions = app.buttons[AccessibilityID.libraryActions]
        XCTAssertTrue(actions.waitForExistence(timeout: Waits.screen), "the library did not open")

        // Save keeps the row.
        actions.tap()
        let save = app.descendants(matching: .any)[AccessibilityID.librarySave]
        XCTAssertTrue(save.waitForExistence(timeout: Waits.state), "the save item did not appear")
        save.tap()
        let row = app.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: Waits.state), "the saved row is missing")

        // Refresh drops the cached plan; the row and the place stay.
        actions.tap()
        let refresh = app.descendants(matching: .any)[AccessibilityID.libraryRefresh]
        XCTAssertTrue(refresh.waitForExistence(timeout: Waits.state), "the refresh item did not appear")
        refresh.tap()
        XCTAssertTrue(row.waitForExistence(timeout: Waits.state), "the refreshed row is missing")

        // Remove drops the row after confirmation.
        actions.tap()
        let remove = app.descendants(matching: .any)[AccessibilityID.libraryRemove]
        XCTAssertTrue(remove.waitForExistence(timeout: Waits.state), "the remove item did not appear")
        remove.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: Waits.state), "the remove confirmation did not appear")
        alert.buttons[LibraryCopy.remove].tap()
        XCTAssertTrue(
            row.waitForNonExistence(timeout: Waits.state),
            "the removed row is still showing"
        )

        Artefacts.capture(app, name: "ios-library", in: self)
    }
}
