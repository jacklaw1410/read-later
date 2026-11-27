# ADR-0004 — Two logs: telemetry and sync oplog

Status: accepted · Date: 2026-11-27

## Decision

The app keeps two logs with two names. Telemetry is the measurement log:
`TelemetryLog` writes `telemetry*.jsonl` under `Application Support/Telemetry/`.
The oplog is the sync log: `SyncOplog` writes rows to the `syncoplog` table.
"Oplog" names only the sync log. See `../telemetry-and-sync-oplog.md` for each
log's fields and events, and `../../GLOSSARY.md` for the terms.

## Context

Both logs were once named "oplog": the measurement log was `TelemetryOplog`
with `oplog.jsonl`, and the sync log was `Oplog` over `changelog`. One word for
two things made readers check which log a line came from.

The invariants conflict. Telemetry must never block or throw on the reader
path, may drop lines when a flush fails, rotates across five 1 MB files, and
stamps process-relative time with flat string fields. The sync oplog must
commit with the domain write, keep `seq` order and device ids, carry typed JSON
payloads, and survive an app update. Deleting telemetry removes diagnostics
only; deleting the oplog removes the record sync needs to reconstruct state.

## Consequences

- One term per thing in code, files and prose. The old type alias and legacy
  `oplog*.jsonl` reads are gone.
- Migration v6 renames `changelog` to `syncoplog` without rewriting rows.
- Observation stays one-way. `SyncOplog.append` emits a `store.write` telemetry
  event; telemetry never writes to the oplog.
- `store.write` carries `write`, not `op`, so a write kind cannot read as a
  sync op.

## Rejected

- One uniform log. One interface would have to allow both drop-on-failure and
  never-drop writes, and both process-relative time and durable sequence order.
  That is a shallow module with conflicting guarantees.
- Keeping the overloaded name. It moved the decision into every reader's head
  instead of concentrating it here.
