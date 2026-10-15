import XCTest
@testable import StrandAnalytics

final class SleepRestlessnessTests: XCTestCase {

    /// A night of `epochs` quiet epochs (count 1.0) with movement of `size` at the given indices.
    private func night(_ epochs: Int = 960, moves: [Int] = [], size: Double = 20) -> [Double] {
        var counts = [Double](repeating: 1, count: epochs)
        for i in moves where i < epochs { counts[i] = size }
        return counts
    }

    func testStillNightHasNoBoutsAndOneLongStretch() throws {
        let r = try XCTUnwrap(SleepRestlessness.analyze(epochCounts: night()))
        XCTAssertEqual(r.bouts, 0)
        XCTAssertEqual(r.restlessMinutes, 0)
        XCTAssertEqual(r.longestStillMinutes, 480)
        XCTAssertEqual(r.confidence, .solid)
    }

    func testCountsBoutsAndMergesShortPauses() throws {
        // 100,101 one bout; 103 continues it (one still epoch between); 300 and 600 separate bouts.
        let r = try XCTUnwrap(SleepRestlessness.analyze(epochCounts: night(moves: [100, 101, 103, 300, 600])))
        XCTAssertEqual(r.bouts, 3)
        XCTAssertEqual(r.restlessMinutes, 2.5)
        // Longest still run: epochs 601...959 = 359 epochs.
        XCTAssertEqual(r.longestStillMinutes, 179.5)
    }

    func testRecoversMultipleRestlessnessLevels() throws {
        // More injected movement must read as more bouts, one for one (not a single tuned match).
        var previous = -1
        for n in [0, 3, 8, 15] {
            let moves = (0..<n).map { 40 + $0 * 60 }
            let r = try XCTUnwrap(SleepRestlessness.analyze(epochCounts: night(moves: moves)))
            XCTAssertEqual(r.bouts, n)
            XCTAssertGreaterThan(r.bouts, previous)
            previous = r.bouts
        }
    }

    func testThresholdIsRelativeToTheNightsFloor() throws {
        // The same shape at ten times the scale (a denser strap) reads the same.
        let base = night(moves: [200, 500])
        let a = try XCTUnwrap(SleepRestlessness.analyze(epochCounts: base))
        let b = try XCTUnwrap(SleepRestlessness.analyze(epochCounts: base.map { $0 * 10 }))
        XCTAssertEqual(a, b)
    }

    func testShortNightOrNoMotionIsNil() {
        XCTAssertNil(SleepRestlessness.analyze(epochCounts: night(200)))
        XCTAssertNil(SleepRestlessness.analyze(epochCounts: [Double](repeating: 0, count: 900)))
    }

    func testSparseOrLowCoverageIsLowConfidence() throws {
        XCTAssertEqual(try XCTUnwrap(SleepRestlessness.analyze(epochCounts: night(), sparse: true)).confidence, .low)
        var gappy = night()
        for i in 0..<500 { gappy[i] = 0 }
        let r = try XCTUnwrap(SleepRestlessness.analyze(epochCounts: gappy))
        XCTAssertEqual(r.confidence, .low)
        XCTAssertLessThan(r.coverage, SleepRestlessness.solidCoverage)
    }

    func testTypicalRangeNeedsSevenNights() throws {
        XCTAssertNil(SleepRestlessness.typicalRange([5, 6, 7, 8, 9, 10]))
        let range = try XCTUnwrap(SleepRestlessness.typicalRange([4, 6, 4, 6, 4, 6, 5]))
        XCTAssertEqual((range.lowerBound + range.upperBound) / 2, 5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(SleepRestlessness.typicalRange([0, 0, 0, 0, 0, 0, 3])).lowerBound, 0)
    }
}
