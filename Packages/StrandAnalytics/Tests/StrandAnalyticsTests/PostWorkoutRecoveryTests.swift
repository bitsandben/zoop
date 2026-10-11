import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class PostWorkoutRecoveryTests: XCTestCase {
    private let end = 100_000
    private typealias P = PostWorkoutRecovery

    /// Five minutes of Zone-3+ effort ending at 170 bpm, then one sample per second following `after`
    /// (seconds after the end -> bpm) for `seconds` seconds.
    private func samples(seconds: Int, after: (Int) -> Int?) -> [HRSample] {
        var out = (end - 300...end).map { HRSample(ts: $0, bpm: $0 >= end - 30 ? 170 : 150) }
        for t in stride(from: 1, to: seconds, by: 1) { if let bpm = after(t) { out.append(HRSample(ts: end + t, bpm: bpm)) } }
        return out
    }

    private func days(_ n: Int, rhr: Double? = 55, hrv: Double? = 60, recovery: Double? = 70) -> [P.DayReading] {
        Array(repeating: P.DayReading(restingHr: rhr, hrv: hrv, recovery: recovery), count: n)
    }

    // MARK: HRR

    func testHRR1AndHRR2FromSamplesAfterTheEnd() {
        let s = samples(seconds: 200) { t in t < 90 ? 140 : 125 }
        let r = P.analyze(samples: s, workoutStart: end - 3600, workoutEnd: end, maxHR: 200,
                          baselineDays: [], nextMorning: nil, now: end + 300)
        XCTAssertEqual(r.hrr1, 30)
        XCTAssertEqual(r.hrr2, 45)
        XCTAssertEqual(r.verdict, .fast)
    }

    func testNoHRRWithoutPostWorkoutSamples() {
        let s = samples(seconds: 0) { _ in nil }
        let r = P.analyze(samples: s, workoutStart: end - 3600, workoutEnd: end, maxHR: 200,
                          baselineDays: days(10), nextMorning: nil, now: end + 60)
        XCTAssertNil(r.hrr1)
        XCTAssertNil(r.hrr2)
        XCTAssertNil(r.verdict)
        XCTAssertFalse(r.hasAnything)
    }

    // MARK: Time back to near resting

    func testMinutesToNearRestingNeedsAHeldRun() {
        // Resting 55 → limit 70. Minute 10 dips once, then from minute 30 it stays.
        let curve = (0..<60).map { m in
            P.MinutePoint(minute: m, bpm: m == 10 ? 65 : (m >= 30 ? 68 : 95))
        }
        XCTAssertEqual(P.minutesToNearResting(curve: curve, resting: 55), 30)
    }

    func testMinutesToNearRestingGapBreaksTheRun() {
        let curve = [0, 1, 2, 4, 5, 6, 7, 8].map { P.MinutePoint(minute: $0, bpm: 60) }
        XCTAssertEqual(P.minutesToNearResting(curve: curve, resting: 55), 4)
    }

    func testMinutesToNearRestingNilWhenNeverReached() {
        let curve = (0..<180).map { P.MinutePoint(minute: $0, bpm: 90) }
        XCTAssertNil(P.minutesToNearResting(curve: curve, resting: 55))
    }

    func testMinuteCurveDropsSparseMinutes() {
        let s = [HRSample(ts: end + 1, bpm: 100), HRSample(ts: end + 2, bpm: 110), HRSample(ts: end + 3, bpm: 120),
                 HRSample(ts: end + 61, bpm: 90)]
        XCTAssertEqual(P.minuteCurve(samples: s, from: end, minutes: 3), [P.MinutePoint(minute: 0, bpm: 110)])
    }

    // MARK: Afterburn

    func testAfterburnAverageVersusResting() {
        let s = samples(seconds: 3 * 3600) { t in t < 3600 ? 90 : 68 }
        let r = P.analyze(samples: s, workoutStart: end - 3600, workoutEnd: end, maxHR: 200,
                          baselineDays: days(14), nextMorning: nil, now: end + 4 * 3600)
        XCTAssertEqual(r.afterburnAvg ?? 0, 68, accuracy: 0.001)
        XCTAssertEqual(r.afterburnDelta ?? 0, 13, accuracy: 0.001)
        XCTAssertEqual(r.minutesToNearResting, 60)
    }

    func testAfterburnNilWithTooLittleCoverage() {
        let curve = (60..<70).map { P.MinutePoint(minute: $0, bpm: 80) }
        XCTAssertNil(P.afterburnAverage(curve: curve))
    }

    func testRestingBaselineNeedsSevenDays() {
        let s = samples(seconds: 3 * 3600) { _ in 72 }
        let r = P.analyze(samples: s, workoutStart: end - 3600, workoutEnd: end, maxHR: 200,
                          baselineDays: days(6), nextMorning: nil, now: end + 4 * 3600)
        XCTAssertNil(r.restingBaseline)
        XCTAssertNil(r.minutesToNearResting)
        XCTAssertNil(r.afterburnDelta)
        XCTAssertNotNil(r.afterburnAvg)
    }

    // MARK: Next morning

    func testMorningDeltasAgainstThirtyDayMeans() {
        let baseline = days(10, rhr: 50, hrv: 80, recovery: 60) + days(10, rhr: 60, hrv: 60, recovery: 80)
        let impact = P.morningImpact(next: .init(restingHr: 58, hrv: 62, recovery: 55), baseline: baseline)
        XCTAssertEqual(impact.restingHr?.delta ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(impact.hrv?.delta ?? 0, -8, accuracy: 0.001)
        XCTAssertEqual(impact.recovery?.delta ?? 0, -15, accuracy: 0.001)
    }

    func testMorningMetricWithoutEnoughHistoryIsDropped() {
        let baseline = days(10, hrv: nil) + days(3, rhr: nil, hrv: 70, recovery: nil)
        let impact = P.morningImpact(next: .init(restingHr: 52, hrv: 75, recovery: nil), baseline: baseline)
        XCTAssertNotNil(impact.restingHr)
        XCTAssertNil(impact.hrv)
        XCTAssertNil(impact.recovery)
    }

    // MARK: Verdict

    func testVerdictThresholdsFromHRR1() {
        XCTAssertEqual(P.verdict(hrr1: 25, minutesToResting: nil, windowClosed: false), .fast)
        XCTAssertEqual(P.verdict(hrr1: 18, minutesToResting: 5, windowClosed: true), .normal)
        XCTAssertEqual(P.verdict(hrr1: 12, minutesToResting: 5, windowClosed: true), .slow)
    }

    func testVerdictFallsBackToTimeBackToResting() {
        XCTAssertEqual(P.verdict(hrr1: nil, minutesToResting: 30, windowClosed: false), .fast)
        XCTAssertEqual(P.verdict(hrr1: nil, minutesToResting: 90, windowClosed: false), .normal)
        XCTAssertEqual(P.verdict(hrr1: nil, minutesToResting: 91, windowClosed: false), .slow)
        XCTAssertEqual(P.verdict(hrr1: nil, minutesToResting: nil, windowClosed: true), .slow)
        XCTAssertNil(P.verdict(hrr1: nil, minutesToResting: nil, windowClosed: false))
    }

    func testOpenWindowIsNotCalledSlow() {
        let s = samples(seconds: 3 * 3600) { _ in 100 }
        let open = P.analyze(samples: s, workoutStart: end - 3600, workoutEnd: end, maxHR: 1000,
                             baselineDays: days(10), nextMorning: nil, now: end + 3600)
        XCTAssertNil(open.verdict)
        let closed = P.analyze(samples: s, workoutStart: end - 3600, workoutEnd: end, maxHR: 1000,
                               baselineDays: days(10), nextMorning: nil, now: end + 3 * 3600)
        XCTAssertEqual(closed.verdict, .slow)
    }

    // MARK: Trend

    func testTrendAgainstRecentWorkouts() {
        XCTAssertEqual(P.trend(currentHRR1: 30, recentHRR1: [24, 26, 28]), .init(kind: .faster, delta: 4))
        XCTAssertEqual(P.trend(currentHRR1: 20, recentHRR1: [24, 26, 28]), .init(kind: .slower, delta: -6))
        XCTAssertEqual(P.trend(currentHRR1: 27, recentHRR1: [24, 26, 28]), .init(kind: .usual, delta: 1))
        XCTAssertNil(P.trend(currentHRR1: 27, recentHRR1: [24, 26]))
    }
}
