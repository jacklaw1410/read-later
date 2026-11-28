import Foundation
import ReadLaterCore
import ReadLaterStore
@testable import ReadLaterUI
import XCTest

/// Exploratory probe: how the entry wait grows with block count and words per block.
///
/// Runs only when `ENTRY_PROBE_OUT` names a directory. It writes `<dir>/telemetry.jsonl`:
/// one `probe.sample` per article and arm, and a `probe.call` marker before each
/// telemetry-recorded `ArticleIngress.read` call. `tools/entryscale` reads that file.
/// `ENTRY_PROBE_PINS` and `ENTRY_PROBE_FIXTURES` optionally name directories of raw
/// `.html` pages. `ENTRY_PROBE_ONLY` (comma-separated labels) limits the run to those inputs.
/// Build with `-Xswiftc -enable-testing` so `@testable` reaches internals.
final class EntryStageBenchmarkTests: XCTestCase {
    private static let samplesPerArm = 20
    private static let telemetryCalls = 5
    private static let arms = ["read", "extract", "plan", "invariant", "sha256", "save", "library", "seed"]

    private static let vocabulary = [
        "the", "reader", "listens", "to", "a", "long", "article", "about", "careful", "listening",
        "while", "paper", "moves", "slowly", "through", "quiet", "rooms", "and", "every", "word",
        "waits", "for", "its", "turn", "in", "the", "order", "that", "the", "author", "chose",
        "with", "patience", "small", "details", "matter", "more", "than", "grand", "claims",
    ]

    private struct Input {
        let sweep: String
        let source: String
        let label: String
        let html: String
    }

