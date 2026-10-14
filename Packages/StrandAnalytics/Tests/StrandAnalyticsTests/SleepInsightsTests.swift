import XCTest
@testable import StrandAnalytics

final class SleepInsightsTests: XCTestCase {

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

    private func night(_ i: Int, bed: Double = 23 * 60, inBed: Double = 480, asleep: Double? = 440,
                       latency: Double? = nil, recovery: Double? = nil, free: Bool? = nil) -> Night {
        let d = day(i)
        return Night(wakeDay: d.key, bedtimeClockMin: bed, inBedMin: inBed, asleepMin: asleep,
                     latencyMin: latency, recovery: recovery, isFreeDay: free ?? d.free)
    }

    // MARK: Helpers

    func testSignedClockHandlesPastMidnight() throws {
        XCTAssertEqual(SleepInsights.signedClock(22 * 60 + 30), -90)
        XCTAssertEqual(SleepInsights.signedClock(30), 30)
        XCTAssertEqual(SleepInsights.signedClock(0), 0)
        XCTAssertEqual(SleepInsights.signedClock(12 * 60), -720)
        XCTAssertEqual(SleepInsights.clock(fromSigned: -90), 22 * 60 + 30)
        XCTAssertEqual(SleepInsights.clock(fromSigned: 45), 45)
    }

    func testNormalizedKeepsLongestNightPerDay() throws {
        let nights = [night(1, inBed: 60), night(0), night(1, inBed: 500)]
        let n = SleepInsights.normalized(nights)
        XCTAssertEqual(n.count, 2)
        XCTAssertEqual(n.map(\.wakeDay), [day(0).key, day(1).key])
        XCTAssertEqual(n[1].inBedMin, 500)
    }

    // MARK: 1. Latency

    func testLatencyTypicalAndRecentFaster() throws {
        // 23 nights at 20 min, then 7 at 10 min: typical median of 30 = 20, recent = 10.
        var nights = (0..<23).map { night($0, latency: 20) }
        nights += (23..<30).map { night($0, latency: 10) }
        let l = try XCTUnwrap(SleepInsights.latency(nights))
        XCTAssertEqual(l.typicalMin, 20)
        XCTAssertEqual(l.recentMin, 10)
        XCTAssertEqual(l.deltaMin, -10)
        XCTAssertEqual(l.trend, .faster)
        XCTAssertEqual(l.nightCount, 30)
        XCTAssertEqual(l.series.count, 30)
        XCTAssertEqual(l.recentDays.last, day(29).key)
    }

    func testLatencyUsesOnlyLastThirtyAndDropsImplausible() throws {
        // 40 old nights at 50 min fall outside the window; a 400-min gap is ignored.
        var nights = (0..<40).map { night($0, latency: 50) }
        nights += (40..<70).map { night($0, latency: 12) }
        nights.append(night(70, latency: 400))
        let l = try XCTUnwrap(SleepInsights.latency(nights))
        XCTAssertEqual(l.typicalMin, 12)
        XCTAssertEqual(l.trend, .steady)
    }

    func testLatencyNeedsFourteenNights() throws {
        XCTAssertNil(SleepInsights.latency((0..<13).map { night($0, latency: 15) }))
        XCTAssertNotNil(SleepInsights.latency((0..<14).map { night($0, latency: 15) }))
        // Nights without a staged timeline do not count.
        let mixed = (0..<20).map { night($0, latency: $0 % 2 == 0 ? 15 : nil) }
        XCTAssertNil(SleepInsights.latency(mixed))
    }

    // MARK: 2. Sleep need

    func testSleepNeedPicksShortestBinNearTheBest() throws {
        // 6:00–6:30 → 45, 7:00–7:30 → 60, 7:30–8:00 → 72, 8:30–9:00 → 74. Best is 74; the shortest
        // bin within 5 points is 7:30–8:00 (center 7 h 45 min).
        let plan: [(Double, Double)] = [(375, 45), (430, 60), (465, 72), (525, 74)]
        var nights: [Night] = []
        var i = 0
        for (asleep, rec) in plan { for _ in 0..<4 { nights.append(night(i, asleep: asleep, recovery: rec)); i += 1 } }
        let need = try XCTUnwrap(SleepInsights.sleepNeed(nights))
        XCTAssertEqual(need.best.lower, 450)
        XCTAssertEqual(need.best.center, 465)
        XCTAssertEqual(need.bins.count, 4)
        XCTAssertEqual(need.spreadPts, 29)
        XCTAssertFalse(need.isFlat)
        XCTAssertEqual(need.nightCount, 16)
    }

    func testSleepNeedIgnoresBinsWithTooFewNights() throws {
        // A two-night bin at 9:30 with recovery 99 must not win.
        var nights = (0..<8).map { night($0, asleep: 420, recovery: 55) }
        nights += (8..<14).map { night($0, asleep: 480, recovery: 70) }
        nights += [night(14, asleep: 575, recovery: 99), night(15, asleep: 575, recovery: 99)]
        let need = try XCTUnwrap(SleepInsights.sleepNeed(nights))
        XCTAssertEqual(need.best.lower, 480)
        XCTAssertEqual(need.bins.count, 2)
    }

