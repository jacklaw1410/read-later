import Foundation

// MARK: - Block model
//
// Shape frozen by `contracts/block-plan.v1.json`. The research repo's gate reads the
// same file, so a rename here is a schema version bump, not a refactor.
// Source of truth: read-later-research/spec/non-prose-classification.md

public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case prose
    case code
    case table
    case figure
    case image
    case math
    case embed
    case quote
    case heading
    case aside
    case nav
    case list
    case cjk
    case pullQuote = "pull-quote"
    case footnoteMarker = "footnote-marker"
    case footnoteBody = "footnote-body"
}

/// One sentence, addressed as a character range inside its block's `text`.
/// The spoken plan invariant requires `block.text[offset..<offset+length] == text`.
public struct Sentence: Codable, Sendable, Hashable {
    public var offset: Int
    public var length: Int
    public var text: String

    public init(offset: Int, length: Int, text: String) {
        // Lenient disk like the counts: the schema pins minimum 0.
        self.offset = max(0, offset)
        self.length = max(0, length)
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case offset, length, text
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = max(0, try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0)
        length = max(0, try c.decodeIfPresent(Int.self, forKey: .length) ?? 0)
        text = try c.decode(String.self, forKey: .text)
    }
}

public struct Block: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var kind: BlockKind
    public var confidence: Double
    public var reason: String
    public var text: String
    public var children: [Block]
    public var spoken: [Sentence]
    public var lowConfidence: Bool
    /// Image reference for `image` and `figure` blocks. The URL as written
    /// in `src` (first `srcset` candidate when `src` is absent), unresolved
    /// against any base. No loader reads this yet: fetching, caching and a
    /// real `<Image>` view are an explicit later slice. This field is the
    /// seam it will build on. Nil for every other kind.
    public var imageURL: String?
    /// The `alt` text as written, for the caption well and accessibility.
    /// Nil when the element carried no `alt`.
    public var alt: String?

    public init(
        id: Int,
        kind: BlockKind,
        confidence: Double,
        reason: String,
        text: String,
        children: [Block] = [],
        spoken: [Sentence] = [],
        lowConfidence: Bool? = nil,
        imageURL: String? = nil,
        alt: String? = nil
    ) {
        self.id = max(0, id)
        self.kind = kind
        // Same clamp as the decoder: every construction path agrees, so a
        // hand-built 1.4 can never disagree with a decoded row. An explicit
        // `lowConfidence: true` with a high confidence is coerced down: the
        // flag derives from confidence, an explicit `false` stays a
        // reviewed-override. NaN heals to 0: min/max pass NaN through.
        self.confidence = confidence.isNaN ? 0 : min(max(confidence, 0), 1)
        self.reason = reason
        self.text = text
        self.children = children
        self.spoken = spoken
        self.lowConfidence = (lowConfidence ?? (self.confidence < 0.8)) && (self.confidence < 0.8)
        self.imageURL = imageURL
        self.alt = alt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, confidence, reason, text, children, spoken, lowConfidence
        case imageURL = "image_url"
        case alt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = max(0, try c.decodeIfPresent(Int.self, forKey: .id) ?? 0)
        kind = try c.decode(BlockKind.self, forKey: .kind)
        // Lenient disk like the plan counts: the schema pins [0, 1], the
        // reader clamps. The default below derives from the clamped value.
        // NaN heals to 0: JSON cannot carry it, memberwise can. Null heals
        // to 0 (flags low confidence) rather than wiping the article;
        // strings/kinds stay strict. Null elements drop: [null] heals to [].
        let rawConfidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        confidence = rawConfidence.isNaN ? 0 : min(max(rawConfidence, 0), 1)
        reason = try c.decode(String.self, forKey: .reason)
        text = try c.decode(String.self, forKey: .text)
        children = try c.decodeIfPresent([Block?].self, forKey: .children)?.compactMap { $0 } ?? []
        spoken = try c.decodeIfPresent([Sentence?].self, forKey: .spoken)?.compactMap { $0 } ?? []
        // Explicit `true` with a clamped-high confidence coerces to false;
        // explicit `false` stays a reviewed-override. See the memberwise
        // init above.
        lowConfidence = (try c.decodeIfPresent(Bool.self, forKey: .lowConfidence) ?? (confidence < 0.8)) && (confidence < 0.8)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        alt = try c.decodeIfPresent(String.self, forKey: .alt)
    }
}

public struct SkippedBlock: Codable, Sendable, Hashable {
    public var blockID: Int
    public var kind: BlockKind
    public var confidence: Double
    public var reason: String
    public var words: Int

    public init(blockID: Int, kind: BlockKind, confidence: Double, reason: String, words: Int) {
        self.blockID = max(0, blockID)
        self.kind = kind
        // Same clamp as the decoder: every construction path agrees.
        // NaN heals to 0: min/max pass NaN through.
        self.confidence = confidence.isNaN ? 0 : min(max(confidence, 0), 1)
        self.reason = reason
        self.words = max(0, words)
    }

