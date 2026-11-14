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
    public static let readerStepForward = "reader.stepForward"
    public static let readerStepBack = "reader.stepBack"
    public static let readerSpeed = "reader.speed"
    public static let readerFootnote = "reader.footnote"

    // C1 revised rail controls
    public static let readerRail = "reader.rail"
    public static let railSpeed = "rail.speed"
    public static let railSpeedMinus = "rail.speed.minus"
    public static let railSpeedPlus = "rail.speed.plus"
    public static let railScrub = "rail.scrub"
    public static let railPlayPause = "rail.playPause"
    public static let railPrevSentence = "rail.prevSentence"
    public static let railNextSentence = "rail.nextSentence"
    public static let followDot = "follow.dot"
    public static let clock = "clock"

    public static let lookupCard = "lookup.card"
    public static let lookupWord = "lookup.word"
    public static let lookupGloss = "lookup.gloss"

    public static let libraryActions = "library.actions"
    public static let librarySave = "library.save"
    public static let libraryUnsave = "library.unsave"
    public static let libraryRefresh = "library.refresh"
    public static let libraryRemove = "library.remove"

    public static let settingsAppearance = "settings.appearance"
    public static let settingsHandedness = "settings.handedness"

    public static let missCard = "miss.card"
    public static let missWord = "miss.word"
    public static let missNotNow = "miss.notNow"
    public static let missClose = "miss.close"
    public static let missInstall = "miss.install"
    public static let missSearch = "miss.search"
}
