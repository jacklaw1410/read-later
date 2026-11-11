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
    private var onTapWord: (WordSlot?, String) -> Void

    public init(
        text: String,
        slots: [WordSlot],
        wash: WashState,
        style: WashableTextStyle = .body,
        tone: WashableTextTone = .ink,
        onTapWord: @escaping (WordSlot?, String) -> Void
    ) {
        self.text = text
        self.slots = slots
        self.wash = wash
        self.style = style
        self.tone = tone
        self.onTapWord = onTapWord
    }

    public var body: some View {
        _WashableTextView(
            text: text,
            slots: slots,
            marks: washMarks(slots: slots, wash: wash),
            style: style,
            tone: tone,
            onTapWord: onTapWord
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

/// The chip behind one word. Rounded, tight to the glyphs, with the state's
/// edge rule drawn inside its bottom edge. The four states are told apart by
/// fill and edge, never by alpha alone.
func washChip(for emphasis: WordEmphasis) -> (fill: NSColor, edge: NSColor?, edgeWidth: CGFloat)? {
    switch emphasis {
    case .current:
        return (Theme.platformWashBackground, nil, 0)
    case .paused:
        return (Theme.platformPausedWash, Theme.platformPausedRing, 2)
    case .selected:
        return (Theme.platformSelectionWash, nil, 0)
    case .coincide:
        return (Theme.platformSelectionWash, Theme.platformCoincidenceRing, 2)
    case .none:
        return nil
    }
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let container = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin

        for mark in washMarkList {
            guard mark.range.length > 0,
                  NSMaxRange(mark.range) <= storage.length,
                  let chip = washChip(for: mark.emphasis)
            else { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            let glyphBox = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard !glyphBox.isEmpty else { continue }

            // Two points of horizontal breathing room, one above and below:
            // the prototype's `padding: 1px 2px`.
            let box = NSRect(
                x: glyphBox.minX + origin.x - 2,
                y: glyphBox.minY + origin.y - 1,
                width: glyphBox.width + 4,
                height: glyphBox.height + 2
            )
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)

            if let edge = chip.edge {
                // The edge rule is the non-colour cue: it survives greyscale
                // and a colour-blind reader still sees where the voice stopped.
                chip.fill.setFill()
                path.fill()
                edge.setFill()
                NSRect(x: box.minX, y: box.maxY - chip.edgeWidth, width: box.width, height: chip.edgeWidth).fill()
            } else {
                chip.fill.setFill()
                path.fill()
            }
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
    var onTapWord: (WordSlot?, String) -> Void

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
        applyBaseStyle(to: textView)
        context.coordinator.lastText = text
        context.coordinator.lastStyle = style
        context.coordinator.lastTone = tone
        context.coordinator.slots = slots
        textView.washMarkList = marks
        context.coordinator.applyMarks(marks, to: textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onTapWord = onTapWord
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
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTapWord: ((WordSlot?, String) -> Void)?
        var slots: [WordSlot] = []
        var lastText: String?
        var lastStyle: WashableTextStyle?
        var lastTone: WashableTextTone?
        var lastMarks: [WashMark] = []

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? NSTextView,
                  let layoutManager = view.layoutManager,
                  let container = view.textContainer
            else { return }
            let point = gesture.location(in: view)
            let index = layoutManager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let nsText = view.string as NSString
            guard let (word, _) = wordAt(nsText, index: index) else { return }
            onTapWord?(slotAt(slots: slots, utf16Index: index), word)
        }

        func applyMarks(_ marks: [WashMark], to view: NSTextView) {
            guard marks != lastMarks,
                  let layoutManager = view.layoutManager,
                  let storage = view.textStorage
            else { return }
            let length = storage.length
            for mark in lastMarks where !marks.contains(mark) {
                guard NSMaxRange(mark.range) <= length else { continue }
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: mark.range)
            }
            for mark in marks where !lastMarks.contains(mark) {
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
    var onTapWord: (WordSlot?, String) -> Void

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
        context.coordinator.slots = slots
        context.coordinator.rebuildBase(text: text, style: style, tone: tone)
        textView.attributedText = context.coordinator.baseText
        context.coordinator.applyMarks(marks)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.view = textView
        context.coordinator.onTapWord = onTapWord
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
        var slots: [WordSlot] = []
        var baseText = NSAttributedString(string: "")
        var lastText: String?
        var lastStyle: WashableTextStyle?
        var lastTone: WashableTextTone?
        var lastMarks: [WashMark] = []

        func rebuildBase(text: String, style: WashableTextStyle, tone: WashableTextTone) {
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
            baseText = NSAttributedString(string: text, attributes: [
                .font: Theme.platformFont(for: style),
                .foregroundColor: ink,
                .paragraphStyle: paragraph,
            ])
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
