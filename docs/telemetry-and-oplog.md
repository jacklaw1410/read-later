# Telemetry and oplog

Two different logs share the word "oplog" in code. This note separates them.

- **Telemetry** is the app's timestamped measurement log, one JSON line per
  event (`GLOSSARY.md:240-242`). The code names it `TelemetryLog`
  (`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryOplog.swift:98`).
  The name is pending a migration ticket; "oplog" is not a synonym for
  telemetry. Use "telemetry" in new names and prose. The rename row is
  `../read-later-research/STATUS.md:165`.
- **Oplog** is the append-only log of sync operations
  (`GLOSSARY.md:244-246`). It lives in the `syncoplog` SQLite table and its
  rows are `ChangeLogEntry`. That name is correct and stays.

The app writes telemetry locally. No analytics SDK and no network are
involved (`TelemetryOplog.swift:89-90`). Sync replays the oplog; it never
mirrors a store (`packages/ReadLaterStore/Sources/ReadLaterStore/SyncOplog.swift:5`).

## Data structures

### Telemetry event

`TelemetryEvent` is one JSONL line
(`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryOplog.swift:7-21`):

| Field | Type | Meaning |
|---|---|---|
| `t` | `Double` | Monotonic seconds since process start (`clock() - originUptime`, `TelemetryOplog.swift:172`). |
| `iso` | `String` | Wall-clock time, ISO 8601 with fractional seconds (`TelemetryOplog.swift:173`, `:319-323`). |
| `session` | `String` | Process id, eight UUID characters by default (`TelemetryOplog.swift:131`, `:174`). |
| `event` | `String` | Event name from `TelemetryName` or a dynamic name. |
| `fields` | `[String: String]` | Flat string map. Numbers are formatted as strings at the call site. |

`TelemetryName` is not an enum of cases. It is an enum namespace of static
string constants (`TelemetryOplog.swift:27-87`). The `T0`–`T7` names match
`read-later-research/spec/device-test-plan.md` so a trace and an export
agree (`TelemetryOplog.swift:23-26`).

### TelemetryLog

The append-only writer
(`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryOplog.swift:98-324`).

- `record(_:fields:)` never throws and never blocks the caller. It JSON-encodes
  the event, appends the line to `pending`, appends the event to a bounded
  in-memory `ring`, and schedules a flush on a private utility queue
  (`TelemetryOplog.swift:169-196`).
- Defaults: `telemetry.jsonl`, 1,048,576 bytes per file, 5 files, ring capacity
  200, flush delay 1.0 s (`TelemetryOplog.swift:99-103`).
- Stock directory is `Application Support/Telemetry/`
  (`TelemetryOplog.swift:153-157`). Before `setDirectory` the log is
  memory-only; the app calls `configure()` at launch before the first record
  (`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryHub.swift:212-216`,
  `apps/apple/Sources/App/ReadLaterApp.swift:31`).
- Rotation keeps `telemetry.jsonl` plus `telemetry.1.jsonl` … `telemetry.4.jsonl`; the
  newest rotated file is `telemetry.1.jsonl` (`TelemetryOplog.swift:296-317`).
- `tail(_:)` returns the last `n` ring events, oldest first. The ring survives
  a full disk, so a crash report or the Diagnostics screen can still show
  events (`TelemetryOplog.swift:203-207`).
- `flushNow()` writes pending lines and drops them on failure; `flushIfDue()`
  is the injected-clock path used by tests
  (`TelemetryOplog.swift:209-234`). The hub flushes on app background and
  foreground notifications on both platforms
  (`TelemetryHub.swift:193-204`); `flush()` is public for explicit exports
  (`TelemetryHub.swift:262-264`).
- `ProcessStart.uptime()` derives true process start via `sysctl` so `t` is
  process-relative, not boot-relative (`TelemetryHub.swift:8-50`,
  `TelemetryOplog.swift:148`).

