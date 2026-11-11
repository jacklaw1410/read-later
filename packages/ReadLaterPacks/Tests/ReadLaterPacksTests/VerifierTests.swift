import Foundation
import Testing

@testable import ReadLaterPacks

@Suite("Verifier")
struct VerifierTests {
    @Test("sha256 of known bytes matches the real manifest digest shape")
    func knownVector() {
        // "abc" is the standard SHA-256 test vector.
        let digest = Verifier.sha256Hex(of: Data("abc".utf8))
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("matching digest verifies")
    func pass() {
        let data = Data("pack bytes".utf8)
        let hex = Verifier.sha256Hex(of: data)
        #expect(Verifier.verify(data: data, expectedHex: hex) == .match(digest: hex))
    }

    @Test("comparison is case-insensitive")
    func caseInsensitive() {
        let data = Data("pack bytes".utf8)
        let hex = Verifier.sha256Hex(of: data).uppercased()
        guard case .match = Verifier.verify(data: data, expectedHex: hex) else {
            Issue.record("uppercase digest did not match")
            return
        }
    }

    @Test("wrong digest mismatches with both digests carried")
    func mismatch() {
        let data = Data("pack bytes".utf8)
        let result = Verifier.verify(data: data, expectedHex: String(repeating: "0", count: 64))
        guard case .mismatch(let expected, let actual) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(expected == String(repeating: "0", count: 64))
        #expect(actual == Verifier.sha256Hex(of: data))
    }

    @Test("file URL verifies")
    func fileURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("file pack bytes".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let hex = Verifier.sha256Hex(of: data)
        #expect(try Verifier.verify(contentsOf: url, expectedHex: hex) == .match(digest: hex))
    }
}
