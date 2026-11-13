import ReadLaterUI
import XCTest

/// Feature: Reading extended
/// Ticket: [e2e] Nightly reading journeys
///
/// Scenario: Sentence step moves the wash
///   Given the sample article is open
///   And the reader is paused at the first word
///   When I step forward one sentence
///   Then the reading progress changes
///   And the play button still offers play
///
/// Scenario: Speed survives a relaunch
///   Given the sample article is open
///   When I set the speed to 1.2x
///   And the app relaunches
///   And I open the sample article again
///   Then the speed still reads 1.2x
///
/// Scenario: Finish offers a replay
///   Given the sample article is open at the fast scripted voice
///   When I scrub near the end and play
///   Then the play button offers replay
final class ReadingExtendedTests: XCTestCase {
    func test_sentenceStepMovesTheWash() throws {
        let app = AppLauncher.launch()
        openSample(app)

        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        XCTAssertEqual(play.label, "Play", "the reader did not start paused")

        let progress = app.descendants(matching: .any)[AccessibilityID.readerProgress]
        XCTAssertTrue(
            progress.waitForExistence(timeout: Waits.screen),
            "the reading progress element is missing"
        )
        let start = try XCTUnwrap(progress.value as? String, "the progress element has no value")

        let next = app.buttons[AccessibilityID.readerStepForward]
        XCTAssertTrue(next.waitForExistence(timeout: Waits.screen), "the next-sentence step is missing")
        next.tap()

        waitForPredicate(
            NSPredicate(format: "value != %@", start),
            on: progress,
            timeout: Waits.state,
            "the sentence step did not move the wash"
        )
        XCTAssertEqual(play.label, "Play", "the player did not stay paused after the step")
        Artefacts.capture(app, name: "ios-step", in: self)
    }

    func test_speedSurvivesRelaunch() {
        let app = AppLauncher.launch()
        openSample(app)
        setSpeed(app, to: "1.2×", label: "Speed 1.2 times")

        // Pause records the place. The relaunch then offers a resume, which
        // is the way back in: the link field is empty after the first demo
        // open, so tapping Open would open nothing.
        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        play.tap()
        waitForLabel("Pause", on: play, timeout: Waits.state, "playback did not start")
        play.tap()
        waitForLabel("Play", on: play, timeout: Waits.state, "pause did not land")

        // The e2e preset wipes defaults on every launch. Keep them for the
        // relaunch, or nothing can persist.
        app.launchArguments += ["--debug.reset=none"]
        AppLauncher.relaunch(app)

        let resume = app.buttons[AccessibilityID.entryResume]
        XCTAssertTrue(
            resume.waitForExistence(timeout: Waits.screen),
            "the resume offer did not appear after relaunch"
        )
        resume.tap()
        XCTAssertTrue(
            app.staticTexts[AccessibilityID.readerTitle].waitForExistence(timeout: Waits.screen),
            "resume did not reopen the article"
        )

        let speed = app.buttons[AccessibilityID.readerSpeed]
        XCTAssertTrue(speed.waitForExistence(timeout: Waits.screen), "the speed control is missing")
        XCTAssertEqual(speed.label, "Speed 1.2 times", "the speed did not survive the relaunch")
        Artefacts.capture(app, name: "ios-speed", in: self)
    }

    func test_finishStateShowsReplay() throws {
        let app = AppLauncher.launch(extraArguments: ["--debug.voice-pace=20"])
        openSample(app)

        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")

        let progress = app.descendants(matching: .any)[AccessibilityID.readerProgress]
        XCTAssertTrue(
            progress.waitForExistence(timeout: Waits.screen),
            "the reading progress element is missing"
        )
        let start = try XCTUnwrap(progress.value as? String, "the progress element has no value")

        // Scrub to the last words: one commit, then play finishes in a
        // fraction of a second at the fast scripted voice.
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        waitForPredicate(
            NSPredicate(format: "value != %@", start),
            on: progress,
            timeout: Waits.state,
            "the scrub did not move the wash"
        )

        play.tap()
        waitForLabel("Replay", on: play, timeout: Waits.state, "the finish state did not offer a replay")
        Artefacts.capture(app, name: "ios-replay", in: self)
    }

    // MARK: - Journey steps

    /// Opens the sample article from a fresh entry screen.
    private func openSample(_ app: XCUIApplication) {
        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        open.tap()
        XCTAssertTrue(
            app.staticTexts[AccessibilityID.readerTitle].waitForExistence(timeout: Waits.screen),
            "the article did not open"
        )
    }

    /// Picks one speed from the speed menu and waits for the label to follow.
    private func setSpeed(_ app: XCUIApplication, to option: String, label: String) {
        let speed = app.buttons[AccessibilityID.readerSpeed]
        XCTAssertTrue(speed.waitForExistence(timeout: Waits.screen), "the speed control is missing")
        speed.tap()
        Artefacts.capture(app, name: "ios-speed-menu", in: self)
        let choice = app.buttons[option]
        XCTAssertTrue(
            choice.waitForExistence(timeout: Waits.state),
            "the speed menu did not offer \(option)"
        )
        choice.tap()
        waitForLabel(label, on: speed, timeout: Waits.state, "the speed change did not land")
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
