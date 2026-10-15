import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class MindfulPracticeTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }()

    /// Wednesday 2026-10-14 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_979_200)
    private func ts(daysAgo: Int, hour: Int = 8) -> Int {
        Int(cal.startOfDay(for: now).timeIntervalSince1970) - daysAgo * 86_400 + hour * 3_600
    }
    private func session(_ daysAgo: Int, minutes: Int = 10, kind: MindfulPractice.Kind = .meditation,
                         source: MindfulPractice.Source = .app, hour: Int = 8) -> MindfulPractice.Session {
        let s = ts(daysAgo: daysAgo, hour: hour)
        return .init(startTs: s, endTs: s + minutes * 60, kind: kind, source: source)
    }

    func testSportMapping() {
        XCTAssertEqual(MindfulPractice.kind(forSport: "Yoga"), .yoga)
        XCTAssertEqual(MindfulPractice.kind(forSport: "Meditation"), .meditation)
        XCTAssertEqual(MindfulPractice.kind(forSport: "MindAndBody"), .meditation)
        XCTAssertEqual(MindfulPractice.kind(forSport: "Pilates"), .pilates)
        XCTAssertEqual(MindfulPractice.kind(forSport: "taiChi"), .taiChi)
        XCTAssertEqual(MindfulPractice.kind(forSport: "Flexibility"), .stretching)
        XCTAssertNil(MindfulPractice.kind(forSport: "Running"))
        XCTAssertNil(MindfulPractice.kind(forSport: "Functional Strength Training"))
    }

    func testMergeDropsShortAndKeepsHigherPrecedenceOnOverlap() {
        let health = MindfulPractice.Session(startTs: 1_000, endTs: 1_900, kind: .meditation, source: .appleHealth)
        let yoga = MindfulPractice.Session(startTs: 1_200, endTs: 2_400, kind: .yoga, source: .workout)
        let tap = MindfulPractice.Session(startTs: 5_000, endTs: 5_030, kind: .breathing, source: .app)
        let merged = MindfulPractice.merge([health, yoga, tap])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].kind, .yoga)
        XCTAssertEqual(merged[0].source, .workout)
        XCTAssertEqual(merged[0].startTs, 1_000)
        XCTAssertEqual(merged[0].endTs, 2_400)
    }

    func testSummaryEmpty() {
        let s = MindfulPractice.summary([], now: now, calendar: cal)
        XCTAssertEqual(s.minutesThisWeek, 0)
        XCTAssertNil(s.typicalWeekMinutes)
        XCTAssertEqual(s.streakDays, 0)
    }

    func testSummaryRollingWeekAndNormalWeekNeedsHistory() {
        // Last 7 days: three sessions on three days. Earlier: one session in each of two windows.
        var sessions = [session(0), session(1), session(2, minutes: 20)]
        sessions += [session(9, minutes: 30), session(16, minutes: 40)]
        let s = MindfulPractice.summary(sessions, now: now, calendar: cal)
        XCTAssertEqual(s.minutesThisWeek, 40, accuracy: 0.001)
        XCTAssertEqual(s.sessionsThisWeek, 3)
        XCTAssertEqual(s.practiceDaysThisWeek, 3)
        XCTAssertEqual(s.pastWeekMinutes, [30, 40])
        XCTAssertNil(s.typicalWeekMinutes, "two weeks are not a normal week")
        XCTAssertNil(s.typicalMinutesRange)

        let more = sessions + [session(23, minutes: 50), session(24, minutes: 10)]
        let s2 = MindfulPractice.summary(more, now: now, calendar: cal)
        XCTAssertEqual(s2.pastWeekMinutes, [30, 40, 60])
        XCTAssertEqual(s2.pastWeekDays, [1, 1, 2])
        XCTAssertEqual(s2.typicalWeekMinutes ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(s2.typicalMinutesRange, 35...50)
    }

    func testStreakToleratesNoPracticeYetToday() {
        let s = [session(1), session(2), session(3), session(5)]
        XCTAssertEqual(MindfulPractice.streak(s, now: now, calendar: cal), 3)
        XCTAssertEqual(MindfulPractice.streak(s + [session(0)], now: now, calendar: cal), 4)
        XCTAssertEqual(MindfulPractice.streak([session(2)], now: now, calendar: cal), 0)
    }
}

