import XCTest
@testable import StrandAnalytics

final class SleepRegularityTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let endDay = Date(timeIntervalSince1970: 1_790_000_000)

    private func nights(_ count: Int, bedHour: (Int) -> Double, hours: Double = 8) -> [(start: Int, end: Int)] {
        let lastMidnight = calendar.startOfDay(for: endDay)
        return (0..<count).map { i in
            let midnight = lastMidnight.addingTimeInterval(Double(i - count + 1) * 86_400)
            let start = midnight.addingTimeInterval((bedHour(i) - 24) * 3_600)
            return (Int(start.timeIntervalSince1970), Int(start.addingTimeInterval(hours * 3_600).timeIntervalSince1970))
        }
    }

    func testIdenticalNightsScoreOneHundred() throws {
        let result = try XCTUnwrap(SleepRegularity.compute(windows: nights(14) { _ in 23 }, endDay: endDay,
                                                           calendar: calendar))
        XCTAssertEqual(result.index, 100, accuracy: 0.01)
        XCTAssertEqual(result.midpointMin, 180, accuracy: 5)
    }

    func testShiftedNightsLowerTheIndexInProportion() throws {
        let small = try XCTUnwrap(SleepRegularity.compute(
            windows: nights(14) { $0 % 2 == 0 ? 23 : 24 }, endDay: endDay, calendar: calendar))
        let large = try XCTUnwrap(SleepRegularity.compute(
            windows: nights(14) { $0 % 2 == 0 ? 22 : 25 }, endDay: endDay, calendar: calendar))
        // 1 h shift: P(same) = 22/24 -> 83.3; 3 h shift: 18/24 -> 50.
        XCTAssertEqual(small.index, 83.3, accuracy: 1)
        XCTAssertEqual(large.index, 50, accuracy: 1)
    }

    func testTooFewWornDaysGivesNoIndex() {
        XCTAssertNil(SleepRegularity.compute(windows: nights(4) { _ in 23 }, endDay: endDay, calendar: calendar))
    }

    func testShortSleepDaysAreSkipped() {
        XCTAssertNil(SleepRegularity.compute(windows: nights(14, bedHour: { _ in 23 }, hours: 2), endDay: endDay,
                                             calendar: calendar))
    }

    func testTrailingSeriesIsHundredEverywhereForIdenticalNights() {
        let series = SleepRegularity.trailingSeries(windows: nights(30) { _ in 23 }, endDay: endDay, count: 5,
                                                    calendar: calendar)
        XCTAssertEqual(series.count, 5)
        for entry in series { XCTAssertEqual(entry.index ?? 0, 100, accuracy: 0.01) }
    }
}

final class SleepPersonalRangeTests: XCTestCase {
    func testInsufficientHistoryKeepsPopulationRange() {
        let r = SleepPersonalRange.resolve(history: [80, 82], cfg: SleepRangeConfig.score,
                                           population: 67...100, lastSample: nil)
        XCTAssertFalse(r.isPersonal)
        XCTAssertEqual(r.range, 67...100)
        XCTAssertNil(r.baseline)
        XCTAssertEqual(r.status, .calibrating)
        XCTAssertEqual(r.nightsLeft, Baselines.minNightsSeed - 2)
    }

    func testEmptyHistoryIsCalibrating() {
        let r = SleepPersonalRange.resolve(history: [], cfg: SleepRangeConfig.score, population: 67...100,
                                           lastSample: nil)
        XCTAssertFalse(r.isPersonal)
        XCTAssertEqual(r.nightsLeft, Baselines.minNightsSeed)
    }

    func testSettledHistoryGivesPersonalRangeAroundTheMean() {
        for level in [60.0, 80.0] {
            let r = SleepPersonalRange.resolve(history: Array(repeating: level, count: 20),
                                               cfg: SleepRangeConfig.score, population: 67...100, lastSample: nil)
            XCTAssertTrue(r.isPersonal)
            XCTAssertEqual(r.baseline ?? 0, level, accuracy: 1)
            XCTAssertTrue(r.range.contains(level))
            XCTAssertEqual(r.nightsLeft, 0)
        }
    }
}