    private enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case kind, confidence, reason, words
    }

    // Lenient disk like `Block.confidence`: the schema pins [0, 1] and
    // `words` minimum 0. Null numerics heal to 0; strings stay strict.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockID = max(0, try c.decodeIfPresent(Int.self, forKey: .blockID) ?? 0)
        kind = try c.decode(BlockKind.self, forKey: .kind)
        let rawConfidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        confidence = rawConfidence.isNaN ? 0 : min(max(rawConfidence, 0), 1)
        reason = try c.decode(String.self, forKey: .reason)
        words = max(0, try c.decodeIfPresent(Int.self, forKey: .words) ?? 0)
    }
}

/// The extraction contract. `schemaVersion` is the schema version, not the
/// app version. `extractorVersion` is the parser build that produced the
/// plan: same hash plus a new parser is a new version, re-planned and
/// re-anchored silently (research `spec/library-identity.md` §3). Both decode
/// with `decodeIfPresent`: missing `schemaVersion` falls back to the legacy
/// `version` key, missing `extractorVersion` defaults to 0, so the contract
/// does not break.
public struct BlockPlan: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var extractorVersion: Int
    public var source: String
    public var sourceSHA256: String
    public var sentenceCount: Int
    public var spokenWords: Int
    public var validationFailures: Int
    public var blocks: [Block]
    public var skipped: [SkippedBlock]

    public init(
        schemaVersion: Int = 1,
        extractorVersion: Int = 0,
        source: String,
        sourceSHA256: String,
        sentenceCount: Int = 0,
        spokenWords: Int = 0,
        validationFailures: Int = 0,
        blocks: [Block],
        skipped: [SkippedBlock] = []
    ) {
        // schemaVersion floors at 1 and ceilings at currentVersion like the
        // decoder guard: a 2 or -5 can never build a plan the reader
        // refuses to open.
        self.schemaVersion = min(max(schemaVersion, 1), Self.currentVersion)
        self.extractorVersion = max(0, extractorVersion)
        self.source = source
        self.sourceSHA256 = sourceSHA256
        self.sentenceCount = max(0, sentenceCount)
        self.spokenWords = max(0, spokenWords)
        self.validationFailures = max(0, validationFailures)
        self.blocks = blocks
        self.skipped = skipped
    }

    /// The newest plan version this build reads.
    public static let currentVersion = 1

    /// The parser build this app ships. A stored plan with a lower value is
    /// re-planned from its saved page (research `spec/library-identity.md` §3).
    public static let currentExtractorVersion = 1

    /// Evolution rule (adopted 2026-11-15, research repo `spec/device-test-plan.md`):
    /// a new field is optional or has a default, and it is decoded with
    /// `decodeIfPresent`. Keys are never renamed or removed, with one past
    /// exception: `version` became `schemaVersion`, kept readable through the
    /// legacy key below. A breaking change bumps `currentVersion` and adds
    /// `contracts/block-plan.vN.json`. Unknown keys are ignored. A plan with
    /// neither key reads as schema version 1. Disk is lenient where the
    /// contract is strict: the schema requires `version`, the reader defaults
    /// it — do not "fix" either side to match the other.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Blame the key that actually produced the value: `decodeIfPresent`
        // returns nil for an explicit null, so a present-but-null
        // `schema_version` with a legacy `version` must name `version`.
        let schemaFromNew = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        let schemaFromLegacy = try container.decodeIfPresent(Int.self, forKey: .version)
        schemaVersion = schemaFromNew ?? schemaFromLegacy ?? 1
        let schemaKey: CodingKeys = schemaFromNew != nil ? .schemaVersion : .version
        extractorVersion = max(0, try container.decodeIfPresent(Int.self, forKey: .extractorVersion) ?? 0)
        guard schemaVersion >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: schemaKey, in: container,
                debugDescription: "plan schema version \(schemaVersion) is older than supported version 1")
        }
        guard schemaVersion <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: schemaKey, in: container,
                debugDescription: "plan schema version \(schemaVersion) is newer than supported version \(Self.currentVersion)")
        }
        source = try container.decode(String.self, forKey: .source)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        // Counts clamp rather than throw: speech totals are computed from
        // blocks, so a lying field must never make a readable article
        // unreadable (lenient disk, strict contract — the schema still says
        // minimum 0, the reader just heals instead of refusing). Missing or
        // null heals to 0 like `blocks`/`skipped` heal to []: a single null
        // must not wipe the article.
        sentenceCount = max(0, try container.decodeIfPresent(Int.self, forKey: .sentenceCount) ?? 0)
        spokenWords = max(0, try container.decodeIfPresent(Int.self, forKey: .spokenWords) ?? 0)
        validationFailures = max(0, try container.decodeIfPresent(Int.self, forKey: .validationFailures) ?? 0)
        // A single null must not wipe a readable article: heal to empty.
        // Null elements drop the same way: [null] heals to [].
        blocks = try container.decodeIfPresent([Block?].self, forKey: .blocks)?.compactMap { $0 } ?? []
        skipped = try container.decodeIfPresent([SkippedBlock?].self, forKey: .skipped)?.compactMap { $0 } ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version, source
        case extractorVersion = "extractor_version"
        case sourceSHA256 = "source_sha256"
        case sentenceCount = "sentence_count"
        case spokenWords = "spoken_words"
        case validationFailures = "validation_failures"
        case blocks, skipped
    }

    /// Writer emits `schema_version` plus the legacy `version` alias with the
    /// same value, so old and new readers both open the plan. (Synthesized
    /// encoding cannot emit one value under two keys.)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(schemaVersion, forKey: .version)
        try container.encode(extractorVersion, forKey: .extractorVersion)
        try container.encode(source, forKey: .source)
        try container.encode(sourceSHA256, forKey: .sourceSHA256)
        try container.encode(sentenceCount, forKey: .sentenceCount)
        try container.encode(spokenWords, forKey: .spokenWords)
        try container.encode(validationFailures, forKey: .validationFailures)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(skipped, forKey: .skipped)
    }
}

