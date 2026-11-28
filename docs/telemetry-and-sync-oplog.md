# Telemetry and sync oplog

Two logs serve two jobs. Telemetry records measurements locally; the oplog
records state changes for replication. This note describes what each log
contains. For why they stay separate, see `adr/0004-two-logs.md`.

- **Telemetry** is the app's timestamped measurement log, one JSON line per
  event (`GLOSSARY.md`). The code type is `TelemetryLog`; files are
  `telemetry*.jsonl` under `Application Support/Telemetry/`.
- **Oplog** is the append-only log of sync operations (`GLOSSARY.md`). The
  code type is `SyncOplog`; rows live in the `syncoplog` SQLite table and are
  `SyncOplogEntry`.

The app writes telemetry locally. No analytics SDK and no network are
involved. Sync replays the oplog; it never mirrors a store
(`packages/ReadLaterStore/Sources/ReadLaterStore/SyncOplog.swift:5`).

## Data structures

### Telemetry event

`TelemetryEvent` is one JSONL line
(`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryLog.swift:7-21`):

| Field | Type | Meaning |
|---|---|---|
| `t` | `Double` | Monotonic seconds since process start (`clock() - originUptime`, `TelemetryLog.swift:172`). |
| `iso` | `String` | Wall-clock time, ISO 8601 with fractional seconds (`TelemetryLog.swift:173`, `:319-323`). |
| `session` | `String` | Process id, eight UUID characters by default (`TelemetryLog.swift:131`, `:174`). |
| `event` | `String` | Event name from `TelemetryName` or a dynamic name. |
| `fields` | `[String: String]` | Flat string map. Numbers are formatted as strings at the call site. |

`TelemetryName` is not an enum of cases. It is an enum namespace of static
string constants (`TelemetryLog.swift:27-94`). Every event name is
`<category>.<event>` with lower_snake_case segments, for example
`launch.process_start`, `entry.tap`, `fetch.body_done` and
`speech.first_word`. There is no camelCase, hyphen or bare event name.
A name matches `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`.
The checkpoint names map one-to-one onto
`read-later-research/spec/device-test-plan.md` so a trace and an export agree
(`TelemetryLog.swift:23-26`).

### TelemetryLog

The append-only writer
(`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryLog.swift:98-324`).

- `record(_:fields:)` never throws and never blocks the caller. It JSON-encodes
  the event, appends the line to `pending`, appends the event to a bounded
  in-memory `ring`, and schedules a flush on a private utility queue
  (`TelemetryLog.swift:169-196`).
- Defaults: `telemetry.jsonl`, 1,048,576 bytes per file, 5 files, ring capacity
  200, flush delay 1.0 s (`TelemetryLog.swift:99-103`).
- Stock directory is `Application Support/Telemetry/`
  (`TelemetryLog.swift:153-157`). Before `setDirectory` the log is
  memory-only; the app calls `configure()` at launch before the first record
  (`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryHub.swift:212-216`,
  `apps/apple/Sources/App/ReadLaterApp.swift:31`).
- Rotation keeps `telemetry.jsonl` plus `telemetry.1.jsonl` … `telemetry.4.jsonl`; the
  newest rotated file is `telemetry.1.jsonl` (`TelemetryLog.swift:296-317`).
- `tail(_:)` returns the last `n` ring events, oldest first. The ring survives
  a full disk, so a crash report or the Diagnostics screen can still show
  events (`TelemetryLog.swift:203-207`).
- `flushNow()` writes pending lines and drops them on failure; `flushIfDue()`
  is the injected-clock path used by tests
  (`TelemetryLog.swift:209-234`). The hub flushes on app background and
  foreground notifications on both platforms
  (`TelemetryHub.swift:193-204`); `flush()` is public for explicit exports
  (`TelemetryHub.swift:262-264`).
- `ProcessStart.uptime()` derives true process start via `sysctl` so `t` is
  process-relative, not boot-relative (`TelemetryHub.swift:8-50`,
  `TelemetryLog.swift:148`).

### TelemetryHub and signposts

`TelemetryHub.shared` owns one `TelemetryLog` and one `SignpostEmitter`
(`TelemetryHub.swift:174-178`). `record(_:fields:)` always writes to the
telemetry log, and adds lifecycle behavior for four names
(`TelemetryHub.swift:220-243`):

- `launch.process_start` begins the `launch` signpost interval.
- `entry.tap` ends a dangling run as `run.end` with `outcome=superseded`, then
  begins a new `ttfw` interval.
