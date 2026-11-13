#if os(iOS)
import ReadLaterCore
@testable import ReadLaterUI
import UIKit
import XCTest

/// Regression for the reader-open crash on device. Two things were wrong in
/// `_WashedTextView`, and both are pinned here.
///
/// 1. `init(usingTextLayoutManager:)` left the subclass's stored properties
///    zeroed, so `washMarkList` held no array buffer and `bodyLength` held no
///    value. `makeWashView()` uses the frame and container initializer, which
///    does run the Swift defaults.
/// 2. The mark list setter compared the new list with the captured `oldValue`
///    inside a `didSet`. On this subclass that comparison read the bad buffer
///    (`_ArrayBuffer.count`, address `0x10`, SIGSEGV). `setWashMarks(_:)` keeps
///    the redraw guard without the captured array.
@MainActor
final class WashMarkListTests: XCTestCase {
    func testFactoryInitializesStoredProperties() {
        let view = _WashedTextView.makeWashView()
        XCTAssertTrue(view.washMarkList.isEmpty)
        XCTAssertEqual(view.bodyLength, 0)
    }

    func testFactoryIsTextKitOne() {
        let view = _WashedTextView.makeWashView()
        XCTAssertNotNil(view.layoutManager)
        XCTAssertNotNil(view.textContainer)
        XCTAssertNil(view.textLayoutManager)
    }

    func testFactoryLaysOutAndWraps() {
        let short = _WashedTextView.makeWashView()
        short.attributedText = NSAttributedString(
            string: "One word.",
            attributes: [.font: UIFont.systemFont(ofSize: 19)]
        )
        let long = _WashedTextView.makeWashView()
        let many = Array(repeating: "word", count: 200).joined(separator: " ")
        long.attributedText = NSAttributedString(
            string: many,
            attributes: [.font: UIFont.systemFont(ofSize: 19)]
        )
        let shortHeight = short.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
        let longHeight = long.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(shortHeight, 0)
        // 200 words at 300 pt wrap to many lines, so the box must grow.
        XCTAssertGreaterThan(longHeight, shortHeight * 5)
    }

    func testGlyphRectsAreAvailableForTheWashChip() {
        let view = _WashedTextView.makeWashView()
        view.attributedText = NSAttributedString(
            string: "chip me",
            attributes: [.font: UIFont.systemFont(ofSize: 19)]
        )
        let manager = view.layoutManager
        let container = view.textContainer
        manager.ensureLayout(for: container)
        let glyphRange = manager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 4),
            actualCharacterRange: nil
        )
        let box = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        XCTAssertGreaterThan(box.width, 0)
        XCTAssertGreaterThan(box.height, 0)
    }

    func testFirstMarkAssignmentOnAFreshView() {
        // The device crash was this exact call: the first marks for a block.
        let view = _WashedTextView.makeWashView()
        view.setWashMarks([WashMark(range: NSRange(location: 4, length: 2), emphasis: .paused)])
        XCTAssertEqual(view.washMarkList.count, 1)
    }

    func testSetWashMarksSurvivesRepeatedAssignment() {
        let view = _WashedTextView.makeWashView()
        let marks = [WashMark(range: NSRange(location: 0, length: 3), emphasis: .current)]
        view.setWashMarks(marks)
        XCTAssertEqual(view.washMarkList, marks)
        view.setWashMarks([])
        XCTAssertTrue(view.washMarkList.isEmpty)
        view.setWashMarks(marks)
        view.setWashMarks(marks)
        XCTAssertEqual(view.washMarkList, marks)
    }

    func testMarkEqualityAcrossEmphasis() {
        let a = WashMark(range: NSRange(location: 1, length: 2), emphasis: .paused)
        let b = WashMark(range: NSRange(location: 1, length: 2), emphasis: .paused)
        let c = WashMark(range: NSRange(location: 1, length: 2), emphasis: .current)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual([a], [b])
        XCTAssertNotEqual([a], [c])
    }
}
#endif
