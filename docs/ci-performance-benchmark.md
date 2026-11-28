# CI performance benchmark from telemetry

Status: proposal · Date: 2026-11-27

## Recommendation

Add a separate `benchmark` workflow on `macos-15` with three measurements in two
parallel jobs:

1. A **stage suite** in Release. Run the `EntryStageBenchmarkTests` probe in
   `packages/ReadLaterUI` against four committed fixture articles and write one
   `probe.sample` telemetry event per article and arm, carrying p50 and p95
   over the repetitions. Arms: `extract`, `plan`, `invariant`, `sha256`,
   `save`, `seed`, `library`, `record`, `read`, plus derived `total`. Gate p50
   and p95 per article and arm.
2. An **interaction suite** in the Debug macOS app. One launch runs 20 scripted
   iterations of play, pause, scrub commit, lookup hit, lookup miss, lookup
   present and lookup resume. Gate the app-side handler and frame metrics; keep
   audio latency in the device lab.
3. A **launch suite** in Debug. Measure `launch.first_frame` over 20 app launches
   after two warmups.

A new Rust crate, `tools/telemetrybench`, reads the telemetry JSONL, compares
each arm with a baseline in the existing public `read-later-dev` R2 bucket, and
fails the pull request when a gated statistic breaches its limit or when the
arm/event set changed. Pull-request runs read `latest.json` with no credentials.
A maintainer accepts a worse result with `/benchmark accept <reason>`; a
privileged `issue_comment` workflow records the acceptance.

Do **not** add a standalone build job in v1. The existing jobs build different
configurations and run in parallel. A shared build job would serialise a
consumer behind it and add an artifact round trip. Measured existing jobs make
this concrete below. Cache dependencies instead, and split `build-for-testing`
from `test-without-building` only when two or more test jobs consume the same
build.

## Context

The existing workflow runs `lint`, `contracts`, `unit`, `build-macos`,
`build-ios`, `invariant`, `e2e-core`, `e2e-full` and `release-guard`
(`.github/workflows/apple.yml`). `e2e-core` has a 20-minute timeout and a count
guard that fails on a short suite, a failed test or any skip
(`.github/workflows/apple.yml:159`, `:214-251`). The summary is a Markdown table
appended to `$GITHUB_STEP_SUMMARY` (`.github/workflows/apple.yml:233-239`).

The repo now has measured CI durations for two successful pull-request runs on
2026-11-27, read from the Actions API:

| Job | Run 46000409871 | Run 46015983392 |
|---|---:|---:|
| `release-guard` | 5:18 | 5:27 |
| `invariant` | 3:28 | 2:24 |
| `unit` | 3:16 | 3:10 |
| `build-ios` | 2:36 | 3:12 |
| `build-macos` | 2:21 | 1:40 |
| `e2e-core (macos)` | 2:12 | 3:21 |
| `lint` | 0:40 | 0:37 |
| `contracts` | 0:07 | 0:11 |
| **Workflow wall clock** | **8:05** | **10:30** |

The two workflows started at 12:39:26Z and 14:26:41Z. Jobs started up to about
three minutes late because the macOS runner pool was busy. The critical path is
`release-guard`, not the sum of the jobs.

Telemetry is a local JSONL log. One line per event, with `t` (monotonic seconds
since process start), `iso` (wall clock), `session`, `event` and a flat string
map `fields` (`docs/telemetry-and-sync-oplog.md:22-36`). Differences between two
`t` values are monotonic and immune to wall-clock changes
(`packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryLog.swift:172`).

Fine stages already have a probe design. `EntryScalingProbeTests` on branch
`probe/entry-scaling-r2` times `extract`, `plan`, `invariant`, `sha256`, `save`,
`seed`, `library` and the whole `read` path, and writes a `probe.sample` event
per article and arm. The fitter is `tools/entryscale`. The first run is recorded
in `read-later-research/evidence/2026-11-26-entry-scaling-r2/results.md`; the
tickets are `jacklaw1410/read-later#40` and `#41`.

Reader interactions already have most of the marks:

- `ReaderSession.togglePlay` records `tap.play` or `tap.pause` at handler entry
  and records `playback.play` or `playback.pause` as it changes state
  (`apps/apple/Sources/App/ReaderSession.swift:111-150`). The speech state
  change also writes `speech.speaking`, `speech.paused` and the other
  `speech.<state>` events (`ReaderSession.swift:431`).
- `DebugFrameMonitor` turns on for Debug builds. It writes `frame.tap_window`
  with `tapToStateMs`, `frames`, `fps` and `longestGapMs` for a play or pause
  tap, and `frame.scrub_window` with the same frame fields for a scrub drag
  (`apps/apple/Sources/App/DebugFrameMonitor.swift:12-126`,
  `packages/ReadLaterCore/Sources/ReadLaterCore/FrameCounter.swift:54-83`).
- `LookupController` records `lookup.start` before the provider call,
  `lookup.hit` or `lookup.miss` when it resolves, `card.close` on close, and
  `speech.speaking` when a close resumes a voice that was live
  (`apps/apple/Sources/App/LookupController.swift:44-103`, `:180-190`).
- `LookupCard` and `MissCard` record `card.shown` one main-loop turn after the
  card attaches, so it marks paint, not intent
  (`packages/ReadLaterUI/Sources/ReadLaterUI/LookupCard.swift:104-116`,
  `MissCard.swift:140-152`).

What CI can gate from those marks is the app-side work: the handler, the
resolve and the paint. What it cannot gate without audio is the voice: tap to
first sound, pause to silence, scrub release to sound, and card close to
resumed speech. Those stay in `LatencyDeviceTests` and `tools/devicebench`
(`apps/apple/E2ETests/LatencyDeviceTests.swift`,
`tools/devicebench/README.md`).

That evidence is the reason to gate stages separately:

- Extract follows HTML bytes and opening-tag count, not spoken words. The
  words-only model has an R² of about 0.55 for total time; extract alone has an
  R² of about 0.86 on bytes.
- The invariant has a strong `blocks · wordsPerBlock²` term even where the
  one-variable exponent looks linear-ish.
- Telemetry inside a span inflates it. The telemetry `plan` span is about 23 %
  larger than the probe's `plan + sha256` because `TelemetryLog.record` runs
  after `extract.parsed` and before `plan.ready`.
- Library open is about 4 ms, about 5 % of the measured entry total. A single
  total hides that.
- `save` and `seed` are a few milliseconds; `sha256` is a fraction of a
  millisecond. A total-only gate cannot tell which one moved.

The research spec fixes the gate shape. D2a is launch to first input, recorded
as p50 and p95 over 10 launches
(`read-later-research/spec/device-test-plan.md:20`). The gates compare p95 with
a baseline and fail at more than 20 % above it
(`read-later-research/spec/device-test-plan.md:104-112`). `ttfb` and `body` are
reported and never gated because their spread is the network's
(`read-later-research/spec/device-test-plan.md:109-110`).

## Spike results (2026-11-28)

