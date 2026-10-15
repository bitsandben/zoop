import Foundation
import XCTest
@testable import StrandAnalytics

/// The morning coach's non-training slots (tonight, stress, HRV, fasting), routine adherence, the
/// cloud reply contract and the reply language check.
final class CoachMorningSignalsTests: XCTestCase {

    private func input(_ build: (inout CoachMorningRules.Input) -> Void) -> CoachMorningRules.Input {
        var i = CoachMorningRules.Input()
        build(&i)
        return i
    }

    private func plan(_ build: (inout CoachMorningRules.Input) -> Void) -> [CoachMorningRules.Candidate] {
        CoachMorningRules.evaluate(input(build)).candidates
    }

    private func reasons(_ build: (inout CoachMorningRules.Input) -> Void) -> [CoachMorningRules.Reason] {
        plan(build).map(\.reason)
    }

    // MARK: Tonight

    func testSleepDebtProposesPlannerBedtime() {
        let c = plan { $0.recovery = 50; $0.sleepDebtMin = 90; $0.bedtimeMinute = 22 * 60 + 40 }
            .first { $0.reason == .sleepDebtBedtime }
        XCTAssertEqual(c?.action, .bedtime(minuteOfDay: 1365), "rounded to the quarter hour")
        XCTAssertEqual(c?.evidence, [.sleepDebt(minutes: 90)])
    }

    func testUnrealisticEarlyBedtimeIsClamped() {
        // A planner bedtime of 20:18 for someone who usually sleeps at 23:10: no earlier than 22:10, on the quarter.
        XCTAssertEqual(CoachMorningRules.reasonableBedtime(20 * 60 + 18, usual: 23 * 60 + 10), 22 * 60 + 15)
        // Without a usual bedtime: not before 21:00.
        XCTAssertEqual(CoachMorningRules.reasonableBedtime(20 * 60 + 18, usual: nil), 21 * 60)
        // An early sleeper keeps their own early time.
        XCTAssertEqual(CoachMorningRules.reasonableBedtime(20 * 60, usual: 20 * 60 + 30), 20 * 60 + 30)
        // A later proposal is left alone apart from rounding, also past midnight.
        XCTAssertEqual(CoachMorningRules.reasonableBedtime(23 * 60 + 7, usual: 23 * 60), 23 * 60)
        XCTAssertEqual(CoachMorningRules.reasonableBedtime(25, usual: 0), 30)
    }

    func testSuggestedBedtimeUsesTheUsualBedtime() {
        let c = plan { $0.recovery = 50; $0.sleepDebtMin = 90; $0.bedtimeMinute = 20 * 60 + 18
            $0.usualBedtimeMinute = 23 * 60 }.first { $0.kind == .sleepTiming }
        XCTAssertEqual(c?.action, .bedtime(minuteOfDay: 22 * 60))
    }

    func testSmallDebtIsNotWorthABedtime() {
        XCTAssertFalse(reasons { $0.recovery = 50; $0.sleepDebtMin = 20; $0.bedtimeMinute = 1360 }
            .contains(.sleepDebtBedtime))
    }

    func testShortNightWithoutDebtStillProposesBedtime() {
        XCTAssertTrue(reasons { $0.recovery = 50; $0.sleepMin = 300; $0.bedtimeMinute = 1380 }
            .contains(.shortNightBedtime))
    }

    func testNoBedtimeKnownMeansNoSleepSuggestion() {
        XCTAssertFalse(reasons { $0.recovery = 50; $0.sleepDebtMin = 120 }.contains(.sleepDebtBedtime))
    }

    func testBestBedtimeWindowIsTheFallbackTime() {
        let c = plan { $0.recovery = 70; $0.sleepDebtMin = 60; $0.bestBedtimeMinute = 22 * 60 + 30 }
            .first { $0.kind == .sleepTiming }
        XCTAssertEqual(c?.action, .bedtime(minuteOfDay: 1350))
    }

    func testBedtimeWrapsIntoTheDay() {
        let c = plan { $0.sleepDebtMin = 90; $0.bedtimeMinute = 1440 + 30 }.first
        XCTAssertEqual(c?.action, .bedtime(minuteOfDay: 30))
    }

    func testLateBedtimeAcrossMidnightIsIrregular() {
        let c = plan { $0.recovery = 70; $0.bedtimeMinute = 22 * 60 + 45; $0.lastBedtimeMinute = 40 }
            .first { $0.kind == .sleepTiming }
        XCTAssertEqual(c?.reason, .bedtimeRegularity)
        XCTAssertEqual(c?.evidence, [.bedtimeDrift(lastMinute: 40, usualMinute: 1365)])
    }

    func testOnTimeBedtimeSaysNothing() {
        XCTAssertFalse(reasons { $0.recovery = 70; $0.bedtimeMinute = 1365; $0.lastBedtimeMinute = 1390 }
            .contains(.bedtimeRegularity))
    }

    // MARK: Stress and HRV

    func testBreatherBeforeTheUsualPeak() {
        let c = plan { $0.recovery = 70; $0.stressPeakHour = 15; $0.stressPeakLevel = 1.8 }
            .first { $0.reason == .stressPeakBreathe }
        XCTAssertEqual(c?.action, .breathe(minuteOfDay: 14 * 60 + 45))
        XCTAssertEqual(c?.evidence, [.stressPeak(hour: 15)])
    }

    func testMildPeakAfterACalmDayIsLeftAlone() {
        XCTAssertFalse(reasons { $0.recovery = 70; $0.stressPeakHour = 15; $0.stressPeakLevel = 1.0 }
            .contains(.stressPeakBreathe))
    }

