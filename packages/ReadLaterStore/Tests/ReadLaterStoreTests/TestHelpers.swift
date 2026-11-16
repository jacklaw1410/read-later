import Foundation
import ReadLaterCore
@testable import ReadLaterStore

/// A store on a fresh temp file, removed when the test finishes.
func makeTemporaryStore(device: String = "test-device", telemetry: TelemetryHub = TelemetryHub()) throws -> (Store, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReadLaterStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try Store(databaseURL: dir.appendingPathComponent("store.sqlite"), device: device, telemetry: telemetry)
    return (store, dir)
}

func removeTemporaryStore(at dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

func makeSamplePlan() -> BlockPlan {
    let text0 = "Attention is a practice, not a talent."
    let text1 = "The mind wanders, and that is normal."
    let block0 = Block(
        id: 0, kind: .prose, confidence: 0.98, reason: "p", text: text0,
        spoken: [Sentence(offset: 0, length: text0.count, text: text0)])
    let block1 = Block(
        id: 1, kind: .prose, confidence: 0.97, reason: "p", text: text1,
        spoken: [Sentence(offset: 0, length: text1.count, text: text1)])
    return BlockPlan(source: "test", sourceSHA256: "abc", blocks: [block0, block1])
}

func makeSampleDocument() -> Document {
    Document(url: URL(string: "https://example.com/article"), title: "Sample", plan: makeSamplePlan())
}
