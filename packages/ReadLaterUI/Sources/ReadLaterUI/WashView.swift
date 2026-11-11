import Foundation
import ReadLaterCore
import SwiftUI

/// Position of the karaoke wash inside one block's text (UTF-16, block space).
public struct WashPosition: Hashable, Sendable {
    public var blockID: Int
    public var range: NSRange

    public init(blockID: Int, range: NSRange) {
        self.blockID = blockID
        self.range = range
    }
}

/// Finds the whole word token around a UTF-16 character index.
func wordAt(_ nsText: NSString, index: Int) -> (String, NSRange)? {
    guard index >= 0, index < nsText.length else { return nil }
    let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-\u{2019}"))
    func isWordChar(_ i: Int) -> Bool {
        guard i >= 0, i < nsText.length else { return false }
        return wordChars.contains(Unicode.Scalar(nsText.character(at: i)) ?? Unicode.Scalar(0))
    }
    guard isWordChar(index) else { return nil }
    var start = index
    while isWordChar(start - 1) { start -= 1 }
    var end = index
    while isWordChar(end + 1) { end += 1 }
    let range = NSRange(location: start, length: end - start + 1)
    return (nsText.substring(with: range), range)
}

/// Type roles for the platform text view. Only `body` carries the fixed
/// 19/31 line box the wash aligns to. The other roles render skipped or
/// ancillary text and never carry the wash.
public enum WashableTextStyle: Sendable, Hashable {
    case body
    case heading
    case note
    case small
}

/// Ink for the platform text view. Skipped blocks use reduced ink.
public enum WashableTextTone: Sendable, Hashable {
    case ink
    case skip
}

/// One marked range inside a text view, with the emphasis to draw.
struct WashMark: Hashable, Sendable {
    var range: NSRange
    var emphasis: WordEmphasis
}

/// Returns the marked ranges for one block: every slot whose emphasis is not
/// `none`. A block normally carries zero to two marks (current/paused word,
/// selected word).
func washMarks(slots: [WordSlot], wash: WashState) -> [WashMark] {
    slots.compactMap { slot in
        let emphasis = wash.emphasis(for: slot.index)
        guard emphasis.isMarked else { return nil }
        return WashMark(range: slot.range, emphasis: emphasis)
    }
}

/// Finds the tapped slot with the same rule as `SpokenIndex.word(inBlock:)`.
func slotAt(slots: [WordSlot], utf16Index: Int) -> WordSlot? {
    for slot in slots where utf16Index >= slot.range.location && utf16Index < NSMaxRange(slot.range) {
        return slot
    }
    return nil
}

/// One platform text view for a block of reader text.
///
/// The wash draws with temporary attributes (macOS) or with an
/// attributed-string swap of the changed ranges only (iOS). The base string
/// is built once per text change. The wash never changes layout: no font
/// change, no padding, no baseline shift.
public struct WashableText: View {
    private var text: String
    private var slots: [WordSlot]
    private var wash: WashState
    private var style: WashableTextStyle
    private var tone: WashableTextTone
    /// A footnote marker drawn as a superscript at the end of the text. It is
    /// display only: it never enters `Block.text`, so the wash ranges and the
    /// spoken plan cannot see it.
    private var marker: String?
    /// True when this block holds the word the voice is on and the reader has
    /// not taken the page over. The platform view then keeps that word in view
    /// itself; SwiftUI's `scrollTo` cannot address a word inside one block.
    private var followsWash: Bool
    private var onTapWord: (WordSlot?, String) -> Void
    private var onTapMarker: (() -> Void)?

    public init(
        text: String,
        slots: [WordSlot],
        wash: WashState,
        style: WashableTextStyle = .body,
        tone: WashableTextTone = .ink,
        marker: String? = nil,
        followsWash: Bool = false,
        onTapWord: @escaping (WordSlot?, String) -> Void,
        onTapMarker: (() -> Void)? = nil
    ) {
        self.text = text
        self.slots = slots
        self.wash = wash
        self.style = style
        self.tone = tone
        self.marker = marker
        self.followsWash = followsWash
        self.onTapWord = onTapWord
        self.onTapMarker = onTapMarker
    }

