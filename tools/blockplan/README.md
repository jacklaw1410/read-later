# blockplan

Dumps a block plan in the contract format (`contracts/block-plan.v1.json`)
so the research gate can score output from the real Swift code.

```bash
swift run blockplan ../../fixtures/pages/004-averages.html > plan.json
swift run blockplan ../../fixtures/pages/007-paywall.html --class --status=403
```

`--class` prints the page class instead of a plan. `--status=<code>` passes the
stored HTTP status, which the extractor needs: three pinned walls answer 403 and
carry an empty body.

## Status: runs

The tool calls the real `SwiftSoupExtractor` and `SpokenPlanBuilder` from
`ReadLaterCore`. The plan on stdout is the block plan the app would build for
the same page.

The research gate scores this output with `gate/blockplan_sweep.py` in
`read-later-research`. The last run is in
`read-later-research/evidence/2026-11-12-d8-blockplan-sweep/`.
