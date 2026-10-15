#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Loading (stored history → engine inputs)
//
// Everything the Insights page reads, fetched once per refresh. The quick readings come from the
// in-memory daily rows; the four that walk raw streams (zone mix, stress timing, evening stress,
// heart-rate recovery) are scored at most once per local day, because a refresh fires on every sync.
// Stress timing comes from `StressPatternStore`, shared with the Stress screen.

/// The outcomes a habit can be measured against.
enum BodyOutcome: String, CaseIterable, Identifiable {
    case recovery, hrv, sleep, restingHR
    var id: String { rawValue }

    /// metricSeries key; also the DailyMetric fallback column.
    var seriesKey: String {
        switch self {
        case .recovery: return "recovery"
        case .hrv: return "hrv"
        case .sleep: return "sleep_performance"
        case .restingHR: return "rhr"
        }
    }

    var higherIsBetter: Bool { self != .restingHR }

    var unit: MetricUnitKind {
        switch self {
        case .recovery, .sleep: return .percent
        case .hrv: return .milliseconds
        case .restingHR: return .beatsPerMinute
        }
    }

    /// The daily-row column standing in when the imported series has no value (strap-only users).
    /// Sleep performance has no column, so it stays import-only.
    func fallback(_ d: DailyMetric) -> Double? {
        switch self {
        case .recovery: return d.recovery
        case .hrv: return d.avgHrv
        case .restingHR: return d.restingHr.map(Double.init)
        case .sleep: return nil
        }
    }
}

/// The subset of units a habit outcome uses; maps to `MetricUnit` in the builders.
enum MetricUnitKind { case percent, milliseconds, beatsPerMinute }

/// Heart-rate drop one minute after recent hard workouts.
struct BodyHRR: Equatable {
    let latestDrop: Int
    let averageDrop: Double
    let workouts: Int
}

struct BodySnapshot: Equatable {
    var hrv: BodyInsights.Direction?
    var restingHR: BodyInsights.Direction?
    var weekday: BodyInsights.WeekdayReading?
    /// Daily recovery, for the weekday chart when no weekday stands out.
    var recovery: [BodyInsights.DayValue] = []
    var bounceBack: BodyInsights.BounceBack?
    var sensitivity: BodyInsights.StrainSensitivity?
    var zoneMix: BodyInsights.ZoneMix?
    var stressTiming: BodyInsights.StressTiming?
    var hrr: BodyHRR?
    var eveningStress: PatternInsights.SplitEffect?
    /// Journal: per question, the days answered yes and the days answered no.
    var yesDays: [String: Set<String>] = [:]
    var noDays: [String: Set<String>] = [:]
    var outcomes: [BodyOutcome: [String: Double]] = [:]
}

@MainActor
final class BodyLoader {
    private struct DayCache {
        var day: String
        var zoneMix: BodyInsights.ZoneMix?
        var stressTiming: BodyInsights.StressTiming?
        var hrr: BodyHRR?
        var eveningStress: PatternInsights.SplitEffect?
    }
    private var cache: DayCache?

    static let zoneWindowDays = 28
    static let eveningDays = 28

    /// The in-memory readings: instant, so the page can draw before the slow ones arrive.
    func quick(repo: Repository) -> BodySnapshot {
        let days = repo.days
        let today = Repository.localDayKey(Date())
        let loads = BodyInsights.loads(days)
        var s = BodySnapshot()
        s.hrv = BodyInsights.direction(BodyInsights.hrv(days), asOf: today)
        s.restingHR = BodyInsights.direction(BodyInsights.restingHR(days), asOf: today)
        s.recovery = BodyInsights.recovery(days)
        s.weekday = BodyInsights.weekday(s.recovery)
        s.bounceBack = BodyInsights.bounceBack(loads)
        s.sensitivity = BodyInsights.strainSensitivity(loads)
        if let cache, cache.day == today {
            s.zoneMix = cache.zoneMix
            s.stressTiming = cache.stressTiming
            s.hrr = cache.hrr
            s.eveningStress = cache.eveningStress
        }
        return s
    }

