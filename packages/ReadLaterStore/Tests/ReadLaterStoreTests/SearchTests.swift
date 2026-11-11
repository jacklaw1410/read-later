import Foundation
import Testing
import ReadLaterCore
@testable import ReadLaterStore

@Suite("Phrase full-text search")
struct SearchTests {
    private func makeStoreWithThreePhrases() throws -> (Store, URL, Phrase, Phrase, Phrase) {
        let (store, dir) = try makeTemporaryStore()
        let near = Phrase(word: "attention", gloss: "the faculty of focusing the mind", source: "test")
        let glossOnly = Phrase(word: "retention", gloss: "the power of keeping attention over time", source: "test")
        let other = Phrase(word: "habit", gloss: "a settled practice or routine", source: "test")
        try store.save(phrase: near)
        try store.save(phrase: glossOnly)
        try store.save(phrase: other)
        return (store, dir, near, glossOnly, other)
    }

    @Test("Word match outranks gloss-only match")
    func exactWordRanksFirst() throws {
        let (store, dir, near, glossOnly, _) = try makeStoreWithThreePhrases()
        defer { removeTemporaryStore(at: dir) }

        let results = try store.searchPhrases(matching: "attention")
        #expect(results.count == 2)
        #expect(results.first?.phrase.id == near.id)
        #expect(results.map(\.phrase.id).contains(glossOnly.id))
    }

    @Test("Prefix query matches the same word")
    func prefixMatches() throws {
        let (store, dir, near, _, _) = try makeStoreWithThreePhrases()
        defer { removeTemporaryStore(at: dir) }

        let results = try store.searchPhrases(matching: "atten*")
        #expect(results.map(\.phrase.id).contains(near.id))
        #expect(results.first?.phrase.id == near.id)
    }

    @Test("Multi-word query matches across word and gloss")
    func multiWordMatches() throws {
        let (store, dir, near, _, _) = try makeStoreWithThreePhrases()
        defer { removeTemporaryStore(at: dir) }

        let results = try store.searchPhrases(matching: "attention focusing")
        #expect(results.map(\.phrase.id).contains(near.id))
    }

    @Test("FTS5 syntax characters in input do not throw")
    func hostileInputDoesNotThrow() throws {
        let (store, dir, _, _, _) = try makeStoreWithThreePhrases()
        defer { removeTemporaryStore(at: dir) }

        for query in ["\"", "*", "OR", "AND NOT", "word:attention", "(attention", "atten\" OR \"1\"=\"1"] {
            let results = try store.searchPhrases(matching: query)
            #expect(results.count >= 0)
        }
        #expect(try store.searchPhrases(matching: "\"").isEmpty)
        #expect(try store.searchPhrases(matching: "").isEmpty)
    }

    @Test("Results carry the matched word and gloss")
    func resultsCarryWordAndGloss() throws {
        let (store, dir, near, _, _) = try makeStoreWithThreePhrases()
        defer { removeTemporaryStore(at: dir) }

        let results = try store.searchPhrases(matching: "attention")
        let first = try #require(results.first)
        #expect(first.phrase.word == near.word)
        #expect(first.phrase.gloss == near.gloss)
    }
}
