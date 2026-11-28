import Dispatch
import Foundation

#if canImport(os)
import os
#endif

/// True process start as uptime seconds, via sysctl. `ProcessInfo.systemUptime`
/// is seconds since boot, so start minus boot time lands on the same basis.
/// Falls back to nil; the caller then uses hub init time and says so.
enum ProcessStart {
    static func uptime() -> TimeInterval? {
        #if canImport(Darwin)
        let start = procStartTime()
        let boot = bootTime()
        guard start.tv_sec != 0, boot.tv_sec != 0 else { return nil }
        let startEpoch = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let bootEpoch = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        let uptime = startEpoch - bootEpoch
        guard uptime >= 0, uptime < ProcessInfo.processInfo.systemUptime + 1 else { return nil }
        return uptime
        #else
        return nil
        #endif
    }

    #if canImport(Darwin)
    private static func procStartTime() -> timeval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result: Int32 = mib.withUnsafeMutableBufferPointer { ptr in
            sysctl(ptr.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0 else { return timeval() }
        return info.kp_proc.p_starttime
    }

    private static func bootTime() -> timeval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let result: Int32 = mib.withUnsafeMutableBufferPointer { ptr in
            sysctl(ptr.baseAddress, 2, &boot, &size, nil, 0)
        }
        guard result == 0 else { return timeval() }
        return boot
    }
    #endif
}

/// Emits `os_signpost` intervals and events for the entry checkpoints. The
/// switch below admits only checkpoint names; the admitted name is passed
/// through, so the signpost cannot drift from `TelemetryName`.
final class SignpostEmitter: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(os)
    private let poster = OSSignposter(subsystem: "app.readlater", category: "ttfw")
    private var run: OSSignpostIntervalState?
    private var runID: OSSignpostID?
    private var launch: OSSignpostIntervalState?
    private var launchID: OSSignpostID?
    #else
    private var runActive = false
    #endif

    var hasActiveRun: Bool {
        lock.withLock {
            #if canImport(os)
            run != nil
            #else
            runActive
            #endif
        }
    }

    func beginLaunch() {
        lock.withLock {
            #if canImport(os)
            if launch == nil {
                let id = poster.makeSignpostID()
                launchID = id
                launch = poster.beginInterval("launch", id: id)
            }
            #endif
        }
    }

    func endLaunch() {
        lock.withLock {
            #if canImport(os)
            if let state = launch {
                launch = nil
                launchID = nil
                poster.endInterval("launch", state)
            }
            #endif
        }
    }

    func beginRun() {
        lock.withLock {
            #if canImport(os)
            if let state = run {
                run = nil
                runID = nil
                poster.endInterval("ttfw", state)
            }
            let id = poster.makeSignpostID()
            runID = id
            run = poster.beginInterval("ttfw", id: id)
            #else
            runActive = true
            #endif
        }
    }

    func endRun() {
        lock.withLock {
            #if canImport(os)
            if let state = run {
                run = nil
                runID = nil
                poster.endInterval("ttfw", state)
            }
            #else
            runActive = false
            #endif
        }
    }

    /// Emits the event on the active run or launch interval. Unknown names
    /// are telemetry-only by design: only checkpoint names get a signpost.
    func event(_ name: String) {
        lock.withLock {
            #if canImport(os)
            switch name {
            case TelemetryName.entryReady:
                if let id = launchID { poster.emitEvent(name, id: id) }
            case TelemetryName.firstFrame:
                if let id = launchID { poster.emitEvent(name, id: id) }
            case TelemetryName.entryTap:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.fetchStart:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.fetchHeaders:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.fetchBodyDone:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.extractParsed:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.planReady:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.speakEnqueued:
                if let id = runID { poster.emitEvent(name, id: id) }
            case TelemetryName.firstWord:
                if let id = runID { poster.emitEvent(name, id: id) }
            default:
                break
            }
            #endif
        }
    }
}

/// The process-wide telemetry hub. One telemetry log, one signpost emitter.
///
/// The shared instance starts memory-only. The app calls `configure` at
/// launch with the real directory; until then `record` fills the ring and
/// drops nothing the ring can hold. Tests build their own instances.
///
/// Unchecked Sendable by design: the telemetry log owns its locks, the emitter
/// owns its, and the observer list is append-once at init.
public final class TelemetryHub: @unchecked Sendable {
    public static let shared = TelemetryHub()

    public let telemetryLog: TelemetryLog
    private let emitter = SignpostEmitter()
    private var observers: [NSObjectProtocol] = []
    private let observerLock = NSLock()

    public init(
        directory: URL? = nil,
        sessionID: String = String(UUID().uuidString.prefix(8)),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wall: @escaping @Sendable () -> Date = Date.init,
        originUptime: TimeInterval? = nil
    ) {
        telemetryLog = TelemetryLog(
            directory: directory, sessionID: sessionID, clock: clock, wall: wall,
            originUptime: originUptime
        )
        let center = NotificationCenter.default
        for raw in [
            "UIApplicationDidEnterBackgroundNotification",
            "UIApplicationWillEnterForegroundNotification",
            "NSApplicationDidResignActiveNotification",
            "NSApplicationWillBecomeActiveNotification",
        ] {
            let token = center.addObserver(forName: Notification.Name(raw), object: nil, queue: nil) { [weak self] _ in
                self?.telemetryLog.flushNow()
            }
            observerLock.withLock { observers.append(token) }
        }
    }

    deinit {
        let tokens = observerLock.withLock { observers }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Points the telemetry log at `Application Support/Telemetry/`. Called
    /// once at app launch, before the first record.
    public func configure(directory: URL? = TelemetryLog.defaultDirectory()) {
        telemetryLog.setDirectory(directory)
    }

    public var hasActiveRun: Bool { emitter.hasActiveRun }

    /// Records to the telemetry log and, for checkpoint names, to the signpost
    /// emitter. A tap ends a dangling run as superseded before starting the
    /// new one; the first word ends the run.
    public func record(_ name: String, fields: [String: String] = [:]) {
        switch name {
        case TelemetryName.processStart:
            emitter.beginLaunch()
        case TelemetryName.entryTap:
            if emitter.hasActiveRun {
                telemetryLog.record(TelemetryName.runEnd, fields: ["outcome": "superseded"])
                emitter.endRun()
            }
            emitter.beginRun()
        case TelemetryName.firstFrame:
            emitter.event(name)
            emitter.endLaunch()
        case TelemetryName.firstWord:
            emitter.event(name)
            emitter.endRun()
        default:
            emitter.event(name)
        }
        telemetryLog.record(name, fields: fields)
    }

    /// Ends the active run without a first word (reader left, session
    /// stopped). No-op when no run is active.
    public func endRunIfActive(outcome: String) {
        guard emitter.hasActiveRun else { return }
        telemetryLog.record(TelemetryName.runEnd, fields: ["outcome": outcome])
        emitter.endRun()
    }

    /// Entry view appeared. The first-frame event follows on the next main
    /// runloop turn, which is the frame the reader can act on.
    public func markEntryReady() {
        record(TelemetryName.entryReady)
        DispatchQueue.main.async { [weak self] in
            self?.record(TelemetryName.firstFrame)
        }
    }

    /// Reader view appeared. The entry event follows on the next main runloop
    /// turn, which is the first frame the reader can act on. Telemetry stamps
    /// `session`; `source` names the ingress.
    public func markReaderEntered(source: String) {
        DispatchQueue.main.async { [weak self] in
            self?.record(TelemetryName.readerEntered, fields: ["source": source])
        }
    }

    public func flush() {
        telemetryLog.flushNow()
    }
}
