# Read Later — app

iOS 17+ / macOS 14+ reading app. Paste a link, listen, tap a word.

**Status:** first milestone. The pipeline compiles and the reader runs against a fixed
document. Extraction from the network, pack download and sync are not wired yet.

The research that produced this design lives in `read-later-research`. That repo is
append-only evidence; this one is code.

## Layout

| Path | Holds |
|---|---|
| `apps/apple/` | XcodeGen project, app target, platform code |
| `packages/ReadLaterCore/` | Block model, extraction, spoken plan, invariant, lookup protocol |
| `packages/ReadLaterPacks/` | Pack manifest, sha256 verify, install state machine |
| `packages/ReadLaterStore/` | GRDB schema, migrations, FTS5, oplog |
| `packages/ReadLaterUI/` | Calm Editorial tokens and shared views |
| `packages/ReadLaterTestKit/` | Fixture loading and assertions |
| `contracts/` | Versioned JSON Schemas shared with the research repo |
| `fixtures/` | 20 committed pages and their expected block plans |
| `tools/blockplan/` | Dumps a block plan so the research gate can score it |
| `docs/` | ADRs, provenance |

## Build

```bash
# packages
swift test --package-path packages/ReadLaterCore

# app
cd apps/apple && xcodegen generate
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater -destination 'platform=macOS' build
```

The generated `.xcodeproj` is not committed. `project.yml` is the source.

## Rules

1. `extract()` returns `[Block]`, never one string.
2. Every spoken sentence is an exact slice of its block text. The invariant runs at load.
3. Reader-facing copy is owned by the research repo's specs. This repo quotes it.
4. One commit per unit of work, Conventional Commits.
