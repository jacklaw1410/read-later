import Foundation

/// One line of the app's JSONL operation log.
///
/// `t` is monotonic seconds since process start. `iso` is the wall-clock
/// time. `session` identifies the process. `fields` is a flat string map.
public struct TelemetryEvent: Codable, Sendable, Hashable {
    public var t: Double
    public var iso: String
    public var session: String
    public var event: String
    public var fields: [String: String]

    public init(t: Double, iso: String, session: String, event: String, fields: [String: String] = [:]) {
        self.t = t
        self.iso = iso
        self.session = session
        self.event = event
        self.fields = fields
    }
}

/// Event names. Every name is `<category>.<event>` with lower_snake_case segments,
/// and the checkpoint names map one-to-one onto
/// `read-later-research/spec/device-test-plan.md` so an Instruments trace and
/// a telemetry export agree. The rest reuse the
/// pilot vocabulary (`spec/pilot-instrument.md`) where it fits.
public enum TelemetryName {
    public static let processStart = "launch.process_start"
    public static let entryReady = "launch.entry_ready"
    public static let firstFrame = "launch.first_frame"
    public static let entryTap = "entry.tap"
    public static let fetchStart = "fetch.start"
    public static let fetchHeaders = "fetch.headers"
    public static let fetchBodyDone = "fetch.body_done"
    public static let extractParsed = "extract.parsed"
    public static let planReady = "plan.ready"
    public static let speakEnqueued = "speech.enqueued"
    public static let firstWord = "speech.first_word"
    public static let runEnd = "run.end"
    public static let fetchSkipped = "fetch.skipped"
    public static let fetchFailed = "fetch.failed"
    public static let extractStart = "extract.start"
    public static let extractFailed = "extract.failed"
    public static let articleReady = "article.ready"
    /// First committed frame of Reader. The end point of the Entry-to-Reader
    /// timeline. `session` comes from the event; `source` names the ingress.
    public static let readerEntered = "reader.entered"
    public static let speechDidStart = "speech.did_start"
    /// Per-utterance start mark for M4, logged from the synthesizer delegate
    /// without an active-run gate (the seeded flow never starts one), in the
    /// `card.shown` style. `speech.did_start` fires once per `speak`; this
    /// fires for every utterance so scrub releases have a phone-side mark.
    public static let utteranceStart = "speech.utterance_start"
    /// Close-request mark for M14, logged in `ReaderSession.closeCard`
    /// before teardown: the near half of close-to-resume. No fields — one
    /// card is open at a time, so session order joins it to `card.shown`.
    public static let cardClose = "card.close"
    public static let readerOpen = "reader.open"
    public static let playbackPlay = "playback.play"
    public static let playbackPause = "playback.pause"
    public static let playbackFinished = "playback.finished"
    public static let lookupStart = "lookup.start"
    public static let lookupHit = "lookup.hit"
    public static let lookupMiss = "lookup.miss"
    /// First commit of a lookup card (hit or miss) after `onAppear`, logged
    /// from one main-loop turn later: the present-plus-paint mark for M14.
    /// `lookup.hit` already covers resolve; this covers what the user sees.
    public static let cardShown = "card.shown"
    public static let speedChange = "playback.speed_change"
    public static let holdStart = "hold.start"
    public static let holdEnd = "hold.end"
    public static let appHide = "app.hide"
    public static let appReturn = "app.return"
    /// Probe events for the device latency runs (device-verification-latency.md §5).
    public static let launchBuild = "launch.build"
    public static let tapPlay = "tap.play"
    public static let tapPause = "tap.pause"
    public static let scrubCommit = "scrub.commit"
    public static let scrubBegin = "scrub.begin"
    public static let speechDidPause = "speech.did_pause"
    public static let speechDidResume = "speech.did_resume"
    public static let speechEnqueue = "speech.enqueue"
    public static let speechDidFinish = "speech.did_finish"
    /// Stall probes, Debug builds only (`StallProbe`). The device runs that
    /// chase a stall use Debug; release builds do not write them.
    public static let speechWord = "speech.word"
    public static let speechHeartbeat = "speech.heartbeat"
    public static let speechDidCancel = "speech.did_cancel"
    public static let audioInterruption = "audio.interruption"
    public static let storeWrite = "store.write"
    public static let markerRequest = "marker.request"
    public static let frameSecond = "frame.second"
    public static let frameTapWindow = "frame.tap_window"
    public static let frameScrubWindow = "frame.scrub_window"
    /// First committed Reader frame, recorded one display transaction after
    /// `reader.entered`. Reader open time is report-only, not gated.
    public static let readerFirstFrame = "reader.first_frame"
    /// Stage probe (`EntryStageBenchmarkTests`): one sample per article and
    /// arm, plus a start mark. `probe.record` is the payload the `record` arm
    /// times; it stays in the ring and never reaches a file.
    public static let probeStart = "probe.start"
    public static let probeSample = "probe.sample"
    public static let probeRecord = "probe.record"
    /// Scripted interaction driver, Debug only: one row per intent, plus the
    /// run's start and end marks.
    public static let benchmarkInteraction = "benchmark.interaction"
    public static let benchmarkDone = "benchmark.done"
    public static let benchmarkFailed = "benchmark.failed"
}

