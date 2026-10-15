# Zoop 2.0 — QA pass 1

Branch `qa-1` from `zoop-2.0`. Simulator: a dedicated iPhone 17 Pro (iOS 27.0), `--demo-seed`, German.
Looks checked: Classic dark and Pastel light throughout, Pastel dark and Classic light as spot checks.
Screenshots (full size, plus `small_*` copies) were saved to the session scratchpad `qa1/` folder;
filenames below. Suffixes: `cd` Classic dark, `cl` Classic light, `pl` Pastel light, `pd` Pastel dark.

## Known issues (all fixed)

| # | Issue | Fix | Evidence |
|---|---|---|---|
| 1 | Secondary buttons invisible on cards (drew the card colour), worst in Pastel dark | New tokens `secondaryButtonFill / Border / Text` for all four looks, used by `ZoopButtonStyle(.secondary)` and the legacy secondary style | `34-training-pl`, `42-training-pd` ("Hinzufügen") |
| 2 | Verdicts without direction ("Fitnessalter: Unter deinem Bereich", "Schlafschuld: Über deinem Bereich") | `MetricPolarity` (higherIsBetter / lowerIsBetter / neutral) on `MetricReadout`, default per `MetricID`, explicit for app ids (sleep debt / stages / efficiency, stress tile, calories, fitness-age factors). Directional metrics read "Besser / Schlechter als üblich" (or "… als typisch" on a population range) in `textPositive` / `textWarning`; neutral ones keep the old words. Tiles' compact verdict and the Today ring tint follow it. Tests in `MetricReadoutTests`. Insights' HRV / resting-HR trend findings use the same words. | `03-today-scroll2-classic-dark`, `32-today-s2-pl`, `70-insights-cl` |
| 3 | Today dashboard tiles of unequal height | Rows laid out as fixed-height HStacks | `03-today-scroll2-classic-dark` |
| 4 | System blue leaking | Theme accent set as SwiftUI tint and UIKit window tint at the app root (`zoopWindowTint`, re-applied on theme / accent / appearance change); tab content uses the accent, the tab bar keeps its white selection | `33-settings-pl`, `43-settings-pd`, `44-planner-pd` |
| 5 | "Disconnected" and the other connection labels in English | `LiveState.connectionStatusLabel` resolves through the catalogue ("Getrennt", new "Gekoppelt · inaktiv") | `14-settings-cd`, `33-settings-pl` |
| 6 | Planner / evening card 20:18 vs coach 22:15 | `TonightBedtime` (StrandAnalytics) is the one resolver: wake − time in bed, clamped to the usual bedtime − 60 min (≥ 21:00 unless habitual), quarter hour. `PatternsModel.tonight` holds it, so planner, evening card, coach (now also handed the armed alarm) and the wind-down reminder agree; time in bed follows the clamped time. Tests in `TonightBedtimeTests`. | `16-sleep-cd`…`19-sleep-end-cd` (before: "Heute Nacht 20:18"), `37-planner-pl` (after: 22:15, matches the coach card) |
| 7 | `AICoach.swift` 1,360 lines | Split into seven files ≤ 281 lines (pure refactor) | — |

## Found in the screen walk

Fixed:

- "kCal" (Foundation's symbol) on the Aktive-Kalorien tile → "kcal" (`02-today-scroll1-classic-dark`).
- Duration delta "-0min ggü. typisch" (Sleep stages) → "±0min".
- Stress chart axis and hour list printed "2.0" on German screens → "2,0" (`53-stress-cd` before, `71-stress-cl` after).
- Sleep planner goal truncated ("meinen Schlafbedarf erre…") → wraps to two lines (`44-planner-pd` before).
- Sleep planner showed "–" for an unknown time → "Nicht festgelegt".
- Fitness-age starfield used a paused `TimelineView` (fails the quiet-motion tests and keeps the render
  server busy) → still frame with no timeline when motion is unwanted, as `LiquidSky` does.

Not fixed (recorded for a follow-up):

- The Belastung ring pushes a screen titled "Workouts" while the ring and tab say "Belastung" / "Training" (`52-strain-cd`).
- Fitness & Ermüdung legend: the two series are two close blues in Classic (`05-training-classic-dark`).
- Fitness-age factor rows show a range verdict ("Besser als typisch") next to a trend badge ("Schlechter"); two facts, but they read as a contradiction (`55-fitnessage-cd`).
- Today "Mein Tag" shows sleep as time in bed (7h 13min) while the coach and Sleep say asleep time (6h 49m) without saying which is which (`45-coachsheet-pd`).
- Energiekonto: "Heute Morgen 60 · Aufgeladen +0 · Verbraucht −15" next to a current 46 (rounding) (`54-energy-cd`).
- Recovery contributor rows mark a neutral effect with a "—" glyph (`50-recovery-cd`).
- Not reached with the automation available (no touch injection into this simulator; navigation was
  driven through the accessibility tree): live workout cover, add-workout form, onboarding past the
  terms page (`80-onboarding2-cl`), Settings sub-pages beyond the root.

## Verification

- `Packages/StrandAnalytics`: `swift test` — 2,412 tests, 0 failures.
- `Packages/StrandDesign`: `swift build` OK; `swift test` passes except `PlaceholderTests.testRecoveryStateWords`, which expects English words and fails on a German-locale host (unrelated, pre-existing).
- `xcodebuild -scheme ZoopiOS -destination 'generic/platform=iOS Simulator'` — build succeeded.
- `Tools/font_lint.py` — font=8 hex=2 (unchanged); `Tools/doc_comment_lint.py` — no new detached doc comments.
