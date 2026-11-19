import ReadLaterCore
import SwiftUI

@main
struct ReadLaterApp: App {
    init() {
        #if DEBUG
        DebugLaunch.prepare()
        DebugProbes.start()
        #endif
        TelemetryHub.shared.configure()
        TelemetryHub.shared.record(TelemetryName.processStart, fields: [
            "uptime": String(format: "%.6f", ProcessInfo.processInfo.systemUptime),
        ])
        TelemetryHub.shared.record(TelemetryName.launchBuild, fields: Self.buildFields)
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
            RootView()
        }
        .defaultSize(width: 430, height: 760)
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
