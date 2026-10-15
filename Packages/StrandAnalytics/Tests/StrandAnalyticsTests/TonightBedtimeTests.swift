import XCTest
@testable import StrandAnalytics

final class TonightBedtimeTests: XCTestCase {

    func testUsualIsTheMedianOfTheLastFourteenNights() {
        XCTAssertNil(TonightBedtime.usualMinute(signedBedtimes: [-60, -50]))
        // 23:00, 23:10, 23:20 → 23:10.
        XCTAssertEqual(TonightBedtime.usualMinute(signedBedtimes: [-60, -40, -50]), 23 * 60 + 10)
        // Older nights beyond fourteen are ignored.
        let old = Array(repeating: -300.0, count: 10)
        XCTAssertEqual(TonightBedtime.usualMinute(signedBedtimes: old + Array(repeating: 30.0, count: 14)), 30)
    }

    func testRecommendedIsClampedAndRounded() {
        // Wake 06:52 with 10 h 34 min in bed would be 20:18; the usual 23:10 keeps it at 22:15.
        XCTAssertEqual(TonightBedtime.recommendedMinute(wakeMinute: 6 * 60 + 52, inBedMinutes: 634,
                                                        usualMinute: 23 * 60 + 10), 22 * 60 + 15)
        // No habit known: not before 21:00.
        XCTAssertEqual(TonightBedtime.recommendedMinute(wakeMinute: 6 * 60 + 52, inBedMinutes: 634,
                                                        usualMinute: nil), 21 * 60)
        // A reachable time only rounds to the quarter hour.
        XCTAssertEqual(TonightBedtime.recommendedMinute(wakeMinute: 7 * 60, inBedMinutes: 488,
                                                        usualMinute: 23 * 60), 22 * 60 + 52 - 7)
    }

    func testCoachClampLeavesTheResolvedTimeUnchanged() {
        let usual = 23 * 60 + 10
        let bed = TonightBedtime.recommendedMinute(wakeMinute: 6 * 60 + 52, inBedMinutes: 634, usualMinute: usual)
        XCTAssertEqual(CoachMorningRules.reasonableBedtime(bed, usual: usual), bed)
    }
}
