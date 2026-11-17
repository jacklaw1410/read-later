import ReadLaterUI
import XCTest

/// Device drivers for the latency plan
/// (read-later-research `spec/device-verification-latency.md`, M2 and M4).
///
/// Each test seeds one article through `--debug.seedTextB64`, then runs its
/// batch in the same launch. The app saves the article with its place at
/// word zero, so the test opens the resume offer. Nothing is typed: typing
/// the raw text (4,500 words for M4) stalls the run, and its keystrokes
/// land inside the measurement window.
///
/// The batch taps play, pause or scrub at random times drawn from
/// `LATENCY_SEED`, and attaches the schedule to the result bundle.
/// The phone's oplog holds the handler times that `devicebench align` reads.
///
/// The article text is not in the repo. The Mac passes it as base64 in
/// `TEST_RUNNER_LATENCY_TEXT_B64`, and the test checks the word count first.
/// The runner forwards it to the app as `--debug.seedTextB64`.
///
/// Every tap is preceded by a read of the play button. A pause is sent only
/// when the button offers Pause, and a batch stops when the button offers
/// Replay, because a tap there restarts the article. A pause that does not
/// hold is logged, not failed, because it is a measurement.
///
/// Skipped unless `TEST_RUNNER_LATENCY_DEVICE_RUN=1` is set. `LATENCY_CYCLES`
/// sets the batch size (default 12 for M2, 20 for M4). `LATENCY_SEED` sets the
/// random seed (default 1).
///
/// The launch keeps the store (`--debug.reset=none`) and uses the system voice
/// (`--debug.voice=system`). The e2e preset would otherwise wipe the store and
/// speak with the scripted voice.
final class LatencyDeviceTests: XCTestCase {
    /// M2: random pauses during playback on the 200-word article.
    func test_m2_pauseBatchOnShortArticle() throws {
        let run = try DeviceRun.read(expectedWords: 200, defaultCycles: 12)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        pauseBatch(app, run: run)
    }

    /// M4: random scrubs during playback on the 4,500-word article.
    func test_m4_scrubBatchOnLongArticle() throws {
        let run = try DeviceRun.read(expectedWords: 4_500, defaultCycles: 20)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        scrubBatch(app, run: run)
    }

    // MARK: - Launch

    /// A run left over from an earlier iteration makes `launch()` fail with
    /// "Failed to terminate". Terminating first makes each launch start clean.
    private func terminateApp() {
        XCUIApplication(bundleIdentifier: "app.readlater.reader").terminate()
    }

    // MARK: - Seeding

    /// Opens the seeded article through the newest library row. The seed
    /// flag writes the article and its place (word zero) before the library
    /// refresh, so its row is on top on launch. No typing.
    private func openSeeded(_ app: XCUIApplication, run: DeviceRun) {
        JourneySteps.openLibraryRow(app, title: run.articleTitle)

        XCTAssertTrue(
            app.buttons[AccessibilityID.readerPlayPause].waitForExistence(timeout: Waits.screen),
            "the seeded article did not open"
        )
    }

    // MARK: - Batches

    private func pauseBatch(_ app: XCUIApplication, run: DeviceRun) {
        let play = app.buttons[AccessibilityID.readerPlayPause]
        var rng = SplitMix64(state: run.seed)
        var log: [String] = []

        guard startPlayback(app, play) else {
            attach(["playback did not start"], name: "m2-schedule-seed-\(run.seed)")
            return
        }

        var pauses = 0
        var attempts = 0
        while pauses < run.cycles, attempts < run.cycles * 4 {
            attempts += 1
            if play.label == "Replay" {
                log.append("article ended before pause \(pauses + 1)")
                break
            }
            if play.label == "Play" {
                // The reader stopped without a tap. Resume, and do not count it as a pause.
                log.append("resumed before pause \(pauses + 1): the reader had stopped")
                guard startPlayback(app, play) else { break }
                continue
            }
            guard play.label == "Pause" else {
                log.append("unexpected label \(play.label) before pause \(pauses + 1)")
                break
            }

            Thread.sleep(forTimeInterval: Double.random(in: 0.8...2.5, using: &rng))
            // Read again: the reader may have ended during the wait.
            guard play.label == "Pause" else { continue }

            pauses += 1
            JourneySteps.tap(app, play)
            let held = waitForLabel("Play", on: play, timeout: 2)
            log.append(
                "pause \(pauses): tapped while the button read Pause; "
                + (held ? "label Play within 2 s" : "label still \(play.label) after 2 s")
            )

            Thread.sleep(forTimeInterval: 1.0)
            if play.label == "Play" {
                JourneySteps.tap(app, play)
                _ = waitForLabel("Pause", on: play)
            }
        }
        attach(log, name: "m2-schedule-seed-\(run.seed)")
    }

