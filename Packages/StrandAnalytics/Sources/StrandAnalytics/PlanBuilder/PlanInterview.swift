import Foundation

// MARK: - Guided plan / routine interview
//
// The conversational plan builder asks a FIXED sequence of questions. The model never decides what to
// ask next — it only phrases the question this state machine hands it — so the interview always ends,
// always covers the same ground, and works offline with template questions when no provider answers.

public enum PlanInterview {

    /// What the conversation builds.
    public enum Kind: String, Sendable, Codable, Equatable {
        case plan, routine
    }

    /// One question of the interview.
    public enum Slot: String, CaseIterable, Sendable, Codable, Hashable {
        // Training plan
        case goal, horizon, days, session, timeOfDay, experience, limitations
        // Single routine
        case focus, equipment, duration, level

        /// What the slot asks, in English, for the model that phrases the question.
        public var brief: String {
            switch self {
            case .goal: return "their main training goal"
            case .horizon: return "whether the plan runs open-ended or towards a target date (which one)"
            case .days: return "how many days per week they can train and on which weekdays"
            case .session: return "how long one session may take and where they train (home, gym, outdoors, equipment)"
            case .timeOfDay: return "what time of day they prefer to train"
            case .experience: return "their training experience level"
            case .limitations: return "any injuries or physical limitations to respect"
            case .focus: return "which muscles or body area the routine should focus on"
            case .equipment: return "which equipment they have (e.g. pull-up bar, bands, dumbbells, full gym)"
            case .duration: return "how many minutes the routine may take"
            case .level: return "their strength-training experience level"
            }
        }
    }

    public static func slots(for kind: Kind) -> [Slot] {
        switch kind {
        case .plan: return [.goal, .horizon, .days, .session, .timeOfDay, .experience, .limitations]
        case .routine: return [.focus, .equipment, .duration, .level]
        }
    }

    /// The interview so far. Answers are free text; a skipped question is recorded as an empty answer.
    public struct State: Equatable, Sendable, Codable {
        public let kind: Kind
        public private(set) var answers: [Slot: String] = [:]

        public init(kind: Kind) { self.kind = kind }

        /// The question to ask next; nil once every slot has an answer.
        public var current: Slot? { PlanInterview.slots(for: kind).first { answers[$0] == nil } }
        public var isComplete: Bool { current == nil }
        public var answeredCount: Int { answers.count }
        public var totalCount: Int { PlanInterview.slots(for: kind).count }

        /// Records `answer` for the current slot and returns that slot; nil when already complete.
        @discardableResult
        public mutating func record(_ answer: String) -> Slot? {
            guard let slot = current else { return nil }
            answers[slot] = String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            return slot
        }

        /// Sets every answer at once, from the native form. Slots outside this kind are ignored.
        public mutating func fill(_ values: [Slot: String]) {
            let valid = Set(PlanInterview.slots(for: kind))
            for (slot, value) in values where valid.contains(slot) {
                answers[slot] = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            }
        }

        /// Clears `slot` and every later one, so the interview resumes there.
        public mutating func reopen(_ slot: Slot) {
            let order = PlanInterview.slots(for: kind)
            guard let index = order.firstIndex(of: slot) else { return }
            for later in order[index...] { answers[later] = nil }
        }

        /// The answers as "brief: answer" lines in interview order, for the final request.
        public var answersBlock: String {
            PlanInterview.slots(for: kind).compactMap { slot in
                guard let answer = answers[slot] else { return nil }
                return "- \(slot.brief): \(answer.isEmpty ? "no preference" : answer)"
            }.joined(separator: "\n")
        }
    }
}
