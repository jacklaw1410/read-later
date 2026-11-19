import ReadLaterCore
import ReadLaterUI
import XCTest
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

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

    func testXComLinkIsOpenableAtPasteLayer() {
        // Every link fetches for real now: the paste rule accepts the link
        // and a genuine wall surfaces from extraction, not a name check.
        XCTAssertEqual(
            EntryPaste.openableLink(from: "https://x.com/someone/status/123"),
            "https://x.com/someone/status/123"
        )
    }

    func testBareHostNeedsSchemeEvenWhenShort() {
        // The <3-word domain rule lives in classify; the paste rule needs a
        // scheme, so a bare host never opens from paste.
        XCTAssertNil(EntryPaste.openableLink(from: "example.com/article"))
        XCTAssertNil(EntryPaste.openableLink(from: "example.com/a b"))
    }
}

/// One clipboard item decodes to text. Pure, so no pasteboard is needed.
final class EntryPasteItemTests: XCTestCase {
    /// Minimal RTF bytes: font table, one sized run, no markup in the text.
    private static let rtfBytes = Data(
        #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs28 https://example.com/article}"#.utf8
    )

    func testStringIsDelivered() {
        XCTAssertEqual(EntryPaste.text(fromItem: "A paragraph."), "A paragraph.")
    }

    func testEmptyStringIsNil() {
        XCTAssertNil(EntryPaste.text(fromItem: ""))
    }

    func testPlainDataIsDecoded() {
        XCTAssertEqual(
            EntryPaste.text(fromItem: Data("https://example.com".utf8)),
            "https://example.com"
        )
    }

    func testURLIsAbsolute() {
        XCTAssertEqual(
            EntryPaste.text(fromItem: URL(string: "https://example.com/a?b=1")!),
            "https://example.com/a?b=1"
        )
    }

    func testRTFStripsToPlainText() {
        XCTAssertEqual(
            EntryPaste.text(fromItem: Self.rtfBytes),
            "https://example.com/article"
        )
    }

    func testAttributedStringStripsToPlainText() {
        #if canImport(AppKit)
        let color: Any = NSColor.red
        #else
        let color: Any = UIColor.red
        #endif
        let attributed = NSAttributedString(
            string: "A paragraph.",
            attributes: [.foregroundColor: color]
        )
        XCTAssertEqual(EntryPaste.text(fromItem: attributed), "A paragraph.")
    }

    func testJunkYieldsNothing() {
        XCTAssertNil(EntryPaste.text(fromItem: NSObject()))
    }

    func testMalformedRTFYieldsNothing() {
        // A truncated header carries no content: nil, never the markup.
        XCTAssertNil(EntryPaste.text(fromItem: Data("{\\rtf".utf8)))
    }
}
