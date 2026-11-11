import Foundation

/// One spoken word, addressed twice: as a global index in the document's
/// spoken order, and as a UTF-16 range inside its block's text.
///
/// The wash needs the range, the player needs the index, and the scrubber
/// needs both. Building it once at load is what lets the reader render a whole
/// document and then move a single highlight.
public struct WordSlot: Sendable, Hashable {
    /// Position in the document's spoken word order. Starts at 0.
    public var index: Int
    public var blockID: Int
    public var sentenceIndex: Int
    /// UTF-16 range inside `Block.text`, not inside the sentence.
    public var range: NSRange
    public var text: String

    public init(index: Int, blockID: Int, sentenceIndex: Int, range: NSRange, text: String) {
        self.index = index
        self.blockID = blockID
        self.sentenceIndex = sentenceIndex
        self.range = range
        self.text = text
    }
}

/// The spoken word order for one document.
///
/// Only sentences in `Block.spoken` become slots. A block that renders
/// reduced-ink contributes nothing, so the count here is the number of words a
/// reader will actually hear. `validationFailures` is not re-checked here; the
/// invariant runs at load and this type trusts its output.
public struct SpokenIndex: Sendable {
    public let words: [WordSlot]
    /// Words for one block, in reading order. A block with no spoken sentences
    /// is absent rather than present with an empty array.
    public let byBlock: [Int: [WordSlot]]
    public let sentenceCount: Int
    /// First word index of each sentence, in order. `firstWordOfSentence[i]`
    /// is where sentence `i` starts.
    public let firstWordOfSentence: [Int]

    public var totalWords: Int { words.count }

    public static let empty = SpokenIndex(words: [], byBlock: [:], sentenceCount: 0, firstWordOfSentence: [])

    private init(words: [WordSlot], byBlock: [Int: [WordSlot]], sentenceCount: Int, firstWordOfSentence: [Int]) {
        self.words = words
        self.byBlock = byBlock
        self.sentenceCount = sentenceCount
        self.firstWordOfSentence = firstWordOfSentence
    }

    /// Builds the spoken order from a document's blocks, flattened the same way
    /// `Document.readingOrder` flattens them.
    public init(blocks: [Block]) {
        var words: [WordSlot] = []
        var byBlock: [Int: [WordSlot]] = [:]
        var firstWordOfSentence: [Int] = []
        var sentenceIndex = 0

        for block in Self.flatten(blocks) {
            guard !block.spoken.isEmpty else { continue }
            let nsText = block.text as NSString
            var blockWords: [WordSlot] = []

            for sentence in block.spoken {
                firstWordOfSentence.append(words.count)
                let base = Self.utf16Offset(ofCharacterOffset: sentence.offset, in: block.text)
                for range in Self.wordRanges(in: sentence.text, base: base) {
                    guard NSMaxRange(range) <= nsText.length else { continue }
                    let text = nsText.substring(with: range)
                    let slot = WordSlot(
                        index: words.count,
                        blockID: block.id,
                        sentenceIndex: sentenceIndex,
                        range: range,
                        text: text
                    )
                    words.append(slot)
                    blockWords.append(slot)
                }
                sentenceIndex += 1
            }

            if !blockWords.isEmpty {
                byBlock[block.id] = blockWords
            }
        }

        self.words = words
        self.byBlock = byBlock
        self.sentenceCount = sentenceIndex
        self.firstWordOfSentence = firstWordOfSentence
    }

    public init(plan: BlockPlan) {
        self.init(blocks: plan.blocks)
    }

    /// The word at a global index, or nil past the end.
    public func word(at index: Int) -> WordSlot? {
        guard index >= 0, index < words.count else { return nil }
        return words[index]
    }

