import XCTest
@testable import StrandAnalytics

final class FitnessAgeEngineTests: XCTestCase {

    // MARK: - VO₂max estimate (Nes 2011 waist-circumference variant, confirmed coefficients)

    func testVO2maxMenKnownValue() {
        // 100.27 − 0.296·40 + 0.226·5 − 0.369·90 − 0.155·65 = 46.275
        let v = FitnessAgeEngine.estimateVO2max(age: 40, sex: "male", waistCm: 90, restingHR: 65, paIndex: 5)
        XCTAssertEqual(v, 46.275, accuracy: 1e-3)
    }

    func testVO2maxWomenKnownValue() {
        // 74.74 − 0.247·40 + 0.198·5 − 0.259·80 − 0.114·65 = 37.72
        let v = FitnessAgeEngine.estimateVO2max(age: 40, sex: "female", waistCm: 80, restingHR: 65, paIndex: 5)
        XCTAssertEqual(v, 37.72, accuracy: 1e-3)
    }

    func testBMIHelper() {
        XCTAssertEqual(FitnessAgeEngine.bmi(weightKg: 80, heightCm: 178), 25.249, accuracy: 1e-3)
    }

    // MARK: - PA-index reconstruction (HUNT1 PA-Q buckets)

    func testPAIndexSedentary() {
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndex(
            activeDaysPerWeek: 0, avgActiveMinutesPerDay: 0, highIntensityFraction: 0), 0, accuracy: 1e-9)
    }

    func testPAIndexHighlyActive() {
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndex(
            activeDaysPerWeek: 7, avgActiveMinutesPerDay: 75, highIntensityFraction: 0.8), 15.0, accuracy: 1e-9)
    }

    func testPAIndexModerate() {
        // 3 days (2.5) × moderate (2) × ~40 min (0.75) = 3.75
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndex(
            activeDaysPerWeek: 3, avgActiveMinutesPerDay: 40, highIntensityFraction: 0.3), 3.75, accuracy: 1e-9)
    }

    func testPAIndexFromStrain() {
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndexFromStrain(
            activeDaysPerWeek: 0, meanActiveStrain: 0), 0, accuracy: 1e-9)
        // 7 days × strain 90 (id 3.0) = 15.
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndexFromStrain(
            activeDaysPerWeek: 7, meanActiveStrain: 90), 15.0, accuracy: 1e-9)
        // 3 days (freq 2.5) × strain 45 (id 1.5) = 3.75.
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndexFromStrain(
            activeDaysPerWeek: 3, meanActiveStrain: 45), 3.75, accuracy: 1e-9)
        // reference-ish: 4 days (2.5) × strain 60 (id 2.0) = 5.0.
        XCTAssertEqual(FitnessAgeEngine.physicalActivityIndexFromStrain(
            activeDaysPerWeek: 4, meanActiveStrain: 60), 5.0, accuracy: 1e-9)
    }

    // MARK: - Multi-marker fitness age

    private func age(_ x: FitnessAgeInputs) -> Double { FitnessAgeEngine.compute(x)!.fitnessAge }

    func testFitThirtyYearOldIsYounger() {
        let x = FitnessAgeInputs(chronoAge: 30, sex: "male", restingHR: 52, vo2max: 50, rmssd: 80)
        XCTAssertLessThan(age(x), 30)
        XCTAssertLessThan(age(x), 25)
    }

    func testUnfitThirtyYearOldIsOlder() {
        let x = FitnessAgeInputs(chronoAge: 30, sex: "male", restingHR: 75, vo2max: 32, rmssd: 30)
        XCTAssertGreaterThan(age(x), 30)
        XCTAssertGreaterThan(age(x), 35)
    }

    func testAveragePeerIsAboutTheirAge() {
        // FRIEND median VO₂max at 45, reference resting HR, HRV at the age norm, PA-index 5.
        let x = FitnessAgeInputs(chronoAge: 45, sex: "male", restingHR: 65, vo2max: 37.8,
                                 rmssd: VitalityEngine.rmssdNorm(forAge: 45), activityIndex: 5, bmi: 23)
        XCTAssertEqual(age(x), 45, accuracy: 0.1)
    }

    func testMissingOptionalInputsStillWorks() {
        let r = FitnessAgeEngine.compute(FitnessAgeInputs(chronoAge: 40, sex: "female", restingHR: 58))
        XCTAssertNotNil(r)
        XCTAssertEqual(Set(r!.contributions.keys), [.restingHR])
        XCTAssertLessThan(r!.fitnessAge, 40)
        XCTAssertNil(FitnessAgeEngine.compute(FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: 0)))
    }

    func testMonotonicInVO2max() {
        var last = Double.infinity
        for v in stride(from: 20.0, through: 65.0, by: 2.5) {
            let a = age(FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: 62, vo2max: v, rmssd: 40))
            XCTAssertLessThanOrEqual(a, last, "VO₂max \(v)")
            last = a
        }
        // Strictly younger across the unclamped middle of the range.
        XCTAssertLessThan(age(FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: 62, vo2max: 45)),
                          age(FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: 62, vo2max: 40)))
    }

    func testBoundedToFifteenYears() {
        let fit = FitnessAgeEngine.compute(FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: 38,
                                                            vo2max: 75, rmssd: 150, activityIndex: 15))!
        XCTAssertEqual(fit.fitnessAge, 25, accuracy: 1e-9)
        XCTAssertTrue(fit.bounded)
        let unfit = FitnessAgeEngine.compute(FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: 100,
                                                              vo2max: 15, rmssd: 8, activityIndex: 0, bmi: 40))!
        XCTAssertLessThanOrEqual(unfit.fitnessAge, 55)
        XCTAssertGreaterThan(unfit.fitnessAge, 50)
    }

    func testContributionsSumToTheOffset() {
        let x = FitnessAgeInputs(chronoAge: 36, sex: "female", restingHR: 60, vo2max: 34, rmssd: 45,
                                 activityIndex: 7, bodyFatPct: 26, sleepConsistency: 0.85)
        let r = FitnessAgeEngine.compute(x)!
        XCTAssertFalse(r.bounded)
        XCTAssertEqual(36 + r.contributions.values.reduce(0, +), r.fitnessAge, accuracy: 0.05)
        XCTAssertEqual(r.contributions.count, 6)
    }

    func testOneDecimal() {
        let r = FitnessAgeEngine.compute(FitnessAgeInputs(chronoAge: 33, sex: "male", restingHR: 61, rmssd: 52))!
        XCTAssertEqual(r.fitnessAge * 10, (r.fitnessAge * 10).rounded(), accuracy: 1e-9)
    }

    func testVO2NormScalesDiffer() {
        // The Nes estimate is read against HUNT norms, which sit higher than FRIEND's.
        XCTAssertGreaterThan(FitnessAgeEngine.vo2Norm(age: 40, sex: "male", source: .nesEstimate),
                             FitnessAgeEngine.vo2Norm(age: 40, sex: "male", source: .measured))
        // vo2Age inverts vo2Norm.
        let n = FitnessAgeEngine.vo2Norm(age: 52, sex: "female", source: .measured)
        XCTAssertEqual(FitnessAgeEngine.vo2Age(n, sex: "female", source: .measured), 52, accuracy: 1e-9)
    }

    func testNonBinaryFlagsLowerConfidence() {
        XCTAssertTrue(FitnessAgeEngine.compute(FitnessAgeInputs(chronoAge: 40, sex: "nonbinary", restingHR: 60))!.lowerConfidence)
    }

    // MARK: - Readiness checklist

    func testReadinessAllPresentIsReady() {
        let r = FitnessAgeEngine.assessReadiness(hasAge: true, hasSex: true, rhrDays: 7, activityDays: 7,
                                                 hasHeightWeight: true, hasWaist: true)
        XCTAssertEqual(r.confidence, .ready)
        XCTAssertTrue(r.canCompute)
        XCTAssertTrue(r.items.allSatisfy { $0.status == .satisfied })
        XCTAssertEqual(r.items.count, 6)
    }

    func testReadinessMissingRHRIsNotReady() {
        let r = FitnessAgeEngine.assessReadiness(hasAge: true, hasSex: true, rhrDays: 0, activityDays: 7,
                                                 hasHeightWeight: true, hasWaist: true)
        XCTAssertEqual(r.confidence, .notReady)
        XCTAssertFalse(r.canCompute)
        XCTAssertEqual(r.items.first { $0.key == "rhr" }!.status, .missing)
    }

    func testReadinessPartialCoverageIsEstimate() {
        // age+sex set, 5 nights RHR (≥ min 4 but < good 6), sparse activity → computes, but "estimate".
        let r = FitnessAgeEngine.assessReadiness(hasAge: true, hasSex: true, rhrDays: 5, activityDays: 3,
                                                 hasHeightWeight: false, hasWaist: false)
        XCTAssertEqual(r.confidence, .estimate)
        XCTAssertTrue(r.canCompute)
        XCTAssertEqual(r.items.first { $0.key == "rhr" }!.status, .partial)
        XCTAssertEqual(r.items.first { $0.key == "activity" }!.status, .partial)
        // Missing body metrics never blocks the headline — they sit under the VO₂max role.
        let body = r.items.first { $0.key == "bodyMetrics" }!
        XCTAssertEqual(body.status, .missing)
        XCTAssertEqual(body.role, .drivesAge)
        XCTAssertFalse(body.required)
    }

    func testReadinessMissingAgeIsNotReady() {
        let r = FitnessAgeEngine.assessReadiness(hasAge: false, hasSex: true, rhrDays: 7, activityDays: 7,
                                                 hasHeightWeight: true, hasWaist: true)
        XCTAssertEqual(r.confidence, .notReady)
    }

    func testReadinessGoodCoverageNoBodyMetricsStillReady() {
        // Headline only needs age/sex/coverage; missing height/weight (VO₂max-only) doesn't drop it.
        let r = FitnessAgeEngine.assessReadiness(hasAge: true, hasSex: true, rhrDays: 7, activityDays: 6,
                                                 hasHeightWeight: false, hasWaist: false)
        XCTAssertEqual(r.confidence, .ready)
    }

    // The not-ready countdown: nights of RHR still needed to reach the floor (minCoverageDays = 4).
    func testNightsUntilReadyCountsDownToTheFloor() {
        XCTAssertEqual(FitnessAgeEngine.nightsUntilReady(rhrDays: 0), 4)
        XCTAssertEqual(FitnessAgeEngine.nightsUntilReady(rhrDays: 1), 3)
        XCTAssertEqual(FitnessAgeEngine.nightsUntilReady(rhrDays: 3), 1)
    }

    // At/above the floor it's 0 (never negative), so the card flips to "ready" with no leftover countdown.
    func testNightsUntilReadyZeroAtOrAboveFloor() {
        XCTAssertEqual(FitnessAgeEngine.nightsUntilReady(rhrDays: 4), 0)
        XCTAssertEqual(FitnessAgeEngine.nightsUntilReady(rhrDays: 7), 0)
    }
}

