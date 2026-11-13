import Foundation

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
}
