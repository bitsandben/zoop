import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// HR-confirmed sleep onset (`SleepStager.hrConfirmedOnset`). A quiet evening on the sofa is
/// gravity-still, so the detector used to start the night there ("bed 22:08" when the wearer went to
/// bed ~23:00). Synthetic evenings only — this pins the rule, it does not validate it on real nights.
final class SleepOnsetTrimTests: XCTestCase {

    /// 2026-06-09 14:00 UTC; tzOffset 0 so local hour == UTC hour.
    private let t14 = 1_749_513_600 - 10 * 3600
    private func at(_ hour: Int, _ minute: Int = 0) -> Int {
        // Hours ≥ 14 are on the evening day, < 14 on the next morning.
        let h = hour >= 14 ? hour - 14 : hour + 10
        return t14 + h * 3600 + minute * 60
    }

    /// Gravity at 1 Hz: active (0.5 g jumps) / still, with an optional 20 s fidget every `fidgetEveryMin`.
    private func gravity(_ from: Int, _ to: Int, active: Bool, fidgetEveryMin: Int? = nil) -> [GravitySample] {
        (from..<to).map { ts in
            let i = ts - from
            var moving = active
            if let every = fidgetEveryMin, i % (every * 60) < 20 { moving = true }
            let x = moving ? Double(i % 2) * 0.5 : 0.0
            return GravitySample(ts: ts, x: x, y: 0, z: 1.0)
        }
    }

    /// HR every 2 s from a per-second bpm function.
    private func hr(_ from: Int, _ to: Int, _ bpm: (Int) -> Int) -> [HRSample] {
        stride(from: from, to: to, by: 2).map { HRSample(ts: $0, bpm: bpm($0)) }
    }

    /// Sleeping HR: 53–57 bpm wobble.
    private func sleepingBpm(_ ts: Int) -> Int { 55 + [0, 1, 2, 1, 0, -1, -2, -1][(ts / 60) % 8] }

    /// 14:00–22:00 active; 22:00–23:05 quiet sitting (fidget every 8 min) at `sofaBpm`; 23:05–07:00
    /// asleep with HR falling from 68 to the sleeping level over 10 min; 07:00–09:00 active.
    private func evening(sofaBpm: @escaping (Int) -> Int) -> (hr: [HRSample], grav: [GravitySample]) {
        let sleepStart = at(23, 5)
        var g = gravity(at(14), at(22), active: true)
        g += gravity(at(22), sleepStart, active: false, fidgetEveryMin: 8)
        g += gravity(sleepStart, at(7), active: false)
        g += gravity(at(7), at(9), active: true)
        var h = hr(at(14), at(22)) { _ in 85 }
        h += hr(at(22), sleepStart, sofaBpm)
        h += hr(sleepStart, at(7)) { ts in
            let minIn = Double(ts - sleepStart) / 60.0
            if minIn < 10 { return Int((68.0 - 1.3 * minIn).rounded()) }   // 68 → 55 over 10 min
            return self.sleepingBpm(ts)
        }
        h += hr(at(7), at(9)) { _ in 85 }
        return (h, g)
    }

    private func mainSession(_ s: [SleepSession]) -> SleepSession? {
        s.max { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    func testQuietSofaHourAtWakingHRIsNotSleep() throws {
        // Sofa HR ~76 (daytime resting + ~10), clearly above the night's ~55 sleeping level.
        let e = evening { ts in 76 + [0, 2, -1, 1, -2][(ts / 60) % 5] }
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: e.hr, gravity: e.grav)))
        XCTAssertGreaterThanOrEqual(s.start, at(23, 0), "onset \(s.start - at(22)) s after 22:00")
        XCTAssertLessThanOrEqual(s.start, at(23, 15), "onset \(s.start - at(22)) s after 22:00")
        // The wake end is untouched.
        XCTAssertGreaterThan(s.end, at(6, 50))
    }

    func testSameGravityWithSleepingHRKeepsTheEarlyStart() throws {
        // Control: identical gravity, but the "sofa" hour already carries the sleeping HR. That is not
        // distinguishable from early sleep, so the rule must leave the gravity onset (~22:00) alone —
        // which also proves the test above starts from a run that really began at ~22:00.
        let e = evening { ts in self.sleepingBpm(ts) }
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: e.hr, gravity: e.grav)))
        XCTAssertLessThan(s.start, at(22, 20), "control onset \(s.start - at(22)) s after 22:00")
    }

    func testSlightlyRaisedLeadIsLeftAlone() throws {
        // A lead only ~4 bpm above the sleeping level is ordinary settling, not clearly awake.
        let e = evening { ts in 59 + [0, 1, -1][(ts / 60) % 3] }
        let s = try XCTUnwrap(mainSession(SleepStager.detectSleep(hr: e.hr, gravity: e.grav)))
        XCTAssertLessThan(s.start, at(22, 20))
    }

    func testOnsetHelperNeverTrimsBelowMinSleep() {
        // A 70-minute run whose first 30 minutes are awake-HR: trimming would leave 40 min ≤ minSleepMin,
        // so the start is kept.
        let start = at(23), end = at(23) + 70 * 60
        let h = hr(start, end) { ts in ts - start < 30 * 60 ? 80 : 55 }
        let g = gravity(start, end, active: false)
        let p = SleepStager.Period(stage: "sleep", start: start, end: end)
        XCTAssertEqual(SleepStager.hrConfirmedOnset(p, hr: h, grav: g), start)
    }

    func testOnsetHelperIgnoresSparseHR() {
        // Under onsetTrimMinHRMinutes of HR coverage → no judgement, start unchanged.
        let start = at(22), end = at(6)
        let h = stride(from: start, to: start + 40 * 60, by: 60).map { HRSample(ts: $0, bpm: 80) }
        let g = gravity(start, end, active: false)
        let p = SleepStager.Period(stage: "sleep", start: start, end: end)
        XCTAssertEqual(SleepStager.hrConfirmedOnset(p, hr: h, grav: g), start)
    }
}
