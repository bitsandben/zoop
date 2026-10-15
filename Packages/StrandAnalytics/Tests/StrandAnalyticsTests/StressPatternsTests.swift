import XCTest
@testable import StrandAnalytics

final class StressPatternsTests: XCTestCase {

    // 2026-01-05 is a Monday.
    private let start = BodyInsights.dayNumber("2026-01-05")!
    private func day(_ i: Int) -> String { BodyInsights.dayString(start + i) }

    // MARK: Time of day

    private func hourDays(_ n: Int, peak: Int?, calm: Int?) -> [[BodyInsights.HourLevel]] {
        (0..<n).map { d in
            (8...21).map { h in
                var level = 1.2 + 0.05 * Double((d + h) % 3)
                if h == peak { level = 2.5 }
                if h == calm { level = 0.3 }
                return .init(hour: h, level: level)
            }
        }
    }

    func testTimeOfDayCarriesTheSameTimingAsInsights() throws {
        let days = hourDays(10, peak: 15, calm: 8)
        let t = try XCTUnwrap(StressPatterns.timeOfDay(days: days))
        XCTAssertEqual(t.days, 10)
        XCTAssertEqual(t.hours.map(\.hour), Array(8...21))
        XCTAssertEqual(t.timing, BodyInsights.stressTiming(days: days))
        XCTAssertEqual(t.timing?.peakHour, 15)
        XCTAssertEqual(t.timing?.calmHour, 8)
        // The curve's hour means are the timing's hour means.
        XCTAssertEqual(t.hours, t.timing?.hourMeans)
    }

    func testFlatDayStillDrawsTheCurveWithoutNamingAPeak() throws {
        let t = try XCTUnwrap(StressPatterns.timeOfDay(days: hourDays(10, peak: nil, calm: nil)))
        XCTAssertNil(t.timing)
        XCTAssertEqual(t.hours.count, 14)
        XCTAssertEqual(t.dayMean, 1.25, accuracy: 0.01)
    }

    func testTimeOfDayNilWithTooFewDays() {
        XCTAssertNil(StressPatterns.timeOfDay(days: hourDays(6, peak: 15, calm: 8)))
        XCTAssertNil(StressPatterns.timeOfDay(days: []))
        // Days with fewer than six scored hours do not count.
        let thin = (0..<10).map { _ in (8...11).map { BodyInsights.HourLevel(hour: $0, level: 1) } }
        XCTAssertNil(StressPatterns.timeOfDay(days: thin))
    }

    // MARK: Week

    /// Eight weeks of daily levels; `weekend` and `workday` set the two groups, a small wobble the spread.
    private func weeks(workday: Double, weekend: Double, count: Int = 56) -> [BodyInsights.DayValue] {
        (0..<count).map { i in
            let wd = BodyInsights.isoWeekday(start + i)
            let base = wd >= 6 ? weekend : workday
            return .init(day: day(i), value: base + [0, 0.1, -0.1, 0.05, -0.05][i % 5])
        }
    }

    func testCalmerWeekendIsClear() throws {
        let w = try XCTUnwrap(StressPatterns.week(weeks(workday: 1.6, weekend: 0.9)))
        XCTAssertEqual(w.verdict, .weekendCalmer)
        XCTAssertEqual(w.workdayDays, 40)
        XCTAssertEqual(w.weekendDays, 16)
        XCTAssertEqual(w.difference, -0.7, accuracy: 0.05)
        XCTAssertLessThan(w.pValue, 0.05)
        XCTAssertEqual(w.weekdays.map(\.weekday), Array(1...7))
        XCTAssertEqual(w.weekdays.first?.days, 8)
    }

    func testMoreStressedWeekendIsClear() throws {
        let w = try XCTUnwrap(StressPatterns.week(weeks(workday: 1.0, weekend: 1.8)))
        XCTAssertEqual(w.verdict, .weekendMoreStressed)
        XCTAssertGreaterThan(w.difference, 0)
    }

    func testSmallGapIsNoClearDifference() throws {
        // Significant on a tiny wobble, but under the 0.25 floor: not worth saying.
        let w = try XCTUnwrap(StressPatterns.week(weeks(workday: 1.3, weekend: 1.2)))
        XCTAssertEqual(w.verdict, .noClearDifference)
        // Same means: no difference at all.
        let same = try XCTUnwrap(StressPatterns.week(weeks(workday: 1.3, weekend: 1.3)))
        XCTAssertEqual(same.verdict, .noClearDifference)
    }

    func testNoisyGapIsNoClearDifference() throws {
        // A 0.4 gap drowned in a ±1 day-to-day swing on few weekend days.
        let values = (0..<21).map { i -> BodyInsights.DayValue in
            let wd = BodyInsights.isoWeekday(start + i)
            let swing = [1.0, -1.0, 0.8, -0.8, 0.0][i % 5]
            return .init(day: day(i), value: (wd >= 6 ? 1.0 : 1.4) + swing)
        }
        let w = try XCTUnwrap(StressPatterns.week(values))
        XCTAssertEqual(w.verdict, .noClearDifference)
        XCTAssertEqual(w.weekendDays, 6)
    }

    func testWeekNilWithoutEnoughWeekendOrWorkdays() {
        // Two weeks: 10 workdays but only 4 weekend days is enough; one week is not.
        XCTAssertNotNil(StressPatterns.week(weeks(workday: 1.5, weekend: 1.0, count: 14)))
        XCTAssertNil(StressPatterns.week(weeks(workday: 1.5, weekend: 1.0, count: 7)))
        XCTAssertNil(StressPatterns.week([]))
    }

    func testWeekWindowEndsAtAsOf() throws {
        // Old history beyond eight weeks before `asOf` is ignored.
        let values = weeks(workday: 1.5, weekend: 1.0)
        XCTAssertNil(StressPatterns.week(values, asOf: day(56 + 60)))
        let w = try XCTUnwrap(StressPatterns.week(values, asOf: day(55)))
        XCTAssertEqual(w.workdayDays + w.weekendDays, 56)
    }
}
