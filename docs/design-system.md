# Design system — Calm Editorial

The design language has one source of truth and four generated outputs. A value
changes in one place. Every platform reads the result.

## 1 · Artifacts

| Path | Role |
|---|---|
| `design/tokens.json` | The only source. Primitive values, semantic roles, platform symbol bindings. |
| `tools/tokens/` | Rust tool. Reads the JSON. Writes every platform file. Fails on a bad reference. |
| `tools/tokens/Cargo.lock` | Committed, so a build uses the exact same crates. |
| `packages/ReadLaterUI/Sources/ReadLaterUI/Generated/ThemeTokens.swift` | Swift tokens. SwiftUI reads these. |
| `packages/ReadLaterUI/Sources/ReadLaterUI/Theme.swift` | Resolver plus UIKit and AppKit adapters. Hand-written, on purpose. |
| `design/generated/tokens.css` | CSS variables. For prototypes, docs and a future web surface. |
| `design/generated/Tokens.kt` | Jetpack Compose colours, dp sizes, sp type sizes, motion. |
| `design/generated/Tokens.xaml` | WinUI 3 theme dictionaries, doubles for size, motion in milliseconds. |

`readlater-tokens --check` exits non-zero when a file is out of date. The build
does not run it, so run it by hand or in CI before a commit.

```bash
cargo run --release --manifest-path tools/tokens/Cargo.toml            # write
cargo run --release --manifest-path tools/tokens/Cargo.toml -- --check # verify
```

The tool finds the repo root by walking up to the directory that holds
`design/tokens.json`. It writes nothing in `--check` mode, so it is safe to run
against a clean tree.

Tooling is Rust. A shell script that grows past a few lines becomes a Rust
binary, because a binary has types, a test surface and no shell-quoting bug.

## 2 · Layers

Three layers. A view may read layer 2 or layer 3. A view never reads a literal.

| Layer | Content | Example | Changes when |
|---|---|---|---|
| 1 Primitive | Raw values, no meaning | `amber.200 = #FDE68A` | Rarely. New value needed. |
| 2 Semantic | Role, one value per mode | `wash.fill = amber.200 / amber.700` | A design decision changes. |
| 3 Component | Role bound to a surface | `PlayerBar` wash on the spoken word | A surface changes. |

Layer 1 and 2 live in the JSON, so every platform gets them. Layer 3 lives in
each platform's own code, because component geometry differs by platform.

Names follow `group.role` in the JSON: `page.paper`, `text.meta`, `wash.fill`.
A dot becomes a camel-case suffix in Swift and Kotlin (`page.paper` →
`paper`), a kebab-case suffix in CSS (`--page-paper`), and Pascal case in XAML
(`PagePaper`). The Swift name is an explicit binding in the JSON, because the
app shipped names before the JSON existed and a rename would touch every view.

## 3 · What is portable

| Portable (in the JSON) | Platform-owned |
|---|---|
| Semantic colours, both modes | Colour object type (`Color`, `UIColor`, `Color`, `Color`) |
| Type role: size, weight family, line box | Font family. System faces differ. |
| Space scale, radius scale, target size, reading measure | Text scaling: Dynamic Type, `sp`, text scale |
| Motion duration and curve name | Runtime API and easing implementation |
| — | Focus, hover, key, safe-area and IME insets |
| — | Component geometry: padding inside a chip, bar layout |

A platform that wants a value reads the semantic role. It never copies a hex or
a point. `ReaderMetrics` shows the pattern on Swift: type and target sizes come
from `Theme`, reader-specific geometry stays local.

## 4 · Workflow

Change a value:

1. Edit `design/tokens.json`.
2. Run `cargo run --release --manifest-path tools/tokens/Cargo.toml`.
3. Run the same command with `-- --check`. It must pass.
4. Build the app. Take snapshots. Compare them.

Compare snapshots with `apps/apple/Sources/App/SnapshotHarness.swift`:
`ReadLater.app/Contents/MacOS/ReadLater --snapshot <dir>`. The harness pins the
window to 430 × 760, so two runs produce the same pixels. A token change that
only moves values shows as identical captures.

Add a semantic role:

1. Add the primitive if it is new.
2. Add the role under `semantic`, with light and dark values and a description.
3. Add the Swift name under `platform.swift.names`.
4. Regenerate. The generator fails if a name is missing or used twice.

Add a platform:

1. Add one emitter module in `tools/tokens/src/emit/` that reads `semantic` only.
2. Add its output to `emit::emit_all`.
3. Add a check in the same emitter if the format needs one, as XAML does.
4. Do not add platform values to the JSON. The JSON holds no geometry that
   belongs to one platform.

## 5 · Platform status

| Platform | State | Notes |
|---|---|---|
| iOS, macOS | In use | `ThemeTokens.swift` plus `Theme.swift`. 29 colours, 11 type roles, 6 spaces, 6 radii, 4 sizes, 4 motions. |
| CSS | Generated, not imported by a live surface | Prototypes in the research repo predate it. Use it for the next prototype. |
| Android | Generated, not compiled | Needs a Compose project to compile against. The wash chip must come from glyph bounds, not a fixed rect. Sizes are `dp`; text is `sp`. |
| Windows | Generated, not compiled | WinUI 3 theme dictionaries. `44` is 44 epx at 100 % scaling. Scale it with the system text scale. |

A generated file that no project compiles is a seed, not proof. Treat the
Kotlin and XAML output as correct-by-construction until a project builds it.

## 6 · Rules for agents

- Never edit a file under `Generated/` or `design/generated/`. Edit the JSON.
- Write a tool in Rust. Do not add a Python script or a shell script.
- Never write a hex, a point size or a radius in a view. Add a role.
- Keep one Swift symbol per semantic role. The generator rejects a duplicate.
- A token change is a design change. Show the owner the snapshot that proves it.
- `Theme.swift` may hold the resolver and platform adapters. It may not hold a
  new value. Both adapters read generated hex pairs.
