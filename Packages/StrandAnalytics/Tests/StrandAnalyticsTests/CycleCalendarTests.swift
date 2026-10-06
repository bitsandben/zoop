import XCTest
@testable import StrandAnalytics

final class CycleCalendarTests: XCTestCase {
    func testNothingWithoutALoggedStart() {
        XCTAssertNil(CycleCalendar.estimate(periodStarts: [], today: 100))
        XCTAssertNil(CycleCalendar.estimate(periodStarts: [120], today: 100))   // only a future log
    }

    func testOneStartUsesTheDefaultLength() {
        let e = CycleCalendar.estimate(periodStarts: [100], today: 100)!
        XCTAssertEqual(e.cycleDay, 1)
        XCTAssertEqual(e.cycleLength, 28)
        XCTAssertEqual(e.phase, .menstrual)
        XCTAssertEqual(e.nextPeriodStart, 128)
        XCTAssertEqual(e.daysUntilNextPeriod, 28)
        XCTAssertEqual(e.cyclesUsed, 0)
    }

    func testLengthIsTheMedianOfAcceptedGaps() {
        // Gaps 30, 32, 31 and one implausible 60 that is ignored.
        let e = CycleCalendar.estimate(periodStarts: [0, 30, 62, 93, 153], today: 160)!
        XCTAssertEqual(e.cycleLength, 31)
        XCTAssertEqual(e.cyclesUsed, 3)
        XCTAssertEqual(e.cycleDay, 8)
        XCTAssertEqual(e.nextPeriodStart, 184)
    }

    func testPhasesAcrossA28DayCycle() {
        func phase(_ day: Int) -> CycleCalendar.Phase {
            CycleCalendar.estimate(periodStarts: [0], today: day - 1)!.phase
        }
        XCTAssertEqual(phase(1), .menstrual)
        XCTAssertEqual(phase(5), .menstrual)
        XCTAssertEqual(phase(6), .follicular)
        XCTAssertEqual(phase(11), .follicular)
        XCTAssertEqual(phase(12), .ovulatory)   // ovulation on day 14, window 12–15
        XCTAssertEqual(phase(15), .ovulatory)
        XCTAssertEqual(phase(16), .luteal)
        XCTAssertEqual(phase(28), .luteal)
    }

    func testLatePeriodCountsBelowZero() {
        let e = CycleCalendar.estimate(periodStarts: [0], today: 31)!
        XCTAssertEqual(e.daysUntilNextPeriod, -3)
        XCTAssertEqual(e.cycleDay, 32)
    }
}
