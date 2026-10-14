#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Trends (pick a metric and a window)
//
// One metric over 7, 30 or 90 days against the personal band, with one sentence saying how the window
// compares with the one before it. The change counts only when it clears the smallest worthwhile
// change (a quarter of the band, i.e. 0.5 SD, Plews 2012); anything smaller reads "no clear change".

enum BodyTrendMetric: String, CaseIterable, Identifiable {
    case recovery, hrv, restingHR, sleep, strain, respiratory
    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .recovery: return BodyStrings.trendRecovery
        case .hrv: return SleepStrings.hrv
        case .restingHR: return SleepStrings.restingHR
        case .sleep: return SleepStrings.duration
        case .strain: return BodyStrings.trendStrain
        case .respiratory: return SleepStrings.respiratory
        }
    }

    func unit(_ scale: EffortScale) -> MetricUnit {
        switch self {
        case .recovery: return .percent
        case .hrv: return .milliseconds
        case .restingHR: return .beatsPerMinute
        case .sleep: return .duration
        case .strain: return .score(fractionDigits: scale == .whoop ? 1 : 0)
        case .respiratory: return .breathsPerMinute
        }
    }

    /// The day's value in the unit's base (seconds for sleep, the user's effort scale for strain).
    func value(_ d: DailyMetric, scale: EffortScale) -> Double? {
        switch self {
        case .recovery: return d.recovery
        case .hrv: return d.avgHrv
        case .restingHR: return d.restingHr.map(Double.init)
        case .sleep: return d.totalSleepMin.map { $0 * 60 }
        case .strain: return d.strain.map { scale == .whoop ? $0 * 0.21 : $0 }
        case .respiratory: return d.respRateBpm
        }
    }

    func cfg(_ scale: EffortScale) -> MetricCfg {
        switch self {
        case .recovery: return SleepRangeConfig.score
        case .hrv: return SleepRangeConfig.hrv
        case .restingHR: return SleepRangeConfig.restingHR
        case .sleep: return SleepRangeConfig.duration
        case .respiratory: return SleepRangeConfig.respiratory
        case .strain:
            return scale == .whoop
                ? MetricCfg(minVal: 0, maxVal: 21, floorSpread: 0.6, halfLifeB: 14, halfLifeS: 21)
                : MetricCfg(minVal: 0, maxVal: 100, floorSpread: 3, halfLifeB: 14, halfLifeS: 21)
        }
    }
}

enum BodyTrendWindow: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    var label: LocalizedStringResource { BodyStrings.windowDays(rawValue) }
}

struct BodyTrend: Equatable {
    let metric: BodyTrendMetric
    let window: BodyTrendWindow
    let unit: MetricUnit
    /// Oldest first; days without a value are absent, so the line breaks there.
    let points: [MetricExplanation.TrendPoint]
    /// The personal band; nil while calibrating (fewer than four nights).
    let band: ClosedRange<Double>?
    let mean: Double?
    /// The one-sentence takeaway (§7.4 "so what").
    let takeaway: LocalizedStringResource
    /// "18 of 30 days in your range", or why there is no band yet.
    let bandNote: LocalizedStringResource

    static let minPoints = 3

    static func build(days: [DailyMetric], metric: BodyTrendMetric, window: BodyTrendWindow,
                      scale: EffortScale, today: Date = Date()) -> BodyTrend {
        let unit = metric.unit(scale)
        let all: [(day: String, value: Double)] = days.compactMap { d in
            guard let v = metric.value(d, scale: scale), v.isFinite else { return nil }
            return (d.day, v)
        }
        let cal = Calendar.current
        let n = window.rawValue
        let start = Repository.localDayKey(cal.date(byAdding: .day, value: -(n - 1), to: today) ?? today)
        let prevStart = Repository.localDayKey(cal.date(byAdding: .day, value: -(2 * n - 1), to: today) ?? today)
        let current = all.filter { $0.day >= start }
        let previous = all.filter { $0.day >= prevStart && $0.day < start }

        let range = SleepPersonalRange.resolve(history: all.map { Optional($0.value) }, cfg: metric.cfg(scale),
                                               population: 0...0, lastSample: nil)
        let band = range.isPersonal ? range.range : nil
        let points = current.map { MetricExplanation.TrendPoint(date: BodyFormat.date($0.day), value: $0.value) }
        let mean = current.isEmpty ? nil : current.map(\.value).reduce(0, +) / Double(current.count)

        guard current.count >= minPoints, let mean else {
            return BodyTrend(metric: metric, window: window, unit: unit, points: points, band: band, mean: nil,
                             takeaway: BodyStrings.trendTooFew(n), bandNote: BodyStrings.trendBandPending)
        }
        let avg = unit.format(mean, locale: BodyFormat.locale)
        let takeaway: LocalizedStringResource
        if previous.count >= minPoints {
            let prevMean = previous.map(\.value).reduce(0, +) / Double(previous.count)
            let delta = mean - prevMean
            let swc = band.map { ($0.upperBound - $0.lowerBound) / 4 } ?? .infinity
            if abs(delta) < swc {
                takeaway = BodyStrings.trendNoClearChange(avg, n)
            } else {
                let change = unit.format(abs(delta), locale: BodyFormat.locale)
                takeaway = delta > 0 ? BodyStrings.trendHigher(avg, change, n) : BodyStrings.trendLower(avg, change, n)
            }
        } else {
            takeaway = BodyStrings.trendAverageOnly(avg, n)
        }
        let note: LocalizedStringResource
        if let band {
            let inside = current.filter { band.contains($0.value) }.count
            note = BodyStrings.trendInRange(inside, current.count)
        } else {
            note = BodyStrings.trendBandPending
        }
        return BodyTrend(metric: metric, window: window, unit: unit, points: points, band: band, mean: mean,
                         takeaway: takeaway, bandNote: note)
    }
}
#endif
