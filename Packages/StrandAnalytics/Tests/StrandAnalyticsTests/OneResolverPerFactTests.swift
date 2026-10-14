import XCTest
@testable import StrandAnalytics
import WhoopStore

/// The single resolvers WP-04 consolidated each fact into: the daily and headline stress level
/// (`DaytimeStress`), the illness history reading (`IllnessSignalEngine.reading`) and the Recovery
/// assessment. Each test recovers several injected values, not one (AGENTS.md physiological rule).
final class OneResolverPerFactTests: XCTestCase {

    private func day(_ i: Int, rhr: Int?, hrv: Double?, resp: Double? = nil, skin: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2026-05-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: skin, respRateBpm: resp)
    }

    /// A steady 28-night history with small alternating wobble so every spread is non-zero.
    private func history(nights: Int = 28) -> [DailyMetric] {
        (1...nights).map { i in
            day(i, rhr: i % 2 == 0 ? 54 : 52, hrv: i % 3 == 0 ? 64 : 58,
                resp: i % 2 == 0 ? 14.6 : 14.2, skin: i % 2 == 0 ? 0.1 : -0.1)
        }
    }

    // MARK: - Daily stress

    /// The view-layer formula the daily level replaced, kept verbatim as an oracle: population SD,
    /// RHR-up and HRV-down z-sum, logistic squash onto 0–3.
    private func oracleLevel(rhr: Double?, hrv: Double?, baseline: [DailyMetric]) -> Double {
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        func std(_ xs: [Double], _ m: Double?) -> Double {
            guard let m, xs.count > 1 else { return 0 }
            return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
        }
        let r = baseline.compactMap(\.restingHr).map(Double.init), h = baseline.compactMap(\.avgHrv)
        let mr = mean(r), mh = mean(h), sr = std(r, mr), sh = std(h, mh)
        var sum = 0.0
        if let x = rhr, let m = mr, sr > 0.0001 { sum += (x - m) / sr }
        if let x = hrv, let m = mh, sh > 0.0001 { sum += (m - x) / sh }
        return min(max(3.0 / (1.0 + exp(-sum)), 0), 3)
    }

    func testDailyLevelMatchesTheReplacedFormulaAcrossInjectedNights() {
        let base = history()
        let cases: [(rhr: Int?, hrv: Double?)] = [(53, 61), (60, 45), (48, 75), (nil, 40), (58, nil), (66, 30)]
        var levels: [Double] = []
        for c in cases {
            let days = base + [day(29, rhr: c.rhr, hrv: c.hrv)]
            let daily = try! XCTUnwrap(DaytimeStress.daily(days: days, stored: []))
            XCTAssertEqual(daily.day, "2026-05-29")
            XCTAssertEqual(daily.source, .derived)
            XCTAssertEqual(daily.level.bitPattern,
                           oracleLevel(rhr: c.rhr.map(Double.init), hrv: c.hrv, baseline: base).bitPattern)
            levels.append(daily.level)
        }
        // The injected nights land in different bands: calm, tense and in between are all recovered.
        XCTAssertEqual(DaytimeStress.Band(level: levels[2]), .low)
        XCTAssertEqual(DaytimeStress.Band(level: levels[0]), .medium)
        XCTAssertEqual(DaytimeStress.Band(level: levels[5]), .high)
        XCTAssertGreaterThan(levels[1], levels[0])
    }

    func testDailyPrefersStoredAndCarriesToTheNewestNightWithSignal() {
        let base = history()
        let stored = DaytimeStress.daily(days: base + [day(29, rhr: 60, hrv: 45)],
                                         stored: [(day: "2026-05-29", value: 2.4)])
        XCTAssertEqual(stored?.level, 2.4)
        XCTAssertEqual(stored?.source, .stored)
        XCTAssertEqual(stored.map(DaytimeStress.dailyConfidence), .solid)

        // Today's row has no vitals yet: the level carries from last night (#543).
        let carried = DaytimeStress.daily(days: base + [day(29, rhr: 60, hrv: 45), day(30, rhr: nil, hrv: nil)],
                                          stored: [])
        XCTAssertEqual(carried?.day, "2026-05-29")
        XCTAssertNil(DaytimeStress.daily(days: [day(1, rhr: nil, hrv: nil)], stored: []))
    }

    // MARK: - Stress headline

    func testHeadlinePrefersTheLatestScoredHourThenTheDailyLevel() {
        let daily = DaytimeStress.daily(days: history() + [day(29, rhr: 60, hrv: 45)], stored: [])
        let hours = [
            DaytimeStress.HourPoint(hour: 9, startTs: 0, level: 0.8, meanHR: 70, rmssd: nil),
            DaytimeStress.HourPoint(hour: 10, startTs: 3600, level: 2.3, meanHR: 88, rmssd: nil),
            DaytimeStress.HourPoint(hour: 11, startTs: 7200, level: nil, meanHR: nil, rmssd: nil),
        ]
        let live = DaytimeStress.headline(hours: hours, daily: daily)
        XCTAssertEqual(live.value, 2.3)
        XCTAssertEqual(live.reason, .currentHour)
        XCTAssertEqual(live.confidence, .building)

        let morning = DaytimeStress.headline(hours: [hours[2]], daily: daily)
        XCTAssertEqual(morning.value, daily?.level)
        XCTAssertEqual(morning.reason, .dailyLevel)
        // 28 baseline nights of a 30-night window: usable but not yet solid.
        XCTAssertEqual(morning.confidence, .building)

        let none = DaytimeStress.headline(hours: [], daily: nil)
        XCTAssertNil(none.value)
        XCTAssertEqual(none.reason, .none)
    }

    // MARK: - Illness history reading

    func testIllnessReadingRecoversEachInjectedSignal() {
        let base = history(nights: 30)
        // Two sick-looking nights: RHR up, HRV down, respiration up, skin temperature up.
        let sick = base + [day(31, rhr: 61, hrv: 40, resp: 16.4, skin: 0.9),
                           day(32, rhr: 62, hrv: 38, resp: 16.6, skin: 1.0)]
        let reading = try! XCTUnwrap(IllnessSignalEngine.reading(days: sick))
        XCTAssertTrue(reading.baselineTrusted)
        XCTAssertGreaterThan(reading.inputs.restingHR!.zIllnessward, IllnessSignalEngine.signalZThreshold)
        XCTAssertGreaterThan(reading.inputs.hrv!.zIllnessward, IllnessSignalEngine.signalZThreshold)
        XCTAssertGreaterThan(reading.inputs.respiration!.zIllnessward, IllnessSignalEngine.signalZThreshold)
        XCTAssertEqual(reading.deltas.restingHRAboveBpm, 9)
        XCTAssertNotNil(reading.deltas.hrvBelowPercent)
        XCTAssertEqual(reading.deltas.skinTempRiseC, 1.0)
        XCTAssertTrue(reading.deltas.respirationUp)
        XCTAssertEqual(IllnessSignalEngine.evaluate(reading.inputs, context: .init()).level, .raised)

        // A single elevated RHR night with the rest steady: one signal only, so the engine stays quiet.
        let oneSignal = base + [day(31, rhr: 61, hrv: 60, resp: 14.4), day(32, rhr: 62, hrv: 61, resp: 14.4)]
        let quiet = try! XCTUnwrap(IllnessSignalEngine.reading(days: oneSignal))
        XCTAssertGreaterThan(quiet.inputs.restingHR!.zIllnessward, IllnessSignalEngine.signalZThreshold)
        XCTAssertLessThan(quiet.inputs.hrv!.zIllnessward, IllnessSignalEngine.signalZThreshold)
        XCTAssertNil(quiet.deltas.hrvBelowPercent)
        XCTAssertEqual(IllnessSignalEngine.evaluate(quiet.inputs, context: .init()).level, .quiet)

        // A steady night reads nothing.
        let steady = try! XCTUnwrap(IllnessSignalEngine.reading(days: base + [day(31, rhr: 53, hrv: 60), day(32, rhr: 53, hrv: 60)]))
        XCTAssertNil(steady.deltas.restingHRAboveBpm.flatMap { $0 > 2 ? $0 : nil })
        XCTAssertEqual(IllnessSignalEngine.evaluate(steady.inputs, context: .init()).level, .quiet)
    }

    func testIllnessReadingNeedsTwoWeeksAndATrustedBaseline() {
        XCTAssertNil(IllnessSignalEngine.reading(days: Array(history().prefix(IllnessSignalEngine.minHistoryDays - 1))))
        let young = try! XCTUnwrap(IllnessSignalEngine.reading(days: Array(history().prefix(IllnessSignalEngine.minHistoryDays))))
        XCTAssertFalse(young.baselineTrusted)
        let result = IllnessSignalEngine.evaluate(young.inputs, context: .init(baselineTrusted: young.baselineTrusted))
        XCTAssertEqual(result.assessment.confidence, .calibrating)
        XCTAssertEqual(result.assessment.reason, .quiet)
    }

    // MARK: - Recovery assessment

    func testRecoveryAssessmentWrapsTheScoreWithoutRecomputingIt() {
        let trusted = BaselineState(baseline: 55, spread: 5, nValid: 20, nightsSinceUpdate: 0, status: .trusted)
        let provisional = BaselineState(baseline: 55, spread: 5, nValid: 6, nightsSinceUpdate: 0, status: .provisional)
        let seeding = BaselineState(baseline: 55, spread: 5, nValid: 2, nightsSinceUpdate: 0, status: .calibrating)
        for score in [12.5, 58.0, 91.3] {
            let a = RecoveryScorer.assessment(score: score, hrvBaseline: trusted)
            XCTAssertEqual(a.value, score)
            XCTAssertEqual(a.confidence, .solid)
            XCTAssertEqual(a.reason, .scored)
        }
        XCTAssertEqual(RecoveryScorer.assessment(score: 70, hrvBaseline: provisional).confidence, .building)
        XCTAssertEqual(RecoveryScorer.assessment(score: nil, hrvBaseline: seeding).reason, .calibrating)
        XCTAssertEqual(RecoveryScorer.assessment(score: nil, hrvBaseline: trusted).reason, .missingInputs)
        XCTAssertEqual(RecoveryScorer.assessment(score: nil, hrvBaseline: nil).confidence, .calibrating)
    }
}
