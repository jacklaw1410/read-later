# entryscale

Fits the entry wait probe. The probe is `EntryScalingProbeTests` in
`packages/ReadLaterUI`. It times the work between a fetched page and a saved
document with reader state, and writes every result to the oplog. This crate
reads the oplog and prints the fits.

Question it answers: does the entry wait grow with the square of the block
count, or with the square of words per block? Does the total grow linearly
with words on real pages?

## Run on macOS

Use Release, with testability enabled so `@testable` reaches the internal hash
function. Set the output directory and, optionally, the page directories.

```
cd packages/ReadLaterUI
ENTRY_PROBE_OUT=/tmp/entryprobe \
ENTRY_PROBE_PINS=/path/to/research-repo/pins \
ENTRY_PROBE_FIXTURES=/path/to/read-later/fixtures/pages \
swift test -c release -Xswiftc -enable-testing --filter EntryScalingProbeTests

cd ../../tools/entryscale
cargo run --release -- --svg-dir /tmp/entryprobe/svg /tmp/entryprobe/oplog.jsonl
```

Without `ENTRY_PROBE_OUT` the test skips. The pin and fixture variables are
optional. Synthetic articles always run.

## What is measured

- `extract`: `SwiftSoupExtractor.extract`, the parse and page classification.
- `plan`: `SpokenPlanBuilder.build`. It includes the invariant check.
- `invariant`: `SpokenPlanInvariant.violations` on its own. It is part of `plan`.
- `sha256`: the page hash that the shipped code computes before the plan build.
- `save`: `Store.save(document:)` into a temporary database.
- `seed`: `ReaderSeed` init, which builds `BlockRoles` and `SpokenWordNumbering`.
- `read`: the whole `ArticleIngress.read` path. It is a check, not a part of the total.
- `total`: extract + plan + sha256 + save + seed.

Each article gets one window per arm, at least 20 ms long, after one untimed
warm-up. Telemetry stages come from five real `ArticleIngress.read` calls per
article, each preceded by a `probe.call` marker. The fitter pairs
`extract.start`, `T4.parsed` and `T5.planReady` inside each marker. The
telemetry `plan` stage includes the hash, because the shipped code computes it
in that span.

## Output

- Sweep A (blocks, 30 words each) and sweep B (words per block, 100 blocks):
  log-log exponent per arm with a 95 % interval and a verdict.
- Two-term fit on synthetic articles: `ms = a + b·words + c·blocks·wpb²`, with
  the t-value of `c`.
- Real pages: log-log exponent and the regression line `ms = a + b·words`.
- Telemetry cross-check: median ratio of telemetry stages to probe stages.
  A value near 1.0 means the two agree.
- Verdicts for H1, H2 and H3.

Verdict rule, fixed before the run: an exponent is linear when its 95 %
interval lies in [0.8, 1.2]. It is quadratic when the interval's lower bound
exceeds 1.5. Anything else is inconclusive.

## Limits

- Synthetic blocks are uniform. Real pages mix block sizes, which the real-page
  fit covers.
- The probe runs in one process with no UI, no network and no fixed 180 ms wait.
- Timings are for one Mac. Device numbers differ.