    /// The sentence that contains a global word index. Clamped, because the
    /// scrubber can land on the final word and the voice still needs a sentence.
    public func sentenceIndex(forWord index: Int) -> Int {
        guard !firstWordOfSentence.isEmpty else { return 0 }
        let clamped = min(max(index, 0), words.count - 1)
        var low = 0
        var high = firstWordOfSentence.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if firstWordOfSentence[mid] <= clamped {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The word a tap landed on, from a UTF-16 index inside one block.
    public func word(inBlock blockID: Int, atUTF16Index index: Int) -> WordSlot? {
        guard let slots = byBlock[blockID] else { return nil }
        // Ranges are ordered; a linear scan over a paragraph is cheap and needs
        // no second index to keep in sync.
        for slot in slots where index >= slot.range.location && index < NSMaxRange(slot.range) {
            return slot
        }
        return nil
    }

    /// The global word index for a range reported inside one sentence, in block
    /// coordinates.
    ///
    /// The speech callback reports `SpokenWordRange` with a range in block text
    /// and the sentence index, but no block id. Searching within the sentence is
    /// bounded by the sentence length, so this stays cheap at any document size.
    public func wordIndex(sentenceIndex: Int, blockRange: NSRange) -> Int? {
        guard sentenceIndex >= 0, sentenceIndex < firstWordOfSentence.count else { return nil }
        var i = firstWordOfSentence[sentenceIndex]
        while i < words.count, words[i].sentenceIndex == sentenceIndex {
            if words[i].range == blockRange { return i }
            i += 1
        }
        return nil
    }

    /// True when the wash jumped over at least one reduced-ink block between
    /// two spoken indices. The reader logs the hop; nothing else depends on it.
    public func crossesSkippedBlock(from: Int, to: Int, blocks: [Block]) -> Bool {
        let order = Self.flatten(blocks)
        guard let a = word(at: from), let b = word(at: to), a.blockID != b.blockID else { return false }
        guard let start = order.firstIndex(where: { $0.id == a.blockID }),
              let end = order.firstIndex(where: { $0.id == b.blockID }),
              start < end
        else { return false }
        return order[(start + 1) ..< end].contains { $0.spoken.isEmpty }
    }

    // MARK: - Tokenising

    /// Splits a sentence into word ranges. A word is a run of non-whitespace
    /// characters; nothing else is dropped, so the ranges tile the sentence
    /// and a tap on punctuation finds no word.
    public static func wordRanges(in text: String, base: Int) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var i = 0
        let length = ns.length
        while i < length {
            var isSpace = false
            if let scalar = Unicode.Scalar(ns.character(at: i)) {
                isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            if isSpace {
                i += 1
                continue
            }
            var j = i
            while j < length {
                var space = false
                if let scalar = Unicode.Scalar(ns.character(at: j)) {
                    space = CharacterSet.whitespacesAndNewlines.contains(scalar)
                }
                if space { break }
                j += 1
            }
            out.append(NSRange(location: base + i, length: j - i))
            i = j
        }
        return out
    }

    /// Converts a grapheme-cluster offset to a UTF-16 offset.
    ///
    /// `Sentence.offset` counts Characters. The text system counts UTF-16 code
    /// units. They agree for English prose and disagree for characters outside
    /// the basic plane, so the conversion happens once here instead of in each
    /// view.
    static func utf16Offset(ofCharacterOffset offset: Int, in text: String) -> Int {
        guard offset > 0 else { return 0 }
        guard let stringIndex = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else {
            return text.utf16.count
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: stringIndex.samePosition(in: text.utf16) ?? text.utf16.endIndex)
    }

    public static func flatten(_ blocks: [Block]) -> [Block] {
        blocks.flatMap { block -> [Block] in [block] + flatten(block.children) }
    }
}

// MARK: - Pace

/// Reading pace and the speed ladder.
///
/// The reference pace is 140 words per minute, or 429 ms per word. That number
/// is a measurement (read-later-research/evidence/2026-11-10-playback-endurance),
/// not a guess, and it is the one the time-remaining label uses.
public enum Pace {
    public static let referenceWordsPerMinute = 140
    public static let millisecondsPerWord = 429

    /// The ladder the speed control walks. 1× is the reference pace.
    public static let steps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    public static let reference: Float = 1

    /// Seconds left from a word index at a speed, rounded up to whole seconds.
    public static func secondsRemaining(wordsLeft: Int, speed: Float) -> Int {
        guard wordsLeft > 0, speed > 0 else { return 0 }
        let ms = Double(wordsLeft) * Double(millisecondsPerWord) / Double(speed)
        return Int((ms / 1000).rounded(.up))
    }

    public static func speedLabel(_ speed: Float) -> String {
        // 1.0 prints as "1×", 1.25 as "1.25×".
        let text = String(format: "%g", speed)
        return "\(text)×"
    }

    public static func next(after speed: Float) -> Float {
        guard let i = steps.firstIndex(of: speed) else { return reference }
        return steps[(i + 1) % steps.count]
    }
}

/// `mm:ss` for a duration. Negative input clamps to zero.
public func clockLabel(seconds: Int) -> String {
    let clamped = max(0, seconds)
    return String(format: "%02d:%02d", clamped / 60, clamped % 60)
}
