import Foundation
import Testing
@testable import ReadLaterCore

/// A clock the test drives. No test waits on wall-clock time: `now` moves
/// only when the test moves it, and `today` never moves.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowValue: TimeInterval
    let today: Date

    init(start: TimeInterval = 1_000, today: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.nowValue = start
        self.today = today
    }

    var now: TimeInterval {
        get { lock.withLock { nowValue } }
        set { lock.withLock { nowValue = newValue } }
    }

    func clock() -> TimeInterval { now }
    func wall() -> Date { today }
}

private func makeLog(
    _ fake: FakeClock,
    maxBytes: Int = TelemetryLog.defaultMaxBytes,
    maxFiles: Int = TelemetryLog.defaultMaxFiles,
    ringCapacity: Int = TelemetryLog.defaultRingCapacity
) -> (TelemetryLog, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("telemetry-test-\(UUID().uuidString)", isDirectory: true)
    let log = TelemetryLog(
        directory: dir, sessionID: "test-session", maxBytes: maxBytes, maxFiles: maxFiles,
        ringCapacity: ringCapacity, clock: fake.clock, wall: fake.wall, originUptime: 1_000
    )
    return (log, dir)
}

private func readLines(_ url: URL) throws -> [TelemetryEvent] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").map { line in
        try decoder.decode(TelemetryEvent.self, from: Data(line.utf8))
    }
}

private func allEvents(_ log: TelemetryLog) throws -> [TelemetryEvent] {
    try log.logFiles().reversed().flatMap { try readLines($0) }
}

/// Fractional milliseconds from either stamp shape, with or without a `Z`.
private func fractionMillis(_ iso: String) -> Int? {
    let core = iso.hasSuffix("Z") ? String(iso.dropLast()) : iso
    guard let fraction = core.split(separator: ".").last,
          fraction.count == 3, let value = Int(fraction)
    else { return nil }
    return value
}

@Suite("Telemetry log")
struct TelemetryLogTests {
    @Test("Append then flush keeps order, session and fields")
    func appendFlushOrdering() throws {
        let fake = FakeClock()
        let (log, _) = makeLog(fake)
        fake.now = 1_001
        log.record("alpha", fields: ["k": "1"])
        fake.now = 1_002
        log.record("beta")
        fake.now = 1_003
        log.record("gamma", fields: ["url": "https://example.com/a"])
        #expect(log.pendingCount == 3)
        log.flushNow()
        #expect(log.pendingCount == 0)

        let files = log.logFiles()
        #expect(files.count == 1)
        let events = try readLines(files[0])
        #expect(events.map(\.event) == ["alpha", "beta", "gamma"])
        #expect(events.allSatisfy { $0.session == "test-session" })
        #expect(events[0].fields == ["k": "1"])
        #expect(events[2].fields == ["url": "https://example.com/a"])
        let times = events.map(\.t)
        #expect(times == times.sorted())
        #expect(times[0] == 1)
        #expect(times[2] == 3)
        #expect(events.allSatisfy { !$0.iso.isEmpty })
    }

