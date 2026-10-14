import XCTest
@testable import StrandAnalytics

final class BodyInsightsTests: XCTestCase {

    // 2026-01-05 is a Monday.
    private let start = BodyInsights.dayNumber("2026-01-05")!
    private func day(_ i: Int) -> String { BodyInsights.dayString(start + i) }

    /// A deterministic ±2 wobble so baselines have a spread.
    private func wobble(_ i: Int) -> Double { [0, 2, -2, 1, -1][i % 5] }

    // MARK: Day arithmetic

    func testDayArithmeticRoundTripsAndWeekdays() {
        XCTAssertEqual(BodyInsights.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(BodyInsights.dayString(0), "1970-01-01")
        for s in ["2024-02-29", "2026-01-05", "2026-12-31", "1999-03-01"] {
            XCTAssertEqual(BodyInsights.dayString(BodyInsights.dayNumber(s)!), s)
        }
        XCTAssertEqual(BodyInsights.isoWeekday(start), 1)        // Monday
        XCTAssertEqual(BodyInsights.isoWeekday(start + 6), 7)    // Sunday
        XCTAssertEqual(BodyInsights.isoWeekday(0), 4)            // 1970-01-01, Thursday
        XCTAssertEqual(BodyInsights.weekIndex(start), BodyInsights.weekIndex(start + 6))
        XCTAssertEqual(BodyInsights.weekIndex(start) + 1, BodyInsights.weekIndex(start + 7))
        XCTAssertNil(BodyInsights.dayNumber("not-a-day"))
    }

    // MARK: 1. Direction

    func testHRVBelowNormalForFourDays() throws {
        var v: [BodyInsights.DayValue] = (0..<56).map { .init(day: day($0), value: 60 + wobble($0)) }
        for i in 56..<60 { v.append(.init(day: day(i), value: 50)) }
        let d = try XCTUnwrap(BodyInsights.direction(v, asOf: day(59)))
        XCTAssertEqual(d.trend, .belowStreak)
        XCTAssertEqual(d.streakDays, 4)
        XCTAssertLessThan(d.deltaPercent, 0)
        XCTAssertEqual(d.series.count, 30)
        XCTAssertEqual(d.baselineMean, 60, accuracy: 0.5)
    }

    func testRestingHRAboveNormalForAWeek() throws {
        var v: [BodyInsights.DayValue] = (0..<53).map { .init(day: day($0), value: 52 + wobble($0)) }
        for i in 53..<60 { v.append(.init(day: day(i), value: 60)) }
        let d = try XCTUnwrap(BodyInsights.direction(v))
        XCTAssertEqual(d.trend, .aboveStreak)
        XCTAssertEqual(d.streakDays, 7)
        XCTAssertEqual(d.recentMean, 60, accuracy: 1e-9)
    }

    func testHigherWeekWithoutARun() throws {
        var v: [BodyInsights.DayValue] = (0..<53).map { .init(day: day($0), value: 60) }
        // Alternating high and normal days: the week is higher, but no three days in a row.
        for (k, i) in (53..<60).enumerated() { v.append(.init(day: day(i), value: k % 2 == 1 ? 66 : 60)) }
        let d = try XCTUnwrap(BodyInsights.direction(v))
        XCTAssertEqual(d.trend, .higherThisWeek)
        XCTAssertEqual(d.streakDays, 0)
    }

    func testSteadyWhenNothingMoves() throws {
        let v: [BodyInsights.DayValue] = (0..<60).map { .init(day: day($0), value: 60 + wobble($0)) }
        let d = try XCTUnwrap(BodyInsights.direction(v))
        XCTAssertEqual(d.trend, .steady)
        XCTAssertEqual(d.streakDays, 0)
    }

    func testDirectionNilWithoutEnoughOrStaleData() {
        let short: [BodyInsights.DayValue] = (0..<12).map { .init(day: day($0), value: 60) }
        XCTAssertNil(BodyInsights.direction(short))
        let full: [BodyInsights.DayValue] = (0..<60).map { .init(day: day($0), value: 60 + wobble($0)) }
        XCTAssertNil(BodyInsights.direction(full, asOf: day(70)))
        XCTAssertNil(BodyInsights.direction([]))
    }

    // MARK: 2. Weekday

    func testMondayIsReliablyLowest() throws {
        let v: [BodyInsights.DayValue] = (0..<112).map { i in
            .init(day: day(i), value: (i % 7 == 0 ? 50 : 70) + wobble(i))
        }
        let w = try XCTUnwrap(BodyInsights.weekday(v))
        let low = try XCTUnwrap(w.lowest)
        XCTAssertEqual(low.weekday, 1)
        XCTAssertLessThanOrEqual(low.gap, -8)
        XCTAssertEqual(low.consistency, 1, accuracy: 1e-9)
        XCTAssertNil(w.highest)
        XCTAssertEqual(w.weeks, 16)
    }

    func testSundayIsReliablyHighest() throws {
        let v: [BodyInsights.DayValue] = (0..<112).map { i in
            .init(day: day(i), value: (i % 7 == 6 ? 85 : 65) + wobble(i))
        }
        let w = try XCTUnwrap(BodyInsights.weekday(v))
        XCTAssertEqual(w.highest?.weekday, 7)
        XCTAssertNil(w.lowest)
    }

    func testWeekdayNilWithoutPatternOrHistory() {
        let flat: [BodyInsights.DayValue] = (0..<112).map { .init(day: day($0), value: 70 + wobble($0)) }
        XCTAssertNil(BodyInsights.weekday(flat))
        let short: [BodyInsights.DayValue] = (0..<35).map { i in
            .init(day: day(i), value: i % 7 == 0 ? 40 : 70)
        }
        XCTAssertNil(BodyInsights.weekday(short))
    }

    // MARK: 3. Bounce-back

    /// Every fourth day is hard (effort 90); the next morning sits 17 below normal, the one after is back.
    private func bounceDays(_ n: Int) -> [BodyInsights.DayLoad] {
        (0..<n).map { i in
            let phase = i % 4
            let strain: Double = [90, 30, 40, 50][phase]
            let recovery: Double = phase == 1 ? 55 : 72
            return .init(day: day(i), strain: strain, recovery: recovery)
        }
    }

    func testBounceBackTakesTwoMornings() throws {
        let b = try XCTUnwrap(BodyInsights.bounceBack(bounceDays(160)))
        XCTAssertEqual(b.medianDays, 2)
        XCTAssertEqual(b.hardThreshold, 90)
        XCTAssertEqual(b.nextMorningDip, -17, accuracy: 1e-9)
        XCTAssertEqual(b.unresolved, 0)
        XCTAssertEqual(b.trajectory.count, 8)
        XCTAssertEqual(b.trajectory[1] ?? 0, -17, accuracy: 1e-9)
        XCTAssertEqual(b.trajectory[2] ?? 1, 0, accuracy: 1e-9)
    }

    func testBounceBackNilWithFewDays() {
        XCTAssertNil(BodyInsights.bounceBack(bounceDays(20)))
        XCTAssertNil(BodyInsights.bounceBack([]))
    }

    // MARK: 4. Zone mix

    func testZoneMixMostlyEasy() throws {
        let m = try XCTUnwrap(BodyInsights.zoneMix(sessions: Array(repeating: [30, 20, 5, 3, 2], count: 4)))
        XCTAssertEqual(m.sessions, 4)
        XCTAssertEqual(m.totalMinutes, 240, accuracy: 1e-9)
        XCTAssertEqual(m.easyShare, 50.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(m.style, .mostlyEasy)
    }

    func testZoneMixMostlyHardAndPadding() throws {
        let m = try XCTUnwrap(BodyInsights.zoneMix(sessions: [[5, 5, 20, 20], [0, 10, 20, 10, 10], [5, 5, 10, 10, 10], []]))
        XCTAssertEqual(m.sessions, 3)
        XCTAssertEqual(m.style, .mostlyHard)
        XCTAssertEqual(m.hardShare, 110.0 / 140.0, accuracy: 1e-9)
    }

    func testZoneMixNilWhenThin() {
        XCTAssertNil(BodyInsights.zoneMix(sessions: [[60, 30, 10, 0, 0], [60, 30, 10, 0, 0]]))
        XCTAssertNil(BodyInsights.zoneMix(sessions: Array(repeating: [5, 5, 5, 5, 5], count: 3)))
    }

    // MARK: 5. Stress timing

    private func stressDays(_ n: Int, peak: Int?, calm: Int?) -> [[BodyInsights.HourLevel]] {
        (0..<n).map { d in
            (8...21).map { h in
                var level = 1.2 + 0.05 * Double((d + h) % 3)
                if h == peak { level = 2.5 }
                if h == calm { level = 0.3 }
                return .init(hour: h, level: level)
            }
        }
    }

    func testStressPeaksMidAfternoon() throws {
        let s = try XCTUnwrap(BodyInsights.stressTiming(days: stressDays(10, peak: 15, calm: 8)))
        XCTAssertEqual(s.peakHour, 15)
        XCTAssertEqual(s.calmHour, 8)
        XCTAssertEqual(s.peakMean, 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.consistency, 1, accuracy: 1e-9)
        XCTAssertEqual(s.days, 10)
        XCTAssertEqual(s.hourMeans.count, 14)
    }

    func testStressTimingNilWhenFlatOrShort() {
        XCTAssertNil(BodyInsights.stressTiming(days: stressDays(10, peak: nil, calm: nil)))
        XCTAssertNil(BodyInsights.stressTiming(days: stressDays(5, peak: 15, calm: 8)))
        XCTAssertNil(BodyInsights.stressTiming(days: []))
    }

    // MARK: 6. Strain sensitivity

    private func sensitivityDays(_ n: Int, slope: Double) -> [BodyInsights.DayLoad] {
        // Effort on day i, and recovery on day i + 1 that follows it exactly.
        let strain = (0...n).map { 20 + Double(($0 * 37) % 60) }
        return (0...n).map { i in
            .init(day: day(i), strain: strain[i], recovery: i == 0 ? nil : 80 + slope * strain[i - 1])
        }
    }

    func testStrongSensitivityRecoversTrueSlope() throws {
        let s = try XCTUnwrap(BodyInsights.strainSensitivity(sensitivityDays(60, slope: -0.4)))
        XCTAssertEqual(s.pointsPer10, -4, accuracy: 1e-9)
        XCTAssertEqual(s.correlation, -1, accuracy: 1e-9)
        XCTAssertEqual(s.level, .strong)
        XCTAssertLessThan(s.splitDelta, 0)
        XCTAssertEqual(s.pairs, 60)
    }

    func testNoticeableAndLittleSensitivity() throws {
        let mid = try XCTUnwrap(BodyInsights.strainSensitivity(sensitivityDays(60, slope: -0.15)))
        XCTAssertEqual(mid.pointsPer10, -1.5, accuracy: 1e-9)
        XCTAssertEqual(mid.level, .noticeable)
        let none = try XCTUnwrap(BodyInsights.strainSensitivity(sensitivityDays(60, slope: 0)))
        XCTAssertEqual(none.pointsPer10, 0, accuracy: 1e-9)
        XCTAssertEqual(none.level, .little)
    }

    func testSensitivityNilWhenThinOrFlatEffort() {
        XCTAssertNil(BodyInsights.strainSensitivity(sensitivityDays(10, slope: -0.4)))
        let flat: [BodyInsights.DayLoad] = (0..<60).map { .init(day: day($0), strain: 50, recovery: 70) }
        XCTAssertNil(BodyInsights.strainSensitivity(flat))
    }
}