    private func scrubBatch(_ app: XCUIApplication, run: DeviceRun) {
        let play = app.buttons[AccessibilityID.readerPlayPause]
        let progress = app.descendants(matching: .any)[AccessibilityID.readerProgress]
        XCTAssertTrue(progress.waitForExistence(timeout: Waits.screen), "the reading progress element is missing")
        var rng = SplitMix64(state: run.seed)
        var log: [String] = []

        guard startPlayback(app, play) else {
            attach(["playback did not start"], name: "m4-schedule-seed-\(run.seed)")
            return
        }

        var scrubs = 0
        var attempts = 0
        while scrubs < run.cycles, attempts < run.cycles * 4 {
            attempts += 1
            if play.label == "Replay" {
                log.append("article ended before scrub \(scrubs + 1)")
                break
            }
            if play.label == "Play" {
                log.append("resumed before scrub \(scrubs + 1): the reader had stopped")
                guard startPlayback(app, play) else { break }
                continue
            }
            guard play.label == "Pause" else {
                log.append("unexpected label \(play.label) before scrub \(scrubs + 1)")
                break
            }

            Thread.sleep(forTimeInterval: Double.random(in: 1.5...4.0, using: &rng))
            guard play.label == "Pause" else { continue }

            scrubs += 1
            let from = Double.random(in: 0.05...0.95, using: &rng)
            let to = Double.random(in: 0.05...0.95, using: &rng)
            let start = progress.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            let end = progress.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
            log.append(
                "scrub \(scrubs): from \(String(format: "%.3f", from)) to \(String(format: "%.3f", to)); "
                + "label \(play.label)"
            )
        }
        attach(log, name: "m4-schedule-seed-\(run.seed)")
    }

    /// Taps play from the paused start and waits for the pause label. Returns
    /// false when the article already ended, so the batch does not start.
    private func startPlayback(_ app: XCUIApplication, _ play: XCUIElement) -> Bool {
        if play.label == "Pause" { return true }
        if play.label == "Replay" { return false }
        JourneySteps.tap(app, play)
        return waitForLabel("Pause", on: play)
    }

    // MARK: - Helpers

    /// True when the element reads `expected` before the timeout.
    @discardableResult
    private func waitForLabel(_ expected: String, on element: XCUIElement, timeout: TimeInterval = Waits.state) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ lines: [String], name: String) {
        let data = Data(lines.joined(separator: "\n").utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The environment for one device run. Missing `TEST_RUNNER_LATENCY_DEVICE_RUN`
/// skips the test; a missing or wrong-length article also skips it, so a run
/// never seeds the wrong text. The base64 text rides to the app as
/// `--debug.seedTextB64`; `reset=none` keeps the store, and the seed write
/// is the newest row, so every run starts at word zero.
private struct DeviceRun {
    let cycles: Int
    let seed: UInt64
    private let encodedText: String

    var launchArguments: [String] {
        ["--debug.reset=none", "--debug.voice=system", "--debug.seedTextB64=\(encodedText)"]
    }

    /// The library row title for the seeded article: same rule the app
    /// uses to derive it, so the test taps the seeded row and no other.
    var articleTitle: String {
        guard let data = Data(base64Encoded: encodedText),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return PasteLoader.derivedTitle(from: text)
    }

    static func read(expectedWords: Int, defaultCycles: Int) throws -> DeviceRun {
        let env = ProcessInfo.processInfo.environment
        guard env["LATENCY_DEVICE_RUN"] == "1" else {
            throw XCTSkip("device latency runs only: set TEST_RUNNER_LATENCY_DEVICE_RUN=1")
        }
        guard let encoded = env["LATENCY_TEXT_B64"],
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8)
        else {
            throw XCTSkip("set TEST_RUNNER_LATENCY_TEXT_B64 to the base64 article text")
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        guard words == expectedWords else {
            throw XCTSkip("article has \(words) words, expected \(expectedWords)")
        }
        let cycles = env["LATENCY_CYCLES"].flatMap(Int.init) ?? defaultCycles
        let seed = env["LATENCY_SEED"].flatMap(UInt64.init) ?? 1
        return DeviceRun(cycles: cycles, seed: seed, encodedText: encoded)
    }
}

/// A fixed generator, so the same seed gives the same schedule on any Mac.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
