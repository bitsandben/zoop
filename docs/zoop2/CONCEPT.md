# Zoop 2.0 — Product & UX Concept

Status: proposal for implementation · Scope: iOS (`ZoopiOS`, widgets, watch) · Owner: product/UX
Constraints inherited unchanged: [AGENTS.md](../../AGENTS.md), [CLAUDE.md](../../CLAUDE.md),
[SCOPE.md](../SCOPE.md) — offline, on-device, anonymous, not a medical device, no strap-protocol
changes without hardware validation.

This document is decision-oriented. Where it says **Decision**, implement it as written; where it says
**Open**, the owner decides before the work package starts.

---

## 0. Diagnosis — why the app does not feel high quality yet

Observed in code and in the simulator (`--demo-seed`, German locale):

1. **Too many surfaces for the same fact.** Four readiness reads (`RecoveryScorer`, `ReadinessEngine`,
   `HRVReadiness`, `WatchRecovery`), four stress definitions (`StressIndex`, `DaytimeStress`,
   `StressOnsetDetector`, the view-layer daily score + `AppModel.evaluateStress`), three illness paths
   (`IllnessSignalEngine`, `IllnessDistance`, `AppModel.evaluateIllness`), two "age" numbers
   (`FitnessAgeEngine`, `VitalityEngine`), two training-load models (ACWR and CTL/ATL). A user can see
   two verdicts that disagree. This violates the AGENTS.md rule "two readouts of one fact must not be
   able to disagree".
2. **Duplicated and orphaned screens.** `HealthView` repeats the Insights tab's vitals/skin-temp/sync
   cards; `TodayView` (5,981 lines) lives on behind a toggle; `InsightsView`, `IntelligenceView`,
   `PatternsScreen` are unreachable; 17 of ~30 `MoreDestination` cases are unused.
3. **No home for the most important score.** The Recovery ring opens a generic `MetricDetailView`.
4. **Numbers without context.** Home shows "Schritte –", "Kalorien – / Ø 604 kcal", "75.0 kg aus dem
   Profil" (decimal point in a German UI, next to "25,5" with a comma). A dash, a profile constant and a
   measured value look identical.
5. **Header chaos.** Pushed screens (`StressView`, `FitnessAgeScreen`) draw their own 30 pt title
   under an empty transparent system bar; the title and the "Jetzt" label scroll under the floating back
   button. Three section-header styles (`SectionHeader`, `HomeSectionTitle`, `sectionHead("…")`),
   ~420 hard-coded `.font(.system(size:))` calls, seven card surfaces (`ZoopCard`, `ZoopPanelSurface`,
   `StatTile`, `StrandCard`, `ChartCard`, `InsightCard`, `FrostedCardSurface`).
6. **Settings as a junk drawer.** 24 toggles, developer controls (R22 flags, raw CSV, BLE rename)
   next to "Appearance", Backup and Test Centre reachable from two places, Coach switch under Appearance.
7. **Giant files.** `LiquidTodayView` 4,264, `SettingsView` 3,676, `SleepView` 3,518, `WorkoutsView`
   2,221 lines — logic and layout are mixed, which is why every change regresses something else.

The fix is not more features. It is **one model per fact, one screen per question, one component per
kind of number.**

---

## 1. Product principles

1. **One question per screen.** Today answers "how ready am I and what should I do today?", Sleep
   answers "how did I sleep and what do I need tonight?", Recovery "why is my score what it is?". A card
   that does not serve the screen's question moves or goes.
2. **Compared to you, not to the population.** Every physiological number is shown against the user's
   own typical range (Apple Vitals / Oura pattern). Population norms only fill the gap while calibrating
   and are labelled as such.
3. **The explainability contract.** No number appears without its anatomy (§1.1). If we cannot fill
   the anatomy (no baseline, no data), we show *why* instead of a number. A dash is never a valid state.
4. **One fact, one resolver.** Each user-visible fact (Recovery, Strain, Sleep score, Stress level,
   Sleep need, Illness signal, Fitness age) has exactly one engine and one view model. Experimental
   alternatives may log beside it in Test Centre but never render on a user screen.
5. **Calm by default.** No alert for a single outlier (Vitals rule: ≥2 signals out of range). No red
   unless action is warranted. Sync, calibration and gaps are reported in one place, in plain language.
6. **Learns from you, visibly.** Check-ins and journal answers re-weight models (already true for
   `RecoveryCalibration`); the explainer says so ("Your check-ins lowered the weight of skin temperature").
7. **Native, fast, quiet code.** SwiftUI + Swift Charts, no logic in views, files < 400 lines, every
   engine pure and unit-tested in `Packages/`.

### 1.1 Metric anatomy (the standard every number follows)

```
┌──────────────────────────────────────────────┐
│ HRV                                   ⓘ     │  label (+ info affordance)
│ 62 ms        ▲ 8 ms vs. typical              │  value · unit · delta
│ ├────[■■■■■■■|■■■]────┤ ●                    │  typical-range band + today marker
│ Above your range                             │  verdict word(s)
│ Your nervous system recovered well overnight.│  one-sentence meaning
└──────────────────────────────────────────────┘
          tap → Explainer sheet
```

| Element | Rule |
|---|---|
| **Value** | Localised number (`FormatStyle`, never `String(format:)`), tabular digits. |
| **Unit** | Always shown; omitted only for 0–100 scores (then "%" for Recovery, nothing for Sleep score). |
| **Baseline / typical range** | Personal range = robust mean ± 1 SD-equivalent from `Baselines` (EWMA, 14-night half-life). During calibration: population range, dashed band, label "Population range — personal range in N nights". |
| **Delta** | vs. typical (default) or vs. yesterday (only for cumulative counts like steps). Sign + unit, arrow only when |delta| exceeds the smallest worthwhile change (0.5 SD). |
| **Verdict word** | From a closed vocabulary per metric kind (below). Never free text. |
| **Meaning** | One sentence, ≤ 90 chars, second person, no hedging stack ("may possibly"). Generated from a template keyed by (metric, verdict), not by an LLM. |
| **Explainer (tap)** | Sheet with: *What it is* (2 sentences) · *How we compute it* (method name + one line + citation) · *Data used* (nights/samples, time window, source strap) · *Confidence* (Calibrating / Building / Solid from `ScoreConfidence`, with the reason) · *Your trend* (30-day chart with band) · *What moves it* (top contributors, personal if available). |

**Verdict vocabulary** (DE / EN, closed sets):

| Kind | Words |
|---|---|
| Vital vs. range | Typisch · Über deinem Bereich · Unter deinem Bereich (Typical · Above your range · Below your range) |
| Score 0–100 | Hoch (67–100) · Mittel (34–66) · Niedrig (0–33) — colours green/amber/red, WHOOP-compatible bands |
| Load | Erholsam · Aufbauend · Fordernd · Überlastend (Restorative · Building · Demanding · Overreaching) |
| Data state | Kalibriert · Noch N Nächte · Keine Daten seit <Zeit> (Calibrated · N more nights · No data since …) |

**Component spec** (`Packages/StrandDesign`, pure SwiftUI, no app imports):

```swift
public struct MetricReadout: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable { case typical, above, below, score(ScoreBand), load(LoadBand), unavailable(Reason) }
    public enum Confidence: Sendable { case calibrating(nightsLeft: Int), building, solid }
    public let id: MetricID            // stable key, also the explainer route
    public let label: LocalizedStringResource
    public let value: Double?          // nil only together with .unavailable
    public let unit: MetricUnit        // formats value + delta (localised)
    public let typicalRange: ClosedRange<Double>?
    public let rangeIsPersonal: Bool
    public let delta: Double?
    public let verdict: Verdict
    public let meaning: LocalizedStringResource
    public let confidence: Confidence
}
```

