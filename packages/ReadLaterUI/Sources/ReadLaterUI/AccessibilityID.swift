import Foundation

/// Stable identifiers shared by the app and the UI tests.
///
/// Tests query these values, never labels or copy. Renaming a control then
/// breaks the build in one place instead of a test at 2 a.m.
public enum AccessibilityID {
    public static let entryLinkField = "entry.link"
    public static let entryRawField = "entry.raw"
    public static let entryOpen = "entry.open"
    public static let entryResume = "entry.resume"
    public static let entryLibrary = "entry.library"
    public static let entrySettings = "entry.settings"

    public static let readerTitle = "reader.title"
    public static let readerBack = "reader.back"
    public static let readerPlayPause = "reader.playPause"
    public static let readerWash = "reader.wash"
    public static let readerProgress = "reader.progress"

    public static let lookupCard = "lookup.card"
    public static let lookupWord = "lookup.word"
    public static let lookupGloss = "lookup.gloss"
}
