import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - SleepModel series
//
// Per-metric history pipelines (latest, typical mean, full series) and the debt ledger. Shared with
// Today's hosted cards and Patterns, so the numbers agree everywhere they appear.

extension SleepModel {

    // MARK: Typical / need

    static func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    static func typicalTotalMin(days: [DailyMetric]) -> Double? {
        mean(days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    static func typicalStageMin(days: [DailyMetric], _ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    static func sleepNeedMin(days: [DailyMetric]) -> Double {
        Swift.max(450, typicalTotalMin(days: days) ?? 450)   // 450 min = 7.5h
    }

    /// The NORMATIVE per-user sleep need (minutes) the DEBT surfaces measure against — the
    /// population-anchored, age-floored, upper-quartile `personalizedNeedHours`, the SAME estimator
    /// Rest/Intelligence score against. Deliberately NOT the descriptive `sleepNeedMin` (mean total
    /// sleep): the mean drifts DOWN toward a chronic under-sleeper's own deficit and quietly erases
    /// their debt, whereas the upper-quartile floored at the ~8 h adult target only adjusts UP for
    /// genuine long sleepers. Age isn't plumbed to this screen (age: nil → adult target); wiring it
    /// would only raise it for under-18s. One need across every debt surface, agreeing with the engine.
    /// (The descriptive `sleepNeedMin` still drives the
    /// non-debt "hours vs needed" performance tile.)
    static func debtNeedMin(days: [DailyMetric]) -> Double {
        AnalyticsEngine.Rest.personalizedNeedHours(
            nightlyHours: days.compactMap { $0.totalSleepMin.map { $0 / 60.0 } },
            age: nil) * 60.0
    }

    // MARK: Per-tile series (latest, typical mean, sparkline history)

    /// Build a metric from a per-day transform, keeping only finite values.
    ///
    /// `latest` is STALENESS-BOUNDED (`Baselines.vitalCarryDays`): it is the newest value only while
    /// that value's own day is recent enough to still be presented as this night's reading, and nil
    /// otherwise. Without the bound `series.last` reached back arbitrarily far — a respiratory rate
    /// last written by a WHOOP CSV import on 30 Jul kept rendering as "Respiratory 15.6" in the Night
    /// detail card two weeks later, with no date anywhere beside it, and was read (by the project's own
    /// investigation) as a current measurement. `typical` and `series` are deliberately UNBOUNDED: they
    /// are explicitly historical — the trend line and the "vs typical" mean are supposed to span the
    /// whole history, and it is only the headline number that claims to be current.
    static func metric(days: [DailyMetric], now: Date = Date(),
                       _ transform: (DailyMetric) -> Double?) -> Metric {
        let points = days.compactMap { d -> (day: String, value: Double)? in
            guard let v = transform(d), v.isFinite else { return nil }
            return (d.day, v)
        }
        let series = points.map(\.value)
        // `BodyVitalSigns.logicalDayKey` rather than `Repository.logicalDayKey`: same 04:00 boundary,
        // but self-contained, so this stays pure and independent of the @MainActor Repository.
        let fresh = Baselines.freshestCarried(points, todayKey: BodyVitalSigns.logicalDayKey(now))
        // track the day the carried value came from so the tile can stamp it. nil when there is
        // no carried value, or when the carried value IS today's own (no stamp needed for today's read).
        let todayKey = BodyVitalSigns.logicalDayKey(now)
        let latestDay = (fresh != nil && fresh!.day != todayKey) ? fresh!.day : nil
        return (fresh?.value, latestDay, mean(series), series)
    }

    /// Sleep performance %: the imported WHOOP figure when the export carried one for that day;
    /// else the REAL resolved Rest composite for that day.
    static func performanceSeries(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures]) -> Metric {
        let imported = importedSleep
        return metric(days: days) { d in
            if let p = imported[d.day]?.performancePct { return p }   // export-verbatim
            return AnalyticsEngine.Rest.composite(daily: d)            // real resolved Rest composite
        }
    }

    static func efficiencySeries(days: [DailyMetric]) -> Metric {
        metric(days: days) { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency: prefer the imported sleep_consistency series when it covers the latest night;
    /// else the APPROXIMATE rolling bedtime-spread score.
    static func consistencySeries(days: [DailyMetric], sleeps: [CachedSleepSession],
                                  importedSleep: [String: ImportedSleepFigures]) -> Metric {
        let imported = importedSleep
        if let lastDay = days.last?.day, imported[lastDay]?.consistencyPct != nil {
            let series = days.compactMap { imported[$0.day]?.consistencyPct }
            return (series.last, nil, mean(series), series)
        }
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, nil, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need. The imported sleep_need_min wins per day; else the
    /// APPROXIMATE personal-mean need.
    static func hoursVsNeededSeries(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures]) -> Metric {
        let imported = importedSleep
        let fallbackNeed = sleepNeedMin(days: days)
        return metric(days: days) { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    static func restorativeSeries(days: [DailyMetric]) -> Metric {
        metric(days: days) { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    static func respiratorySeries(days: [DailyMetric]) -> Metric {
        metric(days: days) { $0.respRateBpm }
    }

    /// Sleep debt (minutes): imported `sleep_debt_min` stays verbatim; otherwise the same
    /// recency-weighted ledger as the debt card, nap credit and 14-night window included.
    static func sleepDebtSeries(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures],
                                napSleepMinByDay: [String: Double]) -> Metric {
        let series = sleepDebtHistory(days: days, importedSleep: importedSleep,
                                      napSleepMinByDay: napSleepMinByDay).map(\.value)
        return (series.last, nil, mean(series), series)
    }

    /// `sleepDebtSeries` with the day each value belongs to.
    static func sleepDebtHistory(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures],
                                 napSleepMinByDay: [String: Double]) -> [(day: String, value: Double)] {
        // The normative need, not the wearer's own mean, which would drift down and erase real debt.
        let need = debtNeedMin(days: days)
        let credited = days.map { d in
            (day: d.day, totalSleepMin: SleepDebt.creditedSleepMin(
                mainSleepMin: d.totalSleepMin,
                napSleepMin: napSleepMinByDay[d.day] ?? 0))
        }
        return SleepDebt.debtSeries(series: credited, needHours: need / 60.0,
                                    importedDebtMin: importedSleep.compactMapValues(\.debtMin))
    }

    // MARK: Trend points

    /// Trailing total-sleep trend, plotted in HOURS. Single source of truth shared with the Today
    /// host (`AsleepDurationCard`), so the Sleep-tab trend and the hosted copy are byte-identical.
    static func durationTrendPoints(days: [DailyMetric]) -> [TrendPoint] {
        AsleepDurationData.build(days: days).points
    }

    // MARK: Sleep-debt ledger

    /// The 14-night recency-weighted estimate from cached daily metrics. It measures against the
    /// normative `debtNeedMin` (the engine's `personalizedNeedHours`) — the SAME need and recurrence
    /// the local "Sleep Debt" tile uses — and credits actual asleep minutes from separate naps.
    static func debtLedger(days: [DailyMetric], napSleepMinByDay: [String: Double]) -> SleepDebtLedger {
        SleepDebt.ledger(
            series: days.map { day in
                (day: day.day, totalSleepMin: SleepDebt.creditedSleepMin(
                    mainSleepMin: day.totalSleepMin,
                    napSleepMin: napSleepMinByDay[day.day] ?? 0))
            },
            needHours: debtNeedMin(days: days) / 60.0)
    }

}
