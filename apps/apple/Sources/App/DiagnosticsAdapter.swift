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
        hub.telemetryLog.configuredDirectory?.path ?? "memory only (directory not configured)"
    }

    var fileCount: Int { hub.telemetryLog.logFiles().count }

    var pendingCount: Int { hub.telemetryLog.pendingCount }

    var latestEvents: [String] { hub.telemetryLog.tail(5).map(\.event) }

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
