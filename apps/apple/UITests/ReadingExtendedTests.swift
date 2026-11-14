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
///
/// Scenario: Rail controls are present
///   Given the sample article is open
///   Then the rail, follow dot and clock are visible
///
/// Scenario: Clock cycles its format
///   Given the sample article is open
///   When I tap the clock
///   Then the clock shows count, then percent, then time again
///
/// Scenario: Follow dot holds and resumes
///   Given the sample article is open
///   When I tap the follow dot
///   Then the dot reports held
///   And tapping again reports following
final class ReadingExtendedTests: XCTestCase {
    func test_sentenceStepMovesTheWash() throws {
#if os(macOS)
        throw XCTSkip("reading progress/wash updates are unreliable under XCUI on macOS; tracked separately")
#endif
        let app = AppLauncher.launch()
        JourneySteps.openSample(app)

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
        JourneySteps.tap(app, next)

        waitForPredicate(
            NSPredicate(format: "value != %@", start),
            on: progress,
            timeout: Waits.state,
            "the sentence step did not move the wash"
        )
        XCTAssertEqual(play.label, "Play", "the player did not stay paused after the step")
        Artefacts.capture(app, name: "ios-step", in: self)
    }

    func test_speedSurvivesRelaunch() throws {
#if os(macOS)
        throw XCTSkip("reading progress/wash updates are unreliable under XCUI on macOS; tracked separately")
#endif
        let app = AppLauncher.launch()
        JourneySteps.openSample(app)
        setSpeed(app, to: "1.2×", label: "Speed 1.2 times")

        // Pause records the place. The relaunch then offers a resume, which
        // is the way back in: the link field is empty after the first demo
        // open, so tapping Open would open nothing.
        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        JourneySteps.tap(app, play)
        waitForLabel("Pause", on: play, timeout: Waits.state, "playback did not start")
        JourneySteps.tap(app, play)
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
        JourneySteps.tap(app, resume)
        XCTAssertTrue(
            JourneySteps.texts(app, id: AccessibilityID.readerTitle).waitForExistence(timeout: Waits.screen),
            "resume did not reopen the article"
        )

        let speed = app.buttons[AccessibilityID.readerSpeed]
        XCTAssertTrue(speed.waitForExistence(timeout: Waits.screen), "the speed control is missing")
        XCTAssertEqual(JourneySteps.displayed(speed), "Speed 1.2 times", "the speed did not survive the relaunch")
        Artefacts.capture(app, name: "ios-speed", in: self)
    }

    func test_finishStateShowsReplay() throws {
#if os(macOS)
        throw XCTSkip("reading progress/wash updates are unreliable under XCUI on macOS; tracked separately")
#endif
        let app = AppLauncher.launch(extraArguments: ["--debug.voice-pace=20"])
        JourneySteps.openSample(app)

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
        JourneySteps.front(app)
        #if os(macOS)
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        #else
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        #endif
        waitForPredicate(
            NSPredicate(format: "value != %@", start),
            on: progress,
            timeout: Waits.state,
            "the scrub did not move the wash"
        )

        JourneySteps.tap(app, play)
        waitForLabel("Replay", on: play, timeout: Waits.state, "the finish state did not offer a replay")
        Artefacts.capture(app, name: "ios-replay", in: self)
    }

    func test_railControlsPresent() throws {
        let app = AppLauncher.launch()
        JourneySteps.openSample(app)

        for id in [
            AccessibilityID.readerRail,
            AccessibilityID.railSpeed,
            AccessibilityID.railSpeedMinus,
            AccessibilityID.railSpeedPlus,
            AccessibilityID.railScrub,
            AccessibilityID.railPlayPause,
            AccessibilityID.railPrevSentence,
            AccessibilityID.railNextSentence,
            AccessibilityID.followDot,
            AccessibilityID.clock,
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)[id].waitForExistence(timeout: Waits.screen),
                "missing rail control \(id)"
            )
        }
        Artefacts.capture(app, name: "ios-rail", in: self)
    }

    func test_clockCyclesMode() throws {
        let app = AppLauncher.launch()
        JourneySteps.openSample(app)

        // The label names the control; the clock text lives in `value`.
        let clock = app.buttons[AccessibilityID.clock]
        XCTAssertTrue(clock.waitForExistence(timeout: Waits.screen), "the clock is missing")
        let start = JourneySteps.displayedValue(clock)
        XCTAssertTrue(start.contains("left"), "the clock did not start in time+count mode: \(start)")

        JourneySteps.tap(app, clock)
        waitForPredicate(
            NSPredicate(format: "value CONTAINS %@", "/"),
            on: clock,
            timeout: Waits.state,
            "the clock did not switch to count mode"
        )
        XCTAssertFalse(JourneySteps.displayedValue(clock).contains("left"), "count mode still shows time")

        JourneySteps.tap(app, clock)
        waitForPredicate(
            NSPredicate(format: "value CONTAINS %@", "%"),
            on: clock,
            timeout: Waits.state,
            "the clock did not switch to percent mode"
        )

        JourneySteps.tap(app, clock)
        waitForPredicate(
            NSPredicate(format: "value == %@", start),
            on: clock,
            timeout: Waits.state,
            "the clock did not cycle back to time+count"
        )
    }

    func test_followDotHoldsAndResumes() throws {
        let app = AppLauncher.launch()
        JourneySteps.openSample(app)

        let dot = app.buttons[AccessibilityID.followDot]
        XCTAssertTrue(dot.waitForExistence(timeout: Waits.screen), "the follow dot is missing")
        XCTAssertEqual(dot.label, "Following wash, tap to hold", "the dot did not start following")

        JourneySteps.tap(app, dot)
        waitForLabel("Held, tap to resume follow", on: dot, timeout: Waits.state, "the dot did not hold")

        JourneySteps.tap(app, dot)
        waitForLabel("Following wash, tap to hold", on: dot, timeout: Waits.state, "the dot did not resume")
    }

    // MARK: - Journey steps

    /// Rail speed: tap steps 0.1 per tap (1.0 -> 1.2 is two taps); the
    /// 4-value ladder (0.5, 1.0, 1.2, 1.5) is the long-press/context menu.
    private func setSpeed(_ app: XCUIApplication, to option: String, label: String) {
        let speed = app.buttons[AccessibilityID.railSpeed]
        XCTAssertTrue(speed.waitForExistence(timeout: Waits.screen), "the speed control is missing")
        JourneySteps.tap(app, speed)
        JourneySteps.tap(app, speed)
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
