import SwiftUI

@main
struct ReadLaterApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 430, height: 760)
        #if os(macOS)
        Settings {
            DictionariesSettings()
        }
        #endif
    }
}
