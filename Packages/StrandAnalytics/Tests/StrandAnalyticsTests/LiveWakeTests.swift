import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The live heart-rate wake heuristic on synthetic ~1 Hz streams, its effect on `GoalWake.decide`, and the
/// night record's live-stream fold.
final class LiveWakeTests: XCTestCase {

    private let now = 2_000_000

    /// One sample a second over the last `seconds`, `bpm(secondsAgo)`.
    private func stream(_ seconds: Int = 180, every: Int = 1, _ bpm: (Int) -> Double) -> [HRSample] {
        stride(from: seconds, through: 0, by: -every).map { ago in
            HRSample(ts: now - ago, bpm: Int(bpm(ago).rounded()))
        }
    }

    // MARK: Sleeping level

    func testSleepingLevelIsTheLowerQuartileOfFiveMinuteMedians() {
        // Eight 5-minute buckets at 50…57 bpm: the lower quartile of the medians is 51.
        let start = 1_000_200 // a bucket boundary (multiple of 300)
        var hr: [HRSample] = []
        for b in 0..<8 { for s in 0..<30 { hr.append(.init(ts: start + b * 300 + s * 10, bpm: 50 + b)) } }
        XCTAssertEqual(LiveWake.sleepingLevel(hr, from: start, to: start + 8 * 300), 51)
    }

    func testSleepingLevelNeedsHalfAnHour() {
        let hr = (0..<(25 * 6)).map { HRSample(ts: 1_000_200 + $0 * 10, bpm: 52) }
        XCTAssertNil(LiveWake.sleepingLevel(hr, from: 1_000_200, to: 1_000_200 + 25 * 60))
    }

    // MARK: Classification

    func testFlatAtTheSleepingLevelReadsDeep() {
        let r = LiveWake.classify(live: stream { ago in 52 + Double(ago % 3) - 1 }, sleepingBpm: 52, moving: false, now: now)
        XCTAssertEqual(r.state, .deep)
        XCTAssertEqual(r.elevatedS, 0)
    }

    func testSustainedRiseWithMovementReadsAwake() {
        // 52 asleep, then +14 for the last 100 s.
        let r = LiveWake.classify(live: stream { $0 <= 100 ? 66 : 52 }, sleepingBpm: 52, moving: true, now: now)
        XCTAssertEqual(r.state, .awake)
        XCTAssertGreaterThanOrEqual(r.elevatedS, LiveWake.awakeSustainS)
    }

    func testSameRiseWithoutMovementReadsLightNotAwake() {
        let r = LiveWake.classify(live: stream { $0 <= 100 ? 66 : 52 }, sleepingBpm: 52, moving: false, now: now)
        XCTAssertEqual(r.state, .light)
    }

    func testLargeLongRiseReadsAwakeWithoutMovement() {
        let r = LiveWake.classify(live: stream { _ in 80 }, sleepingBpm: 55, moving: false, now: now)
        XCTAssertEqual(r.state, .awake)
    }

    func testShortSpikeIsNotAwake() {
        // +25 for only 30 s: below every sustain threshold.
        let r = LiveWake.classify(live: stream { $0 <= 30 ? 77 : 52 }, sleepingBpm: 52, moving: false, now: now)
        XCTAssertEqual(r.state, .steady)
    }

    func testSmallSustainedRiseReadsLight() {
        let r = LiveWake.classify(live: stream { $0 <= 80 ? 59 : 52 }, sleepingBpm: 52, moving: false, now: now)
        XCTAssertEqual(r.state, .light)
    }

    func testRiseThatEndedIsNotCountedAsCurrent() {
        // Elevated earlier, back at the sleeping level for the last 40 s: the run is counted from now back.
        let r = LiveWake.classify(live: stream { $0 > 40 ? 70 : 52 }, sleepingBpm: 52, moving: false, now: now)
        XCTAssertEqual(r.elevatedS, 0)
        XCTAssertNotEqual(r.state, .awake)
    }

