import CryptoKit
import Foundation

/// Typed sha256 verification outcome. Never a bare Bool: a mismatch carries
/// both digests so the caller can log without recomputing.
public enum VerificationResult: Sendable, Equatable {
    case match(digest: String)
    case mismatch(expected: String, actual: String)
}

public enum Verifier {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hex comparison is case-insensitive.
    public static func verify(data: Data, expectedHex: String) -> VerificationResult {
        let actual = sha256Hex(of: data)
        if actual.lowercased() == expectedHex.lowercased() {
            return .match(digest: actual)
        }
        return .mismatch(expected: expectedHex, actual: actual)
    }

    public static func verify(contentsOf url: URL, expectedHex: String) throws -> VerificationResult {
        let data = try Data(contentsOf: url)
        return verify(data: data, expectedHex: expectedHex)
    }
}
