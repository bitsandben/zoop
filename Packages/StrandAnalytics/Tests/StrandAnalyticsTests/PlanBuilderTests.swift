import Foundation
import XCTest
@testable import StrandAnalytics

final class PlanInterviewTests: XCTestCase {

    func testPlanInterviewWalksEverySlotInOrderThenCompletes() {
        var state = PlanInterview.State(kind: .plan)
        XCTAssertEqual(state.current, .goal)
        var asked: [PlanInterview.Slot] = []
        while let slot = state.current {
            asked.append(slot)
            XCTAssertEqual(state.record("answer \(slot.rawValue)"), slot)
        }
        XCTAssertEqual(asked, [.goal, .horizon, .days, .session, .timeOfDay, .experience, .limitations])
        XCTAssertTrue(state.isComplete)
        XCTAssertNil(state.record("extra"))
        XCTAssertEqual(state.answeredCount, 7)
    }

    func testRoutineInterviewHasFourSlotsAndSkipReadsAsNoPreference() {
        var state = PlanInterview.State(kind: .routine)
        state.record("Oberkörper")
        state.record("  ")
        XCTAssertEqual(state.current, .duration)
        XCTAssertTrue(state.answersBlock.contains("equipment"))
        XCTAssertTrue(state.answersBlock.contains("no preference"))
    }

    func testReopenClearsTheSlotAndLaterOnes() {
        var state = PlanInterview.State(kind: .routine)
        ["a", "b", "c", "d"].forEach { state.record($0) }
        state.reopen(.equipment)
        XCTAssertEqual(state.current, .equipment)
        XCTAssertEqual(state.answeredCount, 1)
    }
}

final class WorkoutHistorySummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountsPerSportWithMedianMinutesInsideTheWindow() {
        let base = Int(now.timeIntervalSince1970)
        let sessions = [
            WorkoutHistorySummary.Session(sport: "Walking", durationS: 1800, startTs: base - 86_400),
            .init(sport: "Walking", durationS: 2400, startTs: base - 2 * 86_400),
            .init(sport: "Walking", durationS: 3000, startTs: base - 3 * 86_400),
            .init(sport: "Pool swim", durationS: 2400, startTs: base - 4 * 86_400),
            .init(sport: "Walking", durationS: 9999, startTs: base - 200 * 86_400),
        ]
        let s = WorkoutHistorySummary.make(sessions: sessions, now: now, isStrength: { $0 == "Strength" })
        XCTAssertEqual(s.totalSessions, 4)
        XCTAssertEqual(s.sports.first?.name, "Walking")
        XCTAssertEqual(s.sports.first?.typicalMinutes, 40)
        XCTAssertEqual(s.strengthSessions, 0)
        XCTAssertEqual(s.suggestedLevel, .beginner)
        XCTAssertTrue(s.promptLine.contains("Walking 3× (~40 min)"))
        XCTAssertTrue(s.promptLine.contains("no structured strength training"))
    }

    func testEmptyHistoryLine() {
        let s = WorkoutHistorySummary.make(sessions: [], now: now, isStrength: { _ in false })
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.promptLine, "No workouts recorded in the last 90 days.")
    }
}

final class CoachReplyGuardTests: XCTestCase {

    func testKeepsAcknowledgementAndQuestionWhenTooManySentences() {
        let raw = "Super Ziel! Kraft ist wichtig. Mobility auch. Wie viele Tage pro Woche kannst du trainieren?"
        XCTAssertEqual(CoachReplyGuard.shorten(raw),
                       "Super Ziel! Wie viele Tage pro Woche kannst du trainieren?")
    }

    func testStripsThinkingAndMarkdown() {
        let raw = "<think>user wants strength</think>\n### Klasse\n- **Gut** gemacht. Was ist dein Ziel?"
        let split = CoachReplyGuard.splitThinking(raw)
        XCTAssertEqual(split.thinking, "user wants strength")
        XCTAssertEqual(CoachReplyGuard.shorten(raw), "Klasse Gut gemacht. Was ist dein Ziel?")
    }

    func testCharacterCapPrefersTheQuestion() {
        let long = String(repeating: "Sehr schön ", count: 20) + "gemacht. Wann trainierst du am liebsten?"
        let out = CoachReplyGuard.shorten(long, maxChars: 60)
        XCTAssertEqual(out, "Wann trainierst du am liebsten?")
        let single = String(repeating: "wort ", count: 80)
        XCTAssertLessThanOrEqual(CoachReplyGuard.shorten(single).count, 220)
        XCTAssertTrue(CoachReplyGuard.shorten(single).hasSuffix("…"))
    }
}

final class PlanWeeklyReviewTests: XCTestCase {
    private let strength = PlanSession(id: "a", weekday: 2, title: "Kraft A", sport: "Strength", minutes: 45, programId: "p1")
    private let hyrox = PlanSession(id: "b", weekday: 4, title: "Hyrox", sport: "HIIT", minutes: 45)
    private let walk = PlanSession(id: "c", weekday: 6, title: "Walk", sport: "Walking", minutes: 30)

