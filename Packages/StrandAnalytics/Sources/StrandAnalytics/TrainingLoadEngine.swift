import Foundation

/// Long-horizon training-load model using exponentially weighted daily load. It sits beside Foster
/// monotony WITHOUT feeding the Readiness level. Keeps chronic load (CTL), acute load (ATL) and their
/// difference (TSB / "form") in the SAME units as the supplied daily load; Zoop supplies daily
/// Effort/strain, so these values are not TRIMP and must not be relabelled as such.
///
/// alpha = 1 - exp(-1 / tauDays); state[t] = state[t-1] + alpha * (load[t] - state[t-1]); TSB = CTL - ATL.
/// Time constants are 42 days (chronic) and 7 days (acute). The first `primeDays` contiguous observations
/// are averaged to seed both states, avoiding zero-seeding bias.
///
/// Missing days are NEVER filled with zero: a real rest day must be a row whose load is 0; a missing row
/// or nil load breaks the contiguous suffix the model runs over.
public enum TrainingLoadEngine {
    public struct Configuration: Sendable, Equatable {
        public let chronicTimeConstantDays: Double
        public let acuteTimeConstantDays: Double
        public let primeDays: Int
        public let minimumDays: Int
        public let establishedDays: Int

        public init(chronicTimeConstantDays: Double = 42,
                    acuteTimeConstantDays: Double = 7,
                    primeDays: Int = 7,
                    minimumDays: Int = 14,
                    establishedDays: Int = 42) {
            self.chronicTimeConstantDays = chronicTimeConstantDays
            self.acuteTimeConstantDays = acuteTimeConstantDays
            self.primeDays = primeDays
            self.minimumDays = minimumDays
            self.establishedDays = establishedDays
        }

        public static let standard = Configuration()

        fileprivate var isValid: Bool {
            chronicTimeConstantDays.isFinite && chronicTimeConstantDays > 0
                && acuteTimeConstantDays.isFinite && acuteTimeConstantDays > 0
                && primeDays > 0
                && minimumDays >= primeDays
                && establishedDays >= minimumDays
        }
    }

    /// Calendar-day input. `load == nil` means no usable observation; `load == 0` is a measured rest day.
    public struct DailyLoad: Sendable, Equatable {
        public let day: String       // strict Gregorian YYYY-MM-DD
        public let load: Double?

        public init(day: String, load: Double?) {
            self.day = day
            self.load = load
        }
    }

    public enum State: String, Sendable, Equatable, Codable {
        /// No trustworthy model yet; see `unavailableReason` and `contiguousDays`.
        case unavailable
        /// Minimum history present, but the chronic state is still calibrating.
        case building
        /// At least the established-history window is contiguous and observed.
        case established
    }

    public enum UnavailableReason: String, Sendable, Equatable, Codable {
        case noData
        case missingTargetDay
        case notEnoughContiguousDays
        case invalidConfiguration
        case invalidDay
        case duplicateDay
        case invalidLoad
    }

    /// One chart-ready modeled day. The first point is the final priming day (no CTL/ATL before it).
    public struct Point: Sendable, Equatable, Codable {
        public let day: String
        public let load: Double
        public let chronicLoad: Double
        public let acuteLoad: Double
        public let balance: Double

        public var ctl: Double { chronicLoad }
        public var atl: Double { acuteLoad }
        public var tsb: Double { balance }
    }

    public struct Result: Sendable, Equatable {
        public let state: State
        public let unavailableReason: UnavailableReason?
        public let contiguousDays: Int
        public let startDay: String?
        public let endDay: String?
        public let points: [Point]

        /// Latest modeled chronic load (CTL).
        public var chronicLoad: Double? { points.last?.chronicLoad }
        /// Latest modeled acute load (ATL).
        public var acuteLoad: Double? { points.last?.acuteLoad }
        /// Latest CTL - ATL balance (TSB / form).
        public var balance: Double? { points.last?.balance }

        public var ctl: Double? { chronicLoad }
        public var atl: Double? { acuteLoad }
        public var tsb: Double? { balance }
        public var isAvailable: Bool { state != .unavailable }
    }

