import XCTest
import WhoopStore
import StrandAnalytics
import StrandDesign
@testable import Strand

/// Pins the Today readouts: which state each ring and tile reports for calibrating, carried, stale,
/// past-day and empty inputs, so the screen never shows a dash and never shows two answers for one fact.
final class TodayReadoutsTests: XCTestCase {

    private func day(_ key: String, recovery: Double? = nil, sleepMin: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: recovery, strain: nil, exerciseCount: nil)
    }

    // MARK: Recovery

    func testTodaysOwnScoreWinsOverTheCarry() {
        let d = RecoveryDisplay.resolve(todayRecovery: 61, priorScored: day("2026-07-14", recovery: 82),
                                        calibrationNights: nil)
        XCTAssertEqual(d, .scored(pct: 61))
    }

    func testUnscoredTodayCarriesThePriorNightAsStale() {
        let d = RecoveryDisplay.resolve(todayRecovery: nil, priorScored: day("2026-07-14", recovery: 82),
                                        calibrationNights: nil)
        XCTAssertEqual(d, .carried(pct: 82, day: "2026-07-14"))
        let readout = TodayRings.recovery(d, hrvBaseline: nil)
        XCTAssertEqual(readout.value, 82)
        XCTAssertTrue(readout.isStale, "a carried score is dated, never presented as today's")
    }

    func testCalibrationBeatsTheCarryAndCountsTheNightsLeft() {
        let d = RecoveryDisplay.resolve(todayRecovery: nil, priorScored: day("2026-07-14", recovery: 82),
                                        calibrationNights: 1)
        XCTAssertEqual(d, .calibrating(nights: 1))
        let readout = TodayRings.recovery(d, hrvBaseline: nil)
        XCTAssertNil(readout.displayValue)
        XCTAssertEqual(readout.verdict, .unavailable(.calibrating(nightsLeft: Baselines.minNightsSeed - 1)))
    }

    func testNoPriorAndNoCalibrationIsNoData() {
        let d = RecoveryDisplay.resolve(todayRecovery: nil, priorScored: nil, calibrationNights: nil)
        XCTAssertEqual(d, .noData)
        XCTAssertEqual(TodayRings.recovery(d, hrvBaseline: nil).verdict, .unavailable(.noData(since: nil)))
        XCTAssertNil(TodayRings.synthesis(d, isToday: true))
    }

    // MARK: Sleep

    /// The "--%" next to the Sleep screen's 89: today with no new night shows the newest night, dated.
    func testTodayWithoutANewNightShowsTheNewestNightAsStale() {
        let night = TodayRings.SleepNight(wakeDay: "2026-10-06", score: 89)
        let readout = TodayRings.sleep(night, selectedDay: "2026-10-14", isToday: true)
        XCTAssertEqual(readout.value, 89)
        XCTAssertTrue(readout.isStale)
    }

    func testAPastDayOnlyShowsItsOwnNight() {
        let night = TodayRings.SleepNight(wakeDay: "2026-10-06", score: 89)
        let readout = TodayRings.sleep(night, selectedDay: "2026-10-10", isToday: false)
        XCTAssertNil(readout.displayValue)
        let own = TodayRings.sleep(TodayRings.SleepNight(wakeDay: "2026-10-10", score: 71),
                                   selectedDay: "2026-10-10", isToday: false)
        XCTAssertEqual(own.value, 71)
        XCTAssertFalse(own.isStale)
    }

    func testSleepScorePrefersTheImportedFigure() {
        XCTAssertEqual(TodayRings.sleepScore(wakeDay: "2026-10-06", importedPct: 89, row: nil), 89)
        XCTAssertNil(TodayRings.sleepScore(wakeDay: "2026-10-06", importedPct: nil, row: nil))
    }

    // MARK: Strain

    func testStrainBandsFollowTheWhoopZones() {
        XCTAssertEqual(TodayRings.loadBand(strain21: 9.9), .restorative)
        XCTAssertEqual(TodayRings.loadBand(strain21: 10), .building)
        XCTAssertEqual(TodayRings.loadBand(strain21: 14), .demanding)
        XCTAssertEqual(TodayRings.loadBand(strain21: 18), .overreaching)
    }

    func testStrainOnTheWhoopScaleIsRescaledNotRebanded() {
        let hundred = TodayRings.strain(50, whoopScale: false, hrSamples: nil)
        let whoop = TodayRings.strain(50, whoopScale: true, hrSamples: nil)
        XCTAssertEqual(hundred.value, 50)
        XCTAssertEqual(whoop.value ?? 0, 10.5, accuracy: 0.001)
        XCTAssertEqual(hundred.verdict, whoop.verdict)
    }

    // MARK: Stress

    /// A past day never borrows another day's level from the carry inside `DaytimeStress.daily` (P8).
    func testPastDayStressOnlyUsesThatDaysLevel() {
        XCTAssertNil(TodayBodyReadouts.pastDayStress(nil, dayKey: "2026-10-10").value)
    }

    func testStressIsJudgedAgainstTheMediumBand() {
        let typical = TodayBodyReadouts.stress(Assessment(value: 1.5, confidence: .solid, reason: .dailyLevel))
        let high = TodayBodyReadouts.stress(Assessment(value: 2.4, confidence: .solid, reason: .dailyLevel))
        XCTAssertEqual(typical.verdict, .typical)
        XCTAssertEqual(high.verdict, .above)
    }

    // MARK: Dashboard and fitness age

    func testDailyCountFallsBackToThePopulationRangeWhileCalibrating() {
        let readout = TodayBodyReadouts.dailyCount(id: .steps, value: 4_000, history: [9_000, 9_500],
                                                   unit: .steps, population: 5_000...10_000)
        XCTAssertFalse(readout.rangeIsPersonal)
        XCTAssertEqual(readout.verdict, .below)
        XCTAssertEqual(readout.confidence, .calibrating(nightsLeft: 2))
    }

    func testDailyCountUsesTheOwnRangeOnceEnoughDaysExist() {
        let readout = TodayBodyReadouts.dailyCount(id: .steps, value: 9_000,
                                                   history: [8_000, 9_000, 10_000, 9_500, 8_500],
                                                   unit: .steps, population: 5_000...10_000)
        XCTAssertTrue(readout.rangeIsPersonal)
        XCTAssertEqual(readout.verdict, .typical)
    }

    func testMissingCountsShowAReasonInsteadOfADash() {
        let readout = TodayBodyReadouts.dailyCount(id: .steps, value: nil, history: [],
                                                   unit: .steps, population: 5_000...10_000)
        XCTAssertNil(readout.displayValue)
        XCTAssertEqual(readout.verdict, .unavailable(.noData(since: nil)))
    }

    func testFitnessAgeIsPlacedAgainstTheProfileAge() {
        let older = TodayBodyReadouts.fitnessAge(latest: ("2026-10-12", 38), age: 34, selectedDay: "2026-10-14")
        let same = TodayBodyReadouts.fitnessAge(latest: ("2026-10-12", 34.6), age: 34, selectedDay: "2026-10-14")
        XCTAssertEqual(older.verdict, .above)
        XCTAssertEqual(same.verdict, .typical)
        let old = TodayBodyReadouts.fitnessAge(latest: ("2026-09-01", 34), age: 34, selectedDay: "2026-10-14")
        XCTAssertTrue(old.isStale)
    }
}
