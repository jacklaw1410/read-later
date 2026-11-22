import Foundation

/// Stable identifiers shared by the app and the UI tests.
///
/// Tests query these values, never labels or copy. Renaming a control then
/// breaks the build in one place instead of a test at 2 a.m.
public enum AccessibilityID {
    public static let entryLinkField = "entry.link"
    public static let entryOpen = "entry.open"
    public static let entryLibrary = "entry.library"
    public static let entrySettings = "entry.settings"

    // B2-S strip layout. The view worker wires these to the matching views;
    // tests query the constants, never the strings.
    public static let entryStrip = "entry.strip"
    public static let entryError = "entry.error"
    public static let entryPaste = "entry.paste"
    public static let entryPasteLabel = "entry.paste.label"
    public static let entryStepFetch = "entry.step.fetch"
    public static let entryStepClean = "entry.step.clean"
    public static let entryStepReady = "entry.step.ready"

    public static let readerTitle = "reader.title"
    public static let readerBack = "reader.back"
    public static let readerWash = "reader.wash"
    public static let readerFootnote = "reader.footnote"
    /// Session notice (rewrite gate, lost library row). Persists for the
    /// session by design: it explains the starting place, not a moment.
    public static let readerNotice = "reader.notice"

    // C1 revised rail controls (canonical IDs)
    public static let readerRail = "reader.rail"
    public static let railSpeed = "rail.speed"
    public static let railSpeedMinus = "rail.speed.minus"
    public static let railSpeedPlus = "rail.speed.plus"
    public static let railScrub = "rail.scrub"
    public static let railPlayPause = "rail.playPause"
    public static let railPrevSentence = "rail.prevSentence"
    public static let railNextSentence = "rail.nextSentence"
    public static let railSpeedLadder = "rail.speed.ladder"
    public static let followDot = "follow.dot"
    public static let clock = "clock"

    // Legacy aliases. SwiftUI keeps one identifier per view, so the rail
    // carries the canonical rail ID. Tests query through these constants,
    // which point at the rail IDs, so old call sites stay green.
    public static let readerPlayPause = railPlayPause
    public static let readerProgress = railScrub
    public static let readerSpeed = railSpeed
    public static let readerStepForward = railNextSentence
    public static let readerStepBack = railPrevSentence

    public static let lookupCard = "lookup.card"
    public static let lookupWord = "lookup.word"
    public static let lookupGloss = "lookup.gloss"
    public static let lookupPronounce = "lookup.pronounce"

    public static let libraryActions = "library.actions"
    public static let librarySave = "library.save"
    public static let libraryUnsave = "library.unsave"
    public static let libraryRefresh = "library.refresh"
    public static let libraryRemove = "library.remove"

    public static let settingsAppearance = "settings.appearance"
    public static let settingsHandedness = "settings.handedness"

    public static let missCard = "miss.card"
    public static let missWord = "miss.word"
    public static let missPronounce = "miss.pronounce"
    public static let missNotNow = "miss.notNow"
    public static let missClose = "miss.close"
    public static let missInstall = "miss.install"
    public static let missSearch = "miss.search"
}
