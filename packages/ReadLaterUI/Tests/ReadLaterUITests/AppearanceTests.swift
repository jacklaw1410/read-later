import ReadLaterUI
import SwiftUI
import XCTest

/// The appearance choice is a stored string, so the mapping and the fallback
/// are the whole behaviour and both are testable without a view.
final class AppearanceTests: XCTestCase {
    func testSystemFollowsTheOS() {
        XCTAssertNil(Appearance.system.colorScheme)
    }

    func testPinnedValuesMapToAScheme() {
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
    }

    func testEveryCaseHasATitle() {
        for option in Appearance.allCases {
            XCTAssertFalse(option.title.isEmpty)
        }
    }

    func testStoredFallsBackToSystem() {
        let defaults = UserDefaults(suiteName: "AppearanceTests")!
        defaults.removePersistentDomain(forName: "AppearanceTests")
        XCTAssertEqual(Appearance.stored(in: defaults), .system)
        defaults.set("sepia", forKey: Appearance.storageKey)
        XCTAssertEqual(Appearance.stored(in: defaults), .system)
        defaults.set(Appearance.dark.rawValue, forKey: Appearance.storageKey)
        XCTAssertEqual(Appearance.stored(in: defaults), .dark)
        defaults.removePersistentDomain(forName: "AppearanceTests")
    }
}
