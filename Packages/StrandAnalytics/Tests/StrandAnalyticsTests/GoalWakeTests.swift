import XCTest
@testable import StrandAnalytics

/// The goal-based smart alarm's decision: window bounds, the deadline invariant, condition combinations,
/// and the partial-night recovery estimate.
final class GoalWakeTests: XCTestCase {

    // 06:30–06:50 on an arbitrary day.
    private let window = GoalWake.Window(start: 1_000_000, end: 1_000_000 + 20 * 60)
    private let need = GoalWake.Settings(mode: .sleepNeed)
    private let recovery = GoalWake.Settings(mode: .recovery)

    private func inputs(_ offset: Int, asleep: Double? = nil, needMin: Double? = 480,
                        rec: Double? = nil, light: Bool = false) -> GoalWake.Inputs {
        GoalWake.Inputs(now: window.start + offset, asleepMin: asleep, needMin: needMin, recovery: rec, lightSleep: light)
    }

    // MARK: Window bounds and the deadline invariant

    func testNeverWakesBeforeTheWindow() {
        let d = GoalWake.decide(window: window, settings: need, inputs: inputs(-60, asleep: 600, light: true))
        XCTAssertEqual(d, .hold(.beforeWindow))
        XCTAssertNil(GoalWake.wakeTime(now: window.start - 1, window: window))
    }

    func testWakeIsNowPlusLeadAndInsideTheWindow() {
        let d = GoalWake.decide(window: window, settings: need, inputs: inputs(0, asleep: 500, light: true))
        XCTAssertEqual(d, .wake(at: window.start + GoalWake.earlyWakeLeadS, reason: .sleepNeedReached))
    }

    func testNeverArmsLaterThanTheDeadlineMargin() {
        // Every second of the window: a wake, when chosen, is >= start and <= end - margin.
        for offset in stride(from: 0, through: 20 * 60, by: 7) {
            let d = GoalWake.decide(window: window, settings: need, inputs: inputs(offset, asleep: 600, light: true))
            if case .wake(let at, _) = d {
                XCTAssertGreaterThanOrEqual(at, window.start)
                XCTAssertLessThanOrEqual(at, window.end - GoalWake.deadlineMarginS)
            } else {
                XCTAssertEqual(d, .hold(.deadlineClose), "offset \(offset)")
                XCTAssertGreaterThan(window.start + offset + GoalWake.earlyWakeLeadS, window.end - GoalWake.deadlineMarginS)
            }
        }
    }

    func testAfterTheDeadlineHolds() {
        let d = GoalWake.decide(window: window, settings: need, inputs: inputs(30 * 60, asleep: 600, light: true))
        XCTAssertEqual(d, .hold(.deadlineClose))
    }

    func testZeroLengthWindowNeverWakesEarly() {
        let w = GoalWake.Window(deadline: 2_000_000, minutes: 0)
        XCTAssertEqual(GoalWake.decide(window: w, settings: need,
                                       inputs: .init(now: w.start, asleepMin: 900, needMin: 1, lightSleep: true)),
                       .hold(.deadlineClose))
        XCTAssertTrue(GoalWake.plannedChecks(window: w, intervalS: 180).isEmpty)
    }

    func testPlannedChecksStayInsideTheWindow() {
        let slots = GoalWake.plannedChecks(window: window, intervalS: 180)
        XCTAssertEqual(slots.first, window.start)
        XCTAssertTrue(slots.allSatisfy { $0 + GoalWake.earlyWakeLeadS <= window.end - GoalWake.deadlineMarginS })
        XCTAssertEqual(slots.count, 6)   // 0, 3, …, 15 min; 18 min + 30 s is inside the margin
    }

    // MARK: Conditions

    func testSleepNeedNotMetHolds() {
        XCTAssertEqual(GoalWake.decide(window: window, settings: need, inputs: inputs(300, asleep: 400, light: true)),
                       .hold(.conditionNotMet))
    }