    public var body: some View {
        _WashableTextView(
            text: text,
            slots: slots,
            marks: washMarks(slots: slots, wash: wash),
            style: style,
            tone: tone,
            marker: marker,
            followsWash: followsWash,
            onTapWord: onTapWord,
            onTapMarker: onTapMarker
        )
    }
}

#if os(macOS)
import AppKit

extension NSColor {
    static func washHex(_ hex: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension Theme {
    static var platformPausedWash: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.washHex(0x4A4030) : NSColor.washHex(0xE8D9B0) }
    }

    static var platformPausedRing: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.washHex(0xC9A94E) : NSColor.washHex(0x8A6D1B) }
    }

    static var platformSelectionWash: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.washHex(0x2C4A66) : NSColor.washHex(0xDCE9F5) }
    }

    static var platformCoincidenceRing: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.washHex(0xF59E0B) : NSColor.washHex(0xB45309) }
    }

    /// Link and marker ink. The light value is the brand slate; the dark value
    /// is the lifted blue, so the marker stays visible on the dark page.
    static var platformBrandInk: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.washHex(0x7FB3D5) : NSColor.washHex(0x334E68) }
    }

    static var platformSkipInk: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.washHex(0xC9CDD2) : NSColor.washHex(0x191C1F) }
    }

    static func platformFont(for style: WashableTextStyle) -> NSFont {
        switch style {
        case .body:
            return Theme.platformSerifBody
        case .heading:
            let base = NSFont.systemFont(ofSize: 22, weight: .semibold)
            if let serif = base.fontDescriptor.withDesign(.serif), let font = NSFont(descriptor: serif, size: 22) {
                return font
            }
            return base
        case .note:
            return NSFont.systemFont(ofSize: 14, weight: .regular)
        case .small:
            return NSFont.systemFont(ofSize: 12, weight: .regular)
        }
    }
}

/// Temporary attributes for one emphasis. Temporary attributes change display
/// only, so the layout computed for the base string stays valid.
func temporaryAttributes(for emphasis: WordEmphasis) -> [NSAttributedString.Key: Any] {
    // Only the ink changes here. The wash itself is painted as a chip in
    // `_WashedTextView.drawBackground(in:)`, because a text background
    // attribute fills the whole 31 pt line box and turns a 19 pt word into a
    // slab. Temporary attributes must never change layout, and this set does
    // not.
    switch emphasis {
    case .current:
        return [.foregroundColor: Theme.platformWashForeground]
    case .paused, .selected, .coincide, .none:
        return [:]
    }
}

/// The chip behind one word: fill, and an inset ring when the state has one.
/// Source: prototype `.kw` rules (`background` plus `box-shadow: inset`).
/// The four states are told apart by fill and ring, never by alpha alone.
func washChip(for emphasis: WordEmphasis) -> (fill: NSColor, ring: NSColor?, ringWidth: CGFloat)? {
    switch emphasis {
    case .current:
        return (Theme.platformWashBackground, nil, 0)
    case .paused:
        // The prototype's grey amber with a 1.5 pt inset ring.
        return (Theme.platformPausedWash, Theme.platformPausedRing, 1.5)
    case .selected:
        return (Theme.platformSelectionWash, nil, 0)
    case .coincide:
        return (Theme.platformSelectionWash, Theme.platformCoincidenceRing, 2)
    case .none:
        return nil
    }
}

/// Keeps the wash word inside the enclosing scroll view. Free function so the
/// representable can call it without owning the subclass type.
@MainActor
func revealWash(in textView: NSTextView) {
    (textView as? _WashedTextView)?.revealWash()
}

