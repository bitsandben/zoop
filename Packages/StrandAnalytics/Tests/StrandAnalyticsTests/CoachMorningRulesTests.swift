import Foundation
import XCTest
@testable import StrandAnalytics

/// The offline morning coach, training slot and prioritisation: readiness bands, the one training
/// decision per day, its evidence, ordering, the cap and the dismissal feedback loop.
final class CoachMorningRulesTests: XCTestCase {

    func input(_ build: (inout CoachMorningRules.Input) -> Void) -> CoachMorningRules.Input {
        var i = CoachMorningRules.Input()
        build(&i)
        return i
    }

    func reasons(_ i: CoachMorningRules.Input) -> [CoachMorningRules.Reason] {
        CoachMorningRules.evaluate(i).candidates.map(\.reason)
    }

    func first(_ i: CoachMorningRules.Input) -> CoachMorningRules.Candidate? {
        CoachMorningRules.evaluate(i).candidates.first
    }

    private let upper = CoachMorningRules.Routine(id: "p1", name: "Upper A")
    private let legs = CoachMorningRules.Routine(id: "p2", name: "Legs")

    // MARK: Readiness

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

    // MARK: Low days

    func testLowRecoveryRestsWithStrainBandAndCitesRecovery() {
        let c = first(input { $0.recovery = 25; $0.strainTarget = 4...10 })
        XCTAssertEqual(c?.reason, .lowRecoveryRest)
        XCTAssertEqual(c?.action, .strainTarget(low: 4, high: 10))
        XCTAssertEqual(c?.evidence, [.recovery(percent: 25)])
    }

    func testPoorNightTakesItEasyBecauseOfTheSleep() {
        let c = first(input { $0.recovery = 40; $0.sleepMin = 290; $0.strainTarget = 8...12 })
        XCTAssertEqual(c?.reason, .poorSleepEasy)
        XCTAssertEqual(c?.evidence, [.sleep(minutes: 290), .recovery(percent: 40)])
    }

    func testPoorNightWithoutScoredRecoveryStillAdvisesEasy() {
        XCTAssertEqual(first(input { $0.sleepMin = 280 })?.reason, .poorSleepEasy)
    }

    func testLowRecoveryWithPlannedRoutineEasesOff() {
        let c = first(input { $0.recovery = 25; $0.plannedRoutines = [upper] })
        XCTAssertEqual(c?.reason, .plannedRoutineEaseOff)
        XCTAssertEqual(c?.evidence, [.recovery(percent: 25), .planned(name: "Upper A")])
    }

    func testIllnessOverridesEverythingElse() {
        let plan = CoachMorningRules.evaluate(input {
            $0.recovery = 85; $0.illness = true; $0.availableRoutines = [legs]
        })
        XCTAssertEqual(plan.candidates.first?.reason, .illnessRest)
        XCTAssertEqual(plan.candidates.first?.evidence.first, .illness)
        XCTAssertFalse(plan.candidates.map(\.reason).contains(.greenRoutine))
    }

    // MARK: Trends and load

    func testHrvDownStreakTurnsAGreenDayCautious() {
        let c = first(input {
            $0.recovery = 75; $0.availableRoutines = [legs]
            $0.hrvTrend = .init(below: true, streakDays: 4, deltaPercent: -12.4)
        })
        XCTAssertEqual(c?.reason, .hrvTrendCaution)
        XCTAssertEqual(c?.evidence.first, .hrvTrend(days: 4, deltaPercent: -12))
    }

    func testRestingHrUpStreakIsACaution() {
        let c = first(input { $0.recovery = 55; $0.rhrTrend = .init(below: false, streakDays: 3, deltaPercent: 6) })
        XCTAssertEqual(c?.reason, .hrvTrendCaution)
        XCTAssertEqual(c?.evidence.first, .rhrTrend(days: 3, deltaPercent: 6))
    }

    func testShortStreakIsNotATrend() {
        XCTAssertEqual(first(input {
            $0.recovery = 55; $0.hrvTrend = .init(below: true, streakDays: 2, deltaPercent: -9)
        })?.reason, .moderateSession)
    }

    func testHrvUpStreakIsAGreenLight() {
        let c = first(input { $0.recovery = 80; $0.hrvTrend = .init(below: false, streakDays: 5, deltaPercent: 8) })
        XCTAssertEqual(c?.reason, .trendGreenLight)
    }

    func testHighLoadDeloads() {
        let c = first(input { $0.recovery = 70; $0.loadState = .high; $0.loadRatio = 1.42 })
        XCTAssertEqual(c?.reason, .loadDeload)
        XCTAssertEqual(c?.evidence.first, .load(percentOfNormal: 142))
    }

