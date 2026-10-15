import SwiftUI
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandImport
import OuraProtocol
#if os(iOS)
import UserNotifications
#endif

/// Data source currently running an import from the Data Sources screen.
enum DataSourceImportKind {
    case whoop
    case appleHealth
    case xiaomi
}

/// Root app state: owns the live BLE connection state and the CoreBluetooth engine.
@MainActor
final class AppModel: ObservableObject {
    /// The live instance, so an AppIntent (Shortcuts) can reach the bonded strap instead of spinning up a
    /// second AppModel (duplicate BLE engine, never buzzes). `weak` so an intent fired while Zoop is closed
    /// sees nil (#42).
    static weak var shared: AppModel?

    /// Timestamp formatter for generic-HR strap-log lines; mirrors `BLEManager.logTimeFormatter` (`HH:mm:ss`).
    static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// One of our own strap-log lines, stamped like the lines around it (the log takes each line's time from its writer).
    static func stamped(_ line: String) -> String {
        "[\(logTimeFormatter.string(from: Date()))] \(line)"
    }

    /// The canonical imported/computed id ("my-whoop"): the WHOOP-import target, the FusionSource
    /// `.whoopImport` mapping and manually-saved workouts all land here, and computed scores go under the
    /// matching `-noop` sibling. It must not follow the active strap (#814): a remove+re-add gives the strap
    /// a fresh "whoop-<uuid>" id and history banked under "my-whoop" would be orphaned. The Repository's
    /// active-strap read id follows the registry (`adoptActiveDevice`) and the dashboard reads the union.
    let deviceId = "my-whoop"
    let appleDeviceId = "apple-health"
    let live: LiveState
    let ble: BLEManager
    let repo: Repository
    let profile = ProfileStore()
    let behavior = BehaviorStore()
    let intelligence: IntelligenceEngine

    /// Opt-in AI coach (bring-your-own-key), the one networked feature; off until enabled.
    let coach: AICoachEngine

    /// Observable cache over the paired-device registry; `activeDeviceId` drives the source coordinator. Built
    /// lazily once the store opens, nil until then (with no generic strap paired the active id stays "my-whoop").
    @Published private(set) var deviceRegistry: DeviceRegistry?
    /// Runs exactly one device's live BLE at a time. Dormant while WHOOP is active; acts only when a
    /// non-WHOOP generic strap becomes active, pausing WHOOP and running the isolated `StandardHRSource`.
    private(set) var sourceCoordinator: SourceCoordinator?

    @Published var moments: [Date] = []

    /// Timestamps of "sleep marks" tapped on the strap (#461): bedtime / wake / mid-night. Persisted; each
    /// also writes a greppable "Sleep mark @ HH:mm" strap-log line.
    @Published var sleepMarks: [Date] = []

    /// An in-progress manually-tracked workout. On End the window is scored via `StrainScorer` and saved as a
    /// `WorkoutRow` (source "manual"). The day's strain already counts this HR, so this is a per-session
    /// annotation, not a double-count.
    @Published var activeWorkout: ActiveWorkout?
    @Published var lastWorkout: WorkoutRow?

    /// Records the GPS route of an in-flight distance-type workout from CoreLocation (#524). Fails safe: with
    /// no GPS or denied permission it records nothing and the session still banks HR + Effort. Arms only for
    /// `WorkoutCatalog.Sport.isDistanceSport`; the final route is persisted on End via `RouteStore`.
    let gpsRecorder = GpsWorkoutRecorder()
    private(set) var activeWorkoutIsGps = false

    /// A manual workout in progress. `samples` accumulate from the smoothed live `bpm`; `liveStrain` is
    /// recomputed as the window grows.
    struct ActiveWorkout: Equatable {
        let start: Date
        /// The named sport chosen at start, persisted as the saved row's `sport` (#519). Defaults to the catalogue default.
        var sport: String = WorkoutCatalog.defaultSportName
        var samples: [HRSample] = []
        var liveStrain: Double = 0
        var avgHr: Int = 0
        var peakHr: Int = 0
        var pausedAt: Date?
        var pausedDuration: TimeInterval = 0

        var isPaused: Bool { pausedAt != nil }

        /// Adds a heart-rate sample unless this second already has one, and says whether it did.
        /// `captureWorkoutSample` runs from two `@Published` sinks (`heartRate` and `rr`), so one second can get
        /// two samples. Effort credits a zero gap with a full second (`StrainScorer.sampleDurationsMinutes`), so
        /// each repeat would count as another second of effort. A refused reading still reaches `peakHr`, since a
        /// within-second high belongs to the peak. Only the last sample is compared (the live stream is monotonic).
        mutating func recordSample(_ sample: HRSample) -> Bool {
            if let last = samples.last, last.ts == sample.ts {
                peakHr = max(peakHr, sample.bpm)
                return false
            }
            samples.append(sample)
            return true
        }

        /// The saved max heart rate: the highest sample, or a higher reading a repeated second folded into `peakHr`. Nil with no samples.
        var savedPeak: Int? { samples.map(\.bpm).max().map { max($0, peakHr) } }

        func elapsed(at now: Date = Date()) -> TimeInterval {
            ActiveWorkoutClock.activeElapsed(start: start, pausedAt: pausedAt,
                                             pausedDuration: pausedDuration, now: now)
        }
    }
    struct HealthAlert: Equatable {
        let message: IllnessSignalEngine.Message
        let firedSignals: [String]
    }
    @Published var healthAlert: HealthAlert?

    // MARK: - v5 pillar snapshot (engines run in the analytics pass; the views read these)
    // The Insights / skin-temp Health-hub cards take pure engine results by value. The analytics pass
    // (IntelligenceEngine.analyzeRecent, refreshV5Signals) computes them once and publishes them here. All
    // opt-in and honest-nil: nil means not enough data or not enabled.
    @Published var illnessSignal: IllnessSignalEngine.Result?
    /// Parallel Mahalanobis illness-distance read on the same z-vector as illnessSignal, never gating the
    /// alert: `IllnessSignalEngine` stays the sole fire gate and this only adds a "how strong" readout once it
    /// has raised. Test Centre (Stress domain) only; with an identity correlation it is an unvalidated alternate.
    @Published var illnessDistance: IllnessDistance.Result?
    @Published var cyclePhase: CyclePhaseEngine.Result?
    @Published var cycleCurve: [Double] = []
    @Published var circadianPhase: CircadianEngine.PhaseEstimate?

    /// The passive-nudge surface (haptic biofeedback "stress check-in"). `feedStressOnsetDetector` fires
    /// onto it and both app roots inject it into the environment for the Breathe card.
    let stressNudgeCenter = StressNudgeCenter()

    private var lastDoubleTapAt: Date = .distantPast
    private var lastCoachZone: Int = -1
    // Stress-onset detector state: a rolling R-R buffer plus the replay-safe detector state (persisted via
    // BiofeedbackPrefs so a relaunch cannot re-fire).
    private var rrBuf: [Int] = []
    /// Which live R-R packet `rrBuf` last took, so each packet enters once (`RRPacketCursor`).
    private var stressPackets = RRPacketCursor()
    private var stressState = BiofeedbackPrefs.loadStressState()

    @Published private var activeImportSource: DataSourceImportKind?
    @Published var whoopImportSummary: String?
    @Published var appleHealthImportSummary: String?
    @Published var xiaomiImportSummary: String?
    /// Typed failure flags per source; summary warning styling reads these instead of substring-matching the
    /// message. Used by the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false
    @Published var pendingShortcutHealthImport: ShortcutHealthImport.PendingImport?

