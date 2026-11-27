import Foundation
import Testing
@testable import ReadLaterCore

/// Pins the plan evolution rule (`BlockPlan.init(from:)`). See the rule in
/// `Model.swift`. A failure here means a shipped plan can no longer open.
struct BlockPlanContractTests {
    /// The repo root, from this file's path:
    /// Tests/ReadLaterCoreTests/X.swift -> packages/ReadLaterCore -> packages -> root.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func decode(_ json: String) throws -> BlockPlan {
        try JSONDecoder().decode(BlockPlan.self, from: Data(json.utf8))
    }

    @Test func goldenV1FixtureDecodes() throws {
        let url = Self.repoRoot.appendingPathComponent("contracts/fixtures/block-plan.valid.json")
        let plan = try JSONDecoder().decode(BlockPlan.self, from: Data(contentsOf: url))
        #expect(plan.schemaVersion == 1)
        #expect(plan.sentenceCount == 4)
        #expect(plan.spokenWords == 13)
        #expect(plan.blocks.count > 0)
    }

    @Test func pipelinePlanDecodes() throws {
        let url = Self.repoRoot.appendingPathComponent("fixtures/pages/004-averages.blockplan.json")
        let plan = try JSONDecoder().decode(BlockPlan.self, from: Data(contentsOf: url))
        #expect(plan.schemaVersion == 1)
        #expect(plan.blocks.count == 68)
    }

    @Test func missingVersionReadsAsVersionOne() throws {
        let plan = try decode("""
        {"source": "a.html", "source_sha256": "x", "sentence_count": 0,
         "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(plan.schemaVersion == 1)
    }

    @Test func unknownKeysAreIgnored() throws {
        let plan = try decode("""
        {"version": 1, "source": "a.html", "source_sha256": "x", "sentence_count": 0,
         "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": [],
         "field_from_a_later_build": {"anything": true}}
        """)
        #expect(plan.source == "a.html")
    }

    @Test func newerVersionIsRejectedWithAMessage() throws {
        #expect {
            _ = try decode("""
            {"version": 2, "source": "a.html", "source_sha256": "x", "sentence_count": 0,
             "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return false }
            // Legacy key blamed, not the new alias: the debugger checking
            // the raw JSON must find the offending key.
            return context.codingPath.last?.stringValue == "version"
                && context.debugDescription.contains("newer than supported version 1")
        }
        #expect {
            _ = try decode("""
            {"schema_version": 2, "source": "a.html", "source_sha256": "x", "sentence_count": 0,
             "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return false }
            return context.codingPath.last?.stringValue == "schema_version"
                && context.debugDescription.contains("newer than supported version 1")
        }
    }

    @Test func zeroSchemaVersionIsRejected() throws {
        #expect {
            _ = try decode("""
            {"schema_version": 0, "source": "a.html", "source_sha256": "x", "sentence_count": 0,
             "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return false }
            return context.codingPath.last?.stringValue == "schema_version"
                && context.debugDescription.contains("older than supported version 1")
        }
        // Legacy spelling names its own key.
        #expect {
            _ = try decode("""
            {"version": 0, "source": "a.html", "source_sha256": "x", "sentence_count": 0,
             "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return false }
            return context.codingPath.last?.stringValue == "version"
                && context.debugDescription.contains("older than supported version 1")
        }
        // Present-but-null alias decodes as missing: the legacy value provides
        // the version and takes the blame.
        #expect {
            _ = try decode("""
            {"schema_version": null, "version": 0, "source": "a.html", "source_sha256": "x",
             "sentence_count": 0, "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return false }
            return context.codingPath.last?.stringValue == "version"
                && context.debugDescription.contains("older than supported version 1")
        }
    }

    @Test func confidenceClampsToUnitRange() throws {
        // Schema pins [0, 1]; the reader clamps like the counts. The
        // lowConfidence default derives from the clamped value.
        let high = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": [{"id": 0, "kind": "prose", "confidence": 1.4, "reason": "p", "text": "Hi."}],
         "skipped": [{"block_id": 0, "kind": "figure", "confidence": 9.0, "reason": "f", "words": 3}]}
        """)
        #expect(high.blocks.first?.confidence == 1.0)
        #expect(high.blocks.first?.lowConfidence == false)
        #expect(high.skipped.first?.confidence == 1.0)
        let low = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": [{"id": 0, "kind": "prose", "confidence": -0.5, "reason": "p", "text": "Hi."}],
         "skipped": []}
        """)
        #expect(low.blocks.first?.confidence == 0.0)
        #expect(low.blocks.first?.lowConfidence == true)
        // Memberwise construction clamps identically: no path disagrees.
        let built = Block(id: 0, kind: .prose, confidence: 1.4, reason: "p", text: "Hi.")
        #expect(built.confidence == 1.0)
        let skipped = SkippedBlock(blockID: 0, kind: .figure, confidence: -0.5, reason: "f", words: 3)
        #expect(skipped.confidence == 0.0)
        // An explicit true with a clamped-high confidence coerces down;
        // an explicit false stays a reviewed-override.
        let coerced = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": [{"id": 0, "kind": "prose", "confidence": 1.0, "reason": "p", "text": "Hi.", "lowConfidence": true}],
         "skipped": []}
        """)
        #expect(coerced.blocks.first?.lowConfidence == false)
        let overrideKept = Block(id: 1, kind: .prose, confidence: 0.1, reason: "p", text: "Hi.", lowConfidence: false)
        #expect(overrideKept.lowConfidence == false)
    }

    @Test func skippedWordsAndSentencesClampToZero() throws {
        // Same leniency as the counts: a lying `words`/`offset`/`length`
        // must not violate the schema minimum on read.
        let plan = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": [{"id": 0, "kind": "prose", "confidence": 0.9, "reason": "p", "text": "Hi.",
           "spoken": [{"offset": -3, "length": -2, "text": "Hi."}]}],
         "skipped": [{"block_id": 0, "kind": "figure", "confidence": 0.9, "reason": "f", "words": -5}]}
        """)
        #expect(plan.skipped.first?.words == 0)
        #expect(plan.blocks.first?.spoken.first?.offset == 0)
        #expect(plan.blocks.first?.spoken.first?.length == 0)
        let builtSentence = Sentence(offset: -3, length: -2, text: "Hi.")
        #expect(builtSentence.offset == 0)
        #expect(builtSentence.length == 0)
        let builtSkipped = SkippedBlock(blockID: 0, kind: .figure, confidence: 0.9, reason: "f", words: -5)
        #expect(builtSkipped.words == 0)
    }

    @Test func nullBlocksHealToEmpty() throws {
        // A single null must not wipe a readable article.
        let plan = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": null, "skipped": null}
        """)
        #expect(plan.blocks.isEmpty)
        #expect(plan.skipped.isEmpty)
    }

    @Test func nullCountsHealToZero() throws {
        // Same leniency as null blocks: a single null must not wipe the
        // article. Missing keys heal identically (decodeIfPresent).
        let plan = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": null, "spoken_words": null, "validation_failures": null,
         "blocks": [], "skipped": []}
        """)
        #expect(plan.sentenceCount == 0)
        #expect(plan.spokenWords == 0)
        #expect(plan.validationFailures == 0)
    }

    @Test func blockIDsClampToZero() throws {
        let plan = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": [{"id": -1, "kind": "prose", "confidence": 0.9, "reason": "p", "text": "Hi."}],
         "skipped": [{"block_id": -2, "kind": "figure", "confidence": 0.9, "reason": "f", "words": 3}]}
        """)
        #expect(plan.blocks.first?.id == 0)
        #expect(plan.skipped.first?.blockID == 0)
        #expect(Block(id: -1, kind: .prose, confidence: 0.9, reason: "p", text: "Hi.").id == 0)
        #expect(SkippedBlock(blockID: -2, kind: .figure, confidence: 0.9, reason: "f", words: 3).blockID == 0)
    }

    @Test func memberwiseCountsClampToZero() throws {
        // Every construction path agrees: the memberwise init heals like
        // the decoder, and NaN confidence heals to 0 (min/max pass NaN).
        let plan = BlockPlan(extractorVersion: -1, source: "a", sourceSHA256: "x", sentenceCount: -3,
                             spokenWords: -1, validationFailures: -2,
                             blocks: [], skipped: [])
        #expect(plan.sentenceCount == 0)
        #expect(plan.spokenWords == 0)
        #expect(plan.validationFailures == 0)
        #expect(plan.extractorVersion == 0)
        #expect(Block(id: 0, kind: .prose, confidence: .nan, reason: "p", text: "Hi.").confidence == 0)
    }

    @Test func schemaVersionAliasPrefersNewKey() throws {
        // Writer emits both keys equal; a conflict can only be hand-made.
        // New key wins — the fixture conflicts so a flipped `??` order
        // actually fails. Legacy-alone still reads (and a 0 still throws).
        let conflict = try decode("""
        {"schema_version": 1, "version": 0, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(conflict.schemaVersion == 1)
        #expect {
            _ = try decode("""
            {"version": 0, "source": "a.html", "source_sha256": "x",
             "sentence_count": 0, "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { _ in true }
    }

    @Test func elementNullsHeal() throws {
        // Numerics heal, null elements drop, strings stay strict: a null
        // offset/confidence/words must not wipe the article, but a null
        // text still throws (content, not a lying number).
        let plan = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
         "blocks": [null, {"id": null, "kind": "prose", "confidence": null, "reason": "p", "text": "Hi.",
           "spoken": [null, {"offset": null, "length": null, "text": "Hi."}]}],
         "skipped": [null, {"block_id": null, "kind": "figure", "confidence": null, "reason": "f", "words": null}]}
        """)
        #expect(plan.blocks.count == 1)
        #expect(plan.blocks.first?.id == 0)
        #expect(plan.blocks.first?.confidence == 0.0)
        #expect(plan.blocks.first?.lowConfidence == true)
        #expect(plan.blocks.first?.spoken.count == 1)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.words == 0)
        #expect {
            _ = try decode("""
            {"schema_version": 1, "source": "a.html", "source_sha256": "x",
             "sentence_count": 0, "spoken_words": 0, "validation_failures": 0,
             "blocks": [{"id": 0, "kind": "prose", "confidence": 0.9, "reason": "p", "text": null}],
             "skipped": []}
            """)
        } throws: { _ in true }
    }

    @Test func memberwiseSchemaVersionFloorsAtOne() throws {
        #expect(BlockPlan(schemaVersion: -5, source: "a", sourceSHA256: "x", blocks: []).schemaVersion == 1)
        #expect(BlockPlan(schemaVersion: 99, source: "a", sourceSHA256: "x", blocks: []).schemaVersion == BlockPlan.currentVersion)
    }

    @Test func negativeCountsClampToZero() throws {
        // Speech totals are computed from blocks, so a lying stored field
        // must never make a readable article unreadable: negatives clamp
        // to 0 on read (lenient disk, strict contract — the schema still
        // says minimum 0). Each case pins the clamp, not a throw.
        let negSentence = try decode("""
        {"schema_version": 1, "sentence_count": -1, "source": "a.html", "source_sha256": "x",
         "spoken_words": 5, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(negSentence.sentenceCount == 0)
        #expect(negSentence.spokenWords == 5)
        let negSpoken = try decode("""
        {"schema_version": 1, "sentence_count": 0, "source": "a.html", "source_sha256": "x",
         "spoken_words": -1, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(negSpoken.spokenWords == 0)
        let negFailures = try decode("""
        {"schema_version": 1, "sentence_count": 0, "source": "a.html", "source_sha256": "x",
         "spoken_words": 0, "validation_failures": -1, "blocks": [], "skipped": []}
        """)
        #expect(negFailures.validationFailures == 0)
    }

    @Test func negativeExtractorVersionClampsToZero() throws {
        // Same leniency as the counts: a lying build number forfeits the
        // fast path at most, never the article.
        let plan = try decode("""
        {"version": 1, "extractor_version": -1, "source": "a.html", "source_sha256": "x",
         "sentence_count": 0, "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(plan.extractorVersion == 0)
    }

    @Test func wrongTypedSchemaVersionThrowsTypeMismatch() throws {
        // Only int-valued keys carry the contracted blame shape above;
        // a wrong-typed key surfaces as typeMismatch instead. Pinned so a
        // future refactor cannot silently change the surface. Same for
        // extractor_version below: the exclusion of other types from the
        // blame contract is deliberate, the pin covers the shape.
        #expect {
            _ = try decode("""
            {"schema_version": "1", "source": "a.html", "source_sha256": "x",
             "sentence_count": 0, "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return false }
            return context.codingPath.last?.stringValue == "schema_version"
        }
        #expect {
            _ = try decode("""
            {"schema_version": 1, "extractor_version": "0", "source": "a.html", "source_sha256": "x",
             "sentence_count": 0, "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
            """)
        } throws: { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return false }
            return context.codingPath.last?.stringValue == "extractor_version"
        }
    }

    @Test func roundTripKeepsTheContractKeys() throws {
        let plan = try decode("""
        {"version": 1, "source": "a.html", "source_sha256": "abc", "sentence_count": 2,
         "spoken_words": 5, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        let data = try JSONEncoder().encode(plan)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["source_sha256"] as? String == "abc")
        #expect(object["spoken_words"] as? Int == 5)
    }

    @Test func writerEmitsSchemaVersionPlusLegacyAlias() throws {
        let data = try JSONEncoder().encode(makePlanForKeys())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["version"] as? Int == 1)
        #expect(object["extractor_version"] as? Int == BlockPlan.currentExtractorVersion)
    }

    @Test func schemaVersionKeyDecodes() throws {
        let plan = try decode("""
        {"schema_version": 1, "source": "a.html", "source_sha256": "abc", "sentence_count": 0,
         "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(plan.schemaVersion == 1)
    }
}

private func makePlanForKeys() -> BlockPlan {
    BlockPlan(
        extractorVersion: BlockPlan.currentExtractorVersion,
        source: "a.html", sourceSHA256: "abc", blocks: [])
}
