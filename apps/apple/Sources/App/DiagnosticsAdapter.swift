import Foundation
import ReadLaterCore
import ReadLaterUI

/// Feeds the diagnostics screen. It is the only place that reads the installed
/// dictionary version, the reading pace, and the telemetry log.
@MainActor
final class DiagnosticsAdapter: DiagnosticsExporting {
    private let packs: any CapabilityPacks
    private let speedStore: SpeedStore
    private let hub: TelemetryHub

    init(packs: any CapabilityPacks, speedStore: SpeedStore, hub: TelemetryHub) {
        self.packs = packs
        self.speedStore = speedStore
        self.hub = hub
    }

    var isEnabled: Bool { DiagnosticsExport.isEnabled }

    var sourcePath: String {
        hub.oplog.configuredDirectory?.path ?? "memory only (directory not configured)"
    }

    var fileCount: Int { hub.oplog.logFiles().count }

    var pendingCount: Int { hub.oplog.pendingCount }

    var latestEvents: [String] { hub.oplog.tail(5).map(\.event) }

    var pullCommand: String {
        DiagnosticsExport.pullCommand(
            bundleID: Bundle.main.bundleIdentifier ?? "app.readlater.reader"
        )
    }

    func stage() throws -> URL {
        try DiagnosticsExport.stage(
            dictionaryVersion: packs.installedVersion ?? "not-installed",
            pace: String(speedStore.speed),
            hub: hub
        )
    }
}
