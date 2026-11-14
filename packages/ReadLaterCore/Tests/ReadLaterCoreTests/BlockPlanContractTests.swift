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
        #expect(plan.version == 1)
        #expect(plan.sentenceCount == 4)
        #expect(plan.spokenWords == 13)
        #expect(plan.blocks.count > 0)
    }

    @Test func pipelinePlanDecodes() throws {
        let url = Self.repoRoot.appendingPathComponent("fixtures/pages/004-averages.blockplan.json")
        let plan = try JSONDecoder().decode(BlockPlan.self, from: Data(contentsOf: url))
        #expect(plan.version == 1)
        #expect(plan.blocks.count == 68)
    }

    @Test func missingVersionReadsAsVersionOne() throws {
        let plan = try decode("""
        {"source": "a.html", "source_sha256": "x", "sentence_count": 0,
         "spoken_words": 0, "validation_failures": 0, "blocks": [], "skipped": []}
        """)
        #expect(plan.version == 1)
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
            return context.debugDescription.contains("newer than supported version 1")
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
}
