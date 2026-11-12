# Extraction: how a page becomes blocks

The extractor turns one HTML string into a page class and a list of blocks. A
block is the unit the reader draws, the wash marks, and the synthesizer speaks.

Two files hold the whole path:

| File | Job |
|---|---|
| `packages/ReadLaterCore/Sources/ReadLaterCore/SwiftSoupExtractor.swift` | decides the page class, then walks the body |
| `packages/ReadLaterCore/Sources/ReadLaterCore/ContentRoot.swift` | picks the article root before the walk |
| `packages/ReadLaterCore/Sources/ReadLaterCore/Classifier.swift` | names each block's kind |

The research decision behind the order is `read-later-research/spec/extraction-gate.md`.
The reference implementation is Mozilla Readability 0.6.0, vendored at
`vendor/readability/Readability.js` (see its README for the sha256).

---

## 1. The call graph

```
ArticleIngress.ingest(url:)
  └─ PageFetching.fetch(url)                 → (html, finalURL, httpStatus)
      └─ SwiftSoupExtractor.extract(html:source:httpStatus:)
          ├─ guard: non-empty html
          ├─ SwiftSoup.parse                     → Document
          ├─ body.select("script, style, …").remove()
          ├─ measure: bodyText, bodyChars, bodyWords, linkCount, linkChars, paragraphs
          ├─ class checks, in order (below)
          │    ├─ throw .wall       (status 401/403/451, or a wall marker)
          │    ├─ throw .shell      (tiny body + SPA marker, or tiny body + big html)
          │    ├─ throw .index      (three structural shapes, below)
          │    └─ throw .empty      (under 20 words)
          └─ usable path
              ├─ ContentRoot.roots(in: body)      → [Element]  (1…n, or body)
              ├─ BlockWalker.run / .process       → [Block]
              └─ ExtractionResult(.usable, blocks, title)
```

`extract` throws for every non-usable class. The thrown error carries the class
and a `reason` string, so the card copy and the debug log read the same fact.

---

## 2. The class decision tree

Every check is a stopping rule. The first one that fires wins, so the order is
part of the contract.

```
                    ┌──────────────────────────┐
                    │ html empty or unparseable│──yes──▶ failed (emptyDocument)
                    └────────────┬─────────────┘
                                 no
                    ┌────────────▼─────────────┐
                    │ status ∈ {401,403,451}   │──yes──▶ walled
                    └────────────┬─────────────┘
                                 no
                    ┌────────────▼─────────────┐
                    │ wall marker in html or   │──yes──▶ walled
                    │ title (gate's marker list)│
                    └────────────┬─────────────┘
                                 no
                    ┌────────────▼─────────────┐
                    │ bodyChars < 200  AND     │──yes──▶ unrendered (js-shell)
                    │ (html ≥ 8000 OR SPA hint)│
                    └────────────┬─────────────┘
                                 no
                    ┌────────────▼─────────────┐
                    │ body text empty          │──yes──▶ failed
                    └────────────┬─────────────┘
                                 no
                    ┌────────────▼─────────────┐
                    │ index shape? (3 rules)   │──yes──▶ not-an-article
                    └────────────┬─────────────┘
                                 no
                    ┌────────────▼─────────────┐
                    │ bodyWords < 20           │──yes──▶ failed
                    └────────────┬─────────────┘
                                 no
                                 ▼
                               usable
```

### The index rule

Any one shape is enough:

| shape | test in code |
|---|---|
| link farm | `linkCount ≥ 15 && paragraphs ≤ 3 && bodyWords < 600` |
| no prose | `paragraphs == 0 && bodyWords < 100` |
| link soup | `bodyWords < 40 && linkDensity ≥ 0.5` |

`linkDensity = linkChars / bodyChars`. `paragraphs` counts `<p>` elements with
non-empty text. All three shapes run on the **whole body**, before the article
root is chosen. Section 5 covers why that is the weak point.

### The wall markers

Copied from `read-later-research/gate/inputs/wall_rule.py`, not invented. Markers
are matched against the lowercased HTML and the lowercased title. A wall is
decided before the empty-text guard, because a paywall page often has no body
text after the scripts are removed.

---

## 3. The walk

`ContentRoot.roots(in:)` returns one element, several siblings, or the body.

- One root: `BlockWalker.process(root)`.
- The body itself: `BlockWalker.run(body)`.
- Several roots: each is processed in document order, and blocks continue one
  id sequence.

A root is read in document order. The walker has three cases:

