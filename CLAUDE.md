# CLAUDE.md — Zoop fork

This repository is a **private fork** of [NOOP](https://github.com/ryanbr/noop), branded **Zoop**
(second generation: **2oop → Zoop**). Upstream architecture and safety rules still apply via
[AGENTS.md](AGENTS.md); **this file overrides AGENTS.md** wherever they conflict.

@AGENTS.md

## Fork identity

| | |
|---|---|
| Product name | **Zoop** |
| Upstream project | NOOP (leave historical release notes / changelogs alone) |
| Scope of this fork | Private iOS customization — not an upstream contribution track unless asked |

Use **Zoop** in user-facing copy, new comments, commits, and PR text. Internal Apple identifiers
in this fork are also Zoop-prefixed (see below). The shared module name `Strand` stays (Xcode /
`@testable import Strand`).

## Development focus — iOS only

**Develop iOS only.** That means:

- **In scope:** `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/`, `ZoopWatch*`, shared Apple
  app code under `Strand/` that iOS compiles, and pure Swift packages under `Packages/` when an
  iOS change needs them.
- **Out of scope unless explicitly asked:** `android/**` (still named `com.noop.*` upstream-style),
  Gradle/APK work, and Kotlin “parity for completeness.”
- **macOS (`Strand` scheme):** only touch when shared sources must compile for iOS.

Do **not** mirror Swift changes into Android.

### Verify on iOS paths

```bash
cd Packages/WhoopProtocol && swift build && swift test
# Needs Xcode on macOS:
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme ZoopiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Internal identifiers (already renamed on Apple)

| Kind | Zoop value |
|---|---|
| Display / `ProjectInfo.appName` | Zoop |
| Bundle id prefix | `com.zoopapp` (`Config/BundleId.xcconfig`) |
| App ids | `$(BUNDLE_ID_PREFIX).zoop` (+ `.widgets` / `.watch` / …) |
| App Group | `group.$(BUNDLE_ID_PREFIX).zoop.staging` |
| URL scheme | `zoop://` (Oura callback, Shortcuts import, local access) |
| Backup extension | `.zoopbak` |
| UserDefaults / AppStorage prefix | `zoop.*` |
| Xcode targets / schemes | `ZoopiOS`, `ZoopiOSWidgets`, `ZoopWatch`, `ZoopWatchComplications` |
| Design types | `ZoopButton`, `ZoopMetrics`, `ZoopCard`, … |
| Local-access package | `Packages/ZoopLocalAccess` |

Do **not** reintroduce `noop` / `NOOP` / `Noop` in new Apple code. Android may still say `com.noop`
— leave it alone.

Localized string **catalog keys** that still contain the word NOOP are legacy lookup keys; do not
mass-rename them without updating every `Text("…")` / `String(localized:)` site and all locales.
When editing a string, prefer introducing a Zoop-keyed entry rather than breaking keys mid-flight.

## What not to do

- Do not edit `android/**` for parity.
- Do not add servers, accounts, telemetry, or WHOOP proprietary assets (same as AGENTS.md).
- Do not rewrite `CHANGELOG.md` / `docs/releases/**` history to say Zoop.