/// An `NSTextView` that paints the wash itself.
///
/// TextKit's background attribute covers the full line fragment, so a 31 pt
/// line box gives a 31 pt highlight around a 19 pt word. Drawing the chip from
/// the glyph bounding rect gives the prototype's shape, keeps the layout
/// untouched, and lets the paused and coincidence states carry an edge rule.
final class _WashedTextView: NSTextView {
    var washMarkList: [WashMark] = [] {
        didSet {
            guard washMarkList != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Scrolls the enclosing scroll view so the wash word sits about 40 % down
    /// the viewport. Called from the block that currently holds the word, so
    /// only the visible block ever asks, and only when the reader is following.
    func revealWash(anchorFraction: CGFloat = 0.5) {
        guard let mark = washMarkList.first(where: { $0.emphasis == .current || $0.emphasis == .paused }),
              let layoutManager, let container = textContainer,
              let scrollView = enclosingScrollView,
              let document = scrollView.documentView
        else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
        var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        let inDocument = convert(box, to: document)

        let clip = scrollView.contentView.bounds
        let maxOffset = max(0, document.frame.height - clip.height)
        let target = inDocument.midY - clip.height * anchorFraction
        let y = min(max(target, 0), maxOffset)

        // A small dead band stops the page twitching on every word while the
        // wash moves inside the comfortable middle of the viewport.
        guard abs(y - clip.origin.y) > 32 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: clip.origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The chips go under the text. `drawBackground` runs after the glyphs on
    /// a non-editable `NSTextView`, so painting there hid the washed word under
    /// its own chip; overriding `draw` puts the wash behind the ink.
    override func draw(_ dirtyRect: NSRect) {
        drawWashChips(in: dirtyRect)
        super.draw(dirtyRect)
    }

    /// A width change re-lays the paragraph, and the chip is drawn from glyph
    /// rects. Without a repaint the wash keeps the box it computed at the old
    /// width, which is how a chip ends up beside its word.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func drawWashChips(in rect: NSRect) {
        guard let layoutManager, let container = textContainer, let storage = textStorage else { return }
        // Geometry queries below read the layout manager. Mid-scroll it can be
        // partially invalid, so force the paragraph out first.
        layoutManager.ensureLayout(for: container)
        let origin = textContainerOrigin

        for mark in washMarkList {
            guard mark.range.length > 0,
                  NSMaxRange(mark.range) <= storage.length,
                  let chip = washChip(for: mark.emphasis)
            else { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            let glyphBox = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard !glyphBox.isEmpty else { continue }

            let font = storage.attribute(.font, at: mark.range.location, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: 17)
            // The inline box, not the line box. A washed word is drawn from the
            // type's own ascent and descent, so a 19 pt word on a 31 pt line
            // gets a 23 pt chip. The line box would give a slab.
            //
            // The y comes from the glyph box because
            // `location(forGlyphAt:)` reports the baseline inside the line
            // fragment, not inside the container: on the fifth line it still
            // says 26, which put every chip on the first line.
            let height = font.ascender - font.descender
            let box = NSRect(
                x: glyphBox.minX + origin.x - 2,
                y: glyphBox.minY + origin.y + (glyphBox.height - height) / 2,
                width: glyphBox.width + 4,
                height: height
            )

            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            chip.fill.setFill()
            path.fill()

            if let ring = chip.ring {
                // An inset ring, as the prototype draws it: a shape cue that
                // survives greyscale, so which word holds the voice never
                // depends on telling amber from grey amber.
                let width = chip.ringWidth
                let inner = NSBezierPath(
                    roundedRect: box.insetBy(dx: width / 2, dy: width / 2),
                    xRadius: 4,
                    yRadius: 4
                )
                ring.setStroke()
                inner.lineWidth = width
                inner.stroke()
            }

            if mark.emphasis == .paused {
                drawDottedUnderline(in: NSRect(
                    x: box.minX + 3,
                    y: box.minY,
                    width: box.width - 6,
                    height: box.height
                ), colour: Theme.platformPausedRing, baseline: box.maxY)
            }
        }
    }

    /// The paused state's second non-colour cue, in place of a text underline
    /// attribute: a dotted rule under the word.
    private func drawDottedUnderline(in box: NSRect, colour: NSColor, baseline: CGFloat) {
        colour.setFill()
        let y = baseline - 1
        var x = box.minX
        while x < box.maxX {
            NSRect(x: x, y: y, width: 1.5, height: 1.5).fill()
            x += 4
        }
    }
}

/// One paragraph in a non-editable NSTextView (TextKit 1).
struct _WashableTextView: NSViewRepresentable {
    var text: String
    var slots: [WordSlot]
    var marks: [WashMark]
    var style: WashableTextStyle
    var tone: WashableTextTone
    var marker: String?
    var followsWash: Bool
    var onTapWord: (WordSlot?, String) -> Void
    var onTapMarker: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let textView = _WashedTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        textView.addGestureRecognizer(click)
        context.coordinator.onTapWord = onTapWord
        context.coordinator.onTapMarker = onTapMarker
        context.coordinator.bodyLength = (text as NSString).length
        applyBaseStyle(to: textView)
        context.coordinator.lastText = text
        context.coordinator.lastStyle = style
        context.coordinator.lastTone = tone
        context.coordinator.slots = slots
        textView.washMarkList = marks
        context.coordinator.applyMarks(marks, to: textView)
        if followsWash {
            DispatchQueue.main.async { revealWash(in: textView) }
        }
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onTapWord = onTapWord
        context.coordinator.onTapMarker = onTapMarker
        context.coordinator.bodyLength = (text as NSString).length
        context.coordinator.slots = slots
        if context.coordinator.lastText != text
            || context.coordinator.lastStyle != style
            || context.coordinator.lastTone != tone
        {
            applyBaseStyle(to: textView)
            context.coordinator.lastText = text
            context.coordinator.lastStyle = style
            context.coordinator.lastTone = tone
            context.coordinator.lastMarks = []
        }
        context.coordinator.applyMarks(marks, to: textView)
        if followsWash, marks != context.coordinator.lastRevealedMarks {
            context.coordinator.lastRevealedMarks = marks
            DispatchQueue.main.async { revealWash(in: textView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context _: Context) -> NSSize? {
        let width = proposal.width ?? Theme.maxLineWidth
        return nsView.fittingHeight(forWidth: width)
    }

    private func applyBaseStyle(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        if style == .body {
        // Fixed 31 pt line box, no extra line spacing on top of it.
        paragraph.lineSpacing = 0
        paragraph.minimumLineHeight = ReaderMetrics.bodyLineHeight
        paragraph.maximumLineHeight = ReaderMetrics.bodyLineHeight
        }
        let ink = tone == .skip ? Theme.platformSkipInk : Theme.platformInk
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.platformFont(for: style),
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
        ]
        let built = NSMutableAttributedString(string: text, attributes: attributes)
        if let marker, !marker.isEmpty {
            // A thin space keeps the superscript off the final full stop
            // without changing the word before it.
            let superscript: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(10, ReaderMetrics.bodySize - 8), weight: .semibold),
                .foregroundColor: Theme.platformBrandInk,
                .baselineOffset: 7,
                .paragraphStyle: paragraph,
            ]
            built.append(NSAttributedString(string: "\u{2009}" + marker, attributes: superscript))
        }
        textView.textStorage?.setAttributedString(built)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTapWord: ((WordSlot?, String) -> Void)?
        var onTapMarker: (() -> Void)?
        /// UTF-16 length of the block text, without the marker suffix.
        var bodyLength = 0
        var slots: [WordSlot] = []
        var lastText: String?
        var lastStyle: WashableTextStyle?
        var lastTone: WashableTextTone?
        var lastMarks: [WashMark] = []
        var lastRevealedMarks: [WashMark] = []

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? NSTextView,
                  let layoutManager = view.layoutManager,
                  let container = view.textContainer
            else { return }
            let point = gesture.location(in: view)
            let index = layoutManager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            // Past the body is the footnote marker, which is a target, not a
            // word. Checked before the word scan so the tap cannot fall through.
            if index >= bodyLength {
                if onTapMarker != nil { onTapMarker?() }
                return
            }
            let nsText = view.string as NSString
            guard let (word, _) = wordAt(nsText, index: index) else { return }
            onTapWord?(slotAt(slots: slots, utf16Index: index), word)
        }

        /// Clears and reapplies the whole ink set.
        ///
        /// An incremental diff left the previous word amber whenever two
        /// updates arrived in one run-loop turn, because the "which marks went
        /// away" test compared against a list that had already moved on. A
        /// paragraph is a few hundred characters, so a full reset costs nothing
        /// and cannot go stale.
        func applyMarks(_ marks: [WashMark], to view: NSTextView) {
            guard marks != lastMarks,
                  let layoutManager = view.layoutManager,
                  let storage = view.textStorage
            else { return }
            let length = storage.length
            layoutManager.removeTemporaryAttribute(
                .foregroundColor,
                forCharacterRange: NSRange(location: 0, length: length)
            )
            for mark in marks {
                guard mark.range.length > 0, NSMaxRange(mark.range) <= length else { continue }
                for (key, value) in temporaryAttributes(for: mark.emphasis) {
                    layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: mark.range)
                }
            }
            lastMarks = marks
            (view as? _WashedTextView)?.washMarkList = marks

        }
    }
}

