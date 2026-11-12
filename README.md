# Read Later — app

iOS 17+ / macOS 14+ reading app. Paste a link, listen, tap a word.

**Status:** first milestone. The pipeline compiles and the reader runs against a fixed
document. Extraction from the network, pack download and sync are not wired yet.

The research that produced this design lives in `read-later-research`. That repo is
append-only evidence; this one is code.

## 1. What this repo is

One multiplatform app target (`apps/apple`, XcodeGen spec in `project.yml`).
Four Swift packages hold the model, packs, storage and UI tokens.
`contracts/` holds versioned JSON Schemas shared with the research repo.
`fixtures/` holds 20 committed pages and their expected block plans.
`tools/` holds the block-plan dumper and the pack registry publisher.

## 2. Prerequisites

| Tool | Version on this machine | Check with |
|---|---|---|
| Xcode | 27.2 (27B52) | `xcodebuild -version` |
| XcodeGen | 2.46.0 | `xcodegen --version` |
| Swift | 6.4.2 (Apple) | `swift --version` |
| Node | v26.13.1 — only for pack publish via `wrangler` | `node --version` |

Install XcodeGen with `brew install xcodegen`.
The generated `.xcodeproj` is not committed. `project.yml` is the source.
Run `xcodegen generate` before any `xcodebuild` call, and after any change
to `project.yml` or to the file list.

## 3. Build and boot on macOS

Work in `apps/apple`.

```bash
cd apps/apple
xcodegen generate
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
  -destination 'platform=macOS' \
  -derivedDataPath build -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO build
```

Success looks like `** BUILD SUCCEEDED **` and this file:

```
apps/apple/build/Build/Products/Debug/ReadLater.app
```

Open it with `open` (this registers the launch with LaunchServices, which the
snapshot harness needs):

```bash
open -n ./build/Build/Products/Debug/ReadLater.app
```

## 4. Build and boot on the iOS simulator

Work in `apps/apple`. Use `CODE_SIGNING_ALLOWED=NO` (the `project.yml` default).
Run `xcodegen generate` first if you have not done so yet.

```bash
cd apps/apple
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
open -a Simulator
xcrun simctl install booted ./build/Build/Products/Debug-iphonesimulator/ReadLater.app
xcrun simctl launch booted app.readlater.reader
```

If the simulator runtime is missing, download it first (about 7 GB):

```bash
xcodebuild -downloadPlatform iOS
```

## 5. Build and run on a physical iPhone

**Run on 2026-11-12:** build succeeded, install succeeded, first launch was
denied until the profile was trusted on the phone.

You need an Apple Developer team. A free personal team works, but its
provisioning profile expires after 7 days. Renew it in Xcode when it lapses.

1. Read the team id from the Xcode account, not from the certificate.

```bash
plutil -p ~/Library/Preferences/com.apple.dt.Xcode.plist \
  | grep -A4 IDEProvisioningTeamByIdentifier
```

2. Build. `-allowProvisioningUpdates` lets xcodebuild register the App ID and
   create the profile; without it the build fails with `No profiles … were
   found`.

```bash
cd apps/apple
xcodegen generate
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
  -destination 'platform=iOS,name=<Your iPhone>' \
  -configuration Debug \
  DEVELOPMENT_TEAM=<YourTeamID> CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES -allowProvisioningUpdates build
```

3. Install and launch:

```bash
APP=~/Library/Developer/Xcode/DerivedData/ReadLater-*/Build/Products/Debug-iphoneos/ReadLater.app
xcrun devicectl device install app --device <UDID> "$APP"
xcrun devicectl device process launch --device <UDID> app.readlater.reader
```

4. On the phone, trust the developer certificate under
   Settings → General → VPN & Device Management. Until then the launch fails
   with `… its profile has not been explicitly trusted by the user`.

Keep `CODE_SIGNING_ALLOWED: NO` in the committed `project.yml`.
Override signing on the command line or keep the team id in a local
`Secrets.xcconfig` (gitignored), never in a commit.

## 6. Tests

Work in each package directory. `swift test` covers every package.
Counts below were observed on 2026-11-12 with Swift 6.4.2.

| Package | Command | Observed |
|---|---|---|
| `ReadLaterCore` | `swift test` in `packages/ReadLaterCore` | 64 tests pass |
| `ReadLaterPacks` | `swift test` in `packages/ReadLaterPacks` | 50 tests pass |
| `ReadLaterStore` | `swift test` in `packages/ReadLaterStore` | 11 tests pass |
| `ReadLaterUI` | `swift test` in `packages/ReadLaterUI` | 33 swift-testing tests pass |

```bash
cd packages/ReadLaterCore && swift test
cd ../ReadLaterPacks && swift test
cd ../ReadLaterStore && swift test
cd ../ReadLaterUI && swift test
```

`ReadLaterTestKit` is a fixture library, not a test bundle. It has no
`Package.swift` and no tests of its own.
There is no Xcode UI-test target. UI coverage lives in `ReadLaterUITests`
inside the `ReadLaterUI` package.

## 7. The snapshot harness