### TelemetryHub and signposts

`TelemetryHub.shared` owns one `TelemetryLog` and one `SignpostEmitter`
(`TelemetryHub.swift:174-178`). `record(_:fields:)` always writes to the
telemetry log, and adds lifecycle behavior for four names
(`TelemetryHub.swift:220-243`):

- `launch.processStart` begins the `launch` signpost interval.
- `T0.tap` ends a dangling run as `run.end` with `outcome=superseded`, then
  begins a new `ttfw` interval.
- `launch.firstFrame` emits the launch signpost event and ends `launch`.
- `T7.firstWord` emits the signpost event and ends `ttfw`.

`endRunIfActive(outcome:)` writes `run.end` and ends the interval only when a
run is active (`TelemetryHub.swift:245-251`). `markEntryReady()` records
`launch.entryReady` then schedules `launch.firstFrame` one main-loop turn
later (`TelemetryHub.swift:253-260`).

`SignpostEmitter` emits `os_signpost` intervals `launch` and `ttfw`, and
events under subsystem `app.readlater`, category `ttfw`
(`TelemetryHub.swift:52-65`, `:77-130`). Only the ten checkpoint names get a
signpost; every other name is telemetry-log-only (`TelemetryHub.swift:132-163`).
Checkpoints with signposts: `launch.entryReady`, `launch.firstFrame`,
`T0.tap`, `T1.fetchStart`, `T2.headers`, `T3.bodyDone`, `T4.parsed`,
`T5.planReady`, `T6.speakEnqueued`, `T7.firstWord`
(`TelemetryHub.swift:137-157`).

### Sync oplog

`syncoplog` table (`packages/ReadLaterStore/Sources/ReadLaterStore/Schema.swift:48-55`):

```sql
CREATE TABLE syncoplog(
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    device TEXT NOT NULL,
    "at" REAL NOT NULL,
    op TEXT NOT NULL,
    payload TEXT NOT NULL
)
```

`ChangeLogEntry` is the typed row: `seq`, `device`, `at: Date`, `op`,
`payload: String` (`packages/ReadLaterCore/Sources/ReadLaterCore/Model.swift:282-298`).
Dates are `timeIntervalSinceReferenceDate` REALs so a save/read round-trips
bit-exact (`packages/ReadLaterStore/Sources/ReadLaterStore/Store.swift:74-76`).

`SyncOplog` holds the DB queue and an injected `device` id, never read from the
machine (`packages/ReadLaterStore/Sources/ReadLaterStore/SyncOplog.swift:10-19`).
It has three operations:

- `append(op:payload:at:)` writes one entry in its own transaction, then logs
  a `store.write` telemetry event with `write=oplog.append`, `ms`, and `main`
  (`SyncOplog.swift:21-33`).
- `static insert(in:device:op:payload:at:)` is the transaction-aware insert.
  `Store` calls it so a domain row and its log row commit together
  (`SyncOplog.swift:54-60`, `Store.swift:94-96`).
- `entries(after:limit:)` pages rows oldest first by `seq`
  (`SyncOplog.swift:35-52`).

`Store.timedWrite(_:fields:_:)` is the single write path. It times the SQLite
write and always emits `store.write`, adding `write`, `ms`, `copyMs`,
`encodeMs`, and `main` plus caller fields
(`Store.swift:94-122`). The M8 regression net asserts every write op logs
one `store.write` event
(`packages/ReadLaterStore/Tests/ReadLaterStoreTests/StoreTimingTests.swift:6-48`).

Reading positions are local-only. `record.position`, `position.dismiss`, and
`position.saved` emit `store.write` telemetry but append no `syncoplog` row
(`Store.swift:32-35`, `:193-238`, `:275-281`, `:306-314`). The class comment
at `Store.swift:71` says every write appends a syncoplog row; the specific
comments and code above are the precise rule.

## Telemetry events — exhaustive catalogue

