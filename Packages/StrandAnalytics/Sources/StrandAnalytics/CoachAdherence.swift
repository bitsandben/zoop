import Foundation

// CoachAdherence.swift - planned training days against what was actually done.
//
// The coach nudges "remember your routine" only after the user skipped planned sessions more than
// once. The app lists the window's days with what the weekly plan held and whether any training was
// logged; this file only counts, so the rule is testable without a calendar or a database.

public enum CoachAdherence {

    /// How far back the coach looks: two weeks covers two runs of a weekly plan.
    public static let windowDays = 14

    public struct Day: Equatable, Sendable {
        /// yyyy-MM-dd local day.
        public let day: String
        /// Programs the weekly plan held for that day (empty on a rest day).
        public let plannedProgramIds: [String]
        /// Any workout or Lift Log session was recorded that day.
        public let trained: Bool

        public init(day: String, plannedProgramIds: [String], trained: Bool) {
            self.day = day
            self.plannedProgramIds = plannedProgramIds
            self.trained = trained
        }
    }

    public struct Result: Equatable, Sendable {
        /// Planned days in the window.
        public let planned: Int
        /// Planned days with no training at all.
        public let missed: Int
        /// The first program of the most recent missed day.
        public let missedProgramId: String?

        public init(planned: Int, missed: Int, missedProgramId: String?) {
            self.planned = planned
            self.missed = missed
            self.missedProgramId = missedProgramId
        }
    }

    /// Nil when nothing was planned in the window (no plan, or a plan too new to judge).
    public static func evaluate(_ days: [Day]) -> Result? {
        let planned = days.filter { !$0.plannedProgramIds.isEmpty }.sorted { $0.day < $1.day }
        guard !planned.isEmpty else { return nil }
        let missed = planned.filter { !$0.trained }
        return Result(planned: planned.count, missed: missed.count,
                      missedProgramId: missed.last?.plannedProgramIds.first)
    }
}
