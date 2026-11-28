#if os(macOS) && DEBUG
import AppKit
import Foundation
import ReadLaterCore

/// Drives the reader's interaction intents in a fixed order and records one
/// `benchmark.interaction` row per intent. Debug-only; it is not shipped and
/// it does not synthesize touches.
///
/// The first three iterations are warmups: the system dictionary and the pack
/// are cold, and the first lookup after launch costs ten times the steady
/// state. Warmups are recorded with `warmup=1` so the tool can drop them
/// without guessing.
@MainActor
enum InteractionBenchmark {
    static let warmupIterations = 3

    /// `iterations` counts warmups: the harness passes samples + warmups.
    static func run(app: AppModel, telemetry: TelemetryHub, iterations: Int) async {
        // Let the entry surface settle, then open the seeded article through
        // the same library door the resume offer uses.
        try? await Task.sleep(nanoseconds: 500_000_000)
        if app.session == nil {
            app.openLatestSavedPlace()
        }
        guard let session = app.session else {
            await finish(telemetry, fields: ["reason": "no session"], failed: true)
            return
        }
        // ReaderView marks reader.entered one main-loop turn after it appears.
        guard await waitForEvent(TelemetryName.readerEntered, telemetry: telemetry, timeout: 5) else {
            await finish(telemetry, fields: ["reason": "no reader"], failed: true)
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        for index in 0 ..< iterations {
            let warmup = index < warmupIterations
            let prefix = ["iteration": String(index), "warmup": warmup ? "1" : "0"]

            // Capture the mark before the tap: a stale window from the previous
            // iteration must not satisfy the wait, or the next tap lands while
            // the monitor is still armed and the windows coalesce.
            let playSince = lastT(telemetry)
            await measure("play", prefix: prefix, telemetry: telemetry) { since in
                session.togglePlay()
                return await waitForEvent(
                    "speech.speaking", telemetry: telemetry, after: since, timeout: 2)
            }
            _ = await waitForEvent(
                TelemetryName.frameTapWindow, telemetry: telemetry, after: playSince, timeout: 2)

            let pauseSince = lastT(telemetry)
            await measure("pause", prefix: prefix, telemetry: telemetry) { since in
                session.togglePlay()
                return await waitForEvent(
                    "speech.paused", telemetry: telemetry, after: since, timeout: 2)
            }
            _ = await waitForEvent(
                TelemetryName.frameTapWindow, telemetry: telemetry, after: pauseSince, timeout: 2)

            // Hold the drag for a few frames so `frame.scrub_window` has a
            // window: begin and finish in one runloop produce none. Only the
            // release handler is timed.
            let scrubSince = lastT(telemetry)
            session.beginScrubbing()
            try? await Task.sleep(nanoseconds: 300_000_000)
            let scrubStart = ProcessInfo.processInfo.systemUptime
            session.scrub(toFraction: 0.5)
            let scrubMs = (ProcessInfo.processInfo.systemUptime - scrubStart) * 1000
            session.finishScrubbing()
            var scrubFields = prefix
            scrubFields["kind"] = "scrub"
            scrubFields["ms"] = String(format: "%.3f", scrubMs)
            scrubFields["outcome"] = "ok"
            telemetry.record(TelemetryName.benchmarkInteraction, fields: scrubFields)
            _ = await waitForEvent(
                TelemetryName.frameScrubWindow, telemetry: telemetry, after: scrubSince, timeout: 2)

            // A card resumes the voice only when one was live at open.
            if !session.playbackState.isPlaying {
                session.togglePlay()
                _ = await waitForEvent(
                    "speech.speaking", telemetry: telemetry, timeout: 2)
            }

            await measure("lookup.hit", prefix: prefix, telemetry: telemetry) { since in
                session.lookup.tap(slot: nil, word: "out-argues")
                let resolved = await waitForEvent(
                    TelemetryName.lookupHit, telemetry: telemetry, after: since, timeout: 2)
                let painted = await waitForEvent(
                    TelemetryName.cardShown, telemetry: telemetry, after: since, timeout: 2)
                return resolved && painted
            }
            let closeSince = lastT(telemetry)
            session.lookup.closeCard()
            _ = await waitForEvent(
                "speech.speaking", telemetry: telemetry, after: closeSince, timeout: 2)

            await measure("lookup.miss", prefix: prefix, telemetry: telemetry) { since in
                session.lookup.tap(slot: nil, word: "zzzznotaword")
                let resolved = await waitForEvent(
                    TelemetryName.lookupMiss, telemetry: telemetry, after: since, timeout: 2)
                let painted = await waitForEvent(
                    TelemetryName.cardShown, telemetry: telemetry, after: since, timeout: 2)
                return resolved && painted
            }
            session.lookup.closeCard()

            // Leave the reader paused for the next iteration.
            if session.playbackState.isPlaying { session.togglePlay() }
        }

        await finish(telemetry, fields: ["iterations": String(iterations)], failed: false)
    }

    private static func measure(
        _ kind: String,
        prefix: [String: String],
        telemetry: TelemetryHub,
        _ body: (Double) async -> Bool
    ) async {
        let start = ProcessInfo.processInfo.systemUptime
        let since = lastT(telemetry)
        let ok = await body(since)
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var fields = prefix
        fields["kind"] = kind
        fields["ms"] = String(format: "%.3f", ms)
        fields["outcome"] = ok ? "ok" : "timeout"
        telemetry.record(TelemetryName.benchmarkInteraction, fields: fields)
    }

    private static func finish(_ telemetry: TelemetryHub, fields: [String: String], failed: Bool) async {
        var fields = fields
        fields["outcome"] = failed ? "failed" : "ok"
        telemetry.record(
            failed ? TelemetryName.benchmarkFailed : TelemetryName.benchmarkDone, fields: fields)
        telemetry.flush()
        // Give the flush a turn before terminating.
        try? await Task.sleep(nanoseconds: 200_000_000)
        NSApp.terminate(nil)
    }

    private static func lastT(_ telemetry: TelemetryHub) -> Double {
        telemetry.telemetryLog.tail(1).last?.t ?? 0
    }

    /// True when an event with this name is newer than `after`. Telemetry `t`
    /// is process-relative; the caller takes the last event's `t` before the
    /// intent, so a synchronous event still counts as new.
    private static func waitForEvent(
        _ name: String,
        telemetry: TelemetryHub,
        after: Double = 0,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if telemetry.telemetryLog.tail(500).contains(where: { $0.event == name && $0.t >= after }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
#endif