Every name below is written by `TelemetryHub.record` into the JSONL log
(`TelemetryHub.swift:242`). Names marked **signpost** also emit an
`os_signpost` event (`TelemetryHub.swift:137-157`). Events marked **DEBUG**
compile out of Release and require launch arguments
(`apps/apple/Sources/App/DebugProbes.swift:1-29`,
`apps/apple/Sources/App/DebugFrameMonitor.swift:1-23`).

### Launch, run, and T0–T7 checkpoints

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `launch.processStart` | `TelemetryOplog.swift:28` | `apps/apple/Sources/App/ReadLaterApp.swift:32` | App `init`, after `configure()` | none |
| `launch.entryReady` (signpost) | `TelemetryOplog.swift:29` | `TelemetryHub.swift:256`; called `packages/ReadLaterUI/Sources/ReadLaterUI/EntryView.swift:274` | Entry view `.onAppear` | none |
| `launch.firstFrame` (signpost) | `TelemetryOplog.swift:30` | `TelemetryHub.swift:258` | One main-loop turn after `entryReady` | none |
| `T0.tap` (signpost) | `TelemetryOplog.swift:31` | `EntryView.swift:632`, `apps/apple/Sources/App/RootView.swift:395` | Entry submit; DEBUG autoplay path | none |
| `T1.fetchStart` (signpost) | `TelemetryOplog.swift:32` | `packages/ReadLaterUI/Sources/ReadLaterUI/PageFetching.swift:67` | Just before the page request | `host` |
| `T2.headers` (signpost) | `TelemetryOplog.swift:33` | `PageFetching.swift:167-170` | URLSession delegate receives response headers | `status`, `host` |
| `T3.bodyDone` (signpost) | `TelemetryOplog.swift:34` | `PageFetching.swift:76-79` | Body accumulated; before size/type checks | `status`, `bytes` |
| `T4.parsed` (signpost) | `TelemetryOplog.swift:35` | `packages/ReadLaterUI/Sources/ReadLaterUI/ArticleIngress.swift:133` | Extractor returns blocks | `blocks` |
| `T5.planReady` (signpost) | `TelemetryOplog.swift:36` | `ArticleIngress.swift:140-143`, `:175-178`, `EntryView.swift:671-674` | Spoken plan built (fetch, paste, or sample) | `sentences`, `words` (fetch); `source`, `words` (paste/sample) |
| `T6.speakEnqueued` (signpost) | `TelemetryOplog.swift:37` | `apps/apple/Sources/Platform/AVSpeechController.swift:174-176` | First `speak`, only when a run is active | `sentences` |
| `T7.firstWord` (signpost) | `TelemetryOplog.swift:38` | `AVSpeechController.swift:409-413` | First word boundary, only when a run is active; ends the run | none |
| `run.end` | `TelemetryOplog.swift:39` | `TelemetryHub.swift:229`, `:249`; triggered `RootView.swift:115` | Superseded tap, reader close, or `endRunIfActive` | `outcome`: `superseded`, `closed`, or caller value (`stopped` in tests, `TelemetryOplogTests.swift:185`) |
| `launch.build` | `TelemetryOplog.swift:72` | `ReadLaterApp.swift:33-57` | App `init`; ties the log to a build | `commit`, `configuration`, `model`, `os` |

