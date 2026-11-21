import ReadLaterUI
import XCTest
#if os(macOS)
import AppKit
#endif

/// One phrasing for journey steps that differ by platform.
///
/// iOS exposes a segmented picker as a SegmentedControl of Buttons and menu
/// content as Buttons. macOS exposes a segmented picker as a RadioGroup of
/// RadioButtons and menu content as MenuItems. Identifiers and labels are
/// shared, so only the element type branches here. Queries branch; taps do
/// not: delivery is the runner's job.
enum JourneySteps {
    /// Opens the sample article from a fresh entry screen. A first click on
    /// an inactive macOS window can be swallowed by activation, so a tap
    /// that leaves the entry screen up is retried once.
    static func openSample(_ app: XCUIApplication) {
        let open = app.buttons[AccessibilityID.entryOpen]
        XCTAssertTrue(open.waitForExistence(timeout: Waits.screen), "entry screen did not appear")
        tap(app, open)
        #if os(macOS)
        if open.waitForExistence(timeout: 3) {
            JourneySteps.tap(app, open)
        }
        #endif
        XCTAssertTrue(
            JourneySteps.texts(app, id: AccessibilityID.readerTitle).waitForExistence(timeout: Waits.screen),
            "the article did not open"
        )
    }

    /// Text by identifier or label. On macOS a heading-trait text surfaces
    /// as AXHeading, which XCUI types as Other and never StaticText, so
    /// the query must be type-agnostic there. iOS keeps the typed query:
    /// every iOS caller names a StaticText, and the paste line is queried
    /// through its Button (`entryPaste`), never the inner label.
    static func texts(_ app: XCUIApplication, id: String) -> XCUIElement {
        #if os(macOS)
        app.descendants(matching: .any)[id]
        #else
        app.staticTexts[id]
        #endif
    }

    /// The string a Text element actually shows. macOS exposes heading-trait
    /// and some text elements via `value` with an empty `label`; iOS uses
    /// `label`. Prefer `label`, fall back to `value`.
    static func displayed(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    /// The accessibility value alone. Use it for a control whose `label`
    /// names the control and whose `value` carries the content, such as the
    /// reader clock.
    static func displayedValue(_ element: XCUIElement) -> String {
        (element.value as? String) ?? ""
    }

    /// Every tap routes through here. On macOS the tap synthesizes at
    /// screen coordinates, so the app must own the tap point: assert
    /// frontmost first and re-front until it is. A launch-time front is
    /// not enough; anything re-fronted later re-covers the window.
    static func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        front(app)
        #if os(macOS)
        // Wait for the element to become hittable after activation. A
        // click sent while the window is still activating is lost.
        let deadline = Date().addingTimeInterval(Waits.state)
        while Date() < deadline && !element.isHittable {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if element.isHittable {
            element.click()
        } else {
            // Fall back to the centre coordinate only when the element
            // stays non-hittable. Pin the window size in the app launch
            // so this coordinate stays stable.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        #else
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        #endif
    }

    /// Brings the app under test frontmost and waits until the window
    /// manager agrees. Matches by bundle URL, not identifier: a stale
    /// copy from another build directory shares the identifier and
    /// would satisfy an identifier check while stealing the tap.
    /// Elsewhere a no-op.
    static func front(_ app: XCUIApplication) {
        #if os(macOS)
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("ReadLater.app", isDirectory: true)
            .standardizedFileURL
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == appURL {
                return
            }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", appURL.path]
            try? open.run()
            Thread.sleep(forTimeInterval: 1)
        }
        #endif
    }

    /// Opens a library row by its title. The row button wraps the row text,
    /// so the query finds buttons containing the titled text. On macOS the
    /// title surfaces as a heading (Other), not a StaticText.
    static func openLibraryRow(_ app: XCUIApplication, title: String) {
        let library = app.buttons[AccessibilityID.entryLibrary]
        XCTAssertTrue(library.waitForExistence(timeout: Waits.screen), "the library button is missing")
        tap(app, library)
        #if os(macOS)
        let row = app.buttons.containing(.any, identifier: title).firstMatch
        #else
        let row = app.buttons.containing(.staticText, identifier: title).firstMatch
        #endif
        XCTAssertTrue(row.waitForExistence(timeout: Waits.screen), "no library row for \(title)")
        tap(app, row)
        XCTAssertTrue(
            texts(app, id: AccessibilityID.readerTitle).waitForExistence(timeout: Waits.screen),
            "the library row did not open"
        )
    }

    /// Dismisses the software keyboard when one is showing. macOS has no
    /// keyboard bar, so this is a no-op there.
    static func dismissKeyboardIfPresent(_ app: XCUIApplication) {
        #if os(iOS)
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        }
        #endif
    }

    /// A settings segmented picker: appearance or play side.
    static func settingsControl(_ app: XCUIApplication, id: String) -> XCUIElement {
        #if os(macOS)
        app.radioGroups[id]
        #else
        app.segmentedControls[id]
        #endif
    }

    /// One option inside a settings picker.
    static func settingsOption(in control: XCUIElement, label: String) -> XCUIElement {
        #if os(macOS)
        control.radioButtons[label]
        #else
        control.buttons[label]
        #endif
    }

    /// One row of the speed menu.
    static func speedChoice(_ app: XCUIApplication, label: String) -> XCUIElement {
        #if os(macOS)
        app.menuItems[label]
        #else
        app.buttons[label]
        #endif
    }
}