/// Append-only JSONL measurement log. The app writes it; the analyst takes it
/// off the device. No analytics SDK, no network: local files only.
///
/// Threading: `record` never throws and never blocks the caller. It appends
/// to a bounded in-memory buffer under a lock and schedules a write on a
/// private queue. The reader path calls `record` and moves on.
///
/// Unchecked Sendable by design: every mutable field is guarded by `lock`
/// (buffer, ring, schedule) or `writeLock` (file writes).
public final class TelemetryLog: @unchecked Sendable {
    public static let defaultFileName = "telemetry.jsonl"
    public static let defaultMaxBytes = 1_048_576
    public static let defaultMaxFiles = 5
    public static let defaultRingCapacity = 200
    public static let defaultFlushDelay: TimeInterval = 1.0

    private static let stem = "telemetry"

    private let lock = NSLock()
    private let writeLock = NSLock()
    private let encoderLock = NSLock()
    private let queue = DispatchQueue(label: "app.readlater.telemetry", qos: .utility)

    /// Created once per log, not once per event. `record` uses it under
    /// `encoderLock`, so concurrent callers share one safe encoder.
    private let encoder = JSONEncoder()
    /// UTC, with fractional seconds, and no trailing `Z`. The trailing `Z`
    /// may be absent; parsers must not require it.
    private let isoStyle: Date.ISO8601FormatStyle =
        .iso8601.year().month().day().time(includingFractionalSeconds: true)

    private var pending: [String] = []
    private var deadline: TimeInterval?
    private var flushScheduled = false
    private var ring: [TelemetryEvent] = []

    private var directory: URL?
    private let sessionID: String
    private let maxBytes: Int
    private let maxFiles: Int
    private let ringCapacity: Int
    private let flushDelay: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let wall: @Sendable () -> Date
    private let originUptime: TimeInterval

    /// - Parameters:
    ///   - directory: Where `telemetry.jsonl` lives. Nil keeps everything in
    ///     memory (ring only); the app sets the real directory at launch.
    ///   - clock: Monotonic seconds (uptime basis). Injected in tests.
    ///   - wall: Wall-clock date. Injected in tests.
    public init(
        directory: URL? = nil,
        sessionID: String = String(UUID().uuidString.prefix(8)),
        maxBytes: Int = defaultMaxBytes,
        maxFiles: Int = defaultMaxFiles,
        ringCapacity: Int = defaultRingCapacity,
        flushDelay: TimeInterval = defaultFlushDelay,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wall: @escaping @Sendable () -> Date = Date.init,
        originUptime: TimeInterval? = nil
    ) {
        self.directory = directory
        self.sessionID = sessionID
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.ringCapacity = ringCapacity
        self.flushDelay = flushDelay
        self.clock = clock
        self.wall = wall
        self.originUptime = originUptime ?? ProcessStart.uptime() ?? clock()
    }

    public var session: String { sessionID }

