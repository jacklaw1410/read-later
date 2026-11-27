#if DEBUG
import Foundation
import ReadLaterCore
#if os(iOS)
import AVFoundation
#endif

/// Debug-only stall probe: the 1 Hz heartbeat and the marks that name a stall.
///
/// The voice reports events through `AVSpeechController.onProbe`; this type
/// decides what to log. It owns its timer, its fields, and its `os` imports,
/// so the controller carries no probe state and no Debug conditional.
///
/// Why a heartbeat: a stall reads `state == .speaking` while the synthesizer
/// has stopped (`isSpeaking` false, `queued` zero, flat output volume). One
/// sample per second proves that shape. See
/// `docs/telemetry-and-sync-oplog.md` and
/// `read-later-research/evidence/2026-11-18-stall-signposts-run1/`.
@MainActor
final class StallProbe {
    private let interval: UInt64
    private let sample: @MainActor () -> SpeechProbeSample?
    private let record: (String, [String: String]) -> Void
    private var heartbeat: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: nanoseconds between samples. Tests shorten it.
    ///   - sample: engine truth, normally `{ [weak speech] in speech?.health }`.
    ///   - record: the telemetry sink. `TelemetryHub.record` in the app.
    init(
        interval: UInt64 = 1_000_000_000,
        sample: @escaping @MainActor () -> SpeechProbeSample?,
        record: @escaping (String, [String: String]) -> Void
    ) {
        self.interval = interval
        self.sample = sample
        self.record = record
    }

    /// One thing the voice did. Events that end sound stop the heartbeat at
    /// once; the sample itself also ends it if the voice leaves `.speaking`.
    func note(_ event: SpeechProbeEvent) {
        switch event {
        case .utteranceStarted:
            start()
        case let .boundary(utterance, word):
            record(TelemetryName.speechWord, [
                "word": String(word),
                "utterance": String(utterance),
            ])
        case let .cancelled(tracked, state):
            record(TelemetryName.speechDidCancel, [
                "tracked": String(tracked),
                "state": String(describing: state),
            ])
        case let .interrupted(type, state):
            record(TelemetryName.audioInterruption, [
                "type": String(type),
                "state": String(describing: state),
            ])
        case .resumed:
            start()
        case .held, .finished, .stopped:
            stop()
        }
    }

    private func start() {
        guard heartbeat == nil else { return }
        let interval = interval
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                self.beat()
            }
        }
    }

    private func stop() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func beat() {
        guard let sample = sample(), sample.state == .speaking else {
            // The voice left `.speaking` without an event, or it is gone.
            stop()
            return
        }
        var fields: [String: String] = [
            "state": String(describing: sample.state),
            "isSpeaking": String(sample.isSpeaking),
            "isPaused": String(sample.isPaused),
            "inFlight": String(sample.queued),
            "word": String(sample.word),
            "uptime": String(format: "%.6f", ProcessInfo.processInfo.systemUptime),
        ]
        #if os(iOS)
            fields["outputVolume"] = String(format: "%.3f", AVAudioSession.sharedInstance().outputVolume)
        #endif
        record(TelemetryName.speechHeartbeat, fields)
    }
}
#endif
