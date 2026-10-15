import Foundation

// MARK: - Sleep insights (Zoop)
//
// Pure, DB-free interpretations of the wearer's stored nights: time to fall asleep, the sleep duration
// and bedtime window that precede the best recoveries, whether a regular bedtime pays off, and the
// weekend shift. Each insight is nil unless there is enough data (minimums below, pinned by
// `SleepInsightsTests`). Personal correlations only: not causal or clinical, and none feeds a score.
// The engine returns numbers and series; the app composes the sentences so they localize there.

public enum SleepInsights {

    // MARK: Input

    public struct Night: Equatable, Sendable {
        /// "yyyy-MM-dd" local day the night ended on (the day whose recovery it feeds).
        public var wakeDay: String
        /// Local clock time the night started (in bed), minutes after midnight, 0..<1440.
        public var bedtimeClockMin: Double
        public var inBedMin: Double
        public var asleepMin: Double?
        public var latencyMin: Double?
        /// The recovery scored the morning after this night, 0...100.
        public var recovery: Double?
        public var isFreeDay: Bool

        public init(wakeDay: String, bedtimeClockMin: Double, inBedMin: Double, asleepMin: Double?,
                    latencyMin: Double?, recovery: Double?, isFreeDay: Bool) {
            self.wakeDay = wakeDay; self.bedtimeClockMin = bedtimeClockMin; self.inBedMin = inBedMin
            self.asleepMin = asleepMin; self.latencyMin = latencyMin; self.recovery = recovery
            self.isFreeDay = isFreeDay
        }

        /// Bedtime as signed minutes from midnight: 22:30 is -90, 00:30 is +30. Noon is the seam, so a
        /// night that starts after midnight sorts after one that starts before it.
        public var bedtimeSignedMin: Double { SleepInsights.signedClock(bedtimeClockMin) }
        public var midSleepSignedMin: Double { bedtimeSignedMin + inBedMin / 2 }
    }

    // MARK: Minimums and windows

    public static let latencyMinNights = 14
    public static let latencyWindow = 30
    public static let latencyRecentWindow = 7
    public static let latencyRecentMinNights = 3
    public static let latencySteadyBandMin: Double = 2

    /// Nights paired with a next-morning recovery that the recovery insights need.
    public static let recoveryMinNights = 14
    public static let recoveryWindow = 90
    public static let binWidthMin: Double = 30
    public static let minNightsPerBin = 3
    /// A shorter sleep bin within this many recovery points of the best bin is "as good".
    public static let bestBinTolerancePts: Double = 5
    /// When every qualifying bin is within this many points, the relationship is flat.
    public static let flatSpreadPts: Double = 5

    /// Within this many minutes of the usual bedtime counts as a regular night.
    public static let regularToleranceMin: Double = 30
    public static let consistencyMinPerGroup = 4
    /// A recovery difference smaller than this (points) reads as no clear difference.
    public static let consistencyNoEffectPts: Double = 3

    public static let weekendWindow = 42
    public static let weekendMinFreeNights = 4
    public static let weekendMinWorkNights = 8

    /// Latencies above this are detection gaps, not falling asleep.
    public static let latencyMaxPlausibleMin: Double = 180
    /// Sleep durations outside this range are naps or broken nights, not a usable data point.
    public static let asleepPlausibleMin: ClosedRange<Double> = 180...720

    // MARK: Output

    public struct Point: Equatable, Sendable {
        public var day: String
        public var value: Double
        public init(day: String, value: Double) { self.day = day; self.value = value }
    }

    /// One bin: values in `lower..<upper`, with its mean next-morning recovery.
    public struct Bin: Equatable, Sendable, Identifiable {
        public var lower: Double
        public var upper: Double
        public var meanRecovery: Double
        public var count: Int
        public var id: Double { lower }
        public var center: Double { (lower + upper) / 2 }
    }

    public struct Latency: Equatable, Sendable {
        public var typicalMin: Double
        public var recentMin: Double
        /// recent − typical. Negative = falling asleep faster lately.
        public var deltaMin: Double
        public var nightCount: Int
        public var recentCount: Int
        public var series: [Point]
        public var recentDays: [String]

        public enum Trend: String, Sendable { case faster, slower, steady }
        public var trend: Trend {
            if abs(deltaMin) < SleepInsights.latencySteadyBandMin { return .steady }
            return deltaMin < 0 ? .faster : .slower
        }
    }

    public struct BinnedRecovery: Equatable, Sendable {
        /// Qualifying bins (≥ `minNightsPerBin` nights), ascending.
        public var bins: [Bin]
        public var best: Bin
        public var spreadPts: Double
        public var nightCount: Int
        /// True when no bin stands out, so the headline must not name a winner.
        public var isFlat: Bool { spreadPts < SleepInsights.flatSpreadPts }
    }

