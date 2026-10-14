# Zoop 2.0 code-quality audit (iOS paths)

Scope: `Strand/`, `StrandiOS/`, `Packages/StrandAnalytics`, `Packages/StrandDesign`, `Packages/WhoopStore`. Read-only audit on branch `zoop-2.0`.
Method: grep and small scripts over the tree. Reference counts strip comments and exclude tests unless stated. Line numbers are as of this commit.

Size of the audited tree: Strand 316 files / 139k lines, StrandiOS 18 / 6.1k, StrandAnalytics 353 / 67.6k, StrandDesign 57 / 14.2k, WhoopStore 110 / 19.6k.
The iOS target compiles nearly all of `Strand/`. Only `App/StrandApp`, `App/RootView`, `App/ContentView`, `MenuBar/`, `NotificationSettings*` and `System/ZoopAppIntents` are excluded (`project.yml`). So "macOS-only" code is small (about 1.8k lines) and most dead weight is dead everywhere.

---

## 1. Oversized files and types

### Top 25 by lines (product code, tests excluded)

| # | Lines | File | Shape |
|---|---|---|---|
| 1 | 7553 | `Strand/BLE/BLEManager.swift` | 7 small structs (L24-527), one 7k-line class, 2 delegate extensions |
| 2 | 5981 | `Strand/Screens/TodayView.swift` | one 5,200-line `TodayView` struct (L194-5419) plus helper types |
| 3 | 4264 | `Strand/Liquid/LiquidTodayView.swift` | one 2,860-line struct plus about 20 private helper views |
| 4 | 3739 | `Strand/Data/IntelligenceEngine.swift` | one class; `analyzeRecent` alone is 2,308 lines (L867-3188) |
| 5 | 3706 | `Strand/Data/Repository.swift` | read model, about 10 value types, 5 concerns in one class |
| 6 | 3676 | `Strand/Screens/SettingsView.swift` | one 2,950-line struct (one computed var per card) |
| 7 | 3553 | `Strand/BLE/OuraLiveSource.swift` | class plus 2 delegate extensions plus 3 stores |
| 8 | 3518 | `Strand/Screens/SleepView.swift` | view, scene, `SleepTimeEditor` (350 lines), freshness note |
| 9 | 3377 | `StrandAnalytics/SleepStager.swift` | one `enum SleepStager` with 40 MARK sections |
| 10 | 2742 | `Strand/App/AppModel.swift` | god object (wizard, Oura adopt, workouts, notifications, fusion) |
| 11 | 2545 | `Strand/System/AppChangelog.swift` | 280 release-note entries as Swift string literals |
| 12 | 2221 | `Strand/Screens/WorkoutsView.swift` | |
| 13 | 1953 | `Strand/Screens/MetricExplorerView.swift` | |
| 14 | 1952 | `StrandiOS/Health/HealthKitBridge.swift` | |
| 15 | 1848 | `Strand/Screens/DevicesView.swift` | |
| 16 | 1789 | `StrandAnalytics/AnalyticsEngine.swift` | `analyzeDay` is 829 lines |
| 17 | 1773 | `Strand/Screens/HealthView.swift` | |
| 18 | 1747 | `Strand/Screens/AddDeviceWizard.swift` | |
| 19 | 1654 | `Strand/Screens/BreathingView.swift` | |
| 20 | 1503 | `Strand/Screens/InsightsView.swift` | |
| 21 | 1476 | `Strand/Screens/StressView.swift` | |
| 22 | 1470 | `Strand/Screens/LiveView.swift` | |
| 23 | 1356 | `Strand/AI/AICoach.swift` | |
| 24 | 1277 | `Strand/Screens/TestCentreView.swift` | |
| 25 | 1270 | `Strand/Onboarding/OnboardingWizard.swift` | |

Other giant functions (not just files): `WhoopStore/Database.swift` `makeMigrator()` 1,102 lines (L6); `FrameRouter.handle` 470; `Backfiller.finishChunk` 389; `OuraLiveSource.ingest` 385; `LiquidTodayView.body` 341 and `load()` 326; `BLEManager` central/peripheral delegate callbacks 287-335 each; `SettingsView.aboutCard` 303 and `appearanceCard` 288; `VitalSignsSummary.readings` 302; `StreamStore.insert` 301; `AppModel.init` 300. Only 22 functions exceed 250 lines, which makes them a short list to attack.

### Split proposals for the top 10

Swift cannot split a type body across files, but extensions in new files work. Anything `private` that is touched from another file must become `fileprivate` or internal, so each split lists the access changes it needs. Do not change behavior in these moves.

**1. `BLEManager.swift` (7553). HIGH RISK, hardware-validated per AGENTS.md. Move declarations only, no logic edits.**
- `BLE/Detectors/ConnectionHealthDetectors.swift`: the 7 top-level structs `MarginalRadioDetector`, `PostBondTimeoutLoopDetector`, `BondRefusalGiveUp`, `EmptySyncTracker`, `Whoop5EmptyOffloadTracker`, `BackfillContinuation`, `ContinuousHrvSchedule` (L24-527). They are pure value types, so this is a zero-risk move of about 500 lines.
- `BLEManager+Delegates.swift`: both delegate extensions (L5659-end, about 1,900 lines). Members they touch become internal.
- `BLEManager+Backfill.swift`: "Backfill helpers" L2501-3256 plus `exitBackfilling`.
- `BLEManager+KeepAlive.swift`: L3256-3508.
- `BLEManager+Probes.swift`: ECG gate, R22 disable, reboot, feature-flag probe, device-config probe, MG ECG probe (L3508-4969, about 1,450 lines). All opt-in diagnostics.
- `BLEManager+Alarm.swift`: L5372-5659.
- `BLEManager+MultiDevice.swift`: L1973-2501.
- The core file keeps GATT UUIDs, published state, connect and reconnect (about 2,000 lines).

