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

    static func median(_ values: [Int]) -> Int {
        let v = values.sorted()
        if v.count % 2 == 1 { return v[v.count / 2] }
        return Int((Double(v[v.count / 2 - 1] + v[v.count / 2]) / 2).rounded())
    }
}
