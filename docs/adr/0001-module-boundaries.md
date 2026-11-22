# ADR-0001 — Module boundaries and the contracts seam

Status: accepted · Date: 2026-11-12 · Amended: 2026-11-21

## Decision

Five packages, one seam. `ReadLaterCore` (block model, extraction,
spoken plan, invariant, in-process protocols), `ReadLaterPacks`
(manifest, verify, install state machine), `ReadLaterStore` (GRDB
schema, migrations, FTS5, oplog), `ReadLaterUI` (Calm Editorial tokens
and shared views), `ReadLaterTestKit` (fixture loading, invariant
harness, assertions). The packages touch each other only through
versioned JSON contracts in `contracts/`: the block plan and the pack
manifest.

`ReadLaterCore` may also hold in-process protocols and the value types
they use, provided they import only Foundation and SwiftSoup. Examples:
`Diagnostics`, `SpeechController`, `LookupProvider`, `Extractor`,
`CapabilityPacks`, `LibraryProvider`, `LibraryRow` and `DiagnosticsExporting`.
A view in `ReadLaterUI` reads app-only state, such as pack installs or
library rows, through a protocol defined in Core. The app target
implements the protocol. Data that crosses a package boundary still
travels as a versioned JSON contract.

## Context

The research repo fixes this shape in `spec/engineering.md` §1 and
names exactly two contracts in §1.1: the block plan (written by
`extract()`, read by the app, the research gate and every future
platform) and the pack manifest (written by the pack builder, read by
the installer). The pilot log stays out: it is a research instrument,
not an app output. Section 6 states the rules that keep the seam
honest: a schema change is a version bump, the Swift types derive from
the schema, and a fixture proves each state.

## Consequences

- `extract()` returns `[Block]`, never one string
  (`docs/adr/0002-extraction-returns-blocks.md` in `read-later-research`). The reader renders and
  skips by kind; the speech queue consumes only spoken blocks.
- A second platform reimplements the packages but reuses the contracts
  unchanged (`spec/engineering.md` §1.2). Porting storage or speech is
  bounded by the file format, not by Swift internals.
- CI validates every fixture against its schema on every PR. Schema and
  fixture drift fails in seconds instead of surfacing as a wrong
  percentage months later.

## Rejected

- One package with internal imports. Cheaper today, and every platform
  port becomes a rewrite instead of a reimplementation behind a file.
- Sharing code across platforms (KMP, Rust core). Both cost a second
  toolchain before one platform ships (`spec/engineering.md` §8).