### Ingestion and article open

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `fetch.skipped` | `TelemetryOplog.swift:40` | `EntryView.swift:670` | Bundled sample link, no network | `reason=sample-link` |
| `fetch.failed` | `TelemetryOplog.swift:41` | `ArticleIngress.swift:108`, `:111`, `:114`, `:118` | PageFetchError or catch-all | `kind=tooLarge` + `bytes`; `kind=notText`; `kind=offline` |
| `extract.start` | `TelemetryOplog.swift:42` | `ArticleIngress.swift:130` | Before extraction | `bytes` |
| `extract.failed` | `TelemetryOplog.swift:43` | `ArticleIngress.swift:152`, `:155`, `:158`, `:161`, `:165` | ExtractionError or catch-all | `kind`: `walled`, `unrendered`, `notAnArticle`, `failed` |
| `article.ready` | `TelemetryOplog.swift:44` | `apps/apple/Sources/App/RootView.swift:104-107` | `LibraryModel.open` builds the reader session | `title`, `words` |
| `reader-open` | `TelemetryOplog.swift:55` | `EntryView.swift:657`, `:675`, `:692` | Entry path opens a document | `source`: `pasted`, `sample`, `link` |

### Speech and playback

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `speech.didStart` | `TelemetryOplog.swift:45` | `AVSpeechController.swift:385-389` | First utterance-start delegate callback in a run; once per `speak`, gated on active run | none |
| `speech.utteranceStart` | `TelemetryOplog.swift:46-50` | `AVSpeechController.swift:382-384` | Every utterance start, ungated so scrub releases have a phone-side mark | `utterance` |
| `tap.play` | `TelemetryOplog.swift:73` | `apps/apple/Sources/App/ReaderSession.swift:115-116` | Play handler entry, when not speaking | `word` (wash index, `-1` if unset) |
| `tap.pause` | `TelemetryOplog.swift:74` | `ReaderSession.swift:115-116` | Play handler entry, when speaking | `word` |
| `play` | `TelemetryOplog.swift:56` | `ReaderSession.swift:126` | Play branch starts audio | none |
| `pause` | `TelemetryOplog.swift:57` | `ReaderSession.swift:123`, `:138` | Pause branch or `.speaking` case in toggle | none |
| `finished` | `TelemetryOplog.swift:58` | `ReaderSession.swift:451` | Speech state becomes `.finished` | none |
| `speed change` | `TelemetryOplog.swift:66` | `ReaderSession.swift:180` | Reader changes pace | `from`, `to` |
| `scrub.commit` | `TelemetryOplog.swift:75` | `ReaderSession.swift:206-209` | After restart on scrub release | `fraction` (4 dp), `word` |
| `scrub.begin` | `TelemetryOplog.swift:76` | `ReaderSession.swift:243-245` | Drag begins | `state` (speech state description) |
| `hold-start` | `TelemetryOplog.swift:67` | `ReaderSession.swift:385`, `:391` | Scroll or menu disables auto-follow | `reason`: `scroll`, `menu` |
| `hold-end` | `TelemetryOplog.swift:68` | `ReaderSession.swift:397` | Reader resumes auto-follow | `outcome=resume` |
| `speech.pauseCall` | `TelemetryOplog.swift:77` | `AVSpeechController.swift:190-193` | `pauseSpeaking(at: .word)` call | `accepted`, `synthPaused` |
| `speech.enqueue` | `TelemetryOplog.swift:80` | `AVSpeechController.swift:334-337` | Each utterance enqueued | `utterance`, `inFlight` |
| `speech.didFinish` | `TelemetryOplog.swift:81` | `AVSpeechController.swift:426-431` | Utterance finish delegate callback | `utterance`, `inFlight`, `nextToEnqueue`, `state` |
| `speech.didPause` | `TelemetryOplog.swift:78` | `AVSpeechController.swift:446-449` | Pause delegate callback, including late ones | `tracked`, `state` |
| `speech.didResume` | `TelemetryOplog.swift:79` | `AVSpeechController.swift:456-459` | Resume delegate callback | `tracked`, `state` |