    public struct Consistency: Equatable, Sendable {
        public var usualBedtimeSignedMin: Double
        public var regularMeanRecovery: Double
        public var irregularMeanRecovery: Double
        public var regularCount: Int
        public var irregularCount: Int
        /// regular − irregular, recovery points.
        public var deltaPts: Double
        public var points: [(deviationMin: Double, recovery: Double)]

        public enum Effect: String, Sendable { case regularBetter, irregularBetter, none }
        public var effect: Effect {
            if abs(deltaPts) < SleepInsights.consistencyNoEffectPts { return .none }
            return deltaPts > 0 ? .regularBetter : .irregularBetter
        }

        public static func == (a: Consistency, b: Consistency) -> Bool {
            a.usualBedtimeSignedMin == b.usualBedtimeSignedMin && a.regularMeanRecovery == b.regularMeanRecovery
                && a.irregularMeanRecovery == b.irregularMeanRecovery && a.regularCount == b.regularCount
                && a.irregularCount == b.irregularCount && a.deltaPts == b.deltaPts
                && a.points.map(\.deviationMin) == b.points.map(\.deviationMin)
                && a.points.map(\.recovery) == b.points.map(\.recovery)
        }
    }

    public struct WeekendShift: Equatable, Sendable {
        public var workdayMidSleepSignedMin: Double
        public var freeDayMidSleepSignedMin: Double
        /// free − workday, minutes. Positive = later on weekends.
        public var shiftMin: Double
        public var workdayCount: Int
        public var freeDayCount: Int
        public var series: [(day: String, midSleepSignedMin: Double, isFreeDay: Bool)]

        public static func == (a: WeekendShift, b: WeekendShift) -> Bool {
            a.workdayMidSleepSignedMin == b.workdayMidSleepSignedMin
                && a.freeDayMidSleepSignedMin == b.freeDayMidSleepSignedMin && a.shiftMin == b.shiftMin
                && a.workdayCount == b.workdayCount && a.freeDayCount == b.freeDayCount
                && a.series.map(\.day) == b.series.map(\.day)
        }
    }

    public struct Report: Equatable, Sendable {
        public var latency: Latency?
        public var sleepNeed: BinnedRecovery?
        public var bedtime: BinnedRecovery?
        public var consistency: Consistency?
        public var weekendShift: WeekendShift?
        public var isEmpty: Bool {
            latency == nil && sleepNeed == nil && bedtime == nil && consistency == nil && weekendShift == nil
        }
    }

    // MARK: Entry point

    public static func report(_ nights: [Night]) -> Report {
        let n = normalized(nights)
        return Report(latency: latency(n), sleepNeed: sleepNeed(n), bedtime: bedtime(n),
                      consistency: consistency(n), weekendShift: weekendShift(n))
    }

    /// Oldest first, one night per wake day (the longest in bed wins).
    public static func normalized(_ nights: [Night]) -> [Night] {
        var byDay: [String: Night] = [:]
        for night in nights where night.inBedMin > 0 {
            if let kept = byDay[night.wakeDay], kept.inBedMin >= night.inBedMin { continue }
            byDay[night.wakeDay] = night
        }
        return byDay.values.sorted { $0.wakeDay < $1.wakeDay }
    }

    // MARK: 1. Time to fall asleep

    public static func latency(_ nights: [Night]) -> Latency? {
        let withLatency = normalized(nights).compactMap { n -> Point? in
            guard let l = n.latencyMin, l >= 0, l <= latencyMaxPlausibleMin else { return nil }
            return Point(day: n.wakeDay, value: l)
        }
        let window = Array(withLatency.suffix(latencyWindow))
        guard window.count >= latencyMinNights else { return nil }
        let recent = Array(window.suffix(latencyRecentWindow))
        guard recent.count >= latencyRecentMinNights,
              let typical = median(window.map(\.value)),
              let recentMedian = median(recent.map(\.value)) else { return nil }
        return Latency(typicalMin: typical, recentMin: recentMedian, deltaMin: recentMedian - typical,
                       nightCount: window.count, recentCount: recent.count, series: window,
                       recentDays: recent.map(\.day))
    }

    // MARK: 2. Sleep need for recovery

