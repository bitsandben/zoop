import XCTest
@testable import StrandAnalytics

/// The Sleep factor grid's verdict bands. Each band edge is pinned so a threshold cannot drift silently.
final class SleepFactorsTests: XCTestCase {

    func testDurationBands() {
        XCTAssertEqual(SleepFactors.duration(hoursVsNeededPct: 95).verdict, .good)
        XCTAssertEqual(SleepFactors.duration(hoursVsNeededPct: 90).verdict, .good)
        XCTAssertEqual(SleepFactors.duration(hoursVsNeededPct: 89.9).verdict, .fair)
        XCTAssertEqual(SleepFactors.duration(hoursVsNeededPct: 75).verdict, .fair)
        XCTAssertEqual(SleepFactors.duration(hoursVsNeededPct: 70).verdict, .poor)
        XCTAssertEqual(SleepFactors.duration(hoursVsNeededPct: 130).progress, 1)
    }

    func testEfficiencyAndConsistencyBands() {
        XCTAssertEqual(SleepFactors.efficiency(pct: 85).verdict, .good)
        XCTAssertEqual(SleepFactors.efficiency(pct: 80).verdict, .fair)
        XCTAssertEqual(SleepFactors.efficiency(pct: 74).verdict, .poor)
        XCTAssertEqual(SleepFactors.consistency(pct: 75).verdict, .good)
        XCTAssertEqual(SleepFactors.consistency(pct: 60).verdict, .fair)
        XCTAssertEqual(SleepFactors.consistency(pct: 54).verdict, .poor)
    }

    func testStageAgainstPersonalMean() {
        // 80 of 420 asleep = 19 % share (good for deep on its own).
        XCTAssertEqual(SleepFactors.stage(.deep, minutes: 80, asleepMin: 420, typicalMin: 85)?.verdict, .good)
        // 30 of 420 = 7 % share, 30/85 = 0.35 of mean: poor.
        XCTAssertEqual(SleepFactors.stage(.deep, minutes: 30, asleepMin: 420, typicalMin: 85)?.verdict, .poor)
        // 50 of 420 = 12 % share (fair), 50/85 = 0.59 (poor): the better band wins.
        XCTAssertEqual(SleepFactors.stage(.deep, minutes: 50, asleepMin: 420, typicalMin: 85)?.verdict, .fair)
        // Matching a high personal mean is good even with a modest share.
        XCTAssertEqual(SleepFactors.stage(.rem, minutes: 60, asleepMin: 420, typicalMin: 62)?.verdict, .good)
    }

    func testStageWithoutBaselineUsesShareFloors() {
        XCTAssertEqual(SleepFactors.stage(.rem, minutes: 100, asleepMin: 420, typicalMin: nil)?.verdict, .good)  // 24 %
        XCTAssertEqual(SleepFactors.stage(.rem, minutes: 70, asleepMin: 420, typicalMin: nil)?.verdict, .fair)   // 17 %
        XCTAssertEqual(SleepFactors.stage(.rem, minutes: 40, asleepMin: 420, typicalMin: 5)?.verdict, .poor)     // thin mean ignored
        XCTAssertNil(SleepFactors.stage(.deep, minutes: 0, asleepMin: 0, typicalMin: 80))
    }

    func testWakeUpsLowerIsBetter() {
        XCTAssertEqual(SleepFactors.wakeUps(count: 2, typical: nil).verdict, .good)
        XCTAssertEqual(SleepFactors.wakeUps(count: 4, typical: nil).verdict, .fair)
        XCTAssertEqual(SleepFactors.wakeUps(count: 6, typical: nil).verdict, .poor)
        // A restless sleeper is judged against their own mean.
        XCTAssertEqual(SleepFactors.wakeUps(count: 6, typical: 6).verdict, .good)
        XCTAssertEqual(SleepFactors.wakeUps(count: 9, typical: 6).verdict, .fair)
        XCTAssertEqual(SleepFactors.wakeUps(count: 10, typical: 6).verdict, .poor)
        XCTAssertGreaterThan(SleepFactors.wakeUps(count: 1, typical: 3).progress,
                             SleepFactors.wakeUps(count: 5, typical: 3).progress)
    }

    func testEvaluateKeepsOrderAndDropsMissingInputs() {
        let all = SleepFactors.evaluate(.init(hoursVsNeededPct: 92, asleepMin: 420, deepMin: 70, remMin: 90,
                                              typicalDeepMin: 75, typicalRemMin: 95,
                                              efficiencyPct: 88, consistencyPct: 70,
                                              wakeUps: 3, typicalWakeUps: 3))
        XCTAssertEqual(all.map(\.factor), [.duration, .deep, .rem, .efficiency, .consistency, .wakeUps])
        let some = SleepFactors.evaluate(.init(hoursVsNeededPct: 80, efficiencyPct: 90))
        XCTAssertEqual(some.map(\.factor), [.duration, .efficiency])
        XCTAssertTrue(SleepFactors.evaluate(.init()).isEmpty)
    }

    func testProgressIsClamped() {
        XCTAssertEqual(SleepFactors.wakeUps(count: 50, typical: 2).progress, 0)
        XCTAssertEqual(SleepFactors.stage(.deep, minutes: 200, asleepMin: 420, typicalMin: 80)?.progress, 1)
    }
}