Views (all take a `MetricReadout`, nothing else): `MetricHero` (screen top), `MetricTile` (2-up grid),
`MetricRow` (list), `MetricRangeBar` (band + marker), `MetricExplainerSheet` (takes readout +
`MetricExplanation` value with method/data/contributors/trend). Readouts are built in view models only.
**Acceptance test for any screen:** grep for `Text(` with a numeric interpolation outside these
components fails review.

---

## 2. Information architecture

### 2.1 Tabs — Decision

```
┌─────────┬──────────┬──────────┬──────────┐   + Coach accessory (only if Coach enabled)
│  Heute  │  Körper  │ Training │   Ich    │
│  Today  │   Body   │ Training │    Me    │
└─────────┴──────────┴──────────┴──────────┘
```

| Tab | Question it answers | Root | Replaces |
|---|---|---|---|
| **Heute / Today** | How ready am I, what is today's plan, what's happening now? | `TodayScreen` | `LiquidTodayView` (rebuilt), `TodayView` (deleted) |
| **Körper / Body** | How is my body doing over time? Dashboards per system. | `BodyScreen` | `TrendsView(asInsightsTab:)`, `HealthView`, `InsightsHubView` entry, `MetricExplorerView` entry |
| **Training** | What did I do, how loaded am I, what should I train? | `TrainingScreen` | `WorkoutsView(asTrainingTab:)` |
| **Ich / Me** | My strap, my profile & goals, my logs, settings. | `MeScreen` | "Mehr" list, `MoreDeviceHeader` |

Labels visible (icon + text). Icon-only tab bars fail HIG legibility; the current icon-only bar is
dropped. Coach stays a floating accessory **only when the user enabled Coach** (BYO-key); otherwise no
sparkle button.

### 2.2 Screen map (what belongs where)

```
Heute ─┬─ Recovery  (push)   ← NEW dedicated screen
       ├─ Sleep     (push)
       ├─ Strain    (push → same as Training › Load detail)
       ├─ Stress    (push)
       ├─ Fasting   (push)   ← NEW
       ├─ Energy Bank (push, optional card, see §4.2)
       └─ Sleep planner / alarms (push from Sleep tonight card)
Körper ─┬─ Vitals dashboard (HRV, RHR, resp., SpO2, skin temp) → Metric detail (push)
        ├─ Sleep trends → Sleep (push, range = 30 d)
        ├─ Fitness age (push)
        ├─ Cycle (push, if enabled)
        ├─ Patterns & habits (merged InsightsHubView + PatternsScreen + BodyInsightsSection)
        └─ All metrics (MetricExplorerView)
Training ┬─ Workout detail (push, not sheet)
         ├─ Load detail (CTL/ATL)
         ├─ Lift log / programs
         └─ Start workout (full-screen cover)
Ich ─┬─ Strap & sync (DevicesView, sync log)  ← single home for connection state
     ├─ Profile & goals
     ├─ Logbook (journal + check-ins history)
     ├─ Fasting plan
     ├─ Data (Apple Health, import, backup, export)
     ├─ Settings (simplified, §3.9)
     └─ About & limitations
```

**Delete** (after migrating anything valuable): `TodayView.swift`, `InsightsView.swift`,
`IntelligenceView.swift`, `HealthView` as a screen (its sections move into Body), unused
`MoreDestination` cases, `MoreSectionPrefs.swift`, `zoop.liquidTodayEnabled` toggle, `HomePatternsCarousel`,
macOS-only `TrainingLoadCard` usage on iOS paths, `CoachView` iOS ≤17 tab path (iOS 17 gets the sheet).

**Merge:** `HealthView` + `InsightsVitalsBlock` → Body › Vitals. `InsightsHubView` + `PatternsScreen` +
`BodyInsightsSection` + `HabitEffectsCard` → Body › Patterns. `SmartAlarmView` → `SleepPlannerScreen`
(already the iOS path). `SyncStatusSection` (Health/Insights) + `LiquidSyncStatusRow` + `LiquidStrapBatteryRow`
+ `MoreDeviceHeader` → one `SyncStatusView` (§6). `Compare`, `Rhythm`, `LabBook`, `FusedRecord` → Ich ›
Data › Tools (power-user corner, not top level).

### 2.3 Navigation rules

| Situation | Pattern |
|---|---|
| Drill into more detail of the same thing (score → screen → metric) | **Push** within the tab's `NavigationStack`. |
| Create / edit / log something (workout, nap, journal, check-in, fasting edit) | **Sheet** with detents; Cancel + Save in toolbar. |
| Explainer for a number | **Sheet**, `.medium` + `.large` detents. |
| Live session (workout, breathing, live HR) | **Full-screen cover** + Live Activity. |
| Cross-tab jump (e.g. widget deep link) | `NavRouter` selects tab, then pushes; never presents a pushed screen as a sheet. |

Workout detail moves from sheet to push (it is reading, not editing).

### 2.4 Header rules — Decision

1. **Tab roots:** system large title (`.navigationTitle` + `.navigationBarTitleDisplayMode(.large)`),
   trailing toolbar items for actions. No custom header views, no hidden navigation bar. The day picker
   on Today lives in the toolbar as a principal item, not in-content.
2. **Pushed screens:** `.navigationTitle(title)` + `.inline` display mode. Hero content starts **below**
   the bar (`safeAreaInset`), never under it. A full-bleed background is allowed via
   `.toolbarBackground(.hidden)` **only** when the hero has ≥ 56 pt clear space at its top.
3. **Section labels** inside a screen use one component, `SectionHeader(title:, action:)`; no
   overline-caps duplicated inside the card ("HERZFREQUENZ" + "SCHLÄGE PRO MINUTE" becomes one header).
4. `ScreenScaffold` loses its in-content title parameter; it becomes padding + background only.

**Stress fix (concrete):** `StressView` sets `.navigationTitle("Stress")`, inline; remove the scaffold
title; `StressDayHero`'s "Jetzt" label becomes the hero's `MetricHero` label "Jetzt · 14:20" with top
padding inside the safe area. Same treatment for `FitnessAgeScreen`, `EnergyBankScreen`, `CycleScreen`,
`SleepPlannerScreen` and every `TabRoute` destination — enforced in `tabRouteDestinations()` with a
shared `.zoopPushedScreen(title:)` modifier.

---

## 3. Screen blueprints

Conventions: `[ ]` card, `( )` button, `›` push, `ⓘ` explainer sheet. Widths are schematic.

### 3.1 Today (Heute)

Purpose: the morning answer + the day so far. Max 7 cards on first launch; user can hide, not add new kinds.

```
Heute                       ‹ Di 14. Okt ›   (avatar)
┌──────────────────────────────────────────────┐
│ Sync: vor 4 Min · Akku 62 %                  │  status line (only text; tap › Strap & sync)
└──────────────────────────────────────────────┘
┌──────────────────────────────────────────────┐
│   ◯ Erholung     ◯ Belastung    ◯ Schlaf     │  three rings, value inside
│     78 %           9,4 / 14       91 %       │  (strain shows target)
│     Hoch           Aufbauend      Hoch       │  verdict words
│ Gut erholt: heute ist ein harter Tag drin.   │  ONE synthesis sentence
└──────────────────────────────────────────────┘
  each ring › Recovery / Strain / Sleep
[ Empfehlung heute ]                              derived from Recovery + load
  Belastungsziel 12–14 · Schlafbedarf heute 8:05 · Bettzeit 22:40
[ Jetzt ]  ─ Stress 1,2/3 Ruhig · Energie 64 · HF 58   › Stress / Energy
[ Fasten ]  ─ 13:20 von 16:00 ▓▓▓▓▓▓▓░░  (Stop)       only if fasting enabled
[ Mein Tag ] timeline: Schlaf 23:05–6:48 · Lauf 7:30 (8,1) · Nickerchen …   (+)
[ Signale ]  only when ≥2 vitals out of range (§5.7); else hidden
[ Check-in ] only until answered today (1 tap, 1–5)
```