**2. `TodayView.swift` (5981). Delete rather than split (see WP-1).** The classic Today is reachable on iOS only through the Settings toggle `zoop.liquidTodayEnabled` (`SettingsView.swift:2060`) and a DEBUG harness arg (`StrandiOSApp.swift:523`). Before deleting, relocate what other files use:
- `Screens/TodayLogic.swift` (new): statics `lastScoredRecoveryDay`, `readinessWord`, `carriedCaption`, `provenanceDisplayLabel`, `freshRestScore`, `calibrationDetail`. Callers: `CoupledView`, `MetricExplorerView`, `WatchSessionBridge`, `Repository` comments, and tests `TodayChargeTapCollapseTests` and `LiquidChargeCarryTests`.
- `Screens/ActiveWorkoutIndicator.swift` (L55-193): `ActiveWorkoutIndicatorModel`, `Card`, `Section`.
- `Data/TodayCaches.swift`: `TodayHistoryWideCache`, `TodayDayScopedCache` (used by `Repository` and `InsightsView`).
- `Screens/SyncChipState.swift`: `SyncChipState` (used by `DevicesView` and Liquid).
- `Screens/TodayExplainability.swift`: `MetricTileState`, `RecordingState` (tests only plus classic; move to tests or delete with the classic).
- Everything else in the 5,200-line `TodayView` struct goes.

**3. `LiquidTodayView.swift` (4264).** Rename to `HomeView` later (see WP-9).
- `Liquid/Home/HomeHero.swift`: `HeroScoreCell`, `FlatScoreRing`, `LiquidWordmark`, hero and scene (L837-1235, L2958-3248). About 700 lines.
- `Liquid/Home/HomeHeartRate.swift`: `heartRateSection`, `LiquidLiveHR`, `LiquidHeartRateSleepBands`, `LiquidHeartRateGrid` (L1235-1257, L3490-3720).
- `Liquid/Home/HomePullRefresh.swift`: `PullOverscrollReader`, `PullOffsetKey`, `LiquidRefreshIndicator`, `SyncSpinner`, `DebouncedSyncSignal`, `PullSyncOutcome` (L2931-2957, L3264-3420, L733-837).
- `Liquid/Home/HomeDaySwipe.swift`: `LiquidDaySwipeExclusions*` (L2882-2930) plus day navigation (L240-733).
- `Liquid/Home/HomeHostedCards.swift`: the "Added cards" section (L1291-1657, about 370 lines).
- `Liquid/Home/HomeKeyMetrics.swift`: key metrics grid (L1843-2144, about 300 lines).
- `Liquid/Home/HomeBattery.swift`: `LiquidBatteryButton`, `LiquidStrapBatteryRow`, `LiquidSyncStatusRow` (L3881-4200).
- `HomeViewModel.swift` (new): move `load()` (L2284-2629, 345 lines) and derived values (L2629-2748, 120 lines) out of the view (WP-8).
- Delete the mac-only branches listed in section 2.

**4. `IntelligenceEngine.swift` (3739).** `analyzeRecent` at 2,308 lines is the real problem, not the file.
- First extract the 15 or so static diagnostic and log-line helpers (L131-570: `respRateLogLine`, `rhrFloorMeanLogLine`, `sleepDetectNoNightLogLine`, `sleepDivergenceLogLine`, `mergedDayDiag` and so on) to `IntelligenceEngine+Diagnostics.swift`. These are pure statics.
- Fitness-age block (L584-772) to `IntelligenceEngine+FitnessAge.swift`.
- Rescore and heal runners (`runEffortRescoreIfNeeded`, `runSleepWearRescoreIfNeeded`, `runHistoryRepairIfNeeded`, `runTimestampHealIfNeeded`, L772-867) to `IntelligenceEngine+Maintenance.swift`.
- Recovery and day-owner helpers (L3188-3700) to `IntelligenceEngine+Recovery.swift` and `+DayOwner.swift`.
- Then cut `analyzeRecent` into per-stage private methods on a small `AnalysisPass` struct (load streams, sleep, strain, recovery, skin temp, persist). This is the only part needing care. Write characterization tests against `StrandTests` first.

**5. `Repository.swift` (3706).** There are no MARKs inside the 1,900-line middle. Split by concern:
- `Repository+Metrics.swift`: the value types at the top (`ResolvedMetricPoint`, `MetricSourceCandidate`, `MetricSeriesResolution`, `ScoreInputProvider`, `DailyMetricSource`, `SourcedDailyMetric`, `RepositoryFreshness`, `SleepDeletionSnapshot`, L11-130).
- `Repository+CrossSource.swift`: the resolver (L2300-3019, about 700 lines).
- `Repository+Timeline.swift`: Deep Timeline (L1910-2300).
- `Repository+Workouts.swift`: workout editing, auto-detect, detail (L3019-3636).
- `Repository+Sleep.swift`: sleep reads, deletion and re-detection (around L1700-1900).
- `Repository+Explorer.swift`: metric explorer reads (L1884-1910).
- `Repository+Merge.swift`: the `mergeGravityByTs` / `mergeRRByIdentity` statics and the `Task.detached` merges (around L376-1305).

**6. `SettingsView.swift` (3676).** Each `xxxCard` computed property becomes its own `SettingsSection` file.
- `Settings/SettingsAppearanceCard.swift` (L1134-1618, 480 lines).
- `Settings/SettingsProfileCard.swift` (L467-1030).
- `Settings/SettingsExperimentalCard.swift` (L1971-2229, 260 lines).
- `Settings/SettingsDiagnosticsCard.swift` (L2229-2530) and `SettingsAboutCard.swift` (L2530-2858).
- `Settings/StepsCalibrationSheet.swift`: `StepsCalibrationFormat`, `StepsComparisonRow`, `StepsCalibrationSheet` (L3153-3620, 470 lines).
- `Settings/SettingsChrome.swift`: `SettingsDisclosureGroup`, `SettingsSection`, `FormRow`, `DiagnosticsSheet`, and the `Color` bridge.
- The root view keeps ordering only.