    /// The stock location: `Application Support/Telemetry/`.
    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Telemetry", isDirectory: true)
    }

    /// Sets the directory after init. The app calls this at launch; until
    /// then the log is memory-only.
    public func setDirectory(_ url: URL?) {
        lock.withLock { directory = url }
    }

    public var configuredDirectory: URL? {
        lock.withLock { directory }
    }

    /// Records one event. Never throws, never blocks.
    public func record(_ name: String, fields: [String: String] = [:]) {
        let event = TelemetryEvent(
            t: clock() - originUptime,
            iso: isoStyle.format(wall()),
            session: sessionID,
            event: name,
            fields: fields
        )
        let line: String = encoderLock.withLock {
            guard let data = try? encoder.encode(event),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
        lock.withLock {
            if !line.isEmpty { pending.append(line) }
            ring.append(event)
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            if deadline == nil { deadline = clock() + flushDelay }
            if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
                    self?.flushAsync()
                }
            }
        }
    }

    /// Events still in memory waiting for a write.
    public var pendingCount: Int {
        lock.withLock { pending.count }
    }

    /// The last `n` events, oldest first. Survives a full disk: the ring is
    /// memory-only, so a crash report or the Diagnostics screen can show it.
    public func tail(_ n: Int) -> [TelemetryEvent] {
        lock.withLock { Array(ring.suffix(max(0, n))) }
    }

    /// Writes whatever is pending. Called on lifecycle hooks and by the
    /// export. Never throws; a failure keeps the ring and drops the lines.
    public func flushNow() {
        let lines = lock.withLock { () -> [String] in
            deadline = nil
            let out = pending
            pending = []
            return out
        }
        write(lines: lines)
    }

    /// Writes pending lines when the injected clock has passed the deadline.
    /// The 1 s timer path calls this through the queue; tests drive it with
    /// a fake clock, so no test waits on wall-clock time.
    public func flushIfDue() {
        let lines = lock.withLock { () -> [String] in
            guard let due = deadline, clock() >= due else { return [] }
            deadline = nil
            let out = pending
            pending = []
            return out
        }
        guard !lines.isEmpty else { return }
        write(lines: lines)
    }

    /// Log files on disk, current first. Empty when memory-only.
    public func logFiles() -> [URL] {
        guard let dir = lock.withLock({ directory }) else { return [] }
        var out: [URL] = []
        let current = dir.appendingPathComponent(Self.fileName(stem: Self.stem))
        if FileManager.default.fileExists(atPath: current.path) { out.append(current) }
        for i in 1 ..< maxFiles {
            let url = dir.appendingPathComponent(Self.fileName(stem: Self.stem, index: i))
            if FileManager.default.fileExists(atPath: url.path) { out.append(url) }
        }
        return out
    }

    private func flushAsync() {
        let lines = lock.withLock { () -> [String] in
            flushScheduled = false
            deadline = nil
            let out = pending
            pending = []
            return out
        }
        write(lines: lines)
        lock.withLock {
            if !pending.isEmpty, !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
                    self?.flushAsync()
                }
            }
        }
    }

    private func write(lines: [String]) {
        guard !lines.isEmpty else { return }
        guard let dir = lock.withLock({ directory }) else { return }
        writeLock.withLock {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                return
            }
            let current = dir.appendingPathComponent(Self.defaultFileName)
            rotateIfNeeded(current: current, incomingBytes: lines.joined(separator: "\n").utf8.count + 1)
            let text = lines.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: current.path) {
                guard let handle = try? FileHandle(forWritingTo: current) else { return }
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    return
                }
            } else {
                try? data.write(to: current, options: .atomic)
            }
        }
    }

    /// Rotates before a write that would pass the cap. Keeps the newest
    /// `maxFiles` files: `telemetry.jsonl` plus `telemetry.1.jsonl` (newest
    /// rotated) through `telemetry.(maxFiles-1).jsonl`.
    private func rotateIfNeeded(current: URL, incomingBytes: Int) {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        guard size + incomingBytes > maxBytes else { return }
        guard let dir = lock.withLock({ directory }) else { return }
        for i in stride(from: maxFiles - 1, through: 2, by: -1) {
            let older = dir.appendingPathComponent(Self.fileName(stem: Self.stem, index: i - 1))
            let newer = dir.appendingPathComponent(Self.fileName(stem: Self.stem, index: i))
            try? manager.removeItem(at: newer)
            if manager.fileExists(atPath: older.path) { try? manager.moveItem(at: older, to: newer) }
        }
        if maxFiles > 1 {
            let first = dir.appendingPathComponent(Self.fileName(stem: Self.stem, index: 1))
            try? manager.removeItem(at: first)
            if manager.fileExists(atPath: current.path) { try? manager.moveItem(at: current, to: first) }
        } else {
            try? manager.removeItem(at: current)
        }
    }

    private static func fileName(stem: String, index: Int? = nil) -> String {
        let base = index.map { "\(stem).\($0)" } ?? stem
        return "\(base).jsonl"
    }
}
