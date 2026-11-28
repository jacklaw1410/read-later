#if os(macOS) && DEBUG
import AppKit
import Foundation
import ReadLaterCore

/// Debug-only benchmark exit. With `--debug.benchmarkExit=firstFrame` the app
/// flushes and quits as soon as `launch.first_frame` lands, so the harness
/// never has to kill the process and lose a buffered line.
///
/// The mark is recorded one main-loop turn after `EntryView` appears, so this
/// waits on the telemetry ring rather than on a timer.
@MainActor
enum DebugBenchmarkExit {
    /// A launch that never reaches the mark is a failed sample, not a hang.
    private static let timeout: TimeInterval = 15

    static func armIfRequested(telemetry: TelemetryHub) {
        guard DebugLaunch.options.benchmarkExit == .firstFrame else { return }
        Task { @MainActor in
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if telemetry.telemetryLog.tail(500).contains(where: { $0.event == TelemetryName.firstFrame }) {
                    await finish(telemetry, reason: nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            await finish(telemetry, reason: "first_frame timeout")
        }
    }

    private static func finish(_ telemetry: TelemetryHub, reason: String?) async {
        if let reason {
            telemetry.record(TelemetryName.benchmarkFailed, fields: ["reason": reason])
        }
        telemetry.flush()
        // One turn for the flush before the process goes away.
        try? await Task.sleep(nanoseconds: 200_000_000)
        NSApp.terminate(nil)
    }
}
#endif
