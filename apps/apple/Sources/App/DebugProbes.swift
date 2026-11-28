#if DEBUG
import AVFoundation
import Foundation
import QuartzCore
import ReadLaterCore

/// Debug-only probes for the device latency runs
/// (`read-later-research/spec/device-verification-latency.md`, section 3 and 5).
/// Compiled out of Release. Launch arguments turn them on:
///
///   --debug.marker=<count>   plays <count> clicks, one per second, starting 2 s
///                            after launch. Each click logs `marker.request`.
///   --debug.frames           logs `frame.second` once per second (iOS only).
@MainActor
enum DebugProbes {
    private static let markerPrefix = "--debug.marker="

    static func start() {
        let arguments = ProcessInfo.processInfo.arguments
        if let raw = arguments.first(where: { $0.hasPrefix(markerPrefix) }),
           let count = Int(raw.dropFirst(markerPrefix.count)), count > 0 {
            ClickMarker.shared.schedule(count: count)
        }
        #if os(iOS)
        if arguments.contains("--debug.frames") {
            FrameCounter.shared.start()
        }
        #endif
    }
}

/// Plays a 10 ms, 1 kHz click. The `host` field is `CACurrentMediaTime()` at
/// the request, and `outputLatency` is the session output latency. The clock
/// analysis uses both: the click's onset is at `host + outputLatency`.
@MainActor
final class ClickMarker {
    static let shared = ClickMarker()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 48_000
    private var buffer: AVAudioPCMBuffer?

    func schedule(count: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard setUp() else { return }
            for index in 0..<count {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                click(index: index)
            }
        }
    }

    private func setUp() -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return false
        }
        buffer = makeClick(format: format)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return false
        }
        player.play()
        return true
    }

    private func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(sampleRate / 100)  // 10 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            samples[i] = Float(0.8 * sin(2 * Double.pi * 1_000 * Double(i) / sampleRate))
        }
        return buffer
    }

    private func click(index: Int) {
        guard let buffer else { return }
        #if os(iOS)
        let latency = AVAudioSession.sharedInstance().outputLatency
        #else
        let latency = 0.0
        #endif
        TelemetryHub.shared.record(TelemetryName.markerRequest, fields: [
            "index": String(index),
            "host": String(format: "%.6f", CACurrentMediaTime()),
            "outputLatency": String(format: "%.6f", latency),
        ])
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

#if os(iOS)
/// Counts display-link ticks. Logs frames per second and the longest gap
/// between ticks in each second (M5).
@MainActor
final class FrameCounter: NSObject {
    static let shared = FrameCounter()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var longestGap: CFTimeInterval = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 { longestGap = max(longestGap, now - last) }
        last = now
        if windowStart == 0 { windowStart = now }
        frames += 1
        let window = now - windowStart
        if window >= 1 {
            TelemetryHub.shared.record(TelemetryName.frameSecond, fields: [
                "fps": String(format: "%.1f", Double(frames) / window),
                "longestGapMs": String(format: "%.1f", longestGap * 1_000),
            ])
            frames = 0
            windowStart = now
            longestGap = 0
        }
    }
}
#endif
#endif
