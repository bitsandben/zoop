import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class AlarmAnchoredWakeTests: XCTestCase {
    // Night 23:00 → detected end 07:30 (relative seconds), alarm at 07:00.
    let start = 0
    let end = 8 * 3600 + 30 * 60
    let alarm = 8 * 3600

    func session() -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 1,
                     stages: [StageSegment(start: start, end: alarm - 1800, stage: "deep"),
                              StageSegment(start: alarm - 1800, end: end, stage: "light")],
                     restingHR: 50, avgHRV: 60, hrOnly: false)
    }

    /// 1 Hz heart rate: `sleeping` until `riseAt`, then `awake`.
    func hr(sleeping: Int = 52, awake: Int = 75, riseAt: Int?) -> [HRSample] {
        stride(from: alarm - 1800, to: alarm + 3600, by: 5).map { t in
            HRSample(ts: t, bpm: (riseAt.map { t >= $0 } ?? false) ? awake : sleeping)
        }
    }

    func testEndsAtTheRiseAndMarksTheTailWake() {
        let out = AlarmAnchoredWake.refine(session(), alarmFires: [alarm], hr: hr(riseAt: alarm + 12 * 60))
        XCTAssertEqual(out.end, alarm + 12 * 60)
        XCTAssertEqual(out.stages.last, StageSegment(start: alarm, end: alarm + 12 * 60, stage: "wake"))
        XCTAssertEqual(out.stages.first?.stage, "deep")
        XCTAssertEqual(out.restingHR, 50)
        XCTAssertLessThan(out.efficiency, 1)
    }

    func testExtendsANightTheDetectorEndedBeforeTheAlarm() {
        let early = SleepSession(start: start, end: alarm - 600, efficiency: 1,
                                 stages: [StageSegment(start: start, end: alarm - 600, stage: "light")],
                                 restingHR: nil, avgHRV: nil, hrOnly: false)
        let out = AlarmAnchoredWake.refine(early, alarmFires: [alarm], hr: hr(riseAt: alarm + 5 * 60))
        XCTAssertEqual(out.end, alarm + 5 * 60)
        XCTAssertEqual(out.stages.last, StageSegment(start: alarm - 600, end: alarm + 5 * 60, stage: "wake"))
    }

    func testNoRiseLeavesTheNightAlone() {
        XCTAssertEqual(AlarmAnchoredWake.refine(session(), alarmFires: [alarm], hr: hr(riseAt: nil)), session())
    }

    func testABriefSpikeIsNotGettingUp() {
        var samples = hr(riseAt: nil)
        samples = samples.map { ($0.ts >= alarm + 60 && $0.ts < alarm + 120) ? HRSample(ts: $0.ts, bpm: 90) : $0 }
        XCTAssertEqual(AlarmAnchoredWake.refine(session(), alarmFires: [alarm], hr: samples), session())
    }

    func testAlarmFarFromTheEndOrEarlyInTheNightIsIgnored() {
        let rise = hr(riseAt: alarm + 600)
        XCTAssertEqual(AlarmAnchoredWake.refine(session(), alarmFires: [3600], hr: rise), session())
        XCTAssertEqual(AlarmAnchoredWake.refine(session(), alarmFires: [end + 2 * 3600], hr: rise), session())
        XCTAssertEqual(AlarmAnchoredWake.refine(session(), alarmFires: [], hr: rise), session())
    }

    func testDisabledIsAPassthrough() {
        XCTAssertEqual(AlarmAnchoredWake.apply(session(), alarmFires: [alarm], hr: hr(riseAt: alarm + 600),
                                               enabled: false), session())
    }

    func testPicksStrapAlarmEventsOnly() {
        let events = [WhoopEvent(ts: 5, kind: "STRAP_DRIVEN_ALARM_EXECUTED(57)", payload: [:]),
                      WhoopEvent(ts: 6, kind: "APP_DRIVEN_ALARM_EXECUTED(58)", payload: [:]),
                      WhoopEvent(ts: 7, kind: "WRIST_OFF(10)", payload: [:])]
        XCTAssertEqual(AlarmAnchoredWake.alarmFires(events), [5])
    }
}
