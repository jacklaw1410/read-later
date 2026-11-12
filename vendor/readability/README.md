# Readability.js, upstream copy

This folder holds the Mozilla Readability file that `ContentRoot.swift` ports.
It does not run in the app. It is here so that a scoring constant can be
compared against its source without a network fetch.

| Field | Value |
|---|---|
| Package | `@mozilla/readability` |
| Version | 0.6.0 |
| Source | `https://unpkg.com/@mozilla/readability@0.6.0/Readability.js` |
| sha256 | `34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174` |
| License | Apache 2.0, held by Arc90 Inc and Mozilla contributors; the header is in the file |

## Why a port and not the file

Readability.js needs a DOM: `document`, `cloneNode`, `querySelectorAll`,
`innerHTML`. JavaScriptCore has no DOM, and shipping a DOM implementation to run
one script is larger than the port. Swift already has a DOM in SwiftSoup, which
the rest of `ReadLaterCore` reads.

The port keeps the scoring constants and the selection steps. It does not keep
Readability's DOM rewriting, its image cleaning, or its retry passes. See the
header of `ContentRoot.swift` for the exact list.

## Updating

Replace the file, record the new version and sha256 here, and diff
`ContentRoot.swift` against the constants in the new file:

```bash
shasum -a 256 vendor/readability/Readability.js
grep -n "positiveRe\|negativeRe\|unlikelyCandidates\|score += 1" vendor/readability/Readability.js
```
