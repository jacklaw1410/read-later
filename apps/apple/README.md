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

**Run on 2026-11-12:** build succeeded, install succeeded, first launch was
denied until the profile was trusted on the phone.

You need an Apple Developer team. A free personal team works, but its
provisioning profile expires after 7 days.

### Values

| Build setting | Value on this machine |
|---|---|
| `CODE_SIGN_STYLE` | `Automatic` |
| `DEVELOPMENT_TEAM` | `Z9LTZAW4H3` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `app.readlater.reader` |

Read the team id from the Xcode account, not from the certificate:

```bash
plutil -p ~/Library/Preferences/com.apple.dt.Xcode.plist \
  | grep -A4 IDEProvisioningTeamByIdentifier
# "teamID" => "Z9LTZAW4H3"
# "teamName" => "Hon Man Law (Personal Team)"
```

The `(XXXXXXXXXX)` inside a certificate name is **not** the team id. On this
machine the certificate says `(ANQ2AUKWYY)` while the team is `Z9LTZAW4H3`.
Passing the certificate value fails with `No Account for Team "ANQ2AUKWYY"`.

The bundle id must be unique across all Apple accounts. `com.readlater.app` was
already registered to another team, so Xcode answered `The app identifier …
cannot be registered to your development team because it is not available`.

### Build

`-allowProvisioningUpdates` is required. Without it xcodebuild refuses to create
the App ID and the profile:

```
error: No profiles for 'app.readlater.reader' were found … Automatic signing is
disabled and unable to generate a profile.
```

```bash
cd apps/apple
xcodegen generate
xcodebuild -project ReadLater.xcodeproj -scheme ReadLater \
  -destination 'platform=iOS,name=JL' \
  -configuration Debug \
  DEVELOPMENT_TEAM=Z9LTZAW4H3 CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES -allowProvisioningUpdates build
```

If `name=JL` fails with `Unable to find a destination`, the phone is not in
Xcode's list yet. Check it, then use the UDID instead of the name:

```bash
xcrun devicectl list devices
xcodebuild … -destination 'id=00008140-0001352A14BB001C' …
```

### Install and launch

```bash
APP=~/Library/Developer/Xcode/DerivedData/ReadLater-*/Build/Products/Debug-iphoneos/ReadLater.app
xcrun devicectl device install app --device 00008140-0001352A14BB001C "$APP"
xcrun devicectl device process launch --device 00008140-0001352A14BB001C app.readlater.reader
```

The first launch fails with `… its profile has not been explicitly trusted by
the user`. Trust it on the phone:

**Settings → General → VPN & Device Management → Apple Development: <your email>
→ Trust.** Then launch again.

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
