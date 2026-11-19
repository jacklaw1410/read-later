import Testing
@testable import ReadLaterUI
import ReadLaterCore

// MARK: - PasteLoader

@Test func pastedParagraphsBecomeProseBlocks() {
    let text = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."
    let document = PasteLoader.document(from: text, title: "T")
    #expect(document != nil)
    #expect(document?.plan.blocks.count == 3)
    for block in document?.plan.blocks ?? [] {
        #expect(block.kind == .prose)
        #expect(!block.spoken.isEmpty)
    }
}

@Test func blankLinesAndStraySpacesMakeNoEmptyBlocks() {
    let text = "  \n\n  First paragraph.  \n wrapped line.\n\n\n\nSecond paragraph.\n\n   \n"
    let document = PasteLoader.document(from: text, title: "T")
    #expect(document?.plan.blocks.count == 2)
    #expect(document?.plan.blocks.allSatisfy { !$0.text.isEmpty } == true)
    #expect(document?.plan.blocks[0].text == "First paragraph. wrapped line.")
}

@Test func emptyInputReturnsNil() {
    #expect(PasteLoader.document(from: "", title: "T") == nil)
    #expect(PasteLoader.document(from: "   \n\n  \n ", title: "T") == nil)
}

@Test func derivedTitleTrimsToSixWords() {
    #expect(
        PasteLoader.derivedTitle(from: "one two three four five six seven eight")
            == "one two three four five six…"
    )
    #expect(PasteLoader.derivedTitle(from: "just two") == "just two")
}

// MARK: - ArticleLibrary.demo

@Test func demoHasEveryBlockKind() {
    let kinds = Set(ArticleLibrary.demo.readingOrder.map(\.kind))
    for kind: BlockKind in [
        .prose, .heading, .code, .table, .figure, .math, .quote,
        .pullQuote, .embed, .list, .aside, .footnoteBody, .footnoteMarker, .nav,
    ] {
        #expect(kinds.contains(kind), "missing \(kind.rawValue)")
    }
    #expect(ArticleLibrary.demo.readingOrder.filter { $0.kind == .prose }.count >= 5)
}

@Test func demoSatisfiesSpokenInvariant() {
    #expect(SpokenPlanInvariant.violations(in: ArticleLibrary.demo.plan.blocks).isEmpty)
}

@Test func demoSpokenWordNumberingSkipsCode() {
    let index = SpokenWordNumbering(plan: ArticleLibrary.demo.plan)
    #expect(index.totalWords > 0)
    let codeIDs = Set(
        ArticleLibrary.demo.readingOrder.filter { $0.kind == .code }.map(\.id)
    )
    #expect(!codeIDs.isEmpty)
    for id in codeIDs {
        #expect(index.byBlock[id] == nil)
    }
}

@Test func demoIDsAreUniqueAndIncreasing() {
    let ids = ArticleLibrary.demo.readingOrder.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids == ids.sorted())
}

// MARK: - EntryState stage table

@Test func entryStagesRunInOrder() {
    #expect(EntryStage.allCases == [.fetching, .stripping, .ready])
    let labels = EntryStage.allCases.map(\.label)
    #expect(labels == ["Fetching page…", "Removing nav · ads…", "Body ready"])
    #expect(labels.allSatisfy { !$0.isEmpty })
    let progress = EntryStage.allCases.map(\.progress)
    #expect(progress == [0.3, 0.65, 1.0])
    #expect(progress[0] < progress[1] && progress[1] < progress[2])
}

@Test func entryRefusalStrings() {
    #expect(EntryCopy.emptyRefusal == "Nothing to open — paste a link or some text.")
    #expect(EntryCopy.emptyRefusalNoClipboard == "Nothing to open — copy a link or some text first.")
}


// MARK: - EntryRequest tap snapshot

@Test func tapSnapshotTrimsBothFields() {
    let request = EntryRequest(linkText: "  https://example.com/a  ", rawText: "  hello  \n")
    #expect(request.link == "https://example.com/a")
    #expect(request.raw == "hello")
    #expect(!request.isEmpty)
}

@Test func blankSnapshotRefuses() {
    #expect(EntryRequest(linkText: "  ", rawText: " \n ").isEmpty)
}

// MARK: - EntryMode segmented input

@Test func linkIsFirstAndDefault() {
    #expect(EntryMode.allCases == [.link, .text])
    #expect(EntryMode.link.title == EntryCopy.linkMode)
    #expect(EntryMode.text.title == EntryCopy.textMode)
    #expect(EntryRequest(linkText: "https://example.com/a", rawText: "").mode == .link)
}

@Test func eachModeReadsOnlyItsField() {
    #expect(!EntryRequest(mode: .link, linkText: "https://example.com/a", rawText: "").isEmpty)
    #expect(EntryRequest(mode: .link, linkText: "", rawText: "stray paragraph").isEmpty)
    #expect(!EntryRequest(mode: .text, linkText: "", rawText: "a paragraph").isEmpty)
    #expect(EntryRequest(mode: .text, linkText: "https://example.com/a", rawText: "").isEmpty)
}
// MARK: - Library place line

@Test func libraryPlaceLineStandsAlone() {
    #expect(LibraryCopy.placeLine(wordIndex: 11, totalWords: 300) == "word 12 of 300")
    #expect(LibraryCopy.placeLine(wordIndex: 999, totalWords: 300) == "word 300 of 300")
    #expect(LibraryCopy.placeLine(wordIndex: 0, totalWords: 0) == "")
}

@Suite("Entry link caption")
struct EntryCaptionTests {
    @Test("The sample caption appears only over the sample link")
    func sampleCaptionFollowsTheField() {
        #expect(EntryCopy.linkHint(for: EntryCopy.sampleLink) == EntryCopy.linkHint)
        #expect(EntryCopy.linkHint(for: "") == EntryCopy.linkHintEdited)
        #expect(EntryCopy.linkHint(for: "https://example.com") == EntryCopy.linkHintEdited)
    }
}

// MARK: - B2-S strip port

@Test func entryStageProgressMatchesStripBeats() {
    // Prototype beats: Fetch 30 / Clean 65 / Ready 100.
    #expect(EntryStage.allCases.map { Int($0.progress * 100) } == [30, 65, 100])
}

@Test func stripIdentifiersAreUnique() {
    let ids = [
        AccessibilityID.entryStrip, AccessibilityID.entryError,
        AccessibilityID.entryPaste, AccessibilityID.entryPasteLabel,
        AccessibilityID.entryStepFetch,
        AccessibilityID.entryStepClean, AccessibilityID.entryStepReady,
    ]
    #expect(ids.allSatisfy { !$0.isEmpty })
    #expect(Set(ids).count == ids.count)
}
