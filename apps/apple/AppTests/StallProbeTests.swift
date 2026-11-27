import ReadLaterCore
import XCTest
@testable import ReadLater

/// The stall probe is Debug-only telemetry: it must sample while the voice
/// speaks, stop the moment the voice is held, and name each stall event.
@MainActor
final class StallProbeTests: XCTestCase {
    private final class Recorder {
        var names: [String] = []
        var fields: [String: [String: String]] = [:]
        var heartbeats = 0

        func record(_ name: String, _ fields: [String: String]) {
            names.append(name)
            self.fields[name] = fields
            if name == TelemetryName.speechHeartbeat { heartbeats += 1 }
        }
    }

    private func makeProbe(
        recorder: Recorder,
        interval: UInt64 = 10_000_000
    ) -> StallProbe {
        StallProbe(
            interval: interval,
            sample: {
                SpeechProbeSample(
                    state: .speaking, isSpeaking: true, isPaused: false,
                    queued: 2, word: 7
                )
            },
            record: recorder.record
        )
    }

    func testHeartbeatSamplesWhileSpeakingAndStopsOnHold() async throws {
        let recorder = Recorder()
        let probe = makeProbe(recorder: recorder)
        probe.note(.utteranceStarted(utterance: 0))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThanOrEqual(recorder.heartbeats, 1, "a speaking voice beats")
        XCTAssertEqual(recorder.fields[TelemetryName.speechHeartbeat]?["state"], "speaking")
        XCTAssertEqual(recorder.fields[TelemetryName.speechHeartbeat]?["word"], "7")

        probe.note(.held(reason: .pause))
        let after = recorder.heartbeats
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(recorder.heartbeats, after, "a held voice does not beat")
    }

    func testEventsNameTheStallMarks() {
        let recorder = Recorder()
        let probe = makeProbe(recorder: recorder)
        probe.note(.boundary(utterance: 3, word: 42))
        probe.note(.cancelled(tracked: true, state: .paused))
        probe.note(.interrupted(type: 1, state: .speaking))

        XCTAssertEqual(
            recorder.names,
            [TelemetryName.speechWord, TelemetryName.speechDidCancel, TelemetryName.audioInterruption]
        )
        XCTAssertEqual(recorder.fields[TelemetryName.speechWord]?["word"], "42")
        XCTAssertEqual(recorder.fields[TelemetryName.speechWord]?["utterance"], "3")
        XCTAssertEqual(recorder.fields[TelemetryName.speechDidCancel]?["tracked"], "true")
        XCTAssertEqual(recorder.fields[TelemetryName.audioInterruption]?["type"], "1")
    }
}
