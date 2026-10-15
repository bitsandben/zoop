import XCTest
@testable import StrandAnalytics

/// Live workout distance, pace and split math (`WorkoutSplits`) and the weekly-load sentence.
final class WorkoutSplitsTests: XCTestCase {

    private typealias S = WorkoutSplits.Sample

    /// A steady run: `pace` seconds per km, one sample every `step` seconds, for `seconds`.
    private func steady(pace: Double, seconds: Double, step: Double = 5, offset: (s: Double, m: Double) = (0, 0)) -> [S] {
        stride(from: 0.0, through: seconds, by: step).map { t in
            S(seconds: offset.s + t, meters: offset.m + t / pace * 1000)
        }
    }

    // MARK: Splits

    func testSteadyRunSplitsAtExactPace() {
        let samples = steady(pace: 300, seconds: 1000)   // 3.33 km at 5:00/km
        let splits = WorkoutSplits.splits(samples)
        XCTAssertEqual(splits.map(\.index), [1, 2, 3])
        for s in splits { XCTAssertEqual(s.seconds, 300, accuracy: 1e-6) }
        XCTAssertEqual(splits.last!.endSeconds, 900, accuracy: 1e-6)
    }

    func testSplitInterpolatesBetweenSparseFixes() {
        // Two fixes straddle 1 km: 900 m at 270 s, 1100 m at 330 s -> boundary at 300 s.
        let samples = [S(seconds: 0, meters: 0), S(seconds: 270, meters: 900), S(seconds: 330, meters: 1100)]
        let splits = WorkoutSplits.splits(samples)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].seconds, 300, accuracy: 1e-9)
    }

    func testOneLongJumpCrossesSeveralBoundaries() {
        let samples = [S(seconds: 0, meters: 0), S(seconds: 1000, meters: 2500)]
        let splits = WorkoutSplits.splits(samples)
        XCTAssertEqual(splits.map(\.index), [1, 2])
        XCTAssertEqual(splits[0].seconds, 400, accuracy: 1e-9)
        XCTAssertEqual(splits[1].seconds, 400, accuracy: 1e-9)
    }

    func testVaryingPaceIsTrackedPerSplit() {
        // 1 km at 6:00, then 1 km at 4:30: each split recovers its own pace, not the average.
        let first = steady(pace: 360, seconds: 360)
        let second = steady(pace: 270, seconds: 270, offset: (360, 1000)).dropFirst()
        let splits = WorkoutSplits.splits(first + second)
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].seconds, 360, accuracy: 1e-6)
        XCTAssertEqual(splits[1].seconds, 270, accuracy: 1e-6)
    }

    func testMileSplits() {
        let samples = steady(pace: 300, seconds: 1100)   // ~3.67 km
        let splits = WorkoutSplits.splits(samples, splitMeters: WorkoutSplits.mile)
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].seconds, 300 * 1.609344, accuracy: 1e-6)
    }

    func testBackwardsAndNonFiniteSamplesAreSkipped() {
        let samples = [S(seconds: 0, meters: 0), S(seconds: 100, meters: 500), S(seconds: 90, meters: 400),
                       S(seconds: .nan, meters: 700), S(seconds: 200, meters: 1000)]
        let splits = WorkoutSplits.splits(samples)
        XCTAssertEqual(splits.count, 1)
        XCTAssertEqual(splits[0].seconds, 200, accuracy: 1e-9)
        XCTAssertEqual(WorkoutSplits.splits([], splitMeters: 1000), [])
        XCTAssertEqual(WorkoutSplits.splits(samples, splitMeters: 0), [])
    }

    func testCurrentSplitProgress() {
        let samples = steady(pace: 300, seconds: 450)   // 1.5 km
        let current = WorkoutSplits.currentSplit(samples)!
        XCTAssertEqual(current.meters, 500, accuracy: 1e-6)
        XCTAssertEqual(current.seconds, 150, accuracy: 1e-6)
        XCTAssertNil(WorkoutSplits.currentSplit([]))
    }

    // MARK: Pace

    func testAveragePace() {
        XCTAssertEqual(WorkoutSplits.averagePace(meters: 5000, seconds: 1500)!, 300, accuracy: 1e-9)
        XCTAssertEqual(WorkoutSplits.averagePace(meters: 1609.344, seconds: 480, unitMeters: WorkoutSplits.mile)!,
                       480, accuracy: 1e-9)
        XCTAssertNil(WorkoutSplits.averagePace(meters: 5, seconds: 10))
        XCTAssertNil(WorkoutSplits.averagePace(meters: 500, seconds: 0))
    }

    func testCurrentPaceFollowsTheRecentStretch() {
        // 5:00/km for 10 minutes, then 4:00/km for 2 minutes: current pace reads the new pace.
        let slow = steady(pace: 300, seconds: 600)
        let fast = steady(pace: 240, seconds: 120, offset: (600, 2000)).dropFirst()
        let all = slow + fast
        XCTAssertEqual(WorkoutSplits.currentPace(all, now: 720)!, 240, accuracy: 1e-6)
        XCTAssertEqual(WorkoutSplits.currentPace(Array(slow), now: 600)!, 300, accuracy: 1e-6)
    }

    func testCurrentPaceGoesNilWhenStandingStill() {
        let samples = steady(pace: 300, seconds: 120)
        XCTAssertNotNil(WorkoutSplits.currentPace(samples, now: 125))
        XCTAssertNil(WorkoutSplits.currentPace(samples, now: 140))
        XCTAssertNil(WorkoutSplits.currentPace([S(seconds: 0, meters: 0)], now: 1))
    }

    // MARK: Elevation and clock

    func testElevationGainIgnoresJitter() {
        XCTAssertEqual(WorkoutSplits.elevationGain([100, 101, 99, 101, 100, 101]), 0, accuracy: 1e-9)
        XCTAssertEqual(WorkoutSplits.elevationGain([100, 105, 103, 110, 90, 95]), 17, accuracy: 1e-9)
        XCTAssertEqual(WorkoutSplits.elevationGain([]), 0)
    }

    func testClock() {
        XCTAssertEqual(WorkoutSplits.clock(307), "5:07")
        XCTAssertEqual(WorkoutSplits.clock(59.6), "1:00")
        XCTAssertEqual(WorkoutSplits.clock(3729), "1:02:09")
        XCTAssertNil(WorkoutSplits.clock(-1))
        XCTAssertNil(WorkoutSplits.clock(.infinity))
    }

    // MARK: Weekly load sentence

    func testComparisonMatchesTheGaugeReading() {
        let more = TrainingLoadGauge.reading(acute: 12.3, chronic: 10, historyDays: 30)
        XCTAssertEqual(TrainingLoadGauge.comparison(more), .more(percent: 23))
        let less = TrainingLoadGauge.reading(acute: 6, chronic: 10, historyDays: 30)
        XCTAssertEqual(TrainingLoadGauge.comparison(less), .less(percent: 40))
        let same = TrainingLoadGauge.reading(acute: 10.3, chronic: 10, historyDays: 30)
        XCTAssertEqual(TrainingLoadGauge.comparison(same), .same)
        XCTAssertNil(TrainingLoadGauge.comparison(TrainingLoadGauge.reading(acute: 10, chronic: 10, historyDays: 5)))
        XCTAssertNil(TrainingLoadGauge.comparison(TrainingLoadGauge.reading(acute: 3, chronic: 0, historyDays: 30)))
    }

    func testTrackFractionClamps() {
        let r = TrainingLoadGauge.reading(acute: 10, chronic: 10, historyDays: 30)
        XCTAssertEqual(TrainingLoadGauge.trackFraction(r.scaleMax / 2, of: r), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TrainingLoadGauge.trackFraction(r.scaleMax * 3, of: r), 1)
        XCTAssertEqual(TrainingLoadGauge.trackFraction(-1, of: r), 0)
    }
}
