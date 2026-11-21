import ReadLaterUI
import XCTest

/// Feature: Entry
/// Ticket: [e2e] Open the sample article from the entry screen
///
/// Scenario: First run opens the sample article
///   Given the app starts with no saved state
///   And the entry screen is showing
///   And the link field holds the sample link
///   When I tap "Open in Read Later"
///   Then the sample article is showing
final class EntryTests: XCTestCase {
    func test_firstRunOpensTheSampleArticle() {
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        XCTAssertTrue(
            app.textViews[AccessibilityID.entryLinkField].exists,
            "the link field is missing"
        )
        JourneySteps.tap(app, open)

        let title = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
        XCTAssertTrue(title.waitForExistence(timeout: Waits.screen), "the article did not open")
        XCTAssertEqual(JourneySteps.displayed(title), "The Quiet Power of Slow Reading")
        Artefacts.capture(app, name: "ios-article", in: self)
    }
}