Removed from Today: Fitness-age card (→ Body), "Mein Dashboard" metric list (→ Body), live HR chart
(→ Stress "Jetzt" / Body › HR), weekly trends (→ Body), health/stress monitor tiles (replaced by
"Jetzt"), `HealthAlertBanner` (→ "Signale" card), strap battery/sync rows (→ status line),
calibration invite (→ inline in Recovery hero while calibrating).

### 3.2 Recovery (new screen)

```
‹ Heute            Erholung
┌──────────────────────────────────────────────┐
│ 78 %  Hoch                       ⓘ          │  MetricHero
│ ├────────[ typical 52–74 ]──●┤               │
│ HRV und Ruhepuls liegen über deinem Normal.  │
│ Confidence: Solid · 42 Nächte                │
└──────────────────────────────────────────────┘
Was hat beigetragen (contributors, Oura pattern, sorted by impact)
[ HRV          62 ms   Über deinem Bereich   +++ ]  › metric
[ Ruhepuls     51 bpm  Typisch               +   ]
[ Schlaf       91 %    Hoch                  ++  ]
[ Atemfrequenz 14,1    Typisch               0   ]
[ Hauttemp.    +0,1 °C Typisch               0   ]
[ Gestern Belastung 15,2 Fordernd            −   ]
[ Check-in     4/5                           +   ]  only if calibration on
[ 30 Tage ] bar chart, colour by band, dashed line = personal mean
[ Morgen (Prognose) ] 70–78 % if you sleep 8 h and keep strain < 12   (RecoveryForecast, band shown)
[ Personalisierung ] "Deine Check-ins gewichten Hauttemperatur 20 % niedriger." › RecoveryCalibrationView
```

### 3.3 Sleep

```
‹ Heute            Schlaf          ‹ Nacht 13.→14. ›
[ Hero ] 7:43 geschlafen · 91 % Hoch · Bedarf 8:05 (−22 Min)    ⓘ
[ Hypnogramm ] stages over time, wake bars, HR line overlay toggle
[ Phasen ] Tief 1:32 · REM 1:48 · Leicht 4:03 · Wach 0:21 — each vs. typical range (MetricRow)
[ Schlafschuld ] 1:10 · trend 7 Tage · "Eine Stunde früher ins Bett für 3 Nächte" (SleepDebt)
[ Regelmäßigkeit ] SRI 82 · midpoint 3:10 ± 25 min · chronotype (CircadianEngine)
[ Nachtwerte ] HRV · Ruhepuls · Atmung · SpO2 · Hauttemp (MetricTiles, 2-up)
[ Heute Nacht ] Bettzeit 22:40 · Wecker 6:45 (Smart-Fenster 30 Min)  › Sleep planner
[ Was deine Nächte zeigen ] max 2 insights from SleepInsights, only if significant
```

Cut from Sleep: `StagesVsTypicalCard` (folded into Phasen rows), `AsleepDurationCard` and
`HoursVsNeededCard` (folded into hero), `SleepFactorGrid` (contributors live in hero explainer),
body-clock dial (→ Regelmäßigkeit card), reorderable sections (fixed order; hide only).

### 3.4 Strain / Training

```
Training                                      (Start ▶)
[ Belastung heute ] 9,4 / Ziel 12–14 · Aufbauend · ring + target arc     ⓘ
[ Fitness & Ermüdung ] 6-week chart: Fitness (CTL, 42 d) line, Fatigue (ATL, 7 d) line,
                       Form = CTL − ATL as band; verdict "Aufbauend"
[ Diese Woche ] Mo–So bars (strain), zone minutes stacked, sessions count
[ Muskulär ] body map (MuscleLoad), sets this week vs. 4-week norm — only if lifts logged
[ Einheiten ] list, newest first › Workout detail (push)
[ Kraft ] Lift log · Programme  ›
```

Workout detail: header (sport, time, duration, strain + verdict), HR chart with zone bands, zone minutes,
calories (method in ⓘ), HR recovery 1 min, route map if GPS, "Erholung am nächsten Morgen" (from
`ActivityCostEngine`, only with ≥4 sessions of that sport).

Cut: `TrainingCalendarCard` at top (→ week strip), 13-week calories heatmap, `CumulativeTotalCard`,
"Recovery Trend" (lives on Recovery), ACWR anywhere (see §5.3).

### 3.5 Stress

```
‹ Heute            Stress
[ Jetzt · 14:20 ] 1,2 / 3  Ruhig       ⓘ
  day curve 0–3 with activity-masked gaps (hatched = workout, grey = no data)
[ Heute ] Zeit ruhig 9:10 · mittel 2:40 · hoch 0:35 — vs. typical
[ Muster ] "Deine stressigsten Stunden: Mo–Fr 10–12 Uhr" (≥14 days)
[ Atmen ] (Start 2-Min-Atemübung)  → full-screen BreathingView
[ 30 Tage ] daily stress average with band
```

The breathing nudge from `StressOnsetDetector` asks one question after the session: "Warst du
gestresst? Ja / Nein" — the missing label that tunes the detector (§5.5).

### 3.6 Body (Körper) dashboard

```
Körper                                       (Zeitraum: 7T · 30T · 90T)
[ Vitalwerte ]  5 MetricTiles, each with band sparkline:
   HRV · Ruhepuls · Atemfrequenz · SpO2 · Hauttemp.
[ Schlaf ]  avg duration vs. need, SRI, debt — › Sleep (range)
[ Fitness ] Fitnessalter 25,5 (±3) · VO2max-Schätzung 47 — › Fitness age
[ Aktivität ] Schritte (est.) · aktive kcal · Zonenminuten/Woche vs. 150 min WHO
[ Zyklus ] (if enabled) phase + next window — › Cycle
[ Muster & Gewohnheiten ] top 3 significant effects ("Alkohol: −9 % Erholung, n=14") › Patterns
[ Alle Metriken ] › MetricExplorerView
```

Each tile = `MetricTile` with personal band. No tile renders "–": missing data renders the
`.unavailable(reason)` state ("Noch 3 Nächte", "Kein SpO2 am WHOOP 4.0").

### 3.7 Fitness age

```
‹ Körper           Fitnessalter
[ Hero ] 25,5 Jahre · 4,5 jünger als dein Alter (30)   ±3 J   ⓘ
         dial: chronological age tick + fitness age needle
[ Was es formt ] Ruhepuls 51 (−) · Aktivität 4,1 h/Woche Zone 2+ (−) · BMI 23,1 (0)
                 each row: "−1,8 J" contribution, sparkline
[ Hebel ] "+30 Min Zone-2 pro Woche ≈ −0,6 J in 8 Wochen" (from model gradient, labelled estimate)
[ 90 Tage ] weekly points with ± band
[ Methode ] Nes et al. 2011 (HUNT) non-exercise VO2peak, inverted to age …
```

**Decision:** Vitality age (`VitalityEngine`) is removed from user screens; one age number only.

### 3.8 Fasting (new)

```
‹ Heute            Fasten
[ Timer ] ◯ ring 13:20 / 16:00  · seit 20:10 · Ziel 12:10    (Beenden)
          phase labels on ring: 12 h · 16 h · 18 h (time markers, NOT metabolic claims)
[ Plan ] 16:8 · Essfenster 12:10–20:10 · (Ändern)
[ Diese Woche ] 7 bars: fasted hours vs. goal, ✓ days
[ Und dein Körper? ] (≥ 14 logged fasts)
   "An Fastentagen: Ruhepuls nachts −1,4 bpm, HRV +3 ms vs. Nicht-Fasten (n=9/12, nicht signifikant)"
   from BehaviorInsights; always shows n and significance.
[ Was der Strap nicht misst ] Blutzucker, Ketone, Insulin — one-line footnote, ⓘ
```

