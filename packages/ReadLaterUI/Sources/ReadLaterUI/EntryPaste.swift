import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UniformTypeIdentifiers
#endif

/// The paste rule for the entry screen: a pasted string either names a web
/// link the app can fetch, or it belongs in the field for the reader to fix.
///
/// Pure, so the decision is testable without a pasteboard. Only `http` and
/// `https` count: a bare host has no fetch target, and `file:` or `mailto:`
/// must never become a page request.
public enum EntryPaste {
    public static func openableLink(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return trimmed
    }

    /// The board text for the macOS paste button: the string flavor first,
    /// then a URL object without one (bare Copy Link, Universal Clipboard).
    /// macOS only: no permission prompt there. iOS keeps the system
    /// PasteButton, where a programmatic read would prompt and return nil.
    #if os(macOS)
    public static func appKitBoardText() -> String? {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string), !text.isEmpty {
            return text
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first
        {
            return url.absoluteString
        }
        return nil
    }
    #endif

    /// The board text for the iOS paste button: string flavor first, then a
    /// bare URL object (Copy Link / Universal Clipboard can hold public.url
    /// with no plain text — a String-only read silently ignores that tap).
    /// The provider owns the read, so iOS shows no permission prompt.
    #if !os(macOS)
    public static func loadFirstText(
        from providers: [NSItemProvider],
        deliver: @escaping @Sendable (String) -> Void
    ) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadObject(ofClass: NSString.self) { obj, _ in
                if let text = obj as? String, !text.isEmpty {
                    Task { @MainActor in deliver(text) }
                } else {
                    loadURL(from: provider, deliver: deliver)
                }
            }
        } else {
            loadURL(from: provider, deliver: deliver)
        }
    }

    private static func loadURL(
        from provider: NSItemProvider,
        deliver: @escaping @Sendable (String) -> Void
    ) {
        provider.loadObject(ofClass: NSURL.self) { obj, _ in
            if let url = obj as? URL {
                let text = url.absoluteString
                Task { @MainActor in deliver(text) }
            }
        }
    }
    #endif
}

/// What the B2-S detector sees in the field: empty, a fetchable link, or
/// pasted text. Pure, so tests cover it without a view.
public enum EntryKind: String, Sendable, CaseIterable {
    case empty
    case link
    case text
}

/// The B2-S strip classifier. Mirrors the selected prototype's detector:
/// an `http(s)` URL, or a bare domain/path with fewer than three words, is a
/// link; the rest is text. An empty field is empty. Every link fetches for
/// real — a login wall surfaces from extraction, never from a name check.
public enum EntryDetector {
    /// The kind of one field value, trimmed before reading.
    public static func classify(_ raw: String) -> EntryKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard isLink(trimmed) else { return .text }
        return .link
    }

    /// True for an `http(s)` URL with no whitespace, or a bare
    /// `domain/path` with fewer than three words.
    public static func isLink(_ trimmed: String) -> Bool {
        if trimmed.range(
            of: #"^https?://\S+$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count < 3,
              trimmed.range(
                  of: #"^[\w\-]+\.[\w.\-]+\/\S*$"#,
                  options: [.regularExpression, .caseInsensitive]
              ) != nil
        else {
            return false
        }
        return true
    }

    /// The host a link strip names. Bare `domain/path` reads through
    /// `https://`; anything unparseable shows the raw value.
    public static func domain(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let host = URL(string: candidate)?.host, !host.isEmpty {
            return host
        }
        return trimmed
    }

    /// The words of a pasted value, split on whitespace.
    public static func words(in raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The first `count` words, for the text strip's preview.
    public static func preview(of raw: String, count: Int = 6) -> String {
        words(in: raw).prefix(count).joined(separator: " ")
    }

    /// The fetch target for a link-kind value. A bare `domain/path` has no
    /// scheme to fetch, so it reads through `https://`.
    public static func linkTarget(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#,
            options: .regularExpression
        ) != nil {
            return trimmed
        }
        return "https://" + trimmed
    }
}
