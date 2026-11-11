import Testing
@testable import ReadLaterUI
import ReadLaterCore

// MARK: - Miss state labels

@Test func missNotInDictionaryLabel() {
    #expect(LookupOutcome.miss(.notInDictionary).label == "Not in dictionary.")
}

@Test func missNotAWordLabel() {
    #expect(LookupOutcome.miss(.notAWord).label == "This doesn't look like a word.")
}

@Test func missNoNetworkLabel() {
    #expect(LookupOutcome.miss(.noNetwork).label == "No offline entry for this word.")
}

@Test func everyMissLabelIsShortAndStops() {
    let kinds: [MissKind] = [.notInDictionary, .notAWord, .noNetwork]
    for kind in kinds {
        let label = LookupOutcome.miss(kind).label
        #expect(label.split(separator: " ").count <= 8)
        #expect(label.hasSuffix("."))
    }
}

// MARK: - Source provenance

@Test func appleSourceRawValue() {
    #expect(LookupSource.apple.rawValue == "Apple 譯典通 (built-in)")
}

@Test func emptyGlossStillProducesSourceLine() {
    let result = LookupResult(word: "Kowloon", gloss: "", source: .apple)
    #expect(result.gloss.isEmpty)
    #expect(result.phonetic == nil)
    #expect(CardCopy.hitSourceLine(for: result) == "Source · Apple 譯典通 (built-in)")
}

// MARK: - Shared card copy

@Test func pauseLineWhilePlayingNamesWordIndex() {
    #expect(
        CardCopy.pauseLine(wasPlayingBeforeLookup: true, wordIndex: 42)
            == "Audio paused · resumes at #42 on close"
    )
}

@Test func pauseLineWhenAlreadyPaused() {
    #expect(
        CardCopy.pauseLine(wasPlayingBeforeLookup: false, wordIndex: 42)
            == "Audio was already paused · stays paused"
    )
}

@Test func missSourceLineNamesPackState() {
    #expect(
        CardCopy.missSourceLine(packInstalled: false)
            == "Source · Apple 譯典通 (built-in) · no entry"
    )
    #expect(
        CardCopy.missSourceLine(packInstalled: true)
            == "Source · Apple 譯典通 (built-in) + English–Chinese pack · no entry"
    )
}
