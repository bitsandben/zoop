import Foundation

/// A local calendar date (year/month/day), independent of `Calendar` so day-window rules stay explicit and
/// a library behaviour change can't silently move a day boundary. Converted via proleptic-Gregorian arithmetic.
public struct LocalCalendarDate: Hashable, Comparable, Sendable {

    /// Proleptic Gregorian year.
    public let year: Int

    /// Month, 1...12.
    public let month: Int

    /// Day of month, 1...31. Not validated; an out-of-range day is normalised by the day-number conversion.
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Builds the date `daysSinceEpoch` days after 1970-01-01.
    public init(daysSinceEpoch: Int) {
        // Howard Hinnant's civil_from_days (exact over the Int range, no calendar object); Swift division truncates toward zero as in C, which the era shifts assume.
        var z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        z -= era * 146_097
        let dayOfEra = z
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let d = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let m = monthPrime + (monthPrime < 10 ? 3 : -9)
        let y = yearOfEra + era * 400 + (m <= 2 ? 1 : 0)
        self.init(year: y, month: m, day: d)
    }

    /// Days from 1970-01-01 to this date, negative before it.
    public var daysSinceEpoch: Int {
        // Howard Hinnant's days_from_civil, the inverse of the initialiser above.
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The date as `YYYY-MM-DD`, also the day key this helper hands out.
    public var key: String {
        let y = year < 0 ? "-" + Self.pad(-year, 4) : Self.pad(year, 4)
        return "\(y)-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
    }

    /// The date `count` days after this one (negative moves backward).
    public func adding(days count: Int) -> LocalCalendarDate {
        LocalCalendarDate(daysSinceEpoch: daysSinceEpoch + count)
    }

    public static func < (lhs: LocalCalendarDate, rhs: LocalCalendarDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    /// Left-pads a non-negative number with zeroes without a (locale-aware) formatter.
    private static func pad(_ value: Int, _ width: Int) -> String {
        var s = String(value)
        while s.count < width { s = "0" + s }
        return s
    }
}

/// One local day as a half-open window, with the UTC offset in effect when it began.
public struct LocalDayWindow: Hashable, Sendable {

    public let date: LocalCalendarDate

    /// The first instant of the date.
    public let start: Date

    /// Start of the next date that exists in the zone, where this window ends: not always `start` + 24 h, and more than a day away when a date is skipped.
    public let nextStart: Date

    /// UTC offset at `start`, seconds east of UTC. Describes the window's start only: other times of day come from
    /// the zone, since a transition inside the window would make this wrong by an hour.
    public let utcOffsetSeconds: Int

    public init(date: LocalCalendarDate, start: Date, nextStart: Date, utcOffsetSeconds: Int) {
        self.date = date
        self.start = start
        self.nextStart = nextStart
        self.utcOffsetSeconds = utcOffsetSeconds
    }

    /// Window length: 23, 24 or 25 hours in the fixture zones, longer where a date is skipped.
    public var duration: TimeInterval {
        nextStart.timeIntervalSince(start)
    }
}

/// One entry of a backward run: a date that exists in the zone with its resolved start.
public struct LocalDayStart: Hashable, Sendable {

    public let date: LocalCalendarDate

    public let start: Date

    public init(date: LocalCalendarDate, start: Date) {
        self.date = date
        self.start = start
    }
}

/// When a local calendar date begins and ends in a time zone, from the zone's own rules.
///
/// Two answers coexist and this one is not yet the shipped one: `AnalyticsEngine.dayStartUtcSeconds` with
/// `AnalyticsEngine.dayString` (fixed 86,400 s blocks from a single UTC offset) is what every scored day
/// uses and is wrong by an hour beyond a DST transition; this type is called only by its own tests until a
/// switch-over lands. `LocalDayWindowsTests` pins both answers for America/New_York on 2025-10-19.
///
/// Ambiguous, skipped and non-existent cases follow the rules stated on each operation; the only platform
/// input is `TimeZone.secondsFromGMT(for:)`. Zone and reference instant are injectable so every rule is
/// provable without a device.
public struct LocalDayWindows: Sendable {

    /// The zone used when none is given: the auto-updating current zone. It is bound at construction; follow a
    /// device-zone change by constructing a new helper.
    public static var defaultTimeZone: TimeZone { TimeZone.autoupdatingCurrent }

    /// The reference instant used when none is given: the current `Date`.
    public static var defaultReferenceInstant: Date { Date() }

    /// The zone whose rules every operation reads.
    public let timeZone: TimeZone

    /// "Now": clamps the sleep read window and nothing else; no start, window, key or run depends on it.
    public let referenceInstant: Date

    public init(timeZone: TimeZone = LocalDayWindows.defaultTimeZone,
                referenceInstant: Date = LocalDayWindows.defaultReferenceInstant) {
        self.timeZone = timeZone
        self.referenceInstant = referenceInstant
    }

    /// Seconds either side of a local midnight probed for offsets; far more than a transition needs, far less than the gap between transitions.
    private static let probeWindow: Int64 = 2 * 86_400

    /// The first instant on `date` in this zone, or nil when the zone has no instant on that date. Local midnight
    /// existing once is the start; twice, the earlier; not at all, the instant the clocks jumped to (if that
    /// lands on a later date the date never happened). Assumes at most one offset change within two days of
    /// the midnight. Independent of `referenceInstant`.
    public func start(of date: LocalCalendarDate) -> Date? {
        let localMidnight = Int64(date.daysSinceEpoch) * 86_400
        let offsetBefore = offsetSeconds(atEpochSeconds: localMidnight - Self.probeWindow)
        let offsetAfter = offsetSeconds(atEpochSeconds: localMidnight + Self.probeWindow)

        var candidates = [localMidnight - Int64(offsetBefore), localMidnight - Int64(offsetAfter)].sorted()
        if candidates.count == 2 && candidates[0] == candidates[1] { candidates.removeLast() }
        // An instant maps to this midnight when reading it in the zone gives that wall time back; ascending order yields the earlier of an ambiguous pair.
        for candidate in candidates
        where candidate + Int64(offsetSeconds(atEpochSeconds: candidate)) == localMidnight {
            return Date(timeIntervalSince1970: TimeInterval(candidate))
        }

        // Midnight fell in a gap: the first existing instant is the jump instant, which belongs to this date only if it still reads as this date.
        guard offsetBefore != offsetAfter else { return nil }
        let jump = transitionEpochSeconds(around: localMidnight, offsetBefore: offsetBefore)
        guard localDate(ofEpochSeconds: jump) == date else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(jump))
    }

    /// The half-open window `[start, nextStart)` of `date`, or nil when the date does not exist. `nextStart` is the
    /// next date that exists, so a window before a skipped date spans more than a day.
    public func window(of date: LocalCalendarDate) -> LocalDayWindow? {
        guard let dayStart = start(of: date) else { return nil }
        var next = date.adding(days: 1)
        var nextStart: Date?
        // No zone has skipped more than a couple of consecutive dates; the bound stops a corrupt zone becoming an unbounded walk.
        for _ in 0..<8 {
            if let candidate = start(of: next) {
                nextStart = candidate
                break
            }
            next = next.adding(days: 1)
        }
        guard let end = nextStart else { return nil }
        return LocalDayWindow(date: date,
                              start: dayStart,
                              nextStart: end,
                              utcOffsetSeconds: offsetSeconds(at: dayStart))
    }

    /// The start of the local day containing `instant`.
    public func startOfDay(containing instant: Date) -> Date {
        let date = localDate(of: instant)
        // `instant` lies on `date` by construction; the fallback is unreachable and only keeps the operation total.
        guard let start = start(of: date) else { return instant }
        return start
    }

    /// The `YYYY-MM-DD` key of the local day containing `instant`; agrees with the window by construction.
    public func dayKey(for instant: Date) -> String {
        localDate(of: instant).key
    }

    /// The local calendar date containing `instant`.
    public func localDate(of instant: Date) -> LocalCalendarDate {
        localDate(ofEpochSeconds: Int64(instant.timeIntervalSince1970.rounded(.down)))
    }

    /// Up to `count` consecutive local dates ending at `date`, oldest first, each with its start. Skipped dates are
    /// omitted, so the run can be shorter; if `date` doesn't exist, the newest entry is the latest earlier date.
    public func backwardRun(endingAt date: LocalCalendarDate, count: Int) -> [LocalDayStart] {
        guard count > 0 else { return [] }
        let endDay = date.daysSinceEpoch
        var run: [LocalDayStart] = []
        run.reserveCapacity(count)
        for back in stride(from: count - 1, through: 0, by: -1) {
            let day = LocalCalendarDate(daysSinceEpoch: endDay - back)
            if let start = start(of: day) {
                run.append(LocalDayStart(date: day, start: start))
            }
        }
        return run
    }

    /// End of the sleep read window of `date`: the earlier of its next start and the reference instant, so today
    /// never reaches the future. Nil when the date doesn't exist. A date starting after the reference instant
    /// yields an empty, inverted window; callers must not ask for a future date.
    public func sleepReadWindowEnd(of date: LocalCalendarDate) -> Date? {
        guard let window = window(of: date) else { return nil }
        return min(window.nextStart, referenceInstant)
    }

    /// The UTC offset in effect at `instant`, seconds east of UTC.
    public func offsetSeconds(at instant: Date) -> Int {
        timeZone.secondsFromGMT(for: instant)
    }

    /// The time-zone database version this platform can observe, or nil (Linux Foundation has no equivalent; a faked value would claim an unchecked fact).
    public static var observedTimeZoneDataVersion: String? {
        #if canImport(Darwin)
        return NSTimeZone.timeZoneDataVersion
        #else
        return nil
        #endif
    }

    /// The note attached when a fixture value moves, naming the version recorded in the oracle and the one observed.
    /// A version difference alone is not a failure (fixtures are stable); the note only makes a value difference
    /// explicable. Pure so it can be asserted; an unobservable version is stated in place of one.
    public static func timeZoneDataVersionNote(recorded: String, observed: String?) -> String {
        let observedText = observed.map { "observes \($0)" }
            ?? "cannot observe its own time-zone database version"
        return "time-zone database version: the oracle records \(recorded); this platform \(observedText)."
    }

    private func offsetSeconds(atEpochSeconds seconds: Int64) -> Int {
        timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func localDate(ofEpochSeconds seconds: Int64) -> LocalCalendarDate {
        let localSeconds = seconds + Int64(offsetSeconds(atEpochSeconds: seconds))
        var days = localSeconds / 86_400
        if localSeconds < 0 && localSeconds % 86_400 != 0 { days -= 1 }
        return LocalCalendarDate(daysSinceEpoch: Int(days))
    }

    /// The instant the offset changes near `localMidnight`, found by bisecting the probe window.
    private func transitionEpochSeconds(around localMidnight: Int64, offsetBefore: Int) -> Int64 {
        var low = localMidnight - Self.probeWindow
        var high = localMidnight + Self.probeWindow
        while high - low > 1 {
            let mid = low + (high - low) / 2
            if offsetSeconds(atEpochSeconds: mid) == offsetBefore {
                low = mid
            } else {
                high = mid
            }
        }
        return high
    }
}