**7. `OuraLiveSource.swift` (3553).** Experimental, gated by `ExperimentalBrand`, so low user impact.
- `OuraKeyStore.swift`, `OuraHistoryCursorStore.swift`, `OuraSyncAnchorStore.swift` (L3451-end): trivial extraction.
- `OuraLiveSource+Delegates.swift` (L2846-3451).
- `OuraLiveSource+History.swift` (L669-1241, 570 lines).
- `OuraLiveSource+Ingest.swift` (`ingest`, L2054-2540).
- `OuraLiveSource+Watchdogs.swift` (L1253-1413 plus L2539-2793).

**8. `SleepView.swift` (3518).**
- `Sleep/SleepTimeEditor.swift` (L3105-3449, 350 lines) plus `WakeEdit`, `AddNapSeed`, `SleepUndoBanner`.
- `Sleep/SleepPerformanceNightScene.swift` (L2596-2881, 285 lines).
- `Sleep/SleepStageRows.swift` (L1630-2080, 450 lines of stage rows and timeline rows).
- `Sleep/SleepMarkCard.swift` (L2897-2960) and `SleepFreshness.swift` (L2959-3035).
- Stage decoding (L2514-2596) and the derived model (L2167-2256) go into the existing `SleepModel.swift`.
- `SleepWhy` explainer (L2256-2460) goes to `SleepWhySheet.swift`, which already exists.

**9. `SleepStager.swift` (3377).** Pure enum in a package, so splits are safe and unit-tested. Extensions per MARK group:
- `SleepStager+Gates.swift` (daytime guard, H4 span cap, H7 stillness, off-wrist, sparse gravity: L102-395).
- `SleepStager+HROnset.swift` (L910-1449).
- `SleepStager+Detect.swift` (`detectSleep`, L1449-1833).
- `SleepStager+Respiration.swift` (L2151-2430).
- `SleepStager+Features.swift` and `+Classifier.swift` (L2430-2743).
- `SleepStager+REMDiagnostic.swift` (L2743-3034).
- `SleepStager+HRHRV.swift` (L3034-3304).
- `SleepStager+Hypnogram.swift` (AASM metrics, L3304-3367).
- The constants and output shapes stay in the main file.

**10. `AppModel.swift` (2742).** Split by existing MARKs into extensions in `App/AppModel+*.swift`.
- `+Workouts.swift` (L828-1216).
- `+AddDevice.swift` (L1216-1312).
- `+OuraAdopt.swift` (L1312-1489).
- `+WristBuzz.swift` (L1489-1815).
- `+WearAutomation.swift` (L1815-1945).
- `+BatteryGuard.swift` (L1945-2156).
- `+SkinTemp.swift` (L2156-2319).
- `+Fusion.swift` (L2319-2586).
- `+StorageDiagnostics.swift` (L2586-end).
- `AppModel.init()` is 300 lines (L249); split it into `configureX()` steps.
- There is also `StrandiOS/App/AppModel+iOS.swift` (97 lines) to fold in.

**Also worth doing (not top-10):**
- `AppChangelog.swift` (2545 lines, 280 entries). Move the upstream history to a bundled `changelog.json` and decode it lazily. Keep only the Zoop 1.x entries in Swift. CLAUDE.md forbids rewriting history text, so move it, do not edit it.
- `Database.swift` `makeMigrator()` (1,102 lines): split to `Migrations/V01_V10.swift` and so on. Registration only, so migrations are never mutated.
- `AnalyticsEngine.analyzeDay` (829 lines).
- `FrameRouter.handle` (470 lines). BLE, careful.

---

## 2. Dead code

### 2a. Dead everywhere (no non-test, non-comment references; verified by grep)

| Item | Where | Lines |
|---|---|---|
| `HomePatternsCarousel` (the only pusher of `TabRoute.patterns`; `PatternsScreen` is reached from More) | `Liquid/PatternsScreen.swift:678` | about 50 |
| `HomeHealthMonitorRow`, `HomeStressMonitorCard` | `Liquid/HomeMonitorTiles.swift:172,216` | about 85 |
| `WeeklyDigestCard`, `WeeklyDigestView`. `TrendsView` uses only `WeeklyDigestContent` and `WeeklyDigestSource`. Only a test references the chip style | `Screens/WeeklyDigestView.swift:65,84` | about 55 |
| `FitnessAgeDemoScreen` | `Screens/HealthView.swift` | small |
| `FieldRow` | `Onboarding/OnboardingWizard.swift` | small |
| `ProjectInfo` (entire file; CLAUDE.md claims `ProjectInfo.appName` is used, it is not) | `System/ProjectInfo.swift` | 17 |
| `GuidedCapture`, `BatteryGuidedCapture` (tests only) | `System/GuidedCapture.swift`, `BatteryGuidedCapture.swift` | 68 |
| `MoreSectionPrefs` (tests only) | `App/MoreSectionPrefs.swift` | 40 |
| `StrandPressableButtonStyle`, `StrandPressableModifier`, `StrandCardHover` | `StrandDesign/StrandCard.swift:147` | about 80 |
| `SleepStageLegend` | `StrandDesign/Hypnogram.swift` | small |
| Whole files with no users: `SceneHeroBackground.swift` (217), `TypicalRangeBar.swift` (243), `TimeOfDayBackground.swift` (379) | `StrandDesign/` | 839 |
| Test-only engines: `PreSleepHeartRateFeedback` (285), `AdaptiveExpenditureEngine` (170), `WorkoutTypeClassifier` plus heuristic classifier (399), `DayOwnerResolver` (20) | `StrandAnalytics/` | 874 |
| Unused functions and vars (no references): `liquidWave`, `liquidChordHW`, `liquidCurl` (`LiquidCore:335-349`); `NavRouter.openTrends`, `openLiveSession` (`:92,:100`); `LiveState.formatSpeedKmh` (`:473`); `FileExport.exportPair` (`:100`); `SleepPlannerScreen.weekdayTime` (`:330`); `PatternsScreen.effectsCard` (`:349`); `WorkoutSelectionScreen.nativeLiquidGlassSearchField` (`:369`); `ScoringGuideView.sampleNumber`; `AppModel.cycleAwarenessHidden`, `ouraAllDayLiveHR`; `Repository.cachedWidgetAnchor`, `dismissedSleepManagementWindows`, `allowSleepReDetection`, `availableKeys`, `numericJournalSeries`, `setStoreForTesting`; `BehaviorStore.recalibrateChargeBaseline`; `AICoach.clearKey`; `BLEManager.whoop5OpticalExperimentURL`, `captureRawAccel`, `clearR22DisableReport`, `clearEcgRawDataGate`; `StrandDesign` `noopElevation`, `noopPanel`, `additiveBloom`, `timeOfDayBackground`, `durationFast`, `poseStillIgnoringReduceMotion`; Palette tokens `onDarkSecondary`, `onDarkTertiary`, `glowAmbient`, `cStressStops`, `stressLow/Medium/HighMuted`, `cardFillTop/Bottom`, `titaniumGradient` | | about 400 |