Start/stop also from: Today card, Live Activity, lock-screen widget button (App Intent), Siri
("Fasten starten"). Last meal can be backdated in the stop/start sheet.

### 3.9 Settings (simplified)

Settings opens from Ich. Three levels max. Every toggle answers "would a normal user change this?" —
if not, it moves to **Advanced** or is deleted.

```
Einstellungen
  Profil & Ziele      Name, Geburtsdatum, Geschlecht, Größe, Gewicht, Einheiten,
                      Schlafziel (auto/manual), Trainingsziel, HF-Zonen (auto/manual)
  Strap               Gerät, Synchronisierung, Energiesparen, Wecker
  Benachrichtigungen  Morgen-Zusammenfassung · Schlafenszeit · Fasten · Akku · Atem-Hinweis
  Darstellung         Theme (Klassisch / Pastell & Natur) · App-Icon · Bewegung reduzieren
  Funktionen          Fasten · Zyklus · Coach (BYO-Key) · Morgen-Check-in · Journal
  Daten               Apple Health · Import · Backup & Wiederherstellen · Export · Speicher
  Erweitert           Test Centre, Experimente (Sleep v1, SpO2, Oura, alarm-anchored wake),
                      Diagnose, Rohdaten, Strap-Log, Self-hosted push
  Über                Version, Lizenz, Grenzen von Zoop, Danksagungen
```

Delete toggles: background image, sky behind cards, transparent cards, day-cycle sky (→ part of theme),
hide tab bar on scroll, Liquid Today, Banister vs Edwards (→ Advanced). Developer-only controls (R22
flags, BLE rename, optical-experiment markers) → Advanced › Test Centre only.

### 3.10 Onboarding

Principles: ≤ 9 screens, one decision per screen, permissions at point of need (HIG), every screen has
"Später" except device selection. Terms gate stays first (legal) but becomes one screen.

```
1 Willkommen      "Deine WHOOP-Daten. Auf deinem iPhone. Ohne Konto."   (Los geht's)
2 Hinweise        Terms + "Kein Medizinprodukt" — 2 checkboxes           (Akzeptieren)
3 Gerät wählen    [ WHOOP 5.0 / MG ] [ WHOOP 4.0 ] [ Anderes HF-Gerät ] [ Ohne Gerät (Demo) ]
                  images = neutral line drawings, no WHOOP assets
4 Bluetooth       why → system prompt on button tap
5 Koppeln         "Strap ans Handgelenk, Doppeltipp/Ladegerät…" (model-specific) → scan list
                  → bonded ✓ (strap name, battery, firmware)
6 Über dich       birth date, sex, height, weight (one screen, wheel pickers, units auto from locale)
7 Ziele           Schlafziel (auto 8 h / custom) · Fokus: Erholung / Ausdauer / Kraft / Gewicht
                  · Fasten? (aus / 14:10 / 16:8 / 18:6 / eigenes)
8 Erste Sync      progress bar with honest ETA ("~4 Min für 3 Tage Verlauf"), can leave
                  Optional: import WHOOP export / Apple Health (seeds baselines)
9 Was dich erwartet  calibration timeline:
                  Tag 1 Belastung, Herzfrequenz, Schlaf
                  Nacht 4 erste Erholung (vorläufig)
                  Nacht 14 persönliche Bereiche stabil
                  Tag 28 Check-ins personalisieren deine Erholung
                  (Fertig) → Today; notifications asked later at first bedtime reminder
```

`AddDeviceWizard` (from Ich › Strap) reuses steps 3–5 as the same views. Removed from onboarding:
appearance step (default theme, change later), notifications step (point of need), "what" and
"expectations" merged into 1/2/9.

---

## 4. Widgets, Live Activities, card catalogue

### 4.1 System surfaces

| Surface | Content | Deep link |
|---|---|---|
| Lock `accessoryCircular` | Recovery % gauge | `zoop://recovery` |
| Lock `accessoryCircular` | Fasting progress (when active) | `zoop://fasting` |
| Lock `accessoryRectangular` | Recovery · Strain · Sleep, three numbers + verdict | `zoop://today` |
| Lock `accessoryInline` | "78 % Erholung · 7:43 Schlaf" | `zoop://today` |
| Home `systemSmall` | Recovery ring + verdict | `zoop://recovery` |
| Home `systemSmall` | Fasting timer + start/stop button (App Intent) | `zoop://fasting` |
| Home `systemMedium` | Three rings + synthesis sentence + last sync time | `zoop://today` |
| Home `systemLarge` | Rings + 7-day recovery bars + tonight's bedtime | `zoop://today` |
| **Live Activity** | Workout: elapsed, HR, zone, strain | `zoop://workout` |
| **Live Activity** | Fasting: elapsed / goal (≤ 8 h active + 4 h lock screen per Apple limit; restart at end of window or fall back to widget for 16 h+ fasts) | `zoop://fasting` |
| **Live Activity** | Sync of large backlog (> 2 min) | `zoop://sync` |

Drop: `CoachBriefWidget` (depends on Coach, which is opt-in), `StressWidget` medium (stress is noisy
in a widget; keep it in-app), `HeartRateWidget` (cannot be live; misleading staleness). Every widget
shows data age when > 2 h ("vor 5 Std").

**Sideload constraint.** `Tools/build-ipa.sh:34-36` strips `PlugIns/ZoopWidgets.appex` and the watch
app. Widgets and Live Activities (which need a widget extension for presentation) require:
1. An App Group entitlement and extension bundle id provisioned by SideStore/AltStore. SideStore
   rewrites bundle ids and app groups; extensions are supported but each consumes an App-ID slot
   (free account: 10 App IDs / 7 days, 3 apps).
2. Keep the extension; make `build-ipa.sh` take a flag `--with-widgets` (default on) and verify
   SideStore re-signs the appex group id consistently with the app (`group.$(BUNDLE_ID_PREFIX).zoop.staging`).
3. Fallback when the group is unavailable: `WidgetPublish` detects a nil container URL and the widget
   shows "Öffne Zoop einmal" rather than stale data.
**Open:** owner validates on a real SideStore install (WP-13) before widgets are promised.

### 4.2 In-app card catalogue

| Card (current) | Decision | Where |
|---|---|---|
| Rings Schlaf/Erholung/Belastung | **Keep**, add verdict words + synthesis line | Today |
| `HomeMonitorTiles` (Health, Stress) | **Merge** → "Jetzt" card | Today |
| Energy Bank (`EnergyBankViews`) | **Keep as opt-in** (Settings › Funktionen), default off; explainer states "heuristic, not validated" | Today › Jetzt |
| `RecoveryCalibrationInviteCard` | **Merge** into Recovery hero while calibrating | Recovery |
| My Day / `HomeMomentCard` / activities | **Keep** as timeline | Today |
| `HomeCycleCard` | **Move** | Body |
| Mein Dashboard key-metric grid | **Move** → Vitals tiles | Body |
| `HomeFitnessAgeCard` | **Move** | Body |
| Live HR card | **Merge** into Stress "Jetzt" curve / Metric detail HR | Stress |
| Weekly Trends (Recovery, HRV) | **Drop** (duplicate of Recovery 30 d / Body) | — |
| `JournalReminderCard` | **Merge** with morning check-in → one Check-in card | Today |
| `HealthAlertBanner` | **Replace** by Signale card (≥2 signals rule) | Today |
| `SleepDebtLedgerCard` | **Keep**, simplified | Sleep |
| `StagesVsTypicalCard`, `AsleepDurationCard`, `HoursVsNeededCard`, `SleepFactorGrid` | **Merge** | Sleep hero / Phasen |
| `BodyClockDialCard` | **Merge** into Regelmäßigkeit | Sleep |
| `SleepInsightsSection` | **Keep**, max 2 cards | Sleep |
| `TrainingLoadGaugeRow` (cardio + muscular) | **Replace** by Fitness & Ermüdung + Muskulär | Training |
| Calories heatmap, `CumulativeTotalCard` | **Drop** | — |
| `MuscleLoadCard` | **Keep** (only with lift data) | Training |
| `BodyInsightsSection`, `HabitEffectsCard`, `PatternsScreen` | **Merge** → Patterns | Body |
| `TrendViewerCard`, year heat strip, "Daily signals" | **Drop** (metric detail covers it) | — |
| Export report | **Move** | Ich › Daten |
| `SyncStatusSection` (×2), `LiquidSyncStatusRow`, `LiquidStrapBatteryRow`, `MoreDeviceHeader` | **Merge** → `SyncStatusView` | Ich › Strap, Today status line |
| `CaffeineLogCard`, `HydrationView` | **Keep as opt-in** Funktionen; hydration goal shown as "Richtwert" | Today timeline |

