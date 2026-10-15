# Zoop 2.0 — Restored insights (FB-6)

Owner feedback: Trends used to carry more interpreted trends, for example the sleep type (chronotype),
and that seemed to be gone. This audit compares `main` (before the rebuild) with `zoop-2.0` and
records what each pre-2.0 interpretation feature became on iOS.

| Feature (pre-2.0) | Where it was on `main` | State on `zoop-2.0` before FB-6 | Decision |
|---|---|---|---|
| Body clock dial / chronotype (`BodyClockDialCard`, `BodyClockDialSection`) | Sleep tab section `bodyClock`, cosinor phase from `AppModel.circadianPhase` | **Deleted**, unreachable | **Restored, rebuilt** as the *Sleep type* card on Sleep (`SleepChronotypeSection`) plus a summary row on Einblicke (`BodySleepTypeSection`). The type now comes from habitual mid-sleep (MSFsc, Roenneberg 2004) in `StrandAnalytics/Chronotype.swift`, not from the HR cosinor, which withheld a type for most users (`.wide` fit). One resolver (`SleepChronotypeContent`) feeds both places. |
| Weekend shift / social jetlag (`SleepInsights.weekendShift`) | Sleep › *What your nights show* card | Computed but **never shown** (the code comment claimed the rhythm card held it; it did not) | **Restored** inside the Sleep type card (social-jetlag row with Low / Medium / High, plus the workday vs free-day sentence and per-night chart in the explainer). |
| Regular bedtime vs recovery (`SleepInsights.consistency`) | Sleep › *What your nights show* card | Computed but **never shown** | **Restored** as a fourth `SleepInsightKind` (`.consistency`), shown only when the effect is at least 3 points; limit raised from 2 to 3 cards. |
| Latency, sleep-for-recovery, best bedtime insights | Sleep › *What your nights show* | Kept (significant ones only) | Unchanged. |
| Sleep consistency score (`ConsistencyCard`) | Legacy `TodayView` only | File remains, legacy Today only | **Dropped**: the SRI regularity row on Sleep answers the same question; mid-sleep variation now also sits in the Sleep type card. |
| Sleep debt ledger | Sleep tab | Debt row + bars in *Debt and rhythm* | Kept. |
| Asleep-duration 30-day trend (`AsleepDurationCard`) | Sleep tab | Folded into the explainers and Einblicke › Trends (Sleep metric) | Kept as is. |
| Insights tab trend viewer (`TrendViewerCard`), range bar, recovery hero, HRV / RHR / strain small multiples | Insights tab (`TrendsView(asInsightsTab:)`) | `BodyTrendCard` (metric + 7/30/90 d window, band, takeaway) | **Extended**: a *1 year* window, so HRV and resting-HR long-term drift read against the year before (owner: long-term HRV trend). |
| Year heat strip | Insights tab | Dropped | Stays dropped (CONCEPT §9: metric detail covers it). |
| Body insights (`BodyInsightsSection`: HRV/RHR streaks, strain sensitivity, bounce-back, zone mix, stress timing) | Insights tab | `BodyFindings` (*What your body shows*) | Already restored in 2.0. |
| Habit effects (`HabitEffectsCard`), `PatternsScreen` weekday recovery, evening stress vs deep sleep, `InsightsHubView` | Insights tab / Patterns | `BodyPatterns` section (habits with FDR, weekday, evening stress) | Already restored in 2.0. `InsightsHubView` stays macOS / Recovery-calibration only. |
| Vitals (`InsightsVitalsBlock`, `HealthView`) | Insights tab | `BodyVitalsSection` | Already restored. |
| Trends report (`TrendsReportView`) | Insights footer | Einblicke › links card | Reachable. |
| Skin temperature / cycle cards (`SkinTempCardsView`, `CycleScreen`) | Health / Today | Skin temp in vitals; cycle via `HomeCycleCard` on Today | Reachable; not in FB-6 scope. |
| `CoupledView` (strain vs recovery) | Today route | Route `.coupled` kept; its optimal-strain band feeds the Today rings | Unchanged (Today owned by another package). |
| HRV snapshot (`HRVSnapshotView`) | Live view | Live view sheet | Reachable; a measurement tool, not a trend. |

## Sleep type method

- Window: newest 42 nights (one per wake day). No profile under 7 nights; solid from 14 nights with
  2 free nights (CONCEPT §5.4).
- Free days: nights before Saturday or Sunday. MSF = mean free-day mid-sleep; MSW = mean workday
  mid-sleep. Catch-up correction: MSFsc = MSF − (SDf − SDweek) / 2 when free-day sleep is longer.
- Type: MSFsc before 03:30 early, from 05:00 late, else intermediate. Without 2 free nights the
  all-night median stands in and the card says it is still building.
- Social jetlag = |MSF − MSW| (needs 2 free and 3 work nights): under 1 h low, 1–2 h medium, from
  2 h high (Wittmann 2006). Timing variation = SD of nightly mid-sleep: ≤ 30 min low, ≤ 60 medium.
- Tests: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ChronotypeTests.swift`.