Two further groups:
- About 75 more functions and vars are referenced only by tests (marked `*` in my scan output). Examples: `StreamStore` has 15 `…ForTest` helpers in production code; `RawOutbox` `pendingRawBatches` and `markRawBatchSynced`. They are fine to keep, but move test helpers into `#if DEBUG` or a test-support target.
- Verify `Cursors.setHighwater` / `readHighwater` before deleting; they may be used via the actor.

Caveat: Swift does not warn on unused `private`/internal members, so none of this shows up in the compiler.

### 2b. Dead on iOS, alive on macOS or via the classic Today

- **Classic `TodayView`** (5,981 lines). iOS reaches it only via the "Experimental · Liquid Today (prototype)" toggle (`SettingsView.swift:2055-2080`; the card calls the default screen a "prototype") and DEBUG args. RootTabView picks it at `RootTabView.swift:91`. The memory note says iOS follows one design, so remove the toggle and delete the file after relocating the shared statics (WP-1). The `RootView.swift:480,485` macOS callers are out of scope, so macOS compiles without the classic only if `RootView` is changed; `RootView` is excluded from iOS, so that is safe to leave alone for the iOS target. If macOS must stay buildable, keep it as `#if os(macOS)`.
- **Mac-only branches inside `LiquidTodayView`.** Call sites are wrapped in `#if !os(iOS)` but the definitions are not, so they compile into iOS unused:
  - `liveSessionStartRow` (L1125-1160)
  - `yourCardsSection` (L1259-1297)
  - `recoveryVitalsSection` plus `vitalRow` and `vitalRowBody` (L1779-1843)
  - `lastWorkoutsSection` plus `workoutCard` (L2146-2229)
  - the non-iOS branch of `synthesisSection` (L1690-1774)
  - `cardLink`/`cardAction` variants used only by the macOS card arms
  - together roughly 400 lines
- The same section arms in the `ForEach(sectionOrder)` switch (`.recoveryVitals`, `.yourCards`, `.menstrualCycle`, `.workouts`, `.liveSession`) render nothing on iOS (`LiquidTodayView.swift:474-517`). The enum cases must stay only to keep saved layouts decoding; make them no-op explicitly.
- `MenstrualCycleHomeCard` (`SkinTempCardsView.swift:280`) is mounted only by classic `TodayView:1961` and the `!iOS` Liquid arm, so it is dead on iOS. `HomeCycleCard` replaced it. `recoveryVitalsSection` exists in both Today files and is mounted only for non-iOS (Liquid) or classic (`TodayView:1957`).
- **macOS-only files in the iOS target:** `System/MacActions.swift` (74 lines; `MacActionKind` is still stored by `BehaviorStore` and shown in `AutomationsView`), `MenuBar/` and `RootView` (already excluded). `StrandDesign/RecoveryRing.swift` (244 lines) is used only by `MenuBarContent`.
- AppKit and `#if os(macOS)` / `!os(iOS)` sites remaining in iOS-compiled code: 168 conditional sites in `Strand/` and `StrandDesign`; 107 `NS*`/AppKit references. Most in `LiquidTodayView` (19), `SleepView` (7), `SettingsView` (7), `DisplayPerformanceMonitor` (6), `ZoopMotion` (10 NS refs), `Palette` (7).

### 2c. Android-parity remnants that iOS does not need

- 1,103 comment lines mention Twin/Android/Kotlin mirror; roughly 4,100 comment lines carry issue or PR numbers. Per CLAUDE.md, Zoop does not mirror into Android.
- `AppChangelog.swift` header says "Mirrored byte-for-byte by the Android `AppChangelog.kt`".
- `.zoopbak` and `BackupSettings` byte-identical contracts are real and stay.
- Section keys like `"today.sectionOrder"` are described as "byte-identical key Android uses" in `LiquidTodayView.swift:447`; the key can stay but the comment goes.

### 2d. Naming remnants (the CLAUDE.md "no new noop" rule)

About 385 lines still say noop. In code (not strings): `noopSheetPresentation` (23), `noopPrimary` (18), `noopDeviceId` (15), `noopGhost` (10), `noopLimitations` (enum case, `RootView.swift:28`), `NOOPEntry` (8), `noopSecondary`, `noopAccent` (`StrandApp.swift:71`), `NOOPIntentError`, `NOOPShortcuts`, `NOOPProvider`, `noopStandardSearchChrome`, `noopTabBarAutoHide`, `useNoopFolder`, `StrandDesign.noopElevation`, `noopPanel`, plus 30 UserDefaults keys such as `"noopPuffinCapture"` in `PuffinExperiment.swift` and `AppModel.swift:2165-2220`. The UserDefaults keys are persisted user state, so renaming needs a one-time migration; leave them unless a migration is built.

Also "Liquid" naming (299 references: `LiquidPressStyle` 84, `LiquidVessel` 45, `LiquidTube` 27) contradicts the flat Zoop design direction. `LiquidTodayView` becomes `HomeView`.

---

## 3. Duplicated logic and proposed shared helpers

