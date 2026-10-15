# Zoop 2.0 — Design system

The working reference for building any Zoop screen. [CONCEPT.md](CONCEPT.md) says *what* and *why*
(§1 principles, §2 navigation, §7 visual system, §8 engineering); this file says *how*, with the real
APIs in `Packages/StrandDesign`. Every snippet compiles against those APIs.

**See it live:** Test Centre › *Design gallery* (`Strand/Features/DesignGallery`) renders every token,
component and template below in all states, with a Classic / Pastel and System / Light / Dark switch.
If you change a component, check it there in all four looks.

Structure (tokens → components → patterns, the Material / Polaris layering): §1 principles, §2 tokens,
§3 components, §4 page patterns, §5 data-viz, §6 copy, §7 accessibility, §8 new-feature checklist.

---

## 1. Principles (short)

1. **One question per screen.** A card that does not serve the screen's question moves or goes.
2. **Compared to you.** Every physiological number sits against the user's own typical range.
3. **No number without its anatomy.** Value · unit · range · delta · verdict · meaning. If we cannot
   fill it, show *why* (empty / calibrating / stale state). A dash is never a valid state.
4. **One fact, one resolver.** A fact is built once, in one view model, and rendered by the Metric*
   components. Views never format numbers or pick verdict words.
5. **Calm by default.** Neutral greys; colour means a metric or a warranted action. No tinted capsule
   chips, no ALL-CAPS overlines, one sentence of copy.
6. **Tokens only.** No hex, no `.system(size:)`, no literal spacing/radius in feature code.

---

## 2. Tokens

Tokens resolve **at draw time** against the active theme (`ZoopTheme.current`: `.classic` /
`.pastel`) and the appearance (light / dark). Views never branch on the theme.

### 2.1 Colour roles (`StrandPalette`)

| Role | Token | Use |
|---|---|---|
| Canvas | `surfaceBase` | Screen background (`.background(StrandPalette.surfaceBase.ignoresSafeArea())`). |
| Card | `surfaceRaised` | Card / tile fill (drawn for you by the card types). |
| Overlay | `surfaceOverlay` | Popovers, raised controls. |
| Inset | `surfaceInset` | Tracks, wells, progress backgrounds. |
| Hairline | `hairline`, `hairlineStrong` | Row separators, outlines, quiet gridlines. |
| Text | `textPrimary` / `textSecondary` / `textTertiary` | Values & titles / meaning sentences / units, dates, captions. |
| Accent | `accent` | **Primary actions, focus, toggles only — never data.** User-selectable. |
| Primary button | `primaryButtonFill` / `primaryButtonText` | Drawn by `ZoopButtonStyle(.primary)`. |
| Status | `statusPositive` / `statusWarning` / `statusCritical` | Only when action is warranted (CONCEPT §1 rule 5). |

**Metric colours (fixed, §7.5)** — set `MetricReadout.tint`, never the colour directly:

| Metric | `Tint` | Resolves to |
|---|---|---|
| Recovery | `.recovery` | Score band: `recovery100` (high) · `recovery055` (medium) · `recovery000` (low) |
| Strain | `.strain` | `effortColor` |
| Sleep | `.sleep` | `metricPurple` |
| Stress | `.stress` | `stressHigh` |
| Fasting | `.fasting` | `metricCyan` |
| Everything else | `.neutral` | `textPrimary` |

A stale readout drops to `textTertiary` automatically. In custom charts use the same token the tint
maps to (e.g. `StrandPalette.metricPurple` for a sleep chart).

**Both themes** define every token for light and dark (`Color(classic:pastel:)`). New tokens go in
`Palette.swift` / `ZoopVisualStyle.swift` with all four hexes; check WCAG AA (4.5:1 body, 3:1 large
text and graphics) for text tokens on `surfaceRaised` in all four looks.

### 2.2 Type (`ZoopType`, §7.1) — the only six sizes

