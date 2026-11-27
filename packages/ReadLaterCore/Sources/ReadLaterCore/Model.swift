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
        self.offset = offset
        self.length = length
        self.text = text
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
        self.id = id
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
        self.text = text
        self.children = children
        self.spoken = spoken
        self.lowConfidence = lowConfidence ?? (confidence < 0.8)
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
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decode(BlockKind.self, forKey: .kind)
        confidence = try c.decode(Double.self, forKey: .confidence)
        reason = try c.decode(String.self, forKey: .reason)
        text = try c.decode(String.self, forKey: .text)
        children = try c.decodeIfPresent([Block].self, forKey: .children) ?? []
        spoken = try c.decodeIfPresent([Sentence].self, forKey: .spoken) ?? []
        lowConfidence = try c.decodeIfPresent(Bool.self, forKey: .lowConfidence) ?? (confidence < 0.8)
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
        self.blockID = blockID
        self.kind = kind
        self.confidence = confidence
        self.reason = reason
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case blockID = "block_id"
        case kind, confidence, reason, words
    }
}

/// The extraction contract. `version` is the schema version, not the app version.
public struct BlockPlan: Codable, Sendable, Hashable {
    public var version: Int
    public var source: String
    public var sourceSHA256: String
    public var sentenceCount: Int
    public var spokenWords: Int
    public var validationFailures: Int
    public var blocks: [Block]
    public var skipped: [SkippedBlock]

    public init(
        version: Int = 1,
        source: String,
        sourceSHA256: String,
        sentenceCount: Int = 0,
        spokenWords: Int = 0,
        validationFailures: Int = 0,
        blocks: [Block],
        skipped: [SkippedBlock] = []
    ) {
        self.version = version
        self.source = source
        self.sourceSHA256 = sourceSHA256
        self.sentenceCount = sentenceCount
        self.spokenWords = spokenWords
        self.validationFailures = validationFailures
        self.blocks = blocks
        self.skipped = skipped
    }

    /// The newest plan version this build reads.
    public static let currentVersion = 1

    /// Evolution rule (adopted 2026-11-15, research repo `spec/device-test-plan.md`):
    /// a new field is optional or has a default, and it is decoded with
    /// `decodeIfPresent`. Keys are never renamed or removed. A breaking change
    /// bumps `currentVersion` and adds `contracts/block-plan.vN.json`. Unknown
    /// keys are ignored. A plan with no `version` key reads as version 1.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "plan version \(version) is newer than supported version \(Self.currentVersion)")
        }
        source = try container.decode(String.self, forKey: .source)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        sentenceCount = try container.decode(Int.self, forKey: .sentenceCount)
        spokenWords = try container.decode(Int.self, forKey: .spokenWords)
        validationFailures = try container.decode(Int.self, forKey: .validationFailures)
        blocks = try container.decode([Block].self, forKey: .blocks)
        skipped = try container.decode([SkippedBlock].self, forKey: .skipped)
    }

    private enum CodingKeys: String, CodingKey {
        case version, source
        case sourceSHA256 = "source_sha256"
        case sentenceCount = "sentence_count"
        case spokenWords = "spoken_words"
        case validationFailures = "validation_failures"
        case blocks, skipped
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
    public var title: String
    public var plan: BlockPlan
    public var addedAt: Date

    public init(id: UUID = UUID(), url: URL?, title: String, plan: BlockPlan, addedAt: Date = .now) {
        self.id = id
        self.url = url
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
