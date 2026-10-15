import Foundation
import WhoopStore

// The daily level and headline of the stress fact. `DaytimeStress` is the one stress resolver: the
// hourly curve (`analyze`), the once-a-day level (`daily`) and the single number a surface shows
// (`headline`) share the same 0-3 squash, bands and z directions.

public extension DaytimeStress {

    // MARK: - Bands

    /// The three stress bands on the shared 0-3 scale.
    enum Band: String, Equatable, Sendable {
        case low, medium, high

        /// Below 1 is low, from `highBandFloor` (2) up is high, medium in between.
        public init(level: Double) {
            switch level {
            case ..<1.0: self = .low
            case ..<DaytimeStress.highBandFloor: self = .medium
            default: self = .high
            }
        }
    }

    // MARK: - Daily level

    /// Where the daily level came from.
    enum DailySource: String, Equatable, Sendable {
        /// A stored value for the day (an imported WHOOP stress figure), used verbatim.
        case stored
        /// Derived from the night's resting HR and HRV against the trailing 30-day window.
        case derived
    }

    struct DailyPoint: Equatable, Sendable {
        public let day: String
        public let level: Double
    }

    /// The daily stress level for the newest day with signal, with the inputs that explain it.
    struct Daily: Equatable, Sendable {
        /// The day scored: the newest row with resting HR, HRV or a stored value (#543).
        public let day: String
        public let level: Double
        public let source: DailySource
        public let restingHR: Int?
        public let hrv: Double?
        /// The scored day's value minus the baseline-window mean (bpm / ms); nil without both.
        public let restingHRDelta: Double?
        public let hrvDelta: Double?
        /// Every day with a stored or derivable level, oldest first, against the same baseline as `level`.
        public let trend: [DailyPoint]
        public let baselineNights: Int

        public var band: Band { Band(level: level) }

        /// Days in the last 30 charted that sat in the low band, and how many were charted.
        public var calmDays: (calm: Int, of: Int) {
            let recent = trend.suffix(30)
            return (recent.filter { $0.level < 1.0 }.count, recent.count)
        }
    }

    static let dailyBaselineWindow = 30

    /// The daily level (0-3, clamped) from oldest-first `days` plus any stored stress series.
    ///
    /// A stored value for the scored day wins; otherwise the squashed z-sum of resting HR (up = stress)
    /// and HRV (down = stress) against the 30 days before it. Nil only when no day carries signal.
    static func daily(days: [DailyMetric], stored: [(day: String, value: Double)]) -> Daily? {
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) }, uniquingKeysWith: { _, b in b })

        // Today's row is often vitals-less until the overnight is analysed, so score the newest day that
        // carries signal (#543).
        guard let idx = days.lastIndex(where: {
            $0.restingHr != nil || $0.avgHrv != nil || storedByDay[$0.day] != nil
        }) ?? days.indices.last else { return nil }
        let today = days[idx]

        // The window ends the day before the scored day, so a day is never measured against itself.
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(dailyBaselineWindow)) : []
        let rhrBase = baseline.compactMap(\.restingHr).map(Double.init)
        let hrvBase = baseline.compactMap(\.avgHrv)
        let meanRHR = mean(rhrBase), sdRHR = std(rhrBase, mean: meanRHR)
        let meanHRV = mean(hrvBase), sdHRV = std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv
        let derivable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivable else { return nil }

        let derivedToday: Double? = derivable
            ? squash(rawScore(hr: rhrT, meanHR: meanRHR, sdHR: sdRHR, rmssd: hrvT, meanRMSSD: meanHRV, sdRMSSD: sdHRV))
            : nil

        var trend: [DailyPoint] = []
        for d in days {
            if let v = storedByDay[d.day] {
                trend.append(DailyPoint(day: d.day, level: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = rawScore(hr: dRHR, meanHR: meanRHR, sdHR: sdRHR, rmssd: dHRV, meanRMSSD: meanHRV, sdRMSSD: sdHRV)
            trend.append(DailyPoint(day: d.day, level: squash(r)))
        }

        return Daily(
            day: today.day,
            level: storedToday ?? derivedToday ?? 1.5,
            source: storedToday != nil ? .stored : .derived,
            restingHR: today.restingHr,
            hrv: hrvT,
            restingHRDelta: (rhrT != nil && meanRHR != nil) ? rhrT! - meanRHR! : nil,
            hrvDelta: (hrvT != nil && meanHRV != nil) ? hrvT! - meanHRV! : nil,
            trend: trend,
            baselineNights: max(rhrBase.count, hrvBase.count))
    }

    // MARK: - Headline

    /// Which reading the headline shows.
    enum HeadlineSource: String, Equatable, Sendable {
        case currentHour
        case dailyLevel
        case none
    }

    /// The one stress number a surface shows for today: the latest scored hour, else the daily level.
    /// Hourly reads are `.building` at best (the daytime margin is validated on one subject, r~0.6
    /// against an Oura reference), so they are a hint, not a measurement.
    static func headline(hours: [HourPoint], daily: Daily?) -> Assessment<Double, HeadlineSource> {
        if let level = hours.last(where: { $0.level != nil })?.level {
            return Assessment(value: level, confidence: .building, reason: .currentHour)
        }
        if let daily {
            return Assessment(value: daily.level, confidence: dailyConfidence(daily), reason: .dailyLevel)
        }
        return Assessment(value: nil, confidence: .calibrating, reason: .none)
    }

    /// A stored value is taken as given; a derived level is solid once the full window backs it.
    static func dailyConfidence(_ daily: Daily) -> ScoreConfidence {
        if daily.source == .stored { return .solid }
        return ScoreConfidence.readiness(hasRead: true, baselineNights: daily.baselineNights,
                                         fullWindow: dailyBaselineWindow)
    }
}