| Concern | Evidence | Proposal |
|---|---|---|
| Duration text "Xh Ym" | 12 private copies of the same 4 lines: `SleepView:2506`, `StagesCard:895`, `SleepDebtLedgerCard:157`, `StagesVsTypicalCard:119`, `NightDetailCard:162`, `HomeNapDetail:227`, `XiaomiBandView:568`, `AppleHealthView:806`, `SleepPlannerScreen:304`, `SleepInsightsSection:206`, `FusedRecordView:463`, `CoupledView:695`. More variants: `WorkoutsView:1935`, `WorkoutDetailView:758`, `FullDayChartView:418`, `OverviewHRChart:539`, `TodayView:3736`, `LiftFormat:78`, `MetricKitLine:57`; 28 inline "\(h)h \(m)m" sites | One `ZoopFormat.duration(minutes:)` and `.clock(seconds:)`, `.hoursMinutes(seconds:)` in StrandDesign or `Strand/System/ZoopFormat.swift`. The result must stay a localized string (`String(localized:)`), so the catalog keys `%lldm` and `%lldh %lldm` are unchanged. |
| Clock-of-day text | `SleepModel:125`, `SleepView:417`, `SleepWhySheet:318`, `CoupledView:686`, `SkinTempCardsView:748`, `BodyInsightsSection:282`, `PatternsScreen:533`, `CircadianEngine:453`, `SleepInsights:313` | Same `ZoopFormat.clock`. |
| Day-key / date parsing | `Repository.localDayKey` (`:737`), `Repository.dayString` (`:3617`), `AnalyticsEngine.dayString` (`:166,180`), `TimestampHeal.localDayKey`, `LabBookView.dayKey/dayFromKey` (`:550,571`), `InsightsView.dateFromDayKey` (`:940`), `MetricExplorerView.parseDay` (`:31`), `AppleWatchDevice.dayString`, `HealthKitBridge.dayString`, `ScheduledDebugExport.dayKey`, `CoachBriefScheduler.dayKey`, `IllnessNotifier.dayKey`, `SkinTempBackfillWalker.dayKey`, `WhoopImporter.dayString`, plus `dayKey` local funcs in both Today views. 146 `"yyyy-MM-dd"` literals; 137 `DateFormatter()` in the audited code | One `DayKey` type in `StrandAnalytics` (`DayKey.local(Date)`, `.utc(ts)`, `.date(from:)`, `.shift(_, days:)`) backed by cached formatters; replace all copies. `Repository.localDayKey` keeps forwarding. This sits near the parity contract, so keep output byte-identical and add an oracle test. |
| Uncached `DateFormatter()` | 58 inline in `Strand/` and `StrandiOS/` versus 70 cached; worst: `SettingsView` 4, `AppModel` 3, `SmartAlarmView` 3, `TrendsReportView` 3, `MetricExplorerView` 3 | Same `DayKey`/`ZoopFormat` caches. |
| mean / median / std | UI: `AppModel:2019`, `XiaomiBandView:549`, `NightVitalsCard:42`, `SleepModel:360`, `TrendViewerCard:141`, `InsightsView:951`, `TrendsView:205`, `HealthView:1254`, `StressView:1050-1056`, `AppleHealthView:785`. StrandAnalytics (about 25 copies): `mean` in `WorkoutTypeClassifier`, `ActivityCostEngine`, `PatternInsights`, `SleepInsights`, `BodyInsights`, `ReadinessEngine`, `SleepNightReadouts`, `PostWorkoutRecovery`, `RecoveryForecast`, `RangeReport`, `DaytimeStress`; `median` in `HRVAnalyzer`, `VitalBands`, `ComparisonEngine`, `StepsEstimateEngine`, `CyclePhaseEngine`, `BodyInsights`, `SleepInsights`, `LiveSessionEngine`, plus `IntelligenceEngine.medianOf`; `percentile` x2 in `SleepStager`, one in `StrainScorer` | `StrandAnalytics/Stats.swift` with `Stats.mean/median/std(population)/percentile`. Two behaviors differ today (some return 0 on empty, some nil; median even-count rule), so migrate each caller to the variant matching its current semantics, with a test per variant. Do not unify blindly. |
| Card chrome | Two card systems: `ZoopCard` (249 uses) and `StrandCard` (52 uses); `HomeMomentCard.swift:213` has a private `cardChrome()`; 164 hand-built `RoundedRectangle(cornerRadius: n)` (CoachView 15, SleepView 14, SettingsView 13, AddDeviceWizard 12, StagesCard 9) | One `.zoopCardSurface()` modifier on `ZoopMetrics.cardRadius/cardPadding`; retire `StrandCard` or alias it to `ZoopCard`. |
| `cardOpacity` | The same line `max(0, min(1, Double(cardOpacityPercent) / 100))` in 8 places (`LiquidTodayView:229`, `LiveSessionView:32,303`, `CoupledView:34`, `HydrationView:43`, `LiveView:38,1281,1405`); `cardOpacityPercent` is read in 30 places | An `EnvironmentValue` / `@AppStorage` wrapper `ZoopCardOpacity` in StrandDesign. |
| Chart scrub | Mostly consolidated: `zoopChartScrub` is used in 12 files. Private variants remain: `WeekScrub` + `ScrubBubble` (`HomeMonitorTiles:390,414`), `SleepHRScrubOverlay` (`StagesCard:12`), `TrendsScrubCard` (`TrendsView:952`), `MultiTooltip` (`CompareView:1070`), raw `DragGesture` in `TrainingCalendarCard`, `TodayView`, `LiquidTodayView` | Move these onto `ChartScrubReadout` / `ChartTooltip` from `StrandDesign/ChartScrub.swift` and `ChartHover.swift`. Small, mechanical. |
| Today vs Liquid Today | 150 shared `var`/`let` names and 9 shared func names (`clampedDayOffset`, `dayKey`, `effortStrain`, `hostedCard`, `maxDayOffset`, `pickedDayOffset`, `resolve`, `weightTile`); Liquid says "ported from classic Today" | Resolved by deleting classic (WP-1). |

---

## 4. Comment slop

Measured over the audited sources (560 Swift files): 131k code lines vs 55.6k comment-only lines (42% as much comment as code). 16,729 comment blocks; 1,044 of them 10+ lines and 204 of them 20+ lines. About 4,170 comment lines contain an issue or PR number, 1,772 mention Android, Kotlin, parity or "Twin of", 656 narrate history ("used to", "no longer", "previously", "ported from", "classic"), 190 carry internal labels (`COMPONENT 1`, `A1/S4`, `K4:`, `H7`, `M1`), 80 credit reporters by name, and 17 cite "spec 2026-…" dates.