    func testLowLoadOnAGreenDayCitesRoomToBuild() {
        let c = first(input { $0.recovery = 80; $0.loadState = .low; $0.loadRatio = 0.6 })
        XCTAssertEqual(c?.reason, .greenPush)
        XCTAssertEqual(c?.evidence, [.recovery(percent: 80), .load(percentOfNormal: 60)])
    }

    // MARK: Routines

    func testGreenDayProposesFirstAvailableRoutine() {
        let c = first(input { $0.recovery = 80; $0.availableRoutines = [legs, upper] })
        XCTAssertEqual(c?.action, .routine(programId: "p2", name: "Legs"))
        XCTAssertEqual(c?.kind, .routine)
    }

    func testGreenDayWithoutRoutinesPushes() {
        XCTAssertEqual(reasons(input { $0.recovery = 80; $0.strainTarget = 14...18 }), [.greenPush])
    }

    func testMissedRoutineIsRemindedAfterTwoMisses() {
        let c = first(input {
            $0.recovery = 60; $0.availableRoutines = [legs, upper]
            $0.adherence = .init(planned: 4, missed: 2, missedProgramId: "p1")
        })
        XCTAssertEqual(c?.reason, .routineMissed)
        XCTAssertEqual(c?.action, .routine(programId: "p1", name: "Upper A"))
        XCTAssertEqual(c?.evidence.first, .missedRoutine(missed: 2, planned: 4))
    }

    func testOneMissIsNotANudge() {
        XCTAssertEqual(first(input {
            $0.recovery = 60; $0.availableRoutines = [upper]
            $0.adherence = .init(planned: 4, missed: 1, missedProgramId: "p1")
        })?.reason, .moderateSession)
    }

    func testMissedRoutineIsNotPushedOnALowDay() {
        XCTAssertEqual(first(input {
            $0.recovery = 20; $0.availableRoutines = [upper]
            $0.adherence = .init(planned: 4, missed: 3, missedProgramId: "p1")
        })?.reason, .lowRecoveryRest)
    }

    func testPlannedRoutineAfterMissesIsBackOnTrack() {
        XCTAssertEqual(first(input {
            $0.recovery = 75; $0.plannedRoutines = [upper]
            $0.adherence = .init(planned: 5, missed: 2, missedProgramId: "p1")
        })?.reason, .routineBackOnTrack)
    }

    func testPlannedRoutineOnAMediumDayWithAPoorNightEasesOff() {
        let c = first(input { $0.recovery = 50; $0.sleepMin = 300; $0.plannedRoutines = [upper] })
        XCTAssertEqual(c?.reason, .plannedRoutineEaseOff)
        XCTAssertEqual(c?.evidence, [.sleep(minutes: 300), .planned(name: "Upper A")])
    }

    // MARK: Prioritisation

    func testCappedAtTwoInPriorityOrder() {
        let r = reasons(input {
            $0.recovery = 25; $0.sleepDebtMin = 90; $0.bedtimeMinute = 1360
            $0.hrv = 40; $0.hrvBaseline = 60; $0.stressLevel = 2.5; $0.stressPeakHour = 15
        })
        XCTAssertEqual(r, [.lowRecoveryRest, .sleepDebtBedtime])
    }

    func testFastingBreakOutranksTheBedtime() {
        let r = reasons(input {
            $0.recovery = 20; $0.sleepDebtMin = 90; $0.bedtimeMinute = 1360
            $0.fasting = .init(elapsedHours: 18, targetHours: 20)
        })
        XCTAssertEqual(r, [.lowRecoveryRest, .fastingBreak])
    }

    func testEveryCandidateCarriesEvidence() {
        let plan = CoachMorningRules.evaluate(input {
            $0.recovery = 45; $0.sleepMin = 320; $0.bedtimeMinute = 1350; $0.stressLevel = 2.2
        })
        XCTAssertFalse(plan.candidates.isEmpty)
        for c in plan.candidates { XCTAssertFalse(c.evidence.isEmpty, "\(c.reason) has no because") }
        XCTAssertTrue(plan.candidates.allSatisfy { $0.evidence.count <= 2 })
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
        let plan = CoachMorningRules.evaluate(input { $0.recovery = 80; $0.suppressedKinds = [.trainingToday] })
        XCTAssertEqual(plan.candidates.map(\.reason), [.steadyDay])
        XCTAssertEqual(plan.candidates.first?.evidence, [.recovery(percent: 80)])
    }

    func testReasonRawValuesAreStable() {
        // Stored with every suggestion; renaming one silently breaks the dismissal feedback.
        XCTAssertEqual(CoachMorningRules.Reason.sleepDebtBedtime.rawValue, "sleepDebtBedtime")
        XCTAssertEqual(CoachMorningRules.Reason.lowRecoveryRest.rawValue, "lowRecoveryRest")
        XCTAssertEqual(CoachMorningRules.Reason.allCases.count, 21)
    }
}
