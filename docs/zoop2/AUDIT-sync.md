# Zoop 2.0 audit: sync pipeline and display (iOS)

Scope: read-only audit of the iOS sync path (BLE offload, Backfiller, AppModel orchestration, Repository refresh, IntelligenceEngine re-score, background tasks, notifiers, widget/watch/Health fan-out) and how screens present it. No BLE command behavior is proposed for change. Branch `zoop-2.0`, HEAD `d8dd21d1`.

Method: static reading only. Nothing was run on a simulator or strap. Findings marked "verify" rest on code reading and should get a failing test or log line first.

Tags: **safe** = "safe (no strap behavior change)". **HW** = "needs hardware validation".

## 1. How a sync flows today

1. `BLEManager` offload -> `Backfiller.finishChunk` decodes off-main (`Backfiller.swift:628`), then `store.insert` and the ack on the main actor.
2. `BLEManager.exitBackfilling` (`BLEManager.swift:2698`) stamps `state.lastSyncedAt` **only** for `reason == "HISTORY_COMPLETE"` (`:2806`). Timeout, abort and disconnect do not stamp it.
3. `AppModel` observes `live.$lastSyncedAt`, debounces 2 s, and calls `refreshAfterCompletedBackfill` (`AppModel.swift:422-428`, `:750`).
4. `refreshAfterCompletedBackfill` runs these in order: `repo.refresh(days: 120)`, `analyzeRecent(skipIfUnchanged: true)` (wrapped in `RescoreBackgroundScheduler.run`), `refreshV5Signals`, `WorkoutDetectedNotifier`, `WidgetSnapshot.publish`, `healthWriteBack`.
5. `analyzeRecent` re-scores 21 days, gated by a fingerprint plus `scoringRecipe` watermark (`IntelligenceEngine.swift:911-960`). If anything was written it calls `repo.refresh()` with the default 4000 days (`:3143`).
6. `Repository.refresh` publishes `days/sleeps/...` and bumps `refreshSeq`. About 20 views key `.task(id:)` on it (Liquid Today, Sleep, Workouts, Patterns, Insights, ...). `repo.$days` also drives `evaluateIllness`, `evaluateStrainTarget`, `evaluateGoodMorning` (`AppModel.swift:359-366`).
7. A 30-minute backstop tick runs `analyzeRecent(force: false)` (`AppModel.swift:534`). The foreground handler runs `ble.requestSync(.foreground)`, `runDeferredRescoreIfOwed`, a Health sync, `WidgetSnapshot.publish` and a watch push (`StrandiOSApp.swift:330-368`).

The pipeline is already heavily guarded (fingerprint gate, reuse cache, generation token, diff-before-publish, detached decode). The findings below are what remains.

## 2. Ranked fixes

### P1. Post-offload refresh publishes a 120-day cache over the 4000-day cache (safe)

- `AppModel.swift:752` calls `repo.refresh(days: 120)`. `Repository.refresh` (`:947`) reads only `nDays`, then diffs against the current caches (`:1017-1027`). The caches hold up to 4000 days, so a 120-day result is "changed" and **replaces** `days`, `sleeps`, `vitalRows`, `importedSleep`, `freshness` and bumps `refreshSeq`.
- The full window is restored only if `analyzeRecent` later writes a daily and calls `refresh()` (`IntelligenceEngine.swift:3143`). The post-offload pass is skipped by the fingerprint gate when nothing new landed (`:929-946`). That is the common empty or duplicate offload, which fires `lastSyncedAt` every poll. In that case the history stays truncated until some unrelated refresh.
- Effect: for anyone with more than 120 days of data, every sync can briefly or persistently shrink `repo.days`. Trends/streak and long-window cards, `freshness` counts, and the history-keyed Today caches all see the truncated window. It also costs an extra `refreshSeq` bump (two full Home reloads per sync).
- Fix: use one window, the default, for every `repo.refresh()`. Delete the `days: 120` argument, or make `refresh(days:)` only ever widen the published window. Do not change `refresh` semantics for macOS callers.
- Acceptance: a unit test seeds more than 120 days, calls `refresh(days: 120)`, and asserts `days.count` is unchanged. A simulator run with `--demo-seed` shows `days.count` stable across a simulated sync. Exactly one `refreshSeq` bump per sync when the re-score writes, zero when it is skipped.