    private struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func next(below bound: Int) -> Int {
            Int(next() % UInt64(bound))
        }
    }

    func testEntryScalingProbe() throws {
        guard let out = ProcessInfo.processInfo.environment["ENTRY_PROBE_OUT"] else {
            throw XCTSkip("Set ENTRY_PROBE_OUT to a directory to run the entry scaling probe.")
        }
        let hub = TelemetryHub(directory: URL(fileURLWithPath: out, isDirectory: true))
        let quiet = TelemetryHub()
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        hub.telemetryLog.record("probe.start", fields: [
            "build": build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("entry-probe-\(UUID().uuidString).sqlite")
        let store = try Store(databaseURL: storeURL, device: "probe", telemetry: quiet)
        let extractor = SwiftSoupExtractor()

        var inputs = Self.syntheticInputs()
        for key in ["ENTRY_PROBE_PINS", "ENTRY_PROBE_FIXTURES"] {
            if let dir = ProcessInfo.processInfo.environment[key] {
                inputs += try Self.fileInputs(in: URL(fileURLWithPath: dir, isDirectory: true))
            }
        }
        if let only = ProcessInfo.processInfo.environment["ENTRY_PROBE_ONLY"] {
            let keep = Set(only.split(separator: ",").map { String($0) })
            inputs = inputs.filter { keep.contains($0.label) }
        }

        for input in inputs {
            let page = FetchedPage(
                html: input.html, status: 200,
                url: URL(string: "https://probe.invalid/\(input.label)")!
            )
            guard case .success(let document) = ArticleIngress.read(page, telemetry: quiet) else {
                hub.telemetryLog.record("probe.skip", fields: ["article": input.label, "reason": "not usable"])
                continue
            }
            for _ in 0 ..< Self.telemetryCalls {
                hub.telemetryLog.record("probe.call", fields: ["article": input.label])
                _ = ArticleIngress.read(page, telemetry: hub)
            }
            let blocks = (try? extractor.extract(html: input.html, source: page.url.absoluteString, httpStatus: 200))?.blocks ?? []

            for arm in Self.arms {
                let timing = Self.timed {
                    Self.run(arm, input: input, page: page, blocks: blocks, document: document, store: store, quiet: quiet)
                }
                Self.record(hub.telemetryLog, input: input, document: document, arm: arm, timing: timing)
            }
        }
        hub.telemetryLog.flushNow()
    }

    // MARK: - Arms

    private static func run(
        _ arm: String,
        input: Input,
        page: FetchedPage,
        blocks: [Block],
        document: ReadLaterCore.Document,
        store: Store,
        quiet: TelemetryHub
    ) -> Int {
        switch arm {
        case "read":
            if case .success(let doc) = ArticleIngress.read(page, telemetry: quiet) { return doc.plan.blocks.count }
            return -1
        case "extract":
            return (try? SwiftSoupExtractor().extract(html: input.html, source: page.url.absoluteString, httpStatus: 200))?.blocks.count ?? -1
        case "plan":
            return SpokenPlanBuilder.build(blocks: blocks, source: "probe", sourceSHA256: "").sentenceCount
        case "invariant":
            return SpokenPlanInvariant.violations(in: document.plan.blocks).count
        case "sha256":
            return ArticleIngress.sha256(input.html).count
        case "save":
            return (try? store.save(document: document)) == nil ? 0 : 1
        case "library":
            guard let stored = try? store.document(id: document.id) else { return -1 }
            _ = try? store.save(document: stored)
            return ReaderSeed(document: stored, savedWordIndex: nil).startWord ?? 0
        case "seed":
            return ReaderSeed(document: document, savedWordIndex: nil).startWord ?? 0
        default:
            preconditionFailure("unknown arm \(arm)")
        }
    }

    // MARK: - Timing

    private struct Timing {
        let p50: Double
        let p95: Double
        let minMs: Double
        let maxMs: Double
        let reps: Int
        let check: Int
    }

    /// One result per article and arm: one untimed warm-up, then 20 timed
    /// calls. The record keeps nearest-rank p50 and p95 plus min and max, so
    /// the gate compares the same statistics the CI tool reports.
    private static func timed(_ body: () -> Int) -> Timing {
        var check = body()
        _ = seconds { check = body() }
        var samples: [Double] = []
        samples.reserveCapacity(samplesPerArm)
        for _ in 0 ..< samplesPerArm {
            let elapsed = seconds { check = body() }
            samples.append(elapsed * 1000)
        }
        samples.sort()
        return Timing(
            p50: percentile(samples, 0.50),
            p95: percentile(samples, 0.95),
            minMs: samples[0],
            maxMs: samples[samples.count - 1],
            reps: samples.count,
            check: check
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let index = max(0, min(sorted.count - 1, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[index]
    }

    /// Opening tags in the page. This approximates the DOM node count without SwiftSoup.
    private static func tagCount(_ html: String) -> Int {
        guard let pattern = try? NSRegularExpression(pattern: "<[A-Za-z][A-Za-z0-9]*") else { return 0 }
        return pattern.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }

    private static func seconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func record(_ oplog: TelemetryLog, input: Input, document: ReadLaterCore.Document, arm: String, timing: Timing) {
        let blocks = document.plan.blocks.count
        let words = document.plan.spokenWords
        let fields: [String: String] = [
            "sweep": input.sweep,
            "source": input.source,
            "article": input.label,
            "arm": arm,
            "blocks": String(blocks),
            "words": String(words),
            "sentences": String(document.plan.sentenceCount),
            "bytes": String(input.html.utf8.count),
            "wpb": String(format: "%.3f", Double(words) / Double(max(blocks, 1))),
            "ms": String(format: "%.6f", timing.p50),
            "ms_p50": String(format: "%.6f", timing.p50),
            "ms_p95": String(format: "%.6f", timing.p95),
            "ms_min": String(format: "%.6f", timing.minMs),
            "ms_max": String(format: "%.6f", timing.maxMs),
            "reps": String(timing.reps),
            "nodes": String(tagCount(input.html)),
            "checksum": String(timing.check),
        ]
        oplog.record("probe.sample", fields: fields)
    }

    // MARK: - Inputs

    private static func syntheticInputs() -> [Input] {
        var out: [Input] = []
        for seed in 1 ... 3 {
            for blocks in [25, 50, 100, 200, 400, 800] {
                out.append(synthetic(sweep: "A", blocks: blocks, perBlock: 30, seed: seed))
            }
            for perBlock in [8, 16, 32, 64, 128, 256] {
                out.append(synthetic(sweep: "B", blocks: 100, perBlock: perBlock, seed: seed))
            }
            out.append(synthetic(sweep: "X", blocks: 20, perBlock: 1000, seed: seed))
            out.append(synthetic(sweep: "T", blocks: 5, perBlock: 30, seed: seed))
        }
        return out
    }

    /// Paragraphs of exactly `perBlock` words, with sentence ends every 8 to 30
    /// words and some abbreviations and decimals. The same seed gives the same HTML.
    private static func synthetic(sweep: String, blocks: Int, perBlock: Int, seed: Int) -> Input {
        var rng = SplitMix(state: UInt64(seed) &* 1_000_003 &+ UInt64(blocks) &* 31 &+ UInt64(perBlock))
        var paragraphs: [String] = []
        for _ in 0 ..< blocks {
            var words: [String] = []
            var remaining = 8 + rng.next(below: 23)
            for _ in 0 ..< perBlock {
                var token = vocabulary[rng.next(below: vocabulary.count)]
                let roll = rng.next(below: 100)
                if roll < 3 {
                    token = "Dr."
                } else if roll < 5 {
                    token = "3.5"
                } else if roll < 7 {
                    token = "U.S."
                }
                remaining -= 1
                if remaining == 0 {
                    if !token.hasSuffix(".") { token += "." }
                    remaining = 8 + rng.next(below: 23)
                }
                words.append(token)
            }
            paragraphs.append("<p>" + words.joined(separator: " ") + "</p>")
        }
        let label = "\(sweep)-b\(blocks)-w\(perBlock)-s\(seed)"
        let html = "<!DOCTYPE html><html><head><title>Probe \(label)</title></head><body><article>"
            + paragraphs.joined(separator: "\n") + "</article></body></html>"
        return Input(sweep: sweep, source: "synthetic", label: label, html: html)
    }

    private static func fileInputs(in directory: URL) throws -> [Input] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "html" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.map { url in
            let html = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            return Input(sweep: "real", source: "file", label: url.deletingPathExtension().lastPathComponent, html: html)
        }
    }
}
