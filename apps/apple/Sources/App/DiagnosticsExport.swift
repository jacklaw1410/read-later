import Foundation
import ReadLaterCore

#if canImport(Darwin)
import Darwin
#endif

/// One action that produces a folder the analyst can take off the device:
/// the oplog files plus a `summary.json` describing the build.
///
/// The files come from `Application Support/Oplog/` inside the app
/// container. The same folder is reachable without the UI (see
/// `pullCommand`, shown in the Diagnostics screen and the app README).
enum DiagnosticsExport {
    struct Summary: Codable {
        var schema: String
        var buildSHA: String
        var bundleID: String
        var appVersion: String
        var buildNumber: String
        var os: String
        var deviceModel: String
        var pace: String
        var dictionaryVersion: String
        var exportedAtISO: String
        var sessionID: String
        var oplogSource: String
        var oplogFiles: [String]
    }

    /// Flushes the oplog, copies every log file plus `summary.json` into a
    /// fresh folder in the temporary directory, and returns that folder.
    /// Throws only here, at the reader's explicit request — never on the
    /// reader path.
    static func stage(
        dictionaryVersion: String,
        pace: String,
        hub: TelemetryHub = .shared
    ) throws -> URL {
        hub.flush()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadLater-Diagnostics-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var names: [String] = []
        for file in hub.oplog.logFiles() {
            let target = folder.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: file, to: target)
            names.append(file.lastPathComponent)
        }
        let summary = buildSummary(
            dictionaryVersion: dictionaryVersion, pace: pace,
            oplogFiles: names.sorted(), hub: hub
        )
        let data = try JSONEncoder().encode(summary)
        try data.write(to: folder.appendingPathComponent("summary.json"), options: .atomic)
        return folder
    }

    static func buildSummary(
        dictionaryVersion: String,
        pace: String,
        oplogFiles: [String] = [],
        hub: TelemetryHub = .shared
    ) -> Summary {
        let info = Bundle.main.infoDictionary
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Summary(
            schema: "rl-diagnostics-1",
            buildSHA: BuildInfo.gitSHA,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: (info?["CFBundleShortVersionString"] as? String) ?? "unknown",
            buildNumber: (info?["CFBundleVersion"] as? String) ?? "unknown",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: Self.deviceModel(),
            pace: pace,
            dictionaryVersion: dictionaryVersion,
            exportedAtISO: formatter.string(from: Date()),
            sessionID: hub.oplog.session,
            oplogSource: hub.oplog.configuredDirectory?.path ?? "memory-only (not configured)",
            oplogFiles: oplogFiles
        )
    }

    /// The `devicectl` command that pulls the same Oplog folder without the
    /// UI. `<UDID>` is the device from `xcrun devicectl list devices`.
    static func pullCommand(bundleID: String, source: String = "Library/Application Support/Oplog") -> String {
        "xcrun devicectl device copy from --device <UDID>"
            + " --domain-type appDataContainer --domain-identifier \(bundleID)"
            + " --source \"\(source)\" --destination ./oplog-from-device"
    }

    /// The `uname` machine string, e.g. `arm64` or `iPhone17,2`.
    static func deviceModel() -> String {
        #if canImport(Darwin)
        var uts = utsname()
        uname(&uts)
        return withUnsafeBytes(of: uts.machine) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        #else
        return "unknown"
        #endif
    }
}