- `launch.first_frame` emits the launch signpost event and ends `launch`.
- `speech.first_word` emits the signpost event and ends `ttfw`.

`endRunIfActive(outcome:)` writes `run.end` and ends the interval only when a
run is active (`TelemetryHub.swift:245-251`). `markEntryReady()` records
`launch.entry_ready` then schedules `launch.first_frame` one main-loop turn
later (`TelemetryHub.swift:253-260`).

`SignpostEmitter` emits `os_signpost` intervals `launch` and `ttfw`, and
events under subsystem `app.readlater`, category `ttfw`
(`TelemetryHub.swift:52-65`, `:77-130`). Only the ten checkpoint names get a
signpost; every other name is telemetry-log-only (`TelemetryHub.swift:132-163`).
Checkpoints with signposts: `launch.entry_ready`, `launch.first_frame`,
`entry.tap`, `fetch.start`, `fetch.headers`, `fetch.body_done`, `extract.parsed`,
`plan.ready`, `speech.enqueued`, `speech.first_word`
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

`SyncOplogEntry` is the typed row: `seq`, `device`, `at: Date`, `op`,
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

### Launch, run, and entry checkpoints

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `launch.process_start` | `TelemetryLog.swift:28` | `apps/apple/Sources/App/ReadLaterApp.swift:32` | App `init`, after `configure()` | none |
| `launch.entry_ready` (signpost) | `TelemetryLog.swift:29` | `TelemetryHub.swift:256`; called `packages/ReadLaterUI/Sources/ReadLaterUI/EntryView.swift:274` | Entry view `.onAppear` | none |
| `launch.first_frame` (signpost) | `TelemetryLog.swift:30` | `TelemetryHub.swift:258` | One main-loop turn after `entryReady` | none |
| `entry.tap` (signpost) | `TelemetryLog.swift:31` | `EntryView.swift:632`, `apps/apple/Sources/App/RootView.swift:395` | Entry submit; DEBUG autoplay path | none |
| `fetch.start` (signpost) | `TelemetryLog.swift:32` | `packages/ReadLaterUI/Sources/ReadLaterUI/PageFetching.swift:67` | Just before the page request | `host` |
| `fetch.headers` (signpost) | `TelemetryLog.swift:33` | `PageFetching.swift:167-170` | URLSession delegate receives response headers | `status`, `host` |
| `fetch.body_done` (signpost) | `TelemetryLog.swift:34` | `PageFetching.swift:76-79` | Body accumulated; before size/type checks | `status`, `bytes` |
| `extract.parsed` (signpost) | `TelemetryLog.swift:35` | `packages/ReadLaterUI/Sources/ReadLaterUI/ArticleIngress.swift:133` | Extractor returns blocks | `blocks` |
| `plan.ready` (signpost) | `TelemetryLog.swift:36` | `ArticleIngress.swift:140-143`, `:175-178`, `EntryView.swift:671-674` | Spoken plan built (fetch, paste, or sample) | `sentences`, `words` (fetch); `source`, `words` (paste/sample) |
| `speech.enqueued` (signpost) | `TelemetryLog.swift:37` | `apps/apple/Sources/Platform/AVSpeechController.swift:174-176` | First `speak`, only when a run is active | `sentences` |
| `speech.first_word` (signpost) | `TelemetryLog.swift:38` | `AVSpeechController.swift:409-413` | First word boundary, only when a run is active; ends the run | none |
| `run.end` | `TelemetryLog.swift:39` | `TelemetryHub.swift:229`, `:249`; triggered `RootView.swift:115` | Superseded tap, reader close, or `endRunIfActive` | `outcome`: `superseded`, `closed`, or caller value (`stopped` in tests, `TelemetryLogTests.swift:185`) |
| `launch.build` | `TelemetryLog.swift:72` | `ReadLaterApp.swift:33-57` | App `init`; ties the log to a build | `commit`, `configuration`, `model`, `os` |
| `reader.entered` | `TelemetryLog.swift:47` | `TelemetryHub.swift:267`; called `packages/ReadLaterUI/Sources/ReadLaterUI/ReaderView.swift:219` | Reader view first frame, one main-loop turn after appear | `source`: `link`, `clipboard`, `rawText`, `sample`, `library` |