    var hasActiveImport: Bool { activeImportSource != nil }

    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }

    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        case .xiaomi: return xiaomiImportFailed
        }
    }

    /// Smoothed, display-ready live heart rate (median over a short window, spike-filtered). Screens should
    /// show this, not the raw per-beat value.
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var hrCancellables = Set<AnyCancellable>()
    /// Drives the read spine off the registry's active device (#814). The Devices screen calls
    /// `registry.setActive` directly (not via `registerDevice`), so without this subscription reads stayed
    /// pinned to the id active at wiring time. Mirrors how `SourceCoordinator` drives the write side.
    /// `removeDuplicates` collapses redundant emits.
    private var readSpineCancellable: AnyCancellable?
    private var smartAlarmRearmTimer: Timer?

    init() {
        let live = LiveState()
        self.live = live
        // Seed every subsystem with the same id ("my-whoop" at launch). The store and registry are not open yet;
        // `bootstrapStore` and `wireSourceCoordinator` / `adoptActiveDevice` (#814) re-point them to the
        // registry's active id once it opens.
        self.ble = BLEManager(state: live, deviceId: deviceId)
        self.repo = Repository(deviceId: deviceId)
        self.coach = AICoachEngine(repo: repo)
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: deviceId)
        // Route the engine's per-day scoring diagnostic into the shareable strap log (PII-scrubbed by
        // `live.append(log:)`). `live` is captured strongly; the engine lives as long as the app session.
        self.intelligence.diagnosticSink = { [live] line, domain in live.append(log: line, domain: domain) }
        // Test Centre `.workouts`: wire the Repository and GPS recorder tagged sinks to the strap log. Each
        // emitter re-checks `TestCentre.active(.workouts)` before building a line, so these are inert when off.
        self.repo.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        self.gpsRecorder.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        // Give the read model the user's HRmax and sex so it can backfill a strap-native workout's Effort on
        // display when the stored value is nil (#961). Kept in step with profile edits; objectWillChange fires
        // before a @Published setter lands, so read the current values. Display-only.
        self.repo.strainProfile = Repository.StrainProfile(hrMax: Double(profile.hrMax), sex: profile.sex)
        profile.objectWillChange.sink { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.repo.strainProfile = Repository.StrainProfile(
                    hrMax: Double(self.profile.hrMax), sex: self.profile.sex)
            }
        }.store(in: &hrCancellables)
        // Smooth HR centrally. A `@Published` sink runs in willSet, so each hands `ingestHR` the value being
        // written and reads the other from `live`; reading both from `live` kept the median after the heart rate
        // was cleared (disconnect, strap off the wrist).
        live.$heartRate.sink { [weak self] hr in
            guard let self else { return }
            self.ingestHR(heartRate: hr, rr: self.live.rr)
        }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] rr in
            guard let self else { return }
            self.ingestHR(heartRate: self.live.heartRate, rr: rr)
        }.store(in: &hrCancellables)

        // Bank the device's R-R transport facts whenever a link comes up (#2117). Shell-independent: the Liquid
        // shell is the iOS default and the wearer this explains had HRV silently blank there. Two indexed MINs
        // and a registry read per connect, cheap enough not to gate.
        live.$connected.sink { [weak self] isConnected in
            guard isConnected, let self else { return }
            Task { await self.refreshRRTransportFacts() }
        }.store(in: &hrCancellables)

        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
        // Re-arm the next day's firmware alarm when the strap reports it fired (STRAP_DRIVEN_ALARM_EXECUTED,
        // if the firmware pushes it). Gated on enabled inside applySmartAlarm.
        live.onSmartAlarmFired = { [weak self] in
            guard let self, self.behavior.smartAlarmEnabled else { return }
            // iOS: mirror the strap's wake buzz to a local notification for a phone-in-pocket user (#577). No-op on
            // macOS or when wrist alerts are off.
            AppModel.postSmartAlarm()
            self.applySmartAlarm()
        }
        // Strap battery alerts (#368). The notifier self-gates on the setting and OS authorization and keeps its
        // own once-per-crossing state, so feeding it every reading is safe.
        live.onBatteryUpdate = { [weak self] pct in
            guard let self else { return }
            BatteryNotifier.onBatteryUpdate(pct: Int(pct.rounded()),
                                            charging: self.live.charging,
                                            enabled: self.behavior.batteryAlerts)
            // Predictive runtime alert off the reading just banked into the SoC buffer. A nil estimate is a no-op;
            // the 15% alert remains the safety net.
            BatteryNotifier.onRuntimeEstimate(remainingHours: self.live.batteryEstimate?.remainingHours,
                                              charging: self.live.charging,
                                              enabled: self.behavior.batteryAlerts
                                                    && self.behavior.batteryPredictiveAlerts)
            // Escalation, independent of the two latching gates above: the 15% and 24 h alerts each fire once per
            // discharge cycle, so a strap that keeps draining goes silent as the news worsens (one user lost a night
            // over the final ~3 h to the ~10% cutoff).
            // 1. Critical SoC: a lower crossing with its own persisted gate.
            BatteryNotifier.onCriticalBattery(pct: Int(pct.rounded()),
                                              charging: self.live.charging,
                                              enabled: self.behavior.batteryAlerts)
            // 2. Bedtime night-guard: near the learned habitual bedtime, does the strap clear tonight? Uses the
            // cutoff-aware runtime (the raw estimate is time-to-0% but the strap dies ~10% above that). Without a
            // learned bedtime the policy stays silent. Rides the predictive toggle.
            BatteryNotifier.onBedtimeRunway(
                nowSecOfDay: Self.localSecOfDayNow(),
                habitualMidsleepSec: self.habitualMidsleepCache,
                typicalSleepHours: BatteryEstimator.typicalSleepHours(
                    nightlyHours: self.repo.days.compactMap { $0.totalSleepMin.map { $0 / 60.0 } }),
                usableRemainingHours: self.live.batteryEstimate.map(BatteryEstimator.usableRemainingHours),
                charging: self.live.charging,
                enabled: self.behavior.batteryAlerts && self.behavior.batteryPredictiveAlerts)
        }
        $bpm.sink { [weak self] hr in self?.coachZone(hr) }.store(in: &hrCancellables)
        // Illness/strain early-warning recomputes when daily history changes. Keyed on `refreshSeq`, which
        // `refresh` bumps after every cache is assigned; a `$days` sink runs before `days` is set and so
        // evaluated one refresh late.
        repo.$refreshSeq.sink { [weak self] _ in
            guard let self else { return }
            self.evaluateIllness(self.repo.days)
            self.evaluateStrainTarget()
            self.evaluateGoodMorning()
            self.refreshHabitualMidsleep()
        }.store(in: &hrCancellables)
        // The good-morning check is held while data is in flight; rerun it once offload, pending-history and
        // scoring have settled. `receive(on:)` runs it after the values are assigned, not inside willSet.
        Publishers.CombineLatest3(live.$backfilling, live.$historyPendingSync, intelligence.$computing)
            .map { !$0 && !$1 && !$2 }
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluateGoodMorning() }
            .store(in: &hrCancellables)
        // Re-arm the strap's firmware alarm once the connection has settled, not when it (re)bonds (#59, #34).
        // A smart-alarm time changed while away never reached the strap, so it fired at the old time.
        // Keyed on `connectSettled` (bumped by BLEManager once the handshake has run and the cmd-notify
        // characteristic is confirmed subscribed), not raw `bonded`: `state.bonded` publishes inside the
        // handshake continuation and Combine delivers synchronously, so arming there nested the alarm's
        // SET_CLOCK/SET_ALARM_TIME/GET_ALARM_TIME burst mid-handshake, and the GET_ALARM_TIME readback got no
        // reply. `dropFirst()` skips the initial value so nothing fires at launch.
        // Also re-run when a disarm was dropped (#730): a user who turned the alarm off while disconnected had
        // the disarm swallowed by `send` and the strap still buzzed. `disarmPending` latches that dropped write,
        // so this stays a no-op for users who never armed one (unconditional re-run would send DISABLE_ALARM on every connect).
        live.$connectSettled.dropFirst().sink { [weak self] _ in
            guard let self, self.behavior.smartAlarmEnabled || self.ble.disarmPending else { return }
            self.applySmartAlarm()
        }.store(in: &hrCancellables)
        // The firmware alarm is a single absolute instant with no recurrence, re-armed only on a (re)bond or
        // settings change, so a continuously bonded strap would go silent from day two. Re-arm daily.
        scheduleDailySmartAlarmRearm()
        // Re-apply "Continuous HRV capture" on every (re)bond: if on, the strap holds the dense realtime stream
        // armed with no Live screen open, banking R-R 24/7. The BLE reconciler arms it on the off-to-on edge;
        // pushing it here and at the init tail covers a fresh launch and every reconnect (see PuffinExperiment).
        live.$bonded.removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
            self.applyPowerSaving()
        }.store(in: &hrCancellables)
        // A completed backfill has written strap history: refresh the dashboard cache, leaving heavy analysis to
        // its own guarded path.
        // Coalesced (#755): firmware that segments a deep offload into many small HISTORY_COMPLETE slices stamps
        // `lastSyncedAt` once per slice, and each would fire a full repo.refresh (~50 reads) plus analyzeRecent,
        // contending with the backfill's bulk writes (a ~10s freeze). `.debounce` fires once, 2s after the stream
        // goes quiet, always delivering the trailing edge so the final data still refreshes.
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill() }
            }
            .store(in: &hrCancellables)

        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        sleepMarks = (UserDefaults.standard.array(forKey: "sleepMarks") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        // Rehydrate a manual workout in flight when iOS killed the app, so it can still be ended and saved (#529).
        rehydrateActiveWorkout()

        AppModel.shared = self   // publish for App Intents (Shortcuts) , see the static above (#42)

        // Seed the BLE client with the persisted "Continuous HRV capture" intent so `wantsRealtime` reflects it
        // from launch; the bond sink above re-applies it on reconnects.
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        applyPowerSaving()

        // Turn offloaded raw data into dashboard scores on launch and every 15 minutes (IntelligenceEngine
        // computes, persists under "my-whoop-zoop", refreshes the dashboard).
        // One-shot reclaim of stale Documents/Inbox picker drops and stranded `noop-*` temp scratch (e.g. the
        // multi-GB `noop-health-*` export.xml an interrupted import leaves, #590). Off the main actor; Inbox part is iOS-only.
        Task.detached { AppModel.purgeImportInbox(); AppModel.purgeImportTemp() }

        // Run the launch sequence at `.utility` so the heavy one-shot 4000-day heal/rescore yields to UI
        // rendering; the reads are already off the main actor.
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            #if DEBUG
            // DEBUG-only: `--demo-seed` populates a deterministic synthetic dataset for screenshots. No-op in
            // Release and once data exists.
            if AppleDemoSeeder.requested, let store = await self.repo.storeHandle() {
                await AppleDemoSeeder.seedIfRequested(into: store)
                self.live.batteryPct = 68
            }
            #endif
            await self.repo.refresh()                          // surface any imported data at once
            await self.wireSourceCoordinator()                 // dormant unless a generic strap is active
            await self.recordAppVersionChangeIfNeeded()        // #1410: stamp an update transition once
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            // Defer the heavy one-shot 4000-day heal/rescore while an import is in flight (a large Apple Health
            // import overlapping it caused ~1-minute app-wide lag). The import refreshes the dashboard itself and
            // the cadence loop still runs. Bounded poll that respects cancellation. The wait is capped because
            // `hasActiveImport` clears only in finishImport(), which a true import hang never reaches; uncapped it
            // would starve the one-shot passes and cadence loop for the session.
            var importWaited = 0
            while self.hasActiveImport && !Task.isCancelled && importWaited < 180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s, re-check; ~3 min cap then proceed
                importWaited += 1
            }
            // One-shot on-upgrade heal (#547): purge rows a bad-clock strap dated to far-past / bogus / future
            // dates, then rescore the real days. Runs before the Effort rescore so both see a clean DB. Persisted
            // flag; idempotent.
            await self.intelligence.runTimestampHealIfNeeded()
            // One-shot on-upgrade Effort rescore (#313): recompute strain across the full history and repair sleep
            // rejected by unmatched WRIST_OFF. Either pending flag triggers the shared pass.
            await self.intelligence.runEffortRescoreIfNeeded()
            await self.intelligence.runFitnessAgeBackfillIfNeeded()
            while !Task.isCancelled {
                // Re-heal (#547): a sync since the last tick may have armed a re-heal after its ingest gate dropped
                // bad-clock records. `runTimestampHealIfNeeded` honours the pending flag even after the one-shot is
                // done, so a wandering-clock strap cannot keep re-polluting. No-op when nothing is pending.
                await self.intelligence.runTimestampHealIfNeeded()
                // The steady-state tick is a backstop, not a data-driven refresh: every real update (sync, import,
                // edit, recalibrate, heal) already rescores via its own forced call (#836). `force: false` skips the
                // heavy 21-day rescore when the raw HR stream is unchanged.
                // It is also wrapped by `RescoreBackgroundScheduler` (#1538): this loop lives as long as the process
                // and keeps ticking while backgrounded, and a killed pass never advances the watermark, so it would
                // restart a full pass forever. `owesOnDefer: false`: a skipped backstop owes nothing, since every real
                // update forces its own pass. `live = self.live` is spelled out because the nested `Task` requires explicit `self`.
                await RescoreBackgroundScheduler.run(owesOnDefer: false,
                                                     log: { [live = self.live] line in
                                                         live.append(log: line)
                                                     }) {
                    await self.intelligence.analyzeRecent(force: false)
                }
                await self.refreshV5Signals()
                // 30-minute backstop cadence (#836). The `force: false` gate cannot skip while the strap streams live HR
                // (the fingerprint advances every second), so a 15 min cadence rescored the whole 21-day window though
                // only today's daytime HR changed. Recovery and sleep are night-computed and unaffected.
                try? await Task.sleep(nanoseconds: 1_800_000_000_000)  // 30 min backstop (#836 battery)
            }
        }
    }

    /// Build the device registry and source coordinator once the store is open, then start observing.
    /// Push the persisted Power-saving prefs to the BLE manager (#477): offload-cadence stretch uses the
    /// battery-% threshold (0 = off when the master is off); the HRV pause only applies while the master is on.
    /// The connection-priority idle throttle is intentionally not wired.
    func applyPowerSaving() {
        let on = PuffinExperiment.powerSavingEnabled
        ble.setLowRefreshMode(on && PuffinExperiment.lowRefreshEnabled)
        ble.setLowBatteryOffloadThrottle(on ? PuffinExperiment.powerSavingBatteryPct : 0)
        ble.setPauseCaptureOnPowerSave(on && PuffinExperiment.pauseHrvOnPowerSaveEnabled,
                                       thresholdPct: PuffinExperiment.powerSavingBatteryPct)
    }
    /// Resolve what this device has banked versus what its unit policy can score and hand the facts to
    /// `LiveState`, so Test Centre exports carry the `rrTransport` line (#2117). Facts only; the judgement is
    /// `UniversalTrace.rrTransportLine`, shared with Android. Silent on failure rather than guessing.
    private func refreshRRTransportFacts() async {
        // No store to ask: drop what was banked rather than leaving a previous answer standing; stale facts would be attributed to now.
        guard let store = await repo.storeHandle() else {
            live.clearRRTransport()
            return
        }
        let owner = repo.deviceId
        let strict = (try? await store.isWhoop5RRSource(deviceId: owner)) ?? false
        // The two MINs are only read by a line the formatter suppresses unless this is strict, so a device the
        // policy does not govern stops after the registry read. A 4.0 in a reconnect burst (#1120) would
        // otherwise fetch timestamps from the store queue the backfill is writing through, only to discard them.
        guard strict else {
            live.setRRTransport(strictWhoop5: false, firstRecordedUnix: nil, firstScorableUnix: nil)
            return
        }
        let firstRecorded = (try? await store.firstRecordedRRTimestamp(deviceId: owner)) ?? nil
        let firstScorable = (try? await store.firstScorableWhoop5RRTimestamp(deviceId: owner)) ?? nil
        live.setRRTransport(strictWhoop5: strict, firstRecordedUnix: firstRecorded,
                            firstScorableUnix: firstScorable)
    }


    /// Record an `APP_VERSION_CHANGED` event on the first launch after an update (#1410). UserDefaults holds
    /// the last-seen version; `"noop-app"` is a synthetic deviceId sentinel (strap ids are UUIDs, so it
    /// cannot collide), shared with Android.
    private func recordAppVersionChangeIfNeeded() async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let last = UserDefaults.standard.string(forKey: "zoop.lastSeenVersion")
        guard AppVersionEvent.shouldRecord(lastSeen: last, current: current), let last else {
            UserDefaults.standard.set(current, forKey: "zoop.lastSeenVersion")
            return
        }
        // A real transition: advance the pointer only once the event is durably recorded, so a not-ready store
        // or failed insert retries next launch.
        guard let store = await repo.storeHandle() else { return }
        let payload = AppVersionEvent.payloadJson(from: last, to: current,
                                                  schemaVersion: WhoopStoreInfo.schemaVersion)
        do {
            try await store.recordEvent(deviceId: "noop-app", ts: Int(Date().timeIntervalSince1970),
                                        kind: AppVersionEvent.kind, payloadJSON: payload)
            UserDefaults.standard.set(current, forKey: "zoop.lastSeenVersion")
        } catch {
        }
    }

    private func wireSourceCoordinator() async {
        guard sourceCoordinator == nil, let store = await repo.storeHandle() else { return }
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        registry.reload()
        let coordinator = SourceCoordinator(
            registry: registry,
            live: live,
            storeHandle: { [weak self] in await self?.repo.storeHandle() },
            // The flag rides the same two closures, inheriting the coordinator's semantics including the Apple Watch
            // exception (calls neither, so it never stops a live WHOOP) (#1881). `stopWhoop` alone was edge-triggered:
            // it dropped the link once and nothing stopped `poweredOn`, state restoration or the standing connect bringing it back.
            startWhoop: { [weak self] in self?.ble.setWhoopIsActiveDevice(true); self?.scan() },
            stopWhoop: { [weak self] in self?.ble.setWhoopIsActiveDevice(false); self?.disconnect() },
            // WHOOP targeting hooks: thin wrappers over BLEManager's additive setters, so the coordinator never
            // references BLEManager directly. On the single-WHOOP path they leave the engine defaults.
            setWhoopPreferredPeripheral: { [weak self] uuid in self?.ble.setPreferredPeripheral(uuid) },
            setWhoopActiveDeviceId: { [weak self] id in self?.ble.setActiveDeviceId(id) },
            connectedPeripheralUUID: ble.$connectedPeripheralUUID.eraseToAnyPublisher(),
            // Generic-HR connect lifecycle goes to the same strap log BLEManager writes (`live.append(log:)`), so a
            // "connected but no data" report (#421) is not blind to the Polar/Wahoo path. "HH:mm:ss" matches BLEManager.log().
            straplog: { [weak self] line in
                self?.live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            },
            ouraNightBand: { [weak self] in self?.ouraNightBand() })   // item 27
        coordinator.start()
        self.deviceRegistry = registry
        // Adoption re-points the strap onto its stable `whoop-<serial>` id inside BLEManager (which holds only
        // the non-observable store); mirror it onto the observable registry or the Devices screen and source
        // coordinator watch an id that no longer exists (#1303).
        self.ble.onSerialIdentityAdopted = { [weak registry] serialId in
            registry?.setActive(serialId)
        }
        self.sourceCoordinator = coordinator
        bindOuraFeatureStatusMirror()
        // Read spine (#814): drive the read side off the registry's `activeDeviceId` for the whole session, as
        // SourceCoordinator does for the write side. The Devices screen calls `registry.setActive` directly, so a
        // one-shot adopt at wiring time would pin reads to the launch-time id. `adoptActiveDevice` is idempotent,
        // so the initial emission does the first adopt and later explicit calls are redundant. Import and
        // computed write targets stay on the canonical id.
        readSpineCancellable = registry.$activeDeviceId
            .removeDuplicates()
            .sink { [weak self] id in
                Task { await self?.adoptActiveDevice(id) }
            }
    }

    /// Re-point the Repository's active-strap read id at `activeId` and, if it moved, refresh and re-score so a
    /// re-added strap's live raw (under its fresh "whoop-<uuid>" id) surfaces (#814). No-op when unchanged.
    /// Union model: this moves only the read-side id. The WHOOP-import and computed write targets and the
    /// FusionSource `.whoopImport` mapping stay on the canonical `deviceId` ("my-whoop") or earlier history
    /// would be orphaned. The Repository reads the union of both; the engine already resolves the active strap
    /// per day (`resolveDayOwner`) and writes to the canonical `-noop` sibling.
    private func adoptActiveDevice(_ activeId: String) async {
        let trimmed = activeId.trimmingCharacters(in: .whitespaces)
        let repoMoved = repo.adoptActiveDeviceId(trimmed)
        guard repoMoved else { return }
        live.append(log: "Read spine re-pointed to active device after registry change (#814).")
        await repo.refresh()
        await intelligence.analyzeRecent()
    }

    #if os(iOS)
    /// Pushes freshly-offloaded data to Apple Health, set by `StrandiOSApp` (#1021). A closure because
    /// `HealthKitBridge` owns iOS-only state while this type is shared with macOS.
    var healthWriteBack: (() async -> Void)?
    #endif

    /// Settle a re-score that is owed (#1538): one an earlier attempt started and was killed partway, or one a
    /// background trigger deferred. Called from the iOS `BGProcessingTask` handler (minutes of runtime, not the
    /// seconds of a bluetooth-central wake) and on foreground entry; a no-op unless something is owed.
    /// Forced rather than `skipIfUnchanged`: an interrupted pass never advanced the watermark (by design), so
    /// the fingerprint question is already known to answer "yes".
    func runDeferredRescoreIfOwed() async {
        await intelligence.runSleepWearRescoreIfNeeded()
        // A pass already running holds the owed mark and settles it; forcing another would queue a second full pass.
        guard RescoreBackgroundScheduler.isRescoreOwed, !intelligence.computing else { return }
        // Force only when the debt is unproven (#2238): an interrupted pass whose watermark never advanced. A pass
        // that completed but was outvoted by a mid-pass token did advance it, so the fingerprint is a real question
        // and "nothing changed" is what lets the chain stop. Otherwise a ring draining every 5 minutes would
        // re-score 21 nights continuously, each pass outlasting the drain interval.
        let fromCompletedPass = RescoreBackgroundScheduler.isOwedAfterCompletedPass
        live.append(log: "re-score: resuming a pass an earlier attempt could not finish (#1538)"
                    + (fromCompletedPass ? " — debt is from a completed pass, gating on the fingerprint (#2238)" : ""))
        await intelligence.analyzeRecent(skipIfUnchanged: fromCompletedPass,
                                         triggerLabel: fromCompletedPass ? "resume-gated" : "resume-forced")
        #if os(iOS)
        // The deferred pass finally produces today's score with no UI attached, so publish the snapshot here too.
        await WidgetSnapshot.publish(from: self)
        // Apple Health too: the post-offload write-back ran before this pass (the offload deferred its re-score
        // here), so last night's sleep and vitals only reached Health on a later foreground. The bridge coalesces
        // a call during an in-flight write-back.
        await healthWriteBack?()
        #endif
    }

    private func refreshAfterCompletedBackfill() async {
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        // The full default window: a shorter read would publish as a change that truncates long-window cards.
        await repo.refresh()
        // Score the freshly-offloaded raw data now rather than waiting for the 15-minute tick, so a just-synced
        // night's Charge / Effort / Rest appears promptly on a strap-only dashboard (#218). analyzeRecent no-ops
        // if a tick is running and refreshes the dashboard itself.
        // `skipIfUnchanged` gates this pass on the complete raw-input fingerprint: an empty/duplicate offload
        // (common on a flapping link) skips the whole-window rescore instead of causing a Trends/streak "0 days"
        // flicker (#1196/#1146). Only this caller opts in.
        // The offload routinely completes while backgrounded (a bluetooth-central stays alive to receive it) and
        // the pass is all-or-nothing, so iOS can suspend the process before it finishes; the watermark advances
        // only on completion, so the next trigger starts another doomed pass, a livelock that burned ~8 minutes
        // of CPU per attempt (#1538). Decide whether the pass can finish here and hand it to a background
        // processing task when it cannot. No-op on macOS; on iOS a foreground pass is never deferred.
        await RescoreBackgroundScheduler.run(passInProgress: intelligence.computing,
                                             log: { [live] line in live.append(log: line) }) {
            await intelligence.analyzeRecent(skipIfUnchanged: true)
        }
        await refreshV5Signals()
        if PuffinExperiment.autoDetectWorkoutsEnabled {
            WorkoutDetectedNotifier.onSyncCompleted(candidate: await repo.autoDetectCandidate(),
                                                   enabled: true)
        }
        #if os(iOS)
        // A backfill routinely completes while backgrounded and the other widget-publish sites are gated on
        // scenePhase == .active, so a background sync would rescore without rewriting the App-Group snapshot or
        // reloading timelines. Publish here on the real "new data landed" signal (#980).
        await WidgetSnapshot.publish(from: self)
        // Same for Apple Health (#1021): the only automatic write-back ran on scenePhase == .active in the block
        // that kicks this offload, so it raced the data and sleep reached Health an app-open late. Set by
        // StrandiOSApp; nil on macOS and in tests.
        await healthWriteBack?()
        #endif
    }

    /// Fold a fresh reading into the smoothing window and republish a stable bpm. Prefers the strap's HR,
    /// falling back to 60000/R-R; clamps to 30-220 (rejects 0 and spikes) and publishes the window median.
    private func ingestHR(heartRate: Int?, rr: [Int]) {
        var inst: Double?
        if let hr = heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            // When the live source is gone (disconnect blanks heartRate and rr), drop the stale median so screens fall
            // through to "-" instead of freezing (#39). A transient out-of-range sample with the link up keeps it.
            if heartRate == nil && rr.isEmpty { resetSmoothing() }
            return
        }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        // Republish only when the smoothed value changes: ingestHR fires at ~1-3 Hz on every heartRate and rr
        // update, and an unconditional assign re-renders every bpm observer (Live, menu bar, widgets).
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed { bpm = smoothed }
        captureWorkoutSample()
        feedStressOnsetDetector()
    }

    // MARK: - Manual workout tracking

    /// Begin a manually-tracked workout for `sport` (default "Other"). The Live card shows elapsed time, live
    /// HR and building strain; End scores and saves under this sport. A single buzz confirms (#519).
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        let started = Date()
        activeWorkout = ActiveWorkout(start: started, sport: resolved)
        // Arm GPS route recording for distance sports (run / ride / walk / hike) (#524). The recorder still
        // captures nothing without When-In-Use permission, and the session always banks HR + Effort. A
        // non-distance sport never touches location.
        activeWorkoutIsGps = WorkoutCatalog.sport(named: resolved)?.isDistanceSport ?? false
        if activeWorkoutIsGps {
            gpsRecorder.start(startMs: Int64(started.timeIntervalSince1970 * 1000))
        }
        // Persist now so an OS kill right after Start, before any HR sample, can be rehydrated and ended (#529).
        persistActiveWorkout()
        emitWorkoutsTrace(WorkoutsTrace.sessionLine(
            event: "start", sportKey: WorkoutSource.traceSportKey(resolved), hrSamples: 0))
        buzz(loops: 1, gate: HapticPrefs.workout)
    }

    /// Emit one `.workouts` test-mode line iff the mode is on. The `TestCentre.active(.workouts)` gate runs
    /// before the @autoclosure builds the line. Diagnostic only.
    private func emitWorkoutsTrace(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts) else { return }
        live.append(log: build(), domain: .workouts)
    }

    /// The gated sink the import handlers pass to importers for Import & Data Ingest test mode. Nil when off,
    /// so the importer takes its untraced path; otherwise a `@Sendable` closure that hops already-redacted
    /// lines to the main actor (LiveState is @MainActor) and appends them tagged `.dataImport`, in order.
    private func importTraceSink() -> (@Sendable ([String]) -> Void)? {
        guard TestCentre.active(.dataImport) else { return nil }
        return { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                for line in lines { self.live.append(log: line, domain: .dataImport) }
            }
        }
    }

    /// Emit the file-meta line for an import run (detected kind, extension, size bucket; never path or name),
    /// tagged `.dataImport`, iff the mode is on. The size is bucketed inside `ImportTrace`.
    private func emitImportFileMeta(kind: DataSourceKind, url: URL) {
        guard TestCentre.active(.dataImport) else { return }
        let ext = url.pathExtension
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        live.append(log: ImportTrace.fileMetaLine(sourceKind: kind, ext: ext, sizeBytes: size),
                    domain: .dataImport)
    }

    /// Persist the in-flight manual workout to `UserDefaults` so it survives an app kill (#529); called on
    /// start and each captured sample, no-op when idle. GPS fixes are banked separately by `ActiveRouteStore`,
    /// keeping this a small per-sample write.
    private func persistActiveWorkout() {
        guard let w = activeWorkout else { return }
        ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                startSec: Int(w.start.timeIntervalSince1970),
                sport: w.sport,
                samples: w.samples,
                avgHr: w.avgHr,
                peakHr: w.peakHr,
                liveStrain: w.liveStrain,
                pausedAtSec: w.pausedAt.map { Int($0.timeIntervalSince1970) },
                pausedDurationSec: Int(w.pausedDuration)))
    }

    /// Rebuild `activeWorkout` from the durable snapshot after an app kill so the session can still be ended
    /// and saved (#529). No-op when a workout is already live (live wins over a stale snapshot) or nothing is
    /// stored. Called once from `init`.
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        var w = ActiveWorkout(start: Date(timeIntervalSince1970: TimeInterval(snap.startSec)),
                              sport: snap.sport)
        w.samples = snap.samples
        w.avgHr = snap.avgHr
        w.peakHr = snap.peakHr
        w.liveStrain = snap.liveStrain
        w.pausedAt = snap.pausedAtSec.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        w.pausedDuration = TimeInterval(snap.pausedDurationSec ?? 0)
        activeWorkout = w

        // Rebuild the transient GPS flag too, or a distance workout restored after a kill resumes as non-GPS:
        // Resume would not restart CoreLocation and End would not ask for the route. Re-arm from the original
        // start so elapsed-time basis holds; a restored paused session stays paused until resumed.
        activeWorkoutIsGps = WorkoutCatalog.sport(named: snap.sport)?.isDistanceSport ?? false
        if activeWorkoutIsGps {
            gpsRecorder.restore(
                startMs: Int64(snap.startSec) * 1000,
                pausedAtMs: snap.pausedAtSec.map { Int64($0) * 1000 },
                pausedDurationMs: Int64(snap.pausedDurationSec ?? 0) * 1000
            )
        }
    }

    func toggleWorkoutPause() {
        guard var w = activeWorkout else { return }
        if let pausedAt = w.pausedAt {
            w.pausedDuration += Date().timeIntervalSince(pausedAt)
            w.pausedAt = nil
            if activeWorkoutIsGps { gpsRecorder.resume() }
        } else {
            w.pausedAt = Date()
            if activeWorkoutIsGps { gpsRecorder.pause() }
        }
        activeWorkout = w
        persistActiveWorkout()
    }

    func discardWorkout() {
        guard activeWorkout != nil else { return }
        activeWorkout = nil
        if activeWorkoutIsGps { gpsRecorder.stop() }
        activeWorkoutIsGps = false
        ActiveWorkoutPersistence.clear()
        lastWorkout = nil
    }

    /// Shortest live session worth keeping; below this a start/stop is an accident, not training (#2278).
    static let minimumWorkoutSeconds: TimeInterval = 60

    /// Whether a finished live session is too short to save. A named predicate so a test pins the boundary:
    /// exactly `minimumWorkoutSeconds` is kept.
    nonisolated static func isTooShortToSave(elapsedSeconds: TimeInterval) -> Bool {
        elapsedSeconds < minimumWorkoutSeconds
    }

    /// Finish the active workout: finalize the GPS route (#524), score the captured HR window and save it
    /// as a `WorkoutRow`. A session with no HR window and no real route is discarded quietly, but a
    /// GPS-only walk with no HR stream still saves. A double buzz confirms.
    func endWorkout() {
        guard let w = activeWorkout else { return }
        activeWorkout = nil
        let wasGps = activeWorkoutIsGps
        activeWorkoutIsGps = false
        ActiveWorkoutPersistence.clear()
        // Finalize the GPS route (#524): stop the recorder and take its route, which accumulated independently of
        // the HR window. `capturedRoute()` is nil unless at least 2 points landed (no route or distance for a Mac
        // with no GPS or denied permission). A non-GPS session never armed the recorder.
        var route: WorkoutRoute?
        if wasGps {
            gpsRecorder.stop()
            route = gpsRecorder.capturedRoute()
        }
        let samples = w.samples
        guard samples.count >= 2 || route != nil else {
            emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                event: "discarded", sportKey: WorkoutSource.traceSportKey(w.sport),
                hrSamples: samples.count, gpsPoints: route == nil ? 0 : nil))
            lastWorkout = nil
            return
        }
        let end = Date()
        // A session under a minute is a start/stop the wearer did not mean to keep; the list filled with 5-30
        // second entries and made deletion feel broken (#2278). Discarded here at save rather than pruned later:
        // there is no server or cloud copy, so a later prune would be irreversible, while nothing with real data
        // is removed here. Sits after the sample/route gate so that gate's meaning is unchanged (a 30-second
        // session can carry two HR samples).
        let elapsed = w.elapsed(at: end)
        if Self.isTooShortToSave(elapsedSeconds: elapsed) {
            emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                event: "discarded", sportKey: WorkoutSource.traceSportKey(w.sport),
                hrSamples: samples.count, durationSec: Int(elapsed),
                gpsPoints: wasGps ? gpsRecorder.pointCount : nil))
            lastWorkout = nil
            return
        }
        let avg = samples.isEmpty ? nil
            : Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = w.savedPeak
        // Score the saved workout with the wearer's measured resting HR, not the default 60 (#983): %HRR is
        // (bpm - resting) / (max - resting), so the default moves every zone boundary (at 136 bpm with max 190 it
        // separates zone 1 from 2). Today's Effort and the manual rescore (#972) already thread it. Read once at
        // save time; the live readout is a transient estimate.
        let restingHR = repo.today?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let strain = samples.count >= 2
            ? StrainScorer.strain(samples, maxHR: Double(profile.hrMax),
                                  restingHR: restingHR,
                                  method: PuffinExperiment.effortMethod, sex: profile.sex) : nil
        // Estimate calories from the captured HR window (same Keytel/Harris-Benedict model as the auto-detector) (#117).
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = samples.count >= 2
            // Same measured resting HR as the strain above, not nil (#983): the calories model's active threshold is
            // resting + 30% HRR, and #972 threads it in the rescore path.
            ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax),
                                            restingHR: restingHR).0
            : 0
        let startTs = Int(w.start.timeIntervalSince1970)
        let row = WorkoutRow(
            startTs: startTs, endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: w.elapsed(at: end),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            // GPS distance rides the shared row so the Workouts list shows it like any distance workout; the polyline
            // is persisted in RouteStore (`WorkoutRow` has no route column on Apple). Only a real route sets distance.
            distanceM: route?.distanceM, zonesJSON: nil, notes: nil, steps: nil)
        if let route { RouteStore.store(route, startTs: startTs, sport: w.sport) }
        lastWorkout = row
        emitWorkoutsTrace(WorkoutsTrace.sessionLine(
            event: "end", sportKey: WorkoutSource.traceSportKey(w.sport), hrSamples: samples.count,
            durationSec: Int(w.elapsed(at: end)),
            gpsPoints: wasGps ? gpsRecorder.pointCount : nil))
        buzz(loops: 2, gate: HapticPrefs.workout)
        Task { [weak self] in
            guard let self else { return }
            if let store = await self.repo.storeHandle() {
                _ = try? await store.upsertWorkouts([row], deviceId: self.deviceId)
                await self.repo.refresh()
            }
        }
    }

    /// Append the current smoothed `bpm` to the active workout and recompute its running strain. Called from
    /// `ingestHR` on every fresh sample; no-op when idle. Cheap at the ~1 Hz cadence.
    private func captureWorkoutSample() {
        guard var w = activeWorkout, !w.isPaused, let hr = bpm else { return }
        let peakBefore = w.peakHr
        guard w.recordSample(HRSample(ts: Int(Date().timeIntervalSince1970), bpm: hr)) else {
            if w.peakHr != peakBefore { activeWorkout = w }
            return
        }
        w.peakHr = max(w.peakHr, hr)
        w.avgHr = Int((Double(w.samples.map(\.bpm).reduce(0, +)) / Double(w.samples.count)).rounded())
        w.liveStrain = StrainScorer.strain(w.samples, maxHR: Double(profile.hrMax),
                                              method: PuffinExperiment.effortMethod, sex: profile.sex) ?? 0
        activeWorkout = w
        persistActiveWorkout()
    }

    /// Drop the smoothing window and blank the hero number so a resume shows "-" until a fresh sample
    /// arrives, instead of republishing the stale pre-gap median (#46). Called on Live-tab entry / manual
    /// Start HR (see `startRealtimeHR`), not the 30s keep-alive re-arm.
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// The unit-tested `StressOnsetDetector` decides whether to offer a 60-s guided breath: on a fresh,
    /// non-metabolic HRV dip while still, it fires one confirming buzz and posts a passive nudge to
    /// `stressNudgeCenter`. Its replay-safe state is persisted via `BiofeedbackPrefs`. "Stress" here is an
    /// autonomic proxy vs the user's own baseline, never a diagnosis. This only feeds live R-R into the
    /// trigger; the stress level the app shows comes from `DaytimeStress` alone.
    private func feedStressOnsetDetector() {
        // Once per R-R packet: `ingestHR` runs from both the heart-rate and R-R sinks, which would otherwise
        // enter intervals into `rrBuf` and advance the slow baseline twice per packet.
        guard stressPackets.isNew(live.rrSeq) else { return }
        let fresh = live.rr.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
        guard !fresh.isEmpty else { return }
        rrBuf.append(contentsOf: fresh)
        if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }

        let cfg = BiofeedbackPrefs.stressConfig()
        guard cfg.enabled, live.bonded, live.worn else { return }
        let decision = StressOnsetDetector.evaluate(
            rrBuffer: rrBuf,
            currentHR: bpm.map(Double.init),
            recentMotionG: nil,   // wrist gravity is offloaded + lags live; the resting-HR band is the gate
            sessionActive: stressNudgeCenter.pending != nil,   // never stack a fresh nudge over a live one
            state: stressState,
            config: cfg,
            nowSec: Int(Date().timeIntervalSince1970),
            tzOffsetSec: TimeZone.current.secondsFromGMT())
        stressState = decision.nextState
        BiofeedbackPrefs.saveStressState(decision.nextState)
        guard decision.shouldNudge else { return }
        if canBuzz { buzz(loops: UInt8(clamping: decision.buzzLoops)) }
        stressNudgeCenter.present(fastRMSSD: decision.fastRMSSD, baselineRMSSD: decision.baselineRMSSD)
        live.append(log: "Stress check-in , HRV dipped while still")
    }

    /// Whether the encrypted channel is up so a confirming buzz can fire (the command characteristic is gated on bond).
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    /// Start scanning for the strap. With no model given, uses the persisted "selectedWhoopModel" so every scan entry point agrees.
    func scan(model: WhoopModel? = nil) {
        let chosen = model
            ?? UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:))
            ?? .whoop4
        ble.connect(model: chosen)
    }
    func disconnect() { ble.disconnect() }
    /// Restart the connected strap (user-initiated, confirmation-gated in DevicesView). Non-destructive: the
    /// strap keeps its data and re-advertises; Zoop auto-reconnects. See BLEManager.rebootStrap().
    func rebootStrap() { ble.rebootStrap() }
    /// Send one WHOOP 4.0 reboot-probe candidate (Test Centre, 4.0 only, confirmation-gated), to find the real
    /// reboot frame when the production one is ignored (#235).
    func rebootProbe(_ variant: RebootProbeVariant) { ble.rebootProbe(variant) }

    func probeExtendedBatteryInfo() { ble.probeExtendedBatteryInfo() }
    func clearExtendedBatteryProbe() { ble.clearExtendedBatteryProbe() }

    func probeBodyLocationAndStatus() { ble.probeBodyLocationAndStatus() }
    func clearBodyLocationProbe() { ble.clearBodyLocationProbe() }

    // Read-only feature-flag enumeration probe (117/118): reads the flag names, writes nothing. User-initiated, Test-Centre-gated (#761).
    func probeFeatureFlags() { ble.probeFeatureFlags() }
    func clearFeatureFlagProbe() { ble.clearFeatureFlagProbe() }

    // WHOOP MG ECG experimental probe. Entry points are user-initiated and confirmation-gated, and BLEManager
    // re-gates sends on the Experimental opt-in plus a positively-identified MG. Unvalidated instrumentation,
    // never a medical measurement.
    /// True only for a positively identified WHOOP MG; the gate the ECG UI is offered behind.
    var isWhoop5MG: Bool { ble.isWhoop5MG }
    /// Persistent strap write, deliberately its own action rather than part of the start flow.
    func ecgSelectWrist(_ wrist: Whoop5Ecg.WristSelection) { ble.ecgSelectWrist(wrist) }
    func ecgStartCapture() { ble.ecgStartCapture() }
    /// `reportsResult: false` for the Settings-toggle path so switching the experiment off does not pop the
    /// Devices result sheet.
    func ecgStopCapture(reportsResult: Bool = true) { ble.ecgStopCapture(reportsResult: reportsResult) }
    func clearEcgProbe() { ble.clearEcgProbe() }
    /// True once a start has been sent this session and no stop has completed; keeps Stop reachable after the opt-in is switched off.
    var ecgMayBeRunning: Bool { ble.ecgMayBeRunning }
    // Read-only device-config probe (121/128): asks for a key's value, following #761's key-name enumeration (#103). Writes nothing. User-initiated, Test-Centre-gated.
    func probeDeviceConfigValues() { ble.probeDeviceConfigValues() }
    func clearDeviceConfigProbe() { ble.clearDeviceConfigProbe() }

    func prepareStrapSwitch() { ble.prepareForModelSwitch() }

    // MARK: - Add-a-device wizard (WHOOP present-scan + register/activate)
    // Thin pass-throughs over BLEManager's public present-scan surface so the wizard never references
    // BLEManager directly. The wizard observes `ble.discoveredWhoops` for WHOOP families and runs its own
    // `StandardHRSource` for generic straps (see AddDeviceWizard).

    /// The straps surfaced by the WHOOP present-scan, for the wizard's live list; refreshed as RSSI updates.
    var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] { ble.discoveredWhoops }

    /// True when the selected/connected strap is a WHOOP 5/MG (window onto `BLEManager.isWhoop5`). The
    /// Smart-alarm card uses it to give a 5/MG owner honest "saved but not armed until Experimental is on"
    /// copy (#864).
    var whoop5Detected: Bool { ble.isWhoop5 }

    /// Point the WHOOP scan at a family, then present nearby straps without auto-connecting.
    /// `prepareForModelSwitch()` clears any sticky bond so the engine is idle, `connect(model:)` selects the
    /// family and framing, and `scanForWhoops()` takes over in present-mode (stopping the connect's scan). The
    /// persisted `selectedWhoopModel` is updated so a later real connect targets the right family.
    func presentWhoopScan(model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.prepareForPresentScan(model: model) // idle for a family switch, but KEEP a live same-family bond (#74)
        ble.connect(model: model)             // select the family (sets engine selectedModel + framing)
        ble.scanForWhoops()                   // take over the central, present nearby straps only
    }

    func stopWhoopScan() { ble.stopWhoopScan() }

    /// Register a paired device and optionally make it active. The Add-a-device wizard's single write path:
    /// `add` upserts the row and `setActive` promotes it (SourceCoordinator then connects). No-op until the
    /// registry is wired (post store-open).
    func registerDevice(_ device: PairedDevice, makeActive: Bool) {
        guard let registry = deviceRegistry else { return }
        registry.add(device)
        if makeActive {
            // `setActive` republishes `registry.$activeDeviceId`, which the read-spine subscription
            // (`readSpineCancellable`) re-points reads off. The explicit adopt below is an idempotent immediate re-point.
            registry.setActive(device.id)
            Task { [weak self] in await self?.adoptActiveDevice(device.id) }
        }
    }

    #if os(iOS)
    /// Materialize Apple Health as a device and update the source that feeds Today. Replaces the seeded WHOOP
    /// row only while it is still an empty placeholder; a physical or user-selected source keeps priority.
    func refreshAfterAppleHealthSync(authorized: Bool, now: Date = Date()) async {
        await wireSourceCoordinator()
        guard let registry = deviceRegistry, let store = await repo.storeHandle() else {
            await repo.refresh()
            return
        }

        let current = registry.devices.first(where: { $0.id == registry.activeDeviceId })
        var currentHasRecentData = false
        if let current {
            let range = AppleWatchDevice.recentDayRange(now: now)
            let cutoff = Int(now.timeIntervalSince1970) - AppleWatchDevice.recentWindowDays * 86_400
            let latestHR = (try? await store.latestHRSampleTs(deviceId: current.id)) ?? nil
            let recentDaily = (try? await store.dailyMetrics(
                deviceId: current.id, from: range.from, to: range.to)) ?? []
            currentHasRecentData = (latestHR ?? 0) >= cutoff || !recentDaily.isEmpty
        }

        await AppleWatchDevice.registerIfAuthorized(
            registry: registry, store: store, authorized: authorized, now: now)
        guard registry.devices.contains(where: { $0.id == AppleWatchDevice.deviceId }) else {
            await repo.refresh()
            return
        }

        if AppleWatchDevice.shouldAutoActivate(
            current: current, currentHasRecentData: currentHasRecentData) {
            registry.setActive(AppleWatchDevice.deviceId)
            await adoptActiveDevice(AppleWatchDevice.deviceId)
        } else if registry.activeDeviceId == AppleWatchDevice.deviceId {
            await adoptActiveDevice(AppleWatchDevice.deviceId)
            await repo.refresh()
        } else {
            await repo.refresh()
        }
    }
    #endif

    // MARK: - Oura adopt (factory-reset-and-adopt)

    /// The live adopt outcome of the active Oura ring, mirrored off the coordinator's `OuraLiveSource` so the
    /// Add-device wizard can drive its "Taking over your ring" step to success or Failed without reaching into
    /// the BLE layer. nil when no Oura source is live or no adopt is in flight.
    @Published private(set) var ouraAdoptPhase: OuraLiveSource.AdoptPhase = .idle
    /// The active Oura ring's needs-pairing message (mirrored off the live source), shown verbatim on the
    /// wizard's Failed step. nil when fine or no Oura source is live.
    @Published private(set) var ouraNeedsPairing: String?
    /// Subscriptions mirroring the live Oura source's `adoptPhase` / `needsPairing` into the properties above;
    /// re-bound when the active Oura source changes.
    private var ouraAdoptCancellables = Set<AnyCancellable>()

    /// The latest `feature status` read-back per feature id (0x04 SpO2, 0x0b real-steps, 0x03 exercise-HR,
    /// 0x0d CVA-PPG), mirrored off the live Oura source so Test Centre rows show the ring's own state. Bound
    /// once right after `sourceCoordinator` is set; live for any paired ring, not just mid-adopt.
    @Published private(set) var ouraFeatureStatuses: [Int: OuraFeatureStatus] = [:]
    private var ouraFeatureStatusCancellable: AnyCancellable?

    /// The live ring's link phase (`disconnected` / `connecting` / `authenticating` / `authenticated`),
    /// mirrored off the live Oura source for the Live console's status and reconnect affordance (#2305).
    /// `.disconnected` when no ring source is live.
    @Published private(set) var ouraLinkPhase: OuraLiveSource.LinkPhase = .disconnected
    private var ouraLinkPhaseCancellable: AnyCancellable?

    /// (Re)bind the feature-status and link-phase mirrors to whichever `OuraLiveSource` is live, on every
    /// later swap; same shape as `bindOuraAdoptMirror`.
    private func bindOuraFeatureStatusMirror() {
        guard let coordinator = sourceCoordinator else { return }
        ouraFeatureStatusCancellable = coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<[Int: OuraFeatureStatus], Never> in
                source?.$featureStatuses.eraseToAnyPublisher()
                    ?? Just([:]).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraFeatureStatuses = $0 }
        ouraLinkPhaseCancellable = coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<OuraLiveSource.LinkPhase, Never> in
                source?.$linkPhase.eraseToAnyPublisher()
                    ?? Just(.disconnected).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraLinkPhase = $0 }
    }

    /// Reconnect the active ring on request from the Live console (#2305); routed through the coordinator so
    /// it only reaches the live source.
    func reconnectOuraRing() {
        sourceCoordinator?.reconnectActiveRing()
    }

    /// Take over a factory-reset Oura ring: grant the coordinator adopt consent for this ring (so its live
    /// session may run the one-time key install), register it active, then mirror its adopt outcome. The
    /// irreversible-consent gate was already passed in the wizard; this is the commit.
    func adoptOuraRing(_ device: PairedDevice) {
        sourceCoordinator?.requestOuraAdopt(deviceId: device.id)
        ouraAdoptPhase = .idle
        ouraNeedsPairing = nil
        registerDevice(device, makeActive: true)
        bindOuraAdoptMirror()
    }

    /// (Re)bind the adopt-outcome mirror to the live `OuraLiveSource` and each later swap. `flatMap` tracks
    /// the current source's `adoptPhase` (`.idle` with no source) without leaking subscriptions.
    private func bindOuraAdoptMirror() {
        ouraAdoptCancellables.removeAll()
        guard let coordinator = sourceCoordinator else { return }
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<OuraLiveSource.AdoptPhase, Never> in
                source?.$adoptPhase.eraseToAnyPublisher()
                    ?? Just(.idle).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraAdoptPhase = $0 }
            .store(in: &ouraAdoptCancellables)
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<String?, Never> in
                source?.$needsPairing.eraseToAnyPublisher()
                    ?? Just(nil).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraNeedsPairing = $0 }
            .store(in: &ouraAdoptCancellables)
    }

    /// How many on-screen surfaces want the realtime HR stream (the Live tab and the in-exercise
    /// LiveWorkoutView, which can both be open, or the workout can be reached without Live ever appearing).
    /// The stream stays armed while any is visible, so a second surface never disarms the first (#681: a
    /// WHOOP 5/MG manual workout started without opening Live got no live HR and was silently discarded).
    private var realtimeWanters = 0

    /// A live-HR surface appeared. Arms the realtime stream on the 0-to-1 edge and only then blanks the stale
    /// smoothing window (#46). The keep-alive re-arm calls `ble.startRealtime()` directly, not this. Each
    /// surface balances this with exactly one `stopRealtimeHR()` on disappear.
    func startRealtimeHR() {
        if realtimeWanters == 0 {
            resetSmoothing()
            ble.startRealtime()
        }
        realtimeWanters += 1
    }
    /// A live-HR surface went away. Stops the stream on the 1-to-0 edge (the 0x2A37 HR keeps recording).
    /// Clamped at 0 so an unbalanced stop cannot wedge the stream off.
    func stopRealtimeHR() {
        realtimeWanters = max(0, realtimeWanters - 1)
        if realtimeWanters == 0 { ble.stopRealtime() }
    }

    /// Re-issue the BLE realtime arm without touching the ref-count, for a fresh connection/bond while a
    /// surface is already showing live HR. No-op when nothing wants the stream.
    func rearmRealtimeIfWanted() {
        guard realtimeWanters > 0 else { return }
        ble.startRealtime()
    }
    func getBattery() { ble.refreshBattery() }

    /// Fire a haptic buzz on the strap (patternId=2 is the on-device-confirmed graduated buzz; `loops` sets
    /// length). For scheduled cues. Needs a bonded connection (the command characteristic is gated on bond).
    /// For a user-facing "buzz now" use `buzzStrapOnce()` (#921).
    func buzz(loops: UInt8 = 2) {
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    /// An in-session cue buzz gated by its per-event `HapticPrefs` toggle (opt-in), so the enable check lives
    /// in one place (#1115). The ungated `buzz` / `buzzStrapOnce` remain for ambient cues with their own gates
    /// and explicit user buzzes.
    func buzz(loops: UInt8 = 2, gate: String) {
        if HapticPrefs.enabled(gate) { buzz(loops: loops) }
    }

    /// One-shot user buzz (#921): the confirmed pattern (patternId=2, 3 loops) then RUN_ALARM, both
    /// acknowledged. A bare RUN_HAPTICS_PATTERN write can be silently ignored (4.0 via Siri shortcut) or
    /// dropped unacked on a busy link, so the Live button and Buzz Strap intent share this sequence.
    func buzzStrapOnce() {
        ble.buzzStrapOnce()
    }


    /// Tell the strap to stop an in-progress haptic pattern (#769). Cancelling app-side DispatchWorkItems
    /// stops new pulses but cannot recall a running pattern; if the link drops mid-pattern the strap's haptic
    /// manager can wedge. STOP_HAPTICS (cmd 122, payload [0x00]) is the documented, reversible clear for WHOOP 4.0.
    /// 5/MG caveat: its buzz is a one-shot on the maverick 0x13 path and cmd 122 is unconfirmed there, so
    /// `send` does not allow-list it for that family and this logs "skipped" rather than guessing an opcode.
    /// Best-effort and safe to call always.
    func stopHaptics() {
        ble.send(.stopHaptics, payload: [0x00])
    }

    // MARK: - Wrist-buzz mirror notifications (PR #577 , iOS only)
    // iOS cannot keep a pocketed strap buzz silent the way macOS shows it on screen, so a wrist buzz the user
    // might miss (long sedentary stretch, smart-alarm wake) is also posted as a local notification. macOS
    // never calls these (`#if os(iOS)`). Both are gated on `notif.masterEnabled` (#572), the same switch as the
    // iOS "Wrist alerts" toggle and the SedentaryDetector.

    static let wristAlertsMasterKey = "notif.masterEnabled"

    static func postInactivity(minutes: Int) {
        #if os(iOS)
        let body = minutes > 0
            ? String(localized: "You've been seated for about \(minutes) min. Time to move.")
            : String(localized: "Time to move. You've been seated a while.")
        postWristAlert(identifier: "inactivity-nudge", title: String(localized: "Move reminder"), body: body)
        #endif
    }

    static func postSmartAlarm() {
        #if os(iOS)
        postWristAlert(identifier: "smart-alarm-wake", title: String(localized: "Smart alarm"),
                       body: String(localized: "Good morning. Your smart alarm just woke you."))
        #endif
    }

    #if os(iOS)
    /// Gate on the wrist-alerts master, then deliver only if the OS already authorized notifications (no
    /// second prompt). A fresh identifier per category replaces the old alert rather than stacking.
    private static func postWristAlert(identifier: String, title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: wristAlertsMasterKey) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
    #endif

    /// Identifier base for the smart-alarm backup wake notification(s): used directly for every-day, fanned
    /// out to "<base>-d<weekday>" per weekday so a re-arm replaces by id. Separate from "smart-alarm-wake"
    /// (the strap-confirmed mirror) to avoid collisions.
    private static let smartAlarmBackupId = "smart-alarm-wake-backup"
    private static var smartAlarmBackupIds: [String] {
        [smartAlarmBackupId] + (1...7).map { "\(smartAlarmBackupId)-d\($0)" }
    }

    /// Schedule a best-effort repeating daily backup wake notification for the smart alarm (#4, #6). The strap
    /// alarm is one absolute instant and `postSmartAlarm` only posts after the strap reports it fired, so a
    /// failed buzz or suspended phone left no OS-level wake. A repeating `UNCalendarNotificationTrigger` lives
    /// in the notification center, so it survives relaunch and fires with the app killed.
    /// Not a guaranteed loud alarm: a sideloaded build has no critical-alert entitlement, so Focus / silent
    /// mode can suppress the sound; the UI copy says to keep a real backup.
    /// Gated on the alarm being enabled (its sole caller `applySmartAlarm()` enforces that) plus notification
    /// permission, not the wrist-alerts master (#34). With permission undetermined the user is prompted here
    /// and scheduled on grant, covering the first night. Always removes the prior set first. `weekdays` empty =
    /// every day; non-empty fans out to one weekday-pinned trigger per day. No-op on macOS.
    /// `log` is a strap-log sink for the not-authorized bail (#401); the caller hops it to the main actor.
    /// `overrides` carries per-weekday wake-time overrides (#554, #1864): an overridden weekday fires at its
    /// own time instead of `minutes`; an empty map is the plain path.
    static func scheduleSmartAlarmBackupNotification(minutes: Int, weekdays: Set<Int>,
                                                     overrides: [Int: Int] = [:],
                                                     log: ((String) -> Void)? = nil) {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        // Clear both the single and per-day ids so switching modes or editing the weekday set never orphans or double-fires a trigger.
        center.removePendingNotificationRequests(withIdentifiers: smartAlarmBackupIds)
        guard AlarmBackupPrefs.isEnabled else { return }
        // The backup follows the alarm, not the wrist-alerts master (#34): this is only reached from
        // applySmartAlarm() with the alarm enabled, and a user with a smart alarm but no wrist HR/strain alerts
        // must still get a backup wake.
        let valid = weekdays.filter { (1...7).contains($0) }
        if !weekdays.isEmpty && valid.isEmpty { return }
        // Only valid override entries (day 1-7, minute in [0, 1440)) count; other days use `minutes` (#1864).
        let cleanOverrides = overrides.filter { (1...7).contains($0.key) && (0..<24 * 60).contains($0.value) }

        func addRequests() {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Smart alarm")
            content.body = String(localized: "Backup wake: your smart alarm time is here.")
            content.sound = .default
            if weekdays.isEmpty {
                // Every day. With overrides, fan out to per-weekday triggers so an override fires at the right time even
                // on a day the weekday set does not restrict; without them, the single daily trigger.
                if cleanOverrides.isEmpty {
                    let hour = minutes / 60
                    let minute = minutes % 60
                    var comps = DateComponents()
                    comps.hour = hour
                    comps.minute = minute
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                    center.add(UNNotificationRequest(identifier: smartAlarmBackupId, content: content, trigger: trigger))
                } else {
                    for weekday in 1...7 {
                        let m = cleanOverrides[weekday] ?? minutes
                        var comps = DateComponents()
                        comps.weekday = weekday
                        comps.hour = m / 60
                        comps.minute = m % 60
                        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                        center.add(UNNotificationRequest(identifier: "\(smartAlarmBackupId)-d\(weekday)",
                                                         content: content, trigger: trigger))
                    }
                }
            } else {
                for weekday in valid {
                    let m = cleanOverrides[weekday] ?? minutes
                    var comps = DateComponents()
                    comps.weekday = weekday   // Calendar weekday 1=Sun…7=Sat , fires weekly on that day
                    comps.hour = m / 60
                    comps.minute = m % 60
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                    center.add(UNNotificationRequest(identifier: "\(smartAlarmBackupId)-d\(weekday)",
                                                     content: content, trigger: trigger))
                }
            }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                addRequests()
            case .notDetermined:
                // Permission was never requested (wrist alerts, which used to prompt, may be off). Ask now and schedule
                // on grant so the first night is covered.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { addRequests() }
                    else { log?("Smart alarm: backup notification NOT scheduled (notification permission denied)") }
                }
            default:
                log?("Smart alarm: backup notification NOT scheduled (notifications not authorized)")
            }
        }
        #endif
    }

    static func cancelSmartAlarmBackupNotification() {
        #if os(iOS)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: smartAlarmBackupIds)
        #endif
    }

    /// Warn about a strap last seen low that has not been heard from since (#2556). The live crossings only
    /// run when a reading arrives, so a strap that drains out of range is never judged by them; this reads the
    /// last banked reading. `connected: false` is sound, not a shortcut: a connected strap banks a reading
    /// about every minute, so its last value can never clear the staleness window. Kotlin twin: `StaleBatteryWorker`.
    @MainActor
    func checkStrapNotSeen() async {
        guard let last = await repo.latestBattery() else { return }
        BatteryNotifier.onStrapNotSeen(
            lastSocPct: last.soc.map { Int($0.rounded()) },
            lastTsSec: last.ts,
            lastCharging: last.charging,
            nowSec: Int(Date().timeIntervalSince1970),
            connected: false,
            enabled: behavior.batteryAlerts)
    }

    lazy var smartWake = SmartWakeWindow(model: self)

    /// The next moment the strap alarm will actually buzz, or nil when nothing will fire. The one funnel every
    /// alarm readout resolves through (Alarms screen, Home's evening card), on the same pure
    /// `nextSmartAlarmDate` the strap is armed from. A WHOOP 5/MG arms only with Experimental on (#864).
    func nextArmedStrapAlarm(from now: Date = Date()) -> Date? {
        guard behavior.smartAlarmEnabled, !(whoop5Detected && !PuffinExperiment.isEnabled) else { return nil }
        return Self.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                       weekdays: behavior.smartAlarmWeekdays,
                                       overrides: WindDownNudge.perDayWakeOverrides,
                                       from: now)
    }

    /// Arm (or clear) the strap's firmware alarm from the smart-alarm settings; it fires even with the app
    /// closed. No-op until bonded (send is gated on bond). On iOS this also (dis)arms the backup wake
    /// notification (#4, #6). Per-weekday wake-time overrides (`WindDownNudge.perDayWakeOverrides`, #554)
    /// flow into both the firmware alarm and the backup (#1864), so "Tuesday 03:30" wakes at 03:30 on Tuesday.
    func applySmartAlarm() {
        WindDownNudge.refresh()
        let overrides = WindDownNudge.perDayWakeOverrides
        guard behavior.smartAlarmEnabled else {
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            smartWake.plan(nextAlarm: nil)
            return
        }
        guard let next = Self.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                                 weekdays: behavior.smartAlarmWeekdays,
                                                 overrides: overrides) else {
            // No enabled weekday in the next week (only from a corrupted set): disarm rather than arm a time nobody asked for.
            ble.disableStrapAlarm()
            Self.cancelSmartAlarmBackupNotification()
            return
        }
        ble.armStrapAlarm(at: smartWake.effectiveAlarm(for: next))
        smartWake.plan(nextAlarm: next)
        // Replace (remove and re-add by stable id) on every re-arm so the backup never stacks. The log sink hops
        // to the main actor because the auth check completes off-main (as `importTraceSink` does).
        Self.scheduleSmartAlarmBackupNotification(minutes: behavior.smartAlarmMinutes,
                                                  weekdays: behavior.smartAlarmWeekdays,
                                                  overrides: overrides,
                                                  log: { [weak self] line in
                                                      Task { @MainActor in self?.live.append(log: line) }
                                                  })
    }

    /// Next fire date for the smart alarm, honouring the weekday selection.
    /// - `minutes`: target wake time, minutes since local midnight.
    /// - `weekdays`: Calendar weekday numbers (1 = Sun ... 7 = Sat); empty = every day; others ignored.
    /// - `overrides`: per-weekday wake-time overrides (#554, #1864); only valid entries (day 1-7, minute in
    /// [0, 1440)) count, other days use `minutes`.
    /// Returns the next strictly-future date on an enabled weekday within today plus 7 days, else nil. Pure so
    /// it can be tested against a fixed clock.
    nonisolated static func nextSmartAlarmDate(minutes: Int,
                                               weekdays: Set<Int>,
                                               overrides: [Int: Int] = [:],
                                               from now: Date = Date(),
                                               calendar cal: Calendar = .current) -> Date? {
        let valid = weekdays.filter { (1...7).contains($0) }
        // Empty means every day. A non-empty selection that filters to nothing has no valid day: nil, not a daily alarm.
        if !weekdays.isEmpty && valid.isEmpty { return nil }
        let cleanOverrides = overrides.filter { (1...7).contains($0.key) && (0..<24 * 60).contains($0.value) }
        // Scan today through +7 days so a once-a-week alarm for "today, already passed" resolves to next week.
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            // Resolve the weekday first so the per-day override is applied before the strictly-future check (a later
            // override time can keep today's occurrence pending).
            let dow = cal.component(.weekday, from: day)
            if !weekdays.isEmpty && !valid.contains(dow) { continue }
            let wakeMin = cleanOverrides[dow] ?? minutes
            let hour = wakeMin / 60
            let minute = wakeMin % 60
            guard let fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if fire <= now { continue }
            return fire
        }
        return nil
    }

    /// Re-arms the single-instant firmware alarm daily (just after local midnight) so a continuously-bonded
    /// strap keeps waking the user. macOS keeps running; iOS also re-arms on foreground (no timers while
    /// suspended). `applySmartAlarm` self-gates, so this is a no-op when the alarm is off.
    private func scheduleDailySmartAlarmRearm() {
        smartAlarmRearmTimer?.invalidate()
        let cal = Calendar.current
        guard let firstFire = cal.nextDate(after: Date(),
                                           matching: DateComponents(hour: 0, minute: 1, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: firstFire, interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor. applySmartAlarm self-gates (and re-asserts the disarmed state).
            Task { @MainActor in self?.applySmartAlarm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        smartAlarmRearmTimer = timer
    }

    // MARK: - Physical inputs / wear automation

    /// Set by a running Lift Log session to claim the strap's double-tap for the session, so a set can be
    /// logged with the phone face-down. Cleared at session end, handing the gesture back; the user's setting
    /// is never read or written. A double tap, because a strap takes knocks against bars and benches.
    var strapDoubleTapOverride: (@MainActor () -> Void)?

    private func handleDoubleTap() {
        let now = Date()
        let since = now.timeIntervalSince(lastDoubleTapAt)
        guard since > 1.2 else {   // debounce repeats
            live.append(log: Self.stamped(String(format: "Double-tap ignored: %.1f s after the previous one (debounce 1.2 s)", since)))
            return
        }
        lastDoubleTapAt = now
        if let override = strapDoubleTapOverride {
            live.append(log: Self.stamped("Double-tap → Lift Log: next"))
            override()
            return
        }
        live.append(log: Self.stamped("Double-tap → \(behavior.doubleTapAction.label)"))
        runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
    }

    /// Run a configured Mac action. In-app actions (buzz/moment) stay on-device; lock and shortcuts go through MacActions.
    func runMacAction(_ kind: MacActionKind, shortcut: String) {
        switch kind {
        case .none: break
        case .lockScreen:
            if !MacActions.lockScreen() {
                #if os(macOS)
                MacActions.runShortcut("Lock Screen")   // login.framework unavailable , fall back to a Shortcut
                #endif
            }
        case .buzzBack: buzz(loops: 1)
        case .markMoment: markMoment()
        case .sleepMark: markSleep()
        case .hapticClock: ble.buzzTimeNow(is24h: Self.localeUses24HourClock)
        case .runShortcut: MacActions.runShortcut(shortcut)
        }
    }

    /// Whether the locale formats time on a 24-hour clock; drives the Haptic Clock's hour encoding (#460).
    /// Derived from the "j" template: a 12-hour locale includes the AM/PM symbol.
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: AppLanguage.activeLocale) ?? "h"
        return !fmt.contains("a")
    }

    func markMoment() { markMoment(at: Date()) }

    /// Record a "moment" at a specific time (Siri/Shortcuts captures the invocation time but the app drains the queue later).
    func markMoment(at date: Date) {
        moments.append(date)
        if moments.count > 500 { moments.removeFirst(moments.count - 500) }
        UserDefaults.standard.set(moments.map(\.timeIntervalSince1970), forKey: "moments")
        buzz(loops: 1)
        live.append(log: "Moment marked")
    }

    /// Record a "sleep mark" (bedtime / wake / mid-night tap) (#461). Stored like moments and written as a
    /// greppable "Sleep mark @ HH:mm" line into the strap log. A single buzz confirms. Marks are logged in
    /// sequence; they are not yet paired into sleep bounds.
    func markSleep() { markSleep(at: Date()) }
    func markSleep(at date: Date) {
        sleepMarks.append(date)
        if sleepMarks.count > 500 { sleepMarks.removeFirst(sleepMarks.count - 500) }
        UserDefaults.standard.set(sleepMarks.map(\.timeIntervalSince1970), forKey: "sleepMarks")
        buzz(loops: 1)
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        live.append(log: "Sleep mark @ \(hhmm.string(from: date))")
        // Also upsert the typed `sleep_mark` metric-series row the Sleep screen reads (as SleepView.logMark does),
        // matching Android (#461). A double-tap cannot choose bedtime vs wake, so it defaults to `.bedtime`.
        // Idempotent by (deviceId, day, key) through the repo's live store handle.
        let mark = SleepMark(type: .bedtime, at: date)
        Task { [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: self.repo.deviceId)
        }
    }

    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { MacActions.runShortcut(behavior.wristOnShortcut) }
        } else {
            #if os(macOS)
            // Auto-lock on wrist-off is macOS-only (a third-party iOS app cannot lock the device). Guarding here also
            // stops a stray "Lock Screen" Shortcut launch for iOS users who toggled it on before it was gated off.
            if behavior.autoLockOnWristOff, !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
            #endif
            if !behavior.wristOffShortcut.isEmpty { MacActions.runShortcut(behavior.wristOffShortcut) }
        }
    }

    private func coachZone(_ hr: Int?) {
        guard behavior.zoneCoaching, live.bonded, live.worn, let hr, hr >= 30 else { return }
        guard profile.hrMax > 0 else { return }
        let zone = profile.hrZoneSet.zoneNumber(forBPM: Double(hr))
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { buzz(loops: 3) }          // entered max , ease off
        else if zone <= 1, lastCoachZone > 1 { buzz(loops: 1) }     // recovered
    }

    // MARK: - Battery night-guard: learned bedtime cache

    /// The learned habitual midsleep (local seconds-of-day), cached for the battery night-guard.
    /// `repo.habitualMidsleepSec()` is an async whole-history read but the battery hook runs synchronously on
    /// the BLE callback. nil = cold start (fewer than `SleepStageTotals.habitualMinDays` nights), so
    /// `BatteryEstimator.bedtimeAlert` stays silent.
    private var habitualMidsleepCache: Int? = nil
    private var habitualMidsleepCachedAt: Date? = nil

    /// Refresh the cached midsleep at most hourly: it reads the full sleep history and moves over weeks, so
    /// recomputing on every `repo.$days` republish is pure cost.
    private func refreshHabitualMidsleep() {
        if let at = habitualMidsleepCachedAt, Date().timeIntervalSince(at) < 3600 { return }
        habitualMidsleepCachedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            self.habitualMidsleepCache = await self.repo.habitualMidsleepSec()
        }
    }

    /// Local time-of-day in seconds [0, 86400), in the CURRENT zone so a traveller's night-guard window follows them.
    static func localSecOfDayNow(_ now: Date = Date()) -> Int {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second], from: now)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// Illness early-warning. `IllnessSignalEngine` is the only resolver (history, corroboration gate, journal
    /// confounder suppression); `illnessSignal` and the `healthAlert` banner come from its one decision. This
    /// only gathers the journal context, which needs the store. On-device, approximate, not a diagnosis.
    private func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= IllnessSignalEngine.minHistoryDays,
              let latestDay = days.last?.day, latestDay == repo.today?.day else {
            healthAlert = nil; illnessSignal = nil; illnessDistance = nil; return
        }
        Task { [weak self] in
            guard let self else { return }
            let recentDays = Set(days.suffix(2).map(\.day))
            let journal = await self.repo.journalEntries(days: 7)
            var ctxAlcohol = false, ctxHardWorkout = false, ctxAlreadyUnwell = false
            for e in journal where e.answeredYes && recentDays.contains(e.day) {
                let q = e.question.lowercased()
                if q.contains("alcohol") || q.contains("drink") { ctxAlcohol = true }
                if q.contains("workout") || q.contains("train") || q.contains("exercise") { ctxHardWorkout = true }
                if q.contains("sick") || q.contains("ill") || q.contains("unwell") { ctxAlreadyUnwell = true }
            }
            self.applyIllnessSignal(days, alcohol: ctxAlcohol, hardOrLateWorkout: ctxHardWorkout,
                                    alreadyUnwell: ctxAlreadyUnwell)
        }
    }

    /// The reader's temperature unit, resolved as every screen resolves it (explicit override, else derived
    /// from the unit system). AppModel has no @AppStorage; the resolution must match or the alert banner and
    /// the Skin Temp card disagree about the unit.
    private var displayTemperatureUnit: TemperatureUnit {
        let d = UserDefaults.standard
        let system = UnitSystem(rawValue: d.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        return UnitPrefs.resolveTemperature(system: system,
                                            override: d.string(forKey: UnitPrefs.temperatureKey) ?? "")
    }

    /// Run `IllnessSignalEngine` over the day history and journal confounder context, then publish the result
    /// and the `healthAlert` banner payload.
    private func applyIllnessSignal(_ days: [DailyMetric], alcohol: Bool,
                                    hardOrLateWorkout: Bool, alreadyUnwell: Bool) {
        // A newer day can arrive while the journal read is in flight; never publish the older task's alert over it.
        guard days.last?.day == repo.days.last?.day, days.last?.day == repo.today?.day,
              let reading = IllnessSignalEngine.reading(days: days) else { return }
        let previous = healthAlert

        // The Mahalanobis distance is an unvalidated alternate, so it is computed for Test Centre only and never gates the alert.
        illnessDistance = TestCentre.active(.stress)
            ? IllnessDistance.evaluate(features: reading.distanceFeatures, correlation: nil)
            : nil

        let context = IllnessSignalEngine.Context(
            alcohol: alcohol, hardOrLateWorkout: hardOrLateWorkout,
            alreadyUnwell: alreadyUnwell, baselineTrusted: reading.baselineTrusted)

        var labels: [String: String] = [:]
        if let delta = reading.deltas.restingHRAboveBpm {
            labels["restingHR"] = String(localized: "RHR +\(delta)")
        }
        if let percent = reading.deltas.hrvBelowPercent {
            labels["hrv"] = String(localized: "HRV −\(percent)%")
        }
        if let rise = reading.deltas.skinTempRiseC {
            // Stored in degrees C, shown in the reader's unit; formatted here because it goes through
            // AppLanguage.activeLocale (a German reader sees "0,7").
            let temperature = UnitFormatter.skinTempSignalPhrase(
                rise,
                fahrenheit: displayTemperatureUnit == .fahrenheit,
                locale: AppLanguage.activeLocale)
            labels["skinTemp"] = String(localized: "Skin temperature \(temperature)")
        }
        if reading.deltas.respirationUp {
            labels["respiration"] = String(localized: "Respiration up")
        }

        let result = IllnessSignalEngine.evaluate(reading.inputs, context: context, firedLabels: labels)
        illnessSignal = result
        // The amber banner reflects only the raised / already-unwell levels; calmer levels surface in the Health hub's Heads-Up card.
        switch result.level {
        case .raised:
            healthAlert = HealthAlert(message: result.message ?? .raised,
                                      firedSignals: result.firedSignals)
        case .alreadyUnwell:
            healthAlert = HealthAlert(message: result.message ?? .alreadyUnwell,
                                      firedSignals: result.firedSignals)
        case .quiet, .mild, .suppressed:
            healthAlert = nil
        }
        if healthAlert != nil, previous == nil {
            IllnessNotifier.post(result.copy)
        }
    }

    /// Once-a-day "optimal strain reached" nudge (#593). Reads the resolved today-row, converts stored 0-100
    /// Effort to the 0-21 axis with the shipped formatter, and gates against the low end of today's
    /// recovery-derived optimal band (#43). The notifier's persisted day gate makes firing on every days
    /// republish safe; nil recovery (calibrating) yields no band and no notification.
    func evaluateStrainTarget() {
        guard let row = repo.today else { return }
        StrainTargetNotifier.onDayUpdate(
            day: row.day,
            dayStrain21: row.strain.map { UnitFormatter.effortValue($0, scale: .whoop) },
            target21: CoupledView.optimalStrainRange(recovery: row.recovery)?.lowerBound,
            enabled: behavior.strainTargetNudge)
    }

    /// Once-a-day good-morning notification with the night's Recovery (see GoodMorningNotifier). Held while
    /// history is arriving or being scored: it posts once and is never corrected, so it must not announce a
    /// Recovery from a partial overnight offload.
    func evaluateGoodMorning() {
        guard !live.backfilling, !live.historyPendingSync, !intelligence.computing else { return }
        guard let row = repo.today else { return }
        let nightEnd = repo.sleeps.map(\.endTs).max()
        #if os(iOS)
        // With the Coach on, the morning goes out as the coach brief instead of the plain text.
        if CoachMorningBrief.isActive {
            CoachMorningBrief.onDayUpdate(today: Repository.localDayKey(Date()), recovery: row.recovery,
                                          nightEndTs: nightEnd, repo: repo, coach: coach)
            return
        }
        #endif
        GoodMorningNotifier.onDayUpdate(today: Repository.localDayKey(Date()), recovery: row.recovery,
                                        sleepMinutes: row.totalSleepMin, nightEndTs: nightEnd)
    }

    /// Re-run the illness watch over the cached history when the Automations toggle flips (the
    /// `repo.$refreshSeq` sink only fires on data changes).
    func reevaluateIllness() {
        evaluateIllness(repo.days)
    }

    // MARK: - v5 skin-temp suite engines (cycle phase + body clock)
    // Run in the analytics pass (IntelligenceEngine calls it after persisting the night's scores) so the
    // Health hub's skin-temp cards read a ready snapshot. Both are pure StrandAnalytics engines over the merged
    // daily history; cycle awareness is opt-in (default OFF) and computes nothing until enabled.

    /// UserDefaults key for the cycle-awareness opt-in (default OFF: the most sensitive health category). The
    /// Settings toggle and the card's CTA write this key.
    static let cycleAwarenessKey = "noopCycleAwareness"
    var cycleAwarenessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessKey) }
    }

    /// The user's "not for me" opt-out of cycle awareness: a user-controlled hide, never age-based. When true
    /// the OFFER is suppressed on Today and Health; the Automations toggle stays visible so it is reversible.
    /// Distinct from `cycleAwarenessEnabled` (active tracking).
    static let cycleAwarenessHiddenKey = "noopCycleAwarenessHidden"
    var cycleAwarenessHidden: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessHiddenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessHiddenKey) }
    }

    /// Whether a connecting Polar strap logs the model Zoop identifies it as (plus PMD/HRV capability summary)
    /// to the strap log. Default off; Test Centre shows the toggle only with a Polar strap paired. Diagnostic
    /// only. Twin of Android `ZoopPrefs.KEY_POLAR_DEBUG_LOGGING`.
    static let polarDebugLoggingKey = "noopPolarDebugLogging"
    var polarDebugLogging: Bool {
        get { UserDefaults.standard.bool(forKey: Self.polarDebugLoggingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.polarDebugLoggingKey) }
    }

    /// EXPERIMENTAL, default OFF (#1284): key an Oura hypnogram persist's startTs on the rounded 0x49 onset
    /// (the stable per-night anchor) and suppress/replace a duplicate re-serve before it is banked, closing the
    /// window where the wrong night shows until the next analyze pass. Off = end-anchored persist. A Test Centre
    /// hardware-validation toggle; no effect without an Oura ring.
    static let ouraOnsetKeyingKey = "noopOuraOnsetKeying"
    var ouraOnsetKeying: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ouraOnsetKeyingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ouraOnsetKeyingKey) }
    }

    /// Oura packed-notification A/B (EXPERIMENTAL, default OFF): send the official app's SetNotification mask
    /// `1c 01 ff` at the next connect instead of `3f`. The ring packs ~10 packets per notification for the
    /// official app (9x drain throughput); the mask is the first candidate switch (OURA_PROTOCOL.md s2.3). Read
    /// once per connect and nothing persists on the ring. Readout: the `-> notify_all(ff)` line and the raw
    /// sidecar's notification-size histogram. Test Centre only.
    static let ouraNotifyMaskFullKey = "noopOuraNotifyMaskFull"
    var ouraNotifyMaskFull: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ouraNotifyMaskFullKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ouraNotifyMaskFullKey) }
    }

    /// Item 27 (EXPERIMENTAL, default OFF): keep the Oura ring in daytime-HR mode while the screen is off
    /// during the day, standing down only for the learned night band (`NightStandDown`). The ring emits daytime
    /// HR (and the beats behind windowed rMSSD) only while a client holds that mode, so screen-keyed suspend
    /// empties the day for a pocketed phone. ON costs ring battery; the night is unchanged either way. No
    /// effect without a ring; cold start (no learned schedule) keeps OFF's rule.
    static let ouraAllDayLiveHRKey = "noopOuraAllDayLiveHR"
    var ouraAllDayLiveHR: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ouraAllDayLiveHRKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ouraAllDayLiveHRKey) }
    }

    /// The learned night band for the all-day HR stand-down: the same midsleep and typical-night inputs as the
    /// battery night-guard (`refreshHabitualMidsleep`), so both share one notion of the night. nil at cold start.
    func ouraNightBand() -> NightStandDown.Band? {
        NightStandDown.band(
            habitualMidsleepSec: habitualMidsleepCache,
            typicalSleepHours: BatteryEstimator.typicalSleepHours(
                nightlyHours: repo.days.compactMap { $0.totalSleepMin.map { $0 / 60.0 } }))
    }

    /// Recompute the skin-temp suite snapshots (cycle phase, body clock) from current history. Called from the
    /// analytics pass and when the cycle opt-in flips. Cycle is nil unless opted in; circadian is nil without a
    /// usable activity profile.
    func refreshV5Signals() async {
        await computeCyclePhase()
        await computeCircadianPhase()
    }

    /// Cycle-phase awareness from the nightly skin-temp shift (plus luteal RHR rise / HRV drop): each night is
    /// z-scored against the personal baseline and `CyclePhaseEngine.classify` reads the run. Opt-in; clears
    /// the published result as soon as it is turned off.
    private func computeCyclePhase() async {
        guard cycleAwarenessEnabled else { cyclePhase = nil; cycleCurve = []; return }
        let days = repo.days
        guard let tempCfg = Baselines.metricCfg["skin_temp"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let hrvCfg = Baselines.metricCfg["hrv"] else { return }

        // The absolute skin-temp mean is not in repo.days (only the degrees C deviation), so z-score the deviation
        // against its own folded spread. RHR and HRV z-score their raw columns. Oldest to newest.
        let sorted = days.sorted { $0.day < $1.day }
        let skinState = Baselines.foldHistory(sorted.map { $0.skinTempDevC }, cfg: tempCfg)
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)

        var nights: [CyclePhaseEngine.Night] = []
        var curve: [Double] = []
        for d in sorted {
            let tempZ = d.skinTempDevC.map { skinState.usable ? Baselines.deviation($0, state: skinState).z : $0 / 0.3 }
            let rhrZ = (rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil)
            let hrvZ = (hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil)
            nights.append(CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
            if let fused = CyclePhaseEngine.fusedIndex(tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ) { curve.append(fused) }
        }
        // Optional user-entered cycle-day-1 anchors live under the isolated `noop-cycle` source; the engine
        // cross-validates them against the temperature shift rather than trusting a mistimed log.
        let loggedPeriodStarts = await repo.periodStarts()
        cyclePhase = CyclePhaseEngine.classify(nights,
                                               baselineUsable: skinState.usable,
                                               loggedPeriodStarts: loggedPeriodStarts)
        cycleCurve = curve
    }

    /// Body-clock phase estimate: a coarse per-hour activity profile from ~14 days of downsampled HR buckets
    /// (HR amplitude proxies the rest/activity rhythm when raw motion isn't to hand), then a cosinor fit. nil
    /// when there isn't enough data.
    private func computeCircadianPhase() async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 14 * 86_400
        let buckets = await repo.hrBuckets(from: from, to: now, bucketSeconds: 3_600)
        guard buckets.count >= 24 else { circadianPhase = nil; return }
        let tz = TimeZone.current.secondsFromGMT()
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { circadianPhase = nil; return }
        let wakeHour = habitualWakeHour() ?? 7.0
        circadianPhase = CircadianEngine.estimatePhase(
            bins: bins, daysObserved: daySet.count, habitualWakeHour: wakeHour)
    }

    /// A coarse habitual wake hour (local) from the most recent banked sleep session's end, for the circadian
    /// schedule-offset comparison. nil when no sleep is banked.
    private func habitualWakeHour() -> Double? {
        guard let last = repo.sleeps.last else { return nil }
        let tz = TimeZone.current.secondsFromGMT()
        let local = (last.endTs + tz) % 86_400
        return Double((local + 86_400) % 86_400) / 3_600.0
    }

    // MARK: - v5 local multi-device fusion adapter
    // Assemble today's per-source values per metric and run `FusionResolver` for the "Your Data, Fused"
    // screen (FusedRecordView). Additive read over rows the store already holds; it does not touch the core
    // resolvedSeries waterfall.

    /// Build today's fused record (best signal per metric across sources, with agreement): read each fusable
    /// metric's latest per-source daily value, run the pure `FusionResolver`, map into `FusedRecord`. A
    /// one-WHOOP user degrades honestly to `.single` agreement.
    func buildTodayFusedRecord() async -> FusedRecord {
        guard let store = await repo.storeHandle() else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }
        let specs: [(key: String, label: String, accent: String?)] = [
            ("rhr", "Resting HR", nil),
            ("hrv", "HRV", nil),
            ("sleep_total_min", "Sleep", nil),
            ("steps", "Steps", nil),
            ("skin_temp", "Skin temp", nil),
            ("spo2", "Blood oxygen", nil),
        ]
        // Every source that could carry a value, mapped to its stored device id (the strap's real id is
        // `deviceId`/`computed`, so map explicitly).
        let sources: [(FusionSource, String)] = [
            (.whoopImport, deviceId),
            (.zoopComputed, deviceId + "-zoop"),
            (.appleHealth, appleDeviceId),
            (.xiaomiBand, FusionSource.xiaomiBand.rawValue),
        ]

        let now = Date()
        let fromDay = Repository.dayString(now.addingTimeInterval(-3 * 86_400))
        let toDay = Repository.dayString(now.addingTimeInterval(86_400))

        var rowsBySource: [FusionSource: DailyMetric] = [:]
        for (src, id) in sources {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)) ?? []
            if let latest = rows.sorted(by: { $0.day < $1.day }).last { rowsBySource[src] = latest }
        }
        guard !rowsBySource.isEmpty else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }

        var fusedRows: [FusedRow] = []
        var contributingSources = Set<FusionSource>()
        for spec in specs {
            var inputs: [FusionInput] = []
            for (src, daily) in rowsBySource {
                if let v = Self.fusionColumn(key: spec.key, day: daily) {
                    inputs.append(FusionInput(source: src, value: v))
                    contributingSources.insert(src)
                }
            }
            guard let point = FusionResolver.resolve(metricKey: spec.key, inputs: inputs) else { continue }
            fusedRows.append(FusedRow(point: point, label: spec.label, accentHex: spec.accent))
        }

        let owner = contributingSources.min(by: {
            MetricArbitrationPolicy.sourcePriority($0) < MetricArbitrationPolicy.sourcePriority($1)
        })
        return FusedRecord(rows: fusedRows, dayOwner: owner,
                           contributingSourceCount: contributingSources.count)
    }

    /// The DailyMetric column a fusion metric key maps to (mirrors Repository.dailyColumn); nil when the row lacks that metric.
    private static func fusionColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "rhr":             return d.restingHr.map(Double.init)
        case "hrv":             return d.avgHrv
        case "sleep_total_min": return d.totalSleepMin
        case "steps":           return d.steps.map(Double.init)
        case "skin_temp":       return d.skinTempDevC
        case "spo2":            return d.spo2Pct
        default:                return nil
        }
    }

    /// A picked import file made safe to read. On iOS the security-scoped, possibly iCloud-placeholder URL is
    /// coordinated and copied into the app's temp directory so the importer reads a stable local file
    /// (placeholders can't be opened in place by ZIPFoundation, and scoped-access timing blocked iPhone
    /// imports, #179). On macOS the URL is read in place. `cleanup()` removes the temp copy and the
    /// `Documents/Inbox/` copy that `UIDocumentPickerViewController(asCopy: true)` leaves, which otherwise
    /// grew without bound (a ~19 GB duplicate, #590). Sendable to cross the actor boundary.
    struct ImportFile: Sendable {
        let url: URL
        private let temp: URL?
        private let inboxOriginal: URL?
        init(url: URL, temp: URL?, inboxOriginal: URL? = nil) {
            self.url = url; self.temp = temp; self.inboxOriginal = inboxOriginal
        }
        func cleanup() {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if let inboxOriginal, Self.isInImportInbox(inboxOriginal) {
                try? FileManager.default.removeItem(at: inboxOriginal)
            }
        }

        /// Only delete files the picker placed in our `Documents/Inbox/`, never a user-chosen in-place file or an
        /// iCloud URL outside the sandbox.
        static func isInImportInbox(_ url: URL) -> Bool {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return false }
            let inbox = docs.appendingPathComponent("Inbox").standardizedFileURL.path
            let candidate = url.standardizedFileURL.path
            return candidate.hasPrefix(inbox + "/")
        }
    }

    /// Nonisolated so copying a large export never blocks the UI; the caller holds the security scope.
    nonisolated static func materializeForImport(_ picked: URL) async throws -> ImportFile {
        #if os(iOS)
        let ext = picked.pathExtension.isEmpty ? "dat" : picked.pathExtension
        let dst = ZoopScratch.file("import-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        var coordError: NSError?
        var ioError: Error?
        NSFileCoordinator().coordinate(readingItemAt: picked, options: [.forUploading], error: &coordError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: readURL, to: dst)
            } catch { ioError = error }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
        return ImportFile(url: dst, temp: dst, inboxOriginal: picked)
        #else
        return ImportFile(url: picked, temp: nil)
        #endif
    }

    /// One-shot launch sweep of `Documents/Inbox/`: delete stale `asCopy:true` picker drops a previous build
    /// left (#590). Best-effort and off-main; Inbox only holds picker hand-offs. Skips files newer than 60 s
    /// so it cannot race an import in flight at launch.
    nonisolated static func purgeImportInbox() {
        #if os(iOS)
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = docs.appendingPathComponent("Inbox")
        guard let items = try? fm.contentsOfDirectory(at: inbox,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }   // leave an in-flight hand-off alone
            try? fm.removeItem(at: item)
        }
        #endif
    }

    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.whoop, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .whoopExport, url: local.url)
                let summary = try await WhoopImporter.importExport(url: local.url, into: store,
                                                                   deviceId: deviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    func importXiaomi(url: URL) {
        beginImport(.xiaomi)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.xiaomi, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .xiaomiBand, url: local.url)
                let summary = try await XiaomiImporter.importExport(url: local.url, into: store,
                                                                    trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                let days = summary.countsByCategory["days"] ?? 0
                let sleeps = summary.countsByCategory["sleepSessions"] ?? 0
                finishImport(.xiaomi, summary: "Imported \(days) days · \(sleeps) sleeps\(span)")
            } catch {
                finishImport(.xiaomi, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        // Run the parse and writes at `.utility` so a large import yields to UI rendering instead of inheriting
        // the tap's user-initiated QoS.
        Task(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .appleHealth, url: local.url)
                let summary = try await AppleHealthImport.importExport(url: local.url, into: store,
                                                                       deviceId: appleDeviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                await repo.refresh()
                // An Apple Health import may write only body-composition series (weight, body_fat, lean_mass, bmi,
                // vo2max), which live in metricSeries outside refresh()'s diff, so `refreshSeq` may not bump and
                // AppleHealthView's re-mount cache (keyed on it) would serve the pre-import snapshot. Drop the cache
                // explicitly (#833).
                repo.appleHealthCache = nil
                repo.appleHealthLoadedSeq = -1
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    // MARK: - Storage diagnostics (#590 , StorageView)

    /// A snapshot of the app's on-disk footprint for the Storage screen, in bytes; `db` is nil only for an
    /// unopened/in-memory store.
    struct StorageReport: Equatable, Sendable {
        var db: Int64?
        var inbox: Int64
        var importTemp: Int64
    }

    /// Gather the storage report off the main actor: the GRDB file (+ WAL/SHM), `Documents/Inbox/`, and import temp files.
    func storageReport() async -> StorageReport {
        let db = await repo.storeHandle()?.databaseFileSizeBytes()
        let inbox = Self.inboxSizeBytes()
        let temp = Self.importTempSizeBytes()
        return StorageReport(db: db, inbox: inbox, importTemp: temp)
    }

    nonisolated static func inboxSizeBytes() -> Int64 {
        #if os(iOS)
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return 0 }
        return directorySizeBytes(docs.appendingPathComponent("Inbox"))
        #else
        return 0
        #endif
    }

    /// Total bytes of Zoop's own temp scratch: its owned folder plus the flat scratch earlier builds left. A
    /// crash mid-import can strand a multi-GB extraction (#590). Recursive (the Xiaomi importer stages
    /// directories) and scoped to what [purgeImportTemp] would reclaim, so Storage never attributes another
    /// program's disk to Zoop (#2446).
    nonisolated static func importTempSizeBytes() -> Int64 {
        ZoopScratch.sizeBytes { item in
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { return directorySizeBytes(item) }
            return Int64(vals?.fileSize ?? 0)
        }
    }

    nonisolated private static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// The Storage screen's "Clean up": purge the Inbox and stranded import temps, then truncate the WAL so
    /// freed pages return to the OS. Returns a fresh report. Safe: those hold only picker hand-offs and temp copies.
    @discardableResult
    func cleanUpStorage() async -> StorageReport {
        Self.purgeImportInbox()
        Self.purgeImportTemp()
        if let store = await repo.storeHandle() { try? await store.checkpointWAL() }
        return await storageReport()
    }

    /// Remove Zoop's stranded temp scratch: its owned folder plus the flat scratch earlier builds wrote (the
    /// multi-GB `noop-health-*` export.xml, #590). Keeps `purgeImportInbox`'s 60 s in-flight guard. See
    /// `ZoopScratch` for why ownership is a folder, not a prefix.
    nonisolated static func purgeImportTemp() { ZoopScratch.purge() }

    /// Handle a `zoop://import-health` deep link (#581), the HealthKit-free Shortcuts import for sideloaded
    /// installs. URL schemes are forgeable by other apps/sites, so this only decodes and stages the payload;
    /// the iOS shell confirms before `confirmHealthImport()` writes into the `apple-health` source.
    func handleHealthImportURL(_ url: URL) {
        switch ShortcutHealthImport.prepare(url: url) {
        case .success(let pending):
            pendingShortcutHealthImport = pending
        case .failure(let outcome):
            beginImport(.appleHealth)
            Task { await finishShortcutHealthImport(outcome) }
        }
    }

    func cancelPendingHealthImport() {
        pendingShortcutHealthImport = nil
    }

    func confirmPendingHealthImport() {
        guard let pending = pendingShortcutHealthImport else { return }
        pendingShortcutHealthImport = nil
        beginImport(.appleHealth)
        Task {
            guard let store = await repo.storeHandle() else {
                finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                return
            }
            let outcome = await ShortcutHealthImport.ingest(prepared: pending, into: store)
            await finishShortcutHealthImport(outcome)
        }
    }

    private func finishShortcutHealthImport(_ outcome: ShortcutHealthImport.Outcome) async {
        switch outcome {
        case .imported(let days, let workouts):
            await repo.refresh()
            // The Shortcuts import writes body-composition series into metricSeries, outside refresh()'s diff; drop
            // the Apple Health cache so the next visit re-reads (#833, same as the file-import path).
            repo.appleHealthCache = nil
            repo.appleHealthLoadedSeq = -1
            let w = workouts > 0 ? " · \(workouts) workouts" : ""
            finishImport(.appleHealth, summary: "Imported \(days) days\(w)")
        case .nothingToImport:
            finishImport(.appleHealth, summary: "Nothing new to import.")
        case .rejected(let reason):
            finishImport(.appleHealth, summary: reason, failed: true)
        }
    }

    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        switch source {
        case .whoop:
            whoopImportSummary = nil
            whoopImportFailed = false
        case .appleHealth:
            appleHealthImportSummary = nil
            appleHealthImportFailed = false
        case .xiaomi:
            xiaomiImportSummary = nil
            xiaomiImportFailed = false
        }
    }

    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        switch source {
        case .whoop:
            whoopImportSummary = summary
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        case .xiaomi:
            xiaomiImportSummary = summary
            xiaomiImportFailed = failed
        }
        activeImportSource = nil
    }
}
