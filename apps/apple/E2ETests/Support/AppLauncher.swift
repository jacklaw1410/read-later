import XCTest
#if os(macOS)
import AppKit
#endif

/// The one launch path for every journey.
///
/// `--debug.preset=e2e` resets the store and the defaults, selects the
/// scripted voice, turns animations off, pins the light appearance and the
/// English locale. A journey may add `--debug.<key>=<value>` to change one
/// field; it must not add production arguments.
enum AppLauncher {
    static func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--debug.preset=e2e"] + extraArguments
        app.launch()
        app.activate()
        frontForTaps()
        return app
    }

    static func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
        app.activate()
        frontForTaps()
    }

    /// macOS taps synthesize at screen coordinates, so the window must be
    /// frontmost. Under automation neither the runner's `activate()` nor the
    /// app's own activation is honoured; a LaunchServices open fronts it.
    /// Queries do not need this. Every tap does. Elsewhere a no-op.
    private static func frontForTaps() {
        #if os(macOS)
        // Taps synthesize at screen coordinates and XCUI interrogates every
        // window near the tap point, so a cluttered desktop derails the tap
        // into other apps. Hide them; only this window stays up. The apps
        // are hidden, not quit: click any dock icon to bring one back.
        //
        // The app is located next to this runner, not by bundle
        // identifier: a stale copy from another build directory shares the
        // identifier and would steal the open.
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("ReadLater.app", isDirectory: true)
        NSWorkspace.shared.hideOtherApplications()
        for running in NSWorkspace.shared.runningApplications
            where running.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
        {
            running.unhide()
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appURL.path]
        try? open.run()
        // The window manager and the accessibility tree settle on
        // different clocks. A tap that follows too soon uses the
        // pre-front frame and lands on the wrong app.
        Thread.sleep(forTimeInterval: 2)
        #endif
    }
}
