import Foundation
import GRDB
import ReadLaterCore

/// Append-only sync operation log. Sync replays these entries from the
/// `syncoplog` table; it never mirrors a store.
///
/// The `device` identifier is injected at `Store` creation, never read from
/// the machine. `Store` writes use `insert(in:)` so the domain row and its
/// log row land in the same transaction.
public final class SyncOplog: Sendable {
    private let dbQueue: DatabaseQueue
    public let device: String
    let telemetry: TelemetryHub

    init(dbQueue: DatabaseQueue, device: String, telemetry: TelemetryHub) {
        self.dbQueue = dbQueue
        self.device = device
        self.telemetry = telemetry
    }

    /// Appends one entry in its own transaction.
    public func append(op: String, payload: String, at date: Date = .now) throws {
        let start = CFAbsoluteTimeGetCurrent()
        try dbQueue.write { db in
            try Self.insert(in: db, device: device, op: op, payload: payload, at: date)
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        telemetry.record(TelemetryName.storeWrite, fields: [
            "write": "oplog.append",
            "ms": String(format: "%.2f", ms),
            "main": Thread.isMainThread ? "1" : "0",
        ])
    }

    /// Entries after `seq`, oldest first, up to `limit` rows.
    public func entries(after seq: Int64 = 0, limit: Int = 100) throws -> [SyncOplogEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT seq, device, "at", op, payload FROM \(Schema.syncOplog)
                WHERE seq > ? ORDER BY seq ASC LIMIT ?
                """, arguments: [seq, limit])
            return rows.map { row in
                let at: Double = row["at"]
                return SyncOplogEntry(
                    seq: row["seq"],
                    device: row["device"],
                    at: Date(timeIntervalSinceReferenceDate: at),
                    op: row["op"],
                    payload: row["payload"])
            }
        }
    }

    /// Appends one entry inside an existing transaction. Called by `Store`
    /// so each domain write and its log row commit together.
    static func insert(in db: Database, device: String, op: String, payload: String, at date: Date = .now) throws {
        try db.execute(sql: """
            INSERT INTO \(Schema.syncOplog)(device, "at", op, payload) VALUES (?, ?, ?, ?)
            """, arguments: [device, date.timeIntervalSinceReferenceDate, op, payload])
    }
}