| Token | Classic / Pastel | When |
|---|---|---|
| `ZoopType.display` | 56 bold tabular / 56 semibold rounded | The one hero number on a screen. |
| `ZoopType.title` | `.largeTitle` bold | Navigation large title (normally the system draws it). |
| `ZoopType.metric` | 28 semibold tabular | Tile and row values; empty-state icon. |
| `ZoopType.headline` | `.headline` | Card titles, section headers. |
| `ZoopType.body` | `.body` | The meaning sentence, row labels, explanations. |
| `ZoopType.caption` | `.footnote` | Units, deltas, data age, notes, axis labels. |

All scale with Dynamic Type. `StrandFont` is the legacy scale — do not use it in new code (the Metric*
components still use it internally until migrated). `.font(.system(size:))` is counted by
`Tools/font_lint.py`; the budget only goes down.

### 2.3 Spacing (`ZoopSpacing`, 4-pt grid) and radii (`ZoopRadius`)

| Token | pt | Use |
|---|---|---|
| `xs` | 4 | Label ↔ sub-label, icon ↔ text. |
| `s` | 8 | Section header ↔ its card; inside rows. |
| `m` / `cardGap` | 12 | Between cards; row vertical padding. |
| `l` / `gutter` / `cardPadding` | 16 | Screen side margin; card inner padding. |
| `xl` / `sectionGap` | 24 | Between sections / settings groups. |
| `xxl` | 32 | Bottom scroll room. |

Radii, always `style: .continuous`: `ZoopRadius.card` 24 · `.tile` 18 · `.button` 14. Sheets use the
system radius. Legacy `ZoopMetrics.*` stays valid for its existing call sites; new code uses
`ZoopSpacing` / `ZoopRadius`.

### 2.4 Surfaces & elevation

Flat. One card surface on the canvas (drawn by the four card types), `surfaceInset` for wells. No drop
shadows on data, no glass on content cards, no per-card tint washes. The sky / scenic backgrounds are
Classic-only on the Today hero (§7.6).

### 2.5 Motion (`ZoopMotion`)

| Token | Use |
|---|---|
| `ZoopMotion.screen` | Screen-level transitions. |
| `ZoopMotion.card` | A card appearing / expanding. |
| `ZoopMotion.value` | A number or bar changing. |
| `ZoopMotion.stagger`, `.riseOffset` | Staggered first appearance (`.staggeredAppear(index:)`). |

Always gate: `withAnimation(ZoopMotion.gated(ZoopMotion.value, reduced: reduceMotion)) { … }` with
`@Environment(\.accessibilityReduceMotion)`. Count-up only on the first hero appearance per day
(`CountUpText`); no looping animation on data.

---

## 3. Components

### 3.1 Cards (exactly four, §7.3)

| Type | Purpose |
|---|---|
| `HeroCard { }` | Top of a screen: one `MetricHero` + at most one chart. |
| `ContentCard("Title", showsChevron:) { }` | Any grouped content. Chevron only when the whole card navigates. |
| `ListCard { rows }` | Rows with hairlines (`.listCardRow(isFirst:)`). |
| `TileGrid { MetricTile… }` | 2-up numbers. Custom cells use `.zoopTileSurface()`. |

```swift
VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
    HeroCard { MetricHero(model.recovery) }
    ContentCard("zoop.sleep.tonight.title", showsChevron: true) {
        Text(model.tonightSentence).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
    }
    TileGrid { ForEach(model.vitals) { MetricTile($0) } }
}
```

Do: one hero per screen; header *above* a card via `ZoopSectionHeader`. Don't: nest cards; use
`ZoopCard`, `ChartCard`, `InsightCard`, `StrandCard`, `ZoopPanelSurface`, `FrostedCardSurface` in new
code (being migrated away).

### 3.2 Metric components (anatomy, §1.1)

All take a `MetricReadout` and nothing else; view models build readouts.