### P2. Combine `willSet` sinks read the previous `repo` state (safe)

- `AppModel.swift:359-366`: `repo.$days.sink { days in evaluateIllness(days); evaluateStrainTarget(); evaluateGoodMorning(); ... }`. `@Published` emits **before** the property is set. The closure gets the new `days`, but `evaluateStrainTarget` (`:2132`) and `evaluateGoodMorning` (`:2142`) read `repo.today` and `repo.sleeps`, which still hold the old values. `evaluateIllness` takes the new array but compares `latestDay == repo.today?.day` (`:1975`), also old.
- Effect: the Good morning, strain-target and illness notifications are evaluated one publish late. On a morning where the score is the last write of the day, the notification waits for the next republish, and `repo.sleeps` is assigned after `days` in `refresh` (`Repository.swift:1036-1043`), so `nightEndTs` is stale even in the best case.
- Fix: drive these off `repo.$refreshSeq` (emitted after all caches are assigned, `Repository.swift:1049`) with `.receive(on: RunLoop.main)`, or pass the `days` value through explicitly. Prefer `$refreshSeq`, since it is the "all caches consistent" signal the file already documents.
- Acceptance: a test that publishes a refresh with a scored today and asserts `evaluateGoodMorning` sees that row in the same turn. No notification evaluation reads `repo.*` inside a `$days` sink.

### P3. Queued re-score loses its gate and its attribution (safe)

