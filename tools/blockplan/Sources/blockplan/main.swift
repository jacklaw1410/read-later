import CryptoKit
import Foundation
import ReadLaterCore

func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// `--class` prints the page class instead of a block plan. A non-usable page has no
// blocks to print, so this is the only output it can have.
let classMode = CommandLine.arguments.contains("--class")
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") && Int($0) == nil }
let statusArg = CommandLine.arguments.dropFirst().compactMap { $0.hasPrefix("--status=") ? Int($0.dropFirst(9)) : nil }.first
let httpStatus = CommandLine.arguments.contains("--class") ? statusArg : statusArg
guard positional.count == 1 else {
    fail("usage: blockplan <page.html> [--class] [--status=N]")
}

let path = positional[0]
let url = URL(fileURLWithPath: path)

let html: String
do {
    html = try String(contentsOf: url, encoding: .utf8)
} catch {
    fail("cannot read \(path): \(error)")
}

let bytes: Data
do {
    bytes = try Data(contentsOf: url)
} catch {
    fail("cannot read \(path): \(error)")
}

let source = url.lastPathComponent
let digest = sha256Hex(of: bytes)

// The pipeline, end to end: extract blocks, then build the spoken plan.
let extractor: Extractor = SwiftSoupExtractor()
let result: ExtractionResult
do {
    result = try extractor.extract(html: html, source: source, httpStatus: httpStatus)
} catch {
    if classMode {
        let (pageClass, reason) = classify(error)
        print(#"{"pageClass":"\#(pageClass)","reason":"\#(reason)"}"#)
        exit(0)
    }
    fail("extraction failed: \(error)")
}

if classMode {
    print(#"{"pageClass":"\#(result.pageClass.rawValue)","reason":"\#(result.reason)"}"#)
    exit(0)
}

let plan = SpokenPlanBuilder.build(
    blocks: result.blocks,
    source: source,
    sourceSHA256: digest
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    let data = try encoder.encode(plan)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("cannot encode block plan: \(error)")
}

/// Maps a thrown extraction error to the five-class vocabulary.
func classify(_ error: any Error) -> (String, String) {
    switch error as? ExtractionError {
    case .notAnArticle(let reason): return ("not-an-article", reason)
    case .walled(let reason): return ("walled", reason)
    case .unrendered(let reason): return ("unrendered", reason)
    case .badURL: return ("failed", "bad url")
    case .emptyDocument: return ("failed", "empty document")
    case nil: return ("failed", "\(error)")
    }
}