    /// The journal and the outcome series it is ranked against.
    func journal(into s: inout BodySnapshot, repo: Repository) async {
        var yes: [String: Set<String>] = [:], no: [String: Set<String>] = [:]
        for e in await repo.journalEntries() {
            if e.answeredYes { yes[e.question, default: []].insert(e.day) } else { no[e.question, default: []].insert(e.day) }
        }
        s.yesDays = yes
        s.noDays = no
        let days = repo.days
        for outcome in BodyOutcome.allCases {
            var byDay: [String: Double] = [:]
            for row in await repo.series(key: outcome.seriesKey, source: "my-whoop") { byDay[row.day] = row.value }
            for d in days where byDay[d.day] == nil {
                if let v = outcome.fallback(d) { byDay[d.day] = v }
            }
            s.outcomes[outcome] = byDay
        }
    }

    /// The stream-walking readings, once per local day.
    func slow(into s: inout BodySnapshot, repo: Repository, zoneSet: HRZoneSet, maxHR: Int) async {
        let today = Repository.localDayKey(Date())
        if cache?.day != today {
            var c = DayCache(day: today)
            c.zoneMix = await zoneMix(repo: repo, zoneSet: zoneSet)
            c.hrr = await heartRateRecovery(repo: repo, maxHR: maxHR)
            c.stressTiming = await stressTiming(repo: repo)
            c.eveningStress = await eveningStress(repo: repo)
            cache = c
        }
        s.zoneMix = cache?.zoneMix
        s.stressTiming = cache?.stressTiming
        s.hrr = cache?.hrr
        s.eveningStress = cache?.eveningStress
    }

    /// Zone minutes per workout of the last four weeks: the imported split first, the strap's own heart
    /// rate otherwise (the same precedence as the workout detail page).
    private func zoneMix(repo: Repository, zoneSet: HRZoneSet) async -> BodyInsights.ZoneMix? {
        let cutoff = Int(Date().timeIntervalSince1970) - Self.zoneWindowDays * 86_400
        let rows = await repo.workoutRows(days: Self.zoneWindowDays).filter { $0.startTs >= cutoff && $0.endTs > $0.startTs }
        var sessions: [[Double]] = []
        for row in rows.prefix(60) {
            if let pct = WorkoutZones.percents(row.zonesJSON) {
                let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60
                if durMin > 0 { sessions.append(pct.map { durMin * $0 / 100 }) }
            } else if let m = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs, zoneSet: zoneSet,
                                                             source: row.source) {
                sessions.append(m)
            }
        }
        return BodyInsights.zoneMix(sessions: sessions)
    }

    /// One-minute heart-rate drop after the last twelve workouts of at least ten minutes.
    private func heartRateRecovery(repo: Repository, maxHR: Int) async -> BodyHRR? {
        let rows = await repo.workoutRows(days: 120).filter { $0.endTs - $0.startTs >= 600 }.suffix(12)
        var drops: [Int] = []
        for r in rows {
            // `after1Minute` is already the drop from the cessation heart rate (HeartRateRecovery).
            if let drop = await repo.workoutHeartRateRecovery(from: r.startTs, to: r.endTs, maxHR: Double(maxHR),
                                                               source: r.source)?.after1Minute {
                drops.append(drop)
            }
        }
        guard let last = drops.last else { return nil }
        return BodyHRR(latestDrop: last, averageDrop: Double(drops.reduce(0, +)) / Double(drops.count),
                       workouts: drops.count)
    }

    /// The peak and calmest stress hour of the last 14 days, from the store the Stress screen reads.
    func stressTiming(repo: Repository) async -> BodyInsights.StressTiming? {
        await StressPatternStore.shared.timing(repo: repo)
    }

    /// Mean evening stress (17:00–23:00) against the deep sleep of the night that followed.
    private func eveningStress(repo: Repository) async -> PatternInsights.SplitEffect? {
        var deepByDay: [String: Double] = [:]
        for d in repo.days { if let deep = d.deepMin { deepByDay[d.day] = deep } }
        var pairs: [(driver: Double, outcome: Double)] = []
        for date in StressPatternStore.pastDays(Self.eveningDays) {
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: date),
                  let deep = deepByDay[Repository.localDayKey(next)] else { continue }
            let from = Int(date.timeIntervalSince1970) + 17 * 3600
            guard let result = await StressPatternStore.analyze(repo: repo, from: from, to: from + 6 * 3600, date: date,
                                                                minSamples: DaytimeStress.minHourHRSamples) else { continue }
            let levels = result.hours.compactMap(\.level)
            guard levels.count >= 3 else { continue }
            pairs.append((levels.reduce(0, +) / Double(levels.count), deep))
        }
        return PatternInsights.splitEffect(pairs)
    }
}
#endif