| case | test | result |
|---|---|---|
| leaf | tag in `leafTags` (`p`, `h1…h6`, `pre`, `blockquote`, `ul`, `ol`, `dl`, `li`, `dt`, `dd`, `figure`, `figcaption`, `aside`, `nav`, `code`, `img`, `math`, media, and a data `table`) | one block, text is the element's normalised text |
| container | tag in `containerTags` (`div`, `section`, `article`, `main`, `header`, `footer`, table parts) | children in order; inline runs between block children become their own blocks |
| in disguise | any other tag that holds block-level descendants | treated as a container |
| unknown inline | any other tag, no block descendants | one block from its whole text, so no words are lost |

Three repairs live in the walker. Each one was a defect found by a fixture:

1. **Layout tables recurse.** `isLayoutTable` returns true when a table holds
   paragraph-level prose. Paul Graham's essays are one table. As a leaf, the whole
   essay was skipped.
2. **`<br><br>` splits paragraphs.** `inlineChunks` cuts a leaf on two or more
   consecutive `<br>`. Older pages build paragraphs this way, and the text API
   turns each break into a space.
3. **Mixed content is walked once.** `processContainer` iterates `getChildNodes()`
   and gathers text nodes and inline elements into a run. The older path read
   only `children()` and then `ownText()`, which put direct text into one block
   and inline-child text into a second.

`pre` and `code` skip repair 2, because a line break inside code is content.

### Block kinds

`Classifier.classify` decides in one order: role, class, tag, then shape.

- Element identity decides first. A `pre` is code. A `table` is a table. A `p` is
  prose.
- Class and role names only break ties. A `.pullquote` is a pull quote.
- Shape decides last: link density, line length, CJK ratio, all-caps (a heading),
  digits (a caption).
- When nothing decides, the block is prose with low confidence. The bias is to
  speak: a false-speak costs one bad sentence, a false-skip loses content.

---

## 4. Title

`doc.title()`, with runs of whitespace collapsed. If the page has no `<title>`,
the ingress layer falls back to the host name. The title is display only; it is
not spoken.

---

## 5. Known weak point: index rule before article root

The index rule reads the whole body. A real article with a "recommended reads"
rail can therefore trip the link-farm shape. This is measured, not theoretical:
fixtures 57, 61, 80 and 99 are usable articles that both the gate and the Swift
extractor call `not-an-article` (`evidence/2026-11-12-d8-blockplan-sweep/`).

The opposite error also exists: a home page with one long teaser can pass the
three shapes and be called `usable`.

The proposed repair is in `read-later-research/findings/F16-extraction-order.md`:
choose the article root first, and apply the index rule only when no root passes
a content test. Do not change the order here until that experiment lands.

---

## 6. Reading a bad result

The `reason` string names the rule that fired. Examples:

```
wall marker: subscribers only
js-shell: body 41 chars, html 212003 chars
index: 38 links, 1 paragraphs, 92 words
usable: 14 blocks from https://example.com/a
```

When a page is wrong, first read the class and the reason. Then check the four
counts that decide it: `bodyChars`, `bodyWords`, `linkCount`, `paragraphs`. A
wrong class with plausible counts is a rule-order problem. A wrong class with
absurd counts is a measurement problem.

---

## 7. Where to change what

| Symptom | File | Function |
|---|---|---|
| a paywalled page reads as usable | `SwiftSoupExtractor.swift` | `wallMarker` |
| a JS app shows an empty page | `SwiftSoupExtractor.swift` | `containsSPAMarker` |
| an article is called an index | `SwiftSoupExtractor.swift` | the index `if` in `extract` |
| the reader shows the sidebar or the byline rail | `ContentRoot.swift` | `roots`, `chromeWords` |
| a paragraph is split in two | `SwiftSoupExtractor.swift` | `inlineChunks` |
| a whole essay becomes one block | `SwiftSoupExtractor.swift` | `isBlockPosition`, `isLayoutTable` |
| a heading speaks as prose, or a quote loses its style | `Classifier.swift` | `classify` |

---

## 8. Tests

| Suite | What it pins |
|---|---|
| `SwiftSoupExtractorTests` | the five classes, the wall markers, the three walker repairs |
| `ContentRootTests` | scoring, the climb, siblings, the body fallback |
| `ClassifierTests` | each block kind, and the tie-break order |
| fixture plans | one stored block plan per pinned page, compared exactly |

The pinned pages and their stored plans live in `fixtures/pages/` in this repo:
one `.html`, one `.expected.json` class, one `.blockplan.json` per fixture
(`fixtures/AGREEMENT.md`). The scoring sweep lives in
`read-later-research/evidence/2026-11-12-d8-blockplan-sweep/`. A change to any
rule must regenerate the plans and record the result in a new dated folder.

---

## 9. What this document is not

- Not the reader's visual rules. See `read-later-research/spec/inline-content-rules.md`.
- Not the scoring experiment. See `read-later-research/gate/blockplan_sweep.py`.
- Not the decision record for the block model. See
  `read-later-research/spec/adr-0002-extraction-returns-blocks.md`.
