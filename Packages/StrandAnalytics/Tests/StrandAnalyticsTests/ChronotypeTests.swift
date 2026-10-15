import XCTest
@testable import StrandAnalytics

final class ChronotypeTests: XCTestCase {

    typealias Night = SleepInsights.Night

    /// "yyyy-MM-dd" for day `i` after 2026-01-05 (a Monday), plus whether it is a Saturday or Sunday.
    private func day(_ i: Int) -> (key: String, free: Bool) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let d = cal.date(byAdding: .day, value: i, to: base)!
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: d)
        let key = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return (key, c.weekday == 1 || c.weekday == 7)
    }

    /// `days` nights; work nights in bed from `workBed`, free nights from `freeBed`, both `inBed` long.
    private func nights(_ days: Int, workBed: Double, freeBed: Double, inBed: Double = 480,
                        freeInBed: Double? = nil) -> [Night] {
        (0..<days).map { i in
            let d = day(i)
            let len = d.free ? (freeInBed ?? inBed) : inBed
            return Night(wakeDay: d.key, bedtimeClockMin: d.free ? freeBed : workBed, inBedMin: len,
                         asleepMin: len, latencyMin: nil, recovery: nil, isFreeDay: d.free)
        }
    }

    func testTooFewNightsGiveNoProfile() {
        XCTAssertNil(Chronotype.profile(nights(6, workBed: 23 * 60, freeBed: 23 * 60)))
        XCTAssertNotNil(Chronotype.profile(nights(7, workBed: 23 * 60, freeBed: 23 * 60)))
    }

    /// 22:00–06:00 every night: mid-sleep 02:00, an early type with no social jetlag.
    func testEarlySleeperIsEarlyType() throws {
        let p = try XCTUnwrap(Chronotype.profile(nights(28, workBed: 22 * 60, freeBed: 22 * 60)))
        XCTAssertEqual(p.kind, .early)
        XCTAssertEqual(p.habitualMidSleepSignedMin, 120, accuracy: 0.001)
        XCTAssertEqual(p.socialJetlagMin ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(p.jetlagBand, .low)
        XCTAssertEqual(p.spreadMin, 0, accuracy: 0.001)
        XCTAssertTrue(p.isSolid)
    }

    /// 23:30 on workdays, 01:00 on free days, same length: MSF 05:00, a late type with 90 min jetlag.
    func testLateWeekendsGiveLateTypeAndModerateJetlag() throws {
        let p = try XCTUnwrap(Chronotype.profile(nights(28, workBed: 23 * 60 + 30, freeBed: 60)))
        XCTAssertEqual(p.freeDayMidSleepSignedMin ?? 0, 300, accuracy: 0.001)
        XCTAssertEqual(p.workdayMidSleepSignedMin ?? 0, 210, accuracy: 0.001)
        XCTAssertEqual(p.socialJetlagMin ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(p.jetlagBand, .moderate)
        XCTAssertEqual(p.kind, .late)
        XCTAssertTrue(p.spreadMin > 0)
    }

    /// Catch-up sleep on free days pulls MSFsc earlier than the raw free-day mid-sleep.
    func testCatchUpSleepIsCorrected() throws {
        // Work 23:00 + 7 h (mid 02:30); free 00:00 + 10 h (mid 05:00).
        let p = try XCTUnwrap(Chronotype.profile(nights(28, workBed: 23 * 60, freeBed: 0, inBed: 420,
                                                        freeInBed: 600)))
        let sdWeek = (5.0 * 420 + 2 * 600) / 7
        XCTAssertEqual(p.chronotypeMidSleepSignedMin, 300 - (600 - sdWeek) / 2, accuracy: 0.001)
        XCTAssertEqual(p.kind, .intermediate)
    }

    /// Without free nights the all-night median stands in and the profile is not solid.
    func testWithoutFreeDaysFallsBackToHabitualMidSleep() throws {
        let workOnly = nights(14, workBed: 0, freeBed: 0).filter { !$0.isFreeDay }
        let p = try XCTUnwrap(Chronotype.profile(workOnly))
        XCTAssertFalse(p.usesFreeDays)
        XCTAssertNil(p.socialJetlagMin)
        XCTAssertEqual(p.chronotypeMidSleepSignedMin, p.habitualMidSleepSignedMin)
        XCTAssertEqual(p.kind, .intermediate)
        XCTAssertFalse(p.isSolid)
    }

    func testBandEdges() {
        XCTAssertEqual(Chronotype.kind(midSleepSignedMin: 209), .early)
        XCTAssertEqual(Chronotype.kind(midSleepSignedMin: 210), .intermediate)
        XCTAssertEqual(Chronotype.kind(midSleepSignedMin: 300), .late)
        XCTAssertEqual(Chronotype.jetlagBand(59), .low)
        XCTAssertEqual(Chronotype.jetlagBand(60), .moderate)
        XCTAssertEqual(Chronotype.jetlagBand(120), .high)
    }

    /// Only the newest `window` nights count: an old late phase does not leak into today's type.
    func testOnlyRecentWindowCounts() throws {
        let old = nights(30, workBed: 2 * 60, freeBed: 2 * 60)
        let recent = (30..<72).map { i -> Night in
            let d = day(i)
            return Night(wakeDay: d.key, bedtimeClockMin: 22 * 60, inBedMin: 480, asleepMin: 480,
                         latencyMin: nil, recovery: nil, isFreeDay: d.free)
        }
        let p = try XCTUnwrap(Chronotype.profile(old + recent))
        XCTAssertEqual(p.nightCount, Chronotype.window)
        XCTAssertEqual(p.kind, .early)
    }
}
