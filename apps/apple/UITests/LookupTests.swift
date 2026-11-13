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
    func test_tapWordShowsTheGloss() {
        let app = AppLauncher.launch()

        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        open.tap()

        let wash = app.scrollViews[AccessibilityID.readerWash]
        XCTAssertTrue(wash.waitForExistence(timeout: Waits.screen), "the reader body did not appear")
        // Measured before the scroll. The hold badge can shorten the scroll
        // area after the drag, and the tap point must not move with it.
        let frame = wash.frame

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
            close.tap()
            XCTAssertTrue(
                close.waitForNonExistence(timeout: Waits.state),
                "the card left by the scroll did not close"
            )
        }

        // "susurrus" is on the sixth line of that paragraph. Measured point on
        // an iPhone 16, whose reader is 393 pt wide: (270, 665), which is 0.687
        // across the wash frame and 0.917 down it.
        let point = CGVector(
            dx: frame.minX + frame.width * 0.687,
            dy: frame.minY + frame.height * 0.917
        )
        app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()

        let card = app.otherElements[AccessibilityID.lookupCard]
        XCTAssertTrue(card.waitForExistence(timeout: Waits.state), "the lookup card did not open")

        let word = app.staticTexts[AccessibilityID.lookupWord]
        XCTAssertTrue(word.waitForExistence(timeout: Waits.state), "the card does not name the word")
        XCTAssertEqual(word.label, "susurrus")

        let gloss = app.staticTexts[AccessibilityID.lookupGloss]
        XCTAssertTrue(gloss.waitForExistence(timeout: Waits.state), "the card carries no gloss")
        XCTAssertNotNil(
            gloss.label.range(of: "\\p{Han}", options: .regularExpression),
            "the gloss has no Chinese character: \(gloss.label)"
        )
        Artefacts.capture(app, name: "ios-gloss", in: self)
    }
}
