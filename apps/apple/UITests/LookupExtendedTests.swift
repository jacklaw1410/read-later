import ReadLaterUI
import XCTest

/// Feature: Lookup (extended)
/// Ticket: [p2] Lookup-extended nightly journey
///
/// Scenario: Miss card and decline
///   Given a pasted article whose every word is unknown ("zxqv" repeated)
///   When the reader taps a word in the body
///   Then the miss card names that word
///   And tapping Not now closes the card and the reader remains
///
/// Point method: the document is one long paragraph of one repeated token, so
/// any tap in the paragraph body resolves to the same word. The test probes
/// up to three horizontal offsets at the paragraph mid-height; the first tap
/// that lands inside a token (not a space) opens the card.
final class LookupExtendedTests: XCTestCase {
    func test_missCardAndDecline() throws {
#if os(macOS)
        throw XCTSkip("tap-to-lookup gesture delivery is unreliable under XCUI on macOS; tracked separately")
#endif
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")

        let textMode = JourneySteps.textModeOption(app)
        XCTAssertTrue(textMode.waitForExistence(timeout: Waits.screen), "the Text mode option is missing")
        JourneySteps.tap(app, textMode)

        let raw = app.textViews[AccessibilityID.entryRawField]
        XCTAssertTrue(raw.waitForExistence(timeout: Waits.state), "the raw text field did not appear")
        JourneySteps.tap(app, raw)
        // "zxqv" is word-shaped but in neither the system dictionary (which
        // never answers on iOS) nor the demo pack, so every tap is a miss.
        // Eighty repetitions wrap a paragraph tall enough to cover the tap.
        raw.typeText(String(repeating: "zxqv ", count: 80))

        JourneySteps.dismissKeyboardIfPresent(app)
        JourneySteps.tap(app, open)

        let title = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
        XCTAssertTrue(
            title.waitForExistence(timeout: Waits.screen),
            "the pasted article did not open"
        )

        let wash = app.scrollViews[AccessibilityID.readerWash]
        XCTAssertTrue(wash.waitForExistence(timeout: Waits.screen), "the reader body did not appear")

        let miss = app.otherElements[AccessibilityID.missCard]
        var opened = false
        for dx in [0.5, 0.35, 0.65] {
            JourneySteps.front(app)
            #if os(macOS)
            wash.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).click()
            #else
            wash.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            #endif
            if miss.waitForExistence(timeout: Waits.state) {
                opened = true
                break
            }
        }
        XCTAssertTrue(opened, "the miss card did not open")

        let word = JourneySteps.texts(app, id: AccessibilityID.missWord)
        XCTAssertTrue(word.waitForExistence(timeout: Waits.state), "the card does not name the word")
        XCTAssertEqual(JourneySteps.displayed(word), "zxqv")

        let notNow = app.buttons[AccessibilityID.missNotNow]
        XCTAssertTrue(notNow.exists, "the Not now button is missing")
        JourneySteps.tap(app, notNow)

        XCTAssertTrue(
            miss.waitForNonExistence(timeout: Waits.state),
            "the miss card did not close"
        )
        XCTAssertTrue(
            JourneySteps.texts(app, id: AccessibilityID.readerTitle).exists,
            "the reader did not remain after declining"
        )
        Artefacts.capture(app, name: "ios-miss-declined", in: self)
    }
}
