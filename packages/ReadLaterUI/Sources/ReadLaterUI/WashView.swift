import Foundation
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

#if os(macOS)
import AppKit

/// One paragraph rendered in a non-editable NSTextView (TextKit 1).
/// SwiftUI Text cannot hit-test to a character, so taps resolve through
/// `layoutManager.characterIndex(for:)`, and the wash is drawn with
/// layout-manager temporary attributes (no view rebuild per word).
struct WashableParagraph: NSViewRepresentable {
    var text: String
    var wash: NSRange?
    var onTapWord: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: false)
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
        applyStyle(to: textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onTapWord = onTapWord
        if textView.string != text {
            applyStyle(to: textView)
        }
        context.coordinator.applyWash(wash, to: textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context _: Context) -> NSSize? {
        let width = proposal.width ?? Theme.maxLineWidth
        return nsView.fittingHeight(forWidth: width)
    }

    private func applyStyle(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Theme.bodyLineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.platformSerifBody,
            .foregroundColor: Theme.platformInk,
            .paragraphStyle: paragraph,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTapWord: ((String) -> Void)?

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? NSTextView,
                  let layoutManager = view.layoutManager,
                  let container = view.textContainer
            else { return }
            let point = gesture.location(in: view)
            let index = layoutManager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let nsText = view.string as NSString
            guard index < nsText.length, let (word, _) = wordAt(nsText, index: index) else { return }
            onTapWord?(word)
        }

        func applyWash(_ range: NSRange?, to view: NSTextView) {
            guard let layoutManager = view.layoutManager,
                  let storage = view.textStorage
            else { return }
            let full = NSRange(location: 0, length: storage.length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            guard let range, range.location != NSNotFound, range.length > 0,
                  NSMaxRange(range) <= storage.length
            else { return }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Theme.platformWashBackground, forCharacterRange: range)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.platformWashForeground, forCharacterRange: range)
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

/// One paragraph rendered in a non-editable UITextView (TextKit 1).
/// SwiftUI Text cannot hit-test to a character, so taps resolve through
/// `layoutManager.characterIndex(for:...)`, and the wash is drawn with
/// layout-manager temporary attributes (no view rebuild per word).
struct WashableParagraph: UIViewRepresentable {
    var text: String
    var wash: NSRange?
    var onTapWord: (String) -> Void

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
        applyStyle(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.view = textView
        context.coordinator.onTapWord = onTapWord
        if textView.text != text {
            applyStyle(to: textView)
        }
        context.coordinator.baseText = textView.attributedText
        context.coordinator.applyWash(wash)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? Theme.maxLineWidth
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(ceil(size.height), 24))
    }

    private func applyStyle(to textView: UITextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Theme.bodyLineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.platformSerifBody,
            .foregroundColor: Theme.platformInk,
            .paragraphStyle: paragraph,
        ]
        textView.attributedText = NSAttributedString(string: text, attributes: attributes)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: UITextView?
        var onTapWord: ((String) -> Void)?
        var baseText = NSAttributedString(string: "")

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let layoutManager = view.layoutManager
            let point = gesture.location(in: view)
            let container = view.textContainer
            let index = layoutManager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let nsText = (view.text ?? "") as NSString
            guard index < nsText.length, let (word, _) = wordAt(nsText, index: index) else { return }
            onTapWord?(word)
        }

        /// iOS NSLayoutManager has no temporary attributes, so the wash is
        /// applied by re-setting the view's attributed string from the stored
        /// base. This mutates the UIKit view only; no SwiftUI view rebuilds.
        func applyWash(_ range: NSRange?) {
            guard let view else { return }
            let mutable = NSMutableAttributedString(attributedString: baseText)
            if let range, range.location != NSNotFound, range.length > 0,
               NSMaxRange(range) <= mutable.length
            {
                mutable.addAttributes(
                    [.backgroundColor: Theme.platformWashBackground,
                     .foregroundColor: Theme.platformWashForeground],
                    range: range
                )
            }
            view.attributedText = mutable
        }
    }
}
#endif
