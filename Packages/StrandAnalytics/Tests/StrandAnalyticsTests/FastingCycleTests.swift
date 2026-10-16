import XCTest
@testable import StrandAnalytics

final class FastingCycleTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// 2026-03-10 00:00 Berlin, plus days and hours.
    private func t(_ day: Int, _ hour: Double) -> Date {
        let base = cal.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        return cal.date(byAdding: .day, value: day, to: base)!.addingTimeInterval(hour * 3600)
    }

    private func fast(_ id: String, _ start: Date, _ end: Date?, goalHours: Double = 16) -> FastingInterval {
        FastingInterval(id: id, start: start, end: end, goal: goalHours * 3600)
    }

    private let flexible = FastingSchedule(plan: .sixteen, mode: .flexible)
    private let fixed20 = FastingSchedule(plan: .sixteen, mode: .fixed(startMinute: 20 * 60))

    // MARK: Schedule

    func testFlexibleWindowIsThePlansEatingHours() {
        XCTAssertEqual(flexible.windowClose(after: t(0, 12), calendar: cal), t(0, 20))
        let long = FastingSchedule(plan: .custom(hours: 36), mode: .flexible)
        XCTAssertEqual(long.eatingWindowLength, 3600)
    }

    func testFixedWindowClosesAtTheNextPlannedStart() {
        XCTAssertEqual(fixed20.windowClose(after: t(0, 10), calendar: cal), t(0, 20))
        // A fast that ran past the planned start leaves the window open until tomorrow's.
        XCTAssertEqual(fixed20.windowClose(after: t(0, 20.5), calendar: cal), t(1, 20))
        XCTAssertEqual(fixed20.plannedStart(onOrBefore: t(0, 21), calendar: cal), t(0, 20))
        XCTAssertEqual(fixed20.plannedStart(onOrBefore: t(0, 19), calendar: cal), t(-1, 20))
        XCTAssertEqual(fixed20.plannedStart(after: t(0, 20), calendar: cal), t(1, 20))
        XCTAssertNil(flexible.plannedStart(after: t(0, 20), calendar: cal))
    }

    func testFixedStartSurvivesDaylightSavingChange() {
        // 2026-03-29 is the spring-forward day in Berlin; 20:00 is still 20:00 local.
        let start = fixed20.plannedStart(after: t(18, 21), calendar: cal)!
        XCTAssertEqual(cal.component(.hour, from: start), 20)
        XCTAssertEqual(cal.component(.day, from: start), 29)
    }

    // MARK: State machine

    func testRunningFastWins() {
        let state = FastingCycle.state([fast("a", t(0, 20), nil)], schedule: flexible, now: t(1, 8), calendar: cal)
        guard case .fasting(let i, let s) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(i.id, "a")
        XCTAssertEqual(s.elapsed, 12 * 3600)
        XCTAssertTrue(state.isFasting)
    }

    func testEndingAFastOpensTheEatingWindowWithACountdown() {
        let log = [fast("a", t(-1, 20), t(0, 12))]
        let state = FastingCycle.state(log, schedule: flexible, now: t(0, 16.8), calendar: cal)
        guard case .eating(let w) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(w.opens, t(0, 12))
        XCTAssertEqual(w.closes, t(0, 20))
        XCTAssertEqual(w.remaining(now: t(0, 16.8)), 3.2 * 3600, accuracy: 1)
        XCTAssertEqual(w.progress(now: t(0, 16)), 0.5, accuracy: 0.0001)
    }

    func testClosedWindowMakesTheNextFastDueThenGoesIdle() {
        let log = [fast("a", t(-1, 20), t(0, 12))]
        XCTAssertEqual(FastingCycle.state(log, schedule: flexible, now: t(0, 21), calendar: cal), .due(since: t(0, 20)))
        XCTAssertEqual(FastingCycle.state(log, schedule: flexible, now: t(1, 3), calendar: cal), .waiting(next: nil))
        // A fixed plan idles until its next start, then makes that start due.
        XCTAssertEqual(FastingCycle.state(log, schedule: fixed20, now: t(1, 3), calendar: cal), .waiting(next: t(1, 20)))
        XCTAssertEqual(FastingCycle.state(log, schedule: fixed20, now: t(1, 20.5), calendar: cal), .due(since: t(1, 20)))
    }

    func testFixedPlanWithoutHistoryIsDueAtItsStart() {
        XCTAssertEqual(FastingCycle.state([], schedule: fixed20, now: t(0, 21), calendar: cal), .due(since: t(0, 20)))
        XCTAssertEqual(FastingCycle.state([], schedule: fixed20, now: t(0, 10), calendar: cal), .waiting(next: t(0, 20)))
        XCTAssertEqual(FastingCycle.state([], schedule: flexible, now: t(0, 10), calendar: cal), .waiting(next: nil))
    }

    func testAutoStartOnlyOncePerPlannedStart() {
        let due = FastingCycleState.due(since: t(0, 20))
        XCTAssertEqual(FastingCycle.autoStart(due, lastAutoStart: nil), t(0, 20))
        XCTAssertEqual(FastingCycle.autoStart(due, lastAutoStart: t(-1, 20)), t(0, 20))
        XCTAssertNil(FastingCycle.autoStart(due, lastAutoStart: t(0, 20)))
        XCTAssertNil(FastingCycle.autoStart(.waiting(next: nil), lastAutoStart: nil))
    }

    func testRemindersFollowThePhase() {
        let running = FastingCycle.state([fast("a", t(0, 20), nil)], schedule: flexible, now: t(0, 22), calendar: cal)
        let r1 = FastingCycle.reminders(running, now: t(0, 22))
        XCTAssertEqual(r1.goal, t(1, 12))
        XCTAssertNil(r1.closing)

        let eating = FastingCycleState.eating(EatingWindow(opens: t(0, 12), closes: t(0, 20)))
        let r2 = FastingCycle.reminders(eating, now: t(0, 13))
        XCTAssertNil(r2.goal)
        XCTAssertEqual(r2.closing, t(0, 19.5))
        XCTAssertEqual(r2.start, t(0, 20))
        // Past dates are dropped.
        XCTAssertNil(FastingCycle.reminders(eating, now: t(0, 19.75)).closing)
    }

    // MARK: Windows, timeline, stats

    func testEatingWindowsAreGapsBetweenFasts() {
        let log = [fast("a", t(0, 20), t(1, 12)), fast("b", t(1, 20), t(2, 12)), fast("c", t(4, 20), t(5, 12))]
        let windows = FastingCycle.eatingWindows(log)
        XCTAssertEqual(windows.count, 1, "the 2.5-day gap is untracked, not a window")
        XCTAssertEqual(windows.first?.length, 8 * 3600)
        XCTAssertEqual(windows.first?.previousID, "a")
        XCTAssertEqual(windows.first?.nextID, "b")
    }

    func testTimelineClipsPhasesToDays() {
        let log = [fast("a", t(0, 20), t(1, 12)), fast("b", t(1, 20), nil)]
        let days = FastingCycle.timeline(log, open: nil, now: t(1, 22), days: 2, calendar: cal)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].segments.map(\.kind), [.fasting])
        XCTAssertEqual(days[0].segments[0].startFraction, 20.0 / 24, accuracy: 0.0001)
        XCTAssertEqual(days[1].segments.map(\.kind), [.fasting, .eating, .fasting])
        XCTAssertEqual(days[1].segments[1].endFraction, 20.0 / 24, accuracy: 0.0001)
        XCTAssertTrue(days[1].segments[2].isLive)
        XCTAssertEqual(days[1].segments[2].endFraction, 22.0 / 24, accuracy: 0.0001)
    }

    func testTimelineDrawsTheOpenWindowUpToNow() {
        let log = [fast("a", t(0, 20), t(1, 12))]
        let open = EatingWindow(opens: t(1, 12), closes: t(1, 20))
        let day = FastingCycle.timeline(log, open: open, now: t(1, 15), days: 1, calendar: cal)[0]
        XCTAssertEqual(day.segments.last?.kind, .eating)
        XCTAssertEqual(day.segments.last?.endFraction ?? 0, 15.0 / 24, accuracy: 0.0001)
        XCTAssertEqual(day.segments.last?.isLive, true)
    }

    func testStatsAverageLongestAndAdherence() {
        let log = [fast("a", t(0, 20), t(1, 12)),          // 16 h, met
                   fast("b", t(1, 20), t(2, 10)),          // 14 h, missed
                   fast("c", t(2, 20), t(3, 14))]          // 18 h, met
        let s = FastingCycle.stats(log, now: t(3, 18), days: 30, calendar: cal)
        XCTAssertEqual(s.fastsCounted, 3)
        XCTAssertEqual(s.averageFast, 16 * 3600)
        XCTAssertEqual(s.longestFast, 18 * 3600)
        XCTAssertEqual(s.averageEatingWindow, 9 * 3600)   // 8 h and 10 h
        // Days 0..3 considered (today is met by c): met on day 1 and day 3.
        XCTAssertEqual(s.adherence ?? -1, 0.5, accuracy: 0.0001)
    }

    func testStatsEmpty() {
        let s = FastingCycle.stats([], now: t(0, 12), calendar: cal)
        XCTAssertNil(s.averageFast)
        XCTAssertNil(s.adherence)
        XCTAssertEqual(s.fastsCounted, 0)
    }

    func testWindowEditValidatesBothNeighbours() {
        let a = fast("a", t(0, 20), t(1, 12)), b = fast("b", t(1, 20), t(2, 12))
        XCTAssertEqual(FastingCycle.validateWindow(opens: t(1, 11), closes: t(1, 19), previous: a, next: b,
                                                   now: t(3, 0), others: [a, b]), .ok)
        XCTAssertEqual(FastingCycle.validateWindow(opens: t(1, 19), closes: t(1, 18), previous: a, next: b,
                                                   now: t(3, 0), others: [a, b]), .endBeforeStart)
        XCTAssertEqual(FastingCycle.validateWindow(opens: t(0, 19), closes: t(1, 19), previous: a, next: b,
                                                   now: t(3, 0), others: [a, b]), .endBeforeStart)
    }

    func testRingShare() {
        XCTAssertEqual(FastingCycle.ringFastingShare(goal: 16 * 3600, eatingWindow: 8 * 3600), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(FastingCycle.ringFastingShare(goal: 0, eatingWindow: 0), 1)
    }
}
