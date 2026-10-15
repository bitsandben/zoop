import XCTest
@testable import StrandAnalytics

/// Reading a smart-alarm night: did the app run in the window, and what woke the wearer.
final class SmartAlarmNightTests: XCTestCase {

    private let interval = 180
    private let window = GoalWake.Window(start: 1_000_000, end: 1_000_000 + 20 * 60)

    private func night(mode: GoalWake.Mode = .sleepNeed) -> SmartAlarmNight {
        SmartAlarmNight(deadline: window.end, windowStart: window.start, settings: .init(mode: mode), needMin: 480,
                        plannedChecks: GoalWake.plannedChecks(window: window, intervalS: interval))
    }

    private func check(_ at: Int, decision: String = "conditionNotMet") -> SmartAlarmNight.Check {
        .init(ranAt: at, evaluatedAt: at + 20, connected: true, sync: .completed, hrAgeS: 30, gravityAgeS: 30,
              asleepMin: 400, needMin: 480, recoveryEstimate: nil, lightSleep: nil, decision: decision)
    }

    func testNoCheckRanReadsAppNotRunning() {
        let n = night()
        XCTAssertEqual(n.coverage(now: window.end + 60, intervalS: interval), .none)
        XCTAssertEqual(n.outcome(now: window.end + 60), .deadlineAppNotRunning)
        XCTAssertEqual(n.missedChecks(intervalS: interval).count, n.plannedChecks.count)
    }

    func testEveryCheckRanReadsFull() {
        var n = night()
        n.checks = n.plannedChecks.map { check($0 + 5) }
        XCTAssertEqual(n.coverage(now: window.end + 60, intervalS: interval), .full)
        XCTAssertEqual(n.outcome(now: window.end + 60), .deadlineGoalNotMet)
    }

    func testSomeChecksMissedReadsPartial() {
        var n = night()
        n.checks = [check(window.start + 2)]
        XCTAssertEqual(n.coverage(now: window.end + 60, intervalS: interval), .partial)
        XCTAssertEqual(n.outcome(now: window.end + 60), .deadlineGoalNotMet)
    }

    func testLateCheckCoversTheSlotItLandsIn() {
        var n = night()
        // Suspended through the first slot, woken 4 min in: covers the 3-min slot, not the first.
        n.checks = [check(window.start + 240)]
        let missed = n.missedChecks(intervalS: interval)
        XCTAssertTrue(missed.contains(window.start))
        XCTAssertFalse(missed.contains(window.start + 180))
    }

    func testEarlyWakeEndsTheRelevantChecks() {
        var n = night()
        n.checks = [check(window.start + 1), check(window.start + 181, decision: "wake")]
        n.earlyWake = .init(decidedAt: window.start + 200, wakeAt: window.start + 211, reason: .sleepNeedReached)
        XCTAssertEqual(n.coverage(now: window.start + 300, intervalS: interval), .full)
        XCTAssertEqual(n.outcome(now: window.start + 300), .earlyWake(at: window.start + 211, reason: .sleepNeedReached))
    }

    func testPendingUntilTheDeadline() {
        let n = night()
        XCTAssertEqual(n.coverage(now: window.start + 60, intervalS: interval), .pending)
        XCTAssertEqual(n.outcome(now: window.start + 60), .pending)
    }

    func testPlainAlarmIsNotJudged() {
        let n = SmartAlarmNight(deadline: window.end, windowStart: window.end, settings: .init(mode: .fixedTime),
                                needMin: nil, plannedChecks: [])
        XCTAssertEqual(n.coverage(now: window.end + 60, intervalS: interval), .notApplicable)
        XCTAssertEqual(n.outcome(now: window.end + 60), .deadlineFixed)
    }

    func testSummaryCountsOnlyJudgedNights() {
        var acted = night()
        acted.checks = [check(window.start)]
        var missed = night()
        missed.deadline += 86_400; missed.windowStart += 86_400
        missed.plannedChecks = missed.plannedChecks.map { $0 + 86_400 }
        var tonight = night()
        tonight.deadline += 2 * 86_400; tonight.windowStart += 2 * 86_400
        tonight.plannedChecks = tonight.plannedChecks.map { $0 + 2 * 86_400 }
        let s = SmartAlarmNight.summary([acted, missed, tonight], now: window.end + 86_400 + 60, intervalS: interval)
        XCTAssertEqual(s.acted, 1)
        XCTAssertEqual(s.total, 2)
    }

    func testPrunedKeepsNewestOnePerDeadline() {
        var a = night(); a.needMin = 1
        var b = night(); b.needMin = 2
        var older = night(); older.deadline -= 86_400
        let p = SmartAlarmNight.pruned([older, a, b], keep: 1)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.needMin, 2)
    }

    func testRoundTripsThroughJSON() throws {
        var n = night(mode: .recovery)
        n.checks = [check(window.start)]
        n.events = [.init(at: window.start, kind: .bleRestore)]
        let data = try JSONEncoder().encode(n)
        XCTAssertEqual(try JSONDecoder().decode(SmartAlarmNight.self, from: data), n)
    }
}
