import ReadLaterUI
import XCTest

/// Feature: Entry (extended)
/// Ticket: [p2] Entry-extended nightly journeys
///
/// Scenario: Reopen from the library after relaunch
///   Given the sample article is open
///   And playback started and paused, recording a place
///   And the reader exited to the entry screen
///   When the app relaunches with the store kept
///   Then the library lists the article with its place
///   And tapping the row reopens the same article
///
/// Scenario: Raw-text entry
///   Given the entry screen is showing
///   When the reader types a paragraph in the field and opens it
///   Then the pasted article is showing under its derived title
final class EntryExtendedTests: XCTestCase {
    func test_reopenFromLibraryAfterRelaunch() {
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

        // The resume offer is gone; the way back in is the library row,
        // which carries the saved place.
        JourneySteps.openLibraryRow(app, title: "The Quiet Power of Slow Reading")

        let reopened = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
        XCTAssertTrue(
            reopened.waitForExistence(timeout: Waits.screen),
            "the library row did not reopen the article"
        )
        XCTAssertEqual(JourneySteps.displayed(reopened), "The Quiet Power of Slow Reading")
        Artefacts.capture(app, name: "ios-reopened", in: self)
    }

    func test_rawTextEntry() {
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")

        // One field takes a link or a paragraph; no mode switch. The e2e
        // preset prefills the sample link, so the field is cleared first:
        // where the tap lands the cursor is a platform detail, and typing
        // over the prefill would glue the two together.
        let field = app.textViews[AccessibilityID.entryLinkField]
        XCTAssertTrue(field.waitForExistence(timeout: Waits.state), "the entry field did not appear")
        JourneySteps.tap(app, field)
        clearField(field, in: app)
        // Six words: the derived title is the text itself, no ellipsis.
        field.typeText("Slow readers keep the whole field")

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

    /// Scenario: Paste from clipboard
    ///   Given the entry field holds a link
    ///   When the reader cuts it and taps the paste line
    ///   Then the field holds the board text and the paste line is gone
    ///
    /// The cut seeds the board through the sanctioned path inside the app:
    /// a UI test runner on the host cannot reach the simulator's board.
    func test_pasteButtonFillsField() {
        let app = AppLauncher.launch()

        let field = app.textViews[AccessibilityID.entryLinkField]
        XCTAssertTrue(field.waitForExistence(timeout: Waits.state), "the entry field did not appear")
        JourneySteps.tap(app, field)
        cut(field, in: app)

        let line = JourneySteps.texts(app, id: AccessibilityID.entryPasteLabel)
        XCTAssertTrue(
            line.waitForExistence(timeout: Waits.state),
            "the paste line is missing on the empty field"
        )
        XCTAssertEqual(JourneySteps.displayed(line), EntryCopy.pasteFromClipboard)

        // Tap the system button itself: it owns the board read, so iOS
        // shows no permission prompt. The button enables asynchronously
        // as the board change propagates; a tap before that is swallowed.
        JourneySteps.dismissKeyboardIfPresent(app)
        let sysPaste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(sysPaste.waitForExistence(timeout: Waits.state), "no system paste button")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: sysPaste
        )
        XCTAssertTrue(
            XCTWaiter().wait(for: [enabled], timeout: Waits.state) == .completed,
            "the paste button never enabled with a link on the board"
        )
        JourneySteps.tap(app, sysPaste)
        XCTAssertTrue(
            JourneySteps.displayedValue(field).contains("theatlantic"),
            "the tap did not fill the field, got: \(JourneySteps.displayedValue(field))"
        )
        XCTAssertFalse(
            JourneySteps.texts(app, id: AccessibilityID.entryPasteLabel)
                .waitForExistence(timeout: 2),
            "the paste line stayed after the field filled"
        )
    }

    /// Cuts the prefilled field: select all, then Cut. The e2e preset
    /// always prefills the sample link, so the paste line never shows
    /// until the text is gone — and the cut leaves the link on the board
    /// for the paste step.
    private func cut(_ field: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("x", modifierFlags: .command)
        #else
        field.tap()
        selectAll(in: app)
        let cut = app.menuItems["Cut"]
        XCTAssertTrue(cut.waitForExistence(timeout: Waits.state), "no Cut menu over the selection")
        cut.tap()
        #endif
    }

    /// Empties the prefilled field without touching the board: select all,
    /// then delete. Typing tests use this; the paste test uses cut.
    private func clearField(_ field: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        #else
        field.tap()
        selectAll(in: app)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        #endif
    }

    private func selectAll(in app: XCUIApplication) {
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(
            selectAll.waitForExistence(timeout: Waits.state),
            "no Select All menu over the field"
        )
        selectAll.tap()
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
