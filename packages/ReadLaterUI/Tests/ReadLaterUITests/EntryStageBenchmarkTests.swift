import Foundation
import ReadLaterCore
import ReadLaterStore
@testable import ReadLaterUI
import XCTest

/// Per-PR stage probe: one `probe.sample` per fixture and arm, each carrying
/// nearest-rank p50 and p95 over `samplesPerArm` calls.
///
/// Runs only when `ENTRY_PROBE_OUT` names a directory. `ENTRY_PROBE_FIXTURES`
/// names a directory of committed `.html` pages and `ENTRY_PROBE_ONLY` limits
/// the run to a comma-separated label list. The CI corpus is the four fixtures
/// named in `ci-performance-benchmark.md`; the corpus is fixed and hashed, so a
/// fixture that does not parse fails the run instead of shrinking it.
///
/// No `total` sample is written. `total` is derived from `extract`, `plan`,
/// `sha256`, `save` and `seed` by `tools/telemetrybench`, so a probe field
/// cannot disagree with the components.
///
/// Build with `-Xswiftc -enable-testing` so `@testable` reaches internals.
final class EntryStageBenchmarkTests: XCTestCase {
    private static let samplesPerArm = 20
    private static let arms = [
        "extract", "plan", "invariant", "sha256", "save", "seed", "library", "record", "read",
    ]
    /// The shipped corpus from the proposal. A run that cannot measure one of
    /// these has not measured the corpus.
    static let corpus = ["027-hn", "095-sciencedaily", "004-averages", "005-great-work"]

    private struct Input {
        let source: String
        let label: String
        let html: String
    }

    func testStageProbe() throws {
        guard let out = ProcessInfo.processInfo.environment["ENTRY_PROBE_OUT"] else {
            throw XCTSkip("Set ENTRY_PROBE_OUT to a directory to run the stage probe.")
        }
        let output = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let hub = TelemetryHub(directory: output)
        // Ring only: the `record` arm must not append probe events to the file
        // it is measuring.
        let quiet = TelemetryHub()
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        hub.telemetryLog.record("probe.start", fields: [
            "build": build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "arms": String(Self.arms.count),
        ])

        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("entry-probe-\(UUID().uuidString).sqlite")
        let store = try Store(databaseURL: storeURL, device: "probe", telemetry: quiet)
        let extractor = SwiftSoupExtractor()

        let fixtures = try XCTUnwrap(
            ProcessInfo.processInfo.environment["ENTRY_PROBE_FIXTURES"],
            "ENTRY_PROBE_FIXTURES must name the directory of committed .html fixtures")
        var inputs = try Self.fileInputs(in: URL(fileURLWithPath: fixtures, isDirectory: true))
        if let only = ProcessInfo.processInfo.environment["ENTRY_PROBE_ONLY"] {
            let keep = Set(only.split(separator: ",").map { String($0) })
            inputs = inputs.filter { keep.contains($0.label) }
        } else {
            for label in Self.corpus {
                XCTAssertTrue(
                    inputs.contains { $0.label == label },
                    "corpus fixture \(label) is missing from ENTRY_PROBE_FIXTURES")
            }
        }
        XCTAssertFalse(inputs.isEmpty, "no fixtures selected")

        for input in inputs {
            let page = FetchedPage(
                html: input.html, status: 200,
                url: URL(string: "https://probe.invalid/\(input.label)")!
            )
            guard case .success(let document) = ArticleIngress.read(page, telemetry: quiet) else {
                // The corpus is fixed: an unusable fixture is a probe failure,
                // not a smaller benchmark.
                XCTFail("fixture \(input.label) is not usable by the shipped extractor")
                continue
            }
            let blocks = (try? extractor.extract(
                html: input.html, source: page.url.absoluteString, httpStatus: 200))?.blocks ?? []

            for arm in Self.arms {
                let timing = Self.timed {
                    Self.run(
                        arm, input: input, page: page, blocks: blocks,
                        document: document, store: store, quiet: quiet)
                }
                Self.record(
                    hub.telemetryLog, input: input, document: document, arm: arm, timing: timing)
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
        case "extract":
            return (try? SwiftSoupExtractor().extract(
                html: input.html, source: page.url.absoluteString, httpStatus: 200))?.blocks.count ?? -1
        case "plan":
            return SpokenPlanBuilder.build(
                blocks: blocks, source: "probe", sourceSHA256: "").sentenceCount
        case "invariant":
            return SpokenPlanInvariant.violations(in: document.plan.blocks).count
        case "sha256":
            return ArticleIngress.sha256(input.html).count
        case "save":
            return (try? store.save(document: document)) == nil ? 0 : 1
        case "seed":
            return ReaderSeed(document: document, savedWordIndex: nil).startWord ?? 0
        case "library":
            // The alternate open path: read the stored row back, re-save it and
            // build the seed. `total` does not include it.
            guard let stored = try? store.document(id: document.id) else { return -1 }
            _ = try? store.save(document: stored)
            return ReaderSeed(document: stored, savedWordIndex: nil).startWord ?? 0
        case "record":
            // One telemetry write with a small field map. This is the overhead
            // that inflates the `plan` span by about 23 %.
            quiet.record("probe.record", fields: ["arm": "record"])
            return 1
        case "read":
            // A check that the probe still drives the shipped ingress path.
            if case .success(let doc) = ArticleIngress.read(page, telemetry: quiet) {
                return doc.plan.blocks.count
            }
            return -1
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

    /// One untimed warm-up, then `samplesPerArm` timed calls. The record keeps
    /// nearest-rank p50 and p95 plus min and max, so the gate compares the same
    /// statistics the CI tool reports.
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

    /// Nearest rank: p95 is the value at `ceil(0.95 * n) - 1` after sorting.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let index = max(0, min(sorted.count - 1, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[index]
    }

    /// Opening tags in the page. Approximates the DOM node count without
    /// paying for SwiftSoup outside the arm under test.
    private static func tagCount(_ html: String) -> Int {
        guard let pattern = try? NSRegularExpression(pattern: "<[A-Za-z][A-Za-z0-9]*") else { return 0 }
        return pattern.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }

    private static func seconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func record(
        _ oplog: TelemetryLog,
        input: Input,
        document: ReadLaterCore.Document,
        arm: String,
        timing: Timing
    ) {
        let blocks = document.plan.blocks.count
        let words = document.plan.spokenWords
        let fields: [String: String] = [
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

    private static func fileInputs(in directory: URL) throws -> [Input] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "html" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.map { url in
            let html = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            return Input(source: "file", label: url.deletingPathExtension().lastPathComponent, html: html)
        }
    }
}
