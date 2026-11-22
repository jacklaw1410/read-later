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

        func dismissLookupCardIfPresent() {
            for prefix in ["Close", "Not now"] {
                let button = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", prefix)
                ).firstMatch
                if button.exists {
                    JourneySteps.tap(app, button)
                    _ = card.waitForNonExistence(timeout: Waits.state)
                    _ = app.otherElements[AccessibilityID.missCard].waitForNonExistence(timeout: Waits.state)
                }
            }
        }

        // The target word is in the second prose paragraph. Scroll in short
        // steps and scan the wash after each step. The exact point moves with
        // layout, so the scan covers the visible text area instead of relying
        // on one measured coordinate.
        var opened = false
        for scroll in 0..<4 {
            if scroll > 0 {
                let start = wash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                let end = wash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
                dismissLookupCardIfPresent()
            }

            for dy in stride(from: 0.25, through: 0.9, by: 0.08) {
                for dx in [0.2, 0.35, 0.5, 0.65, 0.8] {
                    JourneySteps.front(app)
                    let tapCoord = wash.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
                    #if os(macOS)
                    tapCoord.click()
                    #else
                    tapCoord.tap()
                    #endif
                    if card.waitForExistence(timeout: 0.8) {
                        if JourneySteps.displayed(word) == "susurrus" {
                            opened = true
                            break
                        }
                        dismissLookupCardIfPresent()
                    } else if app.otherElements[AccessibilityID.missCard].exists {
                        dismissLookupCardIfPresent()
                    }
                }
                if opened { break }
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
        let pronounce = app.buttons[AccessibilityID.lookupPronounce]
        XCTAssertTrue(pronounce.exists, "the hit card has no pronounce control")
        JourneySteps.tap(app, pronounce)
        XCTAssertTrue(card.exists, "pronounce closed the card; it must leave the card open")
        Artefacts.capture(app, name: "ios-gloss", in: self)
    }
}