```swift
let hrv = MetricReadout(
    id: .hrv, label: "zoop.metric.hrv", value: 62, unit: .milliseconds,
    typicalRange: 48...58, rangeIsPersonal: true, delta: 8,
    verdict: .vital(62, typicalRange: 48...58),        // .typical / .above / .below
    meaning: "zoop.hrv.meaning.above",                 // one sentence, ≤ 90 chars
    confidence: .solid, tint: .neutral)
```

| View | Where |
|---|---|
| `MetricHero(r, compact:)` | Screen top inside `HeroCard`. `compact: true` in rings / narrow cells. |
| `MetricTile(r)` | 2-up `TileGrid`. Meaning becomes the VoiceOver hint. |
| `MetricRow(r)` | Inside `ListCard`; already padded (separate rows with a hairline, not `listCardRow`). |
| `MetricRangeBar(r)` | Band + marker; solid = personal, dashed = population / provisional. |
| `MetricExplainerSheet(r, explanation:)` | Tap target of every number (sheet, `.medium`/`.large`). |

States come from data, not from the view: `confidence: .calibrating(nightsLeft:)`, `.building`,
`.solid`, `.stale(since:)`; no value → `verdict: .unavailable(.calibrating(nightsLeft:))` or
`.unavailable(.noData(since:))` with `value: nil`.

Do: tap any number → explainer. Don't: `Text("\(value) ms")` in a screen (review fails, §1.1).

### 3.3 Buttons (`ZoopButton` / `ZoopButtonStyle`)

```swift
ZoopButton("zoop.fasting.start", systemImage: "play.fill", kind: .primary, fullWidth: true) { model.startFast() }
NavigationLink { DetailView() } label: { Text("zoop.more") }.buttonStyle(ZoopButtonStyle(.secondary))
```

Kinds: `.primary` (one per screen) · `.secondary` · `.tertiary` (inline, low emphasis) ·
`.destructive` (irreversible; confirm first). Height 48, hit target ≥ 44.

### 3.4 Section header (`ZoopSectionHeader`)

```swift
ZoopSectionHeader("zoop.recovery.contributors", subtitle: "zoop.recovery.contributors.note",
                  actionTitle: "zoop.common.all") { router.push(.contributors) }
```

Headline + optional one-line subtitle + optional `text ›` action. Replaces legacy `SectionHeader`
(overline) and blue "see all" links.

### 3.5 States

```swift
// Nothing to show
ZoopEmptyState(systemImage: "moon.zzz", title: "zoop.sleep.empty.title",
               message: "zoop.sleep.empty.message", actionTitle: "zoop.sleep.log") { model.logSleep() }

// Baseline still building (counts come from the engine's confidence)
ZoopCalibratingState(title: "zoop.recovery.calibrating.title", message: "zoop.recovery.calibrating.message",
                     nightsCollected: model.nights,
                     milestones: [.init(nights: 4, title: "zoop.recovery.milestone.first"),
                                  .init(nights: 14, title: "zoop.recovery.milestone.full")],
                     tint: StrandPalette.recovery100)

// Value is old / missing
ZoopStaleNote(.stale(since: model.lastSync), message: "zoop.sync.stale.hint")
```

`style: .plain` puts empty / calibrating states inside a card you already have. All three take
`LocalizedStringKey` or `LocalizedStringResource`.

### 3.6 Settings rows

```swift
ZoopSettingsPage("zoop.settings.units") {
    ZoopSettingsGroup("zoop.settings.display", footer: "zoop.settings.display.footer") {
        ZoopSettingsToggleRow("zoop.settings.clock24", systemImage: "clock", isOn: $use24h, isFirst: true)
        ZoopSettingsRow("zoop.settings.temperature", value: MetricUnit.celsius.symbol(locale: locale))
        ZoopSettingsRow("zoop.settings.weight") { Picker(…) }   // any control
    }
}
```

