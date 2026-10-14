import XCTest
@testable import StrandAnalytics

/// Pins `VitalBands` — the Health Monitor's personal-baseline banding. Mirrors the Android
/// `VitalBandsTest` case-for-case with identical numbers, so the two platforms can never
/// band the same vital differently.
final class VitalBandsTests: XCTestCase {

    private let hrvCfg = Baselines.hrvCfg
    private let hrvPop: ClosedRange<Double> = 40...120

    func testNullValueIsNoData() {
        let r = VitalBands.band(value: nil, history: [50.0], populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .noData)
    }

    // THE MOTIVATING CASE: a personal-normal HRV of 35 ms with the population band at 40-120.
    // Below the trust gate it is still judged against the population, hence out-of-range.
    func testLowHrvBelow14NightsPopulationOutOfRange() {
        let r = VitalBands.band(value: 35, history: Array(repeating: 35.0, count: 10),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
        XCTAssertEqual(r.nights, 10)
    }

    // The fix: at 14 trusted nights the same 35 ms is in-range against the user's OWN baseline.
    func testLowHrvAt14NightsPersonalInRange() {
        let r = VitalBands.band(value: 35, history: Array(repeating: 35.0, count: 14),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .inRange)
        XCTAssertEqual(r.basis, .personal)
        XCTAssertEqual(r.nights, 14)
    }

    func testPersonalBigDeviationOutOfRange() {
        // Constant 35 ms history → spread floors out; 70 ms is far beyond 2σ of that baseline.
        let r = VitalBands.band(value: 70, history: Array(repeating: 35.0, count: 30),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .personal)
    }

    func testPersonalJustInside2SigmaInRange() {
        let hist: [Double?] = Array(repeating: 35.0, count: 30)
        let state = Baselines.foldHistory(hist, cfg: hrvCfg)
        // 1.99σ in σ-space (spread is abs-dev, 1.253×spread ≈ σ): strictly inside the 2σ gate.
        let edge = state.baseline + 1.99 * 1.253 * state.spread
        XCTAssertEqual(VitalBands.band(value: edge, history: hist,
                                       populationRange: hrvPop, cfg: hrvCfg).band, .inRange)
    }

    func testImplausibleValueAlwaysOutOfRangeEvenWithTrustedBaseline() {
        // hrv cfg bounds are 5-250: 300 ms is implausible regardless of personal spread,
        // so the absolute outer guard fires and basis stays population.
        let r = VitalBands.band(value: 300, history: Array(repeating: 35.0, count: 30),
                                populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
    }

    func testNilCfgSpo2StaysPopulationOnly() {
        // A nil cfg (SpO₂) disables the personal path: an absolute <95% floor always applies.
        let r = VitalBands.band(value: 93, history: [], populationRange: 95...100, cfg: nil)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
    }

    func testNilNightsDoNotCountTowardTrust() {
        // 13 valid nights then 10 trailing skips: only 13 valid → provisional, still population.
        let hist: [Double?] = Array(repeating: 35.0, count: 13) + Array(repeating: nil, count: 10)
        let r = VitalBands.band(value: 35, history: hist, populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.basis, .population)
    }

    func testStaleBaselineFallsBackToPopulation() {
        // 20 valid nights then 20 missing (> staleDays = 14): status stale → population fallback.
        let hist: [Double?] = Array(repeating: 35.0, count: 20) + Array(repeating: nil, count: 20)
        let r = VitalBands.band(value: 35, history: hist, populationRange: hrvPop, cfg: hrvCfg)
        XCTAssertEqual(r.basis, .population)
    }

    func testSkinTempHistoryPartitionsMixedSemantics() {
        // 34.1/33.8 are absolute °C; 0.2/-0.1 are deviations. Each displayed kind keeps only its own.
        let mixed: [Double?] = [34.1, 0.2, nil, 33.8, -0.1]
        XCTAssertEqual(VitalBands.skinTempHistory(matching: 0.3, in: mixed), [nil, 0.2, nil, nil, -0.1])
        XCTAssertEqual(VitalBands.skinTempHistory(matching: 34.0, in: mixed), [34.1, nil, nil, 33.8, nil])
    }

    func testCalendarSeriesPadsMissingDays() {
        let rows: [(day: String, value: Double?)] = [("2026-06-01", 50.0), ("2026-06-04", 52.0)]
        XCTAssertEqual(VitalBands.calendarSeries(rows), [50.0, nil, nil, 52.0])
    }

    func testCalendarSeriesDropsMalformedKeysEmptyIsEmpty() {
        XCTAssertEqual(VitalBands.calendarSeries([]), [])
        let rows: [(day: String, value: Double?)] = [("not-a-date", 1.0), ("2026-06-01", 50.0)]
        XCTAssertEqual(VitalBands.calendarSeries(rows), [50.0])
    }

    // MARK: - Skin temp

    // THE MOTIVATING CASE: a steady 32.4 °C strap absolute used to read "Outside range" against the
    // 33-36 °C population fallback. Steady against its own history it must read in range.
    func testSkinTempSteadyAbsoluteBelowPopulationRangeReadsInRange() {
        let hist: [Double?] = (0..<20).map { 32.4 + ($0 % 2 == 0 ? 0.05 : -0.05) }
        let r = VitalBands.skinTempBand(value: 32.4, history: hist)
        XCTAssertEqual(r.band, .inRange)
        XCTAssertEqual(r.basis, .personal)
    }

    func testSkinTempTooLittleHistoryNeverWarns() {
        let r = VitalBands.skinTempBand(value: 31.0, history: [32.4, 32.5, 32.3])
        XCTAssertEqual(r.band, .inRange)
        XCTAssertEqual(r.nights, 3)
        // A deviation with no history either.
        XCTAssertEqual(VitalBands.skinTempBand(value: 0.9, history: []).band, .inRange)
    }

    func testSkinTempSmallWobbleOnConstantHistoryStaysInRange() {
        let hist: [Double?] = Array(repeating: 33.0, count: 20)
        // MAD is 0, so the floors decide: max(0.8, 2 x 0.3) = 0.8 °C.
        XCTAssertEqual(VitalBands.skinTempBand(value: 33.5, history: hist).band, .inRange)
        XCTAssertEqual(VitalBands.skinTempBand(value: 33.79, history: hist).band, .inRange)
        XCTAssertEqual(VitalBands.skinTempBand(value: 33.85, history: hist).band, .outOfRange)
        XCTAssertEqual(VitalBands.skinTempBand(value: 32.0, history: hist).band, .outOfRange)
    }

    func testSkinTempNoisyHistoryWidensTheBand() {
        // Alternating ±0.6 °C around 33: MAD 0.6 → σ ≈ 0.89 → threshold ≈ 1.78 °C.
        let hist: [Double?] = (0..<20).map { $0 % 2 == 0 ? 33.6 : 32.4 }
        XCTAssertEqual(VitalBands.skinTempBand(value: 34.5, history: hist).band, .inRange)
        XCTAssertEqual(VitalBands.skinTempBand(value: 35.0, history: hist).band, .outOfRange)
    }

    func testSkinTempIgnoresOtherKindAndOldNights() {
        // 10 deviation nights + gaps; the absolute value sees no matching history → no warning.
        let devs: [Double?] = Array(repeating: 0.1, count: 10)
        XCTAssertEqual(VitalBands.skinTempBand(value: 30.0, history: devs).nights, 0)
        // Steady history that ended more than the lookback ago no longer judges tonight.
        let old: [Double?] = Array(repeating: 33.0, count: 10) + Array(repeating: nil, count: 60)
        let r = VitalBands.skinTempBand(value: 35.0, history: old)
        XCTAssertEqual(r.band, .inRange)
        XCTAssertEqual(r.nights, 0)
    }

    func testSkinTempImplausibleIsOutOfRange() {
        XCTAssertEqual(VitalBands.skinTempBand(value: 45.0, history: []).band, .outOfRange)
        XCTAssertEqual(VitalBands.skinTempBand(value: nil, history: [33.0]).band, .noData)
    }

    func testSkinTempIllnessZSkipsAbsoluteNights() {
        XCTAssertNil(VitalBands.skinTempIllnessZ(recent: [33.4, 33.5], latest: 33.5))
        XCTAssertNil(VitalBands.skinTempIllnessZ(recent: [nil], latest: nil))
        // Mixed recent window: only the deviations count; min(mean 0.6, latest 0.6) / 0.3 = 2.
        XCTAssertEqual(try XCTUnwrap(VitalBands.skinTempIllnessZ(recent: [33.4, 0.6], latest: 0.6)),
                       2.0, accuracy: 1e-9)
        // A steady deviation near zero stays near zero.
        XCTAssertEqual(try XCTUnwrap(VitalBands.skinTempIllnessZ(recent: [0.0, 0.03], latest: 0.03)),
                       0.05, accuracy: 1e-9)
    }
}
