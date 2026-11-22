import Dispatch
import Foundation
import ReadLaterCore
import ReadLaterUI
import XCTest

/// Exploratory probe: how the Reader's per-render work grows with article size.
///
/// Runs only when `READER_PROBE_OUT` names a directory. Each measurement is a
/// `probe.sample` event in `<dir>/oplog.jsonl`, and `tools/readerscale` fits
/// those events. `READER_PROBE_FIXTURES` optionally names a directory of
/// `*.blockplan.json` files to add real articles.
///
/// The render arms mirror `ReaderView.body`. `footnoteAttachments` is private
/// there, so the copy below must stay in step with it. The probe times the copy.
@MainActor
final class ReaderScalingProbeTests: XCTestCase {
    private static let reps = 5

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

        var articles: [Entry] = []
        for blocks in [50, 100, 200, 400, 800, 1600, 3200] {
            articles.append(Entry(corpus: "blocks", label: "b\(blocks)",
                document: Self.synthetic(blocks: blocks, wordsPerBlock: 12, seed: UInt64(blocks))))
        }
        for words in [10, 20, 40, 80, 160, 320] {
            articles.append(Entry(corpus: "words", label: "w\(words)",
                document: Self.synthetic(blocks: 100, wordsPerBlock: words, seed: UInt64(1000 + words))))
        }
        var mix = Lcg(seed: 7)
        for index in 0 ..< 24 {
            let blocks = 10 + mix.next(below: 3000)
            let words = 5 + mix.next(below: 150)
            articles.append(Entry(corpus: "mixed", label: "m\(index)",
                document: Self.synthetic(blocks: blocks, wordsPerBlock: words, seed: UInt64(5000 + index))))
        }
        if let dir = ProcessInfo.processInfo.environment["READER_PROBE_FIXTURES"] {
            articles += try Self.fixtures(in: URL(fileURLWithPath: dir, isDirectory: true), oplog: oplog)
        }

        for entry in articles {
            let document = entry.document
            let spoken = SpokenWordNumbering(plan: document.plan)
            let rows = document.bodyBlocks.filter { $0.kind != .footnoteMarker }.count
            var checks: [String: Int] = [:]
            for name in ["footnote.rowwise", "footnote.once", "meta.count", "wash.scan", "body.total"] {
                let timing = Self.medianMs { Self.run(name, document, spoken) }
                checks[name] = timing.check
                oplog.record("probe.sample", fields: [
                    "corpus": entry.corpus,
                    "article": entry.label,
                    "component": name,
                    "blocks": String(document.readingOrder.count),
                    "rows": String(rows),
                    "words": String(spoken.totalWords),
                    "notes": String(document.noteBlocks.count),
                    "ms": String(format: "%.4f", timing.median),
                    "ms_min": String(format: "%.4f", timing.min),
                    "reps": String(Self.reps),
                    "checksum": String(timing.check),
                ])
            }
            XCTAssertEqual(checks["footnote.rowwise"], checks["footnote.once"],
                           "footnote arms disagree on \(entry.label)")
        }

        let micro = TelemetryOplog(directory: nil)
        var perCall: [Double] = []
        for _ in 0 ..< Self.reps {
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0 ..< 2000 {
                micro.record("tick", fields: ["word": String(index)])
            }
            let end = DispatchTime.now().uptimeNanoseconds
            perCall.append(Double(end - start) / 1_000_000 / 2000)
        }
        perCall.sort()
        oplog.record("probe.sample", fields: [
            "corpus": "micro",
            "article": "record",
            "component": "telemetry.record",
            "blocks": "0",
            "rows": "0",
            "words": "0",
            "notes": "0",
            "ms": String(format: "%.6f", perCall[perCall.count / 2]),
            "ms_min": String(format: "%.6f", perCall[0]),
            "reps": String(Self.reps),
            "checksum": "0",
        ])
        oplog.flushNow()
    }

    // MARK: - Arms

    private struct Entry {
        let corpus: String
        let label: String
        let document: ReadLaterCore.Document
    }

    private static func run(_ name: String, _ document: ReadLaterCore.Document, _ spoken: SpokenWordNumbering) -> Int {
        switch name {
        case "footnote.rowwise": return footnoteRowwise(document)
        case "footnote.once": return footnoteOnce(document)
        case "meta.count": return metaCount(document)
        case "wash.scan": return washScan(document, spoken)
        default: return renderAsShipped(document, spoken)
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

    // MARK: - Timing

    private static func medianMs(_ body: () -> Int) -> (median: Double, min: Double, check: Int) {
        var times: [Double] = []
        var check = 0
        for _ in 0 ..< reps {
            let start = DispatchTime.now().uptimeNanoseconds
            check = body()
            let end = DispatchTime.now().uptimeNanoseconds
            times.append(Double(end - start) / 1_000_000)
        }
        times.sort()
        return (times[times.count / 2], times[0], check)
    }

    // MARK: - Articles

    /// Synthetic article: prose blocks, a footnote marker and note every
    /// tenth block, a code block every twentieth. Every seed gives new text.
    private static func synthetic(blocks: Int, wordsPerBlock: Int, seed: UInt64) -> ReadLaterCore.Document {
        var random = Lcg(seed: seed)
        var body: [ReadLaterCore.Block] = []
        var notes: [ReadLaterCore.Block] = []
        var id = 0
        for index in 0 ..< blocks {
            let words = (0 ..< wordsPerBlock).map { _ in vocabulary[random.next(below: vocabulary.count)] }
            let text = words.joined(separator: " ") + "."
            let isCode = index % 20 == 19
            let spoken: [Sentence] = isCode ? [] : [Sentence(offset: 0, length: text.count, text: text)]
            body.append(Block(id: id, kind: isCode ? .code : .prose, confidence: 0.95,
                              reason: "probe", text: text, spoken: spoken))
            id += 1
            if index % 10 == 5 {
                body.append(Block(id: id, kind: .footnoteMarker, confidence: 0.95,
                                  reason: "probe", text: String(notes.count + 1)))
                id += 1
                notes.append(Block(id: id, kind: .footnoteBody, confidence: 0.95,
                                   reason: "probe", text: "Note \(notes.count + 1) \(text)"))
                id += 1
            }
        }
        let plan = BlockPlan(source: "probe", sourceSHA256: "probe", blocks: body + notes)
        return ReadLaterCore.Document(url: nil, title: "probe \(blocks)x\(wordsPerBlock)", plan: plan)
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
                entries.append(Entry(corpus: "fixture", label: label,
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