Worst files by comment-to-code ratio: `LiveState.swift` 1.40, `FrameRouter.swift` 1.17, `AnalyticsEngine.swift` 1.12, `HRVAnalyzer.swift` 0.99, `IntelligenceEngine.swift` 0.98 (1,793 comment lines, 249 issue refs), `Baselines.swift` 0.92, `BLEManager.swift` 0.90 (3,429 comment lines, 520 issue refs), `Backfiller.swift` 0.90, `Database.swift` 0.88.
Most issue references: `BLEManager` 520, `TodayView` 295, `IntelligenceEngine` 249, `Repository` 157, `SleepStager` 117, `SleepView` 113, `AppModel` 110, `AnalyticsEngine` 109, `LiquidTodayView` 104.

Longest blocks: `Database.swift:637` (74 lines for migration v31), `OuraRawDump.swift:4` (51), `Reads.swift:419` (45), `WakeMotionRefinement.swift:4` (44), `RecoveryScorer.swift:4` (44), `Database.swift:534` (41), `OuraLiveSource.swift:2717` (40).

Representative examples:
- **History narration** (`LiquidTodayView.swift:425-432`): nine lines explaining that the illness banner was "dropped in the liquid Home rewrite", where Android pins it, and which `.swift` default makes liquid the default. The code is one view. Same pattern at `:476-499` ("dropped in the liquid Home rewrite", "The 'Looking ahead' carousel repeated the evening card…"), `:519-530`.
- **Issue-number chatter** (`RootTabView.swift:74-85`): `#135`, `#197`, `#198` explaining why a `NavigationPath` exists. `Repository.swift:134-140`: `#814` on `deviceId`.
- **Stale or contradicting:**
  - `StrandiOSApp.swift:524` refers to the key `noop.liquidTodayEnabled`; the real key is `zoop.liquidTodayEnabled`.
  - `AppChangelog.swift:3-4` says it is mirrored byte-for-byte by Android.
  - `SettingsView.swift:2055` says liquid Today is "opt-in … default ON" and the card title says "Experimental … (prototype)" for the default screen.
  - `LiquidTodayView.swift:426` points to `RootView.swift` for the default.
  - `FullDayChartView.swift:416` says it "mirrors TodayView.hoursMinutes", which is another duplicate.
- **Restating code:** `IntelligenceView.swift:68` "Header row: section label left, range control right"; `TrendsReportView.swift:291` "Title + mean read-out + trend chip"; `ScoringGuideView.swift:209` "Header row — the flat sample ring sits beside the accent icon + headline"; `BLEManager.swift:6117` "Clear the tally with the link" above a line zeroing counters.
- **Back-references to deleted structure:** `SleepView.swift:416` "The metric-grid spark helper moved to NightDetailCard with the grid" (a comment about code that is no longer there).

Rewrite rule (to hand to a model):
1. Keep a comment only if it states a constraint or reason the code cannot show (a hardware quirk, a protocol fact, an ordering requirement, a non-obvious invariant). One to three lines.
2. Delete: issue and PR numbers, reporter names, "used to / no longer / dropped / ported / classic / rewrite", Android and Kotlin parity, internal labels (`A1/S4`, `COMPONENT 2`), dates, and anything that restates the next line.
3. Move design history to `git log` / `docs/zoop2/`; if a decision is still load-bearing, keep one sentence plus the reason.
4. Doc comments (`///`) describe what a type or function does for its caller, in one to two sentences, not how it came to be.
5. Never change code in the same commit; run the build to prove the diff is comment-only (compare `swiftc -dump-ast` or just build and check `git diff --stat` shows only `//` lines).
6. Do not touch the BLE safety-contract comments, the parity-contract notes on `.zoopbak` whitelist keys, or migration headers. Compress those by hand, not mechanically.
7. Keep `doc_comment_lint` happy: removing a doc block above a declaration is fine; do not leave a detached `///`.

---

## 5. Logic in views, heavy work in `body`

- State-heavy giants: `LiquidTodayView` 74 `@State`, `TodayView` 73, `SleepView` 31, `SettingsView` 27, `BreathingView` 27.
- View-embedded loaders: `LiquidTodayView.load()` 326 lines (L2286), `TodayView` "Loading" section about 670 lines (L4523-5197), plus 120-line "Derived" blocks. Both contain 17 and 12 direct `repo.` reads respectively; `SleepView` 16, `WorkoutsView` 12, `DataSourcesView` 11, `LabBookView` 10, `PatternsScreen` 10.
- Analytics called directly from views: `TodayView` 30 call sites into `AnalyticsEngine`/`SleepStager`/`HRVAnalyzer`/`StrainScorer`/`RecoveryScorer`/`DaytimeStress`, `LiquidTodayView` 14, `TrainingLoadCard` 12, `StressView` 12, `HRVSnapshotView` 12, `SleepView` 8, `CoupledView` 7.
- Good existing precedents to copy: `PatternsModel`, `SleepModel`, `StressModel`, `BodyInsightsModel`, `TodayDayScopedCache`.
- `LiquidTodayView.body` is 341 lines; `DevicesView.body` 281; `TrendChart.body` 263.
- Mitigations already present: a memoization plumbing section in both Today views and `Repository` caches (`TodayHistoryWideCache`). So the body flood is partially handled; the remaining risk is long `body` expressions and `DateFormatter()` creation in view helpers called from `body` (58 uncached sites).
- Proposal: `HomeViewModel` (`@MainActor ObservableObject`) owning `load()`, derived values and day navigation; the view keeps layout only. Do the same for `SleepView` (extend `SleepModel`), `WorkoutsView` (aggregation L1822-1908) and `MetricExplorerView.MetricDetailView` ("Derived" L832-982).

## 6. Hardcoded colors, fonts, spacing

Design tokens are used heavily (`StrandPalette` 4,157 refs, `StrandFont` 2,126, `ZoopMetrics` 1,059, `ZoopCard` 251). The leaks:

