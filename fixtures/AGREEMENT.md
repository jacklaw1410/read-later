# Fixture agreement

Date: 2026-11-12. Method: run `tools/blockplan` over all 20 pages in `fixtures/pages/`
and compare `*.expected.json` against `expected_page_class` in `fixtures/manifest.json`.
The expected class comes from the research gate of record
(`read-later-research/gate/extraction_gate.py`), not from this repo.

Result: **18 of 20 exact. 20 of 20 agree on usable versus not usable.**

| Page | Group | Expected | Swift | |
|---|---|---|---|---|
| `004-averages.html` | long-form prose | usable | usable | exact |
| `005-great-work.html` | long-form prose | usable | usable | exact |
| `007-paywall.html` | login wall | walled | walled | exact |
| `008-paywall.html` | login wall | walled | walled | exact |
| `012-medium.html` | login wall | walled | walled | exact |
| `016-login.html` | index | not-an-article | not-an-article | exact |
| `018-javascript.html` | long-form prose | usable | usable | exact |
| `022-python-json.html` | long-form prose | usable | usable | exact |
| `026-reddit.html` | JS shell | unrendered | unrendered | exact |
| `027-hn.html` | index | usable | usable | exact |
| `040-zhihu.html` | non-English | failed | not-an-article | both not usable |
| `042-de-wiki.html` | non-English | usable | usable | exact |
| `056-jb-help.html` | JS shell | unrendered | unrendered | exact |
| `061-halifax-essay.html` | long-form prose | usable | usable | exact |
| `064-tumblr.html` | index | not-an-article | unrendered | both not usable |
| `067-mlk-draft.html` | short news | usable | usable | exact |
| `078-italian-schools.html` | short news | usable | usable | exact |
| `089-bubble-quanta.html` | long-form prose | usable | usable | exact |
| `095-sciencedaily.html` | short news | usable | usable | exact |
| `097-reddit-python.html` | JS shell | unrendered | unrendered | exact |

The two differences are both between two non-usable classes, so no reader sees a
different outcome. Both are reported, not hidden: `040-zhihu` is `failed` in the gate
because no rule fired there, and `064-tumblr` is an index page that the Swift walker
calls a JS shell.

## What this measurement changed

Two defects were found by running the fixtures, and both are fixed:

1. **A wall with an empty body reported as `failed`.** Three pinned walls have no
   readable text once scripts are stripped. The class is a property of the response, so
   `Extractor.extract` now takes `httpStatus` and maps 401, 403 and 451 to `walled`.
   Without this, six of the twenty pages were wrong.
2. **The wall markers were invented and too wide.** A bare `paywall` and `metered`
   appear in the scripts and metadata of ordinary articles, and they refused two full
   articles that the gate passes. The markers are now the gate's six HTML markers and
   two title markers, copied rather than re-derived.

## What this does not prove

- Twenty pages is not a rate. The confidence interval on 20 samples is about ±20 points,
  so this table says the two implementations agree on these pages, not that they agree
  on the web.
- The research corpus is the measurement. `rate_all` and `rate_ours` still come from the
  Python gate over 100 reader-like pages and 100 pins.
- These pages are stored HTML. Nothing here exercised a fetch, a redirect or a timeout.
