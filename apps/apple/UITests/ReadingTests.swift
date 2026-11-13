import ReadLaterUI
import XCTest

/// Feature: Reading
/// Ticket: [e2e] Read and control the voice
///
/// Scenario: Pause holds the place
///   Given the sample article is open
///   And the reader is paused at the first word
///   When I tap play
///   Then the play button offers pause
///   And the reading progress advances
///   When I tap pause
///   Then the play button offers play
///   And the reading progress stays where it stopped for two seconds
final class ReadingTests: XCTestCase {
    func test_playAdvancesAndPauseHoldsThePlace() throws {
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        open.tap()

        XCTAssertTrue(
            app.staticTexts[AccessibilityID.readerTitle].waitForExistence(timeout: Waits.screen),
            "the article did not open"
        )

        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        XCTAssertEqual(play.label, "Play", "the reader did not start paused")

        let progress = app.descendants(matching: .any)[AccessibilityID.readerProgress]
        XCTAssertTrue(
            progress.waitForExistence(timeout: Waits.screen),
            "the reading progress element is missing"
        )
        let start = try XCTUnwrap(progress.value as? String, "the progress element has no value")

        play.tap()
        waitForLabel("Pause", on: play, timeout: Waits.state, "playback did not start")

        waitForPredicate(
            NSPredicate(format: "value != %@", start),
            on: progress,
            timeout: Waits.state,
            "the reading progress did not advance"
        )

        play.tap()
        waitForLabel("Play", on: play, timeout: Waits.state, "pause did not land")

        let held = try XCTUnwrap(progress.value as? String, "the progress element has no value")
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", held),
            object: progress
        )
        moved.isInverted = true
        let result = XCTWaiter().wait(for: [moved], timeout: 2)
        XCTAssertTrue(result == .completed, "the progress moved while paused (was \(held))")
        Artefacts.capture(app, name: "ios-paused", in: self)
    }

    /// Waits for the element label to read `expected`.
    private func waitForLabel(
        _ expected: String,
        on element: XCUIElement,
        timeout: TimeInterval,
        _ message: String
    ) {
        waitForPredicate(
            NSPredicate(format: "label == %@", expected),
            on: element,
            timeout: timeout,
            message
        )
    }

    /// Waits for the predicate to hold against the element.
    private func waitForPredicate(
        _ predicate: NSPredicate,
        on element: XCUIElement,
        timeout: TimeInterval,
        _ message: String
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(result == .completed, message)
    }
}
