import Foundation
import ReadLaterCore
import ReadLaterUI
import SwiftUI

@main
struct ReadLaterApp: App {
    /// One pack registry and one diagnostics adapter. The reader window and the
    /// macOS Settings scene receive these same instances.
    private let registry: PackRegistry
    private let connectivity: Connectivity
    private let speedStore: SpeedStore
    private let diagnostics: DiagnosticsAdapter
    private let telemetry: TelemetryHub

    init() {
        let registry = PackRegistry()
        let connectivity = Connectivity()
        connectivity.start()
        let telemetry = TelemetryHub.shared
        let speedStore = SpeedStore()
        self.registry = registry
        self.connectivity = connectivity
        self.speedStore = speedStore
        self.telemetry = telemetry
        self.diagnostics = DiagnosticsAdapter(
            packs: registry, speedStore: speedStore, hub: telemetry)
        #if DEBUG
        DebugLaunch.prepare()
        DebugProbes.start()
        if let dir = DebugLaunch.options.telemetryDirectory {
            telemetry.configure(directory: URL(fileURLWithPath: dir, isDirectory: true))
        } else {
            telemetry.configure()
        }
        #else
        telemetry.configure()
        #endif
        telemetry.record(TelemetryName.processStart, fields: [
            "uptime": String(format: "%.6f", ProcessInfo.processInfo.systemUptime),
        ])
        telemetry.record(TelemetryName.launchBuild, fields: Self.buildFields)
        #if os(macOS) && DEBUG
        DebugBenchmarkExit.armIfRequested(telemetry: telemetry)
        #endif
    }

    /// Ties every run to a build: the git SHA stamped by the post-build phase,
    /// the configuration, the hardware model, and the OS version.
    private static var buildFields: [String: String] {
        let sha = Bundle.main.url(forResource: "GitSHA", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        return [
            "commit": sha,
            "configuration": configuration,
            "model": machine,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                registry: registry,
                connectivity: connectivity,
                speedStore: speedStore,
                diagnostics: diagnostics,
                telemetry: telemetry
            )
        }
        .defaultSize(width: 430, height: 760)
        #if os(macOS)
        Settings {
            SettingsView(packs: registry, diagnostics: diagnostics)
        }
        #endif
    }
}
