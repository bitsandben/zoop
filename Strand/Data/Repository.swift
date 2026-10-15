import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign   // TrendPoint , the shared chart point type the Deep Timeline series uses

/// Per-day sleep figures the WHOOP export carried verbatim; SleepView prefers these over its
/// APPROXIMATE on-device recomputations.
struct ImportedSleepFigures: Equatable {
    var performancePct: Double?   // "sleep_performance", 0–100
    var consistencyPct: Double?   // "sleep_consistency", 0–100
    var needMin: Double?          // "sleep_need_min", minutes
    var debtMin: Double?          // "sleep_debt_min", minutes
}

// MARK: - Cross-source resolver model
//
// `Repository.resolvedSeries` resolves a metric over an explicit source PRECEDENCE: imported WHOOP
// wins, Zoop-computed fills uncovered days, and Apple Health only fills declared-compatible vitals on
// days neither strap source has. Exact-source reads (`series(key:source:)`) remain for surfaces that
// must not mix sources.

/// One day's resolved value plus the source that actually supplied it (so a caption can name it).
struct ResolvedMetricPoint: Equatable, Sendable {
    let day: String
    let value: Double
    let source: String
    let sourceKey: String
}

/// A candidate (source, key) pair the resolver will try, in precedence order.
struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    let source: String
    let key: String
}

/// The full result of resolving one metric: which sources were tried, and the merged per-day points.
struct MetricSeriesResolution: Equatable, Sendable {
    let requestedSource: String
    let candidates: [MetricSourceCandidate]
    let points: [ResolvedMetricPoint]

    /// Plain `(day, value)` rows, the shape the chart/correlation code consumes.
    var values: [(day: String, value: Double)] { points.map { ($0.day, $0.value) } }

    /// Distinct sources that actually contributed a point, in first-seen order (for a caption).
    var usedSources: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.source) {
            seen.insert(point.source)
            ordered.append(point.source)
        }
        return ordered
    }
}

/// The sensor/import provider whose inputs produced a resolved Today score. `sourceId` is durable;
/// `brand` comes from the paired-device registry when available.
struct ScoreInputProvider: Equatable, Sendable {
    let sourceId: String
    let brand: String?
}

/// Source provenance for daily rows before surfaces merge them, so the UI can say where a vital came from.
enum DailyMetricSource: Equatable {
    case whoopImport
    case zoopComputed
    case appleHealth
    case localCache

    var vitalPriority: Int {
        switch self {
        case .whoopImport:  return 0
        case .zoopComputed: return 1
        case .appleHealth:  return 2
        case .localCache:   return 3
        }
    }
}

struct SourcedDailyMetric: Equatable {
    let metric: DailyMetric
    let source: DailyMetricSource
}

/// A compact snapshot of how much history each source holds, for the Data Sources "Freshness
/// Pipeline" card. Counts only.
struct RepositoryFreshness: Equatable, Sendable {
    var importedDays: Int = 0
    var computedDays: Int = 0
    var appleDays: Int = 0
    var importedSleeps: Int = 0
    var computedSleeps: Int = 0
    var earliestDay: String?
    var latestDay: String?

    static let empty = RepositoryFreshness()
}

/// What `deleteSleepSession` hands back so a transient UNDO can restore the night. Carries the
/// deleted row verbatim plus the deviceId namespace that OWNED it, so undo re-inserts it where it
/// came from; a `userEdited` night keeps its flag and is not re-scored as a detected twin.
struct SleepDeletionSnapshot: Equatable {
    let session: CachedSleepSession
    let ownerDeviceId: String
    /// The night's wake span used in the tombstone token (== `session.endTs`).
    let endTs: Int
    /// The per-epoch Deep Timeline motion series (`motionJSON`), captured at delete time. Not on
    /// `CachedSleepSession`, so undo must re-persist it or a hand-edited night's motion track vanishes
    /// (detected nights self-heal via `analyzeRecent`). nil when the column was NULL.
    var motion: [Double]?
    /// The per-epoch band sleep-state series (`sleepStateJSON`), captured and re-persisted like `motion`.
    var sleepState: [Int]?
}

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches screens bind to.
@MainActor
final class Repository: ObservableObject {
    /// The id of the strap whose recordings this read model surfaces. Seeded with the legacy
    /// "my-whoop", then re-pointed to the registry's `activeDeviceId` (see `adoptActiveDeviceId`), as
    /// `BLEManager.bootstrapStore` does for the write side: a re-added strap gets a fresh
    /// "whoop-<uuid>" id, and reads must follow it. `private(set)` so only `adoptActiveDeviceId` moves it.
    private(set) var deviceId: String
    /// Source id for on-device computed scores (from the raw strap streams by IntelligenceEngine),
    /// merged UNDER imported rows at read time so a real WHOOP import always wins.
    private var computedDeviceId: String { deviceId + "-zoop" }

    /// The CANONICAL imported/computed id ("my-whoop" + its "-zoop" sibling). Import and computed WRITE
    /// targets stay stable here forever so a remove+re-add never orphans banked history, while
    /// `deviceId` follows the active strap; reads take the UNION of the two. On a single-device
    /// install the union collapses to one id.
    private var canonicalDeviceId: String { Self.whoopSource }
    private var canonicalComputedId: String { Self.whoopSource + "-zoop" }

    /// The distinct IMPORTED/MEASURED source ids to union for a dashboard read: the active strap and
    /// the canonical imported id. Active FIRST so per-day dedup lets the live row win. Deduped.
    var importedReadIds: [String] {
        deviceId == canonicalDeviceId ? [deviceId] : [deviceId, canonicalDeviceId]
    }
    /// The distinct COMPUTED ("-zoop") source ids to union; same dedup rule as `importedReadIds`.
    var computedReadIds: [String] {
        computedDeviceId == canonicalComputedId ? [computedDeviceId] : [computedDeviceId, canonicalComputedId]
    }

    /// Every namespace that can own a sleep row the Sleep tab shows: computed first (they keep
    /// precedence over imported), active id ahead of canonical on each side. `CachedSleepSession`
    /// carries no device id, so a write from a merged row must resolve its owner against this same
    /// union, or a night under the CANONICAL source would look editable but save to nothing.
    private var sleepOwnerIds: [String] { computedReadIds + importedReadIds }

