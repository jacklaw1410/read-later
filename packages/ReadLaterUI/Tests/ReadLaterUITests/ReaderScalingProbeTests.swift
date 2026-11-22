import Dispatch
import Foundation
import ReadLaterCore
import ReadLaterUI
import XCTest

/// Exploratory probe: how one Reader render's work grows with article length.
///
/// Runs only when `READER_PROBE_OUT` names a directory. Each article gives one
/// `probe.sample` event per arm in `<dir>/oplog.jsonl`, and `tools/readerscale`
/// fits those events. `READER_PROBE_FIXTURES` optionally names a directory of
/// `*.blockplan.json` files, added as real articles.
///
/// The arms mirror `ReaderView.body`. `footnoteAttachments` is private there,
/// so the copy below must stay in step with it.
@MainActor
final class ReaderScalingProbeTests: XCTestCase {
    /// Each article and arm gets one timed window. Short articles run the arm
    /// many times inside that window, so the reported time keeps resolution.
    private static let windowSeconds = 0.02
    private static let maxIterations = 100_000
    private static let arms = ["footnote.rowwise", "footnote.once", "meta.count", "wash.scan", "body.total"]

    func testScalingProbe() throws {
        guard let out = ProcessInfo.processInfo.environment["READER_PROBE_OUT"] else {
            throw XCTSkip("Set READER_PROBE_OUT to a directory to run the Reader scaling probe.")
        }
        let oplog = TelemetryOplog(directory: URL(fileURLWithPath: out, isDirectory: true))
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        oplog.record("probe.start", fields: [
            "build": build,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])

        var articles = Self.syntheticArticles()
        if let dir = ProcessInfo.processInfo.environment["READER_PROBE_FIXTURES"] {
            articles += try Self.fixtures(in: URL(fileURLWithPath: dir, isDirectory: true), oplog: oplog)
        }

        for entry in articles {
            let document = entry.document
            let spoken = SpokenWordNumbering(plan: document.plan)
            let rows = document.bodyBlocks.filter { $0.kind != ReadLaterCore.BlockKind.footnoteMarker }.count
            var checks: [String: Int] = [:]
            for name in Self.arms {
                let timing = Self.timed { Self.run(name, document, spoken) }
                checks[name] = timing.check
                Self.record(oplog, entry: entry, component: name, rows: rows, words: spoken.totalWords, timing: timing)
            }
            XCTAssertEqual(checks["footnote.rowwise"], checks["footnote.once"],
                           "footnote arms disagree on \(entry.label)")
        }

        let micro = TelemetryOplog(directory: nil)
        var perCall: [Double] = []
        for _ in 0 ..< 5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0 ..< 2000 {
                micro.record("tick", fields: ["word": String(index)])
            }
            let end = DispatchTime.now().uptimeNanoseconds
            perCall.append(Double(end - start) / 1_000_000 / 2000)
        }
        perCall.sort()
        let microFields: [String: String] = [
            "corpus": "micro",
            "article": "record",
            "component": "telemetry.record",
            "blocks": "0",
            "rows": "0",
            "words": "0",
            "notes": "0",
            "ms": String(format: "%.6f", perCall[perCall.count / 2]),
            "iters": "2000",
            "checksum": "0",
        ]
        oplog.record("probe.sample", fields: microFields)
        oplog.flushNow()
    }

    // MARK: - Arms

    private static func record(_ oplog: TelemetryOplog, entry: Entry, component: String, rows: Int, words: Int, timing: Timing) {
        let fields: [String: String] = [
            "corpus": entry.corpus,
            "article": entry.label,
            "component": component,
            "blocks": String(entry.document.readingOrder.count),
            "rows": String(rows),
            "words": String(words),
            "notes": String(entry.document.noteBlocks.count),
            "ms": String(format: "%.6f", timing.ms),
            "iters": String(timing.iterations),
            "checksum": String(timing.check),
        ]
        oplog.record("probe.sample", fields: fields)
    }

    private struct Entry {
        let corpus: String
        let label: String
        let document: ReadLaterCore.Document
    }

    private struct Timing {
        let ms: Double
        let iterations: Int
        let check: Int
    }

    /// One result per article and arm. The first call is an untimed warm-up
    /// and sizes the window. The window then runs the arm enough times to last
    /// `windowSeconds`. `sink` keeps the optimizer from dropping the calls.
    private static func timed(_ body: () -> Int) -> Timing {
        var check = body()
        let one = seconds { check = body() }
        let iterations = min(maxIterations, max(1, Int((windowSeconds / max(one, 1e-9)).rounded(.up))))
        var sink = 0
        let total = seconds {
            for _ in 0 ..< iterations { sink &+= body() }
        }
        _ = sink
        return Timing(ms: total * 1000 / Double(iterations), iterations: iterations, check: check)
    }

    private static func seconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func run(_ name: String, _ document: ReadLaterCore.Document, _ spoken: SpokenWordNumbering) -> Int {
        switch name {
        case "footnote.rowwise": return footnoteRowwise(document)
        case "footnote.once": return footnoteOnce(document)
        case "meta.count": return metaCount(document)
        case "wash.scan": return washScan(document, spoken)
        case "body.total": return renderAsShipped(document, spoken)
        default: preconditionFailure("unknown arm \(name)")
        }
    }

    /// Mirrors `ReaderView.footnoteAttachments`. Rebuilt for every row, as
    /// the view does through its ForEach closure.
    private static func footnoteAttachments(_ document: ReadLaterCore.Document) -> [Int: Int] {
        let notes = document.noteBlocks
        let body = document.bodyBlocks
        var attachments: [Int: Int] = [:]
        var markerIndex = 0
        for position in body.indices {
            guard body[position].kind == .footnoteMarker else { continue }
            defer { markerIndex += 1 }
            guard markerIndex < notes.count, position > 0 else { continue }
            let preceding = body[position - 1]
            guard preceding.kind != .footnoteMarker else { continue }
            attachments[preceding.id] = markerIndex
        }
        return attachments
    }

    private static func footnoteRowwise(_ document: ReadLaterCore.Document) -> Int {
        var sum = 0
        for block in document.bodyBlocks.filter({ $0.kind != .footnoteMarker }) {
            sum &+= footnoteAttachments(document)[block.id] ?? 0
        }
        return sum
    }

    /// The same lookups with the map built once per render. The fix arm.
    private static func footnoteOnce(_ document: ReadLaterCore.Document) -> Int {
        let attachments = footnoteAttachments(document)
        var sum = 0
        for block in document.bodyBlocks.filter({ $0.kind != .footnoteMarker }) {
            sum &+= attachments[block.id] ?? 0
        }
        return sum
    }

    private static func metaCount(_ document: ReadLaterCore.Document) -> Int {
        document.spokenWordCount &+ document.skippedRegionCount
    }

    /// Per row, the wash test runs twice, as in `ReaderView.body`.
    private static func washScan(_ document: ReadLaterCore.Document, _ spoken: SpokenWordNumbering) -> Int {
        let wash = spoken.totalWords / 2
        func holds(_ blockID: Int) -> Bool {
            spoken.byBlock[blockID]?.contains { $0.index == wash } ?? false
        }
        var sum = 0
        for block in document.bodyBlocks.filter({ $0.kind != .footnoteMarker }) {
            if holds(block.id) { sum &+= 1 }
            if holds(block.id) { sum &+= 1 }
        }
        return sum
    }

    private static func renderAsShipped(_ document: ReadLaterCore.Document, _ spoken: SpokenWordNumbering) -> Int {
        metaCount(document) &+ footnoteRowwise(document) &+ washScan(document, spoken)
    }

    // MARK: - Articles

    /// Four groups, 62 articles in all. Rows and words per block vary on
    /// separate axes, so the two-term fit in `readerscale` has leverage.
    private static func syntheticArticles() -> [Entry] {
        var entries: [Entry] = []
        for rows in [50, 100, 200, 400, 800, 1600, 3200] {
            entries.append(Entry(corpus: "rows", label: "r\(rows)",
                                 document: makeDocument(rows: rows, wordsPerBlock: 12, seed: UInt64(rows))))
        }
        for rows in [100, 400, 1600] {
            for wordsPerBlock in [5, 40] {
                entries.append(Entry(corpus: "grid", label: "r\(rows)w\(wordsPerBlock)",
                                     document: makeDocument(rows: rows, wordsPerBlock: wordsPerBlock,
                                                            seed: UInt64(rows * 100 + wordsPerBlock))))
            }
        }
        for wordsPerBlock in [1, 2, 3, 5, 8, 20, 50, 100] {
            entries.append(Entry(corpus: "sweep", label: "w\(wordsPerBlock)",
                                 document: makeDocument(rows: 400, wordsPerBlock: wordsPerBlock,
                                                        seed: UInt64(90_000 + wordsPerBlock))))
        }
        var mix = Lcg(seed: 7)
        for index in 0 ..< 30 {
            let rows = 20 + mix.next(below: 1000)
            let wordsPerBlock = 5 + mix.next(below: 60)
            entries.append(Entry(corpus: "mixed", label: "m\(index)",
                                 document: makeDocument(rows: rows, wordsPerBlock: wordsPerBlock,
                                                        seed: UInt64(5000 + index))))
        }
        return entries
    }

    /// Synthetic article: `rows` prose blocks of `wordsPerBlock` words. A
    /// footnote marker and note follow every tenth block, and every twentieth
    /// block is code. Every seed gives new text.
    private static func makeDocument(rows: Int, wordsPerBlock: Int, seed: UInt64) -> ReadLaterCore.Document {
        var random = Lcg(seed: seed)
        var body: [ReadLaterCore.Block] = []
        var notes: [ReadLaterCore.Block] = []
        var id = 0
        for index in 0 ..< rows {
            let words = (0 ..< wordsPerBlock).map { _ in vocabulary[random.next(below: vocabulary.count)] }
            let text = words.joined(separator: " ") + "."
            let isCode = index % 20 == 19
            let spoken: [ReadLaterCore.Sentence] = isCode ? [] : [ReadLaterCore.Sentence(offset: 0, length: text.count, text: text)]
            body.append(ReadLaterCore.Block(id: id, kind: isCode ? .code : .prose, confidence: 0.95,
                                            reason: "probe", text: text, spoken: spoken))
            id += 1
            if index % 10 == 5 {
                body.append(ReadLaterCore.Block(id: id, kind: .footnoteMarker, confidence: 0.95,
                                                reason: "probe", text: String(notes.count + 1)))
                id += 1
                notes.append(ReadLaterCore.Block(id: id, kind: .footnoteBody, confidence: 0.95,
                                                 reason: "probe", text: "Note \(notes.count + 1) \(text)"))
                id += 1
            }
        }
        let plan = ReadLaterCore.BlockPlan(source: "probe", sourceSHA256: "probe", blocks: body + notes)
        return ReadLaterCore.Document(url: nil, title: "probe \(rows)x\(wordsPerBlock)", plan: plan)
    }

    private static func fixtures(in directory: URL, oplog: TelemetryOplog) throws -> [Entry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".blockplan.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [Entry] = []
        for file in files {
            do {
                let plan = try JSONDecoder().decode(BlockPlan.self, from: Data(contentsOf: file))
                let label = file.lastPathComponent.replacingOccurrences(of: ".blockplan.json", with: "")
                entries.append(Entry(corpus: "real", label: label,
                                     document: ReadLaterCore.Document(url: nil, title: label, plan: plan)))
            } catch {
                oplog.record("probe.error", fields: ["file": file.lastPathComponent, "error": String(describing: error)])
            }
        }
        return entries
    }

    private static let vocabulary = [
        "the", "reader", "opens", "a", "long", "article", "and", "the", "voice",
        "follows", "each", "word", "while", "the", "wash", "moves", "across", "lines",
        "of", "prose", "that", "wrap", "at", "the", "margin", "without", "a", "break",
    ]
}

/// Seeded generator. The same seed gives the same article on every run.
private struct Lcg {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 2_654_435_761 &+ 1
    }

    mutating func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}
