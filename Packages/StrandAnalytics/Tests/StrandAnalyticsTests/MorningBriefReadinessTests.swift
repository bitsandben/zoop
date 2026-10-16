import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The morning brief on a partial night (owner report, 1.9.2: "you slept 2 h 27 min … recovery 17" after a
/// full night). Synthetic nights only: they pin the gate, they do not validate staging on real nights.
final class MorningBriefReadinessTests: XCTestCase {

    /// 2026-06-09 14:00 UTC; tzOffset 0 so local hour == UTC hour.
    private let t14 = 1_749_513_600 - 10 * 3600
    private func at(_ hour: Int, _ minute: Int = 0) -> Int {
        let h = hour >= 14 ? hour - 14 : hour + 10
        return t14 + h * 3600 + minute * 60
    }

    private func gravity(_ from: Int, _ to: Int, active: Bool) -> [GravitySample] {
        (from..<to).map { ts in
            let i = ts - from
            return GravitySample(ts: ts, x: active ? Double(i % 2) * 0.5 : 0.0, y: 0, z: 1.0)
        }
    }

    private func hr(_ from: Int, _ to: Int, step: Int = 2, _ bpm: (Int) -> Int) -> [HRSample] {
        stride(from: from, to: to, by: step).map { HRSample(ts: $0, bpm: bpm($0)) }
    }

    private func sleepingBpm(_ ts: Int) -> Int { 55 + [0, 1, 2, 1, 0, -1, -2, -1][(ts / 60) % 8] }

    /// 20:00–23:30 active, 23:30–07:00 asleep, 07:00–09:00 active: the whole strap history of the night.
    private func fullNight() -> (hr: [HRSample], grav: [GravitySample]) {
        var g = gravity(at(20), at(23, 30), active: true)
        g += gravity(at(23, 30), at(7), active: false)
        g += gravity(at(7), at(9), active: true)
        var h = hr(at(20), at(23, 30)) { _ in 82 }
        h += hr(at(23, 30), at(7)) { self.sleepingBpm($0) }
        h += hr(at(7), at(9)) { _ in 84 }
        return (h, g)
    }

    /// What the store holds when the history offload stopped at `cut`.
    private func offloaded(until cut: Int) -> (hr: [HRSample], grav: [GravitySample]) {
        let n = fullNight()
        return (n.hr.filter { $0.ts < cut }, n.grav.filter { $0.ts < cut })
    }

    private func mainSession(_ s: [SleepSession]) -> SleepSession? {
        s.max { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    private func input(now: Int, end: Int?, frontier: Int?, busy: Bool = false) -> MorningBriefReadiness.Input {
        // tzOffset 0: local hour is the UTC hour, and every night end here is on the morning's day.
        let hour = ((now % 86_400) + 86_400) % 86_400 / 3600
        return .init(nowTs: now, nightEndTs: end, dataFrontierTs: frontier, syncBusy: busy, localHour: hour,
                     nightEndIsToday: true)
    }

    // MARK: - Reproduction

    func testPartialOffloadEndsTheNightAtTheDataEdge() throws {
        // The offload stopped at 01:57: the stored night is 23:30–01:57, about 2 h 27 min, and it "ends" on
        // the morning's day before now. That is everything the old gate asked for.
        let cut = at(1, 57)
        let part = offloaded(until: cut)
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: part.hr, gravity: part.grav)))
        let asleepMin = Double(s.end - s.start) / 60
        XCTAssertGreaterThan(asleepMin, 120, "partial night \(asleepMin) min")
        XCTAssertLessThan(asleepMin, 170, "partial night \(asleepMin) min")
        // The cut night ends at the data edge, well inside the wake margin.
        XCTAssertLessThan(cut - s.end, MorningBriefReadiness.wakeMarginSec,
                          "session ends \(cut - s.end) s before the data edge")

        // Old gate: night ended today, before now, nothing in flight → the brief went out at 02:30.
        let now = at(2, 30)
        XCTAssertTrue(s.end <= now)
        // New gate: too early, and even later in the morning the night stays open until history reaches past it.
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: now, end: s.end, frontier: cut)), .tooEarly)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(6, 50), end: s.end, frontier: cut)), .nightOpen)
    }

    func testLiveHeartRateMustNotCountAsOffloadedHistory() throws {
        // History stopped at 01:57; the smart alarm's live stream then stored HR from 06:20 to 06:45 at
        // the phone's clock. The store-wide newest sample reads 06:45, the history frontier still 01:57.
        let cut = at(1, 57)
        var part = offloaded(until: cut)
        let live = hr(at(6, 20), at(6, 45), step: 1) { _ in 58 }
        part.hr += live
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: part.hr, gravity: part.grav)))
        XCTAssertLessThan(Double(s.end - s.start) / 60, 170)
        let storeLatest = part.hr.map(\.ts).max()
        let now = at(6, 50)
        // The store-wide frontier would call the truncated night finished…
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: now, end: s.end, frontier: storeLatest)), .ready)
        // …the history frontier does not.
        let frontier = MorningBriefReadiness.dataFrontier(historyFrontierTs: cut - 1, storeLatestTs: storeLatest)
        XCTAssertEqual(frontier, cut - 1)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: now, end: s.end, frontier: frontier)), .nightOpen)
    }

    func testNightDeliveredInTwoChunksIsWholeAndReady() throws {
        // First offload to 01:57, the rest after waking: the store holds the union, the night is whole.
        let full = fullNight()
        let first = offloaded(until: at(1, 57))
        let hrUnion = first.hr + full.hr.filter { $0.ts >= at(1, 57) }
        let gUnion = first.grav + full.grav.filter { $0.ts >= at(1, 57) }
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: hrUnion, gravity: gUnion)))
        let asleepMin = Double(s.end - s.start) / 60
        XCTAssertGreaterThan(asleepMin, 7 * 60, "merged night \(asleepMin) min")
        let frontier = at(7, 40)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7, 45), end: s.end, frontier: frontier)), .ready)
    }

    func testLiveSamplesInterleavedWithHistoryDoNotShortenTheNight() throws {
        // Full history plus the live stream's own samples on odd seconds over the wake window.
        let full = fullNight()
        let live = hr(at(6, 21) + 1, at(6, 50), step: 2) { _ in 57 }
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: (full.hr + live).sorted { $0.ts < $1.ts },
                                                                  gravity: full.grav)))
        XCTAssertGreaterThan(Double(s.end - s.start) / 60, 7 * 60)
    }

    func testMidNightWakeBeforeTheMorningHourIsNotTheEnd() {
        // Awake 02:00–02:30, synced at 02:31: history reaches 30 min past the sleep end, but it is 02:31.
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(2, 31), end: at(2), frontier: at(2, 30))),
                       .tooEarly)
    }

    // MARK: - Gate

    func testSyncInFlightAndNoNightHold() {
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7), end: at(6), frontier: at(7), busy: true)),
                       .syncInFlight)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7), end: nil, frontier: at(7))), .noNight)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7), end: at(7, 5), frontier: at(7))), .noNight)
    }

    func testWakeMarginBoundary() {
        let end = at(6, 40)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7), end: end, frontier: end + 14 * 60)), .nightOpen)
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7), end: end, frontier: end + 15 * 60)), .ready)
    }

    func testNoFrontierKeepsTheStoredNight() {
        // Imported / Apple Health nights: no offload to compare with.
        XCTAssertEqual(MorningBriefReadiness.evaluate(input(now: at(7), end: at(6, 40), frontier: nil)), .ready)
        XCTAssertNil(MorningBriefReadiness.dataFrontier(historyFrontierTs: nil, storeLatestTs: nil))
        XCTAssertEqual(MorningBriefReadiness.dataFrontier(historyFrontierTs: nil, storeLatestTs: 5), 5)
    }

    // MARK: - Rewrite

    func testRewriteWhenTheNightGrew() {
        let partial = MorningBriefReadiness.Basis(day: "2026-06-10", sleepMin: 147, nightEndTs: at(1, 57),
                                                  recovery: 17, writtenAt: at(2, 30))
        XCTAssertTrue(MorningBriefReadiness.needsWrite(previous: nil, day: "2026-06-10", sleepMin: 147,
                                                       nightEndTs: at(1, 57)))
        XCTAssertTrue(MorningBriefReadiness.needsWrite(previous: partial, day: "2026-06-11", sleepMin: 147,
                                                       nightEndTs: at(1, 57)))
        XCTAssertTrue(MorningBriefReadiness.needsWrite(previous: partial, day: "2026-06-10", sleepMin: 450,
                                                       nightEndTs: at(7)))
        XCTAssertFalse(MorningBriefReadiness.needsWrite(previous: partial, day: "2026-06-10", sleepMin: 150,
                                                        nightEndTs: at(1, 59)))
        // Same total, later end (a wake moved): rewrite.
        XCTAssertTrue(MorningBriefReadiness.needsWrite(previous: partial, day: "2026-06-10", sleepMin: 147,
                                                       nightEndTs: at(2, 30)))
    }

    func testBasisRoundTrips() throws {
        let b = MorningBriefReadiness.Basis(day: "2026-06-10", sleepMin: 447, nightEndTs: 1, recovery: 64, writtenAt: 2)
        let data = try JSONEncoder().encode(b)
        XCTAssertEqual(try JSONDecoder().decode(MorningBriefReadiness.Basis.self, from: data), b)
    }

    func testNightRecordsWithoutBriefsStillDecode() throws {
        // nights.json written by 1.9.x has no "briefs" key.
        var n = SmartAlarmNight(deadline: 100, windowStart: 50, settings: .init(mode: .fixedTime), needMin: nil,
                                plannedChecks: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(n)) as? [String: Any])
        json.removeValue(forKey: "briefs")
        let old = try JSONDecoder().decode(SmartAlarmNight.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.briefs)
        n.briefs = [.init(at: 90, sleepMin: 441, recovery: 64, nightEndTs: 80, frontierTs: 89, rewrite: true)]
        XCTAssertEqual(try JSONDecoder().decode(SmartAlarmNight.self, from: JSONEncoder().encode(n)), n)
    }
}
