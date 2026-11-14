import ReadLaterUI
import XCTest

/// Feature: Entry (extended)
/// Ticket: [p2] Entry-extended nightly journeys
///
/// Scenario: Resume after relaunch
///   Given the sample article is open
///   And playback started and paused, recording a place
///   And the reader exited to the entry screen
///   When the app relaunches with the store kept
///   Then the resume offer appears
///   And tapping Resume reopens the same article
///
/// Scenario: Raw-text entry
///   Given the entry screen is showing
///   When the reader switches to Text, types a paragraph and opens it
///   Then the pasted article is showing under its derived title
final class EntryExtendedTests: XCTestCase {
    func test_resumeAfterRelaunch() {
        var app = AppLauncher.launch()
        JourneySteps.openSample(app)
        XCTAssertEqual(
            JourneySteps.displayed(JourneySteps.texts(app, id: AccessibilityID.readerTitle)),
            "The Quiet Power of Slow Reading"
        )

        // Play briefly so a place is recorded, then pause. The pause
        // checkpoints the word; the exit below flushes it to the store.
        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        JourneySteps.tap(app, play)
        waitForLabel("Pause", on: play, "playback did not start")
        JourneySteps.tap(app, play)
        waitForLabel("Play", on: play, "pause did not land")

        JourneySteps.tap(app, app.buttons[AccessibilityID.readerBack])
        XCTAssertTrue(
            app.buttons[AccessibilityID.entryOpen].waitForExistence(timeout: Waits.screen),
            "back did not return to the entry screen"
        )

        // A plain relaunch would reset the store (the e2e preset wipes on
        // launch), so keep it: the preset still applies, only the wipe is off.
        app.terminate()
        app = AppLauncher.launch(extraArguments: ["--debug.reset=none"])

        let resume = app.buttons[AccessibilityID.entryResume]
        XCTAssertTrue(
            resume.waitForExistence(timeout: Waits.screen),
            "the resume offer did not appear after relaunch"
        )
        JourneySteps.tap(app, resume)

        let reopened = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
        XCTAssertTrue(
            reopened.waitForExistence(timeout: Waits.screen),
            "resume did not reopen the article"
        )
        XCTAssertEqual(JourneySteps.displayed(reopened), "The Quiet Power of Slow Reading")
        Artefacts.capture(app, name: "ios-resumed", in: self)
    }

    func test_rawTextEntry() {
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")

        let textMode = JourneySteps.textModeOption(app)
        XCTAssertTrue(textMode.waitForExistence(timeout: Waits.screen), "the Text mode option is missing")
        JourneySteps.tap(app, textMode)

        let raw = app.textViews[AccessibilityID.entryRawField]
        XCTAssertTrue(raw.waitForExistence(timeout: Waits.state), "the raw text field did not appear")
        JourneySteps.tap(app, raw)
        // Six words: the derived title is the text itself, no ellipsis.
        raw.typeText("Slow readers keep the whole field")

        // The keyboard Done dismisses the editor; the open tap must land on
        // the button, not the keyboard.
        JourneySteps.dismissKeyboardIfPresent(app)
        let openAgain = app.buttons[AccessibilityID.entryOpen]
        JourneySteps.tap(app, openAgain)

        let title = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
        XCTAssertTrue(
            title.waitForExistence(timeout: Waits.screen),
            "the pasted article did not open"
        )
        XCTAssertEqual(JourneySteps.displayed(title), "Slow readers keep the whole field")
        Artefacts.capture(app, name: "ios-raw", in: self)
    }

    /// Waits for the element label to read `expected`.
    private func waitForLabel(
        _ expected: String,
        on element: XCUIElement,
        _ message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: Waits.state)
        XCTAssertTrue(result == .completed, message)
    }
}