    @Test("New files use the telemetry name and legacy files stay readable")
    func newAndLegacyFileNames() throws {
        let fake = FakeClock()
        let (log, dir) = makeLog(fake)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent(TelemetryLog.legacyFileName)
        let legacyLine = #"{"t":1,"iso":"2023-11-14T22:13:20.000Z","session":"test-session","event":"old","fields":{}}"# + "\n"
        try legacyLine.write(to: old, atomically: true, encoding: .utf8)
        log.record("new")
        log.flushNow()
        #expect(TelemetryLog.defaultFileName == "telemetry.jsonl")
        #expect(log.logFiles().map(\.lastPathComponent) == [
            TelemetryLog.defaultFileName, TelemetryLog.legacyFileName,
        ])
        #expect(try allEvents(log).map(\.event) == ["old", "new"])
    }

    @Test("Rotation keeps the newest files and the latest event")
    func rotationKeepsNewest() throws {
        let fake = FakeClock()
        let (log, _) = makeLog(fake, maxBytes: 400, maxFiles: 3)
        for i in 0 ..< 60 {
            fake.now = 1_000 + Double(i)
            log.record("event-\(i)", fields: ["pad": String(repeating: "x", count: 20)])
            log.flushNow()
        }
        let files = log.logFiles()
        #expect(files.count == 3)
        let events = try allEvents(log)
        #expect(events.last?.event == "event-59")
    }

    @Test("No file passes the size cap by more than one line")
    func sizeCap() throws {
        let fake = FakeClock()
        let (log, _) = makeLog(fake, maxBytes: 500, maxFiles: 5)
        for i in 0 ..< 40 {
            fake.now = 1_000 + Double(i)
            log.record("event-\(i)", fields: ["pad": String(repeating: "y", count: 30)])
            log.flushNow()
        }
        let sizes = log.logFiles().map { url -> Int in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        }
        #expect(!sizes.isEmpty)
        #expect(sizes.allSatisfy { $0 <= 500 + 512 })
        #expect(log.logFiles().count <= 5)
    }

    @Test("Flush on a deadline writes only after the deadline")
    func deadlineFlush() throws {
        let fake = FakeClock()
        let (log, _) = makeLog(fake, maxBytes: 500, maxFiles: 5)
        log.record("before-deadline")
        log.flushIfDue()
        #expect(try allEvents(log).isEmpty)

        fake.now += TelemetryLog.defaultFlushDelay + 1
        log.flushIfDue()
        #expect(try allEvents(log).map(\.event) == ["before-deadline"])
    }

    @Test("An unwritable directory never throws and keeps the ring")
    func unwritableDirectory() throws {
        let fake = FakeClock()
        let dead = URL(fileURLWithPath: "/dev/null/telemetry-test-\(UUID().uuidString)")
        let log = TelemetryLog(
            directory: dead, sessionID: "test-session",
            clock: fake.clock, wall: fake.wall, originUptime: 1_000
        )
        log.record("kept")
        log.flushNow()
        log.flushIfDue()
        #expect(log.logFiles().isEmpty)
        #expect(log.tail(5).map(\.event) == ["kept"])
    }

    @Test("The ring keeps the last N events in order")
    func ringTail() throws {
        let fake = FakeClock()
        let (log, _) = makeLog(fake, ringCapacity: 5)
        for i in 0 ..< 8 {
            fake.now = 1_000 + Double(i)
            log.record("event-\(i)")
        }
        #expect(log.tail(5).map(\.event) == ["event-3", "event-4", "event-5", "event-6", "event-7"])
        #expect(log.tail(100).count == 5)
        #expect(log.tail(0).isEmpty)
    }

    @Test("The hub opens a run on tap and closes it on the first word")
    func hubRunLifecycle() throws {
        let fake = FakeClock()
        let hub = TelemetryHub(
            directory: nil, sessionID: "hub-test",
            clock: fake.clock, wall: fake.wall, originUptime: 1_000
        )
        #expect(!hub.hasActiveRun)
        hub.record(TelemetryName.tap)
        #expect(hub.hasActiveRun)
        hub.record(TelemetryName.fetchStart)
        #expect(hub.hasActiveRun)
        hub.record(TelemetryName.firstWord)
        #expect(!hub.hasActiveRun)
        #expect(hub.telemetryLog.tail(3).map(\.event) == ["T0.tap", "T1.fetchStart", "T7.firstWord"])
    }

    @Test("A fixed date records the ISO8601 style output")
    func fixedDateISOStyle() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let fake = FakeClock(today: date)
        let (log, _) = makeLog(fake)
        log.record("fixed-date")
        log.flushNow()
        let event = try #require(try allEvents(log).first)

        let expected = Date.ISO8601FormatStyle.iso8601
            .year().month().day().time(includingFractionalSeconds: true)
            .format(date)
        // On Swift 6.4.2 this is "2023-11-14T22:13:20.122" — no trailing Z.
        // The old formatter writes "2023-11-14T22:13:20.123Z": fractional
        // milliseconds differ by at most 1 ms, and the trailing Z can be absent.
        #expect(event.iso == expected)

        let old = ISO8601DateFormatter()
        old.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacy = old.string(from: date)
        #expect(String(event.iso.prefix(19)) == String(legacy.prefix(19)))
        let newMillis = try #require(fractionMillis(event.iso))
        let oldMillis = try #require(fractionMillis(legacy))
        #expect(abs(newMillis - oldMillis) <= 1)
    }

    @Test("Monotonic t keeps sub-millisecond precision through encoding")
    func monotonicPrecision() throws {
        let fake = FakeClock(start: 1_000.000000123)
        let (log, _) = makeLog(fake)
        let expected = fake.now - 1_000
        log.record("precise")
        log.flushNow()
        let events = try allEvents(log)
        #expect(events.count == 1)
        #expect(events[0].t == expected)
        #expect(events[0].t > 0)
        #expect(events[0].t < 0.001)
    }

    @Test("A second tap supersedes a dangling run")
    func hubSupersededRun() throws {
        let fake = FakeClock()
        let hub = TelemetryHub(
            directory: nil, sessionID: "hub-test",
            clock: fake.clock, wall: fake.wall, originUptime: 1_000
        )
        hub.record(TelemetryName.tap)
        hub.record(TelemetryName.tap)
        #expect(hub.hasActiveRun)
        let tail = hub.telemetryLog.tail(3).map(\.event)
        #expect(tail == ["T0.tap", "run.end", "T0.tap"])
        hub.endRunIfActive(outcome: "stopped")
        #expect(!hub.hasActiveRun)
        #expect(hub.telemetryLog.tail(1).first?.fields == ["outcome": "stopped"])
    }

    @Test("Reader-entry event carries session and source")
    func readerEnteredEvent() async throws {
        let fake = FakeClock()
        let hub = TelemetryHub(
            directory: nil, sessionID: "frame-test",
            clock: fake.clock, wall: fake.wall, originUptime: 1_000
        )
        hub.markReaderEntered(source: "link")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let event = try #require(hub.oplog.tail(1).first)
        #expect(event.event == TelemetryName.readerEntered)
        #expect(event.session == "frame-test")
        #expect(event.fields == ["source": "link"])
    }
}
