import XCTest
@testable import StrandAnalytics

final class MorningBriefDriversTests: XCTestCase {

    private typealias M = MorningBriefDrivers

    private func base(recovery: Double = 70) -> M.Input {
        var i = M.Input()
        i.recovery = recovery
        i.recoveryRange = 55...80
        return i
    }

    private let calmBouts: [Double] = [6, 7, 5, 6, 8, 6, 7, 5, 6, 7]

    func testQuietMorningIsNotNotable() {
        var i = base()
        i.restingHRDelta = 1
        i.hrvPercent = -4
        i.sleepMinutesVsNeed = -20
        i.restlessBouts = 7
        i.restlessHistoryBouts = calmBouts
        let brief = M.evaluate(i)
        XCTAssertFalse(brief.notable)
        XCTAssertEqual(brief.tone, .within)
        XCTAssertTrue(brief.drivers.isEmpty)
    }

    func testGreatMorningAboveRangeDoesNotPush() {
        var i = base(recovery: 92)
        i.hrvPercent = 15
        let brief = M.evaluate(i)
        XCTAssertEqual(brief.tone, .above)
        XCTAssertFalse(brief.notable)
    }

    func testRestlessNightIsNotableAndNamed() {
        var i = base(recovery: 60)
        i.restlessBouts = 14
        i.restlessHistoryBouts = calmBouts
        let brief = M.evaluate(i)
        XCTAssertTrue(brief.notable)
        XCTAssertEqual(brief.drivers.first?.kind, .restless)
        XCTAssertEqual(brief.drivers.first?.value, 14)
        XCTAssertEqual(brief.drivers.first?.typical, 6)
    }

    func testThinMotionCoverageNamesButDoesNotPush() {
        var i = base(recovery: 60)
        i.restlessBouts = 14
        i.restlessHistoryBouts = calmBouts
        i.restlessSolid = false
        let brief = M.evaluate(i)
        XCTAssertFalse(brief.notable)
        XCTAssertEqual(brief.drivers.map(\.kind), [.restless])
    }

    func testRestlessNeedsAWeekOfHistory() {
        var i = base(recovery: 60)
        i.restlessBouts = 20
        i.restlessHistoryBouts = [5, 6, 5]
        XCTAssertTrue(M.evaluate(i).drivers.isEmpty)
    }

    func testHighRestingHRIsNotable() {
        var i = base(recovery: 58)
        i.restingHRDelta = 6
        let brief = M.evaluate(i)
        XCTAssertTrue(brief.notable)
        XCTAssertEqual(brief.drivers.map(\.kind), [.restingHR])
    }

    func testRecoveryBelowRangeIsNotableEvenWithModestDrivers() {
        var i = base(recovery: 45)
        i.hrvPercent = -12
        i.sleepMinutesVsNeed = -50
        let brief = M.evaluate(i)
        XCTAssertTrue(brief.notable)
        XCTAssertEqual(brief.tone, .below)
        XCTAssertEqual(Set(brief.drivers.map(\.kind)), [.hrv, .sleep])
    }

    func testRedRecoveryWithoutRangeIsNotable() {
        var i = M.Input()
        i.recovery = 28
        XCTAssertTrue(M.evaluate(i).notable)
        XCTAssertEqual(M.evaluate(i).tone, .unknown)
    }

    func testSizedFactorOfFivePointsIsNotable() {
        var i = base(recovery: 62)
        i.factors = [RecoveryFactors.Factor(kind: .logged, points: -7, deviation: 0, question: "Did you drink any alcohol?")]
        let brief = M.evaluate(i)
        XCTAssertTrue(brief.notable)
        XCTAssertEqual(brief.drivers.first?.question, "Did you drink any alcohol?")
        XCTAssertEqual(brief.drivers.first?.points, -7)
    }

