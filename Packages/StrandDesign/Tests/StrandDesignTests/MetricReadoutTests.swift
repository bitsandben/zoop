import XCTest
@testable import StrandDesign

final class MetricReadoutTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    // MARK: Verdict mapping

    func testScoreBandsFollowTheDisplayedInteger() {
        XCTAssertEqual(ScoreBand(score: 100), .high)
        XCTAssertEqual(ScoreBand(score: 67), .high)
        XCTAssertEqual(ScoreBand(score: 66.6), .high, "shows as 67, so it must read High")
        XCTAssertEqual(ScoreBand(score: 66.4), .medium)
        XCTAssertEqual(ScoreBand(score: 34), .medium)
        XCTAssertEqual(ScoreBand(score: 33.5), .medium)
        XCTAssertEqual(ScoreBand(score: 33.4), .low)
        XCTAssertEqual(ScoreBand(score: 0), .low)
    }

    func testVitalVerdictBoundsAreTypical() {
        XCTAssertEqual(MetricVerdict.vital(48, typicalRange: 48...58), .typical)
        XCTAssertEqual(MetricVerdict.vital(58, typicalRange: 48...58), .typical)
        XCTAssertEqual(MetricVerdict.vital(58.1, typicalRange: 48...58), .above)
        XCTAssertEqual(MetricVerdict.vital(47.9, typicalRange: 48...58), .below)
    }

    // MARK: Polarity

    func testPolarityMapsAboveAndBelowToBetterOrWorse() {
        XCTAssertEqual(MetricAssessment(verdict: .above, polarity: .higherIsBetter), .better)
        XCTAssertEqual(MetricAssessment(verdict: .below, polarity: .higherIsBetter), .worse)
        XCTAssertEqual(MetricAssessment(verdict: .above, polarity: .lowerIsBetter), .worse)
        XCTAssertEqual(MetricAssessment(verdict: .below, polarity: .lowerIsBetter), .better)
        XCTAssertEqual(MetricAssessment(verdict: .above, polarity: .neutral), .neutral)
        XCTAssertEqual(MetricAssessment(verdict: .typical, polarity: .higherIsBetter), .neutral)
        XCTAssertEqual(MetricAssessment(verdict: .score(.low), polarity: .higherIsBetter), .neutral)
        XCTAssertEqual(MetricAssessment(verdict: .unavailable(.noData(since: nil)), polarity: .lowerIsBetter), .neutral)
    }

    func testDefaultPolarityPerMetric() {
        XCTAssertEqual(MetricID.hrv.defaultPolarity, .higherIsBetter)
        XCTAssertEqual(MetricID.restingHeartRate.defaultPolarity, .lowerIsBetter)
        XCTAssertEqual(MetricID.fitnessAge.defaultPolarity, .lowerIsBetter)
        XCTAssertEqual(MetricID.skinTemperature.defaultPolarity, .neutral)
        XCTAssertEqual(MetricID("app_defined").defaultPolarity, .neutral)
    }

    func testDirectionalVerdictWording() {
        let age = MetricReadout(id: .fitnessAge, label: "Fitness age", value: 31, unit: .years,
                                typicalRange: 35...37, verdict: .below, meaning: "x")
        XCTAssertEqual(MetricPresentation(age, locale: en).verdict, "Better than usual")
        XCTAssertEqual(MetricPresentation(age, locale: en).compactVerdict, "Better than usual", "tiles use the compact form")
        let debt = MetricReadout(id: "sleep_debt", label: "Debt", value: 90, unit: .duration,
                                 typicalRange: 10...40, rangeIsPersonal: false, verdict: .above, meaning: "x",
                                 polarity: .lowerIsBetter)
        XCTAssertEqual(MetricPresentation(debt, locale: en).verdict, "Worse than typical")
        let temp = MetricReadout(id: .skinTemperature, label: "Temp", value: 36, unit: .celsius,
                                 typicalRange: 34...35, verdict: .above, meaning: "x")
        XCTAssertEqual(MetricPresentation(temp, locale: en).verdict, "Above your range")
    }

    func testDeltaArrowOnlyPastSmallestWorthwhileChange() {
        // Range 48…58: SD 5, SWC 2.5.
        XCTAssertEqual(DeltaDirection(delta: 2.5, typicalRange: 48...58), .up)
        XCTAssertEqual(DeltaDirection(delta: 2.4, typicalRange: 48...58), .flat)
        XCTAssertEqual(DeltaDirection(delta: -3, typicalRange: 48...58), .down)
        XCTAssertEqual(DeltaDirection(delta: 40, typicalRange: nil), .flat)
    }

    // MARK: Presentation

    func testSolidReadoutPresentation() {
        let p = MetricPresentation(MetricSamples.hrvSolid, locale: en)
        XCTAssertEqual(p.label, "HRV")
        XCTAssertEqual(p.number, "62")
        XCTAssertEqual(p.unit, "ms")
        XCTAssertEqual(p.verdict, "Better than usual")
        XCTAssertEqual(p.delta, "+8\u{00A0}ms vs. typical")
        XCTAssertEqual(p.deltaDirection, .up)
        XCTAssertEqual(p.range, "Your range 48–58\u{00A0}ms")
        XCTAssertNil(p.confidenceNote)
        XCTAssertEqual(p.accessibilityValue, "62 milliseconds, Better than usual")
    }

    func testUnavailableNeverShowsANumber() {
        let leftover = MetricReadout(id: .hrv, label: "HRV", value: 62, unit: .milliseconds, delta: 4,
                                     verdict: .unavailable(.calibrating(nightsLeft: 3)), meaning: "x",
                                     confidence: .calibrating(nightsLeft: 3))
        let p = MetricPresentation(leftover, locale: en)
        XCTAssertNil(p.number)
        XCTAssertNil(p.delta)
        XCTAssertNil(p.confidenceNote, "the reason already states the calibration")
        XCTAssertEqual(p.verdict, "3 more nights")
        XCTAssertEqual(p.accessibilityValue, "3 more nights")
    }

    func testConfidenceNotes() {
        XCTAssertEqual(MetricPresentation(MetricSamples.rhrProvisional, locale: en).confidenceNote, "Provisional")
        XCTAssertEqual(MetricPresentation(MetricSamples.tempCalibrating, locale: en).confidenceNote,
                       "Population range, personal range in 3 nights")
        XCTAssertNotNil(MetricPresentation(MetricSamples.respStale, locale: en).confidenceNote)
        XCTAssertTrue(MetricSamples.tempCalibrating.rangeIsTentative)
        XCTAssertTrue(MetricSamples.rhrProvisional.rangeIsTentative)
        XCTAssertFalse(MetricSamples.hrvSolid.rangeIsTentative)
    }

    func testStepsCompareToYesterday() {
        let p = MetricPresentation(MetricSamples.steps, locale: en)
        XCTAssertEqual(p.delta, "+2,100\u{00A0}steps vs. yesterday")
    }

    // MARK: Range bar layout

    func testBandTakesTheMiddleThird() throws {
        let layout = try XCTUnwrap(MetricRangeLayout(MetricSamples.rhrProvisional))
        XCTAssertEqual(layout.band.lowerBound, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(layout.band.upperBound, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(layout.marker), 0.5, accuracy: 1e-9)
    }

    func testOutlierStaysOnTheBar() throws {
        let far = MetricReadout(id: .hrv, label: "HRV", value: 120, unit: .milliseconds,
                                typicalRange: 48...58, verdict: .above, meaning: "x")
        let marker = try XCTUnwrap(MetricRangeLayout(far)?.marker)
        XCTAssertLessThan(marker, 1)
        XCTAssertGreaterThan(marker, 0.9)
    }

    func testScoresUseTheirAbsoluteScale() throws {
        let layout = try XCTUnwrap(MetricRangeLayout(MetricSamples.recoveryHigh))
        XCTAssertEqual(try XCTUnwrap(layout.marker), 0.78, accuracy: 1e-9)
        XCTAssertEqual(layout.band.lowerBound, 0.52, accuracy: 1e-9)
    }

    func testNoRangeNoBar() {
        XCTAssertNil(MetricRangeLayout(MetricSamples.strainLoad))
    }

    // MARK: Explainer

    func testTrendBreaksAtGaps() {
        let segments = MetricTrendSegments.split(MetricSamples.trend)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.count), [12, 16])
    }

    func testDataUsedSummary() {
        let summary = MetricSamples.explanation.dataUsed.summary(locale: en)
        XCTAssertTrue(summary.hasPrefix("14 nights · "), summary)
        XCTAssertTrue(summary.hasSuffix(" · Source: WHOOP 4.0"), summary)
    }
}