### Ingestion and article open

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `fetch.skipped` | `TelemetryLog.swift:40` | `EntryView.swift:670` | Bundled sample link, no network | `reason=sample-link` |
| `fetch.failed` | `TelemetryLog.swift:41` | `ArticleIngress.swift:108`, `:111`, `:114`, `:118` | PageFetchError or catch-all | `kind=tooLarge` + `bytes`; `kind=notText`; `kind=offline` |
| `extract.start` | `TelemetryLog.swift:42` | `ArticleIngress.swift:130` | Before extraction | `bytes` |
| `extract.failed` | `TelemetryLog.swift:43` | `ArticleIngress.swift:152`, `:155`, `:158`, `:161`, `:165` | ExtractionError or catch-all | `kind`: `walled`, `unrendered`, `notAnArticle`, `failed` |
| `article.ready` | `TelemetryLog.swift:44` | `apps/apple/Sources/App/RootView.swift:104-107` | `LibraryModel.open` builds the reader session | `title`, `words` |
| `reader.open` | `TelemetryLog.swift:55` | `EntryView.swift:657`, `:675`, `:692` | Entry path opens a document | `source`: `pasted`, `sample`, `link` |

### Speech and playback

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `speech.did_start` | `TelemetryLog.swift:48` | `AVSpeechController.swift:436` | First utterance-start delegate callback in a run; once per `speak`, gated on active run | none |
| `speech.utterance_start` | `TelemetryLog.swift:53` | `AVSpeechController.swift:400-402` | Every utterance start, ungated so scrub releases have a phone-side mark | `utterance` |
| `tap.play` | `TelemetryLog.swift:76` | `apps/apple/Sources/App/ReaderSession.swift:115-116` | Play handler entry, when not speaking | `word` (wash index, `-1` if unset) |
| `tap.pause` | `TelemetryLog.swift:77` | `ReaderSession.swift:115-116` | Play handler entry, when speaking | `word` |
| `playback.play` | `TelemetryLog.swift:59` | `ReaderSession.swift:126` | Play branch starts audio | none |
| `playback.pause` | `TelemetryLog.swift:60` | `ReaderSession.swift:123`, `:138` | Pause branch or `.speaking` case in toggle | none |
| `audio.interruption` | `TelemetryLog.swift:89` | `StallProbe.swift:57-60` | An audio interruption began or ended, before the hold or resume | `type` (raw value), `state` |
| `playback.finished` | `TelemetryLog.swift:61` | `ReaderSession.swift:451` | Speech state becomes `.finished` | none |
| `playback.speed_change` | `TelemetryLog.swift:69` | `ReaderSession.swift:180` | Reader changes pace | `from`, `to` |
| `scrub.commit` | `TelemetryLog.swift:78` | `ReaderSession.swift:206-209` | After restart on scrub release | `fraction` (4 dp), `word` |
| `scrub.begin` | `TelemetryLog.swift:79` | `ReaderSession.swift:243-245` | Drag begins | `state` (speech state description) |
| `hold.start` | `TelemetryLog.swift:70` | `ReaderSession.swift:385`, `:391` | Scroll or menu disables auto-follow | `reason`: `scroll`, `menu` |
| `hold.end` | `TelemetryLog.swift:71` | `ReaderSession.swift:397` | Reader resumes auto-follow | `outcome=resume` |
| `speech.enqueue` | `TelemetryLog.swift:82` | `AVSpeechController.swift:376-379` | Each utterance enqueued | `utterance`, `inFlight` |
| `speech.did_finish` | `TelemetryLog.swift:83` | `AVSpeechController.swift:481-486` | Utterance finish delegate callback | `utterance`, `inFlight`, `nextToEnqueue`, `state` |
| `speech.did_pause` | `TelemetryLog.swift:80` | `AVSpeechController.swift:502-505` | Pause delegate callback, including late ones | `tracked`, `state` |
| `speech.did_resume` | `TelemetryLog.swift:81` | `AVSpeechController.swift:512-515` | Resume delegate callback | `tracked`, `state` |
| `speech.did_cancel` | `TelemetryLog.swift:88` | `StallProbe.swift:52-55` | Utterance cancel delegate callback, including the hold's own stop | `tracked`, `state` |
| `speech.word` | `TelemetryLog.swift:86` | `StallProbe.swift:47-50` | Every word boundary; Debug builds only, so a stall shows its last word | `word`, `utterance` |
| `speech.heartbeat` | `TelemetryLog.swift:87` | `StallProbe.swift:102` | 1 Hz while the voice runs; Debug builds only, for stall evidence. The probe stops if the sampled state leaves `.speaking` | `state`, `isSpeaking`, `isPaused`, `inFlight`, `word`, `uptime`, `outputVolume` (iOS) |