(The current Settings feature has app-side twins in `SettingsComponents.swift`; new settings-style
pages use the package versions.)

---

## 4. Page patterns

### 4.1 Headers & navigation (§2.3, §2.4)

| Screen | Header |
|---|---|
| Tab root | System large title, actions as trailing toolbar items. No custom header views. |
| Pushed screen | `.zoopPushedScreen(title:)` (app) or the templates below — inline title, content below the bar. |
| Drill-down (score → screen → metric) | **Push**. |
| Create / edit / log | **Sheet** with detents, Cancel + Save in the toolbar. |
| Explainer | **Sheet**, `.medium` + `.large`. |
| Live session | **Full-screen cover**. |

### 4.2 Today-style dashboard

```
HeroCard(MetricHero + one chart)
ZoopSectionHeader → ContentCard / ListCard   (12 between cards, 24 between sections)
TileGrid of MetricTile
```

One question; each fact once. Cards that navigate show `›` and push.

### 4.3 Metric detail screen — `MetricDetailScreen`

```swift
MetricDetailScreen(model.hrv, explanation: model.hrvExplanation,
                   takeaway: "zoop.hrv.trend.takeaway") {
    ZoopSectionHeader("zoop.hrv.related")
    ListCard { ForEach(model.related) { MetricRow($0) } }
}
```

Hero (tap → explainer) · *What it is* · *Your trend* (30 d against the band; empty trend renders a
`ZoopEmptyState`) · your sections. Pass `explanation: nil` to drop the explainer, about and trend.

### 4.4 List / history

`ZoopSectionHeader` per group (e.g. per week) → `ListCard` of rows, newest first. Each row: label left,
value right, `›` if it pushes. Long histories paginate by section, not by infinite card stacks.

### 4.5 Settings page

`ZoopSettingsPage` › `ZoopSettingsGroup` › rows (§3.6). One sentence per footer or note. No
explanatory paragraphs; link to an explainer instead.

### 4.6 Empty / calibrating / stale