private extension NSTextView {
    func fittingHeight(forWidth width: CGFloat) -> NSSize {
        guard let container = textContainer, let layoutManager = layoutManager else {
            return NSSize(width: width, height: 40)
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        return NSSize(width: width, height: max(height, 24))
    }
}

#else
import UIKit

extension UIColor {
    static func washHex(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension Theme {
    static var platformPausedWash: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.washHex(0x4A4030) : UIColor.washHex(0xE8D9B0) }
    }

    static var platformPausedRing: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.washHex(0xC9A94E) : UIColor.washHex(0x8A6D1B) }
    }

    static var platformSelectionWash: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.washHex(0x2C4A66) : UIColor.washHex(0xDCE9F5) }
    }

    static var platformCoincidenceRing: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.washHex(0xF59E0B) : UIColor.washHex(0xB45309) }
    }

    static var platformBrandInk: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.washHex(0x7FB3D5) : UIColor.washHex(0x334E68) }
    }

    static var platformSkipInk: UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.washHex(0xC9CDD2) : UIColor.washHex(0x191C1F) }
    }

    static func platformFont(for style: WashableTextStyle) -> UIFont {
        switch style {
        case .body:
            return Theme.platformSerifBody
        case .heading:
            let base = UIFont.systemFont(ofSize: 22, weight: .semibold)
            if let serif = base.fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: serif, size: 22)
            }
            return base
        case .note:
            return UIFont.systemFont(ofSize: 14, weight: .regular)
        case .small:
            return UIFont.systemFont(ofSize: 12, weight: .regular)
        }
    }
}

