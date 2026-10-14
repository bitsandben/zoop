import XCTest
import StrandAnalytics
@testable import Strand

/// The Sleep Regularity Index and the personal-range fold behind the Sleep readouts.
final class SleepRegularityTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let endDay = Date(timeIntervalSince1970: 1_790_000_000)

    /// One night per day, `bedHour` local (UTC) the evening before each wake day, `hours` long.
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
        // 23:00 + 4 h = 03:00.
        XCTAssertEqual(result.midpointMin, 180, accuracy: 5)
    }

    /// Recovers more than one injected value: a larger alternating shift lowers the index further.
    func testShiftedNightsLowerTheIndexInProportion() throws {
        let small = try XCTUnwrap(SleepRegularity.compute(
            windows: nights(14) { $0 % 2 == 0 ? 23 : 24 }, endDay: endDay, calendar: calendar))
        let large = try XCTUnwrap(SleepRegularity.compute(
            windows: nights(14) { $0 % 2 == 0 ? 22 : 25 }, endDay: endDay, calendar: calendar))
        // A 1 h shift flips 2 h of 24 → P(same) = 22/24 → SRI ≈ 83.3; a 3 h shift → 18/24 → 50.
        XCTAssertEqual(small.index, 83.3, accuracy: 1)
        XCTAssertEqual(large.index, 50, accuracy: 1)
    }

    func testTooFewWornDaysGivesNoIndex() {
        XCTAssertNil(SleepRegularity.compute(windows: nights(4) { _ in 23 }, endDay: endDay, calendar: calendar))
    }

    func testPersonalRangeCalibratesThenFollowsHistory() {
        let cfg = SleepRangeConfig.score
        let early = SleepPersonalRange.resolve(history: [80, 82], cfg: cfg, population: 67...100, lastSample: nil)
        XCTAssertFalse(early.isPersonal)
        XCTAssertEqual(early.range, 67...100)
        XCTAssertNil(early.baseline)

        let settled = SleepPersonalRange.resolve(history: Array(repeating: 80, count: 20), cfg: cfg,
                                                 population: 67...100, lastSample: nil)
        XCTAssertTrue(settled.isPersonal)
        XCTAssertTrue(settled.range.contains(80))
        XCTAssertEqual(settled.confidence, .solid)
    }
}