---

## 5. Algorithms & personalisation

Shared foundation stays: `Baselines.swift` — EWMA (half-life 14 nights), robust spread, outlier clamp
3×/drop 5×, states calibrating (<4) / provisional (4–13) / trusted (≥14) / stale (>14 d gap). This is a
sound, defensible base; every user-facing range comes from it.

### 5.1 Inventory → decision

| Fact | Current engines | Decision | Method (researched) |
|---|---|---|---|
| **Recovery** | `RecoveryScorer` (live), `ReadinessEngine`, `HRVReadiness`, `WatchRecovery`, `ChargeBaselines`, `RecoveryCalibration` | **Keep `RecoveryScorer` as the single resolver.** Fold `HRVReadiness`'s ln-RMSSD 7-vs-60 SWC as the HRV *trend* contributor (not a second score). `ReadinessEngine` → delete from UI; keep only its monotony calc if Training needs it. `WatchRecovery` → Test Centre only. | Weighted robust z (HRV .55, RHR .20, sleep .15, resp .05, temp .05) → logistic, z=0→58. HRV-guided practice: ln rMSSD rolling 7 d vs SWC ±0.5 SD (Plews 2012/2013; Kiviniemi 2007). Score fixed once per morning after the main sleep (Athlytic pattern). |
| **Strain** | `StrainScorer` | **Keep.** Show the strain *target* (from Recovery band + CTL) on Today. Move steps/kcal floor to explainer ("minimum from steps"). | Karvonen %HRR → Edwards zone TRIMP (default) → log scale 0–21 (Edwards 1993; Banister 1991). |
| **Training load** | `TrainingLoadEngine` (CTL/ATL), `ReadinessEngine` ACWR, `TrainingLoadGauge` | **Keep CTL/ATL/TSB only; drop ACWR** from all UI. | Fitness-fatigue EWMA τ=42/7 (Banister). ACWR criticised as statistical artefact (Impellizzeri 2020/2021). |
| **Sleep staging** | `SleepStager` (V1), `SleepStagerV2` | **Keep V2 default, V1 for session detection only**; stage minutes labelled "geschätzt" with κ in explainer. | Per-night z HR/HRV/motion + HMM; κ 0.35 on 44-subject LOO benchmark. |
| **Sleep score** | `AnalyticsEngine` Rest composite | **Keep**; rename "Schlaf" score, show its 4 parts in explainer. | duration/need .5, efficiency .2, deep+REM .2, consistency .1. |
| **Sleep need & debt** | `SleepDebt`, `PatternInsights.sleepNeedTonight` | **Keep `SleepDebt`; delete `sleepNeedTonight`** (old 0–21 scale). Personal need = 14-night median sleep on nights followed by Recovery ≥ personal median, clamped 7–9.5 h, default 8 h until 14 nights. Need tonight = need + strain add-on + 0.55·debt (bounded). Label 0.55 as "fitted on one user's history; adjustable". | Van Dongen 2003: chronic restriction accumulates deficit while subjective sleepiness plateaus → show debt as a number. |
| **Regularity / circadian** | `CircadianEngine`, `SleepInsights` | **Keep.** Add Sleep Regularity Index (SRI) over 7–14 days as the Regularity number; chronotype from MSFsc. | SRI (Phillips 2017); regularity predicts mortality better than duration (Windred 2024, n≈61k). MSFsc (Roenneberg 2004). |
| **Stress** | `StressIndex`, `DaytimeStress`, `StressOnsetDetector`, view score, `AppModel.evaluateStress` | **One daily/hourly resolver: `DaytimeStress(.baselineRelative)`**. `StressOnsetDetector` stays as the nudge trigger only. `StressIndex` → Test Centre. Delete view-layer score and `AppModel.evaluateStress`. | Hourly HR + RMSSD z vs. `DaytimeBaselines`, activity-masked (Firstbeat-style; label "Hinweis, keine Messung": HRV is confounded by posture, caffeine, alcohol). |
| **Illness / body signals** | `IllnessSignalEngine`, `IllnessDistance`, `AppModel.evaluateIllness` | **Keep `IllnessSignalEngine` only**; delete the AppModel rule; keep `IllnessDistance` in Test Centre until fed a real correlation matrix. UI wording: "Mehrere Werte außerhalb deines Bereichs", never "krank". | ≥2 signals out of personal range (Apple Vitals rule); RHR (Mishra 2020), respiratory rate (Miller 2020), skin temp; journal confounders damp ×0.45. |
| **Fitness age / VO2max** | `FitnessAgeEngine`, `VitalityEngine` | **Keep FitnessAge; remove Vitality from UI.** Show VO2max estimate beside it with ±. | Nes 2011 non-exercise VO2peak (age, sex, waist/BMI, RHR, activity); Uth 2004 HRmax/HRrest ratio as a cross-check shown only in explainer (±4.7 ml/kg/min with age-predicted HRmax). |
| **Energy Bank** | `EnergyBank` | **Opt-in, labelled heuristic.** | Hand-tuned; no evidence base. |
| **Forecast** | `RecoveryForecast` | **Keep** on Recovery with band; never as a single number. | Hand-tuned constants → WP-20 refits on user history after 60 nights. |
| **Patterns** | `CorrelationEngine`, `BehaviorInsights`, `EffectRanker`, `DoseResponseEngine`, `PatternInsights`, `ActivityCostEngine` | **One pipeline: `EffectRanker` → Benjamini–Hochberg FDR 10 % → `DoseResponseEngine` shrinkage → display.** Show n, effect, and "nicht signifikant" honestly. | Cohen's d / Welch; multiple-comparison correction is missing today (many behaviours × outcomes × lags). |
| **Muscle** | `MuscleLoad`, `MuscleRecovery` | **Keep, labelled estimate.** | Heuristic tables. |
| **Cycle** | `CyclePhaseEngine` | **Keep opt-in**, windows only, no fertility claims. | Temp-led luteal index. |
| **Hydration** | `HydrationGoal` | **Opt-in**, "Richtwert". | EFSA/IOM adequate intake + strain add-on. |
| **Workouts** | `WorkoutDetector`, `AutoWorkoutDetector`, `WorkoutTypeClassifier` | **Keep** (enrichment vs suggestion are different jobs). | — |
| **Steps** | `StepsEstimateEngine` | **Keep**; label "geschätzt" until phone-calibrated. | Per-user motion→steps ratio. |
| **Fasting** | none | **New `FastingEngine`** (§5.6). | — |

### 5.2 Confidence handling (all engines)

- Every engine returns `(value?, confidence, reason)`; the view never decides confidence.
- `calibrating` → no score, show the timeline ("Noch 3 Nächte"). `provisional` → score with dashed
  range and "vorläufig". `solid` → normal. `stale` → value greyed with "Stand: <Datum>".
- A score is **frozen** once computed for a wake-day (Recovery, Sleep). Late-arriving data creates a
  visible "Aktualisiert" note (existing `SleepResultChange`), never a silent change.

### 5.3 Personal baselining rules