The first rollout step ran on `macos-15`: branch `spike/benchmark-probes`,
commit `09715e6`, workflow run
[`46107176139`](https://github.com/jacklaw1410/read-later/actions/runs/46107176139).
The job took 7:41: 3:52 for five stage-probe processes, 1:48 for the Debug
build, and 1:38 for five interaction launches. These are one day on one runner,
not a baseline.

What the spike proved:

| Check | Result |
|---|---|
| Release stage probe writes telemetry | 32 `probe.sample` per run: 8 arms × 4 fixtures |
| 20 samples per arm | Present as `ms_p50` and `ms_p95`; `reps = 20` |
| Four fixtures are usable | All four produce samples in every run |
| Debug app launch emits launch marks | `launch.first_frame` and `reader.entered` in 5 of 5 launches |
| Interaction driver completes | 20 measured + 3 warmup iterations, all outcomes `ok`, 5 of 5 launches |
| Tap frame window | `frame.tap_window` in 69 to 70 events per launch |
| Scrub frame window | `frame.scrub_window` in 23 events per launch, 60 fps, 16.67 ms worst gap |
| Card paint | `card.shown` 46 times per launch: one hit and one miss per measured iteration |
| Lookup hit and miss | Both resolve through the bundled demo pack, no network |

Stage p50 spread across the five runs:

| Fixture | `extract` | `plan` | `save` | `seed` | `read` |
|---|---:|---:|---:|---:|---:|
| `027-hn` | 20.2–26.1 ms | 0.36–0.40 ms | 1.22–1.38 ms | 0.13–0.14 ms | 23.8–25.2 ms |
| `095-sciencedaily` | 39.3–55.6 ms | 2.03–2.59 ms | 1.93–2.15 ms | 2.36–2.60 ms | 41.1–48.9 ms |
| `004-averages` | 27.4–36.4 ms | 5.68–7.94 ms | 1.75–2.78 ms | 6.28–8.50 ms | 37.8–53.9 ms |
| `005-great-work` | 68.7–93.0 ms | 15.5–19.3 ms | 5.48–6.95 ms | 18.3–21.7 ms | 83.8–107.0 ms |

Stage p95 was much noisier: `extract` on `004-averages` ranged 31.1–61.4 ms,
`seed` on `005-great-work` 19.5–36.8 ms, and `library` on `004-averages`
10.9–74.0 ms. One scheduler stall moves the p95 of 20 samples. This is why the
proposal gates stage p50 and reports stage p95 until more clean baselines exist.

Interaction p50 spread across the five launches was tight:

| Metric | p50 range |
|---|---:|
| `playback.play` handler | 0.07–0.10 ms |
| `playback.pause` handler | 0.26–0.31 ms |
| `scrub` commit handler | 0.35–0.44 ms |
| lookup hit, resolve | 11.3–23.4 ms |
| lookup miss, resolve | 7.8–14.4 ms |
| lookup hit, resolve to paint | 36.7–40.0 ms |
| lookup miss, resolve to paint | 33.6–37.4 ms |
| `frame.tap_window.tapToStateMs` p95 | 0.42–0.61 ms |
| `frame.tap_window.longestGapMs` p95 | 16.7–27.1 ms |
| `frame.scrub_window` | 60 fps, 16.67 ms worst gap |

The first lookup after launch took 266–390 ms, because the system dictionary
and pack are cold. Warmups remove it; the measured iterations start at 34–40 ms.
This is why the interaction suite uses three warmups, not one.

Two driver conditions were not obvious before the spike:

- A scrub must hold for a few frames. Begin and finish in the same runloop
  produce no `frame.scrub_window` because `FrameCounter` needs at least two
  frames.
- Taps must be spaced. Back-to-back taps reset `DebugFrameMonitor` before it
  emits the previous `frame.tap_window`; five taps collapsed to five windows
  instead of ten.

The spike used the existing `EntryScalingProbeTests` body with 20 fixed
samples. The full implementation still needs the `record` arm, the `total`
derivation, and the `telemetrybench` comparator. Those are rollout step 2.

The numbers in the JSON example below are illustrative. Use the spike table for
shape and the next five blank runs for thresholds.

## What to measure

### Stage suite

| Metric | Probe arm | Covers | Gate |
|---|---|---|---|
| `extract` | `SwiftSoupExtractor.extract` | Parse and page classification | p50 |
| `plan` | `SpokenPlanBuilder.build` | Sentence split, block plan, invariant | p50 |
| `invariant` | `SpokenPlanInvariant.violations` | The quadratic risk from #40 | p50 |
| `sha256` | `ArticleIngress.sha256` | Page hash before the plan | p50 |
| `save` | `Store.save(document:)` | SQLite document write | p50 |
| `seed` | `ReaderSeed` init | `BlockRoles` and `SpokenWordNumbering` | p50 |
| `library` | read, re-save, seed | Library open without the view | p50 |
| `record` | `TelemetryLog.record` | Telemetry overhead that inflates spans | p50 |
| `read` | `ArticleIngress.read` | Whole ingress path, as a check | Report |
| `total` | sum of extract, plan, sha256, save, seed | Entry work before the reader | p50 |

`library` is not part of `total`; it is the alternate open path. `read` is a
check that the probe still exercises the shipped path. It is not summed because
`read` includes `extract`, `sha256` and `plan` again.

Each `probe.sample` also carries `blocks`, `words`, `sentences`, `bytes`,
`nodes` (opening tags), `wpb`, `reps`, `ms_p50`, `ms_p95`, `ms_min`, `ms_max`
and a `checksum` that proves the arm did the expected work. The fitter and the
CI tool can then explain a change: a larger page, a larger plan, or a slower
stage.

### Interaction suite

| Metric | Derived from | Covers | Gate |
|---|---|---|---|
| `play.tapToState` | `tap.play` → `speech.speaking` | Play handler through speaking state | p50 and p95 |
| `pause.tapToState` | `tap.pause` → `speech.paused` | Pause handler through paused state | p50 and p95 |
| `tap.tapToState` | `frame.tap_window.tapToStateMs` | Tap window to the changed state | p50 and p95 |
| `tap.longestGap` | `frame.tap_window.longestGapMs` | Worst frame gap in the tap window | p95 |
| `scrub.commit` | `benchmark.interaction{kind=scrub}` | Drag release through `scrub(toFraction:)` | p50 and p95 |
| `scrub.longestGap` | `frame.scrub_window.longestGapMs` | Worst frame gap during the drag window | p95 |
| `lookup.resolveHit` | `lookup.start` → `lookup.hit` | Pack or system dictionary hit | p50 and p95 |
| `lookup.resolveMiss` | `lookup.start` → `lookup.miss` | Lookup that ends in a miss card | p50 and p95 |
| `lookup.present` | `lookup.start` → `card.shown` | Resolve, present and paint the card | p50 and p95 |
| `lookup.resume` | `card.close` → `speech.speaking` | Close a card and resume a live voice | p50 and p95 |
| `speed.apply` | `benchmark.interaction{kind=speed}` | Speed change handler | Report |
| `step.utterance`, `step.block` | `benchmark.interaction{kind=step.*}` | Unit navigation handlers | Report |

The interaction suite runs in the Debug app because the frame monitor and the
`--debug.` surface are Debug-only. One launch is seeded with a short plain-text
fixture under `fixtures/bench/`, opens the saved place, and then runs 3 warmup
iterations and 20 measured iterations after `reader.entered`. Each iteration
does, in order:

1. `togglePlay`; wait for `speech.speaking`.
2. `togglePlay`; wait for `speech.paused`.
3. `beginScrubbing`; `scrub(toFraction: 0.5)`; `finishScrubbing`.
4. `lookup.tap(word: "out-argues")`; wait for `card.shown`; `closeCard`; wait
   for `speech.speaking`.
5. `lookup.tap(word: "zzzznotaword")`; wait for `card.shown`; `closeCard`.

`out-argues` is in the bundled demo pack and is not in the system dictionary,
so the hit is deterministic (`apps/apple/Sources/App/DemoPack.swift:1-55`).
The miss is a well-shaped token that neither source knows. Both paths run with
no network.

The driver calls the same `ReaderSession` and `LookupController` intents the
views call. It does not synthesize touches, so it removes host tap noise but
does not measure gesture recognition. `frame.tap_window` and
`frame.scrub_window` come from `DebugFrameMonitor`; if the hosted runner has no
display link, the frame rows are `missing` and only the handler rows gate. That
is recorded, not hidden.

Audio latency stays out of CI. `tap.play` to first sound, `tap.pause` to
silence, `scrub.commit` to sound and `card.close` to resumed speech need
`AVSpeechController` and a microphone. They stay in `LatencyDeviceTests` and
`tools/devicebench`. The CI rows are the app-side work the reader controls.

### Launch suite

| Metric | Derived from | Covers | Gate |
|---|---|---|---|
| `launch.first_frame` | `t(launch.first_frame) - t(launch.process_start)` | Process init, store open, entry view, first frame | p50 and p95 |
| `launch.entry_ready` | `t(launch.entry_ready) - t(launch.process_start)` | Same, minus one main-loop turn | Report |

Launch stays a Debug app measurement because the launch path has no Release
probe. Report the configuration in every record. Do not compare Debug to
Release.

### What is not gated

- `fetch.start` to `extract.parsed` exist only on a network fetch. The CI input is local. Report
  them only if a later suite adds a local fixture HTTP server.
- `speech.enqueued` and `speech.first_word` need the real `AVSpeechController`; the scripted voice has no
  first-word delay (`apps/apple/Sources/App/ScriptedSpeechController.swift:124-150`).
  Speech stays a device-lab number.
- Audio-side interactions need the real voice and a microphone: tap to first
  sound, pause to silence, scrub release to sound, and card close to resumed
  speech. They stay in `LatencyDeviceTests` and `tools/devicebench`.
- The Reader first frame needs a new telemetry event. It is a separate ticket.
- SwiftUI body counts and real gesture recognition. Those need Instruments or
  XCUITest and are #41 phase 2.

## Where to run

All suites use `macos-15`, the arm64 runner: 3 M1 vCPUs, 7 GB RAM, 14 GB SSD
(https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
That is the label `e2e-core` already uses (`.github/workflows/apple.yml:158`).
The runner image version is part of the baseline key.

| Suite | Venue | Why |
|---|---|---|
| Stage | `swift test -c release -enable-testing` in `packages/ReadLaterUI` | Same Release path as the evidence probe; no window server; direct telemetry file |
| Interaction | Debug macOS `.app`, one launch, scripted intents | Frame monitor and `--debug.` surface are Debug-only; card paint needs the real view |
| Launch | Debug macOS `.app` launched with `open -n -W` | Only way to measure process start to first frame |

The stage suite uses Release. The evidence run and the performance question are
about shipped code; a Debug probe would add bounds checks and unoptimised
SwiftSoup work. The probe is a test target, so `-Xswiftc -enable-testing` is
needed for `@testable import ReadLaterUI`.

A Debug stage suite would not actually share a build with the interaction app.
`swift test` builds into SwiftPM's `.build`; the app builds into Xcode
DerivedData. They compile the same sources twice. Sharing would require moving
the probe into an Xcode test target, which still leaves the stage numbers in
Debug and on a separate baseline. The only real saving would be the 146 s
Release build, and the cost is that the stage gate no longer measures shipped
code. Keep Release; run the stage and app jobs in parallel and cache SwiftPM.
A Debug stage run is acceptable only as a separate smoke suite with its own
baseline, not as the gate.

The interaction and launch suites use Debug for the existing `--debug.` launch
surface. They do not need a simulator. `open -n -W` registers the bundle with
LaunchServices, as the local instructions require
(`apps/apple/README.md:44-47`). A `--debug.telemetryDir=<path>` flag is still
recommended; it keeps the job independent of the home layout and lets the tool
clear a private directory.

The stage suite can run on a Linux runner only if the package builds there; it
does not (SwiftSoup and Apple frameworks), so it stays on macOS.

## Repetition and statistics

| Suite | Corpus | Samples | Warmups | How |
|---|---|---|---:|---|
| Stage | 4 committed fixtures | 20 per article and arm | 3 | one Release test process, in-process calls |
| Interaction | one seeded fixture | 20 per interaction | 3 | one Debug app launch, scripted intents |
| Launch | same store and fixture | 20 launches | 2 | 22 process launches |

Stage corpus, chosen from `fixtures/pages` for size and content type:

| Fixture | Spoken words | Blocks | Role |
|---|---:|---:|---|
| `027-hn` | 30 | 91 | tiny, link-list page |
| `095-sciencedaily` | 1,074 | 85 | short article |
| `004-averages` | 4,446 | 68 | essay |
| `005-great-work` | 11,822 | 235 | long article |

The counts come from the committed `*.blockplan.json` files. The corpus is
fixed and hashed. If a fixture is not usable by the shipped extractor, the
probe fails instead of silently skipping it.

The probe's timing loop follows `EntryScalingProbeTests`: one untimed warm-up,
then 20 timed calls per arm. The record keeps p50, p95, min, max and the repeat
count. Twenty samples make p95 the 19th value, not the maximum of five.

The interaction driver logs one `benchmark.interaction` per iteration with
`kind`, `ms`, `iteration` and `outcome`. The parser pairs the shipped events
around it (`tap.play` to `speech.speaking`, `lookup.start` to `card.shown`, and so on)
as a cross-check. If the two disagree by more than the threshold, the run is
`unstable`: the driver and the app are measuring different work.

Statistics:

- Report p50 and p95 per article and arm, and per interaction kind.
- Gate stage p50. Record stage p95 and show it as a warning for the first week;
  the spike showed the five-run p95 on the shared runner is dominated by one
  scheduler stall. Gate p50 and p95 for interaction and launch.
- Use nearest-rank percentiles: p95 is the value at index
  `ceil(0.95 * n) - 1` after sorting.
- Use the median, not the mean. One stalled call moves a mean and leaves a
  median alone. The tail matters because "a tap that stalls is the flow break
  the reader feels" (`tools/packbench/README.md:33-36`).
- Drop a sample only when it is more than 3 times the median. Report the drop
  count. More than two drops is `unstable`.
- Fail as `unstable` when `MAD / p50 > 0.5`. A ratio above 0.25 and at most 0.5
  warns in the summary.
- Gate each article and arm, and each interaction kind, separately. Do not pool
  articles of different sizes into one number; the evidence shows the size term
  is the signal. Do not pool play, lookup and scrub into one interaction number;
  they exercise different code.

The baseline is the median of the last five successful `main` runs for each
article, arm, interaction kind and statistic, taken before the current run. A
single `main` run is not a baseline. Append a run to `history` only when it has
the required sample count and passes the stability rule. Criterion keeps a saved baseline
and recommends repeated runs instead of one
(https://bheisler.github.io/criterion.rs/book/user_guide/command_line_output.html).
Bencher models a threshold over historical metrics with a maximum sample size
(https://bencher.dev/docs/explanation/thresholds/).

The `github-action-benchmark` maintainers report amplitude of about plus or
minus 10 to 20 percent on their own virtual environments and recommend a stable
environment if that is not acceptable
(https://github.com/benchmark-action/github-action-benchmark#stability-of-virtual-environment).
Criterion defaults to a plus or minus 2 percent noise threshold for tight
microbenchmarks, and warns that moving a laptop between battery and wall power
can produce apparent regressions
(https://bheisler.github.io/criterion.rs/book/user_guide/command_line_output.html).
The stage suite runs in-process with no UI, so it is closer to Criterion than to
a GUI launch. The launch suite is closer to the shared-runner case. The factors
below reflect that difference.

## Thresholds and failure

Formula, per article, arm and statistic:

```
limit = max(baseline * factor, baseline + floor)
fail  = current > limit
```

| Metric | Stat | Factor | Floor | Rationale |
|---|---|---:|---:|---|
| `extract` | p50 | 1.40 | 5 ms | Spike p50 spread up to 35 % |
| `extract` | p95 | 1.60 | 10 ms | Tail allows scheduler jitter; report-only for now |
| `plan` | p50 | 1.30 | 1 ms | Spike p50 spread up to 27 % |
| `plan` | p95 | 1.50 | 2 ms | Tail guard; report-only for now |
| `invariant` | p50 | 1.50 | 0.1 ms | Small absolute values need a floor |
| `invariant` | p95 | 1.60 | 0.3 ms | Quadratic term is the risk; report-only |
| `sha256` | p50 | 1.50 | 0.05 ms | Hash cost is tiny |
| `sha256` | p95 | 1.60 | 0.1 ms | I/O and allocation tail; report-only |
| `save` | p50 | 1.30 | 1 ms | SQLite write |
| `save` | p95 | 1.50 | 2 ms | File-system tail; report-only |
| `seed` | p50 | 1.40 | 1 ms | Linear in words |
| `seed` | p95 | 1.50 | 2 ms | Tail guard; report-only |
| `library` | p50 | 1.50 | 0.5 ms | Read and re-save; p50 spread up to 69 % |
| `library` | p95 | 1.50 | 1 ms | Tail guard; report-only |
| `record` | p50 | 1.25 | 0.05 ms | Compare against the 23 % span inflation |
| `record` | p95 | 1.50 | 0.1 ms | Allocation and lock tail; report-only |
| `total` | p50 | 1.35 | 10 ms | Sum of the stages |
| `total` | p95 | 1.50 | 20 ms | Tail guard; report-only |
| `play.tapToState` | p50 | 1.25 | 5 ms | Handler through speaking state |
| `play.tapToState` | p95 | 1.40 | 10 ms | Main-thread tail |
| `pause.tapToState` | p50 | 1.25 | 5 ms | Handler through paused state |
| `pause.tapToState` | p95 | 1.40 | 10 ms | Main-thread tail |
| `tap.tapToState` | p50 | 1.20 | 2 ms | Frame monitor's tap-to-state gap |
| `tap.tapToState` | p95 | 1.30 | 4 ms | One extra frame |
| `tap.longestGap` | p95 | 1.50 | 16.7 ms | One 60 Hz frame |
| `scrub.commit` | p50 | 1.25 | 2 ms | Drag release handler |
| `scrub.commit` | p95 | 1.40 | 5 ms | Restart scheduling tail |
| `scrub.longestGap` | p95 | 1.50 | 16.7 ms | One 60 Hz frame |
| `lookup.resolveHit` | p50 | 1.75 | 2 ms | Spike p50 11–23 ms |
| `lookup.resolveHit` | p95 | 2.00 | 5 ms | Async resolve tail |
| `lookup.resolveMiss` | p50 | 1.75 | 2 ms | Spike p50 8–14 ms |
| `lookup.resolveMiss` | p95 | 2.00 | 5 ms | Async resolve tail |
| `lookup.present` | p50 | 1.25 | 5 ms | Resolve, present and paint |
| `lookup.present` | p95 | 1.40 | 10 ms | Main-loop turn plus paint |
| `lookup.resume` | p50 | 1.25 | 5 ms | Close and resume the voice |
| `lookup.resume` | p95 | 1.40 | 10 ms | Main-thread tail |
| `launch.first_frame` | p50 | 1.20 | 10 ms | Below one 60 Hz frame is not perceptible |
| `launch.first_frame` | p95 | 1.30 | 20 ms | Tail allows more jitter; stall still fails |

Stage p95 rows above are recorded and warned, not failed, until five clean
`main` baselines show a stable tail. The factors and floors are the values to
use when the tool promotes them. Interaction and launch p95 rows gate now.

The 20 percent factor is the existing repo rule for `parse + plan`
(`read-later-research/spec/device-test-plan.md:106-108`). The higher factors
for `extract` and the tiny stages sit above the 10 to 20 percent amplitude the
benchmark action reports for shared runners. The floors are absolute; they stop
a 1 ms change on a 4 ms stage from reading as a 25 percent regression.

Worked example with invented numbers: a baseline `extract` p50 of 160 ms gives
`max(200, 165) = 200 ms`. A current p50 of 190 ms passes. A baseline `sha256`
p50 of 0.24 ms gives `max(0.3, 0.34) = 0.34 ms`; the floor wins.

Failure classes, each with a distinct message:

| Class | Condition | Message |
|---|---|---|
| `bootstrap` | No baseline, or runner/config differs | `::notice::benchmark bootstrap: no comparable baseline; main will record one` |
| `regression` | Any gated statistic over its limit | `::error::benchmark regression: 005-great-work extract.p50 80.1 ms vs baseline 53.0 ms (limit 74.2 ms)` |
| `rebaseline` | Suite, arm or event fingerprint differs | `::error::benchmark set changed: +probe.arm=record, -probe.arm=library; re-baseline or comment /benchmark accept <reason>` |
| `unstable` | Too few samples, more than two outliers, or MAD ratio over 0.5 | `::error::benchmark unstable: 004-averages plan.p95 MAD/p50 0.63` |
| `insufficient` | Measured samples below the minimum | `::error::only 14 plan samples ran; 20 required` |

`insufficient` mirrors the existing `MIN_TESTS` guard
(`.github/workflows/apple.yml:244-247`). `insufficient` and `unstable` are red.
A benchmark that did not measure has not passed. `bootstrap` is the exception:
there is nothing to compare, so the run passes and the summary says why.

On `push` to `main`, the same comparison runs in `record` mode. A `regression`
or `rebaseline` writes the summary and a warning, then exits 0, so the new
numbers become the baseline. `unstable` and `insufficient` exit 1 and leave the
old `latest.json` in place. The pull request is the enforcement point; `main`
records the new truth so the next pull request compares against it.

## Baseline storage

Use the existing Cloudflare R2 bucket `read-later-dev`, under a `benchmarks/`
prefix, with public read and write credentials only in a trusted workflow. The
bucket already exists, has a public URL, and the registry note records the
account and address (`tools/registry/README.md:34-51`). Reusing it avoids a
second credential and a second billable resource.

### Layout

```
benchmarks/v1/latest.json                       # rolling baseline, mutable
benchmarks/v1/records/main/<commit>.json        # immutable, one per main run
benchmarks/v1/records/accepted/<head-sha>.json  # immutable, one per acceptance
benchmarks/v1/schema.json                       # arm, metric and event definitions
```

`latest.json` uses the same pointer idea as the pack registry: the pointer is
short-cached and mutable; the versioned record never changes
(`tools/registry/README.md:13-18`). The pointer carries the baseline values, so
a pull request needs one GET.

Public read URL:

```
https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev/benchmarks/v1/latest.json
```

The `r2.dev` address is the development endpoint and is rate limited
(`tools/registry/README.md:50-51`). A few reads per pull request stay well
inside it. Attach a custom domain before this becomes a release gate for
outside users.

Write path:

```bash
wrangler r2 object put "read-later-dev/benchmarks/v1/latest.json" \
  --file latest-next.json --remote --cache-control 60
```

The S3 API is at `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` with region
`auto` (https://developers.cloudflare.com/r2/api/s3/api/), and `aws s3 cp`
works. Use wrangler for consistency with the registry publish path.

A record is immutable by convention. A rerun of the same SHA overwrites it,
which is useful when a run was flaky. For a strict guarantee, use `PutObject`
with `If-None-Match: *`; R2 evaluates it atomically
(https://developers.cloudflare.com/r2/api/s3/api/). Write `latest.json` last, so
a failed record write never moves the pointer.

### JSON shape

```json
{
  "schema": "rl-benchmark-2",
  "suite": "apple-telemetry",
  "commit": "abc1234",
  "head_sha": "abc1234",
  "recorded_at": "2026-11-27T18:04:11Z",
  "run": {"id": 123456, "attempt": 1, "url": "https://github.com/..."},
  "runner": {
    "label": "macos-15",
    "image": "20261118.0550.1",
    "os": "macOS 15.8.2",
    "arch": "arm64",
    "hw_model": "<sysctl -n hw.model>",
    "xcode": "16.4"
  },
  "config": {
    "stage_build": "release",
    "launch_build": "debug",
    "stage_samples": 20,
    "stage_warmups": 3,
    "interaction_samples": 20,
    "interaction_warmups": 3,
    "launch_samples": 20,
    "launch_warmups": 2,
    "corpus": ["027-hn", "095-sciencedaily", "004-averages", "005-great-work"],
    "interaction_text": "fixtures/bench/interaction.txt",
    "voice": "scripted"
  },
  "fingerprints": {
    "suite": "sha256:...",
    "events": "sha256:..."
  },
  "metrics": {
    "005-great-work": {
      "words": 11822, "blocks": 235, "bytes": 77912, "nodes": 1830,
      "extract": {"unit": "ms", "n": 20, "p50": 53.0, "p95": 61.2, "min": 50.1, "max": 70.4},
      "plan": {"unit": "ms", "n": 20, "p50": 21.0, "p95": 23.4, "min": 20.1, "max": 24.8},
      "invariant": {"unit": "ms", "n": 20, "p50": 2.4, "p95": 2.9, "min": 2.2, "max": 3.4},
      "sha256": {"unit": "ms", "n": 20, "p50": 0.24, "p95": 0.27, "min": 0.23, "max": 0.31},
      "save": {"unit": "ms", "n": 20, "p50": 9.2, "p95": 11.0, "min": 8.8, "max": 13.0},
      "seed": {"unit": "ms", "n": 20, "p50": 12.4, "p95": 13.5, "min": 12.0, "max": 14.1},
      "library": {"unit": "ms", "n": 20, "p50": 4.2, "p95": 5.0, "min": 4.0, "max": 5.7},
      "record": {"unit": "ms", "n": 20, "p50": 0.08, "p95": 0.11, "min": 0.07, "max": 0.15},
      "total": {"unit": "ms", "n": 20, "p50": 95.8, "p95": 108.0, "min": 92.0, "max": 120.0}
    }
  },
  "interactions": {
    "play.tapToState": {"unit": "ms", "n": 20, "p50": 8.0, "p95": 12.0, "min": 7.1, "max": 18.0},
    "pause.tapToState": {"unit": "ms", "n": 20, "p50": 6.0, "p95": 9.0, "min": 5.4, "max": 14.0},
    "tap.tapToState": {"unit": "ms", "n": 20, "p50": 12.0, "p95": 18.0, "min": 8.0, "max": 25.0},
    "scrub.commit": {"unit": "ms", "n": 20, "p50": 3.0, "p95": 5.0, "min": 2.6, "max": 8.0},
    "lookup.resolveHit": {"unit": "ms", "n": 20, "p50": 16.6, "p95": 33.0, "min": 5.3, "max": 33.0},
    "lookup.resolveMiss": {"unit": "ms", "n": 20, "p50": 12.6, "p95": 25.1, "min": 4.6, "max": 25.1},
    "lookup.present": {"unit": "ms", "n": 20, "p50": 39.0, "p95": 44.0, "min": 33.0, "max": 60.0},
    "lookup.resume": {"unit": "ms", "n": 20, "p50": 7.0, "p95": 10.0, "min": 6.2, "max": 15.0}
  },
  "baseline": {
    "005-great-work": {
      "extract": {"p50": 53.0, "p95": 61.2, "runs": 5, "mad_p50": 1.4}
    },
    "interactions": {
      "lookup.present": {"p50": 39.0, "p95": 44.0, "runs": 5, "mad_p50": 1.2}
    }
  },
  "history": [
    {"commit": "abc1234", "article": "005-great-work", "arm": "extract", "p50": 53.0, "p95": 61.2}
  ],
  "status": "pass"
}
```

`latest.json` carries `metrics`, `interactions`, `baseline` and up to 10
`history` entries per article/arm and per interaction. The tool appends the
current row to `history` in `record` mode,
so the next run can compute a rolling median without listing the bucket. The
immutable record carries the full detail. `records/accepted/<head-sha>.json`
carries `accepted_by`, `accepted_at`, `reason` and the result it accepted.

### Retention and cost

Add one lifecycle rule:

```bash
wrangler r2 bucket lifecycle add read-later-dev benchmark-records \
  benchmarks/v1/records/ --expire-days 180
```

Keep `latest.json` and `schema.json` outside the expiring prefix. A record is a
few kilobytes. Two writes per `main` push (record, then pointer) and one per
accepted pull request are far below R2's free tier of 10 GB-months, 1 million
Class A operations and 10 million Class B operations; egress is free
(https://developers.cloudflare.com/r2/pricing/). Cost is effectively zero.

### Comparison with the alternatives

| Option | Stable pointer | Fork PR read | Write security | Limits | Verdict |
|---|---|---|---|---|---|
| Actions cache | No; key is immutable | Yes, base-branch scope | Low-trust triggers read-only by default | 10 GB, 7-day eviction, PR scoped to merge ref | Reject for baseline |
| Workflow artefacts | No; tied to a run | Needs API by run id | Same as the run | Retention; no cheap pointer | Evidence only |
| GitHub Release asset | Yes | Yes, public | Needs `contents: write` | One release per commit is noisy | Possible, worse |
| `gh-pages` branch | Yes | Yes, public | Needs `contents: write` | Repo bloat; merge conflicts | Fallback |
| S3 | Yes | Yes | Separate account and keys | Egress billed | Reject |
| R2 | Yes | Yes, public URL | Bucket-scoped token, trusted workflow | Free tier, no egress | Chosen |

Cache details: contents cannot be changed under an existing key, the default
limit is 10 GB per repository, entries unused for 7 days are removed, and a pull
request's cache is scoped to `refs/pull/.../merge`
(https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
Artefacts are per-run outputs, not a shared store
(https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts).
`github-action-benchmark` stores history in a `gh-pages` branch or an external
JSON file and inherits the same limits
(https://github.com/benchmark-action/github-action-benchmark#minimal-setup).

## Accepting a worse result

The discretionary path is a pull request comment:

```
/benchmark accept <reason>
```

The comment suppresses `regression` and `rebaseline` failures for one head SHA.
A new commit changes the SHA and needs a new acceptance. The reason is recorded
with the accepted numbers.

Flow:

1. The pull request job runs, fails, and uploads `benchmark-result`.
2. A maintainer writes `/benchmark accept <reason>` on the pull request.
3. `benchmark-baseline.yml` runs on `issue_comment`. It checks that the
   commenter is an owner, member or collaborator, resolves the PR head SHA,
   finds the newest non-cancelled `benchmark` run for that SHA, downloads its
   artefact and validates it with `telemetrybench verify`.
4. The `accept-pr` job runs in the `benchmark-accept` environment with required
   reviewers. On approval it writes `records/accepted/<head-sha>.json`.
5. The maintainer re-runs the failed job. The tool sees the accepted record,
   reports the deltas, and exits 0 for that SHA.

A label is the obvious trigger, but it does not work here: `workflow_run` fires
when the benchmark run finishes, and adding a label afterwards fires no event.
A label-only design would need a privileged `pull_request_target` trigger on
`labeled`. The comment trigger is easier to reason about and carries the reason
in the same action. A bare command accepts every failed row for the SHA. Per-row
acceptance would need a follow-up command shape; do not ship one until the
first week of report-only data shows which rows need it.

Security model:

- A `pull_request` workflow gets no repository secrets on a fork, and
  `GITHUB_TOKEN` is read-only there
  (https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).
- The baseline is public, so a fork pull request reads it with `curl`.
- The write path lives only in `issue_comment` and `workflow_run` workflows.
  Both check out `main` and never execute pull request code. GitHub warns that
  checking out untrusted code in these triggers can take over a repository
  (https://docs.github.com/en/actions/reference/security/secure-use).
- The comment is not trusted. The job accepts only `OWNER`, `MEMBER` or
  `COLLABORATOR`; it resolves the PR and run from GitHub metadata, not from the
  comment text. The comment body is used only as the recorded reason.
- The artefact is untrusted input. `telemetrybench verify` checks the schema,
  key set, numeric ranges, `head_sha`, arm set and a maximum size. A forged
  artefact can only lower the gate for its own SHA, which a reviewer approved.
- `pull_request_target` is not used.
- The R2 token is scoped to `read-later-dev` with Object Read and Write
  (https://developers.cloudflare.com/r2/api/tokens/). It lives in
  `benchmark-accept` (required reviewers) and `benchmark-write` (branch `main`
  only). Environment branch rules and reviewers are configured in repository
  settings
  (https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

`workflow_dispatch` with an `accept_run_id` input is the fallback when a run has
expired and its artefact is gone. Updating the baseline on `main` only is not
used: it leaves the pull request red and needs a merge override.

## Benchmark-set drift

Two fingerprints, both stored in every record:

- `suite`: SHA-256 of the arm definitions, derivation code version, tool
  version, corpus file hashes, build configuration and the telemetry event
  allowlist.
- `events`: SHA-256 of the sorted set of `event` names and their field-key sets
  observed in the run, minus a documented environment allowlist.

Environment allowlist, with reasons: `app.hide`, `app.return`,
`audio.interruption`, `marker.request`, `frame.second`, `speech.heartbeat`,
`speech.word`. These depend on window focus, audio route or debug probes.
List them in `schema.json` so the allowlist is reviewable.

`frame.tap_window` and `frame.scrub_window` are optional. A hosted runner with no
display link emits neither. When they are absent, the record sets
`frames=missing`, the table says so, and the event fingerprint ignores both
names. A transition from present to missing is a warning, not a rebaseline:
it changes the environment, not the benchmark set.

On mismatch, the run fails with `rebaseline` and prints the added and removed
names. It does not update the baseline. Two ways forward:

1. Comment `/benchmark accept <reason>` for this SHA, merge, and let the `main`
   run write a new baseline with the new fingerprint.
2. Change the metric set deliberately, bump `schema`, and seed a new baseline
   from `main` with `workflow_dispatch`.

Prior art is thin. `github-action-benchmark` matches results by benchmark name
and tool; a renamed benchmark starts a new series
(https://github.com/benchmark-action/github-action-benchmark#action-inputs).
Bencher keys a threshold by branch, testbed and measure, so a new benchmark
inside an existing measure is judged against that measure immediately; it does
not detect that the set changed (https://bencher.dev/docs/explanation/thresholds/).
CodSpeed reports a benchmark drop and lets an admin acknowledge it
(https://codspeed.io/docs/features/performance-checks). The event-set
fingerprint is repo-specific because the benchmark source is the app's own
telemetry.

## Build reuse and CI time

This answers the separate question: would factoring the build into a standalone
job, with caching shared with other jobs, speed up CI?

### What the measurements say

Jobs already run in parallel. The workflow wall clock is the slowest job plus
runner queue delay, not the sum. On the two runs above, `release-guard` set the
critical path at 5:18 and 5:27. The Debug macOS build is 1:40 to 2:21.
`e2e-core` spends 1:35 building for testing and 0:23 running the one macOS
journey. Caching compile output cannot make the slowest job shorter by more
than the compile part of that job.

### Factoring out a build job

A standalone build job helps only when two or more downstream jobs need the
same build output and would otherwise each produce it. It does not help when
consumers need different configurations:

| Consumer | Build |
|---|---|
| `unit`, `invariant` | SwiftPM test builds, Debug, per package |
| `build-macos` | Debug macOS app |
| `build-ios` | Debug iOS Simulator app |
| `e2e-core` | Debug macOS build-for-testing |
| `release-guard` | Release iOS Simulator app |
| stage benchmark | Release SwiftPM test bundle |
| interaction benchmark | Debug macOS app |
| launch benchmark | Debug macOS app |

Only `build-macos`, the interaction benchmark and the launch benchmark share an
identical output. Today they run in parallel. The benchmark job spends about 2:21 building the app and
about 5:00 on the stage, interaction and launch work, so it takes about 7:21 on
its own. Making it `needs: build-macos` replaces that overlapping build with:

```
build-macos 2:21 + upload ~0:20 + download ~0:20 + benchmark work 5:00
```

That is about 8:01 before the benchmark finishes, against about 7:21 for a
benchmark that builds its own app. It saves about 2:21 of duplicate runner time
and costs about 0:40 of wall clock. The trade is cost, not speed.

The same arithmetic applies to `build-for-testing` and
`test-without-building`. Apple documents the split: `build-for-testing`
produces the test bundle and `.xctestrun`; `test-without-building` consumes it
(https://developer.apple.com/library/archive/technotes/tn2339/_index.html).
It pays when several destinations or suites run the same built tests. Today
`e2e-core` has one macOS destination, so splitting adds a job and an artifact
round trip for one consumer.

Verdict: do not add a standalone build job in v1. If `e2e-core` grows an iOS
matrix, build once per platform and fan out `test-without-building` jobs. If
the interaction/launch benchmarks and `build-macos` both become required and the
duplicate build is the measured bottleneck, share that one `.app` artifact then.

### Caching

Caching is a smaller, safer win than restructuring jobs. Cache these:

| Path | Key | Expected effect |
|---|---|---|
| `~/.swiftpm`, `~/Library/Caches/org.swift.swiftpm` | OS, Swift version, every `Package.resolved` | Avoid dependency fetch and resolution |
| `packages/*/.build` | OS, Swift version, `Package.resolved`, package name | Reuse dependency modules across PRs |
| `tools/*/target`, `~/.cargo/registry` | OS, `Cargo.lock` | Keep the Rust tool build small |
| `~/Library/Developer/Xcode/DerivedData` | OS, Xcode version, `project.yml`, `Package.resolved` | Reuse unchanged modules |

Do not cache `apps/apple/build/bench` or the measured binary. A stale binary is
exactly the error the benchmark exists to catch. Build the measured code from
source every run.

GitHub cache limits and scope matter. An existing key cannot be overwritten;
the default limit is 10 GB per repo; entries unused for 7 days are evicted; a
PR can restore caches from its base branch but writes its own cache to
`refs/pull/.../merge`, which no other PR can read
(https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
Keep the PR cache read-only with `cache-mode: read` and let `push` to `main`
maintain it; the same page documents the cache-poisoning risk from low-trust
triggers.

DerivedData is large and not fully relocatable. Its cache can exceed the 10 GB
repository limit when several configurations are saved. Start with SwiftPM and
Cargo caches, measure the hit rate, and add DerivedData only if the saved time
is visible in the job summary. A cache miss must never fail the job.

What this does not fix: `release-guard` spends about five minutes compiling a
Release app to run a `strings` check. That is the current critical path. A cache
may trim it, but the bigger win is deciding whether the guard needs a full
Release build or could inspect a smaller target. That is outside this proposal.

## Proposed workflow

The YAML below is the single-job reference. For the three-minute path, split
the stage step into `benchmark-stages` and the app steps into `benchmark-app`;
the timing section gives both shapes. The suites share one baseline contract and
one comparison tool.

### `.github/workflows/benchmark.yml`

```yaml
name: benchmark

on:
  pull_request:
    paths:
      - "apps/apple/**"
      - "packages/**"
      - "fixtures/**"
      - "tools/telemetrybench/**"
      - ".github/workflows/benchmark.yml"
  push:
    branches: [main]
    paths:
      - "apps/apple/**"
      - "packages/**"
      - "fixtures/**"
      - "tools/telemetrybench/**"
      - ".github/workflows/benchmark.yml"
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  benchmark:
    name: benchmark (macos)
    runs-on: macos-15
    timeout-minutes: 15
    env:
      BASELINE: https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev/benchmarks/v1/latest.json
      # Record only on main. A dispatch from a feature branch must gate.
      MODE: ${{ github.ref == 'refs/heads/main' && 'record' || 'gate' }}
      CORPUS: 027-hn,095-sciencedaily,004-averages,005-great-work
    steps:
      - uses: actions/checkout@v5
      - name: stub Device.xcconfig for xcodegen
        working-directory: apps/apple
        run: |
          if [ ! -f Config/Device.xcconfig ]; then
            cp Config/Device.xcconfig.example Config/Device.xcconfig
          fi
      - name: install xcodegen
        run: brew install xcodegen
      - name: generate project
        working-directory: apps/apple
        run: xcodegen generate
      - name: build the stage probe in Release
        run: |
          rm -rf artifacts/bench/stages
          mkdir -p artifacts/bench/stages
          # The probe skips without the output variable. --filter keeps the
          # full unit suite out of this job.
          ENTRY_PROBE_OUT="$PWD/artifacts/bench/stages" \
          ENTRY_PROBE_FIXTURES="$PWD/fixtures/pages" \
          ENTRY_PROBE_ONLY="$CORPUS" \
          swift test -c release -Xswiftc -enable-testing \
            --package-path packages/ReadLaterUI \
            --filter EntryStageBenchmarkTests
      - name: build the Debug macOS app
        working-directory: apps/apple
        run: |
          xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
            -destination 'platform=macOS' -configuration Debug \
            -derivedDataPath build/bench build \
            CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
      - name: build the benchmark tool
        run: cargo build --release --manifest-path tools/telemetrybench/Cargo.toml
      - name: measure launch
        run: |
          B=tools/telemetrybench/target/release/telemetrybench
          APP="apps/apple/build/bench/Build/Products/Debug/ReadLater.app"
          $B run --app "$APP" --mode launch \
            --samples 20 --warmups 2 --telemetry artifacts/bench/launch --timeout 240
      - name: measure interactions
        run: |
          B=tools/telemetrybench/target/release/telemetrybench
          APP="apps/apple/build/bench/Build/Products/Debug/ReadLater.app"
          $B run --app "$APP" --mode interactions \
            --text fixtures/bench/interaction.txt \
            --samples 20 --warmups 3 --telemetry artifacts/bench/interactions --timeout 240
      - name: result
        run: |
          B=tools/telemetrybench/target/release/telemetrybench
          $B result --probe artifacts/bench/stages/telemetry.jsonl \
            --launch artifacts/bench/launch \
            --interactions artifacts/bench/interactions \
            --runner-image "${ImageVersion:-unknown}" \
            --head-sha "${{ github.event.pull_request.head.sha || github.sha }}" \
            --json > artifacts/bench/current.json
      - name: fetch baseline
        run: |
          if ! curl -fsS "$BASELINE" -o artifacts/bench/latest.json; then
            echo "no baseline yet; this run is bootstrap"
            rm -f artifacts/bench/latest.json
          fi
      - name: fetch an accepted record for this commit
        if: github.event_name == 'pull_request'
        run: |
          HEAD="${{ github.event.pull_request.head.sha }}"
          curl -fsS \
            "https://pub-2965e1ed8e124382ae9d91ea1e8637ce.r2.dev/benchmarks/v1/records/accepted/$HEAD.json" \
            -o artifacts/bench/accepted.json || true
      - name: compare
        id: compare
        run: |
          B=tools/telemetrybench/target/release/telemetrybench
          $B compare \
            --current artifacts/bench/current.json \
            --baseline artifacts/bench/latest.json \
            --accepted artifacts/bench/accepted.json \
            --mode "$MODE" \
            --markdown artifacts/bench/table.md \
            --latest-out artifacts/bench/latest-next.json
      - name: summary
        if: always()
        run: |
          {
            echo "### benchmark · macos-15"
            echo
            cat artifacts/bench/table.md 2>/dev/null || echo "no benchmark table"
          } >> "$GITHUB_STEP_SUMMARY"
      - name: upload result
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-result
          path: |
            artifacts/bench/current.json
            artifacts/bench/latest-next.json
            artifacts/bench/table.md
            artifacts/bench/launch
            artifacts/bench/stages
            artifacts/bench/interactions
          if-no-files-found: ignore
          retention-days: 14
```

The `swift test` invocation also builds the package's other test targets unless
`--filter` prunes them. If the build still pays for the full suite, move the
probe to its own test target in `Package.swift`; do not add a second copy of
the production code.

`compare` writes the Markdown table even when it fails, so the summary step still
has content. A missing `accepted.json` is a normal state, not an error. The table
shape:

```markdown
| Scope | Metric | Stat | Baseline | Current | Delta | Limit | Status |
|---|---|---:|---:|---:|---:|---:|---:|---|
| 005-great-work | extract | p50 | 53.0 ms | 51.8 ms | -2.3% | 74.2 ms | pass |
| 005-great-work | plan | p95 | 23.4 ms | 23.8 ms | +1.7% | 30.4 ms | pass |
| 005-great-work | invariant | p50 | 2.4 ms | 2.5 ms | +4.2% | 3.0 ms | pass |
| 004-averages | sha256 | p50 | 0.24 ms | 0.31 ms | +29.2% | 0.34 ms | warn |
| 004-averages | save | p95 | 5.1 ms | 7.8 ms | +52.9% | 7.7 ms | fail |
| interactions | lookup.present | p50 | 39.0 ms | 55.0 ms | +41.0% | 48.8 ms | fail |
```

"warn" is a display state above 10 percent but below the limit. Only "fail" sets
a non-zero exit.

Fork behaviour: the baseline GET is public, so a fork pull request measures and
compares normally. It can read an accepted record, but none exists until a
maintainer creates one. It cannot write anything.

Paths: the workflow repeats the relevant filters from `apple.yml`, plus
`tools/telemetrybench/**`. Docs-only pull requests do not run it.

Build reuse: the workflow does not download `build-macos`'s app. The measured
arithmetic above says that would add wall clock. If it is later shown to save
time, upload the `.app` with `ditto -c -k` and download it in this job; do not
upload `DerivedData`.

Caching: v1 uses only the SwiftPM and Cargo caches. The measured app build is
2:21 and the Release probe build is the larger cost; try the dependency caches
first and report the delta in the job summary. Do not cache measured binaries.

### `.github/workflows/benchmark-baseline.yml`

```yaml
name: benchmark-baseline

on:
  workflow_run:
    workflows: ["benchmark"]
    types: [completed]
  issue_comment:
    types: [created]

permissions:
  actions: read
  contents: read
  pull-requests: read

jobs:
  record-main:
    if: >-
      (github.event.workflow_run.event == 'push' ||
       github.event.workflow_run.event == 'workflow_dispatch') &&
      github.event.workflow_run.head_branch == 'main' &&
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    environment: benchmark-write
    steps:
      - uses: actions/checkout@v5
        with:
          ref: main
      - uses: actions/download-artifact@v4
        with:
          name: benchmark-result
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          path: result
      - name: validate
        run: |
          cargo run --release --manifest-path tools/telemetrybench/Cargo.toml -- \
            verify --result result/current.json --latest result/latest-next.json \
            --head-sha "${{ github.event.workflow_run.head_sha }}"
      - name: install wrangler
        run: npm install -g wrangler
      - name: write record and latest
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.R2_WRITE_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: c77a4d6bb743471e72f2e9805aaeac5d
        run: |
          SHA="${{ github.event.workflow_run.head_sha }}"
          wrangler r2 object put "read-later-dev/benchmarks/v1/records/main/$SHA.json" \
            --file result/current.json --remote
          wrangler r2 object put "read-later-dev/benchmarks/v1/latest.json" \
            --file result/latest-next.json --remote --cache-control 60

  accept-pr:
    if: >-
      github.event_name == 'issue_comment' &&
      github.event.issue.pull_request &&
      startsWith(github.event.comment.body, '/benchmark accept') &&
      contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)
    runs-on: ubuntu-latest
    environment: benchmark-accept
    permissions:
      actions: read
      contents: read
      pull-requests: read
    steps:
      - uses: actions/checkout@v5
        with:
          ref: main
      - name: the commenter may accept
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ASSOC: ${{ github.event.comment.author_association }}
          BODY: ${{ github.event.comment.body }}
          PR: ${{ github.event.issue.number }}
          ACTOR: ${{ github.event.comment.user.login }}
        run: |
          case "$ASSOC" in
            OWNER|MEMBER|COLLABORATOR) ;;
            *) echo "::error::$ACTOR does not have write access"; exit 1 ;;
          esac
          HEAD=$(gh pr view "$PR" --json headRefOid --jq .headRefOid)
          REASON=$(printf '%s' "$BODY" | sed 's|^/benchmark accept[[:space:]]*||')
          [ -n "$REASON" ] || { echo "::error::a reason is required"; exit 1; }
          printf '%s' "$REASON" > reason.txt
          {
            echo "HEAD=$HEAD"
            echo "ACTOR=$ACTOR"
          } >> "$GITHUB_ENV"
      - name: find the newest benchmark run for this head
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR: ${{ github.event.issue.number }}
        run: |
          RUN=$(gh api \
            "repos/$GITHUB_REPOSITORY/actions/workflows/benchmark.yml/runs?event=pull_request&per_page=50" \
            --jq --argjson pr "$PR" \
            '[.workflow_runs[] | select(.conclusion != "cancelled") | select((.pull_requests // []) | any(.number == $pr))][0].id')
          if [ -z "$RUN" ]; then
            BRANCH=$(gh pr view "$PR" --json headRefName --jq .headRefName)
            RUN=$(gh run list --workflow benchmark.yml --event pull_request \
              --branch "$BRANCH" --limit 20 --json databaseId,conclusion \
              --jq '[.[] | select(.conclusion != "cancelled")][0].databaseId')
          fi
          [ -n "$RUN" ] || { echo "::error::no benchmark run for this pull request"; exit 1; }
          echo "RUN_ID=$RUN" >> "$GITHUB_ENV"
      - name: download the result
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh run download "$RUN_ID" --name benchmark-result --dir result
      - name: validate
        run: |
          cargo run --release --manifest-path tools/telemetrybench/Cargo.toml -- \
            verify --result result/current.json --allow-accept --head-sha "$HEAD"
      - name: install wrangler
        run: npm install -g wrangler
      - name: record acceptance
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.R2_WRITE_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: c77a4d6bb743471e72f2e9805aaeac5d
        run: |
          jq --rawfile reason reason.txt --arg user "$ACTOR" --arg run "$RUN_ID" \
            '. + {accepted_at: (now | todate), accepted_by: $user, reason: $reason, accepted_run: $run}' \
            result/current.json > result/accepted.json
          wrangler r2 object put "read-later-dev/benchmarks/v1/records/accepted/$HEAD.json" \
            --file result/accepted.json --remote
```

Both jobs check out `main`, never the pull request. `accept-pr` is the only job
that writes a pull-request-derived value. It runs in a protected environment
with required reviewers, on `ubuntu-latest`, and executes only code from `main`.
`permissions` is read-only apart from what `download-artifact` needs.

`accept-pr` accepts a failed benchmark on purpose. The pull request run is red
when it needs acceptance. `cancelled` runs are excluded because a superseded run
has no usable artefact. `benchmark.yml` uploads `benchmark-result` with
`if: always()`, so the failing run still has the numbers. `verify --allow-accept`
accepts only a result whose status is `regression` or `rebaseline`; a malformed
or passing record is rejected. Run ids are immutable, so the workflow downloads
the exact artefact the failing run produced; it does not re-run untrusted code.

### Tool CLI

`tools/telemetrybench`, a Rust crate under `tools/`, as the repo requires
(`AGENTS.md:32-33`). Commit its `Cargo.lock`, as `tools/tokens` does. Commands:

```
telemetrybench run    --app <ReadLater.app> --mode launch|interactions [--text <file>] --samples N --warmups N --telemetry <dir> --timeout S
telemetrybench result --probe <telemetry.jsonl> --launch <dir> --interactions <dir> --runner-image <id> --head-sha <sha> --json
telemetrybench compare --current <json> --baseline <json> --accepted <json> --mode gate|record --markdown <file> --latest-out <file>
telemetrybench verify --result <json> --latest <json> --head-sha <sha> | --allow-accept
```

`run` owns process launch, timeout and termination. Do not put that logic in
YAML. It launches with `open -n -W` so LaunchServices registers the bundle, the
same step the local instructions call out (`apps/apple/README.md:44-47`). It
clears the telemetry directory and passes `--debug.telemetryDir`. In `launch`
mode it also passes `--debug.benchmarkExit=firstFrame`. In `interactions` mode
it passes `--debug.preset=e2e`, encodes `--text` as
`--debug.seedTextB64`, passes `--debug.interactions=<samples + warmups>`, and
waits for the app to exit after the last iteration. It kills the app if it
overruns the timeout.

`result` parses the stage, interaction and launch telemetry, computes the
statistics once, and fails when sessions disagree on `launch.build` commit,
configuration, model or OS. It computes `total` from the stages rather than
trusting a probe field, and it pairs the shipped interaction events with the
driver's `benchmark.interaction` rows. `compare` holds the threshold table and
fingerprints; it writes the Markdown table before exiting. In `record` mode it
also writes `--latest-out`: the merged record with this run appended to
`history` and the rolling baseline recomputed. `verify` is the only code that
accepts an artefact from a privileged workflow.

`verify` and `compare` run on `ubuntu-latest` in the baseline workflow, so gate
the process-launch code behind `#[cfg(target_os = "macos")]` and keep the
parsing and comparison modules portable.

### Debug hooks needed

Only three flags. All are Debug-only; `release-guard` already enforces that the
`--debug.` prefix is absent from Release (`.github/workflows/apple.yml:440-452`).

- `--debug.telemetryDir=<path>`: in `ReadLaterApp.init`, call
  `telemetry.configure(directory:)` with the given path instead of
  `defaultDirectory()`. The call must happen where `configure()` happens today
  (`apps/apple/Sources/App/ReadLaterApp.swift:31`); setting it earlier would be
  overwritten.
- `--debug.benchmarkExit=firstFrame`: flush and exit after
  `launch.first_frame`. Without it the tool must kill the process, and a
  buffered line can be lost.
- `--debug.interactions=<n>`: after the seeded article reaches `reader.entered`,
  run `n` scripted interaction iterations, then flush and exit 0. The driver is
  a DEBUG-only `InteractionBenchmark` hosted the same way as `SnapshotHarness`.
  It opens the saved place if the app is still on the entry surface, then calls
  `ReaderSession.togglePlay`, `beginScrubbing`, `scrub(toFraction:)`,
  `finishScrubbing` and `LookupController.tap`/`closeCard`. It records one
  `benchmark.interaction` event per intent with `kind`, `iteration`, `ms` and
  `outcome`, and waits for the shipped events before the next intent. It does
  not synthesize touches.

The stage suite needs no app flag. It runs in the test process and writes
through `TelemetryLog` directly, as `EntryScalingProbeTests` does.

No tap-repeat hook and no `--debug.benchmarkTextB64` are needed. The driver
calls `ReaderSession` and `LookupController` directly; the e2e suite continues
to own the real UI gesture path.

### Timing budget

The 7:41 spike was five stage processes and five interaction launches. That is
not the production shape. One repetition each is enough: the stage probe already
takes 20 samples per arm, and the interaction driver already runs 20 measured
iterations.

Measured from run `46107176139`:

| Phase | Measured | Basis |
|---|---|---|
| Stage first run | 2:49 | 146 s build + 16 s test |
| Stage later run | 0:15 | 2 s build + 13 s test |
| Debug macOS build | 1:48 | full Debug app |
| Interaction launch | 0:20 | 23 iterations, one app |
| Launch sample | 2–3 s | 0:25–0:35 for 10 measured + 2 warmups |

The three-minute path is two jobs in parallel:

| Job | Work | Cold estimate | Cached estimate |
|---|---|---:|---:|
| `benchmark-stages` | checkout, Release build, one probe run | 2:50 | 2:00–2:30 |
| `benchmark-app` | Debug build, one interaction launch, 12 launches | 2:45 | 2:10–2:30 |
| **Wall clock** | slower job | **~2:50** | **~2:30** |

This uses two macOS runners. The stage job has no xcodegen or app build. The
app job reuses one Debug build for both interaction and launch.

If 20 launch samples are mandatory, split the launch suite into its own job:

| Job | Work | Cold estimate |
|---|---|---:|
| `benchmark-stages` | Release build + one probe run | 2:50 |
| `benchmark-interactions` | Debug build + one interaction launch | 2:10 |
| `benchmark-launch` | Debug build + 22 launches | 2:45 |

All three stay under three minutes of job time, at the cost of three macOS
runners. The wall clock is still the slowest job, about 2:50.

Caching SwiftPM and DerivedData is what absorbs the cold-build margin. Without
a cache, the stage job is near the limit; with a cache hit it drops to about two
minutes. A cache miss must not fail the job.

Hosted-runner queue delay is outside these numbers. The spike was queued behind
the macOS pool once; that adds wall-clock time before the job starts. A
three-minute job can still take longer to appear.

The single-job layout below is the reference implementation. Split it at the
stage step for the three-minute path; do not run the stage probe and the app
suites in one job if the budget matters.

## Rollout plan

1. **Spike the stage probe and the interaction driver.** Done on 2026-11-28:
   branch `spike/benchmark-probes`, run `46107176139`. The pass conditions are
   in "Spike results" above. Keep the branch as evidence; do not merge it as
   the final tool. The remaining work is the `record` arm and the comparator.
2. **Tool and corpus.** Land `tools/telemetrybench`, the four-fixture stage
   corpus, the plain-text interaction fixture, and the three Debug flags. Add
   unit tests for percentile choice, the floor, the fingerprint, `total`
   derivation and the verifier. One squash commit.
3. **Bootstrap baseline.** Run `benchmark.yml` on `main` five times with
   `workflow_dispatch`. Each run is in record mode and `record-main` writes the
   rolling baseline. Use the observed spread to set the floors. Do not use the
   numbers in this document as measurements.
4. **Report-only gate.** Enable the workflow on pull requests with
   `continue-on-error` on the compare step for one week. Count false positives
   per arm. Adjust floors and sample count from data.
5. **Enforce.** Remove `continue-on-error`, add `benchmark (macos)` to required
   checks, and land the accept workflow. Create `benchmark-write` (branch
   `main`, no reviewers) and `benchmark-accept` (required reviewers), and put
   the R2 write token in both.
6. **Two jobs, then caches.** Split `benchmark-stages` from `benchmark-app`
   before enforcing the three-minute budget. Add SwiftPM and DerivedData caches
   and measure the hit rate. Do not add a third job unless 20 launch samples are
   mandatory.
7. **Nightly scaling sweep.** Keep the full `EntryScalingProbeTests` sweep and
   `tools/entryscale` fit on a nightly job, not per PR. That job answers the
   `B · L²` question from #40; the per-PR gate answers "did this stage get
   slower on these four articles".
8. **Re-measure after a runner image change.** Expect one red run per image
   roll while the baseline is rebuilt.

## Alternatives considered

**Reuse `tools/entryscale` as the gate.** It fits scaling exponents over a large
corpus: synthetic sweeps, 100 pins and fixtures. That is the right tool for the
nightly scaling question, but it is too slow and too fit-oriented for a per-PR
gate. `telemetrybench` reads the same `probe.sample` events from a small fixed
corpus and compares per-arm percentiles.

**`benchmark-action/github-action-benchmark`.** It supports
`customSmallerIsBetter` JSON, `alert-threshold`, `fail-on-alert`,
`fail-threshold`, `comment-on-alert`, `auto-push` and
`external-data-json-path`
(https://github.com/benchmark-action/github-action-benchmark#action-inputs).
Its default threshold is 200 percent, which would miss every regression this
repo cares about. Its README says to run it on branches, not pull requests,
because a PR must not push to `gh-pages`. Use it later as a chart layer if a
dashboard is wanted; it is not the gate.

**CodSpeed.** The CLI can benchmark any executable, including Swift, and its
performance check fails a PR against the main baseline with an admin
acknowledgement (https://codspeed.io/docs/benchmarks/cli-commands,
https://codspeed.io/docs/features/performance-checks). Its walltime instrument
runs on CodSpeed's bare-metal Linux runners, so it cannot run a macOS app or
the SwiftUI package. Rejected for this target.

**Bencher.** Good threshold model: percentage, z-score, t-test, IQR, static,
with minimum and maximum sample sizes and `--error-on-alert`
(https://bencher.dev/docs/explanation/thresholds/). It needs a runner that can
execute the macOS probe and a JSON adapter, and it adds a service or a
self-hosted deployment. A reasonable second choice if cross-project dashboards
matter more than a zero-service design.

**Criterion.rs, `critcmp`, `hyperfine`.** Criterion is for Rust functions, not a
Swift test process, and `critcmp` reads Criterion's internal baseline format
(https://github.com/burntsushi/critcmp). `hyperfine` can time process launches
with warmups, outlier detection and JSON export
(https://github.com/sharkdp/hyperfine), and is a useful cross-check for the
launch metric. Neither can read the app's checkpoint telemetry or run the stage
probe, so neither can be the gate.

**XCUITest metrics.** Reuse the existing e2e runner and read test durations.
Rejected: `xcodebuild` startup dominates, tap synthesis adds noise, and the
measurement is a test duration rather than an in-app stage.

**Self-hosted Mac mini.** Lowest variance and no image roll. Rejected for v1:
GitHub recommends against self-hosted runners for public repositories because
untrusted pull request code can compromise the host
(https://docs.github.com/en/actions/reference/security/secure-use). Revisit only
if hosted-runner noise makes the gate unusable.

**Run the benchmark in `e2e-core` after the journeys.** Saves a checkout and a
runner setup, but couples a performance failure to a functional suite, inherits
the UI-test automation path, and makes the timing budget depend on the journey
count. Rejected.

## Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Hosted-runner CPU jitter | False red or missed regression | 20 samples, p50 and p95, rolling baseline, per-arm floors |
| Runner image roll | Every metric shifts | Image version in the baseline key; mismatch starts a new baseline |
| Probe drifts from shipped code | Gate measures a copy | `read` check, code review, keep the probe in the test target and call shipped types |
| Release probe build is slow | Job loses to `release-guard` | Measure; split stage, interaction and launch jobs; cache SwiftPM deps |
| Debug launch not Release-representative | Launch number is not a device number | Compare Debug to Debug; state it in the summary |
| No voice metric in CI | Speech regressions are missed | Report `plan.ready` to `speech.first_word`; keep the device lab for speech |
| Synthetic intents bypass gestures | Gesture recognition cost is missed | e2e owns the real tap path; device lab owns audio; driver calls shipped intents |
| Hosted runner has no display link | `frame.*` rows are `missing` | Spike confirmed frames on `macos-15`; still record `frame=missing` and gate handler rows |
| Audio interaction latency not in CI | Play, pause and scrub feel slower without a stage change | `LatencyDeviceTests` and `devicebench` own sound and silence |
| Fixture corpus misses a page shape | A regression passes | Four sizes and content types; nightly full sweep |
| Acceptance is too easy | Baseline drifts down | Write access, environment approval, one SHA per acceptance, reason recorded |
| Artefact forgery | A false baseline | Schema, SHA match, size cap, review; worst case affects one SHA |
| `main` baseline overwritten by a bad run | Future PRs pass against noise | Write only when sample count and stability pass |
| R2 `r2.dev` rate limit | Baseline GET fails | Treat as bootstrap in report-only; custom domain before enforcement |
| Cache poisoning | Malicious build output | PR caches read-only; only trusted `push` writes the main cache |
| Cache miss | Job slower, never wrong | Cache is an optimisation; measured binary is always rebuilt |

## Open questions

Resolved by the 2026-11-28 spike:

- A Debug `.app` launched with `open -n -W` gets a window and emits
  `launch.entry_ready`, `launch.first_frame` and `reader.entered` on `macos-15`.
- `swift test -c release -Xswiftc -enable-testing` for `ReadLaterUI` takes
  about 46 seconds per run after the first build; five runs took 3:52.
- `frame.tap_window` and `frame.scrub_window` emit on the hosted runner. A scrub
  must hold for at least two frames.
- `out-argues` resolves through the demo pack in every run; `lookup.hit`
  carried source `English–Chinese pack`, not the system dictionary.

Still open:

- Does `--filter EntryStageBenchmarkTests` still build the other test targets?
  If yes, move the probe to its own target.
- Is `ImageVersion` exported to the job environment? Verify with
  `env | grep -i image`; fall back to parsing the job log.
- Is the four-fixture corpus enough to catch the regression classes from #40
  and #41? The nightly full sweep is the backstop.
- Which stage p95 is stable enough to gate? The spike says not yet; collect five
  clean `main` baselines first.
- Should the stage, interaction and launch suites share one job or split?
  Decide from the first five full-run durations.

## Sources

Repo:

- `.github/workflows/apple.yml`
- `docs/telemetry-and-sync-oplog.md`
- `packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryLog.swift`
- `packages/ReadLaterCore/Sources/ReadLaterCore/TelemetryHub.swift`
- `packages/ReadLaterStore/Sources/ReadLaterStore/Store.swift`
- `packages/ReadLaterUI/Sources/ReadLaterUI/LaunchOptions.swift`
- `packages/ReadLaterUI/Sources/ReadLaterUI/ArticleIngress.swift`
- `apps/apple/Sources/App/DebugLaunch.swift`
- `apps/apple/Sources/App/DebugFrameMonitor.swift`
- `apps/apple/Sources/App/ReadLaterApp.swift`
- `apps/apple/Sources/App/ReaderSession.swift`
- `apps/apple/Sources/App/LookupController.swift`
- `apps/apple/Sources/App/ScriptedSpeechController.swift`
- `apps/apple/E2ETests/LatencyDeviceTests.swift`
- `packages/ReadLaterCore/Sources/ReadLaterCore/FrameCounter.swift`
- `packages/ReadLaterUI/Sources/ReadLaterUI/LookupCard.swift`
- `packages/ReadLaterUI/Sources/ReadLaterUI/MissCard.swift`
- `tools/devicebench/README.md`
- `apps/apple/project.yml`
- `apps/apple/README.md`
- `fixtures/pages/*.blockplan.json`
- `tools/packbench/README.md`
- `tools/registry/README.md`
- `AGENTS.md`
- `read-later-research/spec/device-test-plan.md`
- `read-later-research/spec/device-verification-latency.md`
- `read-later-research/evidence/2026-11-26-entry-scaling-r2/results.md`
- `read-later-research/evidence/2026-11-13-pack-bench/results.md`
- `jacklaw1410/read-later#40`, `#41`
- Branch `spike/benchmark-probes` at `09715e6`: `EntryStageBenchmarkTests`,
  `InteractionBenchmark`, `.github/workflows/spike-benchmark.yml`
- Spike run `46107176139`
- Branch `probe/entry-scaling-r2`: `EntryScalingProbeTests`, `tools/entryscale`

External:

- GitHub Actions runner hardware:
  https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- macOS 15 arm64 runner image:
  https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md
- Actions limits:
  https://docs.github.com/en/actions/reference/limits
- Dependency caching, key immutability, eviction, scopes:
  https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching
- Workflow artefacts:
  https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts
- Sharing data between jobs:
  https://docs.github.com/en/actions/tutorials/store-and-share-data
- Fork pull requests do not receive secrets:
  https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request
- `issue_comment` event:
  https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#issue_comment
- Secure use, `pull_request_target` and self-hosted warnings:
  https://docs.github.com/en/actions/reference/security/secure-use
- Environments, required reviewers, deployment branches:
  https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- Apple TN2339, build-for-testing and test-without-building:
  https://developer.apple.com/library/archive/technotes/tn2339/_index.html
- `github-action-benchmark` inputs and caveats:
  https://github.com/benchmark-action/github-action-benchmark
- CodSpeed CLI commands and walltime runners:
  https://codspeed.io/docs/benchmarks/cli-commands
- CodSpeed performance checks and acknowledgement:
  https://codspeed.io/docs/features/performance-checks
- Bencher thresholds:
  https://bencher.dev/docs/explanation/thresholds/
- Bencher noise probe:
  https://bencher.dev/docs/reference/bencher-noise/
- Criterion output, warmup, noise threshold, outliers:
  https://bheisler.github.io/criterion.rs/book/user_guide/command_line_output.html
- `critcmp`:
  https://github.com/burntsushi/critcmp
- `hyperfine` warmup, runs, outlier detection, JSON export:
  https://github.com/sharkdp/hyperfine
- Cloudflare R2 pricing and free tier:
  https://developers.cloudflare.com/r2/pricing/
- Cloudflare R2 S3 compatibility and endpoint:
  https://developers.cloudflare.com/r2/api/s3/api/
- Cloudflare R2 API tokens and bucket scoping:
  https://developers.cloudflare.com/r2/api/tokens/
- Wrangler R2 object and lifecycle commands:
  https://developers.cloudflare.com/workers/wrangler/commands/r2/