    func testMissingDataHoldsAsNoData() {
        XCTAssertEqual(GoalWake.decide(window: window, settings: need, inputs: inputs(300, asleep: nil)), .hold(.noData))
        XCTAssertEqual(GoalWake.decide(window: window, settings: need, inputs: inputs(300, asleep: 500, needMin: nil)),
                       .hold(.noData))
        XCTAssertEqual(GoalWake.decide(window: window, settings: recovery, inputs: inputs(300, rec: nil)), .hold(.noData))
    }

    func testRecoveryThreshold() {
        XCTAssertEqual(GoalWake.decide(window: window, settings: recovery, inputs: inputs(300, rec: 66.9, light: true)),
                       .hold(.conditionNotMet))
        XCTAssertEqual(GoalWake.decide(window: window, settings: recovery, inputs: inputs(300, rec: 67, light: true)),
                       .wake(at: window.start + 300 + 30, reason: .recoveryReached))
        var custom = recovery
        custom.recoveryThreshold = 80
        XCTAssertEqual(GoalWake.decide(window: window, settings: custom, inputs: inputs(300, rec: 75, light: true)),
                       .hold(.conditionNotMet))
    }

    func testGoalMetWaitsForLightSleepUntilGrace() {
        // Goal met, no light sleep, 5 min in: wait. 10 min in: wake anyway.
        XCTAssertEqual(GoalWake.decide(window: window, settings: need, inputs: inputs(5 * 60, asleep: 500)),
                       .hold(.waitingForLightSleep))
        XCTAssertEqual(GoalWake.decide(window: window, settings: need, inputs: inputs(10 * 60, asleep: 500)),
                       .wake(at: window.start + 600 + 30, reason: .sleepNeedReached))
    }

    func testWithoutLightSleepPreferenceWakesAsSoonAsGoalMet() {
        var s = need
        s.preferLightSleep = false
        XCTAssertEqual(GoalWake.decide(window: window, settings: s, inputs: inputs(0, asleep: 500)),
                       .wake(at: window.start + 30, reason: .sleepNeedReached))
    }

    func testLightSleepAloneNeverMeetsAGoal() {
        XCTAssertEqual(GoalWake.decide(window: window, settings: recovery, inputs: inputs(0, rec: 40, light: true)),
                       .hold(.conditionNotMet))
    }

    func testFixedTimeWakesOnlyOnLightSleep() {
        let fixed = GoalWake.Settings(mode: .fixedTime)
        XCTAssertEqual(GoalWake.decide(window: window, settings: fixed, inputs: inputs(60, asleep: 900, rec: 99)),
                       .hold(.waitingForLightSleep))
        XCTAssertEqual(GoalWake.decide(window: window, settings: fixed, inputs: inputs(60, light: true)),
                       .wake(at: window.start + 90, reason: .lightSleep))
    }

    // MARK: Night so far

    func testNightProgressSumsAsleepStagesAndWeightsHRV() {
        let s1 = SleepSession(start: 0, end: 3600, efficiency: 0.9,
                              stages: [.init(start: 0, end: 600, stage: "wake"), .init(start: 600, end: 3600, stage: "light")],
                              restingHR: 52, avgHRV: 40)
        let s2 = SleepSession(start: 4000, end: 7600, efficiency: 1, stages: [], restingHR: 50, avgHRV: 60)
        let p = NightProgress.tonight(sessions: [s2, s1], now: 7600)
        XCTAssertEqual(p?.onset, 0)
        XCTAssertEqual(p?.asleepMin ?? 0, 50 + 60, accuracy: 0.01)
        XCTAssertEqual(p?.hrv ?? 0, 50, accuracy: 0.01)
        XCTAssertEqual(p?.restingHR, 50)
    }

    func testNightProgressIgnoresOldAndTinySessions() {
        let old = SleepSession(start: 0, end: 3600, efficiency: 1, stages: [], restingHR: 50, avgHRV: 50)
        let nap = SleepSession(start: 100_000, end: 100_300, efficiency: 1, stages: [], restingHR: 50, avgHRV: 50)
        XCTAssertNil(NightProgress.tonight(sessions: [old, nap], now: 100_400))
    }

