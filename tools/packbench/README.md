# readlater-packbench

Repeatable lookup benchmark for the installed dictionary pack: 1,000
lookups with latency percentiles and peak memory.

## Run it

```bash
cargo run --release -- "<index.sqlite>"
cargo run --release -- --json "<index.sqlite>"
```

The first form prints a human table. The second prints one JSON object on
stdout and nothing else. `--lookups N` changes the count (default 1000).
`--help` prints the sampling rule.

## Sampling rule

Order every headword by `key`, set `step` to `row_count / N` with integer
division, and take rows at positions `0, step, 2 * step`, and so on. A
rerun against the same index picks the same N headwords. N must not
exceed the row count. The report carries a `sample_checksum` so two runs
prove they measured the same sample without printing all N words.

One lookup folds the headword as `PackIndexStore.normalize` does (NFKD,
drop combining marks, curly apostrophes to `'`, lowercase, trim), then
runs `SELECT word, phonetic, pos, gloss FROM words WHERE key = ? LIMIT 1`
on a prepared statement, in sample order with no shuffling. Sampling
happens before timing starts.

## What the numbers mean

- `min_us`, `p50_us`, `p95_us`, `p99_us`, `max_us`: per-lookup wall time
  in microseconds, timed with `Instant` around one prepared-statement
  lookup. The tail (p99, max) matters more than the median: a tap that
  stalls is the flow break the reader feels.
- `total_s`, `lookups_per_s`: the whole loop. Divide work per tap from
  these, not from one lucky lookup.
- `rss_before_bytes`, `rss_peak_bytes`: process resident set before the
  loop and the peak sampled every 100 lookups, read from
  `mach_task_basic_info` (no child process). The pack stays in SQLite;
  the process holds one connection and one prepared statement, so the
  peak shows lookup overhead, not the index.
- `hits`: every sampled key exists by construction, so a miss here
  means the fold diverged from the stored key, not a gap in the pack.

Cold vs warm: the first run after a reboot pages the 76 MB index in
from disk and reads slower. Later runs reuse the kernel page cache.
Compare cold runs with cold runs and warm runs with warm runs. Two runs
back to back share one condition; the sample checksums must match, the
percentiles should sit in the same order of magnitude, and exact
microseconds will still differ.