/// Attributes for one emphasis. Applied to the changed ranges only; the base
/// string stays cached in the coordinator.
func washAttributes(for emphasis: WordEmphasis) -> [NSAttributedString.Key: Any] {
    switch emphasis {
    case .none:
        return [:]
    case .current:
        return [
            .backgroundColor: Theme.platformWashBackground,
            .foregroundColor: Theme.platformWashForeground,
        ]
    case .paused:
        return [
            .backgroundColor: Theme.platformPausedWash,
            .foregroundColor: Theme.platformInk,
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: Theme.platformPausedRing,
        ]
    case .selected:
        return [.backgroundColor: Theme.platformSelectionWash]
    case .coincide:
        return [
            .backgroundColor: Theme.platformSelectionWash,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: Theme.platformCoincidenceRing,
        ]
    }
}

/// One paragraph in a non-editable UITextView (TextKit 1).
struct _WashableTextView: UIViewRepresentable {
    var text: String
    var slots: [WordSlot]
    var marks: [WashMark]
    var style: WashableTextStyle
    var tone: WashableTextTone
    var marker: String?
    var followsWash: Bool
    var onTapWord: (WordSlot?, String) -> Void
    var onTapMarker: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        textView.addGestureRecognizer(tap)
        context.coordinator.view = textView
        context.coordinator.onTapWord = onTapWord
        context.coordinator.onTapMarker = onTapMarker
        context.coordinator.slots = slots
        context.coordinator.rebuildBase(text: text, style: style, tone: tone)
        textView.attributedText = context.coordinator.baseText
        context.coordinator.applyMarks(marks)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.view = textView
        context.coordinator.onTapWord = onTapWord
        context.coordinator.onTapMarker = onTapMarker
        context.coordinator.bodyLength = (text as NSString).length
        context.coordinator.slots = slots
        if context.coordinator.lastText != text
            || context.coordinator.lastStyle != style
            || context.coordinator.lastTone != tone
        {
            context.coordinator.rebuildBase(text: text, style: style, tone: tone)
            textView.attributedText = context.coordinator.baseText
            context.coordinator.lastMarks = []
        }
        context.coordinator.applyMarks(marks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? Theme.maxLineWidth
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(ceil(size.height), 24))
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: UITextView?
        var onTapWord: ((WordSlot?, String) -> Void)?
        var onTapMarker: (() -> Void)?
        /// UTF-16 length of the block text, without the marker suffix.
        var bodyLength = 0
        var slots: [WordSlot] = []
        var baseText = NSAttributedString(string: "")
        var lastText: String?
        var lastStyle: WashableTextStyle?
        var lastTone: WashableTextTone?
        var lastMarks: [WashMark] = []

