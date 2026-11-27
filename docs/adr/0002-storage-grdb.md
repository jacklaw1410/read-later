# ADR-0002 — Storage is GRDB, not SwiftData

Status: accepted · Date: 2026-11-12 · Amended: 2026-11-27

## Decision

`ReadLaterStore` is GRDB over system SQLite, with FTS5 for phrase
search and an explicit oplog as the sync boundary. `SyncOplog` writes
`ChangeLogEntry` rows to the `syncoplog` table. CloudKit mirrors the log,
never the store.

## Context

The product rule needs full-text search: a saved phrase must be
findable by a word inside it. SQLite ships FTS5 on both platforms, and
GRDB exposes it as a first-class feature with ordered migrations and
typed rows. SwiftData and Core Data expose no FTS5; the workaround is
unsupported raw SQL against the store, breakable on any OS update
(`spec/engineering.md` §10.4).

Sync already chose the log: `spec/state-machines.md` §8 appends a
`ChangeLog` row in the same transaction as every domain write and
replays entries on the other device, with last-writer-wins per field
and tombstone deletes. Once the log owns sync, the free CloudKit store
mirroring that SwiftData and Core Data advertise buys nothing. What
remains of those frameworks is their constraint.

## Consequences

- Phrase search, migrations and observation stay supported API.
- Nothing crosses a platform boundary except log entries and pack
  files, both already contracts. Android keeps Room with FTS4; the
  index format differs but the op shape holds (§10.4).
- Reversal is a storage rewrite plus a migration of every user's data.
  This decision is taken once.

## Rejected

- SwiftData (`@Model` macros, free mirroring). No FTS5, migrations
  limited to lightweight stages.
- Core Data. Mature, but no FTS5, GUI-owned model, verbose API.
- Raw SQLite. Full control, but typed rows, migrations and observation
  become 400 hand-written lines before the first feature.
