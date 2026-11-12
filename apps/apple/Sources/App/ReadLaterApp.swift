import ReadLaterCore
import SwiftUI

@main
struct ReadLaterApp: App {
    init() {
        TelemetryHub.shared.configure()
        TelemetryHub.shared.record(TelemetryName.processStart)
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
