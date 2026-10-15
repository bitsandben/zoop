import XCTest
@testable import StrandAnalytics

final class RecoveryFactorsTests: XCTestCase {

    func testHardDaySizedBySensitivity() throws {
        // 58 vs an average of 40 = +45 %; -4.4 points per 10 effort → about -8 points.
        let f = RecoveryFactors.rank(.init(strainYesterday: 58, strainAverage: 40, strainPointsPer10: -4.4))
        let strain = try XCTUnwrap(f.first)
        XCTAssertEqual(strain.kind, .strain)
        XCTAssertEqual(strain.deviation, 45, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(strain.points), -7.92, accuracy: 1e-9)
        XCTAssertEqual(RecoveryFactors.advice(f), .lightDay)
    }

    func testOrdinaryDayIsNotNamed() {
        let f = RecoveryFactors.rank(.init(strainYesterday: 44, strainAverage: 40, strainPointsPer10: -4))
        XCTAssertTrue(f.isEmpty)
        XCTAssertNil(RecoveryFactors.advice(f))
    }

    func testUnsizedStrainStillListedAfterSizedFactors() {
        let f = RecoveryFactors.rank(.init(strainYesterday: 60, strainAverage: 40,
                                           sleepMinutesVsNeed: -70, sleepPoints: -5,
                                           hrvPercent: 12, hrvPoints: 3))
        XCTAssertEqual(f.map(\.kind), [.sleep, .hrv, .strain])
        XCTAssertNil(f[2].points)
        XCTAssertEqual(RecoveryFactors.advice(f), .earlierBed)
    }

    func testIllnessRanksFirstAndDrivesAdvice() {
        let f = RecoveryFactors.rank(.init(hrvPercent: -20, hrvPoints: -9, illnessSignals: 2))
        XCTAssertEqual(f.map(\.kind), [.illness, .hrv])
        XCTAssertEqual(RecoveryFactors.advice(f), .rest)
    }

    func testSmallScorerMovesAreDropped() {
        let f = RecoveryFactors.rank(.init(sleepMinutesVsNeed: -10, sleepPoints: -1,
                                           restingHRDelta: 1, restingHRPoints: -1.5))
        XCTAssertTrue(f.isEmpty)
    }

    func testLoggedFactorSizedOnlyWhenSignificant() {
        let sig = BehaviorEffect(behavior: "a", outcome: "r", meanWith: 50, meanWithout: 60, delta: -10,
                                 pctChange: nil, nWith: 8, nWithout: 30, cohensD: -0.9, pApprox: 0.01,
                                 significant: true)
        let weak = BehaviorEffect(behavior: "b", outcome: "r", meanWith: 58, meanWithout: 60, delta: -2,
                                  pctChange: nil, nWith: 2, nWithout: 30, cohensD: -0.1, pApprox: 0.6,
                                  significant: false)
        let f = RecoveryFactors.rank(.init(logged: [.init(question: "b", effect: weak),
                                                    .init(question: "a", effect: sig)]))
        XCTAssertEqual(f.map(\.question), ["a", "b"])
        XCTAssertEqual(f[0].points, -10)
        XCTAssertNil(f[1].points)
    }

    func testPositiveFactorsGiveNoAdvice() {
        let f = RecoveryFactors.rank(.init(strainYesterday: 20, strainAverage: 40, strainPointsPer10: -3,
                                           hrvPercent: 15, hrvPoints: 4))
        XCTAssertEqual(f.map(\.kind), [.strain, .hrv])
        XCTAssertGreaterThan(f[0].points ?? 0, 0)
        XCTAssertNil(RecoveryFactors.advice(f))
    }

    func testLimitKeepsTheStrongest() {
        let f = RecoveryFactors.rank(.init(strainYesterday: 80, strainAverage: 40, strainPointsPer10: -1,
                                           sleepMinutesVsNeed: -90, sleepPoints: -7,
                                           bedtimeLateMinutes: 120, bedtimePointsPerHour: -2.5,
                                           hrvPercent: -25, hrvPoints: -10,
                                           restingHRDelta: 5, restingHRPoints: -3), limit: 3)
        XCTAssertEqual(f.map(\.kind), [.hrv, .sleep, .bedtime])
    }

    func testBedtimeLatenessAcrossMidnight() throws {
        // Usual around 23:00; last night 00:30 → 90 minutes late, not -1350.
        let usual = [1380, 1375, 1385, 1380, 1390, 1370, 1380]
        XCTAssertEqual(try XCTUnwrap(RecoveryFactors.bedtimeLateness(lastMinuteOfDay: 30, earlierMinutesOfDay: usual)), 90)
        XCTAssertNil(RecoveryFactors.bedtimeLateness(lastMinuteOfDay: 30, earlierMinutesOfDay: [1380]))
    }

    func testBedtimeSlopeRecoversInjectedEffects() throws {
        // Two different injected slopes are both recovered (not one tuned match).
        for slope in [-3.0, -8.0] {
            let pairs = (0..<30).map { i -> (lateMinutes: Double, recovery: Double) in
                let late = Double(i % 6) * 20 - 40
                return (late, 60 + slope * late / 60 + (i % 2 == 0 ? 0.5 : -0.5))
            }
            XCTAssertEqual(try XCTUnwrap(RecoveryFactors.bedtimePointsPerHour(pairs)), slope, accuracy: 0.3)
        }
        let flat = [(lateMinutes: Double, recovery: Double)](repeating: (0, 60), count: 30)
        XCTAssertNil(RecoveryFactors.bedtimePointsPerHour(flat))
    }

    func testStrainAverageNeedsAWeek() {
        XCTAssertNil(RecoveryFactors.strainAverage([30, 40]))
        XCTAssertEqual(RecoveryFactors.strainAverage([30, 40, 50, 30, 40, 50, 40]), 40)
    }
}
