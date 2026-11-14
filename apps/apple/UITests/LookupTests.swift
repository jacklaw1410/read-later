import ReadLaterUI
import XCTest

/// Feature: Lookup
/// Ticket: [e2e] Tap a word and read the gloss
///
/// Scenario: Tap a known word
///   Given the sample article is showing
///   And the reader scrolled to the second prose paragraph
///   When I tap the word "susurrus"
///   Then the lookup card names that word
///   And the card shows a gloss with a Chinese character
final class LookupTests: XCTestCase {
    func test_tapWordShowsTheGloss() throws {
#if os(macOS)
        throw XCTSkip("tap-to-lookup gesture delivery is unreliable under XCUI on macOS; tracked separately")
#endif
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        JourneySteps.tap(app, open)

        let wash = app.scrollViews[AccessibilityID.readerWash]
        XCTAssertTrue(wash.waitForExistence(timeout: Waits.screen), "the reader body did not appear")

        let card = app.otherElements[AccessibilityID.lookupCard]
        let word = JourneySteps.texts(app, id: AccessibilityID.lookupWord)
        // Measured before the scroll. The hold badge can shorten the scroll
        // area after the drag, and the tap point must not move with it.

        // Scroll the second prose paragraph into view. Slow, with a hold at the
        // end: no fling, so the offset change is the drag distance on every
        // run. Measured offset change: 433 pt.
        let start = wash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let end = wash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)

        // A card from the release would swallow the measured tap. Close one
        // only if the drag was read as a tap.
        let close = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Close")
        ).firstMatch
        if close.exists {
            JourneySteps.tap(app, close)
            XCTAssertTrue(
                close.waitForNonExistence(timeout: Waits.state),
                "the card left by the scroll did not close"
            )
        }

        // "susurrus" is on the sixth line of that paragraph. Measured point on
        // an iPhone 16, whose reader is 393 pt wide: (270, 665), which is 0.687
        // across the wash frame and 0.917 down it.
        var opened = false
        for dx in [0.687, 0.5, 0.3, 0.75] {
            for dy in [0.917, 0.85, 0.75, 0.6] {
                JourneySteps.front(app)
                let tapCoord = wash.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
                #if os(macOS)
                tapCoord.click()
                #else
                tapCoord.tap()
                #endif
                if card.waitForExistence(timeout: Waits.state) {
                    if JourneySteps.displayed(word) == "susurrus" {
                        opened = true
                        break
                    }
                    // close and try next
                    let closeBtn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close")).firstMatch
                    if closeBtn.exists { JourneySteps.tap(app, closeBtn) }
                    _ = card.waitForNonExistence(timeout: Waits.state)
                }
            }
            if opened { break }
        }
        XCTAssertTrue(opened, "the lookup card did not open for susurrus")

        XCTAssertEqual(JourneySteps.displayed(word), "susurrus")

        let gloss = JourneySteps.texts(app, id: AccessibilityID.lookupGloss)
        XCTAssertTrue(gloss.waitForExistence(timeout: Waits.state), "the card carries no gloss")
        XCTAssertNotNil(
            JourneySteps.displayed(gloss).range(of: "\\p{Han}", options: .regularExpression),
            "the gloss has no Chinese character: \(JourneySteps.displayed(gloss))"
        )
        Artefacts.capture(app, name: "ios-gloss", in: self)
    }
}