    func testLowRecoveryShortensTheLongestSession() {
        let signals = PlanWeeklyReview.Signals(recentRecovery: [70, 30, 25, 31, 20], weeksActive: 5)
        let rev = PlanWeeklyReview.review(sessions: [strength, hyrox, walk], signals: signals, weekKey: "2026-10-19")
        XCTAssertEqual(rev?.items.first, .init(change: .shorten(sessionId: "b", from: 45, to: 30), reason: .lowRecovery(days: 4)))
        // Fatigue blocks progression.
        XCTAssertFalse(rev?.items.contains { if case .addSet = $0.change { return true }; return false } ?? true)
    }

    func testMissedTwiceMovesToTheMostUsedFreeWeekday() {
        let signals = PlanWeeklyReview.Signals(adherence: ["a": [true, false, false]],
                                               activeWeekdays: [2: 5, 3: 4, 4: 9, 7: 1])
        let rev = PlanWeeklyReview.review(sessions: [strength, hyrox], signals: signals, weekKey: "w")
        XCTAssertEqual(rev?.items, [.init(change: .move(sessionId: "a", from: 2, to: 3), reason: .missedTwice)])
        XCTAssertEqual(PlanWeeklyReview.apply(rev!.items, to: [strength]).first?.weekday, 3)
    }

    func testSteadyWeeksProgressStrengthBySetAndCardioByMinutes() {
        let signals = PlanWeeklyReview.Signals(adherence: ["a": [true, true, true], "b": [true, true, true], "c": [true, true, true]],
                                               recentRecovery: [70, 72], load: .optimal, weeksActive: 3)
        let rev = PlanWeeklyReview.review(sessions: [strength, hyrox, walk], signals: signals, weekKey: "w")
        XCTAssertEqual(rev?.items, [
            .init(change: .addSet(sessionId: "a", programId: "p1"), reason: .steady(weeks: 3)),
            .init(change: .lengthen(sessionId: "b", from: 45, to: 50), reason: .steady(weeks: 3)),
        ])
    }

    func testHighLoadShortensAndNothingElseIsNil() {
        XCTAssertNil(PlanWeeklyReview.review(sessions: [walk], signals: .init(), weekKey: "w"))
        let rev = PlanWeeklyReview.review(sessions: [walk], signals: .init(load: .high, weeksActive: 9), weekKey: "w")
        XCTAssertEqual(rev?.items, [.init(change: .shorten(sessionId: "c", from: 30, to: 25), reason: .loadHigh)])
    }

    func testRevisionRoundTripsThroughJSON() throws {
        let rev = PlanWeeklyReview.Revision(weekKey: "w", items: [.init(change: .move(sessionId: "a", from: 2, to: 3), reason: .lowHRV(days: 4))])
        let data = try JSONEncoder().encode(rev)
        XCTAssertEqual(try JSONDecoder().decode(PlanWeeklyReview.Revision.self, from: data), rev)
    }
}

final class LiftProgressionTests: XCTestCase {
    private let target = LiftProgression.Target(sets: 3, repsLow: 8, repsHigh: 10, weightKg: 60)

    private func session(_ reps: Int, _ kg: Double?, rpe: Double? = 8) -> [LiftProgression.Performed] {
        Array(repeating: .init(reps: reps, weightKg: kg, rpe: rpe), count: 3)
    }

    func testTwoCleanSessionsAddWeight() {
        let a = LiftProgression.advise(target: target, sessions: [session(10, 60), session(10, 60)], lowerBody: false)
        XCTAssertEqual(a?.step, .addWeight(from: 60, to: 62.5))
        XCTAssertEqual(a?.next.weightKg, 62.5)
        let legs = LiftProgression.advise(target: target, sessions: [session(10, 100), session(10, 100)], lowerBody: true)
        XCTAssertEqual(legs?.step, .addWeight(from: 100, to: 105))
    }

    func testHardRpeOrOneSessionHolds() {
        XCTAssertEqual(LiftProgression.advise(target: target, sessions: [session(10, 60), session(10, 60, rpe: 9)],
                                              lowerBody: false)?.step, .hold)
        XCTAssertEqual(LiftProgression.advise(target: target, sessions: [session(10, 60)], lowerBody: false)?.step, .hold)
        XCTAssertNil(LiftProgression.advise(target: target, sessions: [], lowerBody: false))
    }

    func testTwoMissedSessionsDeload() {
        let a = LiftProgression.advise(target: target, sessions: [session(5, 60), session(6, 60)], lowerBody: false)
        XCTAssertEqual(a?.step, .deload(from: 60, to: 53.75))
    }

    func testBodyweightAddsRepsThenHarderVariant() {
        let bw = LiftProgression.Target(sets: 3, repsLow: 10, repsHigh: nil, weightKg: nil)
        XCTAssertEqual(LiftProgression.advise(target: bw, sessions: [session(10, nil), session(10, nil)], lowerBody: false)?.step,
                       .addReps(to: 11))
        let high = LiftProgression.Target(sets: 3, repsLow: 20, repsHigh: nil, weightKg: nil)
        XCTAssertEqual(LiftProgression.advise(target: high, sessions: [session(20, nil), session(20, nil)], lowerBody: false)?.step,
                       .harderVariant(repsTo: 10))
    }

    func testRecoveryActionsSkipAtMostHalf() {
        let actions = LiftProgression.recoveryActions(groups: [.chest, .chest, .lats, .quads],
                                                      recovered: [.chest: 30, .lats: 90, .quads: 45])
        XCTAssertEqual(actions, [.skip, .skip, .keep, .reduceSet])
    }
}