    public static func sleepNeed(_ nights: [Night]) -> BinnedRecovery? {
        let pairs = recoveryWindowNights(nights).compactMap { n -> (Double, Double)? in
            guard let a = n.asleepMin, asleepPlausibleMin.contains(a), let r = n.recovery else { return nil }
            return (a, r)
        }
        guard pairs.count >= recoveryMinNights else { return nil }
        let bins = binned(pairs)
        guard bins.count >= 2, let top = bins.map(\.meanRecovery).max(),
              let low = bins.map(\.meanRecovery).min() else { return nil }
        // The shortest duration that recovers about as well as the best one: more sleep past it buys little.
        guard let best = bins.first(where: { $0.meanRecovery >= top - bestBinTolerancePts }) else { return nil }
        return BinnedRecovery(bins: bins, best: best, spreadPts: top - low, nightCount: pairs.count)
    }

    // MARK: 3. Best bedtime window

    public static func bedtime(_ nights: [Night]) -> BinnedRecovery? {
        let pairs = recoveryWindowNights(nights).compactMap { n -> (Double, Double)? in
            guard let r = n.recovery else { return nil }
            return (n.bedtimeSignedMin, r)
        }
        guard pairs.count >= recoveryMinNights else { return nil }
        let bins = binned(pairs)
        guard bins.count >= 2,
              let best = bins.max(by: { $0.meanRecovery < $1.meanRecovery }),
              let low = bins.map(\.meanRecovery).min() else { return nil }
        return BinnedRecovery(bins: bins, best: best, spreadPts: best.meanRecovery - low, nightCount: pairs.count)
    }

    // MARK: 4. Consistency effect

    public static func consistency(_ nights: [Night]) -> Consistency? {
        let paired = recoveryWindowNights(nights).filter { $0.recovery != nil }
        guard paired.count >= recoveryMinNights,
              let usual = median(paired.map(\.bedtimeSignedMin)) else { return nil }
        var regular: [Double] = [], irregular: [Double] = []
        var points: [(Double, Double)] = []
        for n in paired {
            guard let r = n.recovery else { continue }
            let dev = abs(n.bedtimeSignedMin - usual)
            points.append((dev, r))
            if dev <= regularToleranceMin { regular.append(r) } else { irregular.append(r) }
        }
        guard regular.count >= consistencyMinPerGroup, irregular.count >= consistencyMinPerGroup else { return nil }
        let rm = mean(regular), im = mean(irregular)
        return Consistency(usualBedtimeSignedMin: usual, regularMeanRecovery: rm, irregularMeanRecovery: im,
                           regularCount: regular.count, irregularCount: irregular.count, deltaPts: rm - im,
                           points: points.map { (deviationMin: $0.0, recovery: $0.1) })
    }

    // MARK: 5. Weekend shift

    public static func weekendShift(_ nights: [Night]) -> WeekendShift? {
        let window = Array(normalized(nights).suffix(weekendWindow))
        let free = window.filter(\.isFreeDay).map(\.midSleepSignedMin)
        let work = window.filter { !$0.isFreeDay }.map(\.midSleepSignedMin)
        guard free.count >= weekendMinFreeNights, work.count >= weekendMinWorkNights else { return nil }
        let fm = mean(free), wm = mean(work)
        return WeekendShift(workdayMidSleepSignedMin: wm, freeDayMidSleepSignedMin: fm, shiftMin: fm - wm,
                            workdayCount: work.count, freeDayCount: free.count,
                            series: window.map { (day: $0.wakeDay, midSleepSignedMin: $0.midSleepSignedMin,
                                                  isFreeDay: $0.isFreeDay) })
    }

    // MARK: Helpers

    public static func signedClock(_ clockMin: Double) -> Double {
        let c = clockMin.truncatingRemainder(dividingBy: 1440)
        let pos = c < 0 ? c + 1440 : c
        return pos >= 720 ? pos - 1440 : pos
    }

    public static func clock(fromSigned signed: Double) -> Double {
        let c = signed.truncatingRemainder(dividingBy: 1440)
        return c < 0 ? c + 1440 : c
    }

    static func recoveryWindowNights(_ nights: [Night]) -> [Night] {
        Array(normalized(nights).suffix(recoveryWindow))
    }

    static func binned(_ pairs: [(Double, Double)]) -> [Bin] {
        var groups: [Double: [Double]] = [:]
        for (v, r) in pairs {
            let lower = (v / binWidthMin).rounded(.down) * binWidthMin
            groups[lower, default: []].append(r)
        }
        return groups.filter { $0.value.count >= minNightsPerBin }
            .map { Bin(lower: $0.key, upper: $0.key + binWidthMin, meanRecovery: mean($0.value), count: $0.value.count) }
            .sorted { $0.lower < $1.lower }
    }

    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    static func median(_ raw: [Double]) -> Double? {
        let v = raw.sorted()
        guard !v.isEmpty else { return nil }
        let m = v.count / 2
        return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
    }
}