    /// True when the ACTIVE strap is an Oura ring, resolved from its registry id prefix against the
    /// canonical brand table (`DeviceBrandCatalog.idPrefix`), not an ad-hoc literal. Read/UI side only:
    /// lets sleep surfaces name an Oura night's provenance "Oura". Not stored; never crosses `.zoopbak`.
    var activeDeviceIsOura: Bool { DeviceBrandCatalog.isOura(deviceId) }
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR...) over the recent window, oldest first.
    @Published var days: [DailyMetric] = []
    /// The Charge baselines (HRV, resting HR, respiration) resolved from the imported and own daily
    /// rows with the engine's own rule, recomputed on every `refresh()`. The single funnel for every
    /// Charge readout below the headline, so none can fold a different history than the score used.
    /// nil until the first refresh.
    @Published private(set) var chargeBaselines: ChargeBaselines.Resolved?
    /// Cached sleep sessions over the recent window, oldest first.
    @Published var sleeps: [CachedSleepSession] = []
    /// Imported (export-verbatim) sleep figures by day. Empty until a WHOOP import lands.
    @Published var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published var loaded = false
    /// How much history each source holds, recomputed on every `refresh()`; powers the Freshness Pipeline card.
    @Published private(set) var freshness: RepositoryFreshness = .empty
    /// Daily metric rows with source provenance, for vital-sign surfaces that caption their source.
    @Published private(set) var vitalRows: [SourcedDailyMetric] = []
    /// Monotonic counter bumped on every successful `refresh()`. Intraday views key their load on it,
    /// since `today?.day` is stable within a day.
    @Published private(set) var refreshSeq = 0

    /// Bumped by every hydration mutation (log / edit / delete) so the hydration card re-reads without
    /// waiting for a full `refreshSeq` refresh.
    @Published private(set) var hydrationSeq = 0
    func noteHydrationChanged() { hydrationSeq += 1 }

    /// Bumped whenever a period-start row is logged or removed, so cycle surfaces reload their local
    /// history without a full strap-data refresh.
    @Published private(set) var cycleTrackingSeq = 0
    func noteCycleTrackingChanged() { cycleTrackingSeq += 1 }

    /// Workouts & GPS test mode (Test Centre): the tagged sink for `.workouts` diagnostic lines. Nil
    /// (inert) in tests and non-prod inits; AppModel wires it to `live.append(log:domain:)`. Gate on
    /// `TestCentre.active(.workouts)` BEFORE building any line. Diagnostic only.
    var workoutsLog: ((String) -> Void)?

    /// The user's HRmax + sex, injected once by AppModel so the read path can BACKFILL a strap-native
    /// workout's Effort on display when its stored value is nil (a live/manual session can save with
    /// strain nil while the day total counted it; the backend rescore may be a tick away). Recomputed
    /// from the same samples the graph uses, only when the window is dense (the HR-reconcile minSamples
    /// gate); never fabricated. Nil (inert) skips the fill.
    struct StrainProfile: Sendable { let hrMax: Double; let sex: String }
    var strainProfile: StrainProfile?

    /// Emits one Workouts & GPS test-mode line iff the mode is on and a sink is wired. The gate is
    /// checked BEFORE `build()` runs (@autoclosure), so nothing is built when off.
    private func emitWorkouts(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts), let workoutsLog else { return }
        workoutsLog(build())
    }

    init(deviceId: String) { self.deviceId = deviceId }

    /// Re-points the read model's ACTIVE-strap id at the registry's active device, so a re-added
    /// strap's live raw surfaces on the dashboard. Called by AppModel on every registry active-id
    /// change; idempotent, and an empty/unchanged id is a no-op. Read-side only: reads union it with the
    /// canonical "my-whoop", and import/computed WRITE targets stay on the canonical id. Returns true
    /// when the id changed so the caller can `refresh()`.
    @discardableResult
    func adoptActiveDeviceId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != deviceId else { return false }
        deviceId = trimmed
        return true
    }

    #if DEBUG
    /// Injects a pre-opened store so unit tests can exercise read facades against an in-memory
    /// `WhoopStore`. DEBUG-only test seam.
    func setStoreForTesting(_ s: WhoopStore) { self.store = s }
    #endif

    // MARK: - Union reads (active strap + canonical)
    //
    /// Raw physiological streams are a worn timeline, not a property of the active strap. Resolves
    /// every registered physical WHOOP, active first, with the canonical import namespace as the final
    /// fallback. Archived devices stay (archive means "stop connecting, keep data"). The active id
    /// stays first even for a non-WHOOP provider.
    private func rawPhysiologyReadIds(store: WhoopStore) -> [String] {
        let paired = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        let registeredWhoops = paired.filter {
            $0.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        }.map(\.id)
        return Self.rawWhoopSourceIds(activeDeviceId: deviceId, registeredWhoopIds: registeredWhoops)
    }

    /// Every namespace the Workouts list reads a row out of, in read order, duplicates collapsed.
    /// The list unions many device ids, so delete derives from this same function: a row under any
    /// other namespace would otherwise be visible but undeletable and reappear on reload.
    nonisolated static func workoutNamespaces(rawIds: [String]) -> [String] {
        deletableWorkoutNamespaces(rawIds: rawIds)
            + [WorkoutSource.appleHealthSource, "lifting", "activity-file"]
    }

    /// The subset of `workoutNamespaces` a DELETE may touch: strap namespaces only. Imported history is
    /// read-only everywhere else (row menu, `bulkDeleteWorkouts`, `mergeWorkouts`), and collapsing a
    /// cross-source twin at display time does not license deleting the imported half. A `.manual` row,
    /// the only class offered for delete, is written under a strap id.
    nonisolated static func deletableWorkoutNamespaces(rawIds: [String]) -> [String] {
        (rawIds + rawIds.map { $0.hasSuffix("-zoop") ? $0 : $0 + "-zoop" })
            .reduce(into: [String]()) { acc, id in
                if !acc.contains(id) { acc.append(id) }
            }
    }

    /// Pure ordering contract: active source first, every other registered WHOOP in stable registry
    /// order, canonical history last; duplicates collapse.
    nonisolated static func rawWhoopSourceIds(activeDeviceId: String,
                                             registeredWhoopIds: [String]) -> [String] {
        let canonical = Self.whoopSource
        let middle = registeredWhoopIds.filter { $0 != activeDeviceId && $0 != canonical }
        return ([activeDeviceId] + middle + [canonical]).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private func rawComputedReadIds(store: WhoopStore) -> [String] {
        rawPhysiologyReadIds(store: store).map { $0.hasSuffix("-zoop") ? $0 : $0 + "-zoop" }
    }

    // Each helper reads the SAME query across `importedReadIds` and concatenates rows, ACTIVE STRAP
    // FIRST, so the existing per-day dedup lets the live/measured row beat the canonical one and
    // nothing double-counts.

    /// Daily-metric rows across the imported union for a day range, deduped per day with the ACTIVE
    /// STRAP winning; feeds `mergeDaily` unchanged.
    private func unionDailyMetrics(store: WhoopStore, from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in importedReadIds {   // active strap FIRST → it claims each column, canonical fills its gaps
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Self.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Gravity samples across the imported union, deduped by timestamp with the ACTIVE STRAP winning.
    /// Takes the active id from `importedReadIds` so the Steps calibration screen reads the same
    /// union as the estimator (which resolves an owner per day before reading gravity).
    func gravitySamplesUnion(from: Int, to: Int, limit: Int = 200_000) async -> [GravitySample] {
        guard let store = await storeHandle() else { return [] }
        var lists: [[GravitySample]] = []
        for id in rawPhysiologyReadIds(store: store) {   // active strap FIRST → it wins any shared timestamp
            lists.append((try? await store.gravitySamples(deviceId: id, from: from, to: to, limit: limit)) ?? [])
        }
        // Single-id reads return unchanged; a real union is hashed and sorted off the main actor.
        if lists.count == 1 { return lists[0] }
        let merged = lists
        return await Task.detached(priority: .userInitiated) { Self.mergeGravityByTs(merged) }.value
    }

    /// Merges gravity lists into one time-ordered stream, deduped by timestamp with the FIRST list (the
    /// active strap) winning ties. A single-id read is returned UNCHANGED. Pure and static so the
    /// dedup is unit-tested without a store.
    nonisolated static func mergeGravityByTs(_ lists: [[GravitySample]]) -> [GravitySample] {
        if lists.count == 1 { return lists[0] }
        var byTs: [Int: GravitySample] = [:]
        for list in lists {
            for s in list where byTs[s.ts] == nil { byTs[s.ts] = s }
        }
        return byTs.values.sorted { $0.ts < $1.ts }
    }

    /// Merges R-R reads without treating a timestamp as a beat identity: several real beats can share a
    /// second, so only the full storage identity `(ts, rrMs, seq)` is a duplicate across namespaces.
    /// The first list (active strap) wins exact duplicates.
    nonisolated static func mergeRRByIdentity(_ lists: [[RRInterval]]) -> [RRInterval] {
        if lists.count == 1 { return lists[0] }
        struct BeatKey: Hashable { let ts: Int; let rrMs: Int; let seq: Int }
        var seen = Set<BeatKey>()
        var out: [RRInterval] = []
        for list in lists {
            for beat in list where seen.insert(BeatKey(ts: beat.ts, rrMs: beat.rrMs, seq: beat.seq)).inserted {
                out.append(beat)
            }
        }
        if out.contains(where: { $0.srcChannel?.isWhoop5Transport == true || $0.srcChannel == .whoop4Historical }) {
            // Keep emission order within a second: value sorting corrupts successive differences.
            return out.enumerated().sorted {
                $0.element.ts != $1.element.ts ? $0.element.ts < $1.element.ts : $0.offset < $1.offset
            }.map(\.element)
        }
        return out.sorted {
            if $0.ts != $1.ts { return $0.ts < $1.ts }
            if $0.seq != $1.seq { return $0.seq < $1.seq }
            if $0.rrMs != $1.rrMs { return $0.rrMs < $1.rrMs }
            return ($0.ord ?? Int.min) < ($1.ord ?? Int.min)
        }
    }

    /// One day held by two source ids in the SAME bucket, folded into `winner`'s row: `winner` keeps
    /// every non-nil column (a measured zero is a reading) and `filler` supplies only those it left nil,
    /// so a hollow row can't discard a complete one. Columns that only mean something together move as
    /// a GROUP from one row (the sleep block; the raw red/IR PPG pair). Across-bucket precedence
    /// (`mergeDaily`) is untouched.
    nonisolated static func coalesceDay(_ winner: DailyMetric, _ filler: DailyMetric) -> DailyMetric {
        let sleepFromFiller = winner.totalSleepMin == nil && winner.efficiency == nil &&
            winner.deepMin == nil && winner.remMin == nil && winner.lightMin == nil &&
            winner.disturbances == nil
        let rawSpo2FromFiller = winner.spo2Red == nil && winner.spo2Ir == nil
        return DailyMetric(
            day: winner.day,
            totalSleepMin: sleepFromFiller ? filler.totalSleepMin : winner.totalSleepMin,
            efficiency: sleepFromFiller ? filler.efficiency : winner.efficiency,
            deepMin: sleepFromFiller ? filler.deepMin : winner.deepMin,
            remMin: sleepFromFiller ? filler.remMin : winner.remMin,
            lightMin: sleepFromFiller ? filler.lightMin : winner.lightMin,
            disturbances: sleepFromFiller ? filler.disturbances : winner.disturbances,
            restingHr: winner.restingHr ?? filler.restingHr,
            avgHrv: winner.avgHrv ?? filler.avgHrv,
            recovery: winner.recovery ?? filler.recovery,
            strain: winner.strain ?? filler.strain,
            exerciseCount: winner.exerciseCount ?? filler.exerciseCount,
            spo2Pct: winner.spo2Pct ?? filler.spo2Pct,
            skinTempDevC: winner.skinTempDevC ?? filler.skinTempDevC,
            respRateBpm: winner.respRateBpm ?? filler.respRateBpm,
            steps: winner.steps ?? filler.steps,
            activeKcalEst: winner.activeKcalEst ?? filler.activeKcalEst,
            spo2Red: rawSpo2FromFiller ? filler.spo2Red : winner.spo2Red,
            spo2Ir: rawSpo2FromFiller ? filler.spo2Ir : winner.spo2Ir,
            // Strap-only, like raw SpO2: an imported winner carries no absolute skin temp, so take the
            // filler's rather than blank a recorded value.
            skinTempC: winner.skinTempC ?? filler.skinTempC,
            // Part of the SLEEP GROUP: it describes how the stage figures above were derived, so it must come
            // from the row that supplied them.
            sleepHrOnly: sleepFromFiller ? filler.sleepHrOnly : winner.sleepHrOnly
        )
    }

    /// metricSeries points across the imported union for a key + day range, deduped per day, active strap winning.
    private func unionMetricSeries(store: WhoopStore, key: String, from: String, to: String) async -> [MetricPoint] {
        var byDay: [String: MetricPoint] = [:]
        for id in importedReadIds {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] where byDay[p.day] == nil {
                byDay[p.day] = p
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Sleep sessions across every registered WHOOP source for a ts range, keeping ALL sessions per
    /// day (nap + main night) and collapsing near-identical nights recorded under different union ids.
    private func unionSleepSessions(store: WhoopStore, from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: rawPhysiologyReadIds(store: store), from: from, to: to, limit: limit))
    }

    /// Computed ("-zoop") daily-metric rows across the computed union, deduped per day, active strap's sibling winning.
    private func unionComputedDailyMetrics(store: WhoopStore, from: String, to: String) async -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for id in computedReadIds {
            for m in (try? await store.dailyMetrics(deviceId: id, from: from, to: to)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Self.coalesceDay($0, m) } ?? m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Computed ("-zoop") sleep sessions across every registered WHOOP source; all sessions per day kept,
    /// near-identical nights under different siblings collapsed.
    private func unionComputedSleepSessions(store: WhoopStore, from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: rawComputedReadIds(store: store), from: from, to: to, limit: limit))
    }

    /// ALL sleep blocks across `ids` for a ts range (not collapsed to one per day; used by
    /// `allSleepSessions`, which expands split sleeps). Active strap first.
    private func unionRawSleepBlocks(store: WhoopStore, ids: [String], from: Int, to: Int, limit: Int = 4000) async -> [CachedSleepSession] {
        var blocks: [CachedSleepSession] = []
        for id in ids {
            blocks += (try? await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)) ?? []
        }
        return blocks
    }

    /// Keeps the active source's copy of a night when another source recorded nearly the same interval
    /// (a majority of BOTH intervals must overlap, so a short nap inside a long night survives).
    /// Separate blocks from one source stay distinct.
    nonisolated static func dedupBlocks(_ blocks: [CachedSleepSession]) -> [CachedSleepSession] {
        var seen = Set<[Int]>()
        var out: [CachedSleepSession] = []
        for b in blocks {
            let key = [b.startTs, b.endTs]
            guard seen.insert(key).inserted else { continue }
            let overlapsOtherSource = out.contains { kept in
                guard let source = b.deviceId, let keptSource = kept.deviceId,
                      source != keptSource else { return false }
                let start = max(b.effectiveStartTs, kept.effectiveStartTs)
                let end = min(b.endTs, kept.endTs)
                let bDuration = b.endTs - b.effectiveStartTs
                let keptDuration = kept.endTs - kept.effectiveStartTs
                let overlap = end - start
                return bDuration > 0 && keptDuration > 0 &&
                    overlap > bDuration / 2 && overlap > keptDuration / 2
            }
            if !overlapsOtherSource { out.append(b) }
        }
        return out
    }

    /// Drops workout rows sharing a (startTs, endTs, sport, source) key across union device ids,
    /// keeping the first (active strap). `dedupCrossSource` still collapses strap-vs-Apple twins.
    nonisolated private static func dedupWorkoutsByNaturalKey(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var seen = Set<String>()
        var out: [WorkoutRow] = []
        for r in rows {
            let key = "\(r.startTs)-\(r.endTs)-\(r.sport)-\(r.source)"
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    /// Latest HR-sample ts across the imported union, or nil; the auto-land Today anchor.
    private func unionLatestHRSampleTs(store: WhoopStore) async -> Int? {
        var latest: Int?
        for id in importedReadIds {
            if let ts = (try? await store.latestHRSampleTs(deviceId: id)) ?? nil {
                latest = max(latest ?? ts, ts)
            }
        }
        return latest
    }

    /// Today's row, by the device's LOGICAL local day (rolls at 04:00 local, see `logicalDayKey`), not
    /// the newest stored row. nil if the day has no row yet. Pre-04:00 carve-out: a user who sleeps
    /// before midnight and wakes before the rollover has the night banked under the NEW local calendar
    /// day (sleep is keyed by wake-day), so if the local day differs from the logical day AND has a
    /// banked night (`totalSleepMin != nil`), prefer it; otherwise fall back to the logical-day row so
    /// the dashboard never blanks. Presentation-only; stored keys are untouched.
    var today: DailyMetric? {
        let now = Date()
        return Repository.resolveToday(days: days,
                                       logicalKey: Repository.logicalDayKey(now),
                                       localKey: Repository.localDayKey(now))
    }

    /// Pure resolver behind `today`: prefers the LOCAL-calendar-day row when it differs from the
    /// logical day AND has a banked night, else the logical-day row. Equal keys collapse to a plain lookup.
    nonisolated static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }

    /// The SINGLE anchor every off-dashboard surface (widgets, watch snapshot, Live Activity) resolves
    /// its row through. Resolves today's row (`resolveToday`), then uses it when scored, else carries
    /// the freshest STRICTLY-PRIOR scored day for the recovery-derived fields. Anchoring on today's row
    /// (not the newest scored row) avoids showing yesterday after rollover; the `< carriedKey` bound
    /// keeps a stray future-dated scored row from surfacing AS today. Pure and injectable.
    nonisolated static func widgetAnchor(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        let todayRow = resolveToday(days: days, logicalKey: logicalKey, localKey: localKey)
        if todayRow?.recovery != nil { return todayRow }
        let carriedKey = todayRow?.day ?? logicalKey
        return days.last(where: { $0.recovery != nil && $0.day < carriedKey })
    }

    /// Live-clock convenience over the pure `widgetAnchor`, for `now`. MainActor-isolated because it
    /// reads `logicalDayKey` / `localDayKey`; tests call the pure overload.
    static func widgetAnchor(days: [DailyMetric], now: Date = Date()) -> DailyMetric? {
        widgetAnchor(days: days, logicalKey: logicalDayKey(now), localKey: localDayKey(now))
    }

    /// The recovery-INDEPENDENT overnight-vitals carry: the freshest strictly-prior day that recorded
    /// any of HRV / resting HR / respiratory, so vitals keep reading after the 04:00 rollover before
    /// tonight's sleep is scored, without being gated on the prior night's recovery. Call sites read
    /// today-first (`displayDay?.field ?? vitalsDay?.field`). `todayKey` is the future-clock-safe key
    /// (the LATER of logical/local), so today's own forming row is never picked up. Strictly a vitals
    /// selector: it must NEVER feed Charge/Effort/Rest or any recovery/strain-derived surface.
    static func lastVitalsDay(days: [DailyMetric], now: Date = Date()) -> DailyMetric? {
        lastVitalsDay(days: days, todayKey: max(logicalDayKey(now), localDayKey(now)))
    }

    /// Explicit-`todayKey` overload for callers that already hold the resolved key (pass the
    /// future-clock-safe one so the `< todayKey` bound is honest). Forwards to the package selector.
    nonisolated static func lastVitalsDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastVitalsDay(days: days, todayKey: todayKey)
    }

    /// PER-FIELD SpO2 carry: the freshest strictly-prior row with a `spo2Pct`, which `lastVitalsDay`'s
    /// predicate doesn't check (computed rows write it nil). See `DailyMetric.lastSpo2Day`.
    nonisolated static func lastSpo2Day(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastSpo2Day(days: days, todayKey: todayKey)
    }

    /// PER-FIELD skin-temperature-deviation carry. See `DailyMetric.lastSkinTempDay`.
    nonisolated static func lastSkinTempDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastSkinTempDay(days: days, todayKey: todayKey)
    }

    /// The freshest strictly-prior row with EITHER skin-temp number. See `DailyMetric.lastSkinTempReadingDay`.
    nonisolated static func lastSkinTempReadingDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastSkinTempReadingDay(days: days, todayKey: todayKey)
    }

    /// PER-FIELD HRV carry, for a field `lastVitalsDay`'s OR predicate can still resolve nil on. See `DailyMetric.lastHrvDay`.
    nonisolated static func lastHrvDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastHrvDay(days: days, todayKey: todayKey)
    }

    /// PER-FIELD resting-HR carry. See `DailyMetric.lastRestingHrDay`.
    nonisolated static func lastRestingHrDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        DailyMetric.lastRestingHrDay(days: days, todayKey: todayKey)
    }

    /// PER-FIELD respiratory carry, STALENESS-BOUNDED to `Baselines.vitalCarryDays` (respiratory is
    /// nightly, so a weeks-old value must not read as current; SpO2/skin-temp are sparse).
    nonisolated static func lastRespDay(days: [DailyMetric], todayKey: String) -> DailyMetric? {
        guard let newest = days.last(where: { $0.respRateBpm != nil && $0.day < todayKey }) else { return nil }
        return newest.day >= Baselines.cutoffKey(todayKey: todayKey) ? newest : nil
    }
    /// The trailing 7 CALENDAR days ending today (week strip), oldest first, not the last 7 stored rows.
    var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    /// Source-aware rows for vital-sign cards; previews/tests that set `days` directly fall back to the merged cache.
    var vitalMetricRows: [SourcedDailyMetric] {
        vitalRows.isEmpty ? days.map { SourcedDailyMetric(metric: $0, source: .localCache) } : vitalRows
    }

    /// Canonical source ids the resolver cross-references. The strap's actual id is `deviceId` (and
    /// its computed sibling `deviceId + "-zoop"`); these are the FIXED ids.
    static let whoopSource = "my-whoop"
    static let appleHealthSource = "apple-health"
    static let healthConnectSource = "health-connect"
    static let activityFileSource = "activity-file"

    /// Imported wearable-export sources whose DAILY aggregates (HRV / resting HR / sleep) can be scored
    /// for a Zoop Charge/Rest on an import-only day. They carry no raw HR stream, so the source-only
    /// fold scores them from the aggregate vs the person's baseline. Matches `WearableBrand.sourceId`
    /// plus Health Connect.
    static let wearableImportSources = ["oura-import", "fitbit-import", "garmin-import", "oura-api", healthConnectSource]

    /// `yyyy-MM-dd` in the device's local zone, matching `DailyMetric.day`. `nonisolated` so pure
    /// off-actor callers (e.g. `SleepModel.build`) key a day the same way.
    private nonisolated static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    nonisolated static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }

    /// The hour the LOGICAL day rolls (04:00 local); before it, "Today" stays put.
    nonisolated static let logicalDayRolloverHour = 4

    /// The LOGICAL local day for `now`: the calendar date of `now - rolloverHour hours`, so the small
    /// hours resolve to the prior day's row. Pure and injectable (23:59 same day, 01:00 previous day,
    /// 04:01 new day). Presentation-only: picks the Today row and anchors the HR-trend window.
    static func logicalDay(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logicalDay`).
    static func logicalDayKey(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> String {
        localDayKey(logicalDay(now, rolloverHour: rolloverHour))
    }

    /// Start of the logical day (its real calendar midnight) for `now`, the Today HR-trend window anchor.
    static func logicalDayStart(_ now: Date, calendar: Calendar = .current,
                                rolloverHour: Int = logicalDayRolloverHour) -> Date {
        calendar.startOfDay(for: logicalDay(now, rolloverHour: rolloverHour))
    }

    /// In-flight open, so concurrent first-callers share ONE open.
    private var storeOpenTask: Task<WhoopStore?, Never>?

    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        // SINGLE-FLIGHT: several screens ask for the store at once on launch and `store` isn't set until
        // the `await` below returns; without this guard every caller opens a fresh connection and re-runs
        // quarantineIncompatibleDatabase. Cache the in-flight Task so concurrent callers join it.
        if let storeOpenTask { return await storeOpenTask.value }
        let task = Task { [deviceId] () -> WhoopStore? in
            // Log the real open error (don't `try?` it): e.g. a data-protected store while the device is
            // locked would otherwise surface only as a generic "Couldn't open the local store."
            let path: String
            do {
                path = try StorePaths.defaultDatabasePath()
            } catch {
                NSLog("WhoopStore: ensureStore FAILED resolving DB path: \(error)")
                return nil
            }
            let s: WhoopStore
            do {
                s = try await WhoopStore(path: path)
            } catch {
                let ns = error as NSError
                NSLog("WhoopStore: ensureStore FAILED opening store: \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
                return nil
            }
            try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
            return s
        }
        storeOpenTask = task
        let opened = await task.value
        if let opened { store = opened }
        storeOpenTask = nil
        return opened
    }

    /// Exposes the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// The on-device DATA VOLUME read FRESH from the STORE (never the `@Published` caches), for the
    /// Display & Performance test mode's `dataVolume` line: raw decoded-stream footprint, imported daily
    /// rows under the active strap id, and workout-row count. Nil when the store can't open. Pure
    /// reads, so it never perturbs the screens it measures.
    func dataVolumeSnapshot() async -> DataVolume? {
        guard let store = await ensureStore() else { return nil }
        let dbRows = (try? await store.storageStats().decodedRows) ?? 0
        // Imported daily rows live under the UNION of the active strap + canonical "my-whoop" (computed
        // scores merge UNDER them). A wide day range covers the full import span.
        let imported = await unionDailyMetrics(store: store, from: "0000-01-01", to: "9999-12-31")
        // Whole recordable epoch in unix seconds so every workout row is counted.
        var workouts: [WorkoutRow] = []
        for id in importedReadIds { workouts += (try? await store.workouts(deviceId: id, from: 0, to: 4_102_444_800, limit: 1_000_000)) ?? [] }
        workouts = Self.dedupWorkoutsByNaturalKey(workouts)
        // lastRenderRows = size of the merged DAILY set the dashboard renders (union of distinct days
        // across imported strap, computed and Apple), the read-set that drives post-import list/chart lag.
        let computed = await unionComputedDailyMetrics(store: store, from: "0000-01-01", to: "9999-12-31")
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: "0000-01-01", to: "9999-12-31")) ?? []
        var renderDays = Set<String>()
        for m in imported { renderDays.insert(m.day) }
        for m in computed { renderDays.insert(m.day) }
        for m in apple { renderDays.insert(m.day) }
        return DataVolume(dbRows: dbRows, importedDays: imported.count,
                          workouts: workouts.count, lastRenderRows: renderDays.count)
    }

    /// Checkpoints the WAL into the main DB file if the store is open, so a file-level backup captures
    /// everything. No-op (false) without a handle; the caller then copies the files as-is (including -wal).
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// One refresh's fully-merged dashboard caches, computed OFF the main actor and applied to the
    /// `@Published` props in a single main-actor batch. Not `Sendable` (its members aren't formally so);
    /// crosses `Task.detached` as the engine's `DayResult` does under minimal strict concurrency.
    private struct MergedCaches {
        let importedSleep: [String: ImportedSleepFigures]
        let days: [DailyMetric]
        let chargeBaselines: ChargeBaselines.Resolved
        let sleeps: [CachedSleepSession]
        let vitalRows: [SourcedDailyMetric]
        let freshness: RepositoryFreshness
    }

    /// Monotonic ordering token: `refresh()` suspends on an off-actor merge before publishing, so
    /// overlapping calls could publish out of order. Each captures the token at entry and publishes
    /// only if it is still the latest. Not @Published; race-free since Repository is @MainActor.
    private var refreshGen = 0

    /// The `refreshSeq` at which Today last ran its heavy history-wide reload. Lives on the long-lived
    /// Repository so it survives a Today re-mount; Today skips the reload when nothing changed. `-1` =
    /// never loaded this launch. Not @Published.
    var todayHistoryWideLoadedSeq = -1
    /// The last history-wide snapshot Today built, restored on re-mount without queries. Paired with
    /// `todayHistoryWideLoadedSeq`. Not @Published.
    var todayHistoryWideCache: TodayHistoryWideCache?

    /// The `refreshSeq` at which Insights last ran its heavy load. macOS cold-mounts the detail view on
    /// every sidebar switch, so this lives on the Repository to survive the re-mount; `-1` = never
    /// loaded this launch. Not @Published.
    var insightsLoadedSeq = -1
    /// The dayKey Insights last loaded for, paired with `insightsLoadedSeq`: a day rollover re-loads
    /// even at an unchanged seq. Not @Published.
    var insightsLoadedDayKey = ""
    /// The dictionaries + activity costs Insights last built, restored on a same-seq re-mount. Not @Published.
    var insightsCache: InsightsLoadCache?

    /// The same cold-mount cache trio as Insights, for AppleHealthView's per-source load: `-1` / ""
    /// = never loaded this launch. Not @Published.
    var appleHealthLoadedSeq = -1
    /// The dayKey Apple Health last loaded for, paired with `appleHealthLoadedSeq`. Not @Published.
    var appleHealthLoadedDayKey = ""
    /// The snapshot AppleHealthView.load() last built, restored on a same-seq re-mount. Not @Published.
    var appleHealthCache: AppleHealthLoadCache?

    /// The `refreshSeq` at which Today last ran its DAY-SCOPED load (selected day's 5-minute `hrBuckets`
    /// plus, on today, the raw `hrSamples` pass), so a cold re-mount skips the heavy read. `-1` = never
    /// loaded this launch. Not @Published.
    var todayDayScopedLoadedSeq = -1
    /// The day key the day-scoped set last loaded FOR (`TodayView.selectedDayKey`), so day navigation
    /// never serves another day's snapshot. Not @Published.
    var todayDayScopedLoadedDayKey = ""
    /// The snapshot `loadDayScoped()` last built, restored on a same-(seq, day) re-mount. Not @Published.
    var todayDayScopedCache: TodayDayScopedCache?

    #if DEBUG
    /// DEBUG-only tally of how many times each cached heavy load ran its store reads (keyed
    /// "appleHealth" / "xiaomi" / "todayDayScoped"); a cache-restoring re-mount must not increment it.
    var loadFireCounts: [String: Int] = [:]
    #endif

    func refresh(days nDays: Int = 4000) async {
        guard let store = await ensureStore() else { return }
        refreshGen &+= 1
        let myGen = refreshGen
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        // UNION the active strap with the canonical "my-whoop" import, deduped per day (active wins).
        let imported = await unionDailyMetrics(store: store, from: fromDay, to: toDay)
        let computed = await unionComputedDailyMetrics(store: store, from: fromDay, to: toDay)
        let apple = (try? await store.dailyMetrics(deviceId: Self.appleHealthSource, from: fromDay, to: toDay)) ?? []
        let activityFile = (try? await store.dailyMetrics(deviceId: Self.activityFileSource, from: fromDay, to: toDay)) ?? []
        let impSleep = await unionSleepSessions(store: store, from: lo, to: hi)
        let compSleep = await unionComputedSleepSessions(store: store, from: lo, to: hi)

        // Charge-baseline inputs, read on the main actor before detaching: today's local day and the two
        // recalibration epochs the engine reads from the same UserDefaults keys.
        let chargeAnchorDay = AnalyticsEngine.dayString(nowTs, offsetSec: TimeZone.current.secondsFromGMT(for: now))
        let hrvEpoch = Baselines.hrvBaselineEpoch()
        let recoveryEpoch = Baselines.recoveryBaselineEpoch()

        // Export-verbatim sleep figures (long-format metricSeries rows from WhoopImporter).
        let perf = await unionMetricSeries(store: store, key: "sleep_performance", from: fromDay, to: toDay)
        let cons = await unionMetricSeries(store: store, key: "sleep_consistency", from: fromDay, to: toDay)
        let need = await unionMetricSeries(store: store, key: "sleep_need_min", from: fromDay, to: toDay)
        let debt = await unionMetricSeries(store: store, key: "sleep_debt_min", from: fromDay, to: toDay)

        // Merge + sort OFF the main actor: the figures build, daily/sleep merges, source-row sort and
        // freshness counts are pure over the rows just read.
        //
        // The diff runs there too (most refreshes change nothing). The snapshot can't go stale before the
        // publish: only `refresh` assigns these caches and the generation guard drops all but the newest.
        let wasLoaded = loaded
        let current = (days: days, chargeBaselines: chargeBaselines, sleeps: sleeps,
                       importedSleep: importedSleep, vitalRows: vitalRows, freshness: freshness)
        let (merged, unchanged): (MergedCaches, Bool) = await Task.detached(priority: .utility) {
            var fig: [String: ImportedSleepFigures] = [:]
            for p in perf { fig[p.day, default: ImportedSleepFigures()].performancePct = p.value }
            for p in cons { fig[p.day, default: ImportedSleepFigures()].consistencyPct = p.value }
            for p in need { fig[p.day, default: ImportedSleepFigures()].needMin = p.value }
            for p in debt { fig[p.day, default: ImportedSleepFigures()].debtMin = p.value }
            // A hand-edited night (userEdited) keeps its corrected sleep figures even when an import covers
            // that day: the computed ("-zoop") session carries the edit, so collect those days and let the
            // computed row's SLEEP fields win there (imports still win on un-edited days).
            let editedDays = Self.userEditedDays(compSleep)
            let merged = MergedCaches(
                importedSleep: fig,
                days: Self.mergeActivityFileSteps(
                    into: Self.mergeDaily(imported: imported, computed: computed, userEditedDays: editedDays),
                    activityFile
                ),
                // From the two buckets BEFORE `mergeDaily` blends them: the rule needs to know which nights are imported.
                chargeBaselines: ChargeBaselines.resolve(imported: imported, own: computed,
                                                         anchorDay: chargeAnchorDay,
                                                         hrvEpoch: hrvEpoch, recoveryEpoch: recoveryEpoch),
                sleeps: Self.mergeSleep(imported: impSleep, computed: compSleep),
                vitalRows: Self.sourceRows(imported: imported, computed: computed, apple: apple),
                freshness: Self.computeFreshness(imported: imported, computed: computed, apple: apple,
                                                 importedSleeps: impSleep, computedSleeps: compSleep))
            // Byte-identical caches after the first load: skip the re-publish and the `refreshSeq` bump. An
            // equal assignment to an @Published prop still fires objectWillChange, so the skip covers the
            // assignments too (stops the analyze tail's burst of refreshes re-firing TodayView.loadAll()).
            let unchanged = wasLoaded
                && merged.days == current.days
                && merged.chargeBaselines == current.chargeBaselines
                && merged.sleeps == current.sleeps
                && merged.importedSleep == current.importedSleep
                && merged.vitalRows == current.vitalRows
                && merged.freshness == current.freshness
            return (merged, unchanged)
        }.value

        // Generation guard: drop this result if a newer refresh() started while it merged off-actor.
        guard myGen == refreshGen else { return }

        guard !unchanged else { return }

        // One consistent publish: assign every cache, flip `loaded`, then bump `refreshSeq` once.
        self.importedSleep = merged.importedSleep
        self.days = merged.days
        self.chargeBaselines = merged.chargeBaselines
        self.sleeps = merged.sleeps
        self.vitalRows = merged.vitalRows
        self.freshness = merged.freshness
        self.loaded = true
        // Drop the Explorer's cross-catalog memo here rather than waiting for lazy eviction, which would
        // keep a whole catalog of series resident if the user never returns to Explore. The key check
        // stays (it guards an active-strap re-point with no refresh). Kept BEFORE the bump with the other
        // caches: "clear every cache, then publish" must stay true.
        self.exploreAllCache = nil
        self.refreshSeq += 1
    }

    /// Per-source coverage counts for the Freshness Pipeline card. `nonisolated` so the detached merge can call it.
    nonisolated private static func computeFreshness(imported: [DailyMetric], computed: [DailyMetric],
                                         apple: [DailyMetric], importedSleeps: [CachedSleepSession],
                                         computedSleeps: [CachedSleepSession]) -> RepositoryFreshness {
        let days = (imported + computed + apple).map(\.day)
        return RepositoryFreshness(
            importedDays: imported.count,
            computedDays: computed.count,
            appleDays: apple.count,
            importedSleeps: importedSleeps.count,
            computedSleeps: computedSleeps.count,
            earliestDay: days.min(),
            latestDay: days.max()
        )
    }

    /// Imported daily values win field-by-field; computed rows fill only nil imported fields. A day in
    /// `userEditedDays` (hand-edited sleep) takes the COMPUTED row's SLEEP fields over the import, so a
    /// re-import can't mask the correction; non-sleep fields and un-edited days follow imports-win.
    nonisolated static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric],
                                       userEditedDays: Set<String> = []) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for d in imported {
            if let existing = byDay[d.day] {
                let merged = d.fillingNilFields(from: existing)
                byDay[d.day] = userEditedDays.contains(d.day)
                    ? merged.takingSleepFields(from: existing)   // edited night: computed sleep wins
                    : merged
            } else {
                byDay[d.day] = d
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    nonisolated static func mergeActivityFileSteps(into base: [DailyMetric],
                                                   _ activityFile: [DailyMetric]) -> [DailyMetric] {
        guard !activityFile.isEmpty else { return base }
        // Last-wins on a duplicate day: `uniqueKeysWithValues` traps if `base` ever has two rows for a day.
        var byDay = Dictionary(base.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        for row in activityFile {
            guard let steps = row.steps, steps > 0 else { continue }
            if let existing = byDay[row.day] {
                if existing.steps == nil {
                    byDay[row.day] = DailyMetric(
                        day: existing.day,
                        totalSleepMin: existing.totalSleepMin,
                        efficiency: existing.efficiency,
                        deepMin: existing.deepMin,
                        remMin: existing.remMin,
                        lightMin: existing.lightMin,
                        disturbances: existing.disturbances,
                        restingHr: existing.restingHr,
                        avgHrv: existing.avgHrv,
                        recovery: existing.recovery,
                        strain: existing.strain,
                        exerciseCount: existing.exerciseCount,
                        spo2Pct: existing.spo2Pct,
                        skinTempDevC: existing.skinTempDevC,
                        respRateBpm: existing.respRateBpm,
                        steps: steps,
                        activeKcalEst: existing.activeKcalEst,
                        spo2Red: existing.spo2Red,
                        spo2Ir: existing.spo2Ir,
                        skinTempC: existing.skinTempC
                    )
                }
            } else {
                byDay[row.day] = row
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// LOCAL wake-days carrying a user-edited sleep session, keyed as `DailyMetric.day` is (the
    /// engine's cached-offset keyer, matching `mergeSleep.endDay`). Drives the edit-merge precedence in `mergeDaily`.
    nonisolated static func userEditedDays(_ sessions: [CachedSleepSession]) -> Set<String> {
        var days = Set<String>()
        for s in sessions where s.userEdited {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            days.insert(AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec))
        }
        return days
    }

    /// Daily rows tagged with the source that supplied them, for the source-aware vital cards. One
    /// entry per (source, day); the consumer resolves precedence per metric (imported > computed >
    /// Apple). `nonisolated` so the detached merge can call it.
    nonisolated private static func sourceRows(imported: [DailyMetric], computed: [DailyMetric],
                                   apple: [DailyMetric]) -> [SourcedDailyMetric] {
        (imported.map { SourcedDailyMetric(metric: $0, source: .whoopImport) }
            + computed.map { SourcedDailyMetric(metric: $0, source: .zoopComputed) }
            + apple.map { SourcedDailyMetric(metric: $0, source: .appleHealth) })
            .sorted { lhs, rhs in
                if lhs.metric.day == rhs.metric.day {
                    return lhs.source.vitalPriority < rhs.source.vitalPriority
                }
                return lhs.metric.day < rhs.metric.day
            }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on via
    /// `AnalyticsEngine.dayString(_:offsetSec:)`, the engine's LOCAL-day keyer (not the live-zone
    /// `Repository.dayFormatter`, which disagrees across a midnight boundary for non-UTC users).
    nonisolated private static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        // Preserve EVERY session (main night + nap); imported still wins per end-day. Uses the shared
        // grouping in `WhoopStore.SleepMerge`.
        return SleepMerge.merge(imported: imported, computed: computed, endDay: endDay)
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return await unionDailyMetrics(store: store, from: fromDay, to: toDay)
    }

    /// The same dedup over an EXPLICIT id list, so a workout's zone minutes bin its own recording
    /// strap's rows. Order is precedence.
    func hrSamples(deviceIds: [String], from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore(), !deviceIds.isEmpty else { return [] }
        guard deviceIds.count > 1 else {
            return (try? await store.hrSamples(deviceId: deviceIds[0], from: from, to: to,
                                               limit: limit)) ?? []
        }
        var lists: [[HRSample]] = []
        for id in deviceIds {
            lists.append((try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? [])
        }
        return await Self.mergeHRByTsOffMain(lists)
    }

    /// Merges HR lists into one time-ordered stream, deduped by timestamp with the FIRST list winning
    /// ties. Run off the main actor: a day is ~18k rows per namespace and sorting them there stalled scrolling.
    private static func mergeHRByTsOffMain(_ lists: [[HRSample]]) async -> [HRSample] {
        if lists.count == 1 { return lists[0] }
        return await Task.detached(priority: .userInitiated) {
            var byTs: [Int: HRSample] = [:]
            for list in lists {
                for s in list where byTs[s.ts] == nil { byTs[s.ts] = s }
            }
            return byTs.values.sorted { $0.ts < $1.ts }
        }.value
    }

    /// The most recent banked battery reading, for the stale-battery warning. Reads the ACTIVE device
    /// id, not the union: a reading belongs to the strap that sent it.
    func latestBattery() async -> (ts: Int, soc: Double?, charging: Bool?)? {
        guard let store = await ensureStore() else { return nil }
        return try? await store.latestBattery(deviceId: deviceId)
    }

    /// The HR fingerprint over the UNION `hrSamples(from:to:limit:)` reads, as one opaque string. It
    /// walks `rawPhysiologyReadIds` (not `deviceId` alone) so a backfill under an alias id invalidates a
    /// cached result. One COUNT plus one MAX per id over the `(deviceId, ts)` index. Compared only to
    /// itself in memory; the Kotlin twin shares a role, not an encoding, so do not align them.
    func hrFingerprintUnion(from: Int, to: Int) async -> String {
        guard let store = await ensureStore() else { return "" }
        var parts: [String] = []
        for id in rawPhysiologyReadIds(store: store) {
            let fp = (try? await store.hrFingerprint(deviceId: id, from: from, to: to)) ?? (count: 0, maxTs: 0)
            parts.append("\(id):\(fp.count):\(fp.maxTs)")
        }
        return parts.joined(separator: "|")
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        // UNION the active strap + canonical so the HR trend renders wherever the day's raw sits; deduped by
        // ts (active wins), sorted ascending.
        let ids = rawPhysiologyReadIds(store: store)
        guard ids.count != 1 else {
            return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        }
        var lists: [[HRSample]] = []
        for id in ids {
            lists.append((try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? [])
        }
        return await Self.mergeHRByTsOffMain(lists)
    }

    /// Cheap change-detector over a window of heart rate (a COUNT and a MAX on an indexed column, no
    /// rows decoded), so the stress widget's producer needn't read a day's streams each tick. Unions
    /// the same ids as the reads above; nil without a store means "cannot tell", not "unchanged".
    func hrFingerprint(from: Int, to: Int) async -> (count: Int, maxTs: Int)? {
        guard let store = await ensureStore() else { return nil }
        var count = 0
        var maxTs = 0
        for id in rawPhysiologyReadIds(store: store) {
            guard let fp = try? await store.hrFingerprint(deviceId: id, from: from, to: to) else { continue }
            count += fp.count
            maxTs = max(maxTs, fp.maxTs)
        }
        return (count, maxTs)
    }

    /// R-R beats across the active physical WHOOP and canonical history; exact duplicates removed
    /// active-first, same-timestamp distinct beats kept.
    func rrIntervals(from: Int, to: Int, limit: Int = 8000) async -> [RRInterval] {
        guard let store = await ensureStore() else { return [] }
        // Keep each physical strap's independently filtered history after a switch; only the ambiguous
        // canonical alias inherits WHOOP 5's unit guard (a confirmed WHOOP 4 keeps its policy).
        let activeWhoop5 = (try? await store.isWhoop5RRSource(deviceId: deviceId)) == true
        let ids = rawPhysiologyReadIds(store: store)
        guard ids.count != 1 else {
            return (try? await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        }
        var lists: [[RRInterval]] = []
        for id in ids {
            lists.append((try? await store.rrIntervals(deviceId: id, from: from, to: to, limit: limit,
                unlabelledAliasOfWhoop5: activeWhoop5 && id == Self.whoopSource)) ?? [])
        }
        // Tens of thousands of rows per namespace: merge off the main actor.
        let merged = lists
        return await Task.detached(priority: .userInitiated) { Self.mergeRRByIdentity(merged) }.value
    }

    /// Logical day-start of the most recent day with HR data, or nil for an empty store, so the Deep
    /// Timeline can open on a day that has data.
    func latestDataDayStart() async -> Date? {
        guard let store = await ensureStore() else { return nil }
        guard let ts = await unionLatestHRSampleTs(store: store) else { return nil }
        return Self.logicalDayStart(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Downsampled HR (mean bpm per `bucketSeconds`) for a Today/24h trend, aggregated in SQL so a day
    /// never loads the raw ~1 Hz rows. Also reads an EXPLICIT id list (a workout's own strap); earlier ids win per bucket.
    func hrBuckets(deviceIds: [String], from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore(), !deviceIds.isEmpty else { return [] }
        guard deviceIds.count > 1 else {
            return (try? await store.hrBuckets(deviceId: deviceIds[0], from: from, to: to,
                                               bucketSeconds: bucketSeconds)) ?? []
        }
        var byStart: [Int: HRBucket] = [:]
        for id in deviceIds {
            for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to,
                                                 bucketSeconds: bucketSeconds)) ?? [] where byStart[b.ts] == nil {
                byStart[b.ts] = b
            }
        }
        return byStart.values.sorted { $0.ts < $1.ts }
    }

    func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore() else { return [] }
        // UNION all registered WHOOP straps + canonical; per bucket-start the active strap wins.
        return await hrBuckets(deviceIds: rawPhysiologyReadIds(store: store), from: from, to: to,
                               bucketSeconds: bucketSeconds)
    }

    /// The latest non-nil @63 activity class over `[from, to]`, across the active strap + canonical
    /// UNION (`importedReadIds`), for the Steps tile icon. A re-added strap banks its live step samples
    /// under its own id, so a canonical-only read would lose the icon. Ties on ts favour the active strap.
    func stepActivityClassLatest(from: Int, to: Int) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        var perId: [[StepSample]] = []
        for id in importedReadIds {   // active strap FIRST so it wins a ts tie
            perId.append((try? await store.stepSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? [])
        }
        return Self.latestActivityClass(perId)
    }

    /// Raw strap step TICKS over `[from, to]` for a manual-workout summary: the wrap-aware
    /// `step_motion_counter@57` delta-sum (shared `StepsCounter` kernel) from the FIRST id with a
    /// countable window (active wins). Never MERGED across ids: interleaving two devices' cumulative
    /// counters would fabricate huge deltas. nil when no strap counter covers the window (WHOOP 4.0, or
    /// an MG/5.0 not yet offloaded); the caller applies `stepTicksPerStep` and reconciles with the pedometer.
    func strapStepTicks(from: Int, to: Int) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        for id in importedReadIds {   // active strap FIRST
            let samples = (try? await store.stepSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? []
            if let ticks = StepsCounter.stepsInWindow(samples) { return ticks }
        }
        return nil
    }

    /// Pure pick of the latest classed activity across the union's per-id step lists: the non-nil
    /// `activityClass` on the greatest ts, a tie going to the FIRST list (active strap).
    nonisolated static func latestActivityClass(_ perId: [[StepSample]]) -> Int? {
        var bestTs = Int.min
        var bestClass: Int? = nil
        for list in perId {
            for s in list where s.activityClass != nil {
                // Strict `>` keeps the FIRST list's sample on an exact ts tie.
                if s.ts > bestTs { bestTs = s.ts; bestClass = s.activityClass }
            }
        }
        return bestClass
    }

    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return await unionSleepSessions(store: store, from: from, to: to, limit: limit)
    }

    /// Computed ("-zoop") sleep sessions for a ts range, oldest first by onset: the fallback for a
    /// Bluetooth-only strap whose nights are all under the COMPUTED source. Callers use it ONLY when the
    /// imported read is empty.
    func computedSleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return (await unionComputedSleepSessions(store: store, from: from, to: to, limit: limit))
            .sorted { $0.startTs < $1.startTs }
    }

    /// Every sleep BLOCK across BOTH sources, un-deduplicated, so split-sleep days (nap + main sleep)
    /// keep all blocks. Reads the COMPUTED source (`computedDeviceId`) too, since a Bluetooth-only user
    /// has every block there. Imported blocks win on days they cover; computed fill the rest. Oldest first.
    func allSleepSessions(days: Int = 4000) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        let rawIds = rawPhysiologyReadIds(store: store)
        let rawComputedIds = rawComputedReadIds(store: store)
        // UNION the active strap + canonical and their computed siblings, keeping ALL blocks but collapsing
        // a night recorded under BOTH union ids even when bounds differ slightly.
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: rawIds, from: lo, to: hi))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: rawComputedIds, from: lo, to: hi))
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        var importedDays = Set<Date>()
        for s in imported { importedDays.insert(endDay(s)) }
        let computedKept = computed.filter { !importedDays.contains(endDay($0)) }
        return (imported + computedKept).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// The persisted per-epoch MOTION series for each of `starts` (detected session start keys). Motion
    /// is written ONLY under the computed ("-zoop") source, so an imported-only night has none (absent
    /// stays absent, never a fabricated zero array). Doesn't resolve the night: the caller passes the
    /// chosen blocks' starts. A start with no stored series is omitted.
    func sessionMotions(sessions: [CachedSleepSession]) async -> [Int: [Double]] {
        guard !sessions.isEmpty, let store = await ensureStore() else { return [:] }
        let rawIds = rawPhysiologyReadIds(store: store)
        let computedIds = rawComputedReadIds(store: store)
        let starts = sessions.map(\.startTs)
        let lo = starts.min() ?? 0
        let hi = starts.max() ?? 0

        // Phase 1, ownership. A block read from the store carries its device, so the probe below runs only
        // for hand-built blocks (tests, importers). Provenance gives the SAME answer as the probe, which
        // takes the first id in `rawIds + computedIds` whose bounds match and normalises to its computed
        // twin. Uses `sleepSessionBounds` (two integers per block), not `sleepSessions`, to avoid hauling
        // every night's `stagesJSON` per candidate device. Unpaged, so a sparse subset of a wide span can't
        // page short and lose owners.
        var boundsByDevice: [String: [Int: Int]] = [:]   // deviceId -> startTs -> endTs
        if sessions.contains(where: { $0.deviceId == nil }) {
            for id in rawIds + computedIds {
                boundsByDevice[id] = (try? await store.sleepSessionBounds(deviceId: id,
                                                                          from: lo, to: hi)) ?? [:]
            }
        }

        // Each block's ordered source list: its own device if the read supplied one, else the imported-wins
        // owner search, then its computed twin first and the computed ids behind it.
        var sourcesByStart: [Int: [String]] = [:]
        for session in sessions where sourcesByStart[session.startTs] == nil {
            var owner: String? = session.deviceId
            if owner == nil {
                for id in rawIds + computedIds {
                    if boundsByDevice[id]?[session.startTs] == session.endTs {
                        owner = id
                        break
                    }
                }
            }
            let ownerComputed = owner.map { $0.hasSuffix("-zoop") ? $0 : $0 + "-zoop" }
            sourcesByStart[session.startTs] = ([ownerComputed].compactMap { $0 } + computedIds)
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        }

        // Phase 2, motion, in ROUNDS rather than all sources for all blocks: a night's motion is kilobytes
        // of JSON, so asking every computed device for every block would decode several times over. Round k
        // asks each device only for blocks whose k-th source it is and which are still unfilled, so owned
        // blocks resolve in the first round and the second rarely runs.
        var out: [Int: [Double]] = [:]
        var round = 0
        let maxRounds = sourcesByStart.values.map(\.count).max() ?? 0
        while round < maxRounds {
            var wantedByDevice: [String: [Int]] = [:]
            for (start, sources) in sourcesByStart where out[start] == nil && round < sources.count {
                wantedByDevice[sources[round], default: []].append(start)
            }
            if wantedByDevice.isEmpty { break }
            for (id, wanted) in wantedByDevice {
                let motions = (try? await store.sessionMotions(deviceId: id, sessionStarts: wanted)) ?? [:]
                for (start, motion) in motions where out[start] == nil && !motion.isEmpty {
                    out[start] = motion
                }
            }
            round += 1
        }
        return out
    }

    /// The user's learned habitual midsleep (local time-of-day seconds), or nil under
    /// `SleepStageTotals.habitualMinDays` of history. Computed EXACTLY as
    /// `IntelligenceEngine.computeHabitualSleep` does (same imported + computed session union, one
    /// `HistoryBlock` per session, shared `SleepStageTotals.habitualMidsleepSec`), so the Sleep tab's
    /// main-night pick matches the analytics rollup for shift/late sleepers. Reads a wide window so the
    /// distinct-day count clears the threshold.
    func habitualMidsleepSec(days: Int = 4000) async -> Int? {
        guard let store = await ensureStore() else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // Same all-registered-WHOOP source set as allSleepSessions, so retained nights of a removed strap teach the selector.
        let rawIds = rawPhysiologyReadIds(store: store)
        let rawComputedIds = rawComputedReadIds(store: store)
        let imported = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: rawIds, from: lo, to: hi))
        let computed = Self.dedupBlocks(await unionRawSleepBlocks(store: store, ids: rawComputedIds, from: lo, to: hi))
        let offsetSec = TimeZone.current.secondsFromGMT()
        let blocks = (imported + computed).compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
    }

    /// Hand-corrects a night's bed (onset) and/or wake (end) time. `detectedStartTs` is the immutable
    /// detected key; the corrected onset goes in `startTsAdjusted` so the key never moves. Applies under
    /// BOTH imported and computed sources (the merged list carries no deviceId); only the owning
    /// namespace updates. Stages are re-derived from the raw streams for the corrected window via
    /// `SleepStager.stageSession`, falling back to reshaping the stored summary (`SleepWindowReclip`)
    /// for a night with no raw data. Refreshes so the hero re-reads immediately.
    func editSleepTimes(detectedStartTs: Int, oldEndTs: Int, storedStagesJSON: String?,
                        newStartTs: Int, newEndTs: Int) async {
        guard let store = await ensureStore() else { return }
        // Never persist a future-ending or inverted window, whatever the UI sent: the last line of defence
        // so no client can write a phantom night the display merge cannot render.
        guard let window = SleepEditGuard.clampedEditWindow(
            start: newStartTs, end: newEndTs, now: Int(Date().timeIntervalSince1970)) else { return }
        let (safeStartTs, safeEndTs) = window
        // Re-derive stages from raw for the corrected window; fall back to reshaping the stored summary
        // when the strap has no dense data there (an imported night, or an edit made BEFORE a sync
        // imported the window, which `selfHealEditedStages` fixes on the next `analyzeRecent`).
        let stagesJSON = await restageFromRaw(start: safeStartTs, end: safeEndTs)
            ?? SleepWindowReclip.reclip(stagesJSON: storedStagesJSON, sessionStart: detectedStartTs,
                                        oldEnd: oldEndTs, newStart: safeStartTs, newEnd: safeEndTs)
        // Apply to the source that OWNS this block, resolved against every namespace the Sleep tab can
        // display. Stop at the first match so a coincidental same-startTs row elsewhere takes no second edit.
        for ownerDeviceId in sleepOwnerIds {
            let changed = (try? await store.applySleepEdit(
                deviceId: ownerDeviceId, detectedStartTs: detectedStartTs,
                newStartTs: safeStartTs, newEndTs: safeEndTs, stagesJSON: stagesJSON)) ?? 0
            if changed > 0 { break }
        }
        await refresh()
    }

    /// Deletes ONE sleep session so the day recomputes as if it were never recorded. `detectedStartTs`
    /// is the immutable detected key; `endTs` is recorded in the tombstone so the engine's overlap test
    /// suppresses a re-detected onset that drifts. Deletes from the owning namespace (computed first,
    /// imported fallback; never a coincidental same-startTs row elsewhere), and for a DETECTED night
    /// persists a `dismissedSleep` span so `analyzeRecent` doesn't regenerate it. A `userEdited` night is
    /// deleted WITHOUT a tombstone (never re-detected). Refreshes. Returns the snapshot needed to UNDO
    /// (the row + its owning namespace), or nil when no row matched.
    @discardableResult
    func deleteSleepSession(detectedStartTs: Int, endTs: Int) async -> SleepDeletionSnapshot? {
        guard let store = await ensureStore() else { return nil }
        // Snapshot the owning row BEFORE deleting, resolving the owner as the delete does; a one-second
        // window around the immutable detected key identifies the row.
        let snapshot = await ownedSleepRowSnapshot(store: store, detectedStartTs: detectedStartTs)
        // Tombstone ONLY a DETECTED night: a `userEdited` row is never re-detected, and suppressing its
        // window would block a real future night that overlaps it.
        if DismissedSleepSpans.writesTombstoneOnDelete(userEdited: snapshot?.session.userEdited ?? false) {
            dismissedSleepSpans = DismissedSleepSpans.adding(startTs: detectedStartTs, endTs: endTs,
                                                             to: dismissedSleepSpans)
        }
        // Delete from the same owner union the Sleep tab reads, first match wins.
        for ownerDeviceId in sleepOwnerIds {
            let deleted = (try? await store.deleteSleepSession(
                deviceId: ownerDeviceId, startTs: detectedStartTs)) ?? 0
            if deleted > 0 { break }
        }
        await refresh()
        return snapshot
    }

    /// Undoes a `deleteSleepSession`: lifts the tombstone and restores the row into its ORIGINAL owning
    /// namespace, preserving `userEdited`. Single-level and transient. Idempotent: a snapshot with no
    /// tombstone still restores the row.
    func undoDeleteSleepSession(_ snapshot: SleepDeletionSnapshot) async {
        guard let store = await ensureStore() else { return }
        // Lift the tombstone so the restored night isn't re-suppressed on the next pass.
        dismissedSleepSpans = DismissedSleepSpans.removing(startTs: snapshot.session.startTs,
                                                           endTs: snapshot.endTs, from: dismissedSleepSpans)
        // Restore into the SAME namespace that owned it; upsertSleepSessions preserves userEdited.
        _ = try? await store.upsertSleepSessions([snapshot.session], deviceId: snapshot.ownerDeviceId)
        // Re-persist the motion + band-state series the delete dropped (not on CachedSleepSession). Must
        // run AFTER the upsert (both are UPDATEs keyed on (deviceId, startTs)). A nil series persists the
        // empty array, which the store maps to NULL.
        _ = try? await store.persistSessionMotion(deviceId: snapshot.ownerDeviceId,
                                                  sessionStart: snapshot.session.startTs,
                                                  motionEpochs: snapshot.motion ?? [])
        _ = try? await store.persistSessionSleepState(deviceId: snapshot.ownerDeviceId,
                                                     sessionStart: snapshot.session.startTs,
                                                     states: snapshot.sleepState ?? [])
        await refresh()
    }

    /// Reads the single owned sleep row for `detectedStartTs`, resolving the namespace as
    /// `deleteSleepSession` does; returns the row plus its owning deviceId for undo.
    private func ownedSleepRowSnapshot(store: WhoopStore, detectedStartTs: Int) async -> SleepDeletionSnapshot? {
        func row(_ deviceId: String) async -> CachedSleepSession? {
            let rows = (try? await store.sleepSessions(deviceId: deviceId,
                                                       from: detectedStartTs, to: detectedStartTs,
                                                       limit: 4)) ?? []
            return rows.first { $0.startTs == detectedStartTs }
        }
        // Capture the motion + band-state series with the row: they aren't on CachedSleepSession and the
        // delete drops them.
        func snapshot(_ session: CachedSleepSession, owner: String) async -> SleepDeletionSnapshot {
            let motion = try? await store.sessionMotion(deviceId: owner, sessionStart: detectedStartTs)
            let sleepState = try? await store.sessionSleepState(deviceId: owner, sessionStart: detectedStartTs)
            return SleepDeletionSnapshot(session: session, ownerDeviceId: owner, endTs: session.endTs,
                                         motion: motion ?? nil, sleepState: sleepState ?? nil)
        }
        // Same owner union as the edit/delete paths, so the snapshot records the row's REAL owner.
        for ownerDeviceId in sleepOwnerIds {
            if let session = await row(ownerDeviceId) {
                return await snapshot(session, owner: ownerDeviceId)
            }
        }
        return nil
    }

    /// Durable "user deleted this night" tombstones as "startTs:endTs" strings in UserDefaults (this
    /// layer must not add a table to the WhoopStore Journal file, like dismissed WORKOUT spans). The
    /// re-detector in `IntelligenceEngine.analyzeRecent` consults `dismissedSleepWindows`. Pure
    /// token/window logic lives in `DismissedSleepSpans`.
    private var dismissedSleepSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Repository.dismissedSleepDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Repository.dismissedSleepDefaultsKey) }
    }

    /// UserDefaults key holding the dismissed-sleep spans (see `dismissedSleepSpans`).
    static let dismissedSleepDefaultsKey = "sleep.dismissedSessions"

    /// Parsed dismissed-sleep windows for the re-detection guard; malformed or non-positive-width entries are dropped.
    func dismissedSleepWindows() -> [(start: Int, end: Int)] {
        DismissedSleepSpans.windows(from: dismissedSleepSpans)
    }

    /// Manually ADDS a missed sleep session, typically a daytime nap. Stages from raw over
    /// `[startTs, endTs]` (as `restageFromRaw`), falling back to one "awake" block until the post-sync
    /// self-heal. Written under the COMPUTED source as its own row with `userEdited = 1`, so the
    /// recompute guard preserves it and it is never folded into the night's main sleep. Additive:
    /// `insertManualSleepSession` no-ops if a session exists at that exact onset.
    func addManualNap(startTs: Int, endTs: Int) async {
        // A manually-added session can't end in the future or invert (a future nap would own the tab's
        // newest day as an all-awake phantom). The clamped end is used verbatim.
        guard let store = await ensureStore(),
              let window = SleepEditGuard.clampedEditWindow(
                  start: startTs, end: endTs, now: Int(Date().timeIntervalSince1970)) else { return }
        let (safeStartTs, safeEndTs) = window
        // Stage from raw; fall back to a single awake block until the self-heal re-stages. Efficiency is
        // the asleep fraction of the staged window; nil for the fallback.
        let stagesJSON = await restageFromRaw(start: safeStartTs, end: safeEndTs)
            ?? AnalyticsEngine.encodeStages([StageSegment(start: safeStartTs, end: safeEndTs, stage: "wake")])
        let efficiency = sleepEfficiency(fromStagesJSON: stagesJSON)
        _ = try? await store.insertManualSleepSession(
            deviceId: computedDeviceId, startTs: safeStartTs, endTs: safeEndTs,
            efficiency: efficiency, stagesJSON: stagesJSON)
        await refresh()
    }

    /// Asleep fraction (light+deep+rem / total in-bed) of a segment-array `stagesJSON`, or nil for the
    /// awake-only fallback or unparseable JSON; seeds a manual nap's efficiency.
    private func sleepEfficiency(fromStagesJSON json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var asleep = 0.0, total = 0.0
        for seg in arr {
            guard let s = (seg["start"] as? NSNumber)?.intValue,
                  let e = (seg["end"] as? NSNumber)?.intValue,
                  let stage = seg["stage"] as? String, e > s else { continue }
            let dur = Double(e - s)
            total += dur
            if stage != "wake" && stage != "awake" { asleep += dur }
        }
        return total > 0 && asleep > 0 ? asleep / total : nil
    }

    /// The onset evidence for a night (Sleep "Why this sleep?"): what the HR-confirmed onset rule saw and
    /// decided under the CURRENT detection settings, rebuilt from raw by `SleepStager.explainOnset`.
    /// nil when the window has no raw gravity. Re-staging (`restageFromRaw`) needs dense worn-night data
    /// (~1 sample / 2 min) and runs off the main actor.
    func sleepOnsetEvidence(startTs: Int, endTs: Int) async -> SleepOnsetEvidence? {
        guard let store = await ensureStore(), endTs > startTs else { return nil }
        // Hours either side so the gravity-still run the night was built from is rebuilt whole.
        let lo = startTs - 6 * 3_600, hi = endTs + 2 * 3_600
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: 400_000)) ?? []
        guard grav.count >= 2 else { return nil }
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: 400_000)) ?? []
        let tuning = SleepOnsetPrefs.tuning
        let tz = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(startTs)))
        return await Task.detached(priority: .userInitiated) {
            SleepStager.explainOnset(hr: hr, gravity: grav, sessionStart: startTs, sessionEnd: endTs,
                                     tzOffsetSeconds: tz, tuning: tuning)
        }.value
    }

    private func restageFromRaw(start: Int, end: Int) async -> String? {
        guard let store = await ensureStore() else { return nil }
        let lo = start - 3_600, hi = end + 3_600
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let inWindowGravity = grav.lazy.filter { $0.ts >= start && $0.ts <= end }.count
        let windowSeconds = max(1, end - start)
        guard inWindowGravity >= max(20, windowSeconds / 120) else { return nil }
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? []
        // Same provenance refusal as the nightly scan: an Oura ring's respiration rows are a per-window
        // RATE, not the ~1 Hz raw waveform this stager reads (`OuraRespScale.forScoring`).
        let resp = OuraRespScale.forScoring(
            (try? await store.respSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? [],
            deviceId: deviceId)
        // Read only when the refinement below might use it (`useMotionAwareWake`).
        let useMotionAwareWake = PuffinExperiment.motionAwareWakeEnabled
        let steps = useMotionAwareWake
            ? ((try? await store.stepSamples(deviceId: deviceId, from: lo, to: hi, limit: 200_000)) ?? [])
            : []
        // Which staging engine re-stages this window (Settings > Experimental > Sleep staging): default ON
        // is the cardiorespiratory `SleepStagerV2`, OFF falls back to V1 `SleepStager`. Detection is
        // identical either way.
        let useV2 = PuffinExperiment.experimentalSleepV2Enabled
        let segs = await Task.detached(priority: .utility) {
            let staged = useV2
                ? SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
                : SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
            // Motion-aware wake refinement post-pass; a no-op when its Experimental toggle is off.
            return WakeMotionRefinement.apply(staged, grav: grav, steps: steps, enabled: useMotionAwareWake)
        }.value
        return AnalyticsEngine.encodeStages(segs)
    }

    /// Self-heal for the edit-races-sync case: a night edited BEFORE its raw streams synced got
    /// fabricated `SleepWindowReclip` stages and the `userEdited` flag froze them. Called from
    /// `analyzeRecent` after each sync backfill, it re-derives stages from the now-available raw over
    /// each edited night's LOCKED bounds and rewrites the stage breakdown ONLY, never the user's
    /// correction. Idempotent (equal results skip the write); a truly imported night is left alone.
    /// Works on the COMPUTED source and returns the refreshed edited rows for daily-aggregate recompute.
    func selfHealEditedStages(from windowStart: Int, to windowEnd: Int) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        func editedRows() async -> [CachedSleepSession] {
            ((try? await store.sleepSessions(deviceId: computedDeviceId, from: windowStart,
                                             to: windowEnd, limit: 100_000)) ?? [])
                .filter { $0.userEdited }
        }
        let edited = await editedRows()
        guard !edited.isEmpty else { return [] }
        var healed = false
        for row in edited {
            // Re-derive over the LOCKED corrected window; skip when raw isn't dense yet or the result matches what's stored.
            guard let newJSON = await restageFromRaw(start: row.effectiveStartTs, end: row.endTs),
                  newJSON != row.stagesJSON else { continue }
            let n = (try? await store.updateSleepStages(deviceId: computedDeviceId,
                                                        detectedStartTs: row.startTs,
                                                        stagesJSON: newJSON)) ?? 0
            if n > 0 { healed = true }
        }
        return healed ? await editedRows() : edited
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health"). For the
    /// canonical WHOOP id it UNIONs the active strap (deduped per day, active wins); other sources read
    /// verbatim. `fullHistory` spans the whole recordable epoch regardless of `days`.
    func series(key: String, source: String, days: Int = 4000, fullHistory: Bool = false) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))
        let pts: [MetricPoint]
        if source == canonicalDeviceId {
            pts = await unionMetricSeries(store: store, key: key, from: from, to: to)
        } else {
            pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        }
        return pts.map { ($0.day, $0.value) }
    }

    // MARK: - Deep Timeline (full-day full-resolution viewer)
    //
    // Draws one metric across a zoomable window at the resolution the zoom demands: a day reads COARSE
    // SQL buckets (never ~86k raw 1 Hz rows), a zoomed-in window reads RAW per-second rows. The choice
    // lives in the read layer so the chart receives ~targetPoints points regardless of zoom.

    /// A metric the Deep Timeline can plot. HR is the always-present hero (adaptively downsampled); the
    /// rest are lower-frequency raw-sample streams shown where the strap offloaded them.
    enum TimelineMetric: String, CaseIterable, Identifiable, Sendable {
        case hr, hrv, spo2, skinTemp, respiration, motion, bandSleepState, ouraMovement
        var id: String { rawValue }

        /// User-facing pill label.
        var title: String {
            switch self {
            case .hr: return String(localized: "Heart Rate")
            // The .hrv series is a TRAILING-WINDOW rMSSD (HRVAnalyzer.rollingRmssd), not raw R-R ms; label it honestly.
            case .hrv: return String(localized: "Windowed rMSSD")
            case .spo2: return "SpO₂"
            case .skinTemp: return String(localized: "Skin Temp")
            case .respiration: return String(localized: "Respiration")
            case .motion: return String(localized: "Motion")
            // The strap's OWN band sleep_state track (0 wake/1 still/2 asleep/3 up): the band's reported state,
            // not a stage Zoop trusts, so the pill says "Band Sleep State".
            case .bandSleepState: return String(localized: "Band Sleep State")
            // The Oura ring's OWN per-window motion (seconds of movement per ~30 s window, 0x47 OURA_MOTION):
            // an ACTIVITY signal, not gravity and never steps. Empty for WHOOP. Labelled "Movement".
            case .ouraMovement: return String(localized: "Movement")
            }
        }
    }

    /// One Deep-Timeline read: the points, whether they came from raw seconds or coarse buckets, and the bucket width.
    struct TimelineSeries: Sendable {
        var points: [TrendPoint]
        var isRaw: Bool
        var bucketSeconds: Int
        static let empty = TimelineSeries(points: [], isRaw: false, bucketSeconds: 0)
    }

    /// Pure adaptive-resolution decision: the bucket width (seconds) for a `[from, to]` window yielding
    /// ABOUT `targetPoints` points; 1 means "read raw per-second rows". span/targetPoints is floored at
    /// 1 s and rounded to a friendly step so neighbouring zoom levels share bucket edges (no shimmer).
    nonisolated static func timelineBucketSeconds(spanSeconds: Int, targetPoints: Int) -> Int {
        let span = max(1, spanSeconds)
        let target = max(1, targetPoints)
        let ideal = span / target
        guard ideal > 1 else { return 1 }      // zoomed in enough that raw seconds already fit the budget
        // Snap up to a friendly step so neighbouring zoom levels reuse bucket boundaries.
        let steps = [2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        for s in steps where s >= ideal { return s }
        return steps.last!
    }

    /// Trailing-window width (seconds) for the windowed-rMSSD `.hrv` series: ~1/30 of the visible span,
    /// clamped to [120 s, 600 s], so zoomed-in views show short swings and wide views stay readable.
    nonisolated static func hrvRollingWindowSec(spanSeconds: Int) -> Int {
        let span = max(1, spanSeconds)
        return min(600, max(120, span / 30))
    }

    /// Plausible range for a SINGLE-CHANNEL SpO2 reading plotted as a percentage. It only excludes the
    /// mis-scaled `dc_raw` magnitudes (-1016 ... 11,709,098); it is deliberately NOT a clamp to 100.
    /// Open question: on a real Gen 3 capture the `0x6F` channel spans 81-106 with 47% of samples above
    /// 100, yet real SpO2 cannot exceed 100 % and open_oura clamps its own to [85, 100]. That points at an
    /// un-modelled offset in Zoop's `0x6F` decode, and clamping would hide it, so the bound stays 110.
    /// Revisit once the `0x6F` scale is pinned (OURA_PROTOCOL.md section 6.5). Derived from
    /// `AnalyticsEngine.spo2SingleChannelPlausible` (50...110).
    nonisolated static let spo2SingleChannelPlausible = Double(AnalyticsEngine.spo2SingleChannelPlausible.lowerBound)...Double(AnalyticsEngine.spo2SingleChannelPlausible.upperBound)

    /// One SpO2 sample to the value the Deep Timeline plots, or nil to skip it. Two shapes share this
    /// table: two-channel (WHOOP 4.0 v24) has no calibrated %, so the proxy is the unitless `red / ir`
    /// ratio; single-channel (Oura) stores its reading in `red` with `ir = 0` (an unread channel), and the
    /// reading itself is the value. Single-channel is range-gated by `spo2SingleChannelPlausible`, since
    /// the `unit` tag separating `raw` from the mis-scaled `dc_raw` channel isn't persisted. A DISPLAY
    /// gate only (SpO2 is never scored; no stored row changes); the ratio path is not gated.
    nonisolated static func spo2TimelineValue(red: Int, ir: Int) -> Double? {
        guard ir <= 0 else { return Double(red) / Double(ir) }   // two-channel: unchanged ratio proxy
        let v = Double(red)
        return spo2SingleChannelPlausible.contains(v) ? v : nil
    }

    /// Deep-Timeline read facade: ~`targetPoints` points for `metric` over `[from, to]` from `source`
    /// (default the user's own strap), choosing raw seconds vs coarse buckets adaptively. HR rides the
    /// COALESCE reads (`hrBuckets`/`hrSamples`) so a PPG-only WHOOP 5 day still renders. Other metrics
    /// read their raw sample tables and bin to the bucket grid when zoomed out.
    func timelineSeries(metric: TimelineMetric, from: Int, to: Int,
                        targetPoints: Int = 600, source: String? = nil) async -> TimelineSeries {
        guard to > from, let store = await ensureStore() else { return .empty }
        // Default (no explicit source): the complete worn WHOOP timeline (active, prior straps, canonical
        // history). An explicit per-source page reads that source verbatim.
        let unionIds: [String] = source.map { [$0] } ?? rawPhysiologyReadIds(store: store)
        let bucket = Self.timelineBucketSeconds(spanSeconds: to - from, targetPoints: targetPoints)
        let isRaw = bucket <= 1

        if metric == .hr {
            // Both HR paths COALESCE measured + ppgHrSample via the store reads. Day scale: SQL buckets; zoomed-in: raw.
            if isRaw {
                // Read each source's raw seconds, then dedup + sort + map (up to 200k rows) on a utility task off
                // the main actor. Mirrors `restageFromRaw`.
                var perId: [[HRSample]] = []
                for id in unionIds {
                    perId.append((try? await store.hrSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? [])
                }
                let points = await Task.detached(priority: .utility) {
                    Self.dedupSortRawHr(perId)
                }.value
                return TimelineSeries(points: points, isRaw: true, bucketSeconds: 1)
            }
            var byStart: [Int: HRBucket] = [:]
            for id in unionIds {
                for b in (try? await store.hrBuckets(deviceId: id, from: from, to: to, bucketSeconds: bucket)) ?? [] where byStart[b.ts] == nil { byStart[b.ts] = b }
            }
            return TimelineSeries(points: byStart.values.sorted { $0.ts < $1.ts }.map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm)
            }, isRaw: false, bucketSeconds: bucket)
        }

        // Non-HR streams are far sparser than 1 Hz HR, so a day is safe to load; downsample to the bucket
        // grid when zoomed out, with the dedup + sort + downsample on a utility task. Resolve each source
        // id's strap family ONCE (skin-temp raw to C is family-specific: 5/MG centidegrees vs 4.0 v24 raw
        // ADC); a positively-identified 4.0 maps to `.whoop4`, everything else to `.whoop5`.
        let familyById = Self.skinTempFamilies(store: store, ids: unionIds)
        var perId: [[TrendPoint]] = []
        for id in unionIds {
            perId.append(await timelineRawMetric(metric: metric, store: store, source: id,
                                                 family: familyById[id] ?? .whoop5, from: from, to: to))
        }
        let points = await Task.detached(priority: .utility) {
            Self.dedupSortDownsampleRaw(perId, isRaw: isRaw, bucketSeconds: bucket)
        }.value
        guard !points.isEmpty else { return TimelineSeries(points: [], isRaw: isRaw, bucketSeconds: bucket) }
        return TimelineSeries(points: points, isRaw: isRaw, bucketSeconds: isRaw ? 1 : bucket)
    }

    /// Maps each device id to the strap family that wrote its rows, for the family-aware skin-temp
    /// conversion. Reads the registry once (mapping in `DeviceFamily.forRegistryDevice`); an unreadable
    /// registry yields an empty map, so callers fall back to `.whoop5`.
    private static func skinTempFamilies(store: WhoopStore, ids: [String]) -> [String: DeviceFamily] {
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        var out: [String: DeviceFamily] = [:]
        for id in ids {
            let d = devices.first(where: { $0.id == id })
            // A non-WHOOP device (nil) shares the non-4.0 branch, so it coalesces to `.whoop5` (its prior scale).
            out[id] = DeviceFamily.forRegistryDevice(model: d?.model, brand: d?.brand) ?? .whoop5
        }
        return out
    }

    /// Is the ACTIVE strap a 5.0/MG-family WHOOP? Gates the deep timeline's family-specific empty-state
    /// copy. Uses `DeviceFamily.isWhoop5Registry` so a non-WHOOP brand (an Oura ring) doesn't get WHOOP-5
    /// copy. No store or unreadable registry returns `false`, the generic copy.
    func activeStrapIsWhoop5() -> Bool {
        guard let store else { return false }
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        let d = devices.first(where: { $0.id == deviceId })
        return DeviceFamily.isWhoop5Registry(model: d?.model, brand: d?.brand)
    }

    /// The active device's registry display name (nickname, else "Brand Model") for screens naming the
    /// source of what they plot; nil when the active id has no registry row, so the caller keeps its
    /// legacy "My WHOOP" copy.
    func activeDeviceDisplayName() -> String? {
        guard let store else { return nil }
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        return devices.first(where: { $0.id == deviceId })?.displayName
    }

    /// Whether the active strap has EVER banked a sample of `metric`: distinguishes a strap that never
    /// produces it ("not supported" copy) from one with an unsynced window. Only SpO2/respiration are
    /// asked; any other metric returns true. Best-effort.
    func strapHasEverProduced(_ metric: TimelineMetric) async -> Bool {
        guard let store else { return true }
        let now = Int(Date().timeIntervalSince1970)
        switch metric {
        case .spo2:
            return !(((try? await store.spo2Samples(deviceId: deviceId, from: 0, to: now, limit: 1)) ?? []).isEmpty)
        case .respiration:
            return !(((try? await store.respSamples(deviceId: deviceId, from: 0, to: now, limit: 1)) ?? []).isEmpty)
        default:
            return true
        }
    }

    /// Raw points for a non-HR timeline metric in display units (skin temp to C, family-aware via
    /// `skinTempCelsius`; HRV per-RR instantaneous from RR ms; respiration/SpO2/motion as stored).
    /// Empty when nothing was offloaded. `family` is the strap that wrote `source`'s rows.
    private func timelineRawMetric(metric: TimelineMetric, store: WhoopStore, source: String,
                                   family: DeviceFamily, from: Int, to: Int) async -> [TrendPoint] {
        switch metric {
        case .hr:
            return []   // handled by the caller's HR path
        case .hrv:
            // Plot a TRAILING-WINDOW rMSSD via HRVAnalyzer.rollingRmssd (same range and Malik ectopic
            // filtering as the nightly path), not raw R-R ms. A sparse or artifact-heavy window emits nothing.
            // The `to - from` span picks the window width; a thinning stride keeps 1 Hz R-R from emitting a
            // point per beat.
            let activeWhoop5 = (try? await store.isWhoop5RRSource(deviceId: deviceId)) ?? true
            let rr = (try? await store.rrIntervals(deviceId: source, from: from, to: to, limit: 200_000,
                unlabelledAliasOfWhoop5: activeWhoop5 && source == Self.whoopSource)) ?? []
            let window = Self.hrvRollingWindowSec(spanSeconds: to - from)
            // rollingRmssd and the map run OFF the main actor; only the Sendable `rr` rows cross in.
            return await Task.detached(priority: .utility) {
                HRVAnalyzer.rollingRmssd(rr: rr, windowSec: window, stepSec: max(1, window / 8))
                    .map { Self.timelinePoint($0.ts, $0.rmssd) }
            }.value
        case .spo2:
            // Two-channel (WHOOP): raw red/IR ratio proxy; single-channel (Oura): the reading itself. See `spo2TimelineValue(red:ir:)`.
            let s = (try? await store.spo2Samples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            // The up-to-200k-row conversion runs OFF the main actor.
            return await Task.detached(priority: .utility) {
                s.compactMap { row in
                    Self.spo2TimelineValue(red: row.red, ir: row.ir).map { Self.timelinePoint(row.ts, $0) }
                }
            }.value
        case .skinTemp:
            let s = (try? await store.skinTempSamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return await Task.detached(priority: .utility) {
                // Family-aware raw to C: 5/MG centidegrees (raw/100), 4.0 v24 raw ADC map.
                s.map { Self.timelinePoint($0.ts, skinTempCelsius(raw: $0.raw, family: family)) }
            }.value
        case .respiration:
            // Two quantities share this table: a WHOOP's raw respiration ADC waveform (verbatim) and an Oura
            // ring's per-window RATE in milli-bpm (0x6A), scaled back to breaths/min by `OuraRespScale`.
            let s = (try? await store.respSamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return await Task.detached(priority: .utility) {
                s.map { Self.timelinePoint($0.ts, OuraRespScale.displayValue(raw: $0.raw, deviceId: source)) }
            }.value
        case .motion:
            // Gravity magnitude as a coarse movement signal (1 g at rest).
            let s = (try? await store.gravitySamples(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            // The sqrt over up to 200k rows runs OFF the main actor.
            return await Task.detached(priority: .utility) {
                s.map { Self.timelinePoint($0.ts, ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot()) }
            }.value
        case .bandSleepState:
            // The strap's OWN band sleep_state (0 wake/1 still/2 asleep/3 up), plotted verbatim as a stepped
            // track. Empty when never reported (a WHOOP 4.0, or an unoffloaded window): never a fabricated line.
            let s = (try? await store.sleepStateSamples(deviceId: source, from: from, to: to)) ?? []
            return await Task.detached(priority: .utility) {
                s.map { Self.timelinePoint($0.ts, Double($0.state)) }
            }.value
        case .ouraMovement:
            // The ring's per-window motion from OURA_MOTION events (0x47): `motion_seconds` (0 still, up to 31 s
            // in the ~30 s window). An activity track, never scored, never steps; empty for WHOOP.
            let evs = (try? await store.events(deviceId: source, from: from, to: to, limit: 200_000)) ?? []
            return await Task.detached(priority: .utility) {
                evs.compactMap { e -> TrendPoint? in
                    guard e.kind == OuraStreamMapping.motionEventKind,
                          let ms = e.payload["motion_seconds"]?.intValue else { return nil }
                    return Self.timelinePoint(e.ts, Double(ms))
                }
            }.value
        }
    }

    /// Builds a `TrendPoint` from unix-seconds `ts` + value. `nonisolated static` so row conversions can run in `Task.detached`.
    nonisolated static func timelinePoint(_ ts: Int, _ v: Double) -> TrendPoint {
        TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(ts)), value: v)
    }

    /// Mean-bins a raw point series onto a `bucketSeconds` grid (floor(ts/bucket)*bucket), ascending;
    /// the in-process twin of `hrBuckets` for non-HR streams. Pure.
    nonisolated static func downsampleToBuckets(_ points: [TrendPoint], bucketSeconds: Int) -> [TrendPoint] {
        let bucket = max(1, bucketSeconds)
        guard !points.isEmpty else { return [] }
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for p in points {
            let key = (Int(p.date.timeIntervalSince1970) / bucket) * bucket
            let acc = sums[key] ?? (0, 0)
            sums[key] = (acc.sum + p.value, acc.n + 1)
        }
        return sums.keys.sorted().map { key in
            let acc = sums[key]!
            return TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(key)),
                              value: acc.sum / Double(acc.n))
        }
    }

    /// Pure off-main post-processing for the zoomed-in (raw) HR path: dedup ("first id wins per ts",
    /// active strap first in `unionIds`), sort ascending, map to `TrendPoint`. `nonisolated static`
    /// so it runs in a `Task.detached` and is unit-testable.
    nonisolated static func dedupSortRawHr(_ perId: [[HRSample]]) -> [TrendPoint] {
        var byTs: [Int: HRSample] = [:]
        for samples in perId {
            for s in samples where byTs[s.ts] == nil { byTs[s.ts] = s }
        }
        return byTs.values.sorted { $0.ts < $1.ts }.map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: Double($0.bpm))
        }
    }

    /// Pure off-main post-processing for the non-HR raw path: dedups by ts across the union (first id
    /// wins), sorts ascending, and returns raw points (`isRaw`) or mean-bins them onto the
    /// `bucketSeconds` grid. `nonisolated static` so it runs in a `Task.detached` and is unit-testable.
    nonisolated static func dedupSortDownsampleRaw(_ perId: [[TrendPoint]], isRaw: Bool,
                                                   bucketSeconds: Int) -> [TrendPoint] {
        var raw: [TrendPoint] = []
        var seenTs = Set<Int>()
        for points in perId {
            for p in points {
                let ts = Int(p.date.timeIntervalSince1970)
                if seenTs.insert(ts).inserted { raw.append(p) }
            }
        }
        raw.sort { $0.date < $1.date }
        if isRaw { return raw }
        return downsampleToBuckets(raw, bucketSeconds: bucketSeconds)
    }

    // MARK: - Cross-source resolver

    /// Product-facing daily series for a metric across every COMPATIBLE source, freshest-wins, for
    /// surfaces wanting the best available signal; use `series(key:source:)` where one source must be
    /// honoured verbatim. Precedence per `sourceCandidates`: imported WHOOP > Zoop-computed >
    /// declared-compatible Apple Health. `fullHistory` forces the full recordable epoch regardless of `days`.
    func resolvedSeries(key: String, source preferredSource: String, days: Int = 4000, fullHistory: Bool = false) async -> MetricSeriesResolution {
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))
        return await resolvedSeries(key: key, source: preferredSource, from: from, to: to)
    }

    /// Exact-window variant for a known historical day (e.g. Charge carry), with the same precedence.
    func resolvedSeries(
        key: String,
        source preferredSource: String,
        from: String,
        to: String
    ) async -> MetricSeriesResolution {
        let candidates = Self.sourceCandidates(forKey: key, preferredSource: preferredSource,
                                               actualWhoopSource: deviceId)
        guard let store = await ensureStore() else {
            return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: [])
        }

        // First candidate wins per day; later candidates only fill days no earlier one covered.
        var byDay: [String: ResolvedMetricPoint] = [:]
        for candidate in candidates {
            let rows = await resolvedRows(store: store, candidate: candidate, from: from, to: to)
            for row in rows where byDay[row.day] == nil {
                byDay[row.day] = ResolvedMetricPoint(day: row.day, value: row.value,
                                                     source: candidate.source, sourceKey: candidate.key)
            }
        }
        let points = byDay.values.sorted { $0.day < $1.day }
        return MetricSeriesResolution(requestedSource: preferredSource, candidates: candidates, points: points)
    }

    /// Resolves a displayed score back to the provider that supplied its inputs. Direct imported points
    /// name it; a `-zoop` point is looked up in the metric-level provenance cache, and missing legacy
    /// metadata returns nil rather than falsely claiming its parent device.
    func scoreInputProvider(
        resolvedSource: String,
        day: String,
        metricKey: String
    ) async -> ScoreInputProvider? {
        guard let store = await ensureStore() else { return nil }
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let sourceId: String
        if resolvedSource.hasSuffix("-zoop") {
            guard let cached = try? await store.scoreInputSource(
                deviceId: resolvedSource,
                day: day,
                key: metricKey
            ) else { return nil }
            sourceId = cached
        } else {
            sourceId = resolvedSource
        }
        let brand = (try? registry.all())?.first(where: { $0.id == sourceId })?.brand
        return ScoreInputProvider(sourceId: sourceId, brand: brand)
    }

    /// Raw specialized provenance tag for a computed metric point (not a device id; `vo2max_est` uses
    /// it for its `nes` / `uth` estimator id). Missing metadata is legacy-unknown, never reconstructed.
    func scoreProvenanceTag(resolvedSource: String, day: String, metricKey: String) async -> String? {
        guard resolvedSource.hasSuffix("-zoop"), let store = await ensureStore() else { return nil }
        return try? await store.scoreInputSource(deviceId: resolvedSource, day: day, key: metricKey)
    }

    /// Reads one candidate's rows for the window: its metricSeries, plus the matching DailyMetric column
    /// for days the series lacks (a Bluetooth-only WHOOP 5 user has daily columns only). Ascending by
    /// day. The daily read has a +1-day upper buffer (`Self.dayAfter(to)`) because a night is keyed on
    /// its LOCAL WAKE day, which can sort after the caller's `to`; without it Today fell back to the
    /// latest historical Rest. The buffer only widens the read; metricSeries-first precedence is unchanged.
    private func resolvedRows(store: WhoopStore, candidate: MetricSourceCandidate,
                             from: String, to: String) async -> [(day: String, value: Double)] {
        let metricRows = (try? await store.metricSeries(deviceId: candidate.source, key: candidate.key,
                                                        from: from, to: to)) ?? []
        var byDay = Dictionary(metricRows.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        if let dailyRows = try? await store.dailyMetrics(deviceId: candidate.source,
                                                         from: from, to: Self.dayAfter(to)) {
            for row in dailyRows where byDay[row.day] == nil {
                if let value = Self.dailyColumn(key: candidate.key, day: row) { byDay[row.day] = value }
            }
        }
        return byDay.keys.sorted().compactMap { day in byDay[day].map { (day, $0) } }
    }

    /// The candidate (source, key) pairs for `key` in precedence order, given `preferredSource`. The
    /// strap's real id is `actualWhoopSource` (`deviceId`), its computed sibling `+ "-zoop"`.
    ///  - strap-preferred: [imported strap, computed strap, compatible Apple] (Apple only for vitals
    ///    with a declared 1:1 mapping);
    ///  - Apple-preferred: [Apple] (+ computed strap ONLY for steps/active_kcal);
    ///  - any other source: itself only (nutrition/mood are single-source).
    static func sourceCandidates(forKey key: String, preferredSource: String,
                                 actualWhoopSource: String) -> [MetricSourceCandidate] {
        let computedSource = actualWhoopSource + "-zoop"
        func uniqued(_ cs: [MetricSourceCandidate]) -> [MetricSourceCandidate] {
            var seen = Set<MetricSourceCandidate>(); var out: [MetricSourceCandidate] = []
            for c in cs where !seen.contains(c) { seen.insert(c); out.append(c) }
            return out
        }

        if preferredSource == whoopSource || preferredSource == actualWhoopSource {
            // Active strap first (live wins per day), then the CANONICAL "my-whoop" import, THEN the computed
            // siblings, so pre-re-add history still resolves and imports outrank computed estimates
            // (`imported WHOOP > Zoop-computed`). `uniqued` collapses to one pair per source on a single-device
            // install. Apple is the final fallback.
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: whoopSource, key: key),
                MetricSourceCandidate(source: computedSource, key: key),
                MetricSourceCandidate(source: whoopSource + "-zoop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: appleHealthSource, key: appleKey))
            }
            return uniqued(candidates)
        }
        if preferredSource == appleHealthSource {
            var candidates = [MetricSourceCandidate(source: appleHealthSource, key: key)]
            // Health Connect is an Apple-equivalent body-metric source (Android only; a no-op on iOS/Mac). Kept
            // so the resolver matches Android's. A real Apple export still wins per day.
            candidates.append(MetricSourceCandidate(source: healthConnectSource, key: key))
            if zoopComputedCanFillAppleMetric(key) {
                candidates.append(MetricSourceCandidate(source: computedSource, key: key))
            }
            return uniqued(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    /// The Apple-Health series key carrying the SAME quantity as a WHOOP key, for declared-compatible
    /// vitals only; nil means no Apple equivalent.
    static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":              return "resting_hr"
        case "hrv", "spo2", "resp_rate", "avg_hr", "max_hr", "in_bed_min", "active_kcal":
            return key
        case "sleep_total_min":  return "asleep_min"
        case "sleep_deep_min":   return "deep_min"
        case "sleep_rem_min":    return "rem_min"
        case "sleep_light_min":  return "core_min"
        default:                 return nil
        }
    }

    /// Whether the Zoop-computed strap source may fill an Apple-preferred metric: only the daily totals
    /// the strap estimates (steps, calories), never a derived WHOOP score.
    private static func zoopComputedCanFillAppleMetric(_ key: String) -> Bool {
        switch key {
        case "steps", "active_kcal": return true
        default:                     return false
        }
    }

    /// The Explore read path. Like `series(key:source:)` but, for the strap source ("my-whoop"), falls
    /// back to the on-device COMPUTED dailies a Bluetooth-only WHOOP 5 user has. Three layers,
    /// imported-wins per day:
    ///  1. the imported metricSeries under `deviceId`;
    ///  2. the COMPUTED metricSeries under `computedDeviceId` (keys absent from DailyMetric columns, e.g. `sleep_performance`);
    ///  3. the merged daily metrics (`self.days`) for keys with a DailyMetric column.
    /// Any OTHER source reads only its own series. `fullHistory` forces the full recordable epoch
    /// regardless of `days` and is forwarded to the non-strap `series(...)` delegation.
    func exploreSeries(key: String, source: String, days: Int = 4000, fullHistory: Bool = false) async -> [(day: String, value: Double)] {
        guard source == "my-whoop" else {
            return Self.oneSkinTempScale(key: key, await series(key: key, source: source, days: days, fullHistory: fullHistory))
        }
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = fullHistory ? "0000-01-01" : Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = fullHistory ? "9999-12-31" : Self.dayString(now.addingTimeInterval(86_400))

        // day to value, lowest-priority source first; higher priority overwrites per day (imports win).
        var byDay: [String: Double] = [:]

        // Layer 3 (lowest): merged daily column (`self.days` is the imported + computed cache; `days` is the lookback).
        for d in self.days where byDay[d.day] == nil {
            if let v = Self.dailyColumn(key: key, day: d) { byDay[d.day] = v }
        }
        // Layer 2: computed metricSeries (covers sleep_performance). UNION active + canonical computed
        // siblings (canonical first so the active strap's value wins per day).
        for id in computedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }
        // Layer 1 (highest): imported metricSeries, UNION active strap + canonical (canonical first).
        for id in importedReadIds.reversed() {
            for p in (try? await store.metricSeries(deviceId: id, key: key, from: from, to: to)) ?? [] { byDay[p.day] = p.value }
        }

        return Self.oneSkinTempScale(key: key, byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) })
    }

    /// Reduces a `skin_temp` window to a single scale; other keys pass through. The key is bimodal (CSV
    /// import writes ABSOLUTE C, computed layers write a baseline DEVIATION), and mixing them breaks
    /// aggregates, deltas and the correlation scan. Applied on BOTH of `exploreSeries`' return paths so
    /// the guard doesn't depend on a fact in another file. `series(day:value:)` is ascending by day,
    /// which `dominantKind` relies on.
    private static func oneSkinTempScale(
        key: String,
        _ series: [(day: String, value: Double)]
    ) -> [(day: String, value: Double)] {
        guard key == "skin_temp",
              let keep = SkinTempDisplay.dominantKind(valuesAscendingByDay: series.map(\.value))
        else { return series }
        return series.filter { SkinTempDisplay.kind(of: $0.value) == keep }
    }

    /// Every catalog metric's Explore series at once, memoized: the cross-catalog scan behind the
    /// Explorer's correlation card, shared so browsing N metric details doesn't pay the scan N times.
    /// Keyed on `deviceId` AND `refreshSeq` (the read-id sets derive from the active strap and the only
    /// `refreshSeq` bump is in `refresh()`). Returns `nil` if cancelled, and a cancelled scan is NOT
    /// cached. DEFAULT WINDOW ONLY: the key doesn't record `days`/`fullHistory`, so callers needing
    /// another window must call `exploreSeries` directly.
    func exploreAllSeries() async -> [String: [(day: String, value: Double)]]? {
        let key = "\(deviceId)|\(refreshSeq)"
        if let cached = exploreAllCache, cached.key == key { return cached.byMetricID }
        var byMetricID: [String: [(day: String, value: Double)]] = [:]
        for descriptor in MetricCatalog.all {
            if Task.isCancelled { return nil }
            byMetricID[descriptor.id] = await exploreSeries(key: descriptor.key, source: descriptor.source)
        }
        exploreAllCache = (key, byMetricID)
        return byMetricID
    }

    /// Backing store for `exploreAllSeries`; main-actor isolated, so no locking.
    private var exploreAllCache: (key: String, byMetricID: [String: [(day: String, value: Double)]])?

    /// The merged DailyMetric column backing an Explore metric key, for days the metricSeries doesn't
    /// cover (strap-only WHOOP 5 users). Also handles the Apple-compatible sleep aliases (asleep_min /
    /// deep_min / rem_min / core_min). Keys with no daily column (avg_hr / max_hr ...) return nil.
    /// `sleep_performance` (Rest composite, 0-100) is not a stored column: when the night's totals are
    /// banked on the DailyMetric row before the metricSeries point exists, it is derived on the fly via
    /// `AnalyticsEngine.Rest.composite(daily:)` (consistency left to the scorer's neutral default), so
    /// the day resolves to its own Rest instead of a borrowed historical one. Internal + nonisolated
    /// so `EditMergePrecedenceTests` can exercise it off the main actor.
    nonisolated static func dailyColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery":         return d.recovery
        case "hrv":              return d.avgHrv
        case "rhr", "resting_hr": return d.restingHr.map(Double.init)
        case "strain":           return d.strain
        case "resp_rate":        return d.respRateBpm
        case "spo2":             return d.spo2Pct
        case "skin_temp":        return d.skinTempDevC
        case "sleep_total_min", "asleep_min": return d.totalSleepMin
        case "sleep_efficiency": return d.efficiency
        case "sleep_deep_min", "deep_min": return d.deepMin
        case "sleep_rem_min", "rem_min":   return d.remMin
        case "sleep_light_min", "core_min": return d.lightMin
        case "sleep_performance": return AnalyticsEngine.Rest.composite(daily: d)
        case "steps":            return d.steps.map(Double.init)
        case "active_kcal", "energy_kcal": return d.activeKcalEst
        default:                 return nil
        }
    }

    /// Which of `catalog`'s metrics hold at least one reading, for the Explore list's "no data" dot.
    /// One DISTINCT-key query per source plus one in-memory pass for the daily-column layer, rather than
    /// a full series read per metric. Source precedence MIRRORS `exploreSeries`: the WHOOP source unions
    /// imported AND computed read ids, the daily-column fallback is WHOOP-only, other sources read their
    /// own keys. `metricKeys` has no day window, so very old data counts as "has data" (this can only
    /// remove a dot). A store that won't open returns every id, since a dot on every row would read as data loss.
    func nonEmptyMetricIDs(_ catalog: [MetricDescriptor]) async -> Set<String> {
        guard let store = await ensureStore() else { return Set(catalog.map(\.id)) }

        // One DISTINCT-key query per distinct source (the WHOOP one fans out over its read ids).
        var keysBySource: [String: Set<String>] = [:]
        for source in Set(catalog.map(\.source)) {
            var keys = Set<String>()
            if source == canonicalDeviceId {
                for id in importedReadIds + computedReadIds {
                    keys.formUnion((try? await store.metricKeys(deviceId: id)) ?? [])
                }
            } else {
                keys.formUnion((try? await store.metricKeys(deviceId: source)) ?? [])
            }
            keysBySource[source] = keys
        }

        // The merged daily column layer is handled by the pure half below, in memory over the published `days`.
        return Self.nonEmptyMetricIDs(catalog, keysBySource: keysBySource, days: days,
                                      whoopSource: canonicalDeviceId)
    }

    /// The decision itself, split from the queries so it is testable: given the keys each source holds
    /// and the merged daily rows, which catalog ids have data.
    nonisolated static func nonEmptyMetricIDs(_ catalog: [MetricDescriptor],
                                              keysBySource: [String: Set<String>],
                                              days: [DailyMetric],
                                              whoopSource: String = Repository.whoopSource) -> Set<String> {
        Set(catalog.lazy.filter { metric in
            if keysBySource[metric.source]?.contains(metric.key) == true { return true }
            // The daily-column fallback is WHOOP-only, as `exploreSeries` gates it.
            guard metric.source == whoopSource else { return false }
            return days.contains { dailyColumn(key: metric.key, day: $0) != nil }
        }.map(\.id))
    }

    /// Native journal answers live under this dedicated source id. The journal table has no `source`
    /// column (PK is (deviceId, day, question)), so writing under the imported `deviceId` would let a
    /// CSV re-import overwrite them; a separate id keeps the streams independent.
    static let journalDeviceId = "noop-journal"

    /// Logged behaviours (imported WHOOP journal plus native journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        var imported: [JournalEntry] = []
        for id in importedReadIds { imported += (try? await store.journalEntries(deviceId: id, from: from, to: to)) ?? [] }
        let native = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                      from: from, to: to)) ?? []
        return Self.mergeJournal(imported: imported, native: native)
    }

    /// Imported journal rows only (so the logging card can adopt the export's exact question strings).
    func importedJournalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        var rows: [JournalEntry] = []
        for id in importedReadIds { rows += (try? await store.journalEntries(deviceId: id, from: from, to: to)) ?? [] }
        return rows
    }

    /// One day's native answers (question to answeredYes) for the logging card; a targeted read, as the
    /// merged list carries no deviceId.
    func nativeJournalAnswers(day: String) async -> [String: Bool] {
        guard let store = await ensureStore() else { return [:] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: day, to: day)) ?? []
        return Dictionary(rows.map { ($0.question, $0.answeredYes) },
                          uniquingKeysWith: { _, last in last })
    }

    /// One day's native numeric values (question to value); plain yes/no answers are absent.
    func nativeJournalNumeric(day: String) async -> [String: Double] {
        guard let store = await ensureStore() else { return [:] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: day, to: day)) ?? []
        var out: [String: Double] = [:]
        for r in rows { if let v = r.numericValue { out[r.question] = v } }
        return out
    }

    /// Distinct local-day keys (yyyy-MM-dd) in `[from, to]` with at least one NATIVE journal entry
    /// (the native journal device id only). Backs the Today journal widget's completion strip. Read-only.
    func nativeJournalDays(from: String, to: String) async -> Set<String> {
        guard let store = await ensureStore() else { return [] }
        let rows = (try? await store.journalEntries(deviceId: Self.journalDeviceId,
                                                    from: from, to: to)) ?? []
        return Set(rows.map { $0.day })
    }

    /// Union; the NATIVE row wins per (day, question), being the user's most recent explicit action.
    nonisolated static func mergeJournal(imported: [JournalEntry], native: [JournalEntry]) -> [JournalEntry] {
        var byKey: [String: JournalEntry] = [:]
        for e in imported { byKey[e.day + "\u{1F}" + e.question] = e }
        for e in native { byKey[e.day + "\u{1F}" + e.question] = e }
        return byKey.values.sorted { ($0.day, $0.question) < ($1.day, $1.question) }
    }

    /// Writes one native answer (day per the importer's wake-day convention).
    func saveJournalAnswer(day: String, question: String, answeredYes: Bool, notes: String? = nil) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.upsertJournal(
            [JournalEntry(day: day, question: question, answeredYes: answeredYes, notes: notes)],
            deviceId: Self.journalDeviceId)
    }

    /// Writes one native NUMERIC answer: stores the value AND answeredYes=true so BehaviorInsights
    /// treats a numeric log as "behaviour occurred" while carrying the value for dose-response.
    func saveJournalNumeric(day: String, question: String, value: Double, notes: String? = nil) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.upsertJournal(
            [JournalEntry(day: day, question: question, answeredYes: true, notes: notes,
                          numericValue: value)],
            deviceId: Self.journalDeviceId)
    }

    /// Clears one native answer (scoped to the dedicated source id; never touches imported rows).
    func clearJournalAnswer(day: String, question: String) async {
        guard let store = await ensureStore() else { return }
        _ = try? await store.deleteJournal(deviceId: Self.journalDeviceId, day: day, question: question)
    }

    /// All workouts (WHOOP + Apple Health + manual + grandfathered detected bouts), newest first. Legacy
    /// detected bouts stay surfaced with a "Detected" badge, editable, dismissible and exportable; new
    /// scoring passes neither create nor reconcile them. Dismissed spans are filtered HERE so every
    /// consumer honours prior "not a workout" decisions.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        // UNION every registered WHOOP + canonical (and computed siblings). De-dup identical same-source
        // rows present under two union ids by natural key (cross-SOURCE dedup below only collapses
        // strap-vs-Apple twins).
        var rows: [WorkoutRow] = []
        // Every namespace in one list, shared with `deleteWorkout` so they can't disagree about where a row
        // lives: each raw id, its computed `-zoop` sibling, Apple Health, imported lifting sessions (Hevy /
        // Liftosaur) and imported activity FILES (FIT / GPX / TCX). HR is reconciled from the strap trace at the end.
        for id in Self.workoutNamespaces(rawIds: rawPhysiologyReadIds(store: store)) {
            rows += (try? await store.workouts(deviceId: id, from: lo, to: hi, limit: 5000)) ?? []
        }
        rows = Self.dedupWorkoutsByNaturalKey(rows)
        let spans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        // Collapse the SAME activity tracked live under the strap AND imported from Health Connect / Apple
        // Health into one entry. Runs on the dismissed-filtered set, before the final newest-first sort.
        let filtered = rows.filter { !WorkoutSource.isDismissed($0, spans: spans) }
        // Workouts & GPS test mode: run the dedup twin, which returns the byte-identical kept list plus a
        // `.workouts` trace line per collapsed pair. Zero-cost when off.
        let deduped: [WorkoutRow]
        if TestCentre.active(.workouts), workoutsLog != nil {
            let (kept, trace) = WorkoutSource.dedupCrossSourceTrace(filtered)
            for line in trace { emitWorkouts(line) }
            deduped = kept
        } else {
            deduped = WorkoutSource.dedupCrossSource(filtered)
        }
        let visible = deduped.sorted { $0.startTs > $1.startTs }
        return await reconcileWorkoutHrWithTrace(visible, store: store)
    }

    /// DISPLAY-ONLY: reconciles each workout's shown Avg/Max HR with the strap trace that drives its
    /// graph / zones / effort, since a hand-edited stored Avg diverges from it.
    ///  - STRAP-NATIVE rows (`manual` / detected `<id>-zoop`) always get Avg HR recomputed as the mean
    ///    of the trace samples (Max as the peak).
    ///  - IMPORTED rows (Apple Health / Health Connect / Whoop CSV) are only FILLED when nil (and the
    ///    strap was worn), never overriding a real imported value.
    /// Requires `minSamples` (~1 min) so stray samples can't fabricate an average, and caps per-row HR
    /// reads. NEVER persisted: a read-time projection, recomputed on every load.
    private func reconcileWorkoutHrWithTrace(_ rows: [WorkoutRow], store: WhoopStore,
                                             minSamples: Int = 60, cap: Int = 300) async -> [WorkoutRow] {
        // Eligibility and the `cap` budget are resolved FIRST in row order, then the eligible rows' reads
        // run with BOUNDED concurrency (chunks of `readChunk`) so the single-connection store isn't swamped.
        // The mean/peak is a SQLite aggregate (`store.hrWindowStats`), so the common path materialises no
        // rows; rows are read only for a strain fill.
        let readChunk = 8

        // Phase 1: resolve eligibility and spend the `cap` budget in ORIGINAL row order; only these indices
        // get a trace read. (Strap-native is recomputed in Phase 3 from the same `classify`.)
        var budget = cap
        var eligibleIndices: [Int] = []
        for (i, row) in rows.enumerated() {
            let cls = WorkoutSource.classify(row.source)
            let strapNative = cls == .manual || cls == .detected
            // A strap-native row whose Effort (strain) is nil is also eligible even with an avgHr present, so
            // it gets its Effort backfilled once the trace covers the window. Needs the injected profile.
            let needsStrainFill = strapNative && row.strain == nil && strainProfile != nil
            guard row.endTs > row.startTs, budget > 0,
                  strapNative || row.avgHr == nil || needsStrainFill else { continue }
            budget -= 1
            eligibleIndices.append(i)
        }

        // Phase 2: read each eligible window with BOUNDED concurrency and reduce OFF the main actor,
        // returning only PLAIN Ints (index, avg, peak); the `WorkoutRow` is rebuilt on the main actor in
        // Phase 3. The samples are the ones the graph + zones + effort use. Keyed by row index to keep
        // order. The injected profile is captured ONCE (Sendable scalars); nil means no strain fill.
        let strainProfile = self.strainProfile
        var reduced: [Int: (avg: Int, peak: Int, strain: Double?)] = [:]
        for chunkStart in stride(from: 0, to: eligibleIndices.count, by: readChunk) {
            let chunk = eligibleIndices[chunkStart..<min(chunkStart + readChunk, eligibleIndices.count)]
            await withTaskGroup(of: (index: Int, avg: Int, peak: Int, strain: Double?)?.self) { group in
                for idx in chunk {
                    let startTs = rows[idx].startTs
                    let endTs = rows[idx].endTs
                    // Only strap-native rows still missing a strain get one computed; others return nil for the slot.
                    // Resolved on the main actor (WorkoutSource.classify) so the child task crosses only Sendable scalars.
                    let cls = WorkoutSource.classify(rows[idx].source)
                    let wantStrain = (cls == .manual || cls == .detected) && rows[idx].strain == nil
                    // Read HR under the workout's OWN recording strap: a detected row's `source` IS its computed strap
                    // id ("<base>-zoop"), so a bout on a 2nd WHOOP reads "<base>", not the active strap's empty window.
                    let hrIds = Self.workoutHrDeviceIds(source: rows[idx].source, activeStrapId: deviceId,
                                                        importedIds: importedReadIds)
                    group.addTask { [hrIds] in
                        // Aggregate in SQLite over the WHOLE window: a capped 8000-row read made a workout longer than
                        // ~2h13m at 1 Hz report the mean of its first 8000 samples. The common path (no strain fill) also reads no rows.
                        guard let stats = try? await store.hrWindowStats(
                                  primaryId: hrIds[0],
                                  secondaryId: hrIds.count > 1 ? hrIds[1] : hrIds[0],
                                  from: startTs, to: endTs),
                              stats.n >= minSamples,
                              let mean = stats.avg, let peak = stats.max else { return nil }
                        let avg = Int(mean.rounded())
                        // Recompute Effort from the SAME samples the graph/zones use, with the app's StrainScorer and the
                        // injected HRmax + sex (matching endWorkout's score); nil on a too-thin window. Reads rows because
                        // StrainScorer needs the series; the 8000 cap bounds the strain window, not the average.
                        let strain: Double?
                        if wantStrain, let p = strainProfile {
                            let samples = (try? await store.hrSamples(deviceId: hrIds[0],
                                                                      from: startTs, to: endTs,
                                                                      limit: 8000)) ?? []
                            strain = StrainScorer.strain(samples, maxHR: p.hrMax,
                                                method: PuffinExperiment.effortMethod, sex: p.sex)
                        } else {
                            strain = nil
                        }
                        return (index: idx, avg: avg, peak: peak, strain: strain)
                    }
                }
                for await result in group {
                    if let r = result { reduced[r.index] = (avg: r.avg, peak: r.peak, strain: r.strain) }
                }
            }
        }

        // Phase 3: reassemble in ORIGINAL order. A cleared eligible row applies the reduction (strap-native:
        // override avg + max; imported: fill avg, keep imported max); every other row passes through verbatim.
        return zip(rows.indices, rows).map { i, row in
            guard let r = reduced[i] else { return row }
            let cls = WorkoutSource.classify(row.source)
            let strapNative = cls == .manual || cls == .detected
            let newMax = strapNative ? r.peak : (row.maxHr ?? r.peak)
            // FILL a nil Effort from the recomputed strain, never overriding a stored one. Display-only: the
            // durable value is persisted by the backend rescore on the next analyze tick.
            let newStrain = row.strain ?? r.strain
            return WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                              source: row.source, durationS: row.durationS, energyKcal: row.energyKcal,
                              avgHr: r.avg, maxHr: newMax, strain: newStrain, distanceM: row.distanceM,
                              zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps)
        }
    }

    /// The device ids whose `hrSample` rows back a workout's chart, zones, Avg HR and Effort reconcile,
    /// in read precedence. A DETECTED row returns exactly ONE id: its `source` is the computed strap id
    /// ("<base>-zoop"), so the suffix is stripped to read the strap that recorded the bout (unioning
    /// would mix in a strap that never recorded it). MANUAL / IMPORTED rows carry no strap, so they
    /// reconcile against the worn strap via the read-spine union, active first. At most two ids; a
    /// single-WHOOP install collapses to one.
    nonisolated static func workoutHrDeviceIds(source: String, activeStrapId: String,
                                               importedIds: [String]) -> [String] {
        guard WorkoutSource.classify(source) == .detected else { return importedIds }
        return [source.hasSuffix("-zoop") ? String(source.dropLast(5)) : source]
    }

    // MARK: - Workout editing (manual add/edit, relabel, dismiss, delete)
    //
    // Manual workouts live under the strap source (deviceId == `deviceId`, source "manual"), where
    // AppModel.endWorkout also lands live sessions. Legacy detected bouts live under `computedDeviceId`
    // with sport "detected"; new scoring passes preserve those rows and the dismissal list keeps prior intent.

    /// The persisted legacy detected spans ("startTs:endTs"), read off UserDefaults so the read filter,
    /// mutators and candidate selector share one source of truth.
    private var dismissedDetectedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: WorkoutSource.dismissedDefaultsKey) }
    }

    /// Persists a retroactive / edited manual workout under the strap source. `replacing` is the row the
    /// edit started from:
    ///  - a grandfathered DETECTED bout: save this manual row first, then retire the original while
    ///    retaining its legacy dismissal marker;
    ///  - a MANUAL row whose natural key (startTs/sport) changed: save the replacement, then retire the
    ///    stale row (a failed write preserves the original);
    ///  - an IMPORTED row is never passed here as `replacing`; its history is never touched.
    func saveManualWorkout(_ row: WorkoutRow, replacing old: WorkoutRow? = nil) async {
        guard let store = await ensureStore() else { return }
        if let old, WorkoutSource.classify(old.source) == .detected {
            // Write the replacement first: a failed insert must leave the original and its visibility untouched.
            do { _ = try await store.upsertWorkouts([row], deviceId: deviceId) }
            catch { return }
            await dismissDetected(old)
            return
        } else if let old, old.startTs != row.startTs || old.sport != row.sport {
            // Write the replacement before deleting anything; if the later delete fails, the result is two rows rather than lost history.
            do { _ = try await store.upsertWorkouts([row], deviceId: deviceId) }
            catch { return }
            // The GPS route lives in RouteStore keyed by natural key (startTs + sport), not in the DB row. Copy
            // it only after the replacement is durable, and keep the old copy until the old row is retired.
            // Load WITH points: a plain load returns a drawable route only and would drop measurements.
            let oldRoute = RouteStore.loadWithPoints(startTs: old.startTs, sport: old.sport)
            if let route = oldRoute {
                RouteStore.store(route, startTs: row.startTs, sport: row.sport)
            }
            do {
                _ = try await store.deleteWorkouts(deviceId: deviceId, sport: old.sport,
                                                   from: old.startTs, to: old.startTs)
                if oldRoute != nil {
                    RouteStore.remove(startTs: old.startTs, sport: old.sport)
                }
            } catch {
                // Replacement and both route keys remain available; retrying the edit is safe.
            }
            return
        }
        _ = try? await store.upsertWorkouts([row], deviceId: deviceId)
    }

    /// Re-labels a legacy detected bout: copies it to a manual strap row with the chosen sport, then
    /// deletes the detected original. The detector may still enrich this row but no longer recreates a twin.
    func relabelDetected(_ row: WorkoutRow, sport: String) async {
        guard let store = await ensureStore() else { return }
        guard WorkoutSource.classify(row.source) == .detected else { return }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let manual = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: trimmed, source: "manual",
                                durationS: row.durationS, energyKcal: row.energyKcal,
                                avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain,
                                distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes,
                                steps: row.steps)
        do { _ = try await store.upsertWorkouts([manual], deviceId: deviceId) }
        catch { return }
        // Retire through the shared path so the legacy marker prevents resurrection if deletion fails.
        await dismissDetected(row)
    }

    /// Dismisses a grandfathered DETECTED bout the user says isn't a workout: records its span for
    /// suggestion suppression, then deletes the current row. Idempotent.
    func dismissDetected(_ row: WorkoutRow) async {
        guard WorkoutSource.classify(row.source) == .detected else { return }
        let token = WorkoutSource.dismissedToken(for: row)
        var spans = dismissedDetectedSpans
        if !spans.contains(token) { spans.append(token); dismissedDetectedSpans = spans }
        guard let store = await ensureStore() else { return }
        // The displayed history spans current and archived computed ids; `source` is the owning id, the only safe delete target.
        _ = try? await store.deleteWorkouts(deviceId: row.source, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    /// Deletes ONE workout by natural key. A detected row carries its computed owner in `source` and also
    /// gets a durable dismissal marker; everything else deletable (manual) lives under the active strap id.
    func deleteWorkout(_ row: WorkoutRow) async {
        if WorkoutSource.classify(row.source) == .detected { await dismissDetected(row); return }
        guard let store = await ensureStore() else { return }
        // Sweep every STRAP namespace, not just the active one, or a manual row banked under a retained
        // strap or computed sibling would reappear on reload. Import namespaces are excluded (see
        // `deletableWorkoutNamespaces`). The natural key is exact (`sport` plus `startTs`), so only the
        // tapped row and its strap-namespace copies go; overlapping sessions are the display dedup's job.
        for id in Self.deletableWorkoutNamespaces(rawIds: rawPhysiologyReadIds(store: store)) {
            _ = try? await store.deleteWorkouts(deviceId: id, sport: row.sport,
                                                from: row.startTs, to: row.startTs)
        }
    }

    /// Merges overlapping / adjacent MANUAL or DETECTED sessions into ONE manual session (`merged`, from
    /// `WorkoutMerge.merge`), then retires the originals. Imported history is never passed here (the
    /// caller gates on `WorkoutMerge.canMerge`). Sequence:
    ///   1. re-key at most one GPS route (the longest) onto the merged natural key, dropping the others;
    ///   2. save the merged row under the strap id;
    ///   3. per original: retire a DETECTED bout with its dismissal marker, delete a MANUAL row by natural
    ///      key, but never touch a source equal to the merged row's own natural key.
    /// The caller runs `analyzeRecent` (rescores the merged strain from strap HR) and reloads.
    func mergeWorkouts(_ rows: [WorkoutRow], into merged: WorkoutRow) async {
        guard rows.count >= 2 else { return }
        // Pick the richest route (longest polyline) BEFORE deleting the originals; the DB write doesn't move routes.
        var bestRoute: (route: WorkoutRoute, startTs: Int, sport: String)?
        for r in rows {
            // Load WITH points: the winner is re-stored under the merged key, so dropping measurements would lose them.
            guard let route = RouteStore.loadWithPoints(startTs: r.startTs, sport: r.sport) else { continue }
            if bestRoute == nil || route.polyline.count > bestRoute!.route.polyline.count {
                bestRoute = (route, r.startTs, r.sport)
            }
        }

        // Save the merged row before retiring any original. `saveManualWorkout` swallows failures for UI
        // callers, but this destructive follow-up must know the insert succeeded.
        guard let store = await ensureStore() else { return }
        do { _ = try await store.upsertWorkouts([merged], deviceId: deviceId) }
        catch { return }

        // Retire each original, skipping any whose natural key matches the merged row's.
        for r in rows where !(r.startTs == merged.startTs && r.sport == merged.sport) {
            switch WorkoutSource.classify(r.source) {
            case .detected: await dismissDetected(r)
            case .manual:   await deleteWorkout(r)
            case .whoop, .apple, .lifting, .activityFile:
                // Defensive: canMerge already excludes imported rows; never rewrite imported history.
                continue
            }
            // Drop each original's route unless it's the one re-kept onto the merged key.
            if !(bestRoute?.startTs == r.startTs && bestRoute?.sport == r.sport) {
                RouteStore.remove(startTs: r.startTs, sport: r.sport)
            }
        }

        // Move the kept route onto the merged natural key, then drop it from the old key.
        if let best = bestRoute, !(best.startTs == merged.startTs && best.sport == merged.sport) {
            RouteStore.store(best.route, startTs: merged.startTs, sport: merged.sport)
            RouteStore.remove(startTs: best.startTs, sport: best.sport)
        }
    }

    /// Bulk-deletes the selected sessions, routed per class as the single-row path does (detected:
    /// durable dismiss; manual: delete). Imported rows are never selectable. The caller reloads.
    func bulkDeleteWorkouts(_ rows: [WorkoutRow]) async {
        for r in rows {
            switch WorkoutSource.classify(r.source) {
            case .detected: await dismissDetected(r)
            case .manual:   await deleteWorkout(r)
            case .whoop, .apple, .lifting, .activityFile: continue
            }
        }
    }

    // MARK: - Auto-detect workouts (opt-in "Looks like a workout?" Today prompt)
    //
    // The only path that can create a NEW visible suggested workout, and it saves nothing until the user
    // taps Save. The analytics detector stays internal for daily scoring and no longer persists generic
    // `sport="detected"` rows; both historical dismissal stores are honoured so no bout is resurrected.

    /// Dismissed AUTO-DETECT spans ("startSec:endSec"). The key stays distinct for backup compatibility;
    /// selection also honours the legacy `dismissedDetected` intervals.
    private static let autoDetectDismissedKey = "workouts.autoDetectDismissed"
    private var autoDetectDismissedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.autoDetectDismissedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoDetectDismissedKey) }
    }

    /// Token for one auto-detect span (matches the detector's integer seconds).
    nonisolated private static func autoDetectToken(_ w: DetectedWorkout) -> String {
        "\(w.startSec):\(w.endSec)"
    }

    /// Selects the newest published suggestion after applying BOTH dismissal contracts: exact span tokens
    /// (suggestion detector) and half-open overlap tombstones (engine rows, whose boundary a re-score can shift).
    nonisolated static func selectAutoDetectCandidate(
        _ candidates: [DetectedWorkout],
        autoDismissedTokens: [String],
        detectedDismissedTokens: [String]
    ) -> DetectedWorkout? {
        let exact = Set(autoDismissedTokens)
        // A dismissed window also suppresses a re-run whose edges moved a little.
        let autoSpans: [(start: Int, end: Int)] = autoDismissedTokens.compactMap { token in
            let parts = token.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let legacy = WorkoutSource.parseDismissedSpans(detectedDismissedTokens)
        return candidates
            .filter { candidate in
                !exact.contains(autoDetectToken(candidate))
                    && !autoSpans.contains { candidate.startSec <= $0.end && $0.start <= candidate.endSec }
                    && !legacy.contains { span in
                        candidate.startSec < span.end && span.start < candidate.endSec
                    }
            }
            .max(by: { $0.startSec < $1.startSec })
    }

    /// Hard cap on the dismissed-span list (200 most recent by span END), a backstop beyond what
    /// detection's ~2-day window can re-surface; the age prune normally keeps it shorter.
    private static let autoDetectDismissedMax = 200
    /// Spans whose END is older than this many seconds (30 days) can never be re-suggested, so they are dropped.
    private static let autoDetectDismissedMaxAgeSec = 30 * 86_400

    /// Parses the END time (seconds) out of a "startSec:endSec" token; nil if malformed.
    private func autoDetectTokenEnd(_ token: String) -> Int? {
        guard let colon = token.lastIndex(of: ":") else { return nil }
        return Int(token[token.index(after: colon)...])
    }

    /// Prunes the dismissed-span list: drops spans ending over ~30 days ago, then hard-caps to the
    /// `autoDetectDismissedMax` most recent (by END). Malformed tokens are kept (as newest) so a parse miss loses nothing.
    private func prunedAutoDetectSpans(_ spans: [String], now: Int) -> [String] {
        let cutoff = now - Self.autoDetectDismissedMaxAgeSec
        // Drop aged-out spans; an unparseable token survives.
        let fresh = spans.filter { token in
            guard let end = autoDetectTokenEnd(token) else { return true }
            return end >= cutoff
        }
        guard fresh.count > Self.autoDetectDismissedMax else { return fresh }
        // Over the cap, keep the most recent by END (unparseable as newest); sort indices to preserve list order.
        let keepIdx = Set(fresh.indices
            .sorted { (autoDetectTokenEnd(fresh[$0]) ?? .max) > (autoDetectTokenEnd(fresh[$1]) ?? .max) }
            .prefix(Self.autoDetectDismissedMax))
        return fresh.indices.filter { keepIdx.contains($0) }.map { fresh[$0] }
    }

    /// Runs the opt-in detector over the last `daysBack` days of HR and returns the single best newest
    /// candidate that is NOT already saved or previously dismissed; nil when the toggle is off or nothing
    /// qualifies. PURE READ: never writes a workout. Every candidate passes `AutoWorkoutGate`: mandatory
    /// wrist-movement confirmation, at least 15 minutes, an average of 40 % of heart-rate reserve above
    /// resting (50 % within an hour of waking). With no movement data there is no suggestion, so HR landing
    /// before the ~15-minute gravity offload can't announce a bout that later vanishes.
    func autoDetectCandidate(daysBack: Int = 2) async -> DetectedWorkout? {
        guard PuffinExperiment.autoDetectWorkoutsEnabled else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let from = now - daysBack * 86_400
        let samples = await hrSamples(from: from, to: now, limit: 200_000)
        guard samples.count >= 2 else { return nil }
        let hr = samples.map { (ts: $0.ts, bpm: $0.bpm) }

        // Resting HR: most recent nightly RHR in range, else the detector's default (60).
        let restingBpm = days.last(where: { $0.restingHr != nil })?.restingHr

        // Exclude every already-saved workout window (any source).
        let saved = await workoutRows()
        let savedSpans = saved.map { SavedWorkoutSpan(startSec: $0.startTs, endSec: $0.endTs) }

        // Workouts & GPS test mode: local-only trace and shadow comparisons; they never choose the suggestion.
        if TestCentre.active(.workouts), workoutsLog != nil {
            let (_, trace) = AutoWorkoutDetector.detectTrace(
                hr: hr, restingBpm: restingBpm, motion: nil, savedSpans: savedSpans,
                minimumSustainedMinutes: AutoWorkoutDetector.minSustainedMin,
                path: "autoDetect")
            for line in trace { emitWorkouts(line) }
            let labelledSpans = saved
                // `workoutRows()` returns long-lived history; shadow candidates only cover this scan, so count labels
                // in the same [from, now] start-time window or old sessions become false "missed" results.
                .filter {
                    $0.startTs >= from && $0.startTs <= now
                        && WorkoutSource.classify($0.source) != .detected
                }
                .map { SavedWorkoutSpan(startSec: $0.startTs, endSec: $0.endTs) }
            for line in AutoWorkoutDetector.shadowComparisonLines(
                hr: hr, restingBpm: restingBpm, motion: nil, savedSpans: labelledSpans) {
                emitWorkouts(line)
            }
        }

        let gravity = await gravitySamplesUnion(from: from, to: now, limit: 200_000)
        guard gravity.count >= 600 else { return nil }
        let motion = AutoWorkoutDetector.motionPoints(gravity)
        // Every sleep that could sit just before a candidate: the night and naps, both sources.
        var sleepSpans = sleeps.map { AutoWorkoutGate.SleepSpan(startSec: $0.effectiveStartTs, endSec: $0.endTs) }
        sleepSpans += (await allSleepSessions(days: daysBack + 1))
            .map { AutoWorkoutGate.SleepSpan(startSec: $0.effectiveStartTs, endSec: $0.endTs) }
        let hrMax = AutoWorkoutGate.hrMax(
            profileHRMax: strainProfile?.hrMax,
            age: UserDefaults.standard.object(forKey: "profile.age") as? Int)
        let candidates = AutoWorkoutGate.detect(hr: hr, restingBpm: restingBpm, hrMax: hrMax,
                                                motion: motion, sleeps: sleepSpans, savedSpans: savedSpans)
        emitWorkouts("autoDetect gate: hrMax=\(Int(hrMax)) rest=\(restingBpm.map(String.init) ?? "nil") "
                     + "sleeps=\(sleepSpans.count) kept=\(candidates.count)")
        return Self.selectAutoDetectCandidate(
            candidates,
            autoDismissedTokens: autoDetectDismissedSpans,
            detectedDismissedTokens: dismissedDetectedSpans)
    }

    // MARK: Announced candidate (Zoop)
    //
    // The notification and Home must show the same workout. The detector re-runs on every refresh and its
    // window edges move, so the announced candidate is stored when the notification posts and Home shows
    // it until saved or dismissed.

    /// The candidate the last notification announced ("start:end:avg:peak:min").
    nonisolated static let pendingAutoWorkoutKey = "zoop.autoWorkout.pending"

    nonisolated static func encodePendingAutoWorkout(_ w: DetectedWorkout) -> String {
        "\(w.startSec):\(w.endSec):\(w.avgBpm):\(w.peakBpm):\(w.durationMin)"
    }

    nonisolated static func decodePendingAutoWorkout(_ s: String?) -> DetectedWorkout? {
        guard let parts = s?.split(separator: ":").compactMap({ Int($0) }), parts.count == 5,
              parts[1] > parts[0] else { return nil }
        return DetectedWorkout(startSec: parts[0], endSec: parts[1], avgBpm: parts[2],
                               peakBpm: parts[3], durationMin: parts[4])
    }

    /// The suggestion Home shows: the announced candidate while it is still open, else a fresh scan.
    func homeAutoWorkoutCandidate() async -> DetectedWorkout? {
        guard PuffinExperiment.autoDetectWorkoutsEnabled else { return nil }
        let d = UserDefaults.standard
        if let pending = Self.decodePendingAutoWorkout(d.string(forKey: Self.pendingAutoWorkoutKey)) {
            let now = Int(Date().timeIntervalSince1970)
            let saved = await workoutRows()
            let stillOpen = pending.endSec >= now - 3 * 86_400
                && !saved.contains { pending.startSec <= $0.endTs && $0.startTs <= pending.endSec }
                && Self.selectAutoDetectCandidate([pending], autoDismissedTokens: autoDetectDismissedSpans,
                                                  detectedDismissedTokens: dismissedDetectedSpans) != nil
            if stillOpen { return pending }
            d.removeObject(forKey: Self.pendingAutoWorkoutKey)
        }
        return await autoDetectCandidate()
    }

    /// Forget the announced candidate once the user has answered it (or one overlapping it).
    private func clearPendingAutoWorkout(overlapping w: DetectedWorkout) {
        let d = UserDefaults.standard
        guard let p = Self.decodePendingAutoWorkout(d.string(forKey: Self.pendingAutoWorkoutKey)) else { return }
        if p.startSec <= w.endSec && w.startSec <= p.endSec { d.removeObject(forKey: Self.pendingAutoWorkoutKey) }
    }

    /// SAVES a suggested window as a manual-style "Workout" (generic sport; none is claimed), built
    /// through `WorkoutSource.buildManualRow` like the manual sheet. The new span then excludes this window.
    @discardableResult
    func saveDetectedWorkout(_ w: DetectedWorkout) async -> Bool {
        let durationMin = max(1, w.durationMin)
        let start = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        guard let row = WorkoutSource.buildManualRow(start: start, durationMin: durationMin,
                                                     sport: "Workout", avgHr: w.avgBpm,
                                                     energyKcal: nil) else { return false }
        await saveManualWorkout(row)
        clearPendingAutoWorkout(overlapping: w)
        return true
    }

    /// DISMISSES a suggested window by recording its span durably. Idempotent; prunes on every add
    /// (drop spans older than ~30 days, cap at 200 most recent).
    func dismissDetectedSuggestion(_ w: DetectedWorkout) {
        clearPendingAutoWorkout(overlapping: w)
        let token = Self.autoDetectToken(w)
        var spans = autoDetectDismissedSpans
        guard !spans.contains(token) else { return }
        spans.append(token)
        autoDetectDismissedSpans = prunedAutoDetectSpans(spans, now: Int(Date().timeIntervalSince1970))
    }

    // MARK: - Workout detail (read-only helpers)
    //
    // Two reads over one session's [startTs, endTs] window: a downsampled HR curve and the raw HR binned
    // into zone-minutes. Thin wrappers over the existing HR reads that keep bucket size and sample cap
    // consistent. Pure reads; never mutate.

    /// Downsampled HR over a workout window for the detail curve. The bucket scales with duration
    /// (~120 buckets, floored at 15 s, capped at 300 s) so a short session isn't flattened. Reads the
    /// ids `workoutHrDeviceIds` resolves for this row, so the curve and Avg HR describe the same strap.
    /// `source` defaults to "" (the imported/manual branch, the union).
    func workoutHrBuckets(from: Int, to: Int, source: String = "") async -> [HRBucket] {
        guard to > from else { return [] }
        let span = to - from
        let bucket = max(15, min(300, span / 120))
        let ids = Self.workoutHrDeviceIds(source: source, activeStrapId: deviceId,
                                          importedIds: importedReadIds)
        return await hrBuckets(deviceIds: ids, from: from, to: to, bucketSeconds: bucket)
    }

    /// Raw HR samples binned into per-zone MINUTES for a workout window, using age-derived (Tanaka)
    /// %HRmax zones, so a session WITHOUT imported `zonesJSON` still gets a time-in-zone split. Nil when
    /// the window has no HR; `age <= 0` falls back to 30 y (approximate, labelled so in the UI). Bins the
    /// same rows the chart plots and Avg HR aggregates; `source` defaults to "" (the union).
    func workoutZoneMinutes(from: Int, to: Int, zoneSet: HRZoneSet, source: String = "") async -> [Double]? {
        guard to > from else { return nil }
        let ids = Self.workoutHrDeviceIds(source: source, activeStrapId: deviceId,
                                          importedIds: importedReadIds)
        let samples = await hrSamples(deviceIds: ids, from: from, to: to)
        guard !samples.isEmpty else { return nil }
        let tiz = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let minutes = tiz.seconds.map { $0 / 60.0 }
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }

    /// HRR for one workout, derived from the final five minutes of effort plus the five post-workout
    /// minutes: a narrow read, with the pure engine owning every eligibility guard. Missing post-workout
    /// HR returns nil rather than a fabricated value. Reads the ids this row resolves to (the recording
    /// strap is still on the wrist minutes after the bout).
    func workoutHeartRateRecovery(from: Int, to: Int, maxHR: Double,
                                  source: String = "") async -> HeartRateRecovery.Result? {
        guard to > from, maxHR > 0 else { return nil }
        let readFrom = max(from, to - HeartRateRecovery.eligibilityLookbackSeconds)
        let readTo = to + 5 * 60 + HeartRateRecovery.measurementToleranceSeconds
        let ids = Self.workoutHrDeviceIds(source: source, activeStrapId: deviceId,
                                          importedIds: importedReadIds)
        let samples = await hrSamples(deviceIds: ids, from: readFrom, to: readTo, limit: 2_000)
        return HeartRateRecovery.calculate(samples: samples, workoutStart: from, workoutEnd: to,
                                           maxHR: maxHR)
    }

    /// "After the workout": the post-workout engine's inputs for one session. HR is the session's own
    /// namespace from 5 min before the end to 3 h after; daily rows are the 30 logical days up to the
    /// workout day (baseline) plus the next wake day; the trend compares HRR1 with up to 8 sessions of the last 60 days.
    func postWorkoutRecovery(row: WorkoutRow, maxHR: Double)
        async -> (result: PostWorkoutRecovery.Result, trend: PostWorkoutRecovery.Trend?) {
        let end = row.endTs
        let ids = Self.workoutHrDeviceIds(source: row.source, activeStrapId: deviceId,
                                          importedIds: importedReadIds)
        let readFrom = max(row.startTs, end - HeartRateRecovery.eligibilityLookbackSeconds)
        let readTo = end + PostWorkoutRecovery.windowMinutes * 60
        let samples = await hrSamples(deviceIds: ids, from: readFrom, to: readTo, limit: 30_000)

        let workoutDay = Self.logicalDay(Date(timeIntervalSince1970: TimeInterval(end)))
        let cal = Calendar.current
        let firstDay = cal.date(byAdding: .day, value: -29, to: workoutDay) ?? workoutDay
        let nextDay = cal.date(byAdding: .day, value: 1, to: workoutDay) ?? workoutDay
        let nextKey = Self.localDayKey(nextDay)
        let rows = await dailyMetrics(fromDay: Self.localDayKey(firstDay), toDay: nextKey)
        func reading(_ m: DailyMetric) -> PostWorkoutRecovery.DayReading {
            .init(restingHr: m.restingHr.map(Double.init), hrv: m.avgHrv, recovery: m.recovery)
        }
        let baseline = rows.filter { $0.day < nextKey }.map(reading)
        let nextMorning = rows.first { $0.day == nextKey }.map(reading)

        let result = PostWorkoutRecovery.analyze(
            samples: samples, workoutStart: row.startTs, workoutEnd: end, maxHR: maxHR,
            baselineDays: baseline, nextMorning: nextMorning, now: Int(Date().timeIntervalSince1970))

        var trend: PostWorkoutRecovery.Trend?
        if let current = result.hrr1 {
            let earlier = await workoutRows(days: 60)
                .filter { $0.endTs < row.startTs && $0.endTs > $0.startTs }
                .sorted { $0.startTs > $1.startTs }
                .prefix(8)
            var history: [Int] = []
            for w in earlier {
                if let h = await workoutHeartRateRecovery(from: w.startTs, to: w.endTs, maxHR: maxHR,
                                                          source: w.source)?.after1Minute {
                    history.append(h)
                }
            }
            trend = PostWorkoutRecovery.trend(currentHRR1: current, recentHRR1: history)
        }
        return (result, trend)
    }

    /// Apple Health daily aggregates (steps/energy/vo2/hr).
    func appleDailyRows(days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: "apple-health",
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// The SHARED heavy-load seam behind `AppleHealthView.load()`: owns the cache short-circuit, the
    /// DEBUG fire tally, the whole-history reads and the write-back, so the cold-mount freeze fix is
    /// testable. With `allowCache` and unchanged state (`appleHealthLoadedSeq == refreshSeq`, same local
    /// dayKey, snapshot present) it restores the snapshot with no store queries and no tally bump; any
    /// other call runs the full read, snapshots it keyed by seq + dayKey, and returns it.
    func performAppleHealthLoad(seriesKeys: [String], allowCache: Bool) async -> AppleHealthLoadCache {
        // Same-state re-mount: restore the prior snapshot (no queries). The dayKey guard mirrors `.task(id:)`
        // so a day rollover still re-loads.
        if allowCache,
           appleHealthLoadedSeq == refreshSeq,
           appleHealthLoadedDayKey == Repository.localDayKey(Date()),
           let cached = appleHealthCache {
            return cached
        }

        #if DEBUG
        // Count only genuine heavy loads (the cache restore above returned before this).
        loadFireCounts["appleHealth", default: 0] += 1
        #endif

        async let rows = appleDailyRows()
        async let workouts = workoutRows()

        // ALL history is loaded ONCE and the range control windows it client-side, anchored to the latest
        // data point (not "now"), so the fetch forces the full epoch via `fullHistory` (`days` is ignored then).
        var fetched: [String: [(day: String, value: Double)]] = [:]
        for key in seriesKeys {
            fetched[key] = await series(key: key, source: "apple-health", days: 4000, fullHistory: true)
        }

        let loadedRows = await rows
        let appleWorkouts = await workouts.filter { WorkoutSource.isAppleHealth($0.source) }

        let snapshot = AppleHealthLoadCache(appleRows: loadedRows.sorted { $0.day < $1.day },
                                            workoutCount: appleWorkouts.count,
                                            series: fetched)
        // Snapshot what was read onto the long-lived repo, keyed by seq + dayKey, so a same-state re-mount restores it.
        appleHealthCache = snapshot
        appleHealthLoadedSeq = refreshSeq
        appleHealthLoadedDayKey = Repository.localDayKey(Date())
        return snapshot
    }

    /// Shared formatter, created once: hot read path, and allocating a DateFormatter per call was measurable.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

    /// The "yyyy-MM-dd" day one calendar day AFTER `day`, or `day` verbatim when it isn't a parseable ISO
    /// date. Backs the +1-day daily read buffer in `resolvedRows` so a wake-day-keyed night past the upper bound still resolves.
    static func dayAfter(_ day: String) -> String {
        guard let d = dayFormatter.date(from: day),
              let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: d)
        else { return day }
        return dayFormatter.string(from: next)
    }
}

// `internal`, not `private`: `DailySkinTempAbsoluteCarryTests` calls these directly, and a `private`
// extension is invisible even to `@testable import`. Still confined to this module.
extension DailyMetric {
    /// A copy of self with every nil field backfilled from `fallback`, so an imported export keeps its
    /// values while a computed row fills the gaps (on-device Charge, skin-temp deviation, activity totals).
    func fillingNilFields(from fallback: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin ?? fallback.totalSleepMin,
            efficiency: efficiency ?? fallback.efficiency,
            deepMin: deepMin ?? fallback.deepMin,
            remMin: remMin ?? fallback.remMin,
            lightMin: lightMin ?? fallback.lightMin,
            disturbances: disturbances ?? fallback.disturbances,
            restingHr: restingHr ?? fallback.restingHr,
            avgHrv: avgHrv ?? fallback.avgHrv,
            recovery: recovery ?? fallback.recovery,
            strain: strain ?? fallback.strain,
            exerciseCount: exerciseCount ?? fallback.exerciseCount,
            spo2Pct: spo2Pct ?? fallback.spo2Pct,
            skinTempDevC: skinTempDevC ?? fallback.skinTempDevC,
            respRateBpm: respRateBpm ?? fallback.respRateBpm,
            steps: steps ?? fallback.steps,
            activeKcalEst: activeKcalEst ?? fallback.activeKcalEst,
            // Raw SpO2 is on-device only (imports never carry it): backfill from the computed fallback or the nightly means are lost.
            spo2Red: spo2Red ?? fallback.spo2Red,
            spo2Ir: spo2Ir ?? fallback.spo2Ir,
            avgSdnn: avgSdnn ?? fallback.avgSdnn,
            // On-device only (imports never carry it): backfill from the computed fallback or the night's absolute is lost.
            skinTempC: skinTempC ?? fallback.skinTempC,
            // Same reason: only a scoring pass knows how the night was staged, so the import's nil takes the computed answer.
            sleepHrOnly: sleepHrOnly ?? fallback.sleepHrOnly
        )
    }

    /// A copy of self with the SLEEP fields overridden by `source`, so a hand-edited night's computed sleep
    /// figures win over the import for that day. Only sleep columns move; the import still wins elsewhere.
    func takingSleepFields(from source: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: source.totalSleepMin,
            efficiency: source.efficiency,
            deepMin: source.deepMin,
            remMin: source.remMin,
            lightMin: source.lightMin,
            disturbances: source.disturbances,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: recovery,
            strain: strain,
            exerciseCount: exerciseCount,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: activeKcalEst,
            spo2Red: spo2Red,   // non-sleep field: preserved as-is (#93)
            spo2Ir: spo2Ir,
            avgSdnn: avgSdnn,   // non-sleep (HRV) field: preserved as-is
            skinTempC: skinTempC, // non-sleep (thermal) field: preserved as-is (#1636)
            // MOVES with the sleep columns: it describes how the stage figures being taken were derived, and an
            // import's is always nil, so leaving `self`'s would caption the source's hypnogram with the import's staging.
            sleepHrOnly: source.sleepHrOnly
        )
    }
}
