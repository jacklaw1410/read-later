import Foundation

/// One synthesizer utterance: one spoken sentence and its place in the
/// document's spoken order.
public struct Utterance: Sendable, Hashable {
    public var sentenceIndex: Int
    public var blockID: Int
    public var text: String
    public var firstWordIndex: Int
    public var wordCount: Int

    public init(sentenceIndex: Int, blockID: Int, text: String, firstWordIndex: Int, wordCount: Int) {
        self.sentenceIndex = sentenceIndex
        self.blockID = blockID
        self.text = text
        self.firstWordIndex = firstWordIndex
        self.wordCount = wordCount
    }
}

/// A pure planner over the spoken order. No AVFoundation here: the adapter
/// owns the synthesizer and this type owns the index math, so the mapping
/// from a reported range back to a global word is unit-testable.
///
/// Two ways in. `init(index:blocks:)` is the primary one and skips every
/// block whose `spoken` list is empty, so code, tables and other reduced-ink
/// blocks contribute no utterances. `init(sentences:)` regroups bare
/// sentences into blocks first; the controller speaks from sentences alone.
public struct SpeechQueue: Sendable {
    public let utterances: [Utterance]
    private let index: SpokenIndex
    /// UTF-16 offset of each utterance's sentence start inside its block text.
    private let sentenceBases: [Int]
    /// Word ranges relative to each utterance's own text (`base: 0`).
    private let relativeRanges: [[NSRange]]

    /// How many utterances to keep queued ahead of the voice. Two, measured.
    public static let prefetch = 2

    public var totalWords: Int { utterances.reduce(0) { $0 + $1.wordCount } }

    public init(index: SpokenIndex, blocks: [Block]) {
        var utterances: [Utterance] = []
        var bases: [Int] = []
        var ranges: [[NSRange]] = []
        var sentenceIndex = 0
        for block in SpokenIndex.flatten(blocks) {
            guard !block.spoken.isEmpty else { continue }
            for sentence in block.spoken {
                let base = SpokenIndex.utf16Offset(ofCharacterOffset: sentence.offset, in: block.text)
                let words = SpokenIndex.wordRanges(in: sentence.text, base: 0)
                let first: Int
                if sentenceIndex < index.firstWordOfSentence.count {
                    first = index.firstWordOfSentence[sentenceIndex]
                } else {
                    first = utterances.last.map { $0.firstWordIndex + $0.wordCount } ?? 0
                }
                utterances.append(Utterance(
                    sentenceIndex: sentenceIndex,
                    blockID: block.id,
                    text: sentence.text,
                    firstWordIndex: first,
                    wordCount: words.count
                ))
                bases.append(base)
                ranges.append(words)
                sentenceIndex += 1
            }
        }
        self.utterances = utterances
        self.index = index
        self.sentenceBases = bases
        self.relativeRanges = ranges
    }

    /// One utterance per sentence, in input order. Sentences from one block
    /// share that block; blocks appear in first-appearance order.
    public init(sentences: [(blockID: Int, sentence: Sentence)]) {
        let blocks = Self.regroup(sentences: sentences)
        self.init(index: SpokenIndex(blocks: blocks), blocks: blocks)
    }

    /// The utterance that contains a global word index.
    public func utterance(forWord index: Int) -> Utterance? {
        guard index >= 0 else { return nil }
        for utterance in utterances
            where index >= utterance.firstWordIndex
            && index < utterance.firstWordIndex + utterance.wordCount
        {
            return utterance
        }
        return nil
    }

    /// The utterance to start from when the reader scrubs to a word, plus
    /// the character offset inside that utterance to start speaking at. The
    /// synthesizer speaks an utterance from its start, so a mid-sentence
    /// start means a truncated utterance; the adapter slices at the offset.
    /// A word that opens its sentence returns offset 0.
    public func startPosition(forWord index: Int) -> (utterance: Utterance, characterOffset: Int)? {
        guard let utterance = utterance(forWord: index),
              let position = utterances.firstIndex(of: utterance)
        else { return nil }
        let local = index - utterance.firstWordIndex
        guard local >= 0, local < relativeRanges[position].count else { return nil }
        return (utterance, relativeRanges[position][local].location)
    }

    /// Translates a range reported by the synthesizer, in UTF-16 inside the
    /// utterance text, into a global word index. Maps through the word that
    /// contains the range start, or the word that precedes it, so a callback
    /// that spans a boundary or lands on whitespace still resolves. Returns
    /// nil only when the range starts outside the utterance text.
    public func wordIndex(reportedRange range: NSRange, in utterance: Utterance) -> Int? {
        guard let position = utterances.firstIndex(of: utterance) else { return nil }
        let length = (utterance.text as NSString).length
        guard range.location >= 0, range.location < length else { return nil }
        var match: Int?
        for (local, word) in relativeRanges[position].enumerated() {
            if range.location >= word.location {
                match = local
            } else {
                break
            }
        }
        guard let local = match else { return nil }
        return utterance.firstWordIndex + local
    }

    /// Full wash update for one callback: the global word, resolved through
    /// the queue, reported as a block-text range with its sentence address.
    public func spokenWordRange(reportedRange range: NSRange, in utterance: Utterance) -> SpokenWordRange? {
        guard let global = wordIndex(reportedRange: range, in: utterance),
              let slot = index.word(at: global),
              let position = utterances.firstIndex(of: utterance)
        else { return nil }
        return SpokenWordRange(
            range: slot.range,
            sentenceIndex: utterance.sentenceIndex,
            sentenceOffset: sentenceBases[position]
        )
    }

    /// The word at a global index, addressed in block text UTF-16.
    public func slot(at globalIndex: Int) -> WordSlot? {
        index.word(at: globalIndex)
    }

    /// Whether the queue should enqueue another utterance after one
    /// finishes. True while fewer than `prefetch` stay queued ahead.
    public func shouldEnqueueNext(afterFinished _: Int, enqueuedAhead: Int) -> Bool {
        enqueuedAhead < Self.prefetch
    }

    // MARK: - Regrouping

    /// Rebuilds blocks from bare sentences by placing each sentence at its
    /// character offset and filling the gaps with spaces. Gaps between spoken
    /// sentences are trimmed whitespace, which is never astral, so the
    /// rebuilt prefix has the same UTF-16 length as the original block text
    /// and every word range lands exactly.
    private static func regroup(sentences: [(blockID: Int, sentence: Sentence)]) -> [Block] {
        var order: [Int] = []
        var groups: [Int: [Sentence]] = [:]
        for (blockID, sentence) in sentences {
            if groups[blockID] == nil {
                order.append(blockID)
                groups[blockID] = []
            }
            groups[blockID]?.append(sentence)
        }
        return order.map { blockID in
            let spoken = groups[blockID] ?? []
            var text = ""
            var cursor = 0
            for sentence in spoken {
                let gap = max(0, sentence.offset - cursor)
                if gap > 0 {
                    text += String(repeating: " ", count: gap)
                }
                cursor = sentence.offset + sentence.text.count
                text += sentence.text
            }
            return Block(
                id: blockID,
                kind: .prose,
                confidence: 1.0,
                reason: "regrouped speech sentences",
                text: text,
                spoken: spoken
            )
        }
    }
}
