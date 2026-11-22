#if DEBUG
import Foundation
import ReadLaterCore
import ReadLaterUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Applies `LaunchOptions`. This is the only place a debug flag changes the
/// app. Release builds compile the whole file out.
enum DebugLaunch {
    /// Parsed once per process. Every read is a plain static lookup.
    static let options = LaunchOptions()

    /// Runs before `AppModel.init()` opens the store. A reset after that point
    /// would leave the open store pointing at a deleted file.
    static func prepare() {
        guard options.isActive else { return }
        for warning in options.warnings {
            FileHandle.standardError.write(Data("launch: \(warning)\n".utf8))
        }
        switch options.reset {
        case .none:
            break
        case .store:
            resetStore()
        case .defaults:
            resetDefaults()
        case .all:
            resetStore()
            resetDefaults()
        }
        if let seed = options.seedPasteboard {
            seedBoard(seed)
        }
    }

    /// The voice the reader runs on. The production default is the system
    /// synthesizer; the scripted voice exists for tests only.
    @MainActor
    static func makeSpeech(telemetry: TelemetryHub) -> SpeechController {
        if case let .scripted(millisecondsPerWord) = options.voice {
            return ScriptedSpeechController(millisecondsPerWord: millisecondsPerWord)
        }
        return AVSpeechController(telemetry: telemetry)
    }

    private static func resetStore() {
        guard let dir = AppModel.storeDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private static func resetDefaults() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }

    /// The board belongs to the app process. A UI test runner on the host
    /// cannot seed the simulator's board, so the flag does it at launch.
    private static func seedBoard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
#endif
