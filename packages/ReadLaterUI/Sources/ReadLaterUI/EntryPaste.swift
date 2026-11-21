import Foundation
import ReadLaterCore
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UniformTypeIdentifiers
import UIKit
#endif

/// The paste rule for the entry screen: a pasted string either names a web
/// link the app can fetch, or it belongs in the field for the reader to fix.
///
/// Pure, so the decision is testable without a pasteboard. Only `http` and
/// `https` count: a bare host has no fetch target, and `file:` or `mailto:`
/// must never become a page request.
public enum EntryPaste {
    /// First bytes of every RTF document (`{\rtf`). Only data starting
    /// this way is tried as RTF; anything else decodes as UTF-8.
    private static let rtfHeader = Data([0x7B, 0x5C, 0x72, 0x74, 0x66])

    /// Strict RTF decode: plain text on success, nil on parse failure or
    /// empty content. Never the raw markup.
    private static func rtfText(_ data: Data) -> String? {
        guard let rich = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ), !rich.string.isEmpty else { return nil }
        return rich.string
    }

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

    /// The text of one decoded clipboard item: a string, plain-text or RTF
    /// data, an attributed string, or a URL. Nil when none of them yield
    /// text. Pure, so tests decode without a pasteboard.
    public static func text(fromItem item: Any) -> String? {
        switch item {
        case let string as String:
            return string.isEmpty ? nil : string
        case let attributed as NSAttributedString:
            let string = attributed.string
            return string.isEmpty ? nil : string
        case let url as URL:
            return url.absoluteString
        case let data as Data:
            // RTF and friends carry styles the link field does not want,
            // so the rich decode strips them to plain text. Data that is
            // not RTF decodes as UTF-8. Malformed RTF gives nil, never its
            // markup.
            if data.starts(with: rtfHeader) {
                return rtfText(data)
            }
            let plain = String(decoding: data, as: UTF8.self)
            return plain.isEmpty ? nil : plain
        default:
            return nil
        }
    }

    /// The board text for the macOS paste button: the string flavor first,
    /// then RTF data without one, then a URL object without either (bare
    /// Copy Link, Universal Clipboard). macOS only: no permission prompt
    /// there.
    #if os(macOS)
    public static func appKitBoardText() -> String? {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string), !text.isEmpty {
            return text
        }
        if let rtf = board.data(forType: .rtf),
           let text = text(fromItem: rtf), !text.isEmpty
        {
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

    /// Records one `paste.*` event through `TelemetryHub`.
    private static func diag(_ telemetry: TelemetryHub, _ name: String, _ fields: [String: String] = [:]) {
        telemetry.record(name, fields: fields)
    }

    #if !os(macOS)
    /// How long a missed read polls while the native paste prompt may be up.
    /// Reads may return nil until the user answers. An answer after this
    /// wait may land on the next tap.
    private static let promptWait: TimeInterval = 6

    /// The iOS paste button reads the board directly: string flavor first,
    /// then RTF data, then a bare URL object.
    ///
    /// A plain Button owns the tap. Hypothesis, not yet confirmed on a
    /// device: a direct board read shows the native "would like to paste
    /// from" prompt when the app's paste permission is Ask. The read polls
    /// for `promptWait` seconds because reads may return nil while the
    /// prompt is up. `fail` fires when the poll runs out, and the blocked
    /// note shows. A silent miss would read as a broken button.
    ///
    /// Each tap records `paste.tap`. The `paste.*` oplog events record the
    /// branch taken and the result. They may help diagnose a device denial.
    public static func pasteFromBoard(
        telemetry: TelemetryHub,
        deliver: @escaping @Sendable (String) -> Void,
        fail: @escaping @Sendable () -> Void
    ) {
        diag(telemetry, "paste.tap", ["source": "button"])
        readBoardWithPrompt(telemetry: telemetry, deliver: deliver, fail: fail)
    }

    private static func readBoardWithPrompt(
        telemetry: TelemetryHub,
        deliver: @escaping @Sendable (String) -> Void,
        fail: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(promptWait)
            while Date() < deadline {
                if let text = EntryPaste.boardText() {
                    diag(telemetry, "paste.delivered", [
                        "branch": "prompt",
                        "chars": String(text.count),
                    ])
                    deliver(text)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            diag(telemetry, "paste.blocked")
            // Flush at once: the test runner and a dying app may never
            // hit a lifecycle hook, and a Deny outcome must survive.
            telemetry.flush()
            fail()
        }
    }

    /// One direct board read: the string flavor first, then RTF data,
    /// then a bare URL object. Nil when the app may not read or the
    /// board holds neither.
    private static func boardText() -> String? {
        let board = UIPasteboard.general
        if let string = board.string, !string.isEmpty {
            return string
        }
        if let rtf = board.data(forPasteboardType: UTType.rtf.identifier),
           let text = text(fromItem: rtf), !text.isEmpty
        {
            return text
        }
        if let url = board.url?.absoluteString, !url.isEmpty {
            return url
        }
        return nil
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