    func testHighStressWithoutAKnownPeak() {
        XCTAssertTrue(reasons { $0.recovery = 70; $0.stressLevel = 2.3 }.contains(.highStress))
    }

    func testOneLowHrvMorningIsAHabitNote() {
        let c = plan { $0.recovery = 60; $0.hrv = 40; $0.hrvBaseline = 60 }.first { $0.reason == .hrvBelowRange }
        XCTAssertEqual(c?.evidence, [.hrvToday(ms: 40, typicalMs: 60)])
        XCTAssertFalse(reasons { $0.recovery = 60; $0.hrv = 55; $0.hrvBaseline = 60 }.contains(.hrvBelowRange))
    }

    func testHrvNoteStepsAsideForTheTrend() {
        let r = reasons {
            $0.recovery = 60; $0.hrv = 40; $0.hrvBaseline = 60
            $0.hrvTrend = .init(below: true, streakDays: 3, deltaPercent: -15)
        }
        XCTAssertEqual(r.first, .hrvTrendCaution)
        XCTAssertFalse(r.contains(.hrvBelowRange))
    }

    // MARK: Fasting

    func testNoFastingReminderWithoutARunningFast() {
        let r = reasons { $0.recovery = 20; $0.fasting = nil }
        XCTAssertFalse(r.contains(.fastingBreak))
    }

    func testLongFastOnALowDayIsWorthBreaking() {
        let c = plan { $0.recovery = 25; $0.fasting = .init(elapsedHours: 17.6, targetHours: 20) }
            .first { $0.kind == .fasting }
        XCTAssertEqual(c?.reason, .fastingBreak)
        XCTAssertEqual(c?.evidence, [.fasting(hours: 17), .recovery(percent: 25)])
    }

    func testFastOnAGoodDayIsNoneOfTheCoachsBusiness() {
        XCTAssertFalse(reasons { $0.recovery = 70; $0.fasting = .init(elapsedHours: 18, targetHours: 20) }
            .contains(.fastingBreak))
        XCTAssertFalse(reasons { $0.recovery = 20; $0.fasting = .init(elapsedHours: 10, targetHours: 14) }
            .contains(.fastingBreak))
    }

    // MARK: Adherence

    func testAdherenceCountsPlannedDaysOnly() {
        let r = CoachAdherence.evaluate([
            .init(day: "2026-10-01", plannedProgramIds: ["a"], trained: false),
            .init(day: "2026-10-02", plannedProgramIds: [], trained: false),
            .init(day: "2026-10-03", plannedProgramIds: ["a"], trained: true),
            .init(day: "2026-10-05", plannedProgramIds: ["b"], trained: false),
        ])
        XCTAssertEqual(r, .init(planned: 3, missed: 2, missedProgramId: "b"))
    }

    func testNoPlanNoAdherence() {
        XCTAssertNil(CoachAdherence.evaluate([.init(day: "2026-10-01", plannedProgramIds: [], trained: true)]))
    }

    // MARK: Cloud reply

    func testReplyPicksAreCheckedAgainstTheCandidateAction() {
        let reply = """
        Sure! {"brief": "Erholung 31 %.", "suggestions": [
          {"id": 0, "action": "strainTarget", "title": "**Ruhiger Tag** 💪", "body": "- Halte die Belastung niedrig."},
          {"id": 1, "action": "routine", "title": "Erfunden", "body": "Falsche Aktion."}]}
        """
        let parsed = CoachBriefReply.parse(reply, candidateActions: ["strainTarget", "bedtime"])
        XCTAssertEqual(parsed?.picks, [.init(index: 0, title: "Ruhiger Tag", body: "Halte die Belastung niedrig.")])
    }

    func testMalformedReplyIsRejected() {
        XCTAssertNil(CoachBriefReply.parse("Here is your brief", candidateActions: ["none"]))
        XCTAssertNil(CoachBriefReply.parse(#"{"brief": "  "}"#, candidateActions: ["none"]))
    }

    func testSystemPromptNamesTheLanguage() {
        XCTAssertTrue(CoachBriefReply.systemPrompt(languageCode: "de").contains("Antworte ausschließlich auf Deutsch"))
        XCTAssertTrue(CoachBriefReply.systemPrompt(languageCode: "en").contains("Reply only in English"))
    }

    func testPlainStripsStyling() {
        XCTAssertEqual(CoachBriefReply.plain("### Go *easy* today 🙂\nok"), "Go easy today ok")
        XCTAssertEqual(CoachBriefReply.plain("Belastung 8–12, 22:40 Uhr"), "Belastung 8–12, 22:40 Uhr")
    }

    // MARK: Language check

    func testLanguageCheckTellsGermanFromEnglish() {
        let de = "Deine Erholung ist niedrig, halte den Tag leicht und geh heute früh ins Bett."
        let en = "Your recovery is low, so keep the day light and get to bed early tonight."
        XCTAssertTrue(CoachLanguageCheck.matches(de, languageCode: "de"))
        XCTAssertFalse(CoachLanguageCheck.matches(en, languageCode: "de"))
        XCTAssertTrue(CoachLanguageCheck.matches(en, languageCode: "en"))
        XCTAssertFalse(CoachLanguageCheck.matches(de, languageCode: "en"))
    }

    func testLanguageCheckLetsShortTextPass() {
        XCTAssertTrue(CoachLanguageCheck.matches("HRV 42 ms", languageCode: "de"))
        XCTAssertTrue(CoachLanguageCheck.matches("anything at all here", languageCode: "fr"))
    }
}