final class MindfulResponseTests: XCTestCase {

    private func hr(from: Int, to: Int, bpm: Int) -> [HRSample] {
        stride(from: from, to: to, by: 1).map { HRSample(ts: $0, bpm: bpm) }
    }
    /// Beats alternating around `meanMs` by `swing`, one per second: RMSSD = 2 * swing.
    private func rr(from: Int, to: Int, meanMs: Int, swing: Int) -> [RRInterval] {
        stride(from: from, to: to, by: 1).enumerated().map { i, t in
            RRInterval(ts: t, rrMs: meanMs + (i % 2 == 0 ? swing : -swing))
        }
    }

    func testRelaxationResponseAgainstPreSessionWindow() throws {
        let start = 100_000, end = start + 20 * 60
        let hrData = hr(from: start - 600, to: start, bpm: 72) + hr(from: start, to: end, bpm: 64)
        let rrData = rr(from: start - 600, to: start, meanMs: 830, swing: 10)
            + rr(from: start, to: end, meanMs: 930, swing: 20)
        let r = try XCTUnwrap(MindfulResponse.evaluate(startTs: start, endTs: end, hr: hrData, rr: rrData))
        XCTAssertFalse(r.referenceIsOpening)
        XCTAssertEqual(r.hrDrop, 8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r.rmssdChangePercent), 100, accuracy: 0.5)
    }

    func testFallsBackToOpeningMinutesAndRefusesThinData() throws {
        let start = 200_000, end = start + 10 * 60
        let hrData = hr(from: start, to: start + 180, bpm: 80) + hr(from: start + 180, to: end, bpm: 70)
        let r = try XCTUnwrap(MindfulResponse.evaluate(startTs: start, endTs: end, hr: hrData, rr: []))
        XCTAssertTrue(r.referenceIsOpening)
        XCTAssertEqual(r.hrDrop, 10, accuracy: 0.001)
        XCTAssertNil(r.rmssdChangePercent)

        XCTAssertNil(MindfulResponse.evaluate(startTs: start, endTs: start + 4 * 60, hr: hrData, rr: []),
                     "too short to settle")
        XCTAssertNil(MindfulResponse.evaluate(startTs: start, endTs: end, hr: [], rr: []), "no data, no guess")
    }

    private func session(_ i: Int, drop: Double) -> MindfulResponse.Session {
        .init(startTs: i * 1_000, endTs: i * 1_000 + 600, hrBefore: 70, hrSettled: 70 - drop,
              rmssdBefore: nil, rmssdSettled: nil, referenceIsOpening: false)
    }

    func testProgressNeedsSampleSizeAndTracksRecoveringDepth() {
        let few = MindfulResponse.progress([session(1, drop: 3), session(2, drop: 4)])
        XCTAssertNil(few.meanHRDrop)
        XCTAssertEqual(few.trend, .notEnoughData)

        let deeper = MindfulResponse.progress((1...6).map { session($0, drop: $0 <= 3 ? 1 : 5) })
        XCTAssertEqual(deeper.meanHRDrop ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(deeper.trend, .deeper)
        XCTAssertEqual(deeper.settledShare ?? 0, 1, accuracy: 0.001)

        // Different injected values must move the result (not a fixed answer).
        let steady = MindfulResponse.progress((1...6).map { session($0, drop: 2) })
        XCTAssertEqual(steady.trend, .steady)
        let shallower = MindfulResponse.progress((1...8).map { session($0, drop: $0 <= 4 ? 6 : 0) })
        XCTAssertEqual(shallower.trend, .shallower)
        XCTAssertEqual(shallower.settledShare ?? 0, 0.5, accuracy: 0.001)
    }
}

