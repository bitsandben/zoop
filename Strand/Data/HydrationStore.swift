import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Hydration tracker (MVP) — opt-in, local-only water logging
//
// Three quick taps log water (Sip 30 ml / Cup 237 ml / Bottle 500 ml). The day total lives in
// `metricSeries` under a dedicated source/key (no schema change); one row per (deviceId, day, key), so a
// tap re-upserts total + amount.
// Source id, key, additive accumulation and the 7-day projection (0 for empty days, oldest first) must
// match the Android `HydrationStore`. Per-tap timestamps live only in the entry list below. On-device only.

enum HydrationStore {
    /// Local-only source id for the hydration total. Must match Android `SOURCE_ID`.
    static let sourceId = "hydration"

    /// metricSeries key for the daily total (ml). Must match Android `KEY`.
    static let key = "hydration"

    /// Settings opt-in key (default off); card and detail are hidden while false. Must match Android
    /// `KEY_HYDRATION_TRACKING`.
    static let enabledKey = "zoop.hydrationTracking"

    /// UserDefaults prefix for the per-day entry list (#798), one JSON array per local day
    /// (`<prefix><yyyy-MM-dd>`). The `metricSeries` total stays canonical; deleting or editing an entry
    /// re-banks it.
    static let entriesKeyPrefix = "zoop.hydrationEntries."

    /// AppStorage key for the custom container size (ml) (#798). Defaults to `cupML`.
    static let customSizeKey = "zoop.hydrationCustomSizeML"

    /// metricSeries key for water imported from Apple Health / Health Connect (#949). Must match Android
    /// `KEY_IMPORTED`.
    /// Separate from `key` because `key` accumulates per tap while this row is replaced with the platform's
    /// recomputed day sum on each sync. That makes re-import idempotent and lets a drink deleted in the
    /// source app reduce the figure. Imported water is never editable here.
    static let importedKey = "hydrationImported"

    static func entriesKey(forDay dayKey: String) -> String { entriesKeyPrefix + dayKey }
}

// MARK: - Per-entry model (#798) - individual logged drinks for edit/delete

/// One logged drink: stable id, amount (ml) and logged time. Persisted as a JSON array per local day.
struct HydrationEntry: Identifiable, Equatable, Codable {
    let id: UUID
    var amountMl: Int
    var loggedAt: Date

    init(id: UUID = UUID(), amountMl: Int, loggedAt: Date = Date()) {
        self.id = id
        self.amountMl = amountMl
        self.loggedAt = loggedAt
    }
}

/// Pure list operations over the per-day entries (#798). The day total is always the sum of amounts clamped
/// to >= 0.
enum HydrationEntries {
    /// Appends an entry; a non-positive amount returns the list unchanged.
    static func adding(_ entries: [HydrationEntry], amountMl: Int, at date: Date = Date()) -> [HydrationEntry] {
        guard amountMl > 0 else { return entries }
        return entries + [HydrationEntry(amountMl: amountMl, loggedAt: date)]
    }

    /// Removes the entry with `id` (no-op if absent).
    static func removing(_ entries: [HydrationEntry], id: UUID) -> [HydrationEntry] {
        entries.filter { $0.id != id }
    }

    /// Sets an entry's amount; non-positive removes it. Unknown ids are ignored.
    static func updating(_ entries: [HydrationEntry], id: UUID, amountMl: Int) -> [HydrationEntry] {
        guard amountMl > 0 else { return removing(entries, id: id) }
        return entries.map { $0.id == id ? HydrationEntry(id: $0.id, amountMl: amountMl, loggedAt: $0.loggedAt) : $0 }
    }

    /// Day total (ml): sum of entry amounts, each clamped >= 0.
    static func total(_ entries: [HydrationEntry]) -> Double {
        entries.reduce(0) { $0 + Double(max(0, $1.amountMl)) }
    }
}

// MARK: - Logging + read seam (Repository extension)

extension Repository {

