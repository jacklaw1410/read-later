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

        JourneySteps.openSample(app)

        JourneySteps.tap(app, app.buttons[AccessibilityID.readerBack])
        XCTAssertTrue(
            app.buttons[AccessibilityID.entryOpen].waitForExistence(timeout: Waits.screen),
            "exit did not return to entry"
        )

        JourneySteps.tap(app, app.buttons[AccessibilityID.entryLibrary])
        let actions = app.descendants(matching: .any)[AccessibilityID.libraryActions]
        XCTAssertTrue(actions.waitForExistence(timeout: Waits.screen), "the library did not open")

        // Save keeps the row.
        let actions1 = app.descendants(matching: .any)[AccessibilityID.libraryActions]
        JourneySteps.tap(app, actions1)
        let save = app.descendants(matching: .any)[AccessibilityID.librarySave]
        XCTAssertTrue(save.waitForExistence(timeout: Waits.state), "the save item did not appear")
        JourneySteps.tap(app, save)
        let row = JourneySteps.texts(app, id: title)
        XCTAssertTrue(row.waitForExistence(timeout: Waits.state), "the saved row is missing")

        // Refresh drops the cached plan; the row and the place stay.
        let actions2 = app.descendants(matching: .any)[AccessibilityID.libraryActions]
        JourneySteps.tap(app, actions2)
        let refresh = app.descendants(matching: .any)[AccessibilityID.libraryRefresh]
        XCTAssertTrue(refresh.waitForExistence(timeout: Waits.state), "the refresh item did not appear")
        JourneySteps.tap(app, refresh)
        XCTAssertTrue(row.waitForExistence(timeout: Waits.state), "the refreshed row is missing")

        // Remove drops the row after confirmation.
        let actions3 = app.descendants(matching: .any)[AccessibilityID.libraryActions]
        JourneySteps.tap(app, actions3)
        let remove = app.descendants(matching: .any)[AccessibilityID.libraryRemove]
        XCTAssertTrue(remove.waitForExistence(timeout: Waits.state), "the remove item did not appear")
        JourneySteps.tap(app, remove)
        let alert = app.alerts.firstMatch
        let sheet = app.sheets.firstMatch
        let container = alert.exists ? alert : sheet
        XCTAssertTrue(container.waitForExistence(timeout: Waits.state), "the remove confirmation did not appear")
        let confirm = container.buttons[LibraryCopy.remove].exists
            ? container.buttons[LibraryCopy.remove]
            : app.buttons[LibraryCopy.remove]
        JourneySteps.tap(app, confirm)
        XCTAssertTrue(
            row.waitForNonExistence(timeout: Waits.state),
            "the removed row is still showing"
        )

        Artefacts.capture(app, name: "ios-library", in: self)
    }
}
