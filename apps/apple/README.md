# ReadLater — Apple app

Multiplatform app target. One target builds for iOS and macOS.
`project.yml` is the source. The `.xcodeproj` is generated, never committed.

See the root [README](../../README.md) for tests, the snapshot harness,
troubleshooting and the repo map.

## Prerequisites

| Tool | Version on this machine | Check with |
|---|---|---|
| Xcode | 27.2 (27B52) | `xcodebuild -version` |
| XcodeGen | 2.46.0 | `xcodegen --version` |
| Swift | 6.4.2 (Apple) | `swift --version` |

Deployment targets: iOS 17.0, macOS 14.0.
Supported destinations: `iOS`, `macOS` (one target, `supportedDestinations`).

## Generate

Work in this directory (`apps/apple`).

```bash
cd apps/apple
xcodegen generate
```

Run this before any `xcodebuild` call, and after any change to
`project.yml` or to the file list. Note the resource rule: `resources:`
is not a target key in XcodeGen, so `Resources` is a source entry with
`buildPhase: resources`.

`project.yml` sets `CODE_SIGNING_ALLOWED: NO`. That default suits simulator
and macOS-local builds. Device builds need signing; see below.

## macOS

```bash
cd apps/apple
xcodegen generate
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
  -destination 'platform=macOS' \
  -derivedDataPath build -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO build
open -n ./build/Build/Products/Debug/ReadLater.app
```

Success looks like `** BUILD SUCCEEDED **` and this file:

```
apps/apple/build/Build/Products/Debug/ReadLater.app
```

## iOS simulator

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

Keep `CODE_SIGNING_ALLOWED=NO` here. The signing flags differ from macOS:
the macOS build signs ad-hoc (`CODE_SIGN_IDENTITY="-"` with signing on),
the simulator build disables signing outright.

If the runtime is missing, install it first (about 7 GB):

```bash
xcodebuild -downloadPlatform iOS
```

## Physical iPhone

`NOT YET RUN ON THIS MACHINE.`

You need an Apple Developer team. A free personal team works, but its
provisioning profile expires after 7 days.

### Values

| Build setting | Value |
|---|---|
| `CODE_SIGN_STYLE` | `Automatic` |
| `DEVELOPMENT_TEAM` | your 10-character team id |
| `PRODUCT_BUNDLE_IDENTIFIER` | `app.readlater.reader` |

Find the team id from the signing certificate:

```bash
security find-identity -v -p codesigning
# 1) EE1... "Apple Development: you@example.com (ANQ2AUKWYY)"
#                                              ^^^^^^^^^^ team id
```

Xcode shows the same id under Settings → Accounts → your Apple ID → the team
row. The bundle id must be unique across all Apple accounts, not just yours.
`com.readlater.app` was already registered to another team, so Xcode answered
`The app identifier "com.readlater.app" cannot be registered to your
development team because it is not available.` If `app.readlater.reader` is
rejected the same way, append the team id: `app.readlater.anq2aukwyy`.

### Build

```bash
cd apps/apple
xcodegen generate
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
  -destination 'platform=iOS,name=<Your iPhone>' \
  -configuration Debug \
  DEVELOPMENT_TEAM=<YourTeamID> CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES build
```

Then on the phone, trust the developer certificate under
Settings → General → VPN & Device Management.

Do not commit the team id. Keep `CODE_SIGNING_ALLOWED: NO` committed, and
override signing on the command line. The signing pane in Xcode writes to the
generated `.xcodeproj`, which is gitignored, so a team set there is lost at the
next `xcodegen generate`.

## Snapshot harness

```bash
cd apps/apple
open -n ./build/Build/Products/Debug/ReadLater.app --args --snapshot /tmp/rlsnap
```

PNGs land in `/tmp/rlsnap`. Running the binary directly produces no
captures. Use `open -n`. Known limitation: word-boundary callbacks do not
arrive in a `--snapshot` launch, so the harness advances the wash itself
at 429 ms a word (DEBUG only). See the root README §7.