// MARK: - Page outcome
//
// Five classes, two rates. `rate_all = usable/n`, `rate_ours = usable/(n - walled)`.
// Read both. A release must not pass one by failing the other.
// Source of truth: read-later-research/spec/extraction-gate.md

public enum PageClass: String, Codable, Sendable, CaseIterable {
    case usable
    case walled
    case unrendered
    case notAnArticle = "not-an-article"
    case failed
}

public struct ExtractionResult: Sendable {
    public var pageClass: PageClass
    public var blocks: [Block]
    public var reason: String
    /// The page's `<title>`, trimmed. Empty when the page has none. The reader
    /// shows this at the top of an article, so the extractor keeps it here
    /// instead of making the caller parse the HTML a second time.
    public var title: String

    public init(pageClass: PageClass, blocks: [Block] = [], reason: String, title: String = "") {
        self.pageClass = pageClass
        self.blocks = blocks
        self.reason = reason
        self.title = title
    }

    public var isUsable: Bool { pageClass == .usable }
}

public enum ExtractionError: Error, Sendable, Equatable {
    case badURL
    case emptyDocument
    case notAnArticle(reason: String)
    case walled(reason: String)
    case unrendered(reason: String)
}

// MARK: - Document and phrases

public struct Document: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var url: URL?
    /// The link as pasted, before redirects and canonicalization. Kept
    /// alongside the canonical `url` (research `spec/library-identity.md`
    /// §2): refetch prefers it, since stripping a site's own `ref`/`source`
    /// key can fetch a different resource. Nil for pasted text and the demo.
    public var originalURL: URL?
    public var title: String
    public var plan: BlockPlan
    public var addedAt: Date

    public init(id: UUID = UUID(), url: URL?, originalURL: URL? = nil, title: String, plan: BlockPlan, addedAt: Date = .now) {
        self.id = id
        self.url = url
        self.originalURL = originalURL
        self.title = title
        self.plan = plan
        self.addedAt = addedAt
    }

    /// Blocks in reading order, with children flattened after their parent.
    public var readingOrder: [Block] {
        plan.blocks.flatMap { block -> [Block] in [block] + flatten(block.children) }
    }

    private func flatten(_ blocks: [Block]) -> [Block] {
        blocks.flatMap { [$0] + flatten($0.children) }
    }

    /// The text the reader hears, in order, and the range of each sentence in that text.
    public var spokenSentences: [(blockID: Int, sentence: Sentence)] {
        readingOrder.flatMap { block in block.spoken.map { (block.id, $0) } }
    }
}

public struct Phrase: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var word: String
    public var gloss: String
    public var source: String
    public var createdAt: Date

    public init(id: UUID = UUID(), word: String, gloss: String, source: String, createdAt: Date = .now) {
        self.id = id
        self.word = word
        self.gloss = gloss
        self.source = source
        self.createdAt = createdAt
    }
}

/// One row of the sync oplog. Sync replays these; it never mirrors a store.
/// Source of truth: read-later-research/spec/adr-0003 (oplog + CloudKit).
public struct SyncOplogEntry: Codable, Sendable, Hashable {
    public var seq: Int64
    public var device: String
    public var at: Date
    public var op: String
    public var payload: String

    public init(seq: Int64, device: String, at: Date, op: String, payload: String) {
        self.seq = seq
        self.device = device
        self.at = at
        self.op = op
        self.payload = payload
    }
}