        func rebuildBase(text: String, style: WashableTextStyle, tone: WashableTextTone) {
            defer { bodyLength = (text as NSString).length }
            let paragraph = NSMutableParagraphStyle()
            if style == .body {
            // The line box is fixed at 31 pt, so the leading is the
            // difference between the type size and that box. Setting
            // `lineSpacing` as well would add it on top and open the
            // paragraph to 43 pt, which is not the prototype's rhythm.
            paragraph.lineSpacing = 0
            paragraph.minimumLineHeight = ReaderMetrics.bodyLineHeight
            paragraph.maximumLineHeight = ReaderMetrics.bodyLineHeight
            }
            let ink = tone == .skip ? Theme.platformSkipInk : Theme.platformInk
            let built = NSMutableAttributedString(string: text, attributes: [
                .font: Theme.platformFont(for: style),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ])
            if let marker, !marker.isEmpty {
                built.append(NSAttributedString(string: "\u{2009}" + marker, attributes: [
                    .font: UIFont.systemFont(ofSize: max(10, ReaderMetrics.bodySize - 8), weight: .semibold),
                    .foregroundColor: Theme.platformBrandInk,
                    .baselineOffset: 7,
                    .paragraphStyle: paragraph,
                ]))
            }
            baseText = built
            lastText = text
            lastStyle = style
            lastTone = tone
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let layoutManager = view.layoutManager
            let point = gesture.location(in: view)
            let container = view.textContainer
            let index = layoutManager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if index >= bodyLength {
                if onTapMarker != nil { onTapMarker?() }
                return
            }
            let nsText = (view.text ?? "") as NSString
            guard let (word, _) = wordAt(nsText, index: index) else { return }
            onTapWord?(slotAt(slots: slots, utf16Index: index), word)
        }

        /// Restores the changed-away ranges to the cached base, then applies
        /// the new marks. Untouched ranges keep their laid-out storage.
        func applyMarks(_ marks: [WashMark]) {
            guard let view, marks != lastMarks else { return }
            let storage = view.textStorage
            guard storage.length == baseText.length else {
                lastMarks = marks
                return
            }
            for mark in lastMarks where !marks.contains(mark) {
                baseText.enumerateAttributes(in: mark.range, options: []) { attributes, subrange, _ in
                    storage.setAttributes(attributes, range: subrange)
                }
            }
            for mark in marks where !lastMarks.contains(mark) {
                storage.addAttributes(washAttributes(for: mark.emphasis), range: mark.range)
            }
            lastMarks = marks
        }
    }
}
#endif
