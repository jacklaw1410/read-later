import Foundation
import Testing
@testable import ReadLaterCore

/// Guards the measurement vocabulary. A duplicate name makes a trace and an
/// export disagree; a constant with no production call site is dead vocabulary.
struct TelemetryNameTests {
    /// The repo root, from this file's path:
    /// Tests/ReadLaterCoreTests/X.swift -> packages/ReadLaterCore -> packages -> root.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private enum ScanError: Error {
        case missingNameEnum
    }

    @Test("Every telemetry name is unique and has a production call site")
    func namesAreUniqueAndEmitted() throws {
        let definition = try String(
            contentsOf: Self.repoRoot
                .appendingPathComponent("packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryLog.swift"),
            encoding: .utf8
        )
        let names = try Self.extractNames(from: definition)
        #expect(!names.isEmpty)
        let values = names.map(\.value)
        #expect(Set(values).count == values.count)

        let sources = try Self.productionSources()
        for name in names {
            let call = "TelemetryName.\(name.identifier)"
            #expect(sources.contains { $0.contains(call) }, "\(call) has no production call site")
        }
    }

    private static func extractNames(from text: String) throws -> [(identifier: String, value: String)] {
        guard let start = text.range(of: "public enum TelemetryName {"),
              let end = text.range(of: "\n}", range: start.upperBound..<text.endIndex)
        else { throw ScanError.missingNameEnum }
        let body = String(text[start.upperBound..<end.lowerBound])
        let pattern = #"public static let (\w+) = "([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = body as NSString
        return regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges == 3 else { return nil }
            return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
        }
    }

    private static func productionSources() throws -> [String] {
        let manager = FileManager.default
        var out: [String] = []
        for root in ["packages", "apps"] {
            let base = Self.repoRoot.appendingPathComponent(root)
            guard let paths = try? manager.subpathsOfDirectory(atPath: base.path) else { continue }
            for path in paths where path.hasSuffix(".swift")
                && !path.contains("/Tests/")
                && !path.contains("/E2ETests/")
                && !path.contains("/.build/")
                && path != "ReadLaterCore/Sources/ReadLaterCore/TelemetryLog.swift"
            {
                out.append(try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8))
            }
        }
        return out
    }
}
