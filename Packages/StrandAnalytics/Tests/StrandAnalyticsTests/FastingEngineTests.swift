import XCTest
@testable import StrandAnalytics

final class FastingEngineTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// 2026-03-10 00:00 Berlin, plus hours.
    private func t(_ day: Int, _ hour: Double) -> Date {
        let base = cal.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        return cal.date(byAdding: .day, value: day, to: base)!.addingTimeInterval(hour * 3600)
    }

    private func fast(_ id: String, _ start: Date, _ end: Date?, goalHours: Double = 16) -> FastingInterval {
        FastingInterval(id: id, start: start, end: end, goal: goalHours * 3600)
    }

    // MARK: Plans

    func testPresetsCoverRequestedPlans() {
        XCTAssertEqual(FastingPlan.presets.map(\.id), ["12:12", "14:10", "16:8", "18:6", "20:4", "omad"])
        XCTAssertEqual(FastingPlan.sixteen.eatingHours, 8)
        XCTAssertEqual(FastingPlan.omad.eatingHours, 1)
    }

    func testCustomPlanIsClampedAndResolved() {
        XCTAssertEqual(FastingPlan.custom(hours: 3).fastingHours, 10)
        XCTAssertEqual(FastingPlan.custom(hours: 200).fastingHours, 48)
        XCTAssertEqual(FastingPlan.resolve(id: "custom", customHours: 15).fastingHours, 15)
        XCTAssertEqual(FastingPlan.resolve(id: "18:6", customHours: 15), .eighteen)
        XCTAssertEqual(FastingPlan.resolve(id: "unknown", customHours: 15), .defaultPlan)
    }

    // MARK: Status and phases

    func testStatusTracksElapsedAgainstGoal() {
        let f = fast("a", t(0, 20), nil)
        let mid = FastingEngine.status(of: f, now: t(1, 4))       // 8 h of 16
        XCTAssertEqual(mid.progress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.remaining, 8 * 3600, accuracy: 1e-6)
        XCTAssertFalse(mid.goalReached)
        XCTAssertEqual(mid.phase, .fasted)
        XCTAssertEqual(mid.goalDate, t(1, 12))

        let over = FastingEngine.status(of: f, now: t(1, 15))     // 19 h
        XCTAssertEqual(over.progress, 1)
        XCTAssertEqual(over.remaining, 0)
        XCTAssertTrue(over.goalReached)
        XCTAssertEqual(over.phase, .extended)
    }

    func testPhaseBandsAreElapsedTimeOnly() {
        XCTAssertEqual(FastingPhase.at(elapsed: 0), .afterMeal)
        XCTAssertEqual(FastingPhase.at(elapsed: 3.99 * 3600), .afterMeal)
        XCTAssertEqual(FastingPhase.at(elapsed: 4 * 3600), .fasted)
        XCTAssertEqual(FastingPhase.at(elapsed: 12 * 3600), .long)
        XCTAssertEqual(FastingPhase.at(elapsed: 18 * 3600), .extended)
        XCTAssertNil(FastingPhase.extended.next)
    }

    func testMarkersFallInsideGoal() {
        let m16 = FastingEngine.markerFractions(goal: 16 * 3600)
        XCTAssertEqual(m16.map(\.hours), [12])
        XCTAssertEqual(m16[0].fraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(FastingEngine.markerFractions(goal: 23 * 3600).map(\.hours), [12, 16, 18, 20])
        XCTAssertTrue(FastingEngine.markerFractions(goal: 12 * 3600).isEmpty)
    }

    // MARK: Validation (backdating)

    func testValidationRejectsImpossibleEdits() {
        let now = t(2, 12)
        let other = fast("o", t(1, 20), t(2, 10))
        XCTAssertEqual(FastingEngine.validate(start: t(0, 20), end: t(1, 12), now: now, others: [other]), .ok)
        XCTAssertEqual(FastingEngine.validate(start: t(1, 12), end: t(1, 11), now: now, others: []), .endBeforeStart)
        XCTAssertEqual(FastingEngine.validate(start: t(2, 13), end: nil, now: now, others: []), .inFuture)
        XCTAssertEqual(FastingEngine.validate(start: t(-3, 0), end: t(1, 1), now: now, others: []), .tooLong)
        XCTAssertEqual(FastingEngine.validate(start: t(2, 8), end: nil, now: now, others: [other]), .overlaps)
        // Backdating a start to an earlier evening while nothing else overlaps is fine.
        XCTAssertEqual(FastingEngine.validate(start: t(2, 11), end: nil, now: now, others: [other]), .ok)
    }

    // MARK: Week, streak, consistency

    func testWeekAttributesFastToItsEndDay() {
        let now = t(6, 14)
        let fasts = [
            fast("a", t(4, 20), t(5, 13)),          // 17 h, ends day 5: met
            fast("b", t(5, 21), t(6, 9)),           // 12 h, ends day 6: missed 16 h goal
            fast("c", t(6, 10), nil, goalHours: 2), // running 4 h, met already
        ]
        let week = FastingEngine.week(fasts, now: now, calendar: cal)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.dayStart, t(6, 0))
        XCTAssertEqual(week[5].fasted, 17 * 3600, accuracy: 1e-6)
        XCTAssertTrue(week[5].met)
        // Day 6 keeps its longest fast (the finished 12 h one), not the running 4 h one.
        XCTAssertEqual(week[6].fasted, 12 * 3600, accuracy: 1e-6)
        XCTAssertFalse(week[6].met)
        XCTAssertNil(week[0].goal)
    }

    func testStreakCountsBackAndTreatsOpenTodayAsPending() {
        let fasts = (1...4).map { d in fast("f\(d)", t(d - 1, 20), t(d, 13)) }   // met days 1…4
        XCTAssertEqual(FastingEngine.streak(fasts, now: t(4, 18), calendar: cal), 4)
        // Day 5 is open: still 4.
        XCTAssertEqual(FastingEngine.streak(fasts, now: t(5, 9), calendar: cal), 4)
        // Day 5 ended without a fast: broken.
        XCTAssertEqual(FastingEngine.streak(fasts, now: t(6, 9), calendar: cal), 0)
        // A gap in the middle stops the count at the gap.
        let gapped = fasts.filter { $0.id != "f2" }
        XCTAssertEqual(FastingEngine.streak(gapped, now: t(4, 18), calendar: cal), 2)
    }

    func testConsistencyStartsAtFirstLoggedFast() {
        let fasts = [fast("a", t(0, 20), t(1, 13)), fast("b", t(2, 20), t(3, 10))]   // met day 1, missed day 3
        let c = FastingEngine.consistency(fasts, now: t(4, 9), days: 30, calendar: cal)
        // Days 0…3 considered (today, day 4, is open and unmet), one met.
        XCTAssertEqual(c, FastingConsistency(metDays: 1, consideredDays: 4))
        XCTAssertEqual(FastingEngine.consistency([], now: t(4, 9), days: 30, calendar: cal).consideredDays, 0)
    }

    // MARK: Night split

    func testNightSplitSeparatesFastedUnloggedAndPartialNights() {
        let fasts = [
            fast("a", t(0, 19), t(1, 12)),   // covers night of wake-day 1, 17 h → fasting
            fast("b", t(2, 2), t(2, 16)),    // starts inside night 2's window → partial, dropped
            fast("c", t(3, 22), t(4, 7)),    // covers night 4 but only 9 h → too short, dropped
        ]
        let split = FastingEngine.nightSplit(fasts, now: t(5, 12), calendar: cal)
        XCTAssertEqual(split.fasting, ["2026-03-11"])
        // Day 0 (first fast's day) and days 3 and 5 had no fast in the window; nothing before day 0.
        XCTAssertEqual(split.control, ["2026-03-10", "2026-03-13", "2026-03-15"])
    }

    // MARK: Comparison (recovers injected effects, stays quiet without one)

    private func splitAndOutcomes(nights: Int, effect: Double) -> (FastingNightSplit, [String: Double]) {
        var fasting = Set<String>(), control = Set<String>(), outcome: [String: Double] = [:]
        for i in 0..<nights {
            let key = FastingEngine.dayKey(t(i, 0), calendar: cal)
            // Deterministic spread so both groups have variance.
            let noise = Double((i * 7) % 5) - 2
            if i % 2 == 0 { fasting.insert(key); outcome[key] = 60 + effect + noise }
            else { control.insert(key); outcome[key] = 60 + noise }
        }
        return (FastingNightSplit(fasting: fasting, control: control), outcome)
    }

    func testComparisonRecoversMultipleInjectedDifferences() {
        for injected in [-6.0, 4.0, 9.0] {
            let (split, outcome) = splitAndOutcomes(nights: 30, effect: injected)
            guard case .difference(let e) = FastingEngine.compare(split: split, outcomeByDay: outcome,
                                                                  outcome: "HRV") else {
                return XCTFail("expected a difference for \(injected)")
            }
            XCTAssertEqual(e.delta, injected, accuracy: 1.0)
            XCTAssertEqual(e.nWith, 15)
            XCTAssertEqual(e.nWithout, 15)
        }
    }

    func testComparisonSaysNoClearDifferenceWithoutAnEffect() {
        let (split, outcome) = splitAndOutcomes(nights: 30, effect: 0)
        guard case .noClearDifference(let e) = FastingEngine.compare(split: split, outcomeByDay: outcome,
                                                                     outcome: "HRV") else {
            return XCTFail("expected no clear difference")
        }
        XCTAssertFalse(e.significant)
    }

    func testComparisonWithholdsNumbersBelowMinimum() {
        let (split, outcome) = splitAndOutcomes(nights: 8, effect: 9)
        XCTAssertEqual(FastingEngine.compare(split: split, outcomeByDay: outcome, outcome: "HRV"),
                       .notEnoughData(fastingNights: 4, otherNights: 4, needed: 5))
    }
}
