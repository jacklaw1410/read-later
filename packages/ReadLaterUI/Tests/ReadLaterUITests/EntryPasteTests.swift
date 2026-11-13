import ReadLaterCore
import ReadLaterUI
import XCTest

/// The paste rule is pure: a pasted string either names a web link the app can
/// open, or it does not. The view only moves the result into the field.
final class EntryPasteTests: XCTestCase {
    func testHTTPSLinkIsOpenable() {
        XCTAssertEqual(
            EntryPaste.openableLink(from: "https://example.com/article"),
            "https://example.com/article"
        )
    }

    func testHTTPLinkIsOpenable() {
        XCTAssertEqual(
            EntryPaste.openableLink(from: "  http://example.com  "),
            "http://example.com"
        )
    }

    func testLinkWithQueryAndFragmentIsKept() {
        let link = "https://example.com/a?b=1#c"
        XCTAssertEqual(EntryPaste.openableLink(from: link), link)
    }

    func testPastedProseIsNotOpenable() {
        XCTAssertNil(EntryPaste.openableLink(from: "A paragraph about reading."))
    }

    func testBareHostIsNotOpenable() {
        // No scheme means no fetch target, so the text goes to the field.
        XCTAssertNil(EntryPaste.openableLink(from: "example.com/article"))
    }

    func testNonWebSchemeIsNotOpenable() {
        XCTAssertNil(EntryPaste.openableLink(from: "file:///etc/passwd"))
        XCTAssertNil(EntryPaste.openableLink(from: "mailto:someone@example.com"))
    }

    func testEmptyAndWhitespaceAreNotOpenable() {
        XCTAssertNil(EntryPaste.openableLink(from: ""))
        XCTAssertNil(EntryPaste.openableLink(from: "   \n "))
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(
            EntryPaste.openableLink(from: "HTTPS://example.com/x"),
            "HTTPS://example.com/x"
        )
    }
}