- One window per fact kind: nightly vitals → `Baselines` EWMA (14 / 21). Training → CTL τ 42.
  Daytime → `DaytimeBaselines`. No engine may introduce a private trailing window.
- Imported WHOOP/Apple Health history seeds baselines only until 14 own nights (existing
  `ChargeBaselines` rule) — make it global.
- Sensor provenance: baselines are per strap family (4.0 vs 5.0/MG optical differ); switching strap
  starts a 7-night blend, stated in the Recovery explainer.

### 5.4 Learning from the user (fine-tuning)

| Signal | Captured where | Tunes |
|---|---|---|
| Morning check-in 1–5 + symptoms | Today Check-in card (1 tap) | `RecoveryCalibration` weights (±50 %, after 7 / full at 28) — exists |
| "Warst du gestresst?" after nudge | Breathing completion | `StressOnsetDetector` threshold (0.6× → personal, bounded 0.45–0.75) |
| Sleep edits (bed/wake corrections) | Sleep edit sheet | `SleepOnsetTuning` offsets (exists) |
| "Fühlte sich die Belastung richtig an?" (RPE 1–10) | Workout end | Strain explainer shows RPE vs strain; after 10 sessions flag mis-set HRmax/zones |
| Journal tags | Logbook | Patterns, illness confounder damping (exists) |
| Fasting windows | Fasting | Patterns (fasting as a behaviour) |

Rule: every adaptation is bounded, reversible (Settings › Erweitert › "Personalisierung zurücksetzen"),
and mentioned in the relevant explainer.

### 5.5 Minimum data table (user-facing timeline in onboarding step 9)

| Fact | Minimum | Solid |
|---|---|---|
| Strain, HR, stress curve (day-relative) | 1 h wear | — |
| Sleep score & stages | 1 night | — |
| Recovery | 4 nights (provisional) | 14 nights |
| Personal vital ranges | 4 nights | 14 nights |
| Stress baseline-relative | 7 days | 14 days |
| Sleep need (personal) | 14 nights | 30 nights |
| SRI / chronotype | 7 nights | 14 nights (incl. 2 free days) |
| CTL / training form | 21 days | 42 days |
| Fitness age | 4 of 7 nights + profile | 4 weeks |
| Patterns | 5 days per group | 12 days per group |
| Check-in personalisation | 7 answers | 28 answers |

### 5.6 Intermittent fasting — what we can and cannot do

**Can (manual, reliable):** start/stop timestamps, plan presets (12:12, 14:10, 16:8, 18:6, 20:4, OMAD,
5:2 as day-type, custom), streaks against the user's own goal, eating-window reminders, backdating.

**Can (strap, observational, honest):** compare overnight RHR, HRV, sleep score and next-day recovery
on fasting vs non-fasting days via the Patterns pipeline (n, effect size, significance always shown).
Also: last-meal-to-bed interval (from fasting start) vs sleep latency/overnight HR — late large meals
raising nocturnal HR is plausible but evidence is weak and mixed, so it is displayed as a personal
correlation only.

**Cannot (state in UI):** blood glucose, ketones, insulin, autophagy, "fat-burning phase". The timer
ring shows hour markers, not metabolic stage names. No claims of weight-loss superiority: TRE showed no
benefit beyond calorie restriction in TREAT (Lowe 2020, JAMA IM) and Liu 2022 (NEJM); early TRE
improved insulin sensitivity in a small crossover (Sutton 2018) → we may offer "frühes Essfenster" as a
preset with that citation in ⓘ, nothing more.

**Data model:** new GRDB table `fasting_session(id, start_ts, end_ts?, plan_id, note, source)` +
`fasting_plan` in settings (`zoop.fasting.*`). Additive, versioned migration with a test. Not in the
`.zoopbak` whitelist until WP-10 adds it explicitly (Int/String only; Android twin is out of scope —
call it out in the PR per AGENTS.md).

`FastingEngine` (pure, `Packages/StrandAnalytics`): current state, elapsed, goal progress, weekly
adherence, streak, and the "fasting day" boolean per wake-day consumed by `EffectRanker`.

### 5.7 Body signals card (Today)

Shown only when `IllnessSignalEngine` reports ≥2 signals beyond personal range on the same night:
"Ruhepuls +6 bpm und Atemfrequenz +1,4 über deinem Bereich. Das kann an Alkohol, Hitze, Höhe,
Training oder einem beginnenden Infekt liegen. Ruhe heute mehr." One card, dismissible, never a push
notification by default.

---

## 6. Sync & data UX

**One place:** `SyncStatusView` (Ich › Strap & sync). Everywhere else shows at most one line.

| State | Today status line | Strap screen |
|---|---|---|
| Synced < 15 min | "Sync: vor 4 Min · Akku 62 %" (secondary text) | timeline of last syncs |
| Syncing backlog | "Synchronisiere… 3 Std. Verlauf, ~2 Min" + thin progress | detail, chunks, ETA |
| Not connected < 2 h | nothing extra | "Zuletzt verbunden 13:40" |
| Not connected > 2 h | "Strap nicht verbunden seit 13:40" (amber text, tap → help) | reconnect steps per model |
| Gap in data | nothing on Today; affected charts show hatched gap with "keine Daten" | list of gaps with cause if known ("nicht getragen", "Akku leer", "nicht synchronisiert") |
| Calibrating | inside the ring ("Noch 3 Nächte") | — |
| Error | "Sync unterbrochen — erneut versuchen" (one tap) | technical detail collapsed, "Log teilen" |

Rules: no spinner without text; no red for routine disconnection; an error message names what we know
and only that (AGENTS.md diagnostic rule). Charts never interpolate across gaps > 10 min. Score cards
whose inputs have a gap show "Teilweise Daten (5 von 7 Std.)" in the explainer's Data-used line.

**Hardware-validation-required:** any change to *when* sync runs (background scheduling, reconnect
cadence, keep-awake) is out of scope for the UX packages. UX packages only read existing state.

---

## 7. Visual system

Direction (owner memory): flat black, squircles, Dribbble WHOOP-redesign concept; no tinted capsule
chips; one-sentence copy; no duplicate screens.

### 7.1 Typography (Dynamic Type mandatory)

| Token | Use | Classic | Pastel |
|---|---|---|---|
| `display` | Hero numbers | SF Pro Display 56 bold, tabular | SF Pro Rounded 56 semibold |
| `title` | Nav large title | system `.largeTitle` | rounded `.largeTitle` |
| `metric` | Tile / row value | 28 semibold tabular | rounded |
| `headline` | Card title / section header | `.headline` | rounded `.headline` |
| `body` | Meaning sentence | `.body` | same |
| `caption` | Units, deltas, data age | `.footnote` / `.caption` | same |

No other sizes. No ALL-CAPS overlines (they read as shouting in German compound nouns). Retire
`.font(.system(size:))` — a lint script in `Tools/` counts occurrences; budget may only decrease.

### 7.2 Spacing & shape

4-pt grid: `xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32`. Screen gutter 16. Card padding 16. Between cards
12. Between sections 24. Corner radius: card 24 (continuous), tile 18, button 14, sheet system.

### 7.3 Card types (exactly four)

| Type | Purpose |
|---|---|
| `HeroCard` | Top of a screen, hosts `MetricHero` + one chart |
| `ContentCard` | Any grouped content: title row (+ optional `›`), body |
| `TileGrid` of `MetricTile` | 2-up numbers |
| `ListCard` | rows (`MetricRow`, settings, sessions) with hairline separators |

`ZoopCard` becomes `ContentCard`; `StatTile` → `MetricTile`; `StrandCard`, `ChartCard`, `InsightCard`,
`FrostedCardSurface`, `ZoopPanelSurface`, Home's private `card {}` are migrated then deleted.

### 7.4 Charts (Swift Charts only)