final class MindfulOutcomesTests: XCTestCase {

    private func hour(_ startTs: Int, _ level: Double?) -> DaytimeStress.HourPoint {
        .init(hour: 0, startTs: startTs, level: level, meanHR: nil, rmssd: nil)
    }

    func testStressShiftUsesOnlyFullyContainedHours() throws {
        // Session 10:20-10:40 (t in seconds from midnight).
        let start = 10 * 3_600 + 1_200, end = 10 * 3_600 + 2_400
        let hours = [hour(8 * 3_600, 2.8), hour(9 * 3_600, 2.0), hour(10 * 3_600, 0.1),
                     hour(11 * 3_600, 1.2), hour(12 * 3_600, 0.4), hour(13 * 3_600, 0.0)]
        let s = try XCTUnwrap(MindfulOutcomes.stressShift(hours: hours, startTs: start, endTs: end))
        XCTAssertEqual(s.before, 2.0, accuracy: 0.001)   // only 9-10 lies inside the 2 h before
        XCTAssertEqual(s.after, 1.2, accuracy: 0.001)    // only 11-12 lies inside the 2 h after
        XCTAssertEqual(s.change, -0.8, accuracy: 0.001)
        XCTAssertNil(MindfulOutcomes.stressShift(hours: [hour(9 * 3_600, nil), hour(11 * 3_600, 1)],
                                                 startTs: start, endTs: end))
    }

    func testStressSummaryNeedsThreeSessions() {
        let two = [MindfulOutcomes.StressShift(before: 2, after: 1), .init(before: 1, after: 1.5)]
        XCTAssertNil(MindfulOutcomes.stressSummary(two).meanChange)
        let three = MindfulOutcomes.stressSummary(two + [.init(before: 2, after: 1.6)])
        XCTAssertEqual(three.meanChange ?? 0, (-1 + 0.5 - 0.4) / 3, accuracy: 0.0001)
        XCTAssertEqual(three.calmerShare ?? 0, 2.0 / 3, accuracy: 0.0001)
    }

    private func days(_ n: Int) -> [String] {
        (1...n).map { String(format: "2026-09-%02d", $0) }
    }

    func testNextNightContrastPairsWithFollowingMorning() {
        let ds = days(4)
        let values = ["2026-09-02": 50.0, "2026-09-03": 60, "2026-09-04": 70, "2026-09-05": 80]
        let c = MindfulOutcomes.nextNightContrast(days: ds, practiceDays: ["2026-09-01"], values: values)
        XCTAssertEqual(c.withPractice, 50)
        XCTAssertEqual(c.daysWith, 1)
        XCTAssertEqual(c.daysWithout, 3)
        XCTAssertEqual(c.comparison, .notEnoughDays)
    }

    func testContrastOnlyClaimsClearDifferences() {
        // Practice nights HRV ~70, other nights ~50, low noise: clear.
        let clear = MindfulOutcomes.contrast([69, 71, 70, 72, 68, 70], [50, 52, 48, 51, 49, 50])
        XCTAssertEqual(clear.comparison, .clearlyHigher)
        XCTAssertEqual(clear.difference ?? 0, 20, accuracy: 0.001)
        // Same means but huge scatter: not clear.
        let noisy = MindfulOutcomes.contrast([30, 110, 40, 100, 60, 80], [20, 90, 30, 70, 50, 40])
        XCTAssertEqual(noisy.comparison, .noClearDifference)
        let lower = MindfulOutcomes.contrast([55, 56, 54, 55, 56], [60, 61, 59, 60, 61])
        XCTAssertEqual(lower.comparison, .clearlyLower)
    }

    func testNextDayCrossesMonthEnd() {
        XCTAssertEqual(MindfulOutcomes.nextDay("2026-09-30"), "2026-10-01")
    }
}
