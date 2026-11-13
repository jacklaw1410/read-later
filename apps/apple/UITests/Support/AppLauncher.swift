import XCTest

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
        return app
    }

    static func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
    }
}
