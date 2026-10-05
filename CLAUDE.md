# CLAUDE.md — Zoop fork

This repository is a **private fork** of [NOOP](https://github.com/ryanbr/noop), branded **Zoop**
(second generation: **2oop → Zoop**). Upstream architecture and safety rules still apply via
[AGENTS.md](AGENTS.md); **this file overrides AGENTS.md** wherever they conflict.

@AGENTS.md

## Fork identity

| | |
|---|---|
| Product name (user-facing) | **Zoop** |
| Upstream project | NOOP (do not rebrand upstream docs wholesale; leave historical release notes alone) |
| Scope of this fork | Private customization — not an upstream contribution track unless explicitly asked |

When writing new user-facing copy, comments, PR titles, or commit messages for this fork, say
**Zoop**, not NOOP. Internal module/target/path names may still say `Strand`, `NOOPiOS`,
`com.noop`, etc. — do **not** mass-rename those unless the user asks; it breaks builds and
on-device data contracts.

## Development focus — iOS only

**Currently develop iOS only.** That means:

- **In scope:** `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/`, `NOOPWatch*`, shared Apple
  app code under `Strand/` that iOS compiles, and pure Swift packages under `Packages/` when an
  iOS change needs them.
- **Out of scope unless the user explicitly asks:** `android/**` (Kotlin/Compose/Room), Android
  Gradle/CI, APK packaging, and cross-platform Kotlin parity edits “for completeness.”
- **macOS (`Strand` scheme):** only touch when shared sources require it for the iOS build to
  compile; do not spend effort on macOS-only features.

Do **not** mirror every Swift change into Android. Skipping Android is intentional: this fork
optimizes for one platform to keep change cost and token use down.

### Verify on iOS paths

Prefer Apple-side checks that matter for iOS:

```bash
# Pure packages (no Xcode):
cd Packages/WhoopProtocol && swift build && swift test
# App target (needs Xcode on macOS):
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Do not run `./gradlew …` or Android unit tests unless the user asked for Android work.

## Branding rules (Zoop)

- Home-screen / display name, wordmarks, `ProjectInfo.appName`, and new UI copy → **Zoop**.
- Keep stable wire/storage identifiers that still say `noop` (URL scheme `noop://`, bundle id
  fragments, fusion source ids, backup keys, package names) unless a dedicated migration is
  requested — changing those can orphan local data.
- Design-system / BLE / offline-first / no-telemetry constraints from AGENTS.md still apply.

## What not to do

- Do not open upstream-style “parity” PRs that edit Android solely because Swift changed.
- Do not add servers, accounts, telemetry, or WHOOP proprietary assets (same as AGENTS.md).
- Do not treat remaining “NOOP” strings in old docs, changelogs, or untranslated catalogs as a
  mandate to rewrite the whole tree in one pass — rename user-visible surfaces as you touch them.