    /// Total fluid (ml) for a local day as displayed: hand-logged plus imported (#949). Display paths use
    /// this; writes of a hand-logged drink must use `hydrationManualTotal`.
    func hydrationTotal(day: String) async -> Double {
        await hydrationManualTotal(day: day) + hydrationImportedTotal(day: day)
    }

    /// Only hand-logged water. The write path must read this, not `hydrationTotal`: quick-add stores
    /// `current + amount`, so the combined figure would fold imported water into the manual row and double
    /// the day.
    func hydrationManualTotal(day: String) async -> Double {
        await metricSeriesValue(key: HydrationStore.key, day: day)
    }

    /// Only water from the platform health store (#949); replaced wholesale by each sync.
    func hydrationImportedTotal(day: String) async -> Double {
        await metricSeriesValue(key: HydrationStore.importedKey, day: day)
    }

    /// One day's value for a hydration series, or 0 when absent.
    private func metricSeriesValue(key: String, day: String) async -> Double {
        guard let store = await storeHandle() else { return 0 }
        let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                 key: key, from: day, to: day)) ?? []
        return pts.first?.value ?? 0
    }

    /// Replaces the imported-water total per local day with the platform's recomputed sum (#949), so
    /// re-sync is idempotent and water deleted in the source app disappears.
    /// Only days whose value moved are written: the caller passes its whole 31-day window on every hourly
    /// observer wake. A day with no row and value 0 is skipped (absent reads as 0), but a day with a row
    /// now 0 is written, since that is a deletion propagating.
    func setImportedHydration(_ mlByDay: [String: Double]) async {
        guard !mlByDay.isEmpty, let store = await storeHandle() else { return }
        let days = mlByDay.keys.sorted()
        guard let from = days.first, let to = days.last else { return }

        // No `?? []`: a failed read must not look like "no rows", or a deleted day would hit the
        // skip-a-zero case and keep its stale row. Bail and let the next sync retry.
        guard let existing = try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                           key: HydrationStore.importedKey,
                                                           from: from, to: to) else { return }
        var stored: [String: Double] = [:]
        for p in existing { stored[p.day] = p.value }

        // Return type spelled out: app-target Swift is not compiled by CI, so avoid inference in a
        // multi-statement closure.
        let changed: [MetricPoint] = mlByDay.compactMap { (day, ml) -> MetricPoint? in
            let value = max(0, ml)
            guard let current = stored[day] else {
                // No row yet: only create one if there is something to record.
                return value == 0 ? nil : MetricPoint(day: day, key: HydrationStore.importedKey, value: value)
            }
            // Epsilon rather than ==, so float drift cannot rewrite every sync; far below a millilitre.
            guard abs(current - value) > 1e-9 else { return nil }
            return MetricPoint(day: day, key: HydrationStore.importedKey, value: value)
        }
        guard !changed.isEmpty else { return }

        _ = try? await store.upsertMetricSeries(changed, deviceId: HydrationStore.sourceId)
        // Only on a real change: the bump re-reads the Today card, and hydration writes never bump refreshSeq.
        noteHydrationChanged()
    }

    /// Logs `amountMl` for `day` (default today) by reading the current total and upserting total + amount.
    /// Non-positive is a no-op. Returns the new day total (ml).
    @discardableResult
    func logHydration(amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        guard amountMl > 0, let store = await storeHandle() else { return await hydrationTotal(day: dayKey) }
        // Manual total, never the combined one (#949).
        let current = await hydrationManualTotal(day: dayKey)
        let next = current + Double(amountMl)
        _ = try? await store.upsertMetricSeries(
            [MetricPoint(day: dayKey, key: HydrationStore.key, value: next)],
            deviceId: HydrationStore.sourceId)
        // #798: also record the per-entry row so the detail can edit and delete this drink.
        let entries = HydrationEntries.adding(Self.hydrationEntries(day: dayKey), amountMl: amountMl)
        Self.writeHydrationEntries(entries, day: dayKey)
        // #989: hydration writes never bump refreshSeq, so notify the Today card directly.
        noteHydrationChanged()
        // Returns the combined figure (#949) so a caller trusting the value does not drop imported water.
        return next + (await hydrationImportedTotal(day: dayKey))
    }

    // MARK: - Per-entry edit/delete (#798)

    /// Individual logged drinks for today (or `day`), oldest first, from UserDefaults. Local-only.
    func hydrationEntries(day: String? = nil) -> [HydrationEntry] {
        Self.hydrationEntries(day: day ?? Repository.localDayKey(Date()))
    }

    /// Deletes one entry, re-derives and re-banks the day total. Returns the new total (ml).
    @discardableResult
    func deleteHydrationEntry(id: UUID, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = HydrationEntries.removing(Self.hydrationEntries(day: dayKey), id: id)
        Self.writeHydrationEntries(next, day: dayKey)
        return await rebankHydrationTotal(entries: next, day: dayKey)
    }

    /// Sets an entry's amount (non-positive deletes), then re-derives and re-banks the total. Returns the
    /// new total (ml).
    @discardableResult
    func updateHydrationEntry(id: UUID, amountMl: Int, day: String? = nil) async -> Double {
        let dayKey = day ?? Repository.localDayKey(Date())
        let next = HydrationEntries.updating(Self.hydrationEntries(day: dayKey), id: id, amountMl: amountMl)
        Self.writeHydrationEntries(next, day: dayKey)
        return await rebankHydrationTotal(entries: next, day: dayKey)
    }

    /// Re-derives the day total from `entries` and upserts it into `metricSeries`.
    @discardableResult
    private func rebankHydrationTotal(entries: [HydrationEntry], day dayKey: String) async -> Double {
        let total = HydrationEntries.total(entries)
        if let store = await storeHandle() {
            _ = try? await store.upsertMetricSeries(
                [MetricPoint(day: dayKey, key: HydrationStore.key, value: total)],
                deviceId: HydrationStore.sourceId)
        }
        // #989: edits and deletes funnel here; notify the Today card (see logHydration).
        noteHydrationChanged()
        // The entry list covers hand-logged drinks only, so write the manual figure and return the combined
        // one (#949).
        return total + (await hydrationImportedTotal(day: dayKey))
    }

    // MARK: - Entry persistence (UserDefaults JSON, one array per local day)

    fileprivate static func hydrationEntries(day dayKey: String) -> [HydrationEntry] {
        guard let data = UserDefaults.standard.data(forKey: HydrationStore.entriesKey(forDay: dayKey)),
              let decoded = try? JSONDecoder().decode([HydrationEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.loggedAt < $1.loggedAt }
    }

    fileprivate static func writeHydrationEntries(_ entries: [HydrationEntry], day dayKey: String) {
        let key = HydrationStore.entriesKey(forDay: dayKey)
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Last `days` local-day totals through today, oldest first, as (day, ml); 0 for days with no log.
    /// `days` clamps to >= 1.
    func hydrationHistory(days: Int = 7, now: Date = Date()) async -> [(day: String, value: Double)] {
        let n = max(1, days)
        let from = now.addingTimeInterval(-Double(n - 1) * 86_400)
        let fromKey = Repository.localDayKey(from)
        let toKey = Repository.localDayKey(now)
        var byDay: [String: Double] = [:]
        if let store = await storeHandle() {
            // Both rows summed per day (#949), so bars agree with the Today card and ring.
            for key in [HydrationStore.key, HydrationStore.importedKey] {
                let pts = (try? await store.metricSeries(deviceId: HydrationStore.sourceId,
                                                         key: key,
                                                         from: fromKey, to: toKey)) ?? []
                for p in pts { byDay[p.day, default: 0] += p.value }
            }
        }
        return (0..<n).map { i in
            let key = Repository.localDayKey(now.addingTimeInterval(-Double(n - 1 - i) * 86_400))
            return (key, byDay[key] ?? 0)
        }
    }

    /// Today's hydration goal (ml) from profile sex and today's Effort (0-100) via `HydrationGoal`.
    func hydrationGoalML(profileSex: String) -> Int {
        HydrationGoal.dailyGoalML(sex: profileSex, effort: today?.strain)
    }
}