    func testSmallSizedFactorIsNamedButQuiet() {
        var i = base(recovery: 62)
        i.factors = [RecoveryFactors.Factor(kind: .bedtime, points: -3, deviation: 70)]
        let brief = M.evaluate(i)
        XCTAssertFalse(brief.notable)
        XCTAssertEqual(brief.drivers.map(\.kind), [.bedtime])
    }

    func testFactorThatRaisedRecoveryIsNotAnExplanation() {
        var i = base(recovery: 62)
        i.factors = [RecoveryFactors.Factor(kind: .strain, points: 4, deviation: 40)]
        XCTAssertTrue(M.evaluate(i).drivers.isEmpty)
    }

    func testIllnessComesFirstAndCapsAtThree() {
        var i = base(recovery: 40)
        i.illness = true
        i.restingHRDelta = 7
        i.hrvPercent = -30
        i.sleepMinutesVsNeed = -120
        i.restlessBouts = 15
        i.restlessHistoryBouts = calmBouts
        let brief = M.evaluate(i)
        XCTAssertTrue(brief.notable)
        XCTAssertEqual(brief.drivers.count, M.maxDrivers)
        XCTAssertEqual(brief.drivers.first?.kind, .illness)
    }

    func testScorerPointsOrderDrivers() {
        var i = base(recovery: 44)
        i.factors = [RecoveryFactors.Factor(kind: .sleep, points: -9, deviation: -100),
                     RecoveryFactors.Factor(kind: .hrv, points: -3, deviation: -12)]
        i.sleepMinutesVsNeed = -100
        i.hrvPercent = -12
        XCTAssertEqual(M.evaluate(i).drivers.map(\.kind), [.sleep, .hrv])
    }

    func testRestlessMinutesStandInWhenBoutsDoNot() {
        var i = base(recovery: 60)
        i.restlessBouts = 7
        i.restlessHistoryBouts = calmBouts
        i.restlessMinutes = 40
        i.restlessHistoryMinutes = [12, 14, 10, 15, 13, 11, 12, 14]
        let brief = M.evaluate(i)
        XCTAssertEqual(brief.drivers.first?.kind, .restlessMinutes)
        XCTAssertTrue(brief.notable)
    }

    func testNoRecoveryNeverPushes() {
        var i = M.Input()
        i.restingHRDelta = 9
        XCTAssertFalse(M.evaluate(i).notable)
    }
}

final class CoachBriefReplySchemaTests: XCTestCase {

    func testHeadlineAndReasonsBuildTheBrief() {
        let reply = """
        {"headline": "Erholung 41: heute ruhig angehen.",
         "reasons": ["Du hast dich nachts viel bewegt: 14 Phasen statt 6.", "**Ruhepuls** 6 bpm über normal.", "Dritter.", "Vierter."],
         "suggestions": [{"id": 0, "action": "strainTarget", "title": "Ruhiger Tag", "body": "Belastung 4–8."},
                         {"id": 1, "action": "bedtime", "title": "Bett um 22:30", "body": "Gleicht die Nacht aus."},
                         {"id": 2, "action": "none", "title": "Zu viel", "body": "Nur zwei erlaubt."}]}
        """
        let parsed = CoachBriefReply.parse(reply, candidateActions: ["strainTarget", "bedtime", "none"])
        XCTAssertEqual(parsed?.headline, "Erholung 41: heute ruhig angehen.")
        XCTAssertEqual(parsed?.reasons.count, MorningBriefDrivers.maxDrivers)
        XCTAssertEqual(parsed?.reasons[1], "Ruhepuls 6 bpm über normal.")
        XCTAssertEqual(parsed?.picks.count, CoachMorningRules.maxSuggestions)
        XCTAssertEqual(parsed?.brief.components(separatedBy: "\n").count, 4)
    }

    func testPromptAsksForStrictJSONAndNoInventedReasons() {
        let prompt = CoachBriefReply.systemPrompt(languageCode: "de")
        XCTAssertTrue(prompt.contains("\"headline\""))
        XCTAssertTrue(prompt.contains("Never add a reason that is not listed"))
    }
}
