import XCTest
@testable import StrandAnalytics

/// Zoop: the personal Charge weighting, the check-in symptom term, the WHOOP-style weighted overnight HRV
/// and the sleep-sufficiency term.
final class ChargePersonalWeightingTests: XCTestCase {

    private func base(_ mean: Double, _ spread: Double) -> BaselineState {
        BaselineState(baseline: mean, spread: spread, nValid: 30, nightsSinceUpdate: 0, status: .trusted)
    }

    /// `n` mornings where the feeling follows the RHR term and ignores HRV.
    private func samples(_ n: Int) -> [CalibrationSample] {
        (0..<n).map { i in
            let rhrZ = Double(i % 5) - 2.0
            let hrvZ = Double((i * 3) % 7) - 3.0
            return CalibrationSample(day: "d\(i)", feeling: rhrZ + 3.0,
                                     termZ: [.hrv: hrvZ, .rhr: rhrZ, .sleep: 0.5 * Double(i % 2)])
        }
    }

    func testCollectingUntilThePreviewThresholdKeepsStandardWeights() {
        let r = RecoveryCalibration.fit(samples(RecoveryCalibration.previewDays - 1))
        XCTAssertEqual(r.phase, .collecting)
        XCTAssertEqual(r.weights, .standard)
    }

    func testPreviewMovesLessThanFullCalibration() {
        let preview = RecoveryCalibration.fit(samples(10))
        let full = RecoveryCalibration.fit(samples(40))
        XCTAssertEqual(preview.phase, .preview)
        XCTAssertEqual(full.phase, .calibrated)
        let std = ChargeWeights.standard
        // RHR tracks the feeling, so it gains weight, and gains more once fully calibrated.
        XCTAssertGreaterThan(preview.weights.rhr, std.rhr)
        XCTAssertGreaterThan(full.weights.rhr, preview.weights.rhr)
    }

    func testGuardRailsHoldTotalAndHrvDominance() {
        let full = RecoveryCalibration.fit(samples(60))
        XCTAssertEqual(full.weights.total, ChargeWeights.standard.total, accuracy: 1e-9)
        for t in ChargeTerm.allCases where t != .hrv {
            XCTAssertGreaterThanOrEqual(full.weights.hrv, full.weights.weight(t))
        }
        // No weight leaves its ±50 % band by more than renormalisation can move it.
        XCTAssertLessThanOrEqual(full.weights.rhr, ChargeWeights.standard.rhr * 1.5 * 1.5)
    }

    func testCalibratedWeightsChangeTheScore() {
        let args = (hrv: 60.0, rhr: 50.0)
        let standard = RecoveryScorer.recovery(hrv: args.hrv, rhr: args.rhr, resp: nil,
                                               hrvBaseline: base(60, 8), rhrBaseline: base(55, 2),
                                               respBaseline: nil, sleepPerf: nil)!
        var w = ChargeWeights.standard
        w.rhr = 0.4
        let personal = RecoveryScorer.recovery(hrv: args.hrv, rhr: args.rhr, resp: nil,
                                               hrvBaseline: base(60, 8), rhrBaseline: base(55, 2),
                                               respBaseline: nil, sleepPerf: nil, weights: w)!
        XCTAssertGreaterThan(personal, standard, "a low resting HR counts for more when RHR weighs more")
    }

    func testSymptomsLowerChargeAndNoSymptomsChangeNothing() {
        func score(_ load: Double?) -> Double {
            RecoveryScorer.recovery(hrv: 65, rhr: 52, resp: nil, hrvBaseline: base(60, 8),
                                    rhrBaseline: base(55, 2), respBaseline: nil, sleepPerf: 0.9,
                                    symptomLoad: load)!
        }
        XCTAssertEqual(score(0), score(nil))
        XCTAssertLessThan(score(MorningCheckIn(feeling: 3, headache: true).symptomLoad), score(nil))
        XCTAssertLessThan(score(MorningCheckIn(feeling: 3, ill: true).symptomLoad),
                          score(MorningCheckIn(feeling: 3, headache: true).symptomLoad))
    }

    func testWeightedNightHrvFavoursDeepAndLateWindowsAndDropsWake() {
        let start = 0, end = 4 * 300
        let windows = [
            SleepStager.HrvWindow(startTs: 0, stage: "light", cleanBeats: 300, rmssd: 30),
            SleepStager.HrvWindow(startTs: 300, stage: "wake", cleanBeats: 300, rmssd: 200),
            SleepStager.HrvWindow(startTs: 600, stage: "deep", cleanBeats: 300, rmssd: 60),
            SleepStager.HrvWindow(startTs: 900, stage: "rem", cleanBeats: 300, rmssd: 40),
        ]
        let weighted = SleepStager.weightedNightHRV(windows, start: start, end: end)!
        let plainWithoutWake = (30.0 + 60.0 + 40.0) / 3.0
        XCTAssertGreaterThan(weighted, plainWithoutWake)
        XCTAssertLessThan(weighted, 60)
        XCTAssertNil(SleepStager.weightedNightHRV([windows[1]], start: start, end: end))
    }

    func testSleepSufficiencyIsAsleepOverNeedCapped() {
        XCTAssertEqual(AnalyticsEngine.Rest.sufficiency(tstSeconds: 6 * 3600, needHours: 8), 0.75, accuracy: 1e-9)
        XCTAssertEqual(AnalyticsEngine.Rest.sufficiency(tstSeconds: 9 * 3600, needHours: 8), 1.0)
    }

    /// Zoop: the stricter nap bar covers still mornings (08:00-10:00) and evenings on the sofa (19:00-22:00),
    /// while a normal night stays overnight.
    func testDaytimeBandCoversMorningAndEveningStillness() {
        func p(_ startH: Int, _ endH: Int) -> SleepStager.Period {
            SleepStager.Period(stage: "sleep", start: startH * 3600, end: endH * 3600)
        }
        XCTAssertTrue(SleepStager.isDaytimeCenter(p(8, 10), tzOffsetSeconds: 0))
        XCTAssertTrue(SleepStager.isDaytimeCenter(p(19, 22), tzOffsetSeconds: 0))
        XCTAssertFalse(SleepStager.isDaytimeCenter(p(23, 31), tzOffsetSeconds: 0))
    }
}
