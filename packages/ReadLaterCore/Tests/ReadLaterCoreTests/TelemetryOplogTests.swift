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
    maxBytes: Int = TelemetryOplog.defaultMaxBytes,
    maxFiles: Int = TelemetryOplog.defaultMaxFiles,
    ringCapacity: Int = TelemetryOplog.defaultRingCapacity
) -> (TelemetryOplog, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("oplog-test-\(UUID().uuidString)", isDirectory: true)
    let log = TelemetryOplog(
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

private func allEvents(_ log: TelemetryOplog) throws -> [TelemetryEvent] {
    try log.logFiles().reversed().flatMap { try readLines($0) }
}

@Suite("Telemetry oplog")
struct TelemetryOplogTests {
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

        fake.now += TelemetryOplog.defaultFlushDelay + 1
        log.flushIfDue()
        #expect(try allEvents(log).map(\.event) == ["before-deadline"])
    }

    @Test("An unwritable directory never throws and keeps the ring")
    func unwritableDirectory() throws {
        let fake = FakeClock()
        let dead = URL(fileURLWithPath: "/dev/null/oplog-test-\(UUID().uuidString)")
        let log = TelemetryOplog(
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
        #expect(hub.oplog.tail(3).map(\.event) == ["T0.tap", "T1.fetchStart", "T7.firstWord"])
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
        let tail = hub.oplog.tail(3).map(\.event)
        #expect(tail == ["T0.tap", "run.end", "T0.tap"])
        hub.endRunIfActive(outcome: "stopped")
        #expect(!hub.hasActiveRun)
        #expect(hub.oplog.tail(1).first?.fields == ["outcome": "stopped"])
    }
}