    // MARK: Partial-night estimate

    private let hrvBase = BaselineState(baseline: 50, spread: 8, nValid: 20, nightsSinceUpdate: 0, status: .trusted)
    private let rhrBase = BaselineState(baseline: 55, spread: 2, nValid: 20, nightsSinceUpdate: 0, status: .trusted)

    func testEstimateNeedsEnoughSleepAndAUsableBaseline() {
        XCTAssertNil(PartialNightRecovery.estimate(hrvSoFar: 60, restingHRSoFar: 50, asleepMin: 60, needMin: 480,
                                                   hrvBaseline: hrvBase, rhrBaseline: rhrBase))
        let calibrating = BaselineState(baseline: 50, spread: 8, nValid: 2, nightsSinceUpdate: 0, status: .calibrating)
        XCTAssertNil(PartialNightRecovery.estimate(hrvSoFar: 60, restingHRSoFar: 50, asleepMin: 300, needMin: 480,
                                                   hrvBaseline: calibrating, rhrBaseline: rhrBase))
        XCTAssertNil(PartialNightRecovery.estimate(hrvSoFar: nil, restingHRSoFar: 50, asleepMin: 300, needMin: 480,
                                                   hrvBaseline: hrvBase, rhrBaseline: rhrBase))
    }

    func testEstimateTracksTheInputsNotOneValue() {
        // Higher HRV and lower resting HR than usual read higher; the reverse reads lower.
        let good = PartialNightRecovery.estimate(hrvSoFar: 65, restingHRSoFar: 51, asleepMin: 420, needMin: 450,
                                                 hrvBaseline: hrvBase, rhrBaseline: rhrBase)
        let typical = PartialNightRecovery.estimate(hrvSoFar: 50, restingHRSoFar: 55, asleepMin: 420, needMin: 450,
                                                    hrvBaseline: hrvBase, rhrBaseline: rhrBase)
        let poor = PartialNightRecovery.estimate(hrvSoFar: 35, restingHRSoFar: 60, asleepMin: 420, needMin: 450,
                                                 hrvBaseline: hrvBase, rhrBaseline: rhrBase)
        XCTAssertNotNil(good); XCTAssertNotNil(typical); XCTAssertNotNil(poor)
        XCTAssertGreaterThan(good!.score, typical!.score)
        XCTAssertGreaterThan(typical!.score, poor!.score)
        XCTAssertGreaterThanOrEqual(good!.score, 67)
        XCTAssertLessThan(poor!.score, 34)
        XCTAssertTrue(good!.isEstimate)
    }

    func testEstimateRisesAsTheNightGoesOn() {
        // Same physiology, more sleep so far: the sufficiency term lifts the estimate, never lowers it.
        let early = PartialNightRecovery.estimate(hrvSoFar: 55, restingHRSoFar: 54, asleepMin: 200, needMin: 480,
                                                  hrvBaseline: hrvBase, rhrBaseline: rhrBase)!
        let late = PartialNightRecovery.estimate(hrvSoFar: 55, restingHRSoFar: 54, asleepMin: 470, needMin: 480,
                                                 hrvBaseline: hrvBase, rhrBaseline: rhrBase)!
        XCTAssertGreaterThan(late.score, early.score)
    }

    func testEstimateMatchesTheScorerWithTheSameInputs() {
        let e = PartialNightRecovery.estimate(hrvSoFar: 58, restingHRSoFar: 53, asleepMin: 400, needMin: 480,
                                              hrvBaseline: hrvBase, rhrBaseline: rhrBase)!
        let direct = RecoveryScorer.recovery(hrv: 58, rhr: 53, resp: nil, hrvBaseline: hrvBase, rhrBaseline: rhrBase,
                                             respBaseline: nil,
                                             sleepPerf: AnalyticsEngine.Rest.sufficiency(tstSeconds: 400 * 60, needHours: 8))
        XCTAssertEqual(e.score, direct!, accuracy: 1e-9)
    }
}
