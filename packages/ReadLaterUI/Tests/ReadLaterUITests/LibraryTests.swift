import Testing
@testable import ReadLaterUI
import Foundation

// MARK: - Place line

@Test func placeLineCountsFromOne() {
    #expect(LibraryCopy.placeLine(wordIndex: 0, totalWords: 300) == "word 1 of 300")
    #expect(LibraryCopy.placeLine(wordIndex: 11, totalWords: 300) == "word 12 of 300")
}

@Test func placeLineClampsToTheArticleLength() {
    #expect(LibraryCopy.placeLine(wordIndex: 999, totalWords: 300) == "word 300 of 300")
}

@Test func placeLineIsEmptyWithoutALength() {
    #expect(LibraryCopy.placeLine(wordIndex: 12, totalWords: 0) == "")
    #expect(LibraryCopy.placeLine(wordIndex: 12, totalWords: -1) == "")
}

@Test func placeLineMatchesTheResumeOfferRule() {
    for (index, total) in [(0, 300), (11, 300), (299, 300), (400, 300)] {
        let offer = ResumeOffer(title: "T", wordIndex: index, totalWords: total)
        #expect(LibraryCopy.placeLine(wordIndex: index, totalWords: total) == offer.placeLine)
    }
}

// MARK: - First run

@Test func theDemoPrefillsOnceThenLeavesTheFieldEmpty() {
    #expect(LibraryCopy.prefillLink(seenDemo: false) == EntryCopy.sampleLink)
    #expect(LibraryCopy.prefillLink(seenDemo: true).isEmpty)
}

@Test func onlyTheSampleURLCountsAsTheDemo() {
    #expect(LibraryCopy.isDemo(url: ArticleLibrary.sampleURL))
    #expect(LibraryCopy.isDemo(url: URL(string: "https://example.com/reading")) == false)
    #expect(LibraryCopy.isDemo(url: nil) == false)
}