### Lookup and card

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `lookup.start` | `TelemetryLog.swift:59` | `apps/apple/Sources/App/LookupController.swift:58` | Token tap, after trimming | `word` |
| `lookup.hit` | `TelemetryLog.swift:60` | `LookupController.swift:70-76` | Provider returns a hit | `source` (LookupSource raw value), `lines` (gloss line count) |
| `lookup.miss` | `TelemetryLog.swift:61` | `LookupController.swift:80-83` | Provider returns a miss, after refinement | `kind` (MissKind description) |
| `card.shown` | `TelemetryLog.swift:62-65` | `packages/ReadLaterUI/Sources/ReadLaterUI/LookupCard.swift:112-115`, `MissCard.swift:145-148` | One main-loop turn after card `.onAppear`, once per card | `word`, `kind`: `hit` / `miss` |
| `card.close` | `TelemetryLog.swift:51-54` | `LookupController.swift:99` | Close request, before teardown | none |

### App lifecycle and store

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `app.hide` | `TelemetryLog.swift:69` | `RootView.swift:366-371` | Scene phase `.background` | none |
| `app.return` | `TelemetryLog.swift:70` | `RootView.swift:372-374` | Scene phase `.active` | none |
| `store.write` | `TelemetryLog.swift:82` | `Store.swift:107-120`, `SyncOplog.swift:28-32` | Every `timedWrite` and every direct `oplog.append` | `write`, `ms`, `copyMs`, `encodeMs`, `main`; `record.position` adds `source`, `word`, `encodeMs` (`Store.swift:210-214`) |

The `write` values seen on `store.write` are asserted in
`packages/ReadLaterStore/Tests/ReadLaterStoreTests/StoreTimingTests.swift:33-37`:
`save.document`, `record.position`, `position.saved`, `phrase.save`,
`occurrence.record`, `oplog.append`, `position.dismiss`, `document.delete`.

### DEBUG device probes

| Event | Defined | Emitted at | When | Fields |
|---|---|---|---|---|
| `marker.request` | `TelemetryLog.swift:83` | `apps/apple/Sources/App/DebugProbes.swift:96-100` | `--debug.marker=<n>` click, one per second after 2 s | `index`, `host` (CACurrentMediaTime), `outputLatency` |
| `frame.second` | `TelemetryLog.swift:84` | `DebugProbes.swift:132-135` | `--debug.frames` on iOS, once per second | `fps`, `longestGapMs` |
| `frame.tap_window` | `TelemetryLog.swift:85` | `apps/apple/Sources/App/DebugFrameMonitor.swift:115-126` | Tap window closes, five frames after state change or at 120-frame cap | `frames`, `durationMs`, `fps`, `longestGapMs`, `tapToStateMs`, `state` (`changed`/`missing`) |
| `frame.scrub_window` | `TelemetryLog.swift:86` | `DebugFrameMonitor.swift:96-102` | Scrub drag release | `frames`, `durationMs`, `fps`, `longestGapMs` |

Frame fields come from `FrameWindowSummary.fields()`
(`packages/ReadLaterCore/Sources/ReadLaterCore/FrameCounter.swift:71-80`);
the tap window adds its two keys at `DebugFrameMonitor.swift:119-125`.

### Dynamic names (not in `TelemetryName`)

| Event | Emitted at | When | Fields |
|---|---|---|---|
| `speech.idle`, `speech.warming`, `speech.speaking`, `speech.paused`, `speech.finished` | `ReaderSession.swift:429-431`; states from `packages/ReadLaterCore/Sources/ReadLaterCore/Contracts.swift:68-74` | Every speech delegate state change, including late callbacks | none |
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
(`packages/ReadLaterCore/Tests/ReadLaterCoreTests/TelemetryLogTests.swift:55-81`).
`fields` is a flat string map and `t` is process-relative:

```json
{"t":1,"iso":"2023-11-14T22:13:20.000Z","session":"test-session","event":"alpha","fields":{"k":"1"}}
```

An entry run, as asserted by the hub test
(`TelemetryLogTests.swift:156-170`):

```text
entry.tap → fetch.start → … → speech.first_word
```

A superseded run shows why `run.end` is telemetry-log-only
(`TelemetryLogTests.swift:173-187`):

```text
entry.tap → run.end {outcome: superseded} → entry.tap
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
`apps/apple/README.md:190-197`). Entry checkpoint names in the export map
one-to-one onto the device plan checkpoints (`apps/apple/README.md:199-201`).
