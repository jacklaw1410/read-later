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

/// Event names. The `T0`–`T7` names match
/// `read-later-research/spec/device-test-plan.md` exactly, so an Instruments
/// trace and an oplog export agree. The rest reuse the pilot vocabulary
/// (`spec/pilot-instrument.md`) where it fits.
public enum TelemetryName {
    public static let processStart = "launch.processStart"
    public static let entryReady = "launch.entryReady"
    public static let firstFrame = "launch.firstFrame"
    public static let tap = "T0.tap"
    public static let fetchStart = "T1.fetchStart"
    public static let headers = "T2.headers"
    public static let bodyDone = "T3.bodyDone"
    public static let parsed = "T4.parsed"
    public static let planReady = "T5.planReady"
    public static let speakEnqueued = "T6.speakEnqueued"
    public static let firstWord = "T7.firstWord"
    public static let runEnd = "run.end"
    public static let fetchSkipped = "fetch.skipped"
    public static let fetchFailed = "fetch.failed"
    public static let extractStart = "extract.start"
    public static let extractFailed = "extract.failed"
    public static let articleReady = "article.ready"
    public static let speechDidStart = "speech.didStart"
    public static let readerOpen = "reader-open"
    public static let play = "play"
    public static let pause = "pause"
    public static let finished = "finished"
    public static let lookup = "lookup"
    public static let lookupHit = "lookup.hit"
    public static let lookupMiss = "lookup.miss"
    public static let speedChange = "speed change"
    public static let holdStart = "hold-start"
    public static let holdEnd = "hold-end"
    public static let appHide = "app-hide"
    public static let appReturn = "app-return"
}

/// Append-only JSONL event log. The app writes it; the analyst takes it off
/// the device. No analytics SDK, no network: local files only.
///
/// Threading: `record` never throws and never blocks the caller. It appends
/// to a bounded in-memory buffer under a lock and schedules a write on a
/// private queue. The reader path calls `record` and moves on.
///
/// Unchecked Sendable by design: every mutable field is guarded by `lock`
/// (buffer, ring, schedule) or `writeLock` (file writes).
public final class TelemetryOplog: @unchecked Sendable {
    public static let defaultFileName = "oplog.jsonl"
    public static let defaultMaxBytes = 1_048_576
    public static let defaultMaxFiles = 5
    public static let defaultRingCapacity = 200
    public static let defaultFlushDelay: TimeInterval = 1.0

    private let lock = NSLock()
    private let writeLock = NSLock()
    private let queue = DispatchQueue(label: "app.readlater.telemetry-oplog", qos: .utility)

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
    ///   - directory: Where `oplog.jsonl` lives. Nil keeps everything in
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

    /// The stock location: `Application Support/Oplog/`.
    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Oplog", isDirectory: true)
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
            iso: Self.isoString(wall()),
            session: sessionID,
            event: name,
            fields: fields
        )
        let line: String = {
            guard let data = try? JSONEncoder().encode(event),
                  let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }()
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
        let current = dir.appendingPathComponent(Self.defaultFileName)
        if FileManager.default.fileExists(atPath: current.path) { out.append(current) }
        for i in 1 ..< maxFiles {
            let url = dir.appendingPathComponent("oplog.\(i).jsonl")
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
    /// `maxFiles` files: `oplog.jsonl` plus `oplog.1.jsonl` (newest
    /// rotated) through `oplog.(maxFiles-1).jsonl`.
    private func rotateIfNeeded(current: URL, incomingBytes: Int) {
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        guard size + incomingBytes > maxBytes else { return }
        guard let dir = lock.withLock({ directory }) else { return }
        for i in stride(from: maxFiles - 1, through: 2, by: -1) {
            let older = dir.appendingPathComponent("oplog.\(i - 1).jsonl")
            let newer = dir.appendingPathComponent("oplog.\(i).jsonl")
            try? manager.removeItem(at: newer)
            if manager.fileExists(atPath: older.path) { try? manager.moveItem(at: older, to: newer) }
        }
        if maxFiles > 1 {
            let first = dir.appendingPathComponent("oplog.1.jsonl")
            try? manager.removeItem(at: first)
            if manager.fileExists(atPath: current.path) { try? manager.moveItem(at: current, to: first) }
        } else {
            try? manager.removeItem(at: current)
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
