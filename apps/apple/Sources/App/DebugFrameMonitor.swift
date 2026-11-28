#if DEBUG
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#endif
import ReadLaterCore
#if os(macOS)
import AppKit
#endif

/// DEBUG-only display-frame recorder for M1 (tap pixel side) and M5 (scrub).
///
/// The whole file compiles out of Release, so shipping behavior cannot
/// change. The driver feeds vsync times (`targetTimestamp`, the time the
/// frame will display) into the `FrameCounter` accumulator and writes one
/// telemetry event per window:
///
/// - Tap window (`frame.tap_window`): opened at handler entry, closed a short
///   tail after the state change. M1 counts frames from tap to state change
///   against the one-frame gate.
/// - Scrub window (`frame.scrub_window`): opened when the drag starts, closed
///   on release. M5 reads `fps` and `longestGapMs` straight off the event.
///
/// Timestamps use `ProcessInfo.systemUptime`, the same basis as the telemetry log
/// clock, so `tapToStateMs` lines up with the `play`/`pause` events.
@MainActor
final class DebugFrameMonitor: NSObject {
    static let shared = DebugFrameMonitor()

    private enum Mode {
        case idle
        case tap
        case scrub
    }

    /// Frames kept after the state change, so the window shows the changed
    /// icon actually reached the screen.
    private static let tapTailFrames = 5
    /// Safety cap when no state change ever arrives (failed press). The
    /// window still closes and reports `state: missing`.
    private static let tapCapFrames = 120

    private var link: CADisplayLink?
    private var counter = ReadLaterCore.FrameCounter()
    private var mode = Mode.idle
    private var tapStamp: TimeInterval = 0
    private var stateStamp: TimeInterval?
    private var closeAtCount: Int?

    private func ensureLink() {
        guard link == nil else { return }
        #if os(macOS)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        #else
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// Call at tap handler entry (`ReaderSession.togglePlay`).
    func noteTap() {
        guard mode != .scrub else { return }
        counter.reset()
        mode = .tap
        tapStamp = ProcessInfo.processInfo.systemUptime
        stateStamp = nil
        closeAtCount = nil
        ensureLink()
    }

    /// Call when the speech state lands (`ReaderSession.speechStateChanged`).
    func noteStateChange() {
        guard mode == .tap, stateStamp == nil else { return }
        stateStamp = ProcessInfo.processInfo.systemUptime
        closeAtCount = counter.count + Self.tapTailFrames
    }

    /// Call when the scrub drag starts (`isScrubbing` turns true).
    func noteScrubBegan() {
        counter.reset()
        mode = .scrub
        stateStamp = nil
        closeAtCount = nil
        ensureLink()
    }

    /// Call when the drag releases. Emits `frame.scrub_window`.
    func noteScrubEnded() {
        guard mode == .scrub else { return }
        mode = .idle
        stopLink()
        guard let summary = counter.summary() else { return }
        TelemetryHub.shared.record(TelemetryName.frameScrubWindow, fields: summary.fields())
    }

    @objc private func tick(_ link: CADisplayLink) {
        let stamp = link.targetTimestamp != 0 ? link.targetTimestamp : link.timestamp
        counter.record(at: stamp)
        guard mode == .tap else { return }
        if closeAtCount.map({ counter.count >= $0 }) ?? false {
            emitTapWindow()
        } else if counter.count >= Self.tapCapFrames {
            emitTapWindow()
        }
    }

    private func emitTapWindow() {
        mode = .idle
        stopLink()
        guard let summary = counter.summary() else { return }
        var extra: [String: String] = [:]
        if let state = stateStamp {
            extra["tapToStateMs"] = FrameWindowSummary.ms(state - tapStamp)
            extra["state"] = "changed"
        } else {
            extra["state"] = "missing"
        }
        TelemetryHub.shared.record(TelemetryName.frameTapWindow, fields: summary.fields(extra: extra))
    }
}
#endif