    func testTracksDifferentSleepingLevelsNotOneValue() {
        // The same absolute 66 bpm is awake for a 52-bpm sleeper and deep for a 65-bpm sleeper.
        let s = stream { _ in 66 }
        XCTAssertEqual(LiveWake.classify(live: s, sleepingBpm: 45, moving: false, now: now).state, .awake)
        XCTAssertEqual(LiveWake.classify(live: s, sleepingBpm: 52, moving: true, now: now).state, .awake)
        XCTAssertEqual(LiveWake.classify(live: s, sleepingBpm: 65, moving: false, now: now).state, .deep)
    }

    func testSparseOrStaleStreamHasNoState() {
        // One sample every 5 s: 24 in two minutes, below the minimum.
        XCTAssertNil(LiveWake.classify(live: stream(every: 5) { _ in 70 }, sleepingBpm: 52, moving: true, now: now).state)
        // Dense but the newest sample is a minute old.
        let stale = stream { _ in 70 }.filter { $0.ts <= now - 60 }
        XCTAssertNil(LiveWake.classify(live: stale, sleepingBpm: 52, moving: true, now: now).state)
        // No sleeping level to compare against.
        XCTAssertNil(LiveWake.classify(live: stream { _ in 70 }, sleepingBpm: nil, moving: true, now: now).state)
    }

    func testAGapInsideTheRunEndsIt() {
        // Elevated, but the 10 s just before the newest 30 s carry no samples: the run stops at the gap.
        let s = stream { _ in 70 }.filter { !(now - $0.ts > 30 && now - $0.ts <= 45) }
        let r = LiveWake.classify(live: s, sleepingBpm: 52, moving: true, now: now)
        XCTAssertLessThan(r.elevatedS, LiveWake.awakeSustainS)
        XCTAssertNotEqual(r.state, .awake)
    }

    // MARK: GoalWake with the live read

    private let window = GoalWake.Window(start: 1_000_000, end: 1_000_000 + 30 * 60)

