# readerscale

Fits the Reader scaling probe. The probe is `ReaderScalingProbeTests` in
`packages/ReadLaterUI`. It times the per-render work of `ReaderView` on
articles of many lengths, and writes each result as a `probe.sample` event in
the oplog. This crate reads the oplog and prints the fits.

Question it answers: does the cost of one render grow with the square of the
block count (footnote map rebuilt per row), or with the word count only?

## Run on macOS

Use Release. Debug timings do not rank the costs the same way.

```
cd packages/ReadLaterUI
READER_PROBE_OUT=/tmp/readerprobe \
READER_PROBE_FIXTURES=/path/to/read-later/fixtures/pages \
swift test -c release --filter ReaderScalingProbeTests

cd ../../tools/readerscale
cargo run --release -- --svg-dir /tmp/readerprobe/svg /tmp/readerprobe/oplog.jsonl
```

`READER_PROBE_FIXTURES` is optional. Without it the probe runs the synthetic
and mixed articles only. Without `READER_PROBE_OUT` the test skips.

## Output

One row per component on stdout. Components:

- `footnote.rowwise`: the footnote map rebuilt for every row, as `ReaderView` does now.
- `footnote.once`: the same lookups with the map built once. The fix arm.
- `meta.count`: `spokenWordCount` and `skippedRegionCount`, read in the subhead.
- `wash.scan`: the wash test for every row, twice per row.
- `body.total`: the three above plus `footnote.rowwise`, as one render.
- `telemetry.record`: cost of one `TelemetryOplog.record` call, in ms.

Columns: `ms/word` is the slope of ms on spoken words, pooled. `exp_rows` and
`exp_words` are power-law exponents from the block and word sweeps. `c_rows2`
and `c_words` come from `ms = a + c_rows2 * rows^2 + c_words * words`, fit on
the block sweep. A quadratic cost shows as `c_rows2` clearly above zero, and
`exp_rows` near 2 for the rowwise arm.

The SVG files plot ms against words with the pooled regression line.

## Limits

- The render arms are a copy of `ReaderView`'s private footnote code, not the view.
  The probe times the copy. SwiftUI body re-runs are not counted here.
- Each article is measured once, as the median of 5 renders.
- The probe runs in one process with no app UI. It does not show scrub hitches.