| Situation | Show |
|---|---|
| Never had data | `ZoopEmptyState` with what to do. |
| Collecting baseline | `ZoopCalibratingState` (or the hero's `.unavailable(.calibrating)` verdict for one number). |
| Value exists but range is population / settling | The readout's `confidence` (`.calibrating` / `.building`) — the components label it. |
| Old value | `confidence: .stale(since:)` on the readout, or `ZoopStaleNote` under a non-metric block. |
| Sync problem | The single sync status view (§6) — not per card. |

---

## 5. Data-viz rules (§7.4) — Swift Charts only

- Every chart answers **what** (title), **compared to what** (band or reference line) and **so what**
  (one-line takeaway under the chart).
- Band: `ZoopBandMark(x:low:high:color:)` (15 % metric colour). Mean / target: `RuleMark(...).zoopReferenceRule()`.
- Gaps: break the line (separate `series` per segment); > 1 h gap → `ZoopGapMark`. Never interpolate across missing data.
- Axes: `.zoopYAxis(format:)` (≤ 4 labels, trailing, localised formatter) and `.zoopDayXAxis(days:)`
  (weekday letters for 7 d, dates for 30/90 d).
- Units: the axis is in display units; format ticks with `MetricUnit.axisLabel(_:locale:)` or
  `ZoopNumber`. Units in the title or caption, not on every tick.
- Colour: the metric's colour for data, `textTertiary` for axes, `hairline` for grids. No rainbow.
- Selection: `zoopScrubRule()` + a pinned value / verdict / date readout, not a floating tooltip.
- Accessibility: `.accessibilityLabel` on the chart; `AXChartDescriptor` for custom canvases.

```swift
Chart {
    ForEach(days) { ZoopBandMark(x: .value("Day", $0.date), low: band.lowerBound, high: band.upperBound,
                                 color: StrandPalette.metricPurple) }
    RuleMark(y: .value("Typical", mean)).zoopReferenceRule()
    ForEach(days) { LineMark(x: .value("Day", $0.date), y: .value("HRV", $0.value), series: .value("Seg", $0.segment))
        .foregroundStyle(StrandPalette.metricPurple) }
}
.zoopYAxis { ZoopNumber.decimal($0, digits: 0) }
.zoopDayXAxis(days: 30)
```

---

## 6. Copy rules

- **German-first.** Write the DE string first, then EN. All user strings live in the catalogue under
  Zoop keys (`zoop.<feature>.<thing>`); never rename legacy NOOP keys in passing.
- **One sentence**, second person, ≤ 90 characters, no hedging stack ("may possibly"). No ALL CAPS.
- **Verdicts only from the closed vocabulary** (`MetricVerdict`): Typisch · Über / Unter deinem Bereich;
  Hoch · Mittel · Niedrig; Erholsam · Aufbauend · Fordernd · Überlastend; Kalibriert · Noch N Nächte ·
  Keine Daten seit …. Never free text.
- **Numbers**: metric values via `MetricUnit` inside the Metric* components; any other user-visible
  number via `ZoopNumber.decimal/signed/percent` (app) or `FormatStyle` with the view's locale. Never
  `String(format:)` for UI (keep it for logs). Durations via `MetricUnit.duration` /
  `Duration.formatted` ("7 Std. 43 Min." / "7h 43m").
- Units are always shown, except unitless 0–100 scores.

---

## 7. Accessibility

- **Dynamic Type:** only `ZoopType`; `@ScaledMetric` for any size a layout depends on; let text wrap
  (`.fixedSize(horizontal: false, vertical: true)`); switch HStack → VStack at
  `dynamicTypeSize.isAccessibilitySize` (see `MetricRow`). Test at AX3 in the gallery or previews.
- **VoiceOver:** Metric* components combine into one element: label → "value, verdict", meaning as
  hint, delta / range in the More Content rotor. Decorative icons `.accessibilityHidden(true)`;
  headers `.accessibilityAddTraits(.isHeader)` (the templates do this).
- **Contrast:** text tokens meet AA on `surfaceRaised` in all four looks; never encode meaning by
  colour alone (verdict word always present).
- **Reduce Motion:** `ZoopMotion.gated(…, reduced:)`; static fallbacks for count-ups and rings.
- **Targets:** ≥ 44 × 44 pt; use `.contentShape(Rectangle())` on rows.

---

## 8. New-feature checklist

- [ ] Screen answers one question; placed per CONCEPT §2.2; push vs sheet per §4.1.
- [ ] Files in `Strand/Features/<Feature>/` (`Screen`, `Model`, `Explanations`, `Components/`);
      ≤ 400 lines per file, ≤ 40 lines per `body`.
- [ ] Every number is a `MetricReadout` built in the model and rendered by a Metric* view;
      tapping it opens `MetricExplainerSheet`.
- [ ] Empty, calibrating, provisional, stale states handled with the templates (no dashes, no blanks).
- [ ] Only `StrandPalette` / `ZoopType` / `ZoopSpacing` / `ZoopRadius` / `ZoopMotion`; no hex,
      no `.system(size:)`, no literal paddings.
- [ ] Only the four card types; `ZoopSectionHeader` for section labels.
- [ ] Charts follow §5 (band / rule, takeaway, ≤ 4 y-labels, gaps broken).
- [ ] Strings in the catalogue (DE + EN), one sentence, verdict vocabulary.
- [ ] Dynamic Type AX3, VoiceOver pass, Reduce Motion, both themes × both appearances checked
      (Design gallery for components, simulator for the screen).
- [ ] Model unit-tested for calibrating / provisional / solid / stale / empty readouts.
- [ ] `swift build` for touched packages + `xcodebuild -scheme ZoopiOS -destination 'generic/platform=iOS Simulator' build`;
      DE + EN screenshots in the PR.