- Every chart has: title (what), personal band or reference line (compared to what), one-line takeaway
  (so what) — Tufte's "compared to what?".
- Band: `AreaMark` at 15 % opacity in the metric colour; mean as 1 pt dashed `RuleMark`.
- Gaps: no line across missing data; hatched rectangle for > 1 h gaps.
- Axis: max 4 y-labels, localised; x-axis weekday letters for 7 d, dates for 30/90 d.
- Selection: drag shows value + verdict + date in a pinned overlay, not a floating tooltip.
- Accessibility: `.accessibilityLabel` on series, `AXChartDescriptor` for custom canvases (HIG audio graphs).

### 7.5 Colour

Metric colours fixed: Recovery = band colour (green/amber/red), Strain = blue, Sleep = violet, Stress =
orange, Fasting = teal. Neutral greys for everything else. Accent (`#BFEB7B` classic) only for primary
actions, not for data. System blue links ("Alle Metriken anzeigen") are removed — rows with `›` instead.
Both themes define the same semantic tokens (`StrandPalette.metric(.recovery)` etc.); views never
reference a theme directly.

### 7.6 Motion

Count-up only on first appearance of a hero number per day; ring fill 0.6 s ease-out; no looping
animations on data; respect Reduce Motion (static). `LiquidSky` / sky backgrounds: Classic theme only on
Today hero, nowhere else.

### 7.7 Locale

All numbers via `FormatStyle` with the app locale (fixes "75.0 kg" in German). Durations as `7:43 Std.`
/ `7h 43m` via `Duration.formatted`. New strings use Zoop-keyed catalogue entries.

---

## 8. Engineering guidelines for the 2.0 refactor

### 8.1 Module boundaries

```
Packages/StrandAnalytics   pure engines (no SwiftUI, no GRDB) — returns values + confidence + reason
Packages/WhoopStore        persistence, migrations
Packages/StrandDesign      tokens, MetricReadout + components, card types, chart styles
Strand/Features/<Feature>/ NEW layout for 2.0 screens (shared iOS/macOS where compiled):
    <Feature>Screen.swift        view only
    <Feature>Model.swift         @Observable view model: loads from Repository, builds MetricReadouts
    <Feature>Explanations.swift  MetricExplanation builders (copy templates)
    Components/                  feature-private subviews
StrandiOS/App                shell only (tabs, routing, scene)
```

Features: `Today`, `Recovery`, `Sleep`, `Stress`, `Training`, `Body`, `FitnessAge`, `Fasting`,
`Onboarding`, `Settings`, `Me`, `Sync`. Old files under `Strand/Screens` and `Strand/Liquid` are moved
or deleted per feature; no feature imports another feature's `Components/`.

### 8.2 Rules

- **File size:** ≤ 400 lines per file (hard review gate), ≤ 40 lines per `body`. Split by subview.
- **No logic in views:** views read `MetricReadout`s and call intents (`model.startFast()`). No date
  math, no thresholds, no formatting beyond the components.
- **View model pattern:** `@Observable @MainActor final class XModel` with `load(day:) async`,
  injected `Repository` and `AppClock` (one clock — AGENTS.md rule). Expensive analytics run in
  `Task.detached` and are memoised per wake-day (`AnalyticsMemo`).
- **Naming:** user-facing English names in code (`RecoveryModel`, not `ChargeModel`); legacy internal
  keys (`recovery`, `strain`, `sleep_performance`) stay in storage. Types `Zoop…` only for design
  components. No `Liquid…` prefix for new code.
- **Comments:** why, not what. A comment cites method + source when encoding a constant
  (`// SWC = 0.5 SD (Plews 2012)`). No narrative comments, no "This function…", no TODO without issue.
- **Copy:** every user string in the catalogue, ≤ 1 sentence, verdict vocabulary from §1.1 only.
- **Tests:** every engine change → `swift test` in its package with synthetic data that recovers
  *multiple* injected values (AGENTS.md physiological rule). Every view model → unit test of its
  readouts for calibrating / provisional / solid / stale / empty. Snapshot tests not required.
- **Verification per PR:** `swift test` on touched packages + `xcodebuild -scheme ZoopiOS
  -destination 'generic/platform=iOS Simulator' build` (owner rule: no macOS build locally; CI covers
  `Strand`). Simulator screenshot DE + EN in PR for UI work.
- **Not allowed:** strap protocol/BLE/sync timing changes in UX packages; Android edits; new network
  calls; WHOOP assets.

---

## 9. Roadmap — work packages

Ordering: **Phase A** (foundations) must merge before B; within a phase, packages touch disjoint files
and run in parallel. "Owns" = only that package edits those files during the phase.

### Phase A — Foundations

**WP-01 Metric anatomy components** · complexity **high**
- Goal: `MetricReadout`, `MetricHero/Tile/Row/RangeBar`, `MetricExplainerSheet`, verdict vocabulary,
  localised `MetricUnit` formatting.
- Owns: `Packages/StrandDesign/Sources/StrandDesign/Metric/*` (new), catalogue entries `zoop.metric.*`.
- Accept: components render all 5 confidence/verdict states in previews; DE uses decimal comma;
  Dynamic Type XXL no truncation; VoiceOver reads "HRV, 62 Millisekunden, über deinem Bereich".
- Risk: low (additive).

**WP-02 Design tokens & card types** · **medium**
- Goal: typography/spacing/radius tokens (§7), four card types, chart style helpers, font-lint script.
- Owns: `Typography.swift`, `ZoopTheme.swift`, new `Cards/`, `Charts/` in StrandDesign; `Tools/font_lint.py`.
- Accept: both themes expose identical semantic tokens; lint reports current count as baseline.
- Risk: medium (theme regressions) — no call-site migration in this WP.

**WP-03 Navigation & header rules** · **medium**
- Goal: `.zoopPushedScreen(title:)`, `ScreenScaffold` without in-content title, fix Stress / FitnessAge /
  EnergyBank / Cycle / SleepPlanner headers.
- Owns: `ScreenScaffold.swift`, `RootTabView.tabRouteDestinations()`, header portions of those 5 screens.
- Accept: no pushed screen has content under the back button at any scroll offset (screenshots).
- Risk: low.

**WP-04 One resolver per fact (analytics consolidation)** · **high**
- Goal: Recovery = `RecoveryScorer` (+ SWC HRV trend contributor), Stress = `DaytimeStress`,
  Illness = `IllnessSignalEngine`; delete `AppModel.evaluateStress/evaluateIllness`, view-layer stress
  score, `PatternInsights.sleepNeedTonight`; ACWR removed from outputs; Vitality and alternates behind
  Test Centre. Every engine returns value + confidence + reason.
- Owns: `Packages/StrandAnalytics/**`, the evaluate* sections of `Strand/App/AppModel.swift`.
- Accept: `swift test` green; a test asserts a single resolver per fact (grep-based test in `Tools/`);
  Recovery values unchanged on demo seed (± 0).
- Risk: high (numbers users rely on) — byte-identical Recovery output required.

**WP-05 Sync status unification** · **medium**
- Goal: `SyncStatusView` + `SyncStatusLine`, reading existing state only; replace the five current
  surfaces.
- Owns: new `Strand/Features/Sync/*`; deletes `LiquidSyncStatusRow`, `LiquidStrapBatteryRow`,
  `SyncStatusSection`, `MoreDeviceHeader`.
- Accept: state table §6 covered by view-model tests. **No change to sync scheduling** (hardware-validation-required otherwise).
- Risk: medium.

### Phase B — Screens (parallel; each owns its feature folder)

**WP-06 Tab shell & Me tab** · **medium** — tabs Heute/Körper/Training/Ich with labels, Coach accessory
only if enabled, `MeScreen`, delete unused `MoreDestination` cases and `MoreSectionPrefs`. Owns
`StrandiOS/App/RootTabView.swift`, `TabRoute.swift`, `NavRouter.swift`, `Strand/Features/Me/*`.
Accept: every route reachable, deep links `zoop://today|recovery|sleep|fasting|workout|sync` work.
Risk: medium (deep links, quick actions).