final class FitnessAgeLeversTests: XCTestCase {

    private func inputs(vo2: Double? = 40, rhr: Double = 60, activity: Double? = 5,
                        sleep: Double? = 0.8, bmi: Double? = 23) -> FitnessAgeInputs {
        FitnessAgeInputs(chronoAge: 40, sex: "male", restingHR: rhr, vo2max: vo2, vo2Source: .measured,
                         rmssd: 45, activityIndex: activity, bmi: bmi, sleepConsistency: sleep)
    }

    func testLeversAreSortedAndPositive() {
        let ranked = FitnessAgeLevers.rank(inputs())
        XCTAssertFalse(ranked.isEmpty)
        XCTAssertEqual(ranked.map(\.yearsSaved), ranked.map(\.yearsSaved).sorted(by: >))
        XCTAssertTrue(ranked.allSatisfy { $0.yearsSaved >= FitnessAgeLevers.minimumYears })
    }

    func testMissingInputsGiveNoLever() {
        let kinds = FitnessAgeLevers.rank(inputs(vo2: nil, activity: nil, sleep: nil, bmi: nil)).map(\.kind)
        XCTAssertEqual(kinds, [.restingHeartRate])
    }

    func testHealthyBMIIsNotALever() {
        XCTAssertFalse(FitnessAgeLevers.rank(inputs(bmi: 23)).contains { $0.kind == .bodyComposition })
        XCTAssertTrue(FitnessAgeLevers.rank(inputs(bmi: 29)).contains { $0.kind == .bodyComposition })
    }

    func testSavingMatchesTheEngineOffset() {
        // Resting HR -3 bpm: only that factor moves, by 3 · 0.155/0.296 years before weighting.
        let x = inputs(vo2: nil, activity: nil, sleep: nil, bmi: nil)
        let lever = FitnessAgeLevers.rank(x).first { $0.kind == .restingHeartRate }
        XCTAssertEqual(lever?.yearsSaved ?? 0, 3 * 0.155 / 0.296 * (0.20 / 0.35), accuracy: 0.01)
    }
}
