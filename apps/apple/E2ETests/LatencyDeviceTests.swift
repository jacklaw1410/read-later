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

    /// Control: plays the 4,500-word article with no gesture for 90 s. Shows
    /// whether speech runs dry on its own, without a scrub.
    func test_control_playNoGestureOnLongArticle() throws {
        let run = try DeviceRun.read(expectedWords: 4_500, defaultCycles: 1)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        let play = app.buttons[AccessibilityID.readerPlayPause]
        XCTAssertTrue(startPlayback(app, play), "the voice did not start")
        Thread.sleep(forTimeInterval: 90)
    }

    /// M3: play taps from the paused start on the 200-word article.
    func test_m3_playBatchOnShortArticle() throws {
        let run = try DeviceRun.read(expectedWords: 200, defaultCycles: 10)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        playBatch(app, run: run)
    }

    /// M10: seeks (progress taps) during playback on the 200-word article.
    /// The gesture is the same tap the M4 batch uses; the analysis reads
    /// release-to-sound per seek from the recording. The last tap lands at
    /// 0.97, and the driver waits for Replay: the article ending on time
    /// proves the voice followed the wash there. (The first-word oplog
    /// event needs an active telemetry run, which the seeded flow never
    /// starts, so the oplog side is unavailable in this build.)
    func test_m10_seekBatchOnShortArticle() throws {
        let run = try DeviceRun.read(expectedWords: 200, defaultCycles: 20)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        seekBatch(app, run: run)
    }

    /// M14: word taps end to end on the 200-word article. Each counted tap
    /// opens a card (hit or miss), closes it, and restores playback.
    func test_m14_lookupBatchOnSeededArticle() throws {
        let run = try DeviceRun.read(expectedWords: 200, defaultCycles: 20)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        lookupBatch(app, run: run)
    }

    /// M14 rerun: same batch on a 600-word article. The 200-word article
    /// ended at lookup 12 in sessA; 600 words keep all 20 taps in playback
    /// at 1x (about 4.3 min of speech for about 2 min of tapping).
    func test_m14_lookupBatchOnLongArticle() throws {
        let run = try DeviceRun.read(expectedWords: 600, defaultCycles: 20)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        lookupBatch(app, run: run)
    }

    /// M15: warm opens of the long article from the library. The first open
    /// after install is the cold sample; the rest are warm.
    func test_m15_openBatchOnLongArticle() throws {
        let run = try DeviceRun.read(expectedWords: 3_160, defaultCycles: 20)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openBatch(app, run: run)
    }

    /// M16: rate legs 1x -> 1.5x -> 1x on the 200-word article. Five plus
    /// taps step 1.0 to 1.5; five minus taps step back. Each leg counts once.
    func test_m16_rateBatchOnSeededArticle() throws {
        let run = try DeviceRun.read(expectedWords: 200, defaultCycles: 10)
        terminateApp()
        let app = AppLauncher.launch(extraArguments: run.launchArguments)
        openSeeded(app, run: run)
        rateBatch(app, run: run)
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
            // The rail scrubber is vertical (fraction = location.y / height):
            // the drag runs vertically with fixed dx, and both
            // ends vary. A horizontal drag releases at 0.5 every time
            // (sessA-m4: 40/40 commits at 0.5000); a tap-only driver would
            // not exercise the release path the gate measures.
            let from = Double.random(in: 0.05...0.95, using: &rng)
            let to = Double.random(in: 0.05...0.95, using: &rng)
            let start = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let end = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
            start.press(forDuration: 0.1, thenDragTo: end)
            log.append(
                "scrub \(scrubs): vertical drag dy \(String(format: "%.3f", from))->\(String(format: "%.3f", to)); "
                + "label \(play.label)"
            )
        }
        attach(log, name: "m4-schedule-seed-\(run.seed)")
    }

    /// M3 play batch: tap play from paused, let speech run, tap pause.
    private func playBatch(_ app: XCUIApplication, run: DeviceRun) {
        let play = app.buttons[AccessibilityID.readerPlayPause]
        var log: [String] = []
        var plays = 0
        var attempts = 0
        while plays < run.cycles, attempts < run.cycles * 4 {
            attempts += 1
            if play.label == "Replay" {
                log.append("article ended before play \(plays + 1)")
                break
            }
            if play.label == "Pause" {
                // Left over from a previous leg. Pause first, then count the leg.
                JourneySteps.tap(app, play)
                _ = waitForLabel("Play", on: play)
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard play.label == "Play" else {
                log.append("unexpected label \(play.label) before play \(plays + 1)")
                break
            }
            plays += 1
            JourneySteps.tap(app, play)
            let held = waitForLabel("Pause", on: play, timeout: 2)
            log.append("play \(plays): tapped while the button read Play; " + (held ? "label Pause within 2 s" : "label still \(play.label) after 2 s"))
            Thread.sleep(forTimeInterval: 3.0)
            if play.label == "Pause" {
                JourneySteps.tap(app, play)
                _ = waitForLabel("Play", on: play)
            }
            Thread.sleep(forTimeInterval: 0.7)
        }
        attach(log, name: "m3-schedule-seed-\(run.seed)")
    }

    /// M14 lookup batch: tap a word, wait for a card, close it, resume.
    private func lookupBatch(_ app: XCUIApplication, run: DeviceRun) {
        let play = app.buttons[AccessibilityID.readerPlayPause]
        let wash = app.scrollViews[AccessibilityID.readerWash]
        XCTAssertTrue(wash.waitForExistence(timeout: Waits.screen), "the reader body is missing")
        let card = app.otherElements[AccessibilityID.lookupCard]
        let miss = app.otherElements[AccessibilityID.missCard]
        var rng = SplitMix64(state: run.seed)
        var log: [String] = []

        guard startPlayback(app, play) else {
            attach(["playback did not start"], name: "m14-schedule-seed-\(run.seed)")
            return
        }

        var lookups = 0
        var attempts = 0
        let dxs = [0.2, 0.35, 0.5, 0.65, 0.8]
        let dys = stride(from: 0.25, through: 0.85, by: 0.1).map { $0 }
        while lookups < run.cycles, attempts < run.cycles * 8 {
            attempts += 1
            if play.label == "Replay" {
                log.append("article ended before lookup \(lookups + 1)")
                break
            }
            if play.label == "Play" {
                log.append("resumed before lookup \(lookups + 1): the reader had stopped")
                guard startPlayback(app, play) else { break }
                continue
            }
            Thread.sleep(forTimeInterval: 1.0)
            guard play.label == "Pause" else { continue }

            let dx = dxs[Int.random(in: 0..<dxs.count, using: &rng)]
            let dy = dys[Int.random(in: 0..<dys.count, using: &rng)]
            JourneySteps.front(app)
            let tapStart = Date()
            wash.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            let opened: String? = {
                if card.waitForExistence(timeout: 0.8) { return "card" }
                if miss.exists { return "miss" }
                return nil
            }()
            guard let kind = opened else {
                log.append("lookup \(lookups + 1) attempt \(attempts): no card at (\(dx), \(dy))")
                dismissCardIfPresent(app)
                continue
            }
            let popoverMs = Date().timeIntervalSince(tapStart) * 1000.0
            lookups += 1
            log.append("lookup \(lookups): \(kind) opened at (\(dx), \(dy)) tap-to-card \(String(format: "%.0f", popoverMs)) ms")
            let closeStart = Date()
            dismissCardIfPresent(app)
            _ = card.waitForNonExistence(timeout: Waits.state)
            _ = miss.waitForNonExistence(timeout: Waits.state)
            if play.label == "Play" {
                // Close restores only when playback was live. Tap back into it.
                JourneySteps.tap(app, play)
                _ = waitForLabel("Pause", on: play)
                let resumeMs = Date().timeIntervalSince(closeStart) * 1000.0
                log.append("lookup \(lookups): resumed with a tap after close, close-to-pause \(String(format: "%.0f", resumeMs)) ms")
            } else {
                let resumeMs = Date().timeIntervalSince(closeStart) * 1000.0
                log.append("lookup \(lookups): auto-resumed on close, close-to-pause \(String(format: "%.0f", resumeMs)) ms")
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        attach(log, name: "m14-schedule-seed-\(run.seed)")
    }

    /// Closes a lookup or miss card through its Close button when present.
    private func dismissCardIfPresent(_ app: XCUIApplication) {
        for prefix in ["Close", "Not now"] {
            let button = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", prefix)
            ).firstMatch
            if button.exists {
                JourneySteps.tap(app, button)
                return
            }
        }
    }

    /// M15 open batch: library row in, back out, once per cycle.
    private func openBatch(_ app: XCUIApplication, run: DeviceRun) {
        var log: [String] = []
        for cycle in 1...run.cycles {
            let library = app.buttons[AccessibilityID.entryLibrary]
            guard library.waitForExistence(timeout: Waits.screen) else {
                log.append("open \(cycle): library button missing")
                break
            }
            JourneySteps.tap(app, library)
            let row = app.buttons.containing(.staticText, identifier: run.articleTitle).firstMatch
            guard row.waitForExistence(timeout: Waits.screen) else {
                log.append("open \(cycle): no library row for title")
                break
            }
            let tapStart = Date()
            JourneySteps.tap(app, row)
            let reader = JourneySteps.texts(app, id: AccessibilityID.readerTitle)
            if reader.waitForExistence(timeout: Waits.screen) {
                let openMs = Date().timeIntervalSince(tapStart) * 1000.0
                log.append("open \(cycle): reader showing, tap-to-reader \(String(format: "%.0f", openMs)) ms")
            } else {
                log.append("open \(cycle): reader did not open")
                break
            }
            let back = app.buttons[AccessibilityID.readerBack]
            guard back.waitForExistence(timeout: Waits.screen) else {
                log.append("open \(cycle): back button missing")
                break
            }
            JourneySteps.tap(app, back)
            if library.waitForExistence(timeout: Waits.screen) {
                log.append("open \(cycle): back at entry")
            } else {
                log.append("open \(cycle): entry did not return")
                break
            }
        }
        attach(log, name: "m15-schedule-seed-\(run.seed)")
    }

    /// M16 rate batch: plus legs up to 1.5x, minus legs back to 1.0x.
    private func rateBatch(_ app: XCUIApplication, run: DeviceRun) {
        let play = app.buttons[AccessibilityID.readerPlayPause]
        let speed = app.buttons[AccessibilityID.readerSpeed]
        let plus = app.buttons[AccessibilityID.railSpeedPlus]
        let minus = app.buttons[AccessibilityID.railSpeedMinus]
        XCTAssertTrue(plus.waitForExistence(timeout: Waits.screen), "the speed plus stepper is missing")
        XCTAssertTrue(minus.waitForExistence(timeout: Waits.screen), "the speed minus stepper is missing")
        var log: [String] = []

        guard startPlayback(app, play) else {
            attach(["playback did not start"], name: "m16-schedule-seed-\(run.seed)")
            return
        }

        var legs = 0
        var attempts = 0
        var up = true
        while legs < run.cycles, attempts < run.cycles * 4 {
            attempts += 1
            if play.label == "Replay" {
                log.append("article ended before leg \(legs + 1)")
                break
            }
            if play.label == "Play" {
                log.append("resumed before leg \(legs + 1): the reader had stopped")
                guard startPlayback(app, play) else { break }
                continue
            }
            legs += 1
            let legStart = Date()
            let stepper = up ? plus : minus
            for _ in 0..<5 {
                JourneySteps.tap(app, stepper)
                Thread.sleep(forTimeInterval: 0.4)
            }
            log.append("leg \(legs) \(up ? "up" : "down"): speed reads \(JourneySteps.displayed(speed)) after \(String(format: "%.1f", Date().timeIntervalSince(legStart))) s")
            up.toggle()
            Thread.sleep(forTimeInterval: 3.0)
        }
        attach(log, name: "m16-schedule-seed-\(run.seed)")
    }

    /// M10 seek batch: varied taps, then a 0.97 tap with a Replay wait.
    private func seekBatch(_ app: XCUIApplication, run: DeviceRun) {
        let play = app.buttons[AccessibilityID.readerPlayPause]
        let progress = app.descendants(matching: .any)[AccessibilityID.readerProgress]
        XCTAssertTrue(progress.waitForExistence(timeout: Waits.screen), "the reading progress element is missing")
        var rng = SplitMix64(state: run.seed &+ 0x9E37)
        var log: [String] = []

        guard startPlayback(app, play) else {
            attach(["playback did not start"], name: "m10-schedule-seed-\(run.seed)")
            return
        }

        var seeks = 0
        var attempts = 0
        while seeks < run.cycles, attempts < run.cycles * 4 {
            attempts += 1
            if play.label == "Replay" {
                log.append("article ended before seek \(seeks + 1)")
                break
            }
            if play.label == "Play" {
                log.append("resumed before seek \(seeks + 1): the reader had stopped")
                guard startPlayback(app, play) else { break }
                continue
            }
            guard play.label == "Pause" else {
                log.append("unexpected label \(play.label) before seek \(seeks + 1)")
                break
            }

            Thread.sleep(forTimeInterval: Double.random(in: 1.5...4.0, using: &rng))
            guard play.label == "Pause" else { continue }

            seeks += 1
            let at = Double.random(in: 0.05...0.95, using: &rng)
            progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: at)).tap()
            log.append("seek \(seeks): tap at dy \(String(format: "%.3f", at)); label \(play.label)")
        }

        // Voice-follow proof: park near the end and wait for Replay.
        if play.label == "Pause" {
            progress.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
            let ended = waitForLabel("Replay", on: play, timeout: 30)
            log.append("final tap at dy 0.970: " + (ended ? "Replay within 30 s" : "label still \(play.label) after 30 s"))
        } else {
            log.append("final tap skipped: label \(play.label)")
        }
        attach(log, name: "m10-schedule-seed-\(run.seed)")
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
        ["--debug.reset=none", "--debug.voice=system", "--debug.marker=10", "--debug.seedTextB64=\(encodedText)"]
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