    func testSleepNeedFlatWhenRecoveryDoesNotMove() throws {
        let nights = (0..<16).map { night($0, asleep: $0 % 2 == 0 ? 420 : 480, recovery: 60 + Double($0 % 3)) }
        let need = try XCTUnwrap(SleepInsights.sleepNeed(nights))
        XCTAssertTrue(need.isFlat)
    }

    func testSleepNeedInsufficientData() throws {
        XCTAssertNil(SleepInsights.sleepNeed((0..<13).map { night($0, asleep: 420 + Double($0 % 2) * 60, recovery: 60) }))
        // Enough nights but all in one bin: nothing to compare.
        XCTAssertNil(SleepInsights.sleepNeed((0..<20).map { night($0, asleep: 440, recovery: 60) }))
        // Recovery missing.
        XCTAssertNil(SleepInsights.sleepNeed((0..<20).map { night($0, asleep: 420 + Double($0 % 2) * 60) }))
    }

    // MARK: 3. Bedtime

    func testBedtimeWindowAcrossMidnight() throws {
        // 22:30 → 80, 23:30 → 65, 00:15 → 50, 01:10 → 40. Past-midnight bedtimes must sort after the evening.
        let plan: [(Double, Double)] = [(22 * 60 + 35, 80), (23 * 60 + 35, 65), (15, 50), (70, 40)]
        var nights: [Night] = []
        var i = 0
        for (bed, rec) in plan { for _ in 0..<4 { nights.append(night(i, bed: bed, recovery: rec)); i += 1 } }
        let b = try XCTUnwrap(SleepInsights.bedtime(nights))
        XCTAssertEqual(b.best.lower, -90)  // 22:30
        XCTAssertEqual(b.best.upper, -60)  // 23:00
        XCTAssertEqual(b.bins.map(\.lower), [-90, -30, 0, 60])
        XCTAssertEqual(b.spreadPts, 40)
    }

    func testBedtimeBestAfterMidnight() throws {
        var nights = (0..<8).map { night($0, bed: 23 * 60 + 10, recovery: 50) }
        nights += (8..<16).map { night($0, bed: 40, recovery: 75) }
        let b = try XCTUnwrap(SleepInsights.bedtime(nights))
        XCTAssertEqual(b.best.lower, 30)
        XCTAssertEqual(SleepInsights.clock(fromSigned: b.best.lower), 30)
    }

    func testBedtimeInsufficientData() throws {
        XCTAssertNil(SleepInsights.bedtime((0..<10).map { night($0, bed: $0 % 2 == 0 ? 1380 : 10, recovery: 60) }))
    }

    // MARK: 4. Consistency

    func testConsistencyRegularNightsRecoverBetter() throws {
        // Usual bedtime 23:00. 10 regular nights (±10 min) at 70, 6 irregular (±90 min, across midnight) at 55.
        var nights = (0..<10).map { night($0, bed: 23 * 60 + ($0 % 2 == 0 ? 10 : -10), recovery: 70) }
        nights += (10..<16).map { night($0, bed: $0 % 2 == 0 ? 30 : 21 * 60 + 30, recovery: 55) }
        let c = try XCTUnwrap(SleepInsights.consistency(nights))
        XCTAssertEqual(c.regularCount, 10)
        XCTAssertEqual(c.irregularCount, 6)
        XCTAssertEqual(c.deltaPts, 15)
        XCTAssertEqual(c.effect, .regularBetter)
        XCTAssertEqual(c.points.count, 16)
    }

    func testConsistencyNoEffectAndInsufficient() throws {
        var nights = (0..<10).map { night($0, bed: 23 * 60, recovery: 61) }
        nights += (10..<16).map { night($0, bed: 60, recovery: 60) }
        XCTAssertEqual(try XCTUnwrap(SleepInsights.consistency(nights)).effect, .none)
        // Only regular nights: no comparison possible.
        XCTAssertNil(SleepInsights.consistency((0..<20).map { night($0, bed: 23 * 60, recovery: 60) }))
    }

    // MARK: 5. Weekend shift

    func testWeekendShiftMidSleep() throws {
        // Workdays: bed 23:00, 8 h → mid 03:00 (180). Free days: bed 00:30, 8 h → mid 04:30 (270).
        let nights = (0..<28).map { i -> Night in
            let free = day(i).free
            return night(i, bed: free ? 30 : 23 * 60, inBed: 480)
        }
        let w = try XCTUnwrap(SleepInsights.weekendShift(nights))
        XCTAssertEqual(w.workdayMidSleepSignedMin, 180)
        XCTAssertEqual(w.freeDayMidSleepSignedMin, 270)
        XCTAssertEqual(w.shiftMin, 90)
        XCTAssertEqual(w.freeDayCount, 8)
        XCTAssertEqual(w.workdayCount, 20)
    }

    func testWeekendShiftInsufficient() throws {
        // One week: only two free days.
        XCTAssertNil(SleepInsights.weekendShift((0..<7).map { night($0) }))
    }

    // MARK: Report

    func testReportEmptyWithoutData() throws {
        XCTAssertTrue(SleepInsights.report([]).isEmpty)
        XCTAssertTrue(SleepInsights.report((0..<5).map { night($0, latency: 10, recovery: 60) }).isEmpty)
    }
}
