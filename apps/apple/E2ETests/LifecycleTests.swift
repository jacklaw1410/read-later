import ReadLaterUI
import XCTest

/// Feature: Lifecycle
/// Ticket: [p3] Phase 2 lifecycle + real-voice journey
///
/// Scenario: Background pauses and return holds the place
///   Given the sample article is open and playing
///   When the app goes to the background and returns
///   Then the player offers Play (paused)
///   And the article is still showing
///
/// Scenario: Voice state transitions only
///   Given the sample article is open
///   When I tap play then pause
///   Then the button offers Pause then Play
///   And no assertion depends on timing or pace
///
/// Honesty note: the second test keeps the `--debug.preset=e2e` scripted
/// voice. `AVSpeechSynthesizer` delivers no word-boundary callbacks in a
/// simulator/`--snapshot` launch (see README §7), so a real-synthesizer
/// timing assertion is not reliable here. The test asserts only Play/Pause
/// label transitions, which is voice-agnostic, and keeps its
/// `test_realVoiceStateOnly` name as the placeholder the nightly run fills
/// once a device runner can host the real synthesizer.
final class LifecycleTests: XCTestCase {
    func test_backgroundPausesAndReturns() throws {
#if os(iOS)
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        JourneySteps.tap(app, open)

        let title = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
        XCTAssertTrue(title.waitForExistence(timeout: Waits.screen), "the article did not open")

        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        JourneySteps.tap(app, play)
        waitForLabel("Pause", on: play, timeout: Waits.state, "playback did not start")

        XCUIDevice.shared.press(.home)

        app.activate()
        XCTAssertTrue(title.waitForExistence(timeout: Waits.screen), "the article did not survive background")
        waitForLabel("Play", on: play, timeout: Waits.state, "background did not pause playback")
        Artefacts.capture(app, name: "ios-background-paused", in: self)
#else
        // macOS has no Home button and no scenePhase background in the UI
        // runner. Skip so the suite stays green without a false pass.
        throw XCTSkip("background pause is iOS-only; no Home button on macOS")
#endif
    }

    func test_realVoiceStateOnly() {
        // Keeps the e2e preset (scripted voice, determinism). Asserts only
        // Play/Pause label transitions, never timing or pace.
        let app = AppLauncher.launch()
        JourneySteps.openSample(app)

        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(play.waitForExistence(timeout: Waits.screen), "the play button is missing")
        XCTAssertEqual(play.label, "Play", "the reader did not start paused")

        JourneySteps.tap(app, play)
        waitForLabel("Pause", on: play, timeout: Waits.state, "playback did not start")

        JourneySteps.tap(app, play)
        waitForLabel("Play", on: play, timeout: Waits.state, "pause did not land")
        Artefacts.capture(app, name: "ios-voice-state", in: self)
    }

    /// Waits for the element label to read `expected`.
    private func waitForLabel(
        _ expected: String,
        on element: XCUIElement,
        timeout: TimeInterval,
        _ message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(result == .completed, message)
    }
}