- `IntelligenceEngine.swift:885-903`: a call that arrives while `computing` is true sets only `pendingForcedRescore = true`. The follow-up is `analyzeRecent(maxDays:, force: true)` with no `skipIfUnchanged` and no `triggerLabel`.
- Effects:
  - A post-offload call (`skipIfUnchanged: true`) or a foreground resume (`runDeferredRescoreIfOwed`) that lands mid-pass becomes an unconditional full 21-day pass, even when the running pass already scored the same fingerprint. This is the same livelock shape as #2238.
  - The strap log then says `trigger=forced`. That is the wrong-caller trail AGENTS.md calls out (#1538): the queued pass is really post-offload or resume.
- Fix: replace the Bool with a small value (`pendingRescore: (needsForce: Bool, label: String)?`). Merge by "forced wins", keep the first label, and run the follow-up with `skipIfUnchanged` when no caller was truly forced. Keep the existing one-shot re-arm.
- Acceptance: extend the existing `IntelligenceEngine` tests. A post-offload call during a running pass, with an unchanged fingerprint, produces zero second passes and one `trigger=post-offload newData=no` skip line. A genuinely forced call (edit/recalibrate) still produces exactly one follow-up pass.

### P4. One sync-status resolver; `lastSyncError` is overloaded (safe)

`LiveState.lastSyncError` carries four different meanings: a real stall (`timeoutSyncError`), a successful sync with undecodable records (`BLEManager.swift:2858-2860`), an empty-strap advisory (`:2899`), and Bluetooth radio state (`:5695-5774`). Consumers treat any non-nil value as "the sync failed":

| Surface | File:line | What it asserts |
|---|---|---|
| Home pull-to-sync | `LiquidTodayView.swift:830` | non-nil -> "Sync interrupted" even after a completed sync with archived frames |
| Sleep banner | `SleepView.swift:3008` | `syncFailed` -> "The history sync stopped before it finished" |
| Data-sources row | `TodayView.swift:5660-5664` | tints warning, prints the raw message |
| Live tile | `LiveView.swift:1157` | prints the raw message as detail |

The wording for the same state also differs by screen:

| State | Strings in use |
|---|---|
| In progress | "Syncing…", "Syncing… N chunks" (`LiquidTodayView.swift:4130`), "Syncing strap · N" (`:3324`), "SYNCING N" (`LiveView.swift:228,241`), "N chunks" (`LiveView.swift:1183`), `SyncingHistoryNote` (`HealthView.swift:219`) |
| Done | "History synced" (`HealthView.swift:225`, `TodayView.swift:5671`), "Synced 5 min ago" (`LiquidTodayView.swift:4133`), "Last sync …" (`RootTabView.swift:747`), "Up to date" (`LiquidTodayView.swift:3334`), "Last offload completed" (`LiveView.swift:1159`) |
| Never | "Not synced yet" (`RootTabView.swift:745`, `TodayView.swift:5676`), "No completed offload yet" (`LiveView.swift:1159`), "Never" (`LiveView.swift:1390`) |
| No strap | "No strap connected" (`HealthView.swift:222`), "Strap not connected" (`LiquidTodayView.swift:3339`), "Not connected" (`RootTabView.swift:737`) |

- AGENTS.md "two readouts of one fact must not disagree" applies directly.
- "History synced" is also asserted after a `HISTORY_COMPLETE` that banked nothing (`lastSyncedAt` is stamped before `bankedNothing` is classified, `BLEManager.swift:2806` vs `:2865`). The LiveView text "Last offload completed" is the honest one.
- Fix: add one pure `SyncStatus.resolve(live:now:) -> SyncStatus` in `Strand/BLE` (no new BLE behavior). It yields `.noStrap`, `.pairing`, `.syncing(chunks)`, `.complete(at, bankedRows)`, `.completeWithNotes(at, kind)`, `.stalled(message)` and `.radioOff`, derived from existing `LiveState` fields. Split `lastSyncError` consumers by kind with a new `lastSyncNote` field, or derive the kind in the resolver. Every surface above renders from it with one string table.
- Acceptance: unit tests per state. A grep for `lastSyncError` finds only the resolver and BLEManager. The Sleep banner no longer says "stopped before it finished" for a completed sync.

### P5. Pull-to-sync reports outcomes it did not observe (safe)

`LiquidTodayView.swift:808-835`:
- `.synced` ("Up to date") is shown when `lastSyncError == nil`, including when no offload ever started (`waited < 6` times out at 3 s, `ble.syncNow()` declined) and when the 60 s follow cap (`running < 120`) expired while the offload is still running.
- It also shows "Up to date" before scoring has happened. The scoring trigger fires 2 s after `lastSyncedAt` changes, but this flow calls `repo.refresh()` and `load()` immediately and finishes.
- `load()` is called explicitly twice, on top of the `.task(id: refreshSeq)` load (`:629`), so a successful pull runs the day load two or three times.
- The doc comment on `LiquidRefreshIndicator` (`:3254-3265`) says it "no longer reads LiveState at all" and no longer holds for the offload tail. The code still has `@EnvironmentObject live` and reads `live.backfilling` at `:3324`, and `refreshing` stays up for up to 60 s. The header chip and the vessel again report one signal twice.
- Fix: derive the outcome from `SyncStatus` (P4) sampled after the run: `.syncing` -> "Still syncing", never started -> "Couldn't start", complete -> "Up to date". Drop the explicit `load()` calls and let `refreshSeq` drive them. Fix or remove the stale comment.
- Acceptance: pull while the strap is connected but `historyReady == false` shows the not-ready state. Pull during a 90 s offload never says "Up to date". One `load()` per bump.

### P6. Notifications can announce provisional data and can duplicate (safe)

- `GoodMorningNotifier.swift:46-65`, `WorkoutDetectedNotifier.swift:38-56`: the "already posted" marker is written inside the async `getNotificationSettings` callback. Two evaluations in the same turn (the P2 sink plus the settings toggle at `AutomationsView.swift:462`, or two syncs) both pass the gate and both post. `IllnessNotifier` marks the day first and does not have this problem.
- `evaluateGoodMorning` has no sync guard. Nothing checks `live.backfilling`, `live.historyPendingSync` or `intelligence.computing`, so the once-a-day message can state a Recovery computed from a partial overnight offload and is then never corrected. The Rest hero already treats this as "Pending sync" (`TodayView.swift:794-805`).
- `WorkoutDetectedNotifier` stores the **announced** candidate as the one Home shows "until it is answered" (`:53-54`, `Repository.swift:3379-3391`). If the workout is still in progress at sync time, Home keeps showing the short, frozen window and saving it saves the truncated session. The 30-minute re-announce tolerance (`:21`) stops it from ever being refreshed.
- `autoDetectCandidate` reads 2 days of HR with `limit: 200_000` (`Repository.swift:3303`). The read is ordered by `ts ASC`, so for dense libraries the cap drops the **newest** rows (the exact problem the Home comment at `LiquidTodayView.swift:2362-2369` describes). Home runs the same scan again from `.task(id: refreshSeq)` (`:668`).
- Fix: mark the day or candidate synchronously before the async post, and roll back if not authorized. Gate Good morning on `!backfilling && !historyPendingSync && !intelligence.computing`. Only record the pending candidate when its end is older than a few minutes, or re-resolve it on each Home load instead of freezing it. Run candidate detection once per sync and share the result.
- Acceptance: a unit test with two concurrent calls posts once. Good morning does not post while `historyPendingSync` is true.

### P7. Rest (sleep) score has two resolvers (safe)

- Home reads the stored/merged series: `repo.exploreSeries("sleep_performance")`, with imported export > computed series > daily column layering (`LiquidTodayView.swift:2384`, `Repository.swift:2494-2525`).
- Sleep tab, Sleep model, Coupled and Weekly Digest recompute: `importedSleep[day]?.performancePct ?? AnalyticsEngine.Rest.composite(daily:)` over the merged `repo.days` row (`SleepView.swift:504-509`, `SleepModel.swift:431`, `CoupledView.swift:105`, `WeeklyDigestView.swift:57`, `Repository.swift:2623`).
- The comments claim the two are identical. They are the same function over different inputs. The engine persists the composite from its `scored` row at scoring time (`IntelligenceEngine.swift:2433,2598`). The recompute uses the merged row, where imports win except on user-edited nights (`Repository.mergeDaily`). A stored point also survives a composite-formula change that does not bump `scoringRecipe`. A mismatch shows as Home and Sleep disagreeing on one night.
- Fix: add `Repository.restScore(forDay:) -> Double?` implementing one precedence rule. Use it from Home, Sleep, Coupled, Weekly and the widget. Keep the recompute only as the documented fallback inside it.
- Acceptance: one test builds an edited-sleep night where the stored and recomputed values differ, and asserts every surface returns the resolver's value.

### P8. Stress readouts: past-day leak and tile/card mismatch (safe, verify first)

- Home loads `stress` and `hostedStressHours` for **today only** (`LiquidTodayView.swift:2474`, `:2553-2562`, `StressDayCurve.today`), but `monitorTilesRow` passes them to `HomeStressMonitorTile` regardless of `selectedDayOffset`; only `isLive` and the live level are gated on offset 0 (`:874-876`). Navigating to a past day appears to show today's stress score and curve there. Verify in the simulator.
- Two numbers for one fact on the same screen: the tile shows the intraday live level (`liveStressLevel`), the card at `:1486` shows `stressText` = integer of the daily `StressModel` proxy. Both are 0-3 but are different derivations (see also `StressView.swift:213`, `TodayView.swift:4738`, `StressDayCurve` memo).
- Fix: key both off the selected day. For a past day use that day's stored value and no curve. Label which value each shows, or show one.
- Acceptance: Home on day offset -1 shows no today-derived stress value.

### P9. "Carried recovery" has three implementations that disagree while calibrating (safe)

- Home: `TodayView.lastScoredRecoveryDay` returns nil while calibrating (`TodayView.swift:693`), and Home shows "Calibrating".
- Widget, watch and Live Activity: `Repository.widgetAnchor` (`Repository.swift:~618-624`) carries the previous scored day regardless of calibration.
- Result: a calibrating wearer can see a number on the lock-screen widget or wrist while Home says Calibrating, and a Good morning message (P2/P6) reads a third path.
- Fix: put `isCalibrating` into the single anchor (`widgetAnchor`) and make `lastScoredRecoveryDay` delegate to it.
- Acceptance: parameterized test over (scored today, prior scored, calibrating) for both entry points.

### P10. Sync completion is detected by the `lastSyncedAt` timestamp, not by data landing (HW)

- `lastSyncedAt` is the only trigger for the refresh and re-score (`AppModel.swift:422`). It is stamped on `HISTORY_COMPLETE` only (`BLEManager.swift:2806`). A WHOOP 4.0 routinely ends a productive night on the idle **timeout** (comment at `:2955-2965`, #1466). That path banks rows, sets no timestamp, and triggers nothing until the next `HISTORY_COMPLETE` or the 30-minute backstop. `SleepView.swift:2999` also hard-codes a 5 s "calculation queued" window against the 2 s debounce.
- It is also keyed to a wall-clock second (`removeDuplicates()` on a `TimeInterval`).
- Fix (app layer, no command change): add `LiveState.lastDataLandedAt` (or a monotonically increasing `offloadBankedSeq`) bumped from the existing `onBankedOffload` closure (`BLEManager.swift:1498`), and debounce on that. Keep `lastSyncedAt` purely as the display timestamp.
- Needs HW: confirm on a real WHOOP 4.0 that a timeout-ended session with rows now triggers exactly one refresh and one gated re-score, and that a `HISTORY_COMPLETE` slice storm still collapses to one.
- Acceptance: strap log pairs `Backfill: session ended - reason=timeout` with one `re-score: trigger=post-offload` within about 3 s.

### P11. Fan-out after a sync runs the same publish several times (safe)

In the foreground, one sync with a re-score produces: `WidgetSnapshot.publish` from `refreshAfterCompletedBackfill` (`AppModel.swift:787`), from each `refreshSeq` bump (`StrandiOSApp.swift:~255`), from `runDeferredRescoreIfOwed` (`:741`), and from the foreground handler (`StrandiOSApp.swift:~352`). `healthWriteBack` has three call sites (`AppModel.swift:741,792`, foreground `HealthSyncRefreshCoordinator`). The code comments already flag WidgetKit reloads as budgeted. P1 doubles the `refreshSeq` publishes.
- Fix: one `SnapshotPublisher` actor with a 2 s trailing debounce and a "dirty" flag. All call sites call `markDirty()`. Keep the immediate path for the background transition.
- Acceptance: a simulated sync yields one widget publish and one Health write-back per quiet period.

### P12. Liquid Today has no day-scoped load cache and does heavy reads per bump (safe)

- Classic `TodayView` restores a repo-held snapshot at the same `(refreshSeq, day)` (`Repository.swift:927-936`). `LiquidTodayView.load()` (`:2257-2610`), which is the default iOS Today (`RootTabView.swift:87`), does not use it. Every bump re-runs about 25 reads plus a whole-day `hrSamples(limit: 200_000)` for live Effort (`:2370`), plus `SleepModel.build` on the main actor when sleep cards are hosted (`:2531-2538`).
- Fix: reuse the `todayDayScoped*` pair, or skip `hrSamples` when the HR fingerprint (`StressDayCurve` already uses one) is unchanged.
- Acceptance: a tab switch back with unchanged `refreshSeq` runs zero store reads (DEBUG `loadFireCounts`).

### P13. Main-actor work in `Repository.refresh` (safe)

`merged.days == days`, `sleeps`, `vitalRows`, `importedSleep` equality (`Repository.swift:1017-1024`) runs on the main actor over up to 4000 days of rows and tens of thousands of vital rows, on every refresh including the no-change ones. Move the comparison into the detached merge task, passing the current caches in as value snapshots, then re-check `myGen` on resume. Also, `RootTabView.reselectTab` (`:116`) runs a full refresh per tab-bar tap.
- Acceptance: Instruments Time Profiler shows no `==` of those arrays on the main thread in a no-change refresh.

### P14. Background re-score cannot be cancelled by the BGProcessingTask expiry handler (HW; no strap, device background only)

- `RescoreBackgroundScheduler.register` (`:298-316`) calls `worker.cancel()` on expiry. The comment at `:263-264` states the heavy loop is a detached task and "does not inherit cancellation", and `IntelligenceEngine` only checks `Task.isCancelled` at `:797` and `:3173`. After `setTaskCompleted(false)` the pass keeps running with no grant, which is the CPU-limit kill the pacing policy exists to avoid.
- Fix: carry an explicit cancellation token (a `Sendable` flag or `withTaskCancellationHandler`) into the per-day loop, checked at each day boundary, and leave the owed mark set when it stops.
- Needs on-device validation: force-expire via the `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:...]` debugger command and confirm the log shows a clean stop and the next wake resumes.

### P15. Guideline and token hygiene in sync-adjacent UI (safe)

- Tokens: `LiquidTodayView.swift:218` (hard-coded sRGB purple), `:4078,4102,4108` (`.white.opacity(0.16)` borders). `.font(.system(size:))`: 21 in `LiquidTodayView.swift` (for example `:990,1038,1129,2055-2072,3125-3160,3302`), 7 in `HealthView.swift` (`:922-1675`), 5 in `RootTabView.swift` (`:639,761-853`). `ScreenScaffold.swift:129` hard-codes a 30 pt title.
- Flat-UI direction (memory: no tinted capsule chips): `StatePill` in the sync row (`HealthView.swift:222-233`), `SourceBadge("SYNCING n")` (`LiveView.swift:228,241`), `SourceBadge("Strap sync")` (`TodayView.swift:5659`), tinted `Capsule` backgrounds (`LiquidTodayView.swift:1140,1703`). Replace with plain text rows once P4 lands.
- Stale-key hygiene (CLAUDE.md `zoop.*` prefix): new-looking `noop*` UserDefaults keys in `AppModel.swift` (`noopCycleAwareness`, `noopOuraOnsetKeying`, `noopPolarDebugLogging`, about `:2166-2200`) are legacy and fine to leave, but should not be copied into new code.
- Diagnostics honesty (AGENTS.md): `BLEManager.swift:2860` asserts "saved on this Mac" on an iPhone build. The same sentence is shown to iOS users through `lastSyncError`. Also see P3 (`trigger=forced` mislabel).
- Acceptance: grep for the listed patterns drops to zero in the touched files. The `i18n_audit` gate passes (the message changes need Zoop-keyed catalog entries, not renamed legacy keys).

## 3. Edge and error states, as presented today

| State | Where it shows | Gap |
|---|---|---|
| No strap | Health pill "No strap connected"; pull gives "Strap not connected"; Settings avatar "Not connected" | Three wordings (P4). Sleep banner `awaitingSync` is the only one that tells the user what to do |
| Connected, not paired | Health "Pairing…" (uses `historyReady`, good) | Settings avatar says "Connected" with a green dot for the same state (`RootTabView.swift:737-744`, keyed on `live.connected` only), so it contradicts the Health pill |
| Empty/caught-up offload | "History synced" | Asserts a sync happened when no data came (P4) |
| Partial/idle-timeout with rows | Nothing (no stamp, no error) | Stale "Last sync 9 h ago" with fresh data (P10) |
| Stalled with zero rows | `timeoutSyncError` banner | Fine; not stamped, honest |
| Archived undecodable frames | "Sync interrupted" / "stopped before it finished" | Wrong severity (P4/P5) |
| Store write stalled | Only a pref (`BLEManager.swift:2853`) | No in-app readout (verify what the user sees when `persistStalled` is true and the session then ends on timeout) |
| Bluetooth off or denied | `lastSyncError` text | Shares the field with sync failures (P4) |
| Mid-offload partial data | Rest "Pending sync", `SyncingHistoryNote` | Good. Home pull indicator and notifications ignore it (P5/P6) |

## 4. Redundant recompute and races: what was checked and found acceptable

- Same-day re-scores per sync: gated by the fingerprint and `scoringRecipe` watermark; the reuse cache prunes to 21 days. The remaining waste is P3 (queued unconditional pass) and callers that run `analyzeRecent(); repo.refresh()` back to back (`SettingsView.swift:592,1124,2032,2193`); the engine already refreshes when it wrote anything.
- UI reading half-written data: `Repository.refresh` assigns all caches then bumps the seq, with a generation guard. The scoring write is atomic per #521. The only half-written view is the one P2 creates through willSet sinks, and the one P1 creates via truncation.
- Decode and merge work is off the main actor (`Backfiller.swift:628`, `Repository.swift:988`, `StrainScorer` and `StressModel` in detached tasks). Remaining main-actor loads are P13 and the hosted `SleepModel.build` (P12).
- Background tasks: identifiers match `Info.plist` and are registered at launch. HealthWriteback re-arms before work (good). Rescore re-arms only while owed (good). Only the cancellation gap in P14.
- BLE safety: no finding here requires a command, ack or cursor change. P10 reads an existing callback and adds a counter. Everything else is in app-layer presentation or scheduling.

## 5. Suggested order

1. P1, P2, P3 (small, test-first, remove real stale-data and wasted-pass bugs).
2. P4 then P5 and P15 chip removal (one resolver, fixes the owner's wording concern).
3. P6, P7, P8, P9 (single-resolver facts).
4. P11, P12, P13 (efficiency).
5. P10 and P14 last, each with its HW or on-device check.
