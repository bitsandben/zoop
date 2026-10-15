import Foundation
import XCTest
@testable import StrandAnalytics

/// The offline morning coach: readiness bands, which suggestion each signal raises, ordering, caps and
/// the dismissal feedback loop.
final class CoachMorningRulesTests: XCTestCase {

    private func input(_ build: (inout CoachMorningRules.Input) -> Void) -> CoachMorningRules.Input {
        var i = CoachMorningRules.Input()
        build(&i)
        return i
    }

    private func reasons(_ i: CoachMorningRules.Input) -> [CoachMorningRules.Reason] {
        CoachMorningRules.evaluate(i).candidates.map(\.reason)
    }

    func testNoDataGivesNoSuggestions() {
        let plan = CoachMorningRules.evaluate(.init())
        XCTAssertEqual(plan.readiness, .unknown)
        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testReadinessBands() {
        XCTAssertEqual(CoachMorningRules.Readiness(recovery: 20), .low)
        XCTAssertEqual(CoachMorningRules.Readiness(recovery: 34), .medium)
        XCTAssertEqual(CoachMorningRules.Readiness(recovery: 66.9), .medium)
        XCTAssertEqual(CoachMorningRules.Readiness(recovery: 67), .high)
    }

    func testLowRecoveryRestsWithStrainBand() {
        let plan = CoachMorningRules.evaluate(input { $0.recovery = 25; $0.strainTarget = 4...10 })
        XCTAssertEqual(plan.candidates.first,
                       .init(kind: .recovery, reason: .lowRecoveryRest, action: .strainTarget(low: 4, high: 10)))
    }

    func testLowRecoveryWithPlannedRoutineEasesOff() {
        let r = reasons(input {
            $0.recovery = 25
            $0.plannedRoutines = [.init(id: "p1", name: "Upper A")]
        })
        XCTAssertEqual(r.first, .plannedRoutineEaseOff)
    }

    func testGreenDayProposesFirstAvailableRoutine() {
        let plan = CoachMorningRules.evaluate(input {
            $0.recovery = 80
            $0.availableRoutines = [.init(id: "p2", name: "Legs"), .init(id: "p1", name: "Upper A")]
        })
        XCTAssertEqual(plan.candidates.first?.action, .routine(programId: "p2", name: "Legs"))
        XCTAssertEqual(plan.candidates.first?.kind, .routine)
    }

    func testGreenDayWithoutRoutinesPushes() {
        XCTAssertEqual(reasons(input { $0.recovery = 80; $0.strainTarget = 14...18 }), [.greenPush])
    }

    func testSleepDebtProposesPlannerBedtime() {
        let plan = CoachMorningRules.evaluate(input {
            $0.recovery = 50; $0.sleepDebtMin = 90; $0.bedtimeMinute = 22 * 60 + 40
        })
        XCTAssertTrue(plan.candidates.contains(.init(kind: .sleepTiming, reason: .sleepDebtBedtime,
                                                     action: .bedtime(minuteOfDay: 1360))))
    }

    func testShortNightWithoutDebtStillProposesBedtime() {
        XCTAssertTrue(reasons(input {
            $0.recovery = 50; $0.sleepMin = 300; $0.bedtimeMinute = 1380
        }).contains(.shortNightBedtime))
    }

    func testNoBedtimeKnownMeansNoSleepSuggestion() {
        XCTAssertFalse(reasons(input { $0.recovery = 50; $0.sleepDebtMin = 120 })
            .contains(.sleepDebtBedtime))
    }

    func testBedtimeWrapsIntoTheDay() {
        let plan = CoachMorningRules.evaluate(input { $0.sleepDebtMin = 90; $0.bedtimeMinute = 1440 + 30 })
        XCTAssertEqual(plan.candidates.first?.action, .bedtime(minuteOfDay: 30))
    }

    func testHrvBelowRangeAndHighStress() {
        let r = reasons(input { $0.hrv = 40; $0.hrvBaseline = 60; $0.stressLevel = 2.4 })
        XCTAssertEqual(r, [.hrvBelowRange, .highStress])
        XCTAssertEqual(reasons(input { $0.hrv = 55; $0.hrvBaseline = 60 }), [])
    }

    func testFastingNextOnlyForPeopleWhoFastAndAreNotFasting() {
        let fasting = CoachMorningRules.Fasting(active: false, nextStartMinute: 20 * 60, planId: "16-8",
                                                fastingHours: 16)
        let plan = CoachMorningRules.evaluate(input { $0.recovery = 50; $0.fasting = fasting })
        XCTAssertTrue(plan.candidates.contains(.init(kind: .fasting, reason: .fastingNext,
                                                     action: .fastingStart(minuteOfDay: 1200, planId: "16-8"))))
        let active = CoachMorningRules.Fasting(active: true, nextStartMinute: 1200, planId: "16-8", fastingHours: 16)
        XCTAssertFalse(reasons(input { $0.recovery = 50; $0.fasting = active }).contains(.fastingNext))
    }

    func testLongFastShortenedOnLowRecovery() {
        let fasting = CoachMorningRules.Fasting(active: false, nextStartMinute: 1200, planId: "20-4", fastingHours: 20)
        XCTAssertTrue(reasons(input { $0.recovery = 20; $0.fasting = fasting }).contains(.fastingShorten))
    }

    func testCappedAtThreeInPriorityOrder() {
        let r = reasons(input {
            $0.recovery = 25; $0.sleepDebtMin = 90; $0.bedtimeMinute = 1360
            $0.hrv = 40; $0.hrvBaseline = 60; $0.stressLevel = 2.5
        })
        XCTAssertEqual(r, [.lowRecoveryRest, .sleepDebtBedtime, .hrvBelowRange])
    }

    func testSuppressedReasonAndKindAreLeftOut() {
        let r = reasons(input {
            $0.recovery = 25; $0.sleepDebtMin = 90; $0.bedtimeMinute = 1360; $0.stressLevel = 2.5
            $0.suppressedReasons = [CoachMorningRules.Reason.lowRecoveryRest.rawValue]
            $0.suppressedKinds = [.sleepTiming]
        })
        XCTAssertEqual(r, [.highStress])
    }

    func testSteadyDayWhenNothingFires() {
        // Medium readiness always yields a training line; a high day with routines suppressed and no
        // other signal falls through to the steady-day note.
        let r = reasons(input { $0.recovery = 80; $0.suppressedKinds = [.trainingToday] })
        XCTAssertEqual(r, [.steadyDay])
    }

    func testReasonRawValuesAreStable() {
        // Stored with every suggestion; renaming one silently breaks the dismissal feedback.
        XCTAssertEqual(CoachMorningRules.Reason.sleepDebtBedtime.rawValue, "sleepDebtBedtime")
        XCTAssertEqual(CoachMorningRules.Reason.allCases.count, 13)
    }
}
