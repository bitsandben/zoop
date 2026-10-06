import Foundation

// CycleCalendar.swift — a calendar estimate of the menstrual cycle from logged period starts alone.
//
// `CyclePhaseEngine` reads the cycle from skin temperature and needs weeks of nights before it says
// anything. This is the plain calendar method a period tracker uses from the first log: cycle length
// is the median gap between logged starts (21–40 days count; 28 until there are two), ovulation is
// placed 14 days before the next expected start, and the phase follows from the cycle day. It is an
// estimate for orientation, not contraception or diagnosis, and it never reads or writes a score.
// Days are whole local day numbers (days since the epoch in the user's calendar) so this stays pure.

public enum CycleCalendar {

    public enum Phase: String, Sendable {
        case menstrual, follicular, ovulatory, luteal
    }

    public struct Estimate: Equatable, Sendable {
        /// 1 on the day the last logged period started.
        public let cycleDay: Int
        public let cycleLength: Int
        public let periodLength: Int
        public let phase: Phase
        /// Day number of the next expected period start.
        public let nextPeriodStart: Int
        /// Days from today to the next expected start; negative when it is late.
        public let daysUntilNextPeriod: Int
        /// How many logged gaps the cycle length is based on (0 = the 28-day default).
        public let cyclesUsed: Int
        /// Cycle-day ranges of each phase, for drawing the cycle bar.
        public let ovulationDay: Int
    }

    public static let defaultCycleLength = 28
    public static let defaultPeriodLength = 5
    static let lutealLength = 14
    static let acceptedGaps = 21...40

    /// The estimate for `today`, or nil with no logged start on or before today.
    public static func estimate(periodStarts: [Int], today: Int,
                                periodLength: Int = defaultPeriodLength) -> Estimate? {
        let starts = Array(Set(periodStarts.filter { $0 <= today })).sorted()
        guard let last = starts.last else { return nil }
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }.filter { acceptedGaps.contains($0) }
        let length = gaps.isEmpty ? defaultCycleLength : median(gaps)
        let cycleDay = today - last + 1
        let next = last + length
        let ovulation = length - lutealLength
        let phase: Phase
        if cycleDay <= periodLength {
            phase = .menstrual
        } else if cycleDay < ovulation - 2 {
            phase = .follicular
        } else if cycleDay <= ovulation + 1 {
            phase = .ovulatory
        } else {
            phase = .luteal
        }
        return Estimate(cycleDay: cycleDay, cycleLength: length, periodLength: periodLength, phase: phase,
                        nextPeriodStart: next, daysUntilNextPeriod: next - today, cyclesUsed: gaps.count,
                        ovulationDay: ovulation)
    }

    /// How a calendar day relates to the logged cycles, for the month view.
    public struct DayInfo: Equatable, Sendable {
        public let phase: Phase
        /// True when the day is after today, so it is a projection rather than a record.
        public let predicted: Bool
        /// True on a period day that follows a logged start (not a projected one).
        public let loggedPeriod: Bool
    }

    /// The phase of any calendar day: inside a logged cycle it uses that cycle's real length (the gap to
    /// the next logged start), after the last start it projects cycles of the estimated length forward.
    /// nil before the first logged start.
    public static func dayInfo(_ day: Int, periodStarts: [Int], today: Int,
                               periodLength: Int = defaultPeriodLength) -> DayInfo? {
        let starts = Array(Set(periodStarts.filter { $0 <= today })).sorted()
        guard let first = starts.first, day >= first,
              let est = estimate(periodStarts: starts, today: today, periodLength: periodLength) else { return nil }
        var start: Int
        var length: Int
        var logged: Bool
        if let idx = starts.lastIndex(where: { $0 <= day }), idx < starts.count - 1 {
            start = starts[idx]
            length = starts[idx + 1] - start
            logged = true
        } else {
            let last = starts[starts.count - 1]
            let k = max(0, (day - last) / est.cycleLength)
            start = last + k * est.cycleLength
            length = est.cycleLength
            logged = k == 0
        }
        let cycleDay = day - start + 1
        let ovulation = length - lutealLength
        let phase: Phase
        if cycleDay <= periodLength {
            phase = .menstrual
        } else if cycleDay < ovulation - 2 {
            phase = .follicular
        } else if cycleDay <= ovulation + 1 {
            phase = .ovulatory
        } else {
            phase = .luteal
        }
        return DayInfo(phase: phase, predicted: day > today,
                       loggedPeriod: logged && phase == .menstrual && day <= today)
    }

    /// The window the next period is expected in: the estimate ± half the spread of the logged cycle
    /// lengths (1–4 days), or ± 2 days while there are fewer than two logged cycles.
    public static func nextPeriodWindow(periodStarts: [Int], today: Int) -> ClosedRange<Int>? {
        guard let e = estimate(periodStarts: periodStarts, today: today) else { return nil }
        let starts = Array(Set(periodStarts.filter { $0 <= today })).sorted()
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }.filter { acceptedGaps.contains($0) }
        let half: Int
        if gaps.count >= 2, let lo = gaps.min(), let hi = gaps.max() {
            half = min(4, max(1, Int((Double(hi - lo) / 2).rounded())))
        } else {
            half = 2
        }
        return (e.daysUntilNextPeriod - half)...(e.daysUntilNextPeriod + half)
    }

    static func median(_ values: [Int]) -> Int {
        let v = values.sorted()
        if v.count % 2 == 1 { return v[v.count / 2] }
        return Int((Double(v[v.count / 2 - 1] + v[v.count / 2]) / 2).rounded())
    }
}