**WP-07 Today rebuild** · **high** — `Strand/Features/Today/*` per §3.1; `LiquidTodayView` reduced to
nothing and deleted; `TodayView` deleted with its toggle. Accept: ≤ 7 cards, no "–" anywhere, all
numbers via WP-01 components, synthesis sentence from template. Risk: high (largest file).

**WP-08 Recovery screen (new)** · **medium** — §3.2, contributors from `RecoveryScorer` trace,
forecast band, personalisation note. Owns `Strand/Features/Recovery/*`. Accept: contributors sum
explains score direction; calibrating state shows timeline. Risk: low.

**WP-09 Sleep restructure** · **high** — §3.3; split `SleepView.swift` into feature folder; SRI card;
merge the four duration/stage cards. Owns `Strand/Features/Sleep/*`, `Strand/Screens/Sleep*`,
`StagesVsTypicalCard`, `AsleepDurationCard`, `HoursVsNeededCard`, `BodyClockDial*`. Accept: no file > 400
lines; sleep edit/undo flows unchanged. Risk: medium.

**WP-10 Fasting (new)** · **medium** — `FastingEngine` (StrandAnalytics), GRDB migration + test
(WhoopStore), `Strand/Features/Fasting/*`, App Intents start/stop, Settings toggle. Accept: presets,
backdate, streaks, patterns hook; "can't measure" footnote; migration test. Risk: low–medium
(schema). Note in PR: no Android twin (fork scope).

**WP-11 Stress screen** · **medium** — §3.5 on top of WP-04's single resolver; post-breathing
"gestresst?" label stored for tuning. Owns `Strand/Features/Stress/*`, `StressView`, `StressDayHero`,
`StressCheckInCard`. Risk: low.

**WP-12 Body dashboard** · **high** — §3.6; merge `TrendsView(asInsightsTab)`, `HealthView`,
`BodyInsightsSection`, `InsightsHubView`, `PatternsScreen` into `Body` + `Patterns`; FDR correction
in the patterns pipeline (coordinate with WP-04: WP-12 owns only the view side; FDR lands in WP-04).
Delete `InsightsView`, `IntelligenceView`. Risk: medium.

**WP-13 Training** · **medium** — §3.4; CTL/ATL chart, week strip, workout detail as push, RPE prompt.
Owns `Strand/Features/Training/*`, `WorkoutsView`, `WorkoutsFitnessCards`, `WorkoutDetailView`.
Risk: medium (lift-session flows must remain intact).

**WP-14 Fitness age** · **low** — §3.7; remove Vitality from UI; VO2max line; "Hebel" estimate.
Owns `Strand/Liquid/FitnessAgeViews.swift` → `Strand/Features/FitnessAge/*`. Risk: low.

**WP-15 Onboarding** · **high** — §3.10; 9 steps, device selection reusing `AddDeviceWizard` step
views, calibration timeline, permissions at point of need. Owns `Strand/Onboarding/*`,
`TermsGateView`, step views extracted from `AddDeviceWizard.swift`. **Pairing/bond logic untouched —
any change to scan/bond sequencing is hardware-validation-required (WHOOP 4.0 and 5.0/MG).** Risk: high.

**WP-16 Settings simplification** · **medium** — §3.9; split `SettingsView.swift` into one file per
page; delete cosmetic toggles; move developer controls to Advanced. Owns `Strand/Features/Settings/*`,
`SettingsView.swift`. Accept: ≤ 8 top-level rows, no duplicate entry points, all removed toggles'
`zoop.*` keys migrated to theme defaults. Risk: medium (hidden dependencies on removed prefs).

### Phase C — System surfaces & cleanup

**WP-17 Widgets & Live Activities** · **high** — §4.1; rebuild `StrandiOSWidgets` families, add
ActivityKit for workout/fasting/sync; `WidgetSnapshot` v2; `build-ipa.sh --with-widgets`; validate on a
real SideStore install. Owns `StrandiOSWidgets/*`, `StrandiOSShared/WidgetSnapshot.swift`,
`StrandiOS/Widgets/*`, `Tools/build-ipa.sh`, `project.yml` (extension target only). Risk: high
(sideload signing). Device-validation-required (not strap).

**WP-18 Card-surface migration & lint** · **low** — migrate remaining `StrandCard/ChartCard/InsightCard/
FrostedCardSurface/ZoopPanelSurface` call sites; drive font-lint count down; delete old surfaces.
Runs last (touches many files) — do not run in parallel with Phase B.

**WP-19 Copy & localisation pass** · **low** — verdict vocabulary and meaning templates DE/EN review,
Zoop-keyed entries, `FormatStyle` everywhere. After Phase B.

**WP-20 Personalisation refits** · **medium** — after 60-night history: refit `RecoveryForecast`
constants and `SleepDebt` 0.55 per user with bounded shrinkage to defaults; stress threshold tuning
from WP-11 labels. `Packages/StrandAnalytics` only. Accept: synthetic tests recover multiple injected
parameters. Risk: medium.

### Parallelisation map

```
Phase A:  WP-01 ─┐  WP-02 ─┐  WP-03 ─┐  WP-04 ─┐  WP-05 ─┐      (all parallel)
Phase B:  WP-06  WP-07  WP-08  WP-09  WP-10  WP-11  WP-12  WP-13  WP-14  WP-15  WP-16   (parallel; WP-07 & WP-12 depend on WP-06 routes merged first or stubbed)
Phase C:  WP-17 (any time after WP-10)   WP-18, WP-19 (after B)   WP-20 (after WP-04, WP-11)
```

Shared-file conflicts to watch: `project.yml` (only WP-17 adds targets; others rely on XcodeGen globs),
`Localizable.xcstrings` (append-only, Zoop-keyed entries per feature prefix), `AppModel.swift` (only
WP-04 edits it in Phase A; Phase B view models read through `Repository`).

---

## 10. Sources (brief)

- Apple HIG — Tab bars, Onboarding, Accessing private data, Charts, Widgets, Live Activities
  (developer.apple.com/design/human-interface-guidelines); ActivityKit duration limits (8 h + 4 h).
- Apple watchOS 11 Vitals — typical range after ~7 days, notify on ≥2 outliers (apple.com/newsroom, 2024).
- Oura Readiness contributors (ouraring.com/blog/readiness-score); Athlytic Recovery 60-day baseline;
  Gentler Streak Activity Path; WHOOP Recovery bands & strain target (whoop.com/thelocker).
- Li, Dey & Forlizzi, CHI 2010 (stage model); Choe et al., CHI 2014 (QS pitfalls); Tufte,
  *Envisioning Information* ("compared to what?").
- Kiviniemi 2007 Eur J Appl Physiol 101:743; Plews et al. 2012/2013 (ln rMSSD 7-day, SWC).
- Van Dongen et al. 2003 Sleep 26:117; Phillips et al. 2017 Sci Rep 7:3216; Windred et al. 2024 SLEEP 47.
- Banister 1991 / Edwards 1993 TRIMP; Impellizzeri et al. 2020/2021 Sports Med (ACWR critique).
- Mishra et al. 2020 Nat Biomed Eng 4:1208; Quer et al. 2021 Nat Med; Miller et al. 2020 PLOS ONE.
- Nes et al. 2011 MSSE 43:2024; Uth et al. 2004 Eur J Appl Physiol.
- Lowe et al. 2020 JAMA Intern Med (TREAT); Liu et al. 2022 NEJM; Sutton et al. 2018 Cell Metab.
- Roenneberg et al. 2004 Curr Biol (MSFsc).
- Internal: docs/ANALYTICS.md, docs/FITNESS_AGE.md, engine headers in `Packages/StrandAnalytics`.