    func testAwakeWakesEvenBeforeTheGoalIsMet() {
        let i = GoalWake.Inputs(now: window.start + 60, asleepMin: 300, needMin: 480, live: .awake)
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .sleepNeed), inputs: i),
                       .wake(at: window.start + 60 + GoalWake.earlyWakeLeadS, reason: .awake))
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .fixedTime), inputs: i),
                       .wake(at: window.start + 60 + GoalWake.earlyWakeLeadS, reason: .awake))
    }

    func testAwakeNeverWakesOutsideTheWindow() {
        let before = GoalWake.Inputs(now: window.start - 30, live: .awake)
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .fixedTime), inputs: before),
                       .hold(.beforeWindow))
        let late = GoalWake.Inputs(now: window.end - 60, live: .awake)
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .fixedTime), inputs: late),
                       .hold(.deadlineClose))
    }

    func testLiveDeepOverridesAStaleLightSignal() {
        let i = GoalWake.Inputs(now: window.start + 60, asleepMin: 500, needMin: 480, lightSleep: true, live: .deep)
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .sleepNeed), inputs: i),
                       .hold(.waitingForLightSleep))
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .fixedTime), inputs: i),
                       .hold(.waitingForLightSleep))
    }

    func testLiveLightWakesAMetGoal() {
        let i = GoalWake.Inputs(now: window.start + 60, asleepMin: 500, needMin: 480, live: .light)
        XCTAssertEqual(GoalWake.decide(window: window, settings: .init(mode: .sleepNeed), inputs: i),
                       .wake(at: window.start + 60 + GoalWake.earlyWakeLeadS, reason: .sleepNeedReached))
    }

    func testSteadyFallsBackToTheSyncedSignal() {
        let i = GoalWake.Inputs(now: window.start + 60, lightSleep: true, live: .steady)
        XCTAssertTrue(i.effectiveLightSleep)
        XCTAssertFalse(GoalWake.Inputs(now: 0, live: .steady).effectiveLightSleep)
    }

    // MARK: Night record

    func testLiveStreamCountsWindowSamplesAndGaps() {
        var l = SmartAlarmNight.LiveStream()
        l.toggle(on: true, reason: .windowOpening, at: window.start - 600)
        // Before the window: 100 samples; a 3-minute gap; then 200 samples inside the window.
        l.note(samples: (0..<100).map { window.start - 500 + $0 }, window: window)
        l.note(samples: (0..<200).map { window.start + 60 + $0 }, window: window)
        XCTAssertEqual(l.samplesInWindow, 200)
        XCTAssertEqual(l.gaps, [.init(start: window.start - 401, end: window.start + 60)])
        XCTAssertEqual(l.firstSampleAt, window.start - 500)
        XCTAssertEqual(l.lastSampleAt, window.start + 259)
        // A duplicate or older sample is ignored.
        l.note(samples: [window.start + 100], window: window)
        XCTAssertEqual(l.samplesInWindow, 200)
    }

    func testTogglesRecordOnlyChanges() {
        var l = SmartAlarmNight.LiveStream()
        l.toggle(on: false, reason: .windowEnded, at: 1)          // nothing held yet: not news
        l.toggle(on: true, reason: .windowOpening, at: 2)
        l.toggle(on: true, reason: .reconnected, at: 3)           // already held
        l.toggle(on: false, reason: .woken, at: 4)
        XCTAssertEqual(l.toggles.map(\.at), [2, 4])
        XCTAssertEqual(l.lastOff?.reason, .woken)
        XCTAssertFalse(l.isHeld)
    }

    func testOpenGapOnlyWhileHeld() {
        var l = SmartAlarmNight.LiveStream()
        l.toggle(on: true, reason: .windowOpening, at: 100)
        XCTAssertEqual(l.openGap(now: 200), .init(start: 100, end: 200))
        l.note(samples: [190], window: window)
        XCTAssertNil(l.openGap(now: 200))
        l.toggle(on: false, reason: .windowEnded, at: 300)
        XCTAssertNil(l.openGap(now: 1000))
    }

    func testEvaluationsAreCountedByTrigger() {
        var n = SmartAlarmNight(deadline: window.end, windowStart: window.start, settings: .init(mode: .fixedTime),
                                needMin: nil, plannedChecks: GoalWake.plannedChecks(window: window, intervalS: 180))
        func c(_ at: Int, _ t: SmartAlarmNight.Trigger) -> SmartAlarmNight.Check {
            .init(ranAt: at, evaluatedAt: at, connected: true, sync: .notRequested, hrAgeS: 1, gravityAgeS: nil,
                  asleepMin: nil, needMin: nil, recoveryEstimate: nil, lightSleep: nil, decision: "waitingForLightSleep",
                  trigger: t, liveState: "deep")
        }
        n.checks = [c(window.start - 300, .stream), c(window.start + 10, .timer), c(window.start + 70, .stream),
                    c(window.start + 130, .stream), c(window.start + 400, .appWake)]
        let e = n.evaluationsByTrigger
        XCTAssertEqual(e.stream, 2)
        XCTAssertEqual(e.timer, 1)
        XCTAssertEqual(e.appWake, 1)
    }

    func testLiveStreamRoundTripsThroughJSON() throws {
        var n = SmartAlarmNight(deadline: window.end, windowStart: window.start, settings: .init(mode: .recovery),
                                needMin: 480, plannedChecks: [])
        var l = SmartAlarmNight.LiveStream()
        l.toggle(on: true, reason: .windowOpening, at: 5)
        l.note(samples: [10, 200], window: window)
        n.liveStream = l
        let data = try JSONEncoder().encode(n)
        XCTAssertEqual(try JSONDecoder().decode(SmartAlarmNight.self, from: data), n)
    }

    func testRecordWithoutLiveFieldsStillDecodes() throws {
        // A night written before the live stream existed (no liveStream, no trigger, no liveState).
        let json = """
        {"deadline":100,"windowStart":40,"settings":{"mode":"sleepNeed","recoveryThreshold":67,
        "preferLightSleep":true,"lightSleepGraceMin":10},"plannedChecks":[40],"arms":[],"events":[],
        "checks":[{"ranAt":41,"evaluatedAt":42,"connected":true,"sync":"completed","decision":"noData"}]}
        """
        let n = try JSONDecoder().decode(SmartAlarmNight.self, from: Data(json.utf8))
        XCTAssertNil(n.liveStream)
        XCTAssertNil(n.checks.first?.trigger)
    }
}