### Lookup and card

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `lookup` | `TelemetryOplog.swift:59` | `apps/apple/Sources/App/LookupController.swift:58` | Token tap, after trimming | `word` |
| `lookup.hit` | `TelemetryOplog.swift:60` | `LookupController.swift:70-76` | Provider returns a hit | `source` (LookupSource raw value), `lines` (gloss line count) |
| `lookup.miss` | `TelemetryOplog.swift:61` | `LookupController.swift:80-83` | Provider returns a miss, after refinement | `kind` (MissKind description) |
| `card.shown` | `TelemetryOplog.swift:62-65` | `packages/ReadLaterUI/Sources/ReadLaterUI/LookupCard.swift:112-115`, `MissCard.swift:145-148` | One main-loop turn after card `.onAppear`, once per card | `word`, `kind`: `hit` / `miss` |
| `card.close` | `TelemetryOplog.swift:51-54` | `LookupController.swift:99` | Close request, before teardown | none |

### App lifecycle and store

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `app-hide` | `TelemetryOplog.swift:69` | `RootView.swift:366-371` | Scene phase `.background` | none |
| `app-return` | `TelemetryOplog.swift:70` | `RootView.swift:372-374` | Scene phase `.active` | none |
| `store.write` | `TelemetryOplog.swift:82` | `Store.swift:107-120`, `SyncOplog.swift:28-32` | Every `timedWrite` and every direct `oplog.append` | `write`, `ms`, `copyMs`, `encodeMs`, `main`; `record.position` adds `source`, `word`, `encodeMs` (`Store.swift:210-214`) |

The `write` values seen on `store.write` are asserted in
`packages/ReadLaterStore/Tests/ReadLaterStoreTests/StoreTimingTests.swift:33-37`:
`save.document`, `record.position`, `position.saved`, `phrase.save`,
`occurrence.record`, `oplog.append`, `position.dismiss`, `document.delete`.

### DEBUG device probes

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `marker.request` | `TelemetryOplog.swift:83` | `apps/apple/Sources/App/DebugProbes.swift:96-100` | `--debug.marker=<n>` click, one per second after 2 s | `index`, `host` (CACurrentMediaTime), `outputLatency` |
| `frames.second` | `TelemetryOplog.swift:84` | `DebugProbes.swift:132-135` | `--debug.frames` on iOS, once per second | `fps`, `longestGapMs` |
| `frame.tapWindow` | `TelemetryOplog.swift:85` | `apps/apple/Sources/App/DebugFrameMonitor.swift:115-126` | Tap window closes, five frames after state change or at 120-frame cap | `frames`, `durationMs`, `fps`, `longestGapMs`, `tapToStateMs`, `state` (`changed`/`missing`) |
| `frame.scrubWindow` | `TelemetryOplog.swift:86` | `DebugFrameMonitor.swift:96-102` | Scrub drag release | `frames`, `durationMs`, `fps`, `longestGapMs` |

Frame fields come from `FrameWindowSummary.fields()`
(`packages/ReadLaterCore/Sources/ReadLaterCore/FrameCounter.swift:71-80`);
the tap window adds its two keys at `DebugFrameMonitor.swift:119-125`.

### Dynamic names (not in `TelemetryName`)

| Event | Emitted at | When | Fields |
|---|---|---|---|
| `state.idle`, `state.warming`, `state.speaking`, `state.paused`, `state.finished` | `ReaderSession.swift:429-431`; states from `packages/ReadLaterCore/Sources/ReadLaterCore/Contracts.swift:68-74` | Every speech delegate state change, including late callbacks | none |
| `paste.tap` | `packages/ReadLaterUI/Sources/ReadLaterUI/EntryPaste.swift:122` | iOS paste button tap | `source=button` |
| `paste.delivered` | `EntryPaste.swift:135-138` | Board text read within the 6 s prompt wait | `branch=prompt`, `chars` |
| `paste.blocked` | `EntryPaste.swift:144-147` | Poll expires; followed by an immediate `flush()` | none |

`EntryPaste` writes these through a private `diag` helper that forwards to
`TelemetryHub.record` (`EntryPaste.swift:94-97`).

## Sync oplog operations — exhaustive catalogue

