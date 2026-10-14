import XCTest
@testable import StrandAnalytics

/// The Sleep screen's latency track, typical stage-share bands and overnight-curve gates.
final class SleepNightReadoutsTests: XCTestCase {

    // MARK: Latency

    func testLatencyIsTimeToFirstAsleepSegment() {
        let segs: [(start: Double, end: Double, asleep: Bool)] = [
            (0, 720, false), (720, 3600, true), (3600, 3700, false),
        ]
        XCTAssertEqual(SleepLatency.minutes(segments: segs), 12)
    }

    func testLatencyCountsAGapBeforeTheFirstSegment() {
        // An edited bedtime earlier than the first staged segment: the gap is time before sleep too.
        XCTAssertEqual(SleepLatency.minutes(segments: [(1200, 4000, true), (4000, 5000, true)]), 20)
    }

    func testLatencyZeroWhenNightOpensAsleep() {
        XCTAssertEqual(SleepLatency.minutes(segments: [(0, 600, true), (600, 900, false)]), 0)
    }

    func testLatencyNilWithoutSleep() {
        XCTAssertNil(SleepLatency.minutes(segments: []))
        XCTAssertNil(SleepLatency.minutes(segments: [(0, 600, false)]))
        // A zero-length asleep segment is not sleep.
        XCTAssertNil(SleepLatency.minutes(segments: [(0, 600, false), (600, 600, true)]))
    }

    func testLatencyIgnoresSegmentOrder() {
        let segs: [(start: Double, end: Double, asleep: Bool)] = [(900, 2000, true), (0, 300, false), (300, 900, false)]
        XCTAssertEqual(SleepLatency.minutes(segments: segs), 15)
    }

    func testLatencyBandEdges() {
        XCTAssertEqual(SleepLatency.band(minutes: 0), .fast)
        XCTAssertEqual(SleepLatency.band(minutes: 9.9), .fast)
        XCTAssertEqual(SleepLatency.band(minutes: 10), .normal)
        XCTAssertEqual(SleepLatency.band(minutes: 20), .normal)
        XCTAssertEqual(SleepLatency.band(minutes: 30), .normal)
        XCTAssertEqual(SleepLatency.band(minutes: 30.1), .late)
        XCTAssertEqual(SleepLatency.band(minutes: 90), .late)
    }

    func testLatencyTrackFraction() {
        XCTAssertEqual(SleepLatency.trackFraction(minutes: 0), 0)
        XCTAssertEqual(SleepLatency.trackFraction(minutes: 22.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SleepLatency.trackFraction(minutes: 120), 1)
        XCTAssertEqual(SleepLatency.trackFraction(minutes: -5), 0)
    }

    // MARK: Stage share bands

    func testStageShareBandsNeedFiveNights() {
        let n = StageShareBands.Night(lightMin: 240, deepMin: 90, remMin: 90, efficiency: 0.9)
        XCTAssertNil(StageShareBands.bands(Array(repeating: n, count: 4)).deep)
        XCTAssertNotNil(StageShareBands.bands(Array(repeating: n, count: 5)).deep)
    }

    func testStageShareBandsOverTimeInBed() {
        // 420 asleep at 84 % efficiency = 500 in bed: deep 84/500 = 0.168, awake 0.16.
        let n = StageShareBands.Night(lightMin: 252, deepMin: 84, remMin: 84, efficiency: 84)
        let b = StageShareBands.bands(Array(repeating: n, count: 6))
        XCTAssertEqual(b.deep?.lowerBound ?? 0, 0.168, accuracy: 1e-9)
        XCTAssertEqual(b.awake?.upperBound ?? 0, 0.16, accuracy: 1e-9)
        XCTAssertEqual(b.light?.lowerBound ?? 0, 0.504, accuracy: 1e-9)
        let sum = (b.awake?.lowerBound ?? 0) + (b.light?.lowerBound ?? 0)
            + (b.deep?.lowerBound ?? 0) + (b.rem?.lowerBound ?? 0)
        XCTAssertEqual(sum, 1, accuracy: 1e-9)
    }

    func testStageShareBandsInterquartile() {
        let deeps: [Double] = [40, 60, 80, 100, 120]
        let nights = deeps.map { StageShareBands.Night(lightMin: 300 - $0, deepMin: $0, remMin: 100, efficiency: 1) }
        let b = StageShareBands.bands(nights)
        // Shares 0.1 ... 0.3 in steps of 0.05: the 25th is 0.15, the 75th 0.25.
        XCTAssertEqual(b.deep?.lowerBound ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(b.deep?.upperBound ?? 0, 0.25, accuracy: 1e-9)
    }

    func testStageShareBandsSkipUnusableNights() {
        let good = StageShareBands.Night(lightMin: 240, deepMin: 90, remMin: 90, efficiency: 0.9)
        let noEff = StageShareBands.Night(lightMin: 240, deepMin: 90, remMin: 90, efficiency: nil)
        let lowEff = StageShareBands.Night(lightMin: 240, deepMin: 90, remMin: 90, efficiency: 0.2)
        let b = StageShareBands.bands(Array(repeating: good, count: 4) + [noEff, lowEff])
        XCTAssertNil(b.rem)
    }

    // MARK: Night signal

    func testPlottableDropsImplausibleValues() {
        let v: [Double] = [60, 58, 57, 300, 56, 55, 55, 54, 53, 52]
        XCTAssertEqual(NightSignal.plottable(v, metric: .heartRate), [0, 1, 2, 4, 5, 6, 7, 8, 9])
    }

    func testPlottableRejectsRawSensorStreams() {
        // A red/IR ratio is not a percentage, and a raw respiration ADC is not a rate.
        XCTAssertNil(NightSignal.plottable(Array(repeating: 0.98, count: 50), metric: .spo2))
        XCTAssertNil(NightSignal.plottable(Array(repeating: 31_250, count: 50), metric: .respiratoryRate))
        XCTAssertNotNil(NightSignal.plottable(Array(repeating: 96, count: 50), metric: .spo2))
        XCTAssertNotNil(NightSignal.plottable(Array(repeating: 14.5, count: 50), metric: .respiratoryRate))
    }

    func testPlottableNeedsEnoughPointsAndShare() {
        XCTAssertNil(NightSignal.plottable(Array(repeating: 60, count: 7), metric: .heartRate))
        XCTAssertNotNil(NightSignal.plottable(Array(repeating: 60, count: 8), metric: .heartRate))
        // 8 plausible of 11 = 73 %, under the 80 % share.
        XCTAssertNil(NightSignal.plottable(Array(repeating: 60, count: 8) + [0, 0, 0], metric: .heartRate))
        XCTAssertNil(NightSignal.plottable([], metric: .hrv))
    }

    func testSmoothedIsCenteredMovingAverage() {
        XCTAssertEqual(NightSignal.smoothed([0, 3, 6, 9, 12], window: 3), [1.5, 3, 6, 9, 10.5])
        XCTAssertEqual(NightSignal.smoothed([5, 7], window: 3), [5, 7])
        XCTAssertEqual(NightSignal.smoothed([1, 2, 3], window: 1), [1, 2, 3])
    }

    func testMean() {
        XCTAssertNil(NightSignal.mean([]))
        XCTAssertEqual(NightSignal.mean([60, 62, 64]), 62)
    }
}
