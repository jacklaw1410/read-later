import Foundation

/// Every reader-facing string and rule on the library screen, in one type.
/// The view reads these values, and the tests read the same values, so the
/// place line and the first-run rule cannot drift apart.
public enum LibraryCopy {
    public static let title = "Library"
    public static let close = "Close"
    public static let empty = "Nothing read yet — open a link or paste text."
    public static let save = "Save"
    public static let unsave = "Unsave"
    public static let refresh = "Refresh"
    public static let remove = "Remove"
    public static let removeTitle = "Remove article?"
    public static let removeQuestion = "This drops the cached plan and the place."
    public static let cancel = "Cancel"
    public static let finished = "Finished"
    public static let saved = "Saved"
    public static let actions = "Article actions"

    /// Library failures and refusals, in one line each. The view shows one at a
    /// time; no message invites an action the app cannot do.
    public static let readFailed = "could not read the library"
    public static let noStore = "no library on this device"
    public static let openFailed = "could not open this article — open the link again"
    public static let libraryRowLost = "opened, but the library could not keep this article"
    public static let needsLink = "no stored copy — open the link again"
    public static let saveFailed = "could not change the save"
    public static let refreshFailed = "could not refresh this article"
    public static let forgetFailed = "could not remove this article"
    public static let articleUpdated = "article updated since your last read — starting at the top"

    /// "word 12 of 300". The place in one glance, clamped to the article
    /// length on both ends: a corrupt negative index reads as word 1, never
    /// "word -4 of 50". Empty when the length is unknown, so the row shows
    /// the title only.
    public static func placeLine(wordIndex: Int, totalWords: Int) -> String {
        guard totalWords > 0 else { return "" }
        return "word \(max(min(wordIndex + 1, totalWords), 1)) of \(totalWords)"
    }

    /// The link the entry screen starts with: the sample once, then empty, so
    /// the demo never reads as the app's only input.
    public static func prefillLink(seenDemo: Bool) -> String {
        seenDemo ? "" : EntryCopy.sampleLink
    }

    /// True when an opened document is the bundled demo. One demo open sets
    /// the first-run flag, and the next launch starts on an empty link field.
    public static func isDemo(url: URL?) -> Bool {
        url == ArticleLibrary.sampleURL
    }
}
