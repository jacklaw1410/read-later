#if DEBUG
import XCTest

@testable import ReadLaterUI

final class LaunchOptionsTests: XCTestCase {
    func test_noFlagsMeansProductionBehaviour() {
        let options = LaunchOptions(arguments: ["/path/to/app"])
        XCTAssertFalse(options.isActive)
        XCTAssertEqual(options.reset, .none)
        XCTAssertEqual(options.voice, .system)
        XCTAssertTrue(options.animations)
        XCTAssertNil(options.appearance)
        XCTAssertNil(options.locale)
        XCTAssertTrue(options.warnings.isEmpty)
    }

    func test_e2ePresetFillsTheDebugSurface() {
        let options = LaunchOptions(arguments: ["app", "--debug.preset=e2e"])
        XCTAssertTrue(options.isActive)
        XCTAssertEqual(options.reset, .all)
        XCTAssertEqual(options.voice, .scripted(millisecondsPerWord: 80))
        XCTAssertFalse(options.animations)
        XCTAssertEqual(options.appearance, .light)
        XCTAssertEqual(options.locale, "en")
        XCTAssertTrue(options.warnings.isEmpty)
    }

    func test_explicitFlagOverridesOnePresetField() {
        let options = LaunchOptions(arguments: [
            "app", "--debug.preset=e2e", "--debug.voice-pace=120",
        ])
        XCTAssertEqual(options.voice, .scripted(millisecondsPerWord: 120))
        // Every other preset field survives.
        XCTAssertEqual(options.reset, .all)
        XCTAssertFalse(options.animations)
    }

    func test_flagsWorkWithoutAPreset() {
        let options = LaunchOptions(arguments: [
            "app", "--debug.reset=store", "--debug.voice=scripted",
            "--debug.animations=off", "--debug.appearance=dark", "--debug.locale=zh_HK",
        ])
        XCTAssertTrue(options.isActive)
        XCTAssertEqual(options.reset, .store)
        XCTAssertEqual(options.voice, .scripted(millisecondsPerWord: 80))
        XCTAssertFalse(options.animations)
        XCTAssertEqual(options.appearance, .dark)
        XCTAssertEqual(options.locale, "zh_HK")
    }

    func test_paceIsClampedToTheAllowedRange() {
        XCTAssertEqual(
            LaunchOptions(arguments: ["app", "--debug.voice=scripted", "--debug.voice-pace=1"]).voice,
            .scripted(millisecondsPerWord: 20)
        )
        XCTAssertEqual(
            LaunchOptions(arguments: ["app", "--debug.voice=scripted", "--debug.voice-pace=5000"]).voice,
            .scripted(millisecondsPerWord: 1_000)
        )
    }

    func test_badValuesKeepTheCurrentValueAndWarn() {
        let options = LaunchOptions(arguments: [
            "app", "--debug.preset=e2e", "--debug.appearance=sepia",
            "--debug.animations=sometimes", "--debug.reset=partial",
            "--debug.voice=robot",
        ])
        XCTAssertEqual(options.appearance, .light)
        XCTAssertFalse(options.animations)
        XCTAssertEqual(options.reset, .all)
        XCTAssertEqual(options.voice, .scripted(millisecondsPerWord: 80))
        XCTAssertEqual(options.warnings.count, 4)
    }

    func test_unknownPresetKeepsTheDefaultSurfaceAndWarns() {
        let options = LaunchOptions(arguments: ["app", "--debug.preset=nightly"])
        XCTAssertTrue(options.isActive)
        XCTAssertEqual(options.reset, .none)
        XCTAssertEqual(options.voice, .system)
        XCTAssertTrue(options.animations)
        XCTAssertNil(options.appearance)
        XCTAssertEqual(options.warnings, ["ignored preset=nightly: expected e2e"])
    }

    func test_unknownKeyIsIgnoredWithAWarning() {
        let options = LaunchOptions(arguments: ["app", "--debug.teleport=yes"])
        XCTAssertTrue(options.isActive)
        XCTAssertEqual(options.voice, .system)
        XCTAssertEqual(options.warnings, ["ignored unknown flag --debug.teleport"])
    }

    func test_flagWithoutAValueIsIgnoredWithAWarning() {
        let options = LaunchOptions(arguments: ["app", "--debug.reset"])
        XCTAssertTrue(options.isActive)
        XCTAssertEqual(options.reset, .none)
        XCTAssertEqual(options.warnings, ["ignored --debug.reset: expected key=value"])
    }

    func test_emptyLocaleIsIgnored() {
        let options = LaunchOptions(arguments: ["app", "--debug.locale="])
        XCTAssertNil(options.locale)
        XCTAssertEqual(options.warnings, ["ignored locale: the value is empty"])
    }

    func test_realArgumentsAreNotMistakenForDebugFlags() {
        let options = LaunchOptions(arguments: [
            "app", "--snapshot", "/tmp/out", "--reset", "e2e",
        ])
        XCTAssertFalse(options.isActive)
        XCTAssertEqual(options.reset, .none)
    }
}
#endif
