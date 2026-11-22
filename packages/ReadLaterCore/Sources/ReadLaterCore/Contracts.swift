import Foundation

// MARK: - Diagnostics
//
// The seam that makes analytics and crash reporting a later implementation instead of a
// later refactor. No vendor ships in the MVP. Every call site goes through here.

public enum DiagnosticEvent: Sendable, Hashable {
    case appLaunch(coldStartMS: Int)
    case extractionFinished(PageClass, blockCount: Int)
    case lookup(LookupSource, milliseconds: Double)
    case miss(MissKind)
    case packInstall(String)
    case nonFatal(String, context: [String: String])
}

public protocol Diagnostics: Sendable {
    func record(_ event: DiagnosticEvent)
}

public struct NoopDiagnostics: Diagnostics {
    public init() {}
    public func record(_ event: DiagnosticEvent) {}
}

/// Keeps events in memory so tests and the pilot export can read them.
public final class InMemoryDiagnostics: Diagnostics, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DiagnosticEvent] = []

    public init() {}

    public func record(_ event: DiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    public var events: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Speech
//
// `AVSpeechSynthesizer` reports word boundaries through
// `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`, which delivers an
// NSRange. That callback is the source of truth for the wash. Measured at 0 drift over
// 26.4 minutes and 623 sentences (read-later-research/evidence/2026-11-10-playback-endurance).

public struct SpokenWordRange: Sendable, Hashable {
    /// Character range inside the block's `text`, already offset by the sentence start.
    public var range: NSRange
    /// Index of the utterance inside the current utterance queue.
    public var utteranceIndex: Int
    /// UTF-16 offset of the sentence start inside the block text.
    public var sentenceOffset: Int

    public init(range: NSRange, utteranceIndex: Int, sentenceOffset: Int) {
        self.range = range
        self.utteranceIndex = utteranceIndex
        self.sentenceOffset = sentenceOffset
    }
}

public enum SpeechState: Sendable, Equatable {
    case idle
    case warming
    case speaking
    case paused
    case finished
}

@MainActor
public protocol SpeechController: AnyObject {
    var state: SpeechState { get }
    var onWord: ((SpokenWordRange) -> Void)? { get set }
    var onStateChange: ((SpeechState) -> Void)? { get set }

    /// Pre-warm the synthesizer and voice so the first word arrives without a stall.
    /// Required: cold start measured 1,139.7 ms against a 700 ms gate.
    func warmUp()

    /// Speak a whole document's sentences. `prefetch` is the number of utterances kept
    /// queued ahead of the voice. Two is the measured default.
    func speak(sentences: [(blockID: Int, sentence: Sentence)], prefetch: Int)

    func pause()
    /// Silences the voice now and keeps the queue at the current word. `resume()`
    /// plays on from that word. Unlike `pause()`, this does not wait for a word
    /// boundary, so a release that comes first cannot restart into a voice whose
    /// pause lands later.
    func holdForScrub()
    func resume()
    func stop()

    /// True when a restart has a queue to seek in. False before the first
    /// `speak` and after `stop`.
    var canRestart: Bool { get }

    /// Restarts speech at a word or a sentence. Returns false when there is no
    /// queue, so the caller can rebuild instead of failing silently.
    @discardableResult
    func restart(fromWord index: Int) -> Bool
    @discardableResult
    func restart(fromUtterance index: Int) -> Bool

    /// True while the voice still holds live audio. A suspension can kill the
    /// queue while the state still reads `.speaking`; this is the reconcile
    /// signal that turns that lie into a clean pause.
    var hasLiveUtterances: Bool { get }

    /// 1.0 is the reference pace, about 140 words per minute.
    var rate: Float { get set }
}

public extension SpeechController {
    func speak(sentences: [(blockID: Int, sentence: Sentence)]) {
        speak(sentences: sentences, prefetch: 2)
    }
}

// MARK: - Lookup
//
// Order: user override, note, cache, Apple dictionary, installed pack.
// Apple 譯典通 (`zh_TW-en.DrEye`) first on macOS: 0.28 ms median, p95 1.18 ms.
// On iOS the pack is the only source: D7 found no public API that returns dictionary text.

public enum LookupSource: String, Codable, Sendable, CaseIterable {
    case apple = "Apple 譯典通 (built-in)"
    case pack = "English–Chinese pack"
    case cache
    case userOverride = "your entry"
    case none
}

public struct LookupResult: Codable, Sendable, Hashable {
    public var word: String
    public var gloss: String
    public var phonetic: String?
    public var partOfSpeech: String?
    public var source: LookupSource
    /// Set when the shown headword differs from the tapped one, e.g. `café` resolved as `cafe`.
    public var accentVariant: String?

    public init(
        word: String,
        gloss: String,
        phonetic: String? = nil,
        partOfSpeech: String? = nil,
        source: LookupSource,
        accentVariant: String? = nil
    ) {
        self.word = word
        self.gloss = gloss
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.source = source
        self.accentVariant = accentVariant
    }
}

/// The three non-clean states. Card copy is owned by
/// read-later-research/design/miss-state.md. One label per case, no taxonomy.
public enum MissKind: Sendable, Hashable {
    case notInDictionary
    case notAWord
    case noNetwork
}

public enum LookupOutcome: Sendable, Hashable {
    case hit(LookupResult)
    case miss(MissKind)

    /// `Not in dictionary.` or `This doesn't look like a word.`
    public var label: String {
        switch self {
        case .hit: return ""
        case .miss(.notInDictionary): return "Not in dictionary."
        case .miss(.notAWord): return "This doesn't look like a word."
        case .miss(.noNetwork): return "No offline entry for this word."
        }
    }
}

public protocol LookupProvider: Sendable {
    func lookup(_ word: String) async -> LookupOutcome
}

// MARK: - Capability packs
//
// The state and actions of the installed dictionary pack, as Settings and the
// reader use them. The app target implements it; `ReadLaterUI` shows it.

@MainActor
public protocol CapabilityPacks: AnyObject {
    var isInstalled: Bool { get }
    var installedVersion: String? { get }
    var isInstalling: Bool { get }
    var isPaused: Bool { get }
    var failure: String? { get }
    var downloadedBytes: Int { get }
    var totalBytes: Int { get }
    var updateVersion: String? { get }
    var updateSizeBytes: Int? { get }
    var offerDeclined: Bool { get }

    func startInstall()
    func cancelInstall()
    func install() async
    func remove()
    func removePartial()
    func declineOffer()
    func checkForUpdate() async
    func lookup(_ word: String) -> LookupResult?
}

// MARK: - Library
//
// The browse list of started articles. The app target implements the provider
// over its store; `ReadLaterUI` shows the rows and sends actions back.

public struct LibraryRow: Sendable, Hashable, Identifiable {
    public var contentHash: String
    public var title: String
    public var wordIndex: Int
    public var totalWords: Int
    public var finished: Bool
    public var saved: Bool

    public var id: String { contentHash }

    public init(
        contentHash: String, title: String, wordIndex: Int, totalWords: Int,
        finished: Bool, saved: Bool
    ) {
        self.contentHash = contentHash
        self.title = title
        self.wordIndex = wordIndex
        self.totalWords = totalWords
        self.finished = finished
        self.saved = saved
    }
}

@MainActor
public protocol LibraryProvider: AnyObject {
    var rows: [LibraryRow] { get }
    var message: String? { get }

    /// Returns true when the article opened. A false return keeps the list up.
    func open(_ row: LibraryRow) async -> Bool
    func setSaved(_ row: LibraryRow, saved: Bool)
    func refresh(_ row: LibraryRow)
    func forget(_ row: LibraryRow)
}

// MARK: - Diagnostics export
//
// The diagnostics screen reads the telemetry log's status and asks for a staged
// folder. The app target implements it over `TelemetryHub` and the staging code.

@MainActor
public protocol DiagnosticsExporting: AnyObject {
    var isEnabled: Bool { get }
    var sourcePath: String { get }
    var fileCount: Int { get }
    var pendingCount: Int { get }
    var latestEvents: [String] { get }
    var pullCommand: String { get }

    /// Writes the log files and a summary to a fresh folder and returns it.
    func stage() throws -> URL
}

/// Classifies the tapped token. A URL, a path or a code identifier is not a word.
public enum WordShape: String, Sendable {
    case word
    case notAWord
}

public enum TokenShape {
    /// Strips leading and trailing non-alphanumerics from a tapped token.
    ///
    /// A tap resolves to the whitespace-delimited word, which carries its
    /// punctuation: `attention.` and `("café")` arrive as they appear on the
    /// page. The dictionary is asked for `attention` and `café`.
    public static func trimmed(_ token: String) -> String {
        var slice = Substring(token)
        while let first = slice.first, !first.isLetter, !first.isNumber {
            slice = slice.dropFirst()
        }
        while let last = slice.last, !last.isLetter, !last.isNumber {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    public static func shape(of token: String) -> WordShape {
        let trimmed = Self.trimmed(token)
        guard !trimmed.isEmpty else { return .notAWord }
        if trimmed.contains("/") || trimmed.contains("\\") { return .notAWord }
        if trimmed.contains("://") || trimmed.contains("@") && trimmed.contains(".") { return .notAWord }
        if trimmed.contains("_") || trimmed.contains("{") || trimmed.contains("}") { return .notAWord }
        if trimmed.contains("(") || trimmed.contains(")") { return .notAWord }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 1 else { return .notAWord }
        let alphanumerics = trimmed.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "-"
        }
        return alphanumerics.count == trimmed.unicodeScalars.count ? .word : .notAWord
    }
}

// MARK: - Extraction

public protocol Extractor: Sendable {
    /// Returns blocks for a usable page, or throws the class that stopped it.
    ///
    /// `httpStatus` is part of the input on purpose. A 401, 403 or 451 is a wall
    /// whatever the body says, and the stored body of such a page is often empty:
    /// nine of the pinned walls carry no readable text. Without the status the
    /// extractor reports `failed`, and `failed` tells the reader nothing.
    func extract(html: String, source: String, httpStatus: Int?) throws -> ExtractionResult
}

public extension Extractor {
    func extract(html: String, source: String) throws -> ExtractionResult {
        try extract(html: html, source: source, httpStatus: nil)
    }
}

public enum WallStatus {
    public static let denied: Set<Int> = [401, 403, 451]
}

// MARK: - Spoken plan
//
// Splits each block into sentences and addresses every sentence as a range inside the
// block text. The invariant below fails when a sentence is not an exact slice.

public enum SpokenPlanBuilder {
    /// Fills `spoken` on every block, then returns a plan with counts set.
    public static func build(
        blocks: [Block],
        source: String,
        sourceSHA256: String
    ) -> BlockPlan {
        SpokenPlanEngine.build(blocks: blocks, source: source, sourceSHA256: sourceSHA256)
    }

    /// Splits one block's text into sentences, without touching the block tree.
    public static func sentences(in text: String) -> [Sentence] {
        SpokenPlanEngine.sentences(in: text)
    }
}

public struct InvariantViolation: Sendable, Hashable, CustomStringConvertible {
    public var blockID: Int
    public var sentenceOffset: Int
    public var sentenceLength: Int
    public var expected: String
    public var actual: String

    public init(blockID: Int, sentenceOffset: Int, sentenceLength: Int, expected: String, actual: String) {
        self.blockID = blockID
        self.sentenceOffset = sentenceOffset
        self.sentenceLength = sentenceLength
        self.expected = expected
        self.actual = actual
    }

    public var description: String {
        "block \(blockID) [\(sentenceOffset)..<\(sentenceOffset + sentenceLength)] expected \(expected.debugDescription) got \(actual.debugDescription)"
    }
}

public enum SpokenPlanInvariant {
    /// Every utterance must be an exact slice of its block's text.
    /// Runs at load, before the first utterance. Zero failures on 12,240 sentences.
    public static func violations(in blocks: [Block]) -> [InvariantViolation] {
        SpokenPlanCheck.violations(in: blocks)
    }
}