    /// Evaluates the latest day in the input, or an explicit target day; inputs may be in any order. Only
    /// the longest fully observed CONTIGUOUS suffix ending on the target is modeled; older history before
    /// a gap is ignored rather than compressing calendar time or inventing zero load.
    public static func evaluate(days: [DailyLoad],
                                through targetDay: String? = nil,
                                configuration: Configuration = .standard) -> Result {
        guard configuration.isValid else {
            return unavailable(.invalidConfiguration, contiguousDays: 0)
        }
        guard !days.isEmpty else { return unavailable(.noData, contiguousDays: 0) }

        var parsed: [(day: String, ordinal: Int, load: Double?)] = []
        parsed.reserveCapacity(days.count)
        var seen = Set<Int>()
        for item in days {
            guard let ordinal = dayOrdinal(item.day) else {
                return unavailable(.invalidDay, contiguousDays: 0)
            }
            guard seen.insert(ordinal).inserted else {
                return unavailable(.duplicateDay, contiguousDays: 0)
            }
            if let load = item.load, (!load.isFinite || load < 0) {
                return unavailable(.invalidLoad, contiguousDays: 0)
            }
            parsed.append((item.day, ordinal, item.load))
        }
        parsed.sort { $0.ordinal < $1.ordinal }

        let targetOrdinal: Int
        if let targetDay {
            guard let ordinal = dayOrdinal(targetDay) else {
                return unavailable(.invalidDay, contiguousDays: 0)
            }
            targetOrdinal = ordinal
        } else {
            targetOrdinal = parsed.last!.ordinal
        }

        guard let targetIndex = parsed.lastIndex(where: { $0.ordinal == targetOrdinal }) else {
            return unavailable(.missingTargetDay, contiguousDays: 0)
        }

        // Walk back from the target to the first calendar gap or unobserved load; a stored zero stays valid.
        var suffixReversed: [(day: String, ordinal: Int, load: Double)] = []
        var expectedOrdinal = targetOrdinal
        var index = targetIndex
        while index >= 0 {
            let item = parsed[index]
            guard item.ordinal == expectedOrdinal, let load = item.load else { break }
            suffixReversed.append((item.day, item.ordinal, load))
            expectedOrdinal -= 1
            if index == 0 { break }
            index -= 1
        }
        let ordered = Array(suffixReversed.reversed())
        let contiguousDays = ordered.count
        guard contiguousDays >= configuration.minimumDays else {
            return unavailable(.notEnoughContiguousDays,
                               contiguousDays: contiguousDays,
                               startDay: ordered.first?.day,
                               endDay: ordered.last?.day)
        }

        let seedWindow = ordered.prefix(configuration.primeDays)
        let seed = seedWindow.reduce(0.0) { $0 + $1.load } / Double(configuration.primeDays)
        let alphaChronic = 1 - exp(-1 / configuration.chronicTimeConstantDays)
        let alphaAcute = 1 - exp(-1 / configuration.acuteTimeConstantDays)

        var chronic = seed
        var acute = seed
        var points: [Point] = []
        points.reserveCapacity(ordered.count - configuration.primeDays + 1)

        let seedDay = ordered[configuration.primeDays - 1]
        points.append(Point(day: seedDay.day, load: seedDay.load,
                            chronicLoad: chronic, acuteLoad: acute, balance: chronic - acute))

        for item in ordered.dropFirst(configuration.primeDays) {
            chronic += alphaChronic * (item.load - chronic)
            acute += alphaAcute * (item.load - acute)
            points.append(Point(day: item.day, load: item.load,
                                chronicLoad: chronic, acuteLoad: acute, balance: chronic - acute))
        }

        return Result(
            state: contiguousDays >= configuration.establishedDays ? .established : .building,
            unavailableReason: nil,
            contiguousDays: contiguousDays,
            startDay: ordered.first?.day,
            endDay: ordered.last?.day,
            points: points
        )
    }

    /// Convenience for already-dense load arrays; day labels are synthetic but deterministic.
    public static func evaluateDense(_ loads: [Double],
                                     configuration: Configuration = .standard) -> Result {
        let baseOrdinal = dayOrdinal("2000-01-01")!
        let days = loads.enumerated().map { offset, load in
            DailyLoad(day: LocalCalendarDate(daysSinceEpoch: baseOrdinal + offset).key, load: load)
        }
        return evaluate(days: days, configuration: configuration)
    }

    private static func unavailable(_ reason: UnavailableReason,
                                    contiguousDays: Int,
                                    startDay: String? = nil,
                                    endDay: String? = nil) -> Result {
        Result(state: .unavailable, unavailableReason: reason,
               contiguousDays: contiguousDays, startDay: startDay, endDay: endDay, points: [])
    }

    // MARK: - Strict, timezone-free Gregorian calendar helpers

    /// Gregorian date to day ordinal (Howard Hinnant's civil-date transform); integer-only and timezone-free.
    private static func dayOrdinal(_ value: String) -> Int? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year >= 1, (1...12).contains(month) else { return nil }
        let daysInMonth: [Int] = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...daysInMonth[month - 1]).contains(day) else { return nil }

        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = floorDiv(adjustedYear, 400)
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }
}
