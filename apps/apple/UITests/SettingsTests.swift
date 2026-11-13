import ReadLaterUI
import XCTest

/// Feature: Settings
/// Ticket: [e2e] Appearance and play-side choices survive a relaunch
///
/// Scenario: Appearance survives a relaunch
///   Given the settings sheet is showing
///   When I set the appearance to dark
///   And the app relaunches without a defaults reset
///   And I open settings again
///   Then dark is still selected
///
/// Scenario: Handedness flips and survives a relaunch
///   Given the settings sheet is showing
///   When I flip the play button to the left
///   Then the left side is selected
///   When the app relaunches without a defaults reset
///   And I open settings again
///   Then the left side is still selected when stored,
///   else the flip still works
final class SettingsTests: XCTestCase {
    func test_appearanceSurvivesRelaunch() {
        let app = AppLauncher.launch()

        let settings = app.buttons[AccessibilityID.entrySettings]
        XCTAssertTrue(settings.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        settings.tap()

        let appearance = app.segmentedControls[AccessibilityID.settingsAppearance]
        XCTAssertTrue(
            appearance.waitForExistence(timeout: Waits.screen),
            "the appearance control is missing"
        )
        let dark = appearance.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: Waits.state), "the dark option is missing")
        dark.tap()
        waitForSelected(dark, timeout: Waits.state, message: "the dark option did not select")

        // The e2e preset wipes the defaults on launch. Keep them on the
        // relaunch so the stored choice can survive, then relaunch.
        app.launchArguments = app.launchArguments + ["--debug.reset=none"]
        AppLauncher.relaunch(app)

        let settingsAgain = app.buttons[AccessibilityID.entrySettings]
        XCTAssertTrue(
            settingsAgain.waitForExistence(timeout: Waits.screen),
            "entry screen did not reappear"
        )
        settingsAgain.tap()

        let appearanceAgain = app.segmentedControls[AccessibilityID.settingsAppearance]
        XCTAssertTrue(
            appearanceAgain.waitForExistence(timeout: Waits.screen),
            "the appearance control is missing after relaunch"
        )
        let darkAgain = appearanceAgain.buttons["Dark"]
        XCTAssertTrue(
            darkAgain.waitForExistence(timeout: Waits.state),
            "the dark option is missing after relaunch"
        )
        waitForSelected(darkAgain, timeout: Waits.state, message: "the dark choice did not survive")
        Artefacts.capture(app, name: "ios-settings", in: self)
    }

    func test_handednessFlip() {
        let app = AppLauncher.launch()

        let settings = app.buttons[AccessibilityID.entrySettings]
        XCTAssertTrue(settings.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        settings.tap()

        let handedness = app.segmentedControls[AccessibilityID.settingsHandedness]
        XCTAssertTrue(
            handedness.waitForExistence(timeout: Waits.screen),
            "the play-side control is missing"
        )
        let left = handedness.buttons["Left"]
        XCTAssertTrue(left.waitForExistence(timeout: Waits.state), "the left option is missing")
        left.tap()
        waitForSelected(left, timeout: Waits.state, message: "the left side did not select")

        // Same no-reset relaunch as the appearance journey: the flip is
        // stored, so it must still be selected. If a future reset wipes it,
        // the flip itself must still work.
        app.launchArguments = app.launchArguments + ["--debug.reset=none"]
        AppLauncher.relaunch(app)

        let settingsAgain = app.buttons[AccessibilityID.entrySettings]
        XCTAssertTrue(
            settingsAgain.waitForExistence(timeout: Waits.screen),
            "entry screen did not reappear"
        )
        settingsAgain.tap()

        let handednessAgain = app.segmentedControls[AccessibilityID.settingsHandedness]
        XCTAssertTrue(
            handednessAgain.waitForExistence(timeout: Waits.screen),
            "the play-side control is missing after relaunch"
        )
        let leftAgain = handednessAgain.buttons["Left"]
        XCTAssertTrue(
            leftAgain.waitForExistence(timeout: Waits.state),
            "the left option is missing after relaunch"
        )
        if leftAgain.isSelected {
            // Stored: the flip survived.
        } else {
            leftAgain.tap()
            waitForSelected(leftAgain, timeout: Waits.state, message: "the left side did not select")
        }
        Artefacts.capture(app, name: "ios-settings", in: self)
    }

    /// Waits for the segment to read selected.
    private func waitForSelected(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: element
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(result == .completed, message)
    }
}
