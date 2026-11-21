import XCTest

/// One screenshot helper for every journey. Checkpoints use stable names so
/// two runs compare by name. Lifetime is keepAlways so the result bundle and
/// the CI export keep them.
enum Artefacts {
    static func capture(_ app: XCUIApplication, name: String, in test: XCTestCase) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}