All four production ops are written by `SyncOplog.insert` inside `Store.timedWrite`.
`SyncOplog.append(op:payload:)` accepts any string and is used only by tests.

| `op` | Written at | When | `payload` |
|---|---|---|---|
| `document.save` | `Store.swift:134-151` | Document upsert on open/ingress | JSON-encoded `Document`: `id`, `url`, `title`, `plan` (`BlockPlan` JSON), `addedAt` (`Store.swift:127-133`, `Model.swift:236-249`) |
| `document.delete` | `Store.swift:172-177` | Document delete, including `cacheBust` (`Store.swift:316-320`) | `{"id": "<uuid>"}` (`Store.swift:173`) |
| `phrase.save` | `Store.swift:329-350` | Saved phrase upsert | JSON-encoded `Phrase`: `id`, `word`, `gloss`, `source`, `createdAt` (`Model.swift:266-279`) |
| `occurrence.record` | `Store.swift:364-393` | Each saved phrase sighting | JSON map `phrase_id`, `document_id`, `block_id`, `char_offset` (`Store.swift:372-377`) |

`OplogTests` asserts exactly one entry per write for these four ops, ordered
by `seq`, with the injected device id
(`packages/ReadLaterStore/Tests/ReadLaterStoreTests/OplogTests.swift:8-41`).

## Concrete examples

One telemetry line, from the flush-and-order test
(`packages/ReadLaterCore/Tests/ReadLaterCoreTests/TelemetryOplogTests.swift:55-81`).
`fields` is a flat string map and `t` is process-relative:

```json
{"t":1,"iso":"2023-11-14T22:13:20.000Z","session":"test-session","event":"alpha","fields":{"k":"1"}}
```

A T0–T7 run, as asserted by the hub test
(`TelemetryOplogTests.swift:156-170`):

```text
T0.tap → T1.fetchStart → … → T7.firstWord
```

A superseded run shows why `run.end` is telemetry-log-only
(`TelemetryOplogTests.swift:173-187`):

```text
T0.tap → run.end {outcome: superseded} → T0.tap
```

`store.write` from `Store.timedWrite`
(`Store.swift:107-120`); `encodeMs` is caller-supplied for `record.position`
(`Store.swift:210-214`):

```text
event:   store.write
fields:  {write: record.position, ms: 1.23, copyMs: 1.23,
          encodeMs: 0.87, main: 0, source: tick, word: 42}
```

The lookup chain, from tap to painted card to close:

```text
lookup        {word: café}
lookup.hit    {source: Apple 譯典通 (built-in), lines: 3}
card.shown    {word: café, kind: hit}
card.close
```

`LookupSource` raw values are defined at `Contracts.swift:131-137`.

A sync oplog row for an occurrence, from `recordOccurrence`
(`Store.swift:372-390`):

```text
seq: 7  device: device-A  at: <reference-date REAL>
op:  occurrence.record
payload: {"phrase_id":"…","document_id":"…","block_id":"0","char_offset":"12"}
```

`entries(after:limit:)` pages these rows back oldest first
(`SyncOplog.swift:35-52`, `SyncOplogTests.swift:43-61`).

## Reading the logs

The Diagnostics screen is DEBUG-only
(`apps/apple/Sources/App/DiagnosticsExport.swift:14-24`). It reads the log
through `DiagnosticsAdapter`: source path, file count, pending count, and the
last five event names (`apps/apple/Sources/App/DiagnosticsAdapter.swift:19-29`).
`stage()` flushes, copies `telemetry*.jsonl` into a fresh temporary folder, and
writes `summary.json` with schema `rl-diagnostics-2`
(`DiagnosticsExport.swift:42-74`, `:90-114`). The same folder can be pulled
with `devicectl` (`DiagnosticsExport.swift:116-122`,
`apps/apple/README.md:190-197`). T0–T7 event names in the export match the
device plan checkpoints (`apps/apple/README.md:199-201`).
