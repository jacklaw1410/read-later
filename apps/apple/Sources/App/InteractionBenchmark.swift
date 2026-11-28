#if os(macOS) && DEBUG
import AppKit
import Foundation
import ReadLaterCore

/// Drives the reader's interaction intents in a fixed order and records one
/// `benchmark.interaction` per intent. This is the spike harness for the CI
/// interaction suite; it is not shipped and does not synthesize touches.
@MainActor
enum InteractionBenchmark {
    private static let warmupIterations = 3

    static func run(app: AppModel, telemetry: TelemetryHub, iterations: Int) async {
        // Let the entry surface settle, then open the seeded article through
        // the same library door the resume offer uses.
        try? await Task.sleep(for: .milliseconds(500))
        if app.session == nil {
            app.openLatestSavedPlace()
        }
        guard let session = app.session else {
            telemetry.record("benchmark.failed", fields: ["reason": "no session"])
            telemetry.flush()
            NSApp.terminate(nil)
            return
        }
        // ReaderView marks reader.entered one main-loop turn after it appears.
        try? await Task.sleep(for: .milliseconds(800))

        for index in 0 ..< iterations {
            let warmup = index < warmupIterations
            let prefix = ["iteration": String(index), "warmup": warmup ? "1" : "0"]

            await measure("play", prefix: prefix, telemetry: telemetry) { since in
                session.togglePlay()
                return await waitForEvent("state.speaking", telemetry: telemetry, after: since, timeout: 2)
            }
            _ = await waitForEvent("frame.tapWindow", telemetry: telemetry, after: lastT(telemetry), timeout: 2)

            await measure("pause", prefix: prefix, telemetry: telemetry) { since in
                session.togglePlay()
                return await waitForEvent("state.paused", telemetry: telemetry, after: since, timeout: 2)
            }
            _ = await waitForEvent("frame.tapWindow", telemetry: telemetry, after: lastT(telemetry), timeout: 2)

            // Hold the drag for a few frames so frame.scrubWindow has a
            // window. Only the release handler is measured.
            let scrubSince = lastT(telemetry)
            session.beginScrubbing()
            try? await Task.sleep(for: .milliseconds(300))
            let scrubStart = ProcessInfo.processInfo.systemUptime
            session.scrub(toFraction: 0.5)
            let scrubMs = (ProcessInfo.processInfo.systemUptime - scrubStart) * 1000
            session.finishScrubbing()
            var scrubFields = prefix
            scrubFields["kind"] = "scrub"
            scrubFields["ms"] = String(format: "%.3f", scrubMs)
            scrubFields["outcome"] = "ok"
            telemetry.record("benchmark.interaction", fields: scrubFields)
            _ = await waitForEvent("frame.scrubWindow", telemetry: telemetry, after: scrubSince, timeout: 2)

            // The lookup path resumes only when a voice was live at open.
            session.togglePlay()
            try? await Task.sleep(for: .milliseconds(100))

            await measure("lookup.hit", prefix: prefix, telemetry: telemetry) { since in
                session.lookup.tap(slot: nil, word: "out-argues")
                let resolved = await waitForEvent(TelemetryName.lookupHit, telemetry: telemetry, after: since, timeout: 2)
                let painted = await waitForEvent(TelemetryName.cardShown, telemetry: telemetry, after: since, timeout: 2)
                return resolved && painted
            }
            let closeSince = lastT(telemetry)
            session.lookup.closeCard()
            _ = await waitForEvent("state.speaking", telemetry: telemetry, after: closeSince, timeout: 2)

            await measure("lookup.miss", prefix: prefix, telemetry: telemetry) { since in
                session.lookup.tap(slot: nil, word: "zzzznotaword")
                let resolved = await waitForEvent(TelemetryName.lookupMiss, telemetry: telemetry, after: since, timeout: 2)
                let painted = await waitForEvent(TelemetryName.cardShown, telemetry: telemetry, after: since, timeout: 2)
                return resolved && painted
            }
            session.lookup.closeCard()

            // Leave the reader paused for the next iteration.
            if session.playbackState.isPlaying { session.togglePlay() }
        }

        telemetry.record("benchmark.done", fields: ["iterations": String(iterations)])
        telemetry.flush()
        // Give the flush a turn before terminating.
        try? await Task.sleep(for: .milliseconds(200))
        NSApp.terminate(nil)
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
        telemetry.record("benchmark.interaction", fields: fields)
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
        after: Double,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if telemetry.telemetryLog.tail(200).contains(where: { $0.event == name && $0.t >= after }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
#endif