`SnapshotHarness.swift` drives the real reader session and writes PNGs of the
running window. It captures entry, entry-progress, reader, playing,
playing-scrolled, hold, footnote, middle blocks, notes, miss-offer,
miss-resolved and hit.

Launch it with `open -n` and pass the output directory after `--snapshot`:

```bash
cd apps/apple
open -n ./build/Build/Products/Debug/ReadLater.app --args --snapshot /tmp/rlsnap
```

PNGs land in the directory you name (`/tmp/rlsnap` above).
Without a directory, they land in a `readlater-snapshots` temp folder.
The harness pins the window to 430 × 760, so two runs of the same build write
the same pixels. Launch it with `open -n`, or run the binary in
`Contents/MacOS` directly. Both write captures.

Known limitation: in a `--snapshot` launch, `AVSpeechSynthesizer` starts the
utterance and then delivers no word-boundary callbacks. The harness advances
the wash itself (`simulateWash`, DEBUG builds only) at the measured reference
pace of 429 ms a word. Screenshots show where the voice would be, not live
speech tracking.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `xcodebuild: error: The project 'ReadLater.xcodeproj' does not exist` | `xcodegen generate` never ran, or the file list changed | Run `xcodegen generate` in `apps/apple`, then retry |
| `Ad Hoc code signing is not allowed with SDK 'iOS 27.2'` | Ad-hoc signing (`CODE_SIGN_IDENTITY="-"` with signing on) against the iOS SDK | Use `CODE_SIGNING_ALLOWED=NO` for simulator builds. Seen in the past; on Xcode 27.2 ad-hoc signing also builds clean |
| Simulator list is empty or the build asks for a runtime | iOS simulator runtime is not installed | Run `xcodebuild -downloadPlatform iOS` (about 7 GB), then retry |
| No PNGs appear after a snapshot run | Binary was run directly instead of through LaunchServices | Launch with `open -n … --args --snapshot <dir>`, not by path to the binary |
| Wash stays on word zero in a `--snapshot` launch | Word-boundary callbacks do not arrive in that launch | Expected. The harness drives the wash itself. See §7 |
| `error: Could not find Package.swift` in `packages/ReadLaterTestKit` | TestKit is a source library inside the app project, not a package | Do not run `swift test` there. Test it through the packages that use it |
| `The app identifier "…" cannot be registered to your development team because it is not available` | the bundle id is already registered to another Apple team; ids are unique across all accounts | Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to a unique id, then `xcodegen generate` |
| `No profiles for '…' were found` | Xcode has not created a profile for this bundle id and team | Add `-allowProvisioningUpdates` so xcodebuild can register the App ID |
| `No Account for Team "…"` | the value came from the certificate name, not from the Xcode account | Use the `teamID` from `IDEProvisioningTeamByIdentifier` in `com.apple.dt.Xcode.plist` |
| `Unable to find a destination matching … name:JL` | Xcode has not listed the phone yet: locked, asleep, or not trusted | Unlock and trust the phone, then check `xcrun devicectl list devices` and use `-destination 'id=<UDID>'` |
| `… its profile has not been explicitly trusted by the user` | the free-team profile needs one manual trust on the device | Settings → General → VPN & Device Management → Apple Development → Trust |
| `main actor-isolated class method … cannot be called from outside of the actor` in `DictionaryLookup.swift` | Swift 6 language-mode warning | Warning only. The build still succeeds |

## 9. Where things live

```
apps/apple/          XcodeGen spec, app target, platform code
packages/ReadLaterCore/   Block model, extraction, spoken plan, invariant, lookup protocol
packages/ReadLaterPacks/  Pack manifest, sha256 verify, install state machine
packages/ReadLaterStore/  GRDB schema, migrations, FTS5, oplog
packages/ReadLaterUI/     Calm Editorial tokens and shared views
packages/ReadLaterTestKit/ Fixture loading and assertions
contracts/           Versioned JSON Schemas shared with the research repo
fixtures/            20 committed pages and their expected block plans
tools/blockplan/     Dumps a block plan so the research gate can score it
tools/registry/      Pack publish script (`publish.sh`, needs `wrangler` + Node)
docs/                ADRs, provenance and the design system. Extraction flow: research repo spec/extraction-flow.md
design/tokens.json   The only source for colour, type, space, radius, size and motion
tools/tokens/        Generator for every platform, plus the stale-file check
```

## 10. Design system

`design/tokens.json` holds the Calm Editorial values. `tools/tokens/generate.py`
writes Swift, CSS, Kotlin and XAML from that one file. A view reads a semantic
name, never a literal.

```bash
python3 tools/tokens/generate.py     # write every platform file
./tools/tokens/check.sh              # fail when a file is stale
```

The layers, the portability boundary and the steps to add a platform are in
[`docs/design-system.md`](docs/design-system.md).

## Rules

1. `extract()` returns `[Block]`, never one string.
2. Every spoken sentence is an exact slice of its block text. The invariant runs at load.
3. Reader-facing copy is owned by the research repo's specs. This repo quotes it.
4. One commit per unit of work, Conventional Commits.
