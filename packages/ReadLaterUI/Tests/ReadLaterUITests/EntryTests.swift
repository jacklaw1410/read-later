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

@Test func demoSpokenIndexSkipsCode() {
    let index = SpokenIndex(plan: ArticleLibrary.demo.plan)
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
    #expect(EntryCopy.emptyRefusal == "nothing to open — paste a link or text")
    #expect(EntryCopy.loginWallRefusal == "login wall — paste text instead")
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
