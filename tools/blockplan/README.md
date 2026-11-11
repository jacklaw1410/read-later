# blockplan

Dumps a block plan in the contract format (`contracts/block-plan.v1.json`)
so the research gate can score output from the real Swift code.

```bash
swift run blockplan ../../fixtures/pages/004-averages.html > plan.json
```

## Status: does not run yet

The call chain is complete — `Extractor.extract()` then
`SpokenPlanBuilder.build()` — but both are `fatalError` stubs in
`ReadLaterCore` until the Core extractor lands. The package compiles;
running it throws `unrendered(reason: "extractor not implemented yet")`.
That is expected.

When the extractor lands, delete `PendingExtractor` in
`Sources/blockplan/main.swift` and use the real type. No other change
is needed here: the tool already writes the plan to stdout.
