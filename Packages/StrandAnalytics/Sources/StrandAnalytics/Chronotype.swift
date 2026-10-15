import Foundation

/// Sleep type (chronotype) from the user's own habitual sleep timing.
///
/// Method: the mid-sleep on free days corrected for catch-up sleep (MSFsc, Roenneberg et al. 2004,
/// the Munich ChronoType Questionnaire's measure), here taken from recorded nights instead of a
/// questionnaire. Free days are nights before a Saturday or Sunday (`SleepInsights.Night.isFreeDay`).
/// Social jetlag is the absolute gap between free-day and workday mid-sleep (Wittmann et al. 2006).
///
/// The type buckets are deliberately coarse: an MSFsc before 03:30 reads as an early type, from 05:00
/// as a late type, anything between as intermediate. Central-European adults centre around 04:00–04:30
/// (Roenneberg 2007), so the bands sit either side of that. Without enough free days the mid-sleep of
/// all nights stands in, and the profile says so (`usesFreeDays == false`).
public enum Chronotype {

    public enum Kind: String, Equatable, Sendable { case early, intermediate, late }
    public enum JetlagBand: String, Equatable, Sendable { case low, moderate, high }

    /// Most recent nights considered (six weeks, as `SleepInsights.weekendWindow`).
    public static let window = 42
    /// Fewer nights than this give no profile at all (CONCEPT §5.4: 7 nights).
    public static let minNights = 7
    /// A profile is solid from this many nights, including `solidFreeNights` free nights.
    public static let solidNights = 14
    public static let solidFreeNights = 2
    /// Free / work nights needed before free-day mid-sleep and social jetlag are computed.
    public static let minFreeNights = 2
    public static let minWorkNights = 3
    /// MSFsc (signed minutes from midnight) before which the type reads as early.
    public static let earlyBeforeMin: Double = 210
    /// MSFsc from which the type reads as late.
    public static let lateFromMin: Double = 300
    /// Social jetlag bands, minutes: under one hour low, from two hours high (Wittmann 2006).
    public static let jetlagModerateMin: Double = 60
    public static let jetlagHighMin: Double = 120

    public struct NightPoint: Equatable, Sendable {
        public var day: String
        public var midSleepSignedMin: Double
        public var isFreeDay: Bool
    }

    public struct Profile: Equatable, Sendable {
        public var kind: Kind
        /// The mid-sleep the type is read from: MSFsc, or the all-night median without free days.
        public var chronotypeMidSleepSignedMin: Double
        /// Median mid-sleep of every night in the window: when the user is usually halfway through the night.
        public var habitualMidSleepSignedMin: Double
        /// Standard deviation of the nightly mid-sleep, minutes. Lower is steadier.
        public var spreadMin: Double
        public var workdayMidSleepSignedMin: Double?
        public var freeDayMidSleepSignedMin: Double?
        /// |free − workday| mid-sleep, minutes; nil without enough of both.
        public var socialJetlagMin: Double?
        public var nightCount: Int
        public var freeNightCount: Int
        public var usesFreeDays: Bool
        public var series: [NightPoint]

        public var isSolid: Bool { nightCount >= Chronotype.solidNights && freeNightCount >= Chronotype.solidFreeNights }
        public var jetlagBand: JetlagBand? { socialJetlagMin.map(Chronotype.jetlagBand) }
    }

    public static func kind(midSleepSignedMin m: Double) -> Kind {
        if m < earlyBeforeMin { return .early }
        if m >= lateFromMin { return .late }
        return .intermediate
    }

    public static func jetlagBand(_ minutes: Double) -> JetlagBand {
        if minutes >= jetlagHighMin { return .high }
        if minutes >= jetlagModerateMin { return .moderate }
        return .low
    }

    /// The profile over the newest `window` nights, or nil under `minNights`.
    public static func profile(_ nights: [SleepInsights.Night]) -> Profile? {
        let recent = Array(SleepInsights.normalized(nights).suffix(window))
        guard recent.count >= minNights else { return nil }
        let mids = recent.map(\.midSleepSignedMin)
        let free = recent.filter(\.isFreeDay)
        let work = recent.filter { !$0.isFreeDay }
        let habitual = median(mids)
        let spread = standardDeviation(mids)

        var freeMid: Double?, workMid: Double?, jetlag: Double?
        var corrected = habitual
        let usesFree = free.count >= minFreeNights
        if usesFree {
            let msf = mean(free.map(\.midSleepSignedMin))
            freeMid = msf
            corrected = msf
            if work.count >= minWorkNights {
                let msw = mean(work.map(\.midSleepSignedMin))
                workMid = msw
                jetlag = abs(msf - msw)
                // Catch-up correction: remove half the extra free-day sleep over the weekly average.
                let sdf = mean(free.map(duration)), sdw = mean(work.map(duration))
                let sdWeek = (5 * sdw + 2 * sdf) / 7
                if sdf > sdw { corrected = msf - (sdf - sdWeek) / 2 }
            }
        }
        return Profile(kind: kind(midSleepSignedMin: corrected), chronotypeMidSleepSignedMin: corrected,
                       habitualMidSleepSignedMin: habitual, spreadMin: spread,
                       workdayMidSleepSignedMin: workMid, freeDayMidSleepSignedMin: freeMid,
                       socialJetlagMin: jetlag, nightCount: recent.count, freeNightCount: free.count,
                       usesFreeDays: usesFree,
                       series: recent.map { NightPoint(day: $0.wakeDay, midSleepSignedMin: $0.midSleepSignedMin,
                                                       isFreeDay: $0.isFreeDay) })
    }

    /// Time asleep when known, otherwise time in bed.
    private static func duration(_ n: SleepInsights.Night) -> Double { n.asleepMin ?? n.inBedMin }

    private static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func standardDeviation(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
    }
}
