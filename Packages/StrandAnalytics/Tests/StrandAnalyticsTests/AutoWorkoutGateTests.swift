import XCTest
@testable import StrandAnalytics

final class AutoWorkoutGateTests: XCTestCase {

    /// 06:50 local-ish anchor; only relative times matter.
    private let wake = 1_760_000_000

    /// One HR sample every 5 s from `start` for `minutes`, cycling through `bpms`.
    private func hr(from start: Int, minutes: Int, bpms: [Int]) -> [(ts: Int, bpm: Int)] {
        stride(from: 0, to: minutes * 60, by: 5).enumerated().map { i, off in
            (ts: start + off, bpm: bpms[i % bpms.count])
        }
    }

    /// A motion point every second with a constant intensity.
    private func motion(from start: Int, minutes: Int, intensity: Double) -> [AutoWorkoutDetector.MotionPoint] {
        (0..<(minutes * 60)).map { AutoWorkoutDetector.MotionPoint(ts: start + $0, intensity: intensity) }
    }

    func testHRMaxFallbacks() {
        XCTAssertEqual(AutoWorkoutGate.hrMax(profileHRMax: 183, age: 40), 183)
        XCTAssertEqual(AutoWorkoutGate.hrMax(profileHRMax: nil, age: 40), 180)
        XCTAssertEqual(AutoWorkoutGate.hrMax(profileHRMax: 0, age: nil), 190)
    }

    func testRequiredAverageUsesHeartRateReserve() {
        // rest 55, HRmax 190 → reserve 135; 40 % → 109, 50 % → 122.5
        XCTAssertEqual(AutoWorkoutGate.requiredAvgBpm(restingBpm: 55, hrMax: 190, reserveFraction: 0.4), 109, accuracy: 0.001)
        XCTAssertEqual(AutoWorkoutGate.requiredAvgBpm(restingBpm: 55, hrMax: 190, reserveFraction: 0.5), 122.5, accuracy: 0.001)
    }

    /// The reported morning: woke at 06:50, then 34 minutes of moving around the house at 91-100 bpm.
    /// The raw detector flags it (floor = 55 + 30 = 85); the gate must not.
    func testGettingUpAfterSleepIsNotAWorkout() {
        let sleep = AutoWorkoutGate.SleepSpan(startSec: wake - 8 * 3600, endSec: wake)
        let start = wake + 5 * 60   // 06:55
        let samples = hr(from: start, minutes: 34, bpms: [91, 95, 97, 100, 98, 96])
        let moves = motion(from: start, minutes: 34, intensity: 0.08)

        let raw = AutoWorkoutDetector.detect(hr: samples, restingBpm: 55, motion: moves)
        XCTAssertEqual(raw.count, 1, "the raw detector sees this morning as a candidate")
        XCTAssertGreaterThanOrEqual(raw[0].durationMin, 30)

        let gated = AutoWorkoutGate.detect(hr: samples, restingBpm: 55, hrMax: 190,
                                           motion: moves, sleeps: [sleep])
        XCTAssertTrue(gated.isEmpty)
        // Not even without the sleep context: 97 bpm is far below 40 % of reserve.
        XCTAssertTrue(AutoWorkoutGate.detect(hr: samples, restingBpm: 55, hrMax: 190,
                                             motion: moves, sleeps: []).isEmpty)
    }

    func testRealRunPasses() {
        let start = wake + 4 * 3600
        let samples = hr(from: start, minutes: 40, bpms: [138, 145, 152, 158, 150, 147])
        let moves = motion(from: start, minutes: 40, intensity: 0.3)
        let gated = AutoWorkoutGate.detect(hr: samples, restingBpm: 55, hrMax: 190,
                                           motion: moves, sleeps: [AutoWorkoutGate.SleepSpan(startSec: wake - 8 * 3600, endSec: wake)])
        XCTAssertEqual(gated.count, 1)
        XCTAssertGreaterThanOrEqual(gated[0].avgBpm, 140)
    }

    func testModerateRideRightAfterWakingNeedsTheStricterShare() {
        // avg ~115: above 40 % (109) but below the post-sleep 50 % (122.5).
        let sleep = AutoWorkoutGate.SleepSpan(startSec: wake - 8 * 3600, endSec: wake)
        let w = DetectedWorkout(startSec: wake + 20 * 60, endSec: wake + 50 * 60, avgBpm: 115, peakBpm: 130, durationMin: 30)
        XCTAssertFalse(AutoWorkoutGate.passes(w, restingBpm: 55, hrMax: 190, sleeps: [sleep], motionConfirmed: true))
        let later = DetectedWorkout(startSec: wake + 3 * 3600, endSec: wake + 3 * 3600 + 1800, avgBpm: 115, peakBpm: 130, durationMin: 30)
        XCTAssertTrue(AutoWorkoutGate.passes(later, restingBpm: 55, hrMax: 190, sleeps: [sleep], motionConfirmed: true))
        // A hard session right after waking still counts.
        let hard = DetectedWorkout(startSec: wake + 20 * 60, endSec: wake + 60 * 60, avgBpm: 150, peakBpm: 172, durationMin: 40)
        XCTAssertTrue(AutoWorkoutGate.passes(hard, restingBpm: 55, hrMax: 190, sleeps: [sleep], motionConfirmed: true))
    }

    func testNapCountsAsSleepToo() {
        let nap = AutoWorkoutGate.SleepSpan(startSec: wake + 6 * 3600, endSec: wake + 6 * 3600 + 1800)
        XCTAssertTrue(AutoWorkoutGate.isNearSleep(startSec: nap.endSec + 59 * 60, endSec: nap.endSec + 90 * 60, sleeps: [nap]))
        XCTAssertFalse(AutoWorkoutGate.isNearSleep(startSec: nap.endSec + 60 * 60, endSec: nap.endSec + 90 * 60, sleeps: [nap]))
    }

    func testNoMotionMeansNoSuggestion() {
        let start = wake + 4 * 3600
        let samples = hr(from: start, minutes: 40, bpms: [150])
        XCTAssertTrue(AutoWorkoutGate.detect(hr: samples, restingBpm: 55, hrMax: 190, motion: nil, sleeps: []).isEmpty)
        XCTAssertTrue(AutoWorkoutGate.detect(hr: samples, restingBpm: 55, hrMax: 190, motion: [], sleeps: []).isEmpty)
        let w = DetectedWorkout(startSec: start, endSec: start + 2400, avgBpm: 150, peakBpm: 160, durationMin: 40)
        XCTAssertFalse(AutoWorkoutGate.passes(w, restingBpm: 55, hrMax: 190, sleeps: [], motionConfirmed: false))
    }

    func testStillWristWithHighHeartRateIsNotAWorkout() {
        let start = wake + 4 * 3600
        let samples = hr(from: start, minutes: 40, bpms: [150])
        let still = motion(from: start, minutes: 40, intensity: 0.01)
        XCTAssertTrue(AutoWorkoutGate.detect(hr: samples, restingBpm: 55, hrMax: 190, motion: still, sleeps: []).isEmpty)
    }

    func testShortBoutIsDropped() {
        let w = DetectedWorkout(startSec: wake + 4 * 3600, endSec: wake + 4 * 3600 + 13 * 60, avgBpm: 160, peakBpm: 170, durationMin: 13)
        XCTAssertFalse(AutoWorkoutGate.passes(w, restingBpm: 55, hrMax: 190, sleeps: [], motionConfirmed: true))
    }
}