- **Colors** (63 literal sites, mostly fine): `SleepView` 15 (night-scene gradient `Color(red:…)` at `:2763-2811`), `LiquidPrimitives` 11, `LiquidSky` 8 (sky keyframes, defensible), `CoupledView` 5, `LiquidTodayView` 4, `LiquidCore` 4, `TodayView:5553` recording red, `WorkoutDetailView:862` effort color duplicated for UIKit and AppKit, `MuscleIcon` 2, `HealthView` 2, `SettingsView` 2. Add `StrandPalette.nightSky*` tokens and `recordingRed`; reuse `effortColor`.
- **Raw system fonts:** 421 `.font(.system(size:…))` sites (most common sizes: 12 x67, 14 x63, 15 x54, 13 x50, 16 x41, 18 x27). Worst: `PatternsScreen` 27, `TodayView` 27, `SleepPlannerScreen` 24, `CoachChatSheet` 22, `LiquidTodayView` 21, `SettingsView` 21, `OnboardingWizard` 19, `CoachSettingsPage` 14, `CycleScreen` 13, `HomeMonitorTiles` 13. Plus `.font(.title/.body/…)` text-style fonts in the same pass (456 total with the first group).
- **Literal spacing:** 1,146 `VStack/HStack(spacing: n)` (values 10 x181, 8 x172, 12 x139, 2 x128, 6 x106, 0 x98), 573 literal `.padding(n)` (16 x47, 20 x29), 499 literal `.frame` dimensions, 239 literal `cornerRadius`. Worst files: spacing: `SettingsView` 61, `AddDeviceWizard` 47, `LiquidTodayView` 44, `LiveView` 43, `WorkoutsView` 40, `TodayView` 39, `OnboardingWizard` 35, `BreathingView` 32; padding: `AddDeviceWizard` 34, `LiquidTodayView` 31, `CoachChatSheet` 27, `CoachView` 25; corner radius: `AddDeviceWizard` 22, `CoachView` 18, `SleepView` 15, `SettingsView` 13, `LiveView` 13; frames: `OnboardingWizard` 25, `SleepView` 24, `LiquidTodayView` 20, `SettingsView` 20.
- `ZoopMetrics` already has a 4pt ramp (`space1…`, `spaceHalf`, `cardRadius`, `gap`, `sectionGap`). Map 4/8/12/16/20 mechanically; the oddballs (10, 6, 3, 14, 1, 2) need a design decision, so add `space1_5`-style tokens only if the design wants them.
- Dead tokens in `Palette.swift` (`cardFillTop`, `titaniumGradient`, `onDarkSecondary`, …) and the `noop`-named Appearance helpers should go at the same time.

## 7. Concurrency smells

Counts over `Strand/` + `StrandiOS/` (comments excluded):
- `Task.detached`: 33 sites. 20 in `Repository`, 7 in `IntelligenceEngine`. 29 are `await Task.detached{…}.value`, the shape that `UnescalatedWork.swift` documents as wrong for `.utility` work (the awaiter escalates the priority). Only 10 sites use `runUnescalated`. Sites to convert: `Repository.swift:376,984,1211,1305,1806,1840,2061`, `LiquidTodayView.swift:2376,2473`, `TodayView.swift:5044`.
- Neither pattern propagates cancellation (0 `withTaskCancellationHandler`). A cancelled `.task` (view disappears, day swipe) lets the detached analysis run to completion and then discards it. The pre-existing note in `UnescalatedWork` says this is accepted; a day-swipe storm on Home still queues work, so add a generation counter or check `Task.isCancelled` after the hop (21 files check cancellation at all).
- 244 unstructured `Task { … }`, but only 6 stored `Task<…>` handles. Hot spots: `AppModel` 17, `BLEManager` 16, `SettingsView` 13, `StrandiOSApp` 11, `OuraLiveSource` 8, `WorkoutsView` 7, `DataSourcesView` 7, `CoachChatSheet` 6. View-owned ones (Settings, Workouts, DataSources) should be `.task`/`.task(id:)` (87 sites already are) or store the handle and cancel on disappear. 9 use `[weak self]`; most don't need it.
- 46 `DispatchQueue.main` and 20 `MainActor.run` in code that is already `@MainActor` (238 `@MainActor` annotations); likely redundant hops. Audit with the compiler: delete and let strict concurrency flag real cases.
- 31 `Task.sleep` and 17 `Timer.scheduledTimer/publish` loops; check each has a cancellation owner.
- DB access is fine: `WhoopStore` is an `actor`, so reads hop off the main actor. 18 synchronous `store.` calls remain, in `DeviceRegistry` (11) and `Collector` (7); I did not check their isolation.
- Main-actor CPU work: `SleepView`, `TrainingLoadCard`, `HRVSnapshotView`, `StressView` call analytics synchronously from view code. `StressView` already moved to `runUnescalated` (`:176-185`); the others should follow the same pattern.
- `UserDefaults.standard` is read from 17 places in `Screens`/`Liquid`; fine, but prefer `@AppStorage` for views.

---

## 8. Ranked work packages

Cheaper model = can a smaller model do it mechanically with a compile check.

