import Testing
import ReadLaterCore

// A one-letter token is a word. The non-word rules still hold for URLs,
// paths, code identifiers, digit runs and symbols.

@Test func singleLetterTokenIsAWord() {
    #expect(TokenShape.shape(of: "a") == .word)
    #expect(TokenShape.shape(of: "I") == .word)
    #expect(TokenShape.shape(of: "é") == .word)
}

@Test func digitOrSymbolAloneIsNotAWord() {
    #expect(TokenShape.shape(of: "1") == .notAWord)
    #expect(TokenShape.shape(of: "%") == .notAWord)
    #expect(TokenShape.shape(of: "") == .notAWord)
}

@Test func urlPathAndCodeShapesAreNotWords() {
    #expect(TokenShape.shape(of: "https://x.io") == .notAWord)
    #expect(TokenShape.shape(of: "src/app") == .notAWord)
    #expect(TokenShape.shape(of: "foo_bar") == .notAWord)
}

@Test func ordinaryWordsAreWords() {
    #expect(TokenShape.shape(of: "Kowloon") == .word)
    #expect(TokenShape.shape(of: "don't") == .word)
}