| Rank | WP | Files | Effort | Risk | Cheap model? |
|---|---|---|---|---|---|
| 1 | **WP-1 Remove classic Today.** Delete the Settings toggle card, `TodayView` struct and its private helpers (about 5,000 lines), `MenstrualCycleHomeCard`, classic-only leaves (`StrapSyncRow`, `UpdatesInboxView` mount); relocate the shared statics and types listed in section 1.2 first; make `RootTabView.todayTabRoot` and `StrandiOSApp` DEBUG harness use the Liquid screen; fix tests that call `TodayView.x`. | `TodayView.swift`, `SettingsView.swift:2055`, `RootTabView.swift:87-91`, `StrandiOSApp.swift:523`, `CoupledView`, `MetricExplorerView`, `WatchSessionBridge`, tests | L | Medium (shared statics) | Relocation: yes. Deletion: needs a careful build and a test run. |
| 2 | **WP-2 Delete dead-everywhere code** in 2a: HomePatternsCarousel, WeeklyDigestCard/View, HomeHealthMonitorRow/StressMonitorCard, ProjectInfo, GuidedCapture*, MoreSectionPrefs, dead StrandDesign files (`SceneHeroBackground`, `TypicalRangeBar`, `TimeOfDayBackground`), dead StrandCard bits, unused funcs and Palette tokens; test-only engines (`PreSleepHeartRateFeedback`, `AdaptiveExpenditureEngine`, `WorkoutTypeClassifier`, `DayOwnerResolver`) together with their tests, after confirming with the owner they will not come back. | listed in 2a | M | Low (compiler catches misses) | Yes |
| 3 | **WP-3 Strip mac-only branches from `LiquidTodayView`** (about 400 lines) and make the non-iOS section arms explicit no-ops. Do after WP-1 so only one Today remains. | `LiquidTodayView.swift` | S | Low | Yes |
| 4 | **WP-4 Shared formatting helpers**: `ZoopFormat` (duration, clock, hoursMinutes) and `DayKey` with cached formatters; replace the 12+ `durationText` copies, clock copies and about 58 inline `DateFormatter()`. Add unit tests and an oracle test for `DayKey`. | about 35 files | M | Low-Medium (localized-string keys, parity of day keys) | Yes after the helper exists |
| 5 | **WP-5 Comment diet** (rule in section 4), starting with `LiquidTodayView`, `RootTabView`, `SettingsView`, `Repository`, `AppModel`, `IntelligenceEngine`, `SleepView`. Excluded for hand-review: `BLEManager`, `Database.swift` migrations, `FrameRouter`. Target: halve comment lines (55k to under 28k). Comment-only diff check required. | all | L (volume) | Low if comment-only; high if it lets code slip in | Yes, with the verification step |
| 6 | **WP-6 Mechanical file splits** (no logic change): `BLEManager` structs and extensions, `AppModel+*`, `Repository+*`, `SettingsView` cards, `SleepView`, `OuraLiveSource` stores, `SleepStager` extensions, `Database.swift` migration batches. Do one file per commit. | top-10 list | L | Low except BLE (hardware validation per AGENTS.md) and access-level fallout | Mostly yes; BLE should be supervised. |
| 7 | **WP-7 Tokenize design leaks**: add `StrandFont` roles for the common sizes (12/13/14/15/16/18), map paddings and spacing to the `ZoopMetrics` ramp, add palette tokens for the night-scene colors, unify `StrandCard`/`ZoopCard`, one card-surface modifier, one `cardOpacity` environment value. Start with the worst files in section 6. | about 60 files | L | Medium (visual drift; needs simulator screenshots per screen) | Partly. Mapping is mechanical; the odd values need a design call. |
| 8 | **WP-8 Extract view models** from `LiquidTodayView` (`HomeViewModel`), `SleepView`, `WorkoutsView`, `MetricDetailView`; split `IntelligenceEngine.analyzeRecent` into stages behind characterization tests. | 5 files | L | High for `analyzeRecent` (core scoring), Medium for views | No |
| 9 | **WP-9 Naming sweep**: rename `noop*` identifiers (`noopPrimary`, `noopGhost`, `noopSheetPresentation`, `noopAccent`, `noopLimitations`, `NOOPEntry`/`NOOPProvider`/`NOOPShortcuts`/`NOOPIntentError`, `noopDeviceId`), `Liquid*` to `Home*`/`Zoop*` where flat design no longer matches. Leave persisted UserDefaults keys alone unless a migration is written. | about 60 files | M | Low (renames) but check AppIntents/widget identifiers and string-catalog keys (CLAUDE.md warns about catalog keys) | Yes |
| 10 | **WP-10 Concurrency tidy**: convert the 29 `await Task.detached…value` sites to `runUnescalated` where all callers are unprompted; add cancellation checks after the hop in Home, Sleep and Stress loaders; replace view-owned `Task {}` with `.task`; audit `DispatchQueue.main`/`MainActor.run` redundancy. | `Repository`, `IntelligenceEngine`, Today/Liquid, Settings, Workouts, DataSources | M | Medium (priority and ordering behavior changes; per `UnescalatedWork` doc, do not convert user-initiated paths) | No, needs judgment per site |
| 11 | **WP-11 Shared stats**: `StrandAnalytics/Stats.swift` and migrate about 35 `mean/median/std/percentile` copies, preserving empty-input behavior per caller, with tests. | `StrandAnalytics`, 10 UI files | M | Medium (numbers must stay identical; empty and even-count rules differ) | With tests per caller, partly |
| 12 | **WP-12 Move `AppChangelog` data to a bundled JSON** and move test-only `…ForTest` helpers behind `#if DEBUG`; fold chart-scrub stragglers onto `ChartScrubReadout`. | `AppChangelog.swift`, `StreamStore.swift`, `WhoopStore.swift`, `HomeMonitorTiles`, `StagesCard`, `TrendsView`, `CompareView` | S-M | Low | Yes |

Suggested order: WP-2 and WP-1 first (they remove about 6,500 lines and make everything else cheaper), then WP-3, WP-4, WP-5 in parallel, then WP-6 and WP-7, then WP-9, WP-11, WP-10, with WP-8 last.

Net effect if WP-1, 2, 3, 12 land: about 7,000 fewer Swift lines (about 4% of the iOS-compiled tree) before any comment work. WP-5 could remove another 25k comment lines.

## Method notes and limits

- Reference scans strip `//` and `/* */` comments, then count identifier tokens. They miss reflection, string-based lookups (`NSClassFromString`, `Image("name")`), AppIntents and widget entry points, `@main` types, and protocol-witness methods (for example `peripheralManagerDidUpdateState`, `sceneDidDisconnect`). Those were excluded by hand from the dead list.
- A "dead function" means no other file mentions the name. A same-named method on another type would hide a dead one (false negative), but cannot cause a false positive.
- StrandDesign and StrandAnalytics types referenced only from within their own package or only by tests were not all listed; the lists above cover only items I verified individually.
- I did not build or run tests. Line numbers will drift once any work package lands.
