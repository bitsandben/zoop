import XCTest
@testable import StrandAnalytics

/// Coloured route maps: track cleaning and smoothing (`RouteTrack`), colour buckets (`RouteColoring`),
/// simplification (`RouteSimplify`) and the split table (`RouteSplitTable`).
final class RouteTrackTests: XCTestCase {

    private typealias Fix = RouteTrack.Fix
    /// Metres per degree of latitude used to lay a straight north-bound synthetic route.
    private let mPerDegLat = 6_371_000.0 * .pi / 180

    /// A straight north-bound route: one fix every `step` seconds, each stretch at its own speed (m/s).
    private func route(_ stretches: [(seconds: Double, speed: Double)], step: Double = 2,
                       altitude: ((Double) -> Double)? = nil) -> [Fix] {
        var fixes: [Fix] = [Fix(lat: 0, lon: 0, t: 0, altitude: altitude?(0))]
        var t = 0.0, m = 0.0
        for s in stretches {
            for _ in 0..<Int(s.seconds / step) {
                t += step; m += s.speed * step
                fixes.append(Fix(lat: m / mPerDegLat, lon: 0, t: t, altitude: altitude?(m)))
            }
        }
        return fixes
    }

    // MARK: Track

    func testSteadyRunRecoversItsSpeed() {
        let track = RouteTrack.build(route([(600, 3.0)]))
        XCTAssertEqual(track.totalMeters, 1800, accuracy: 1)
        for v in track.speed.compactMap({ $0 }) { XCTAssertEqual(v, 3.0, accuracy: 0.01) }
        XCTAssertEqual(track.movingSeconds.last!, 600, accuracy: 1e-6)
    }

    func testSpikeIsRemoved() {
        var fixes = route([(120, 3.0)])
        // A teleport 2 km east between two good fixes.
        let mid = fixes[30]
        fixes.insert(Fix(lat: mid.lat, lon: 0.018, t: mid.t + 0.5), at: 31)
        let cleaned = RouteTrack.removeSpikes(fixes, maxSpeedMps: 12)
        XCTAssertEqual(cleaned.count, fixes.count - 1)
        XCTAssertFalse(cleaned.contains { $0.lon != 0 })
        let track = RouteTrack.build(fixes)
        XCTAssertEqual(track.totalMeters, 360, accuracy: 1)
    }

    func testPauseGapIsNotAPaceAndNotMovingTime() {
        var fixes = route([(300, 3.0)])
        let last = fixes.last!
        // Resume two minutes later, 5 m further on, then keep running.
        fixes += route([(300, 3.0)]).dropFirst().map {
            Fix(lat: last.lat + $0.lat + 5 / mPerDegLat, lon: 0, t: last.t + 120 + $0.t)
        }
        let track = RouteTrack.build(fixes)
        XCTAssertEqual(track.movingSeconds.last!, 600, accuracy: 3)
        for v in track.speed.compactMap({ $0 }) { XCTAssertEqual(v, 3.0, accuracy: 0.05) }
    }

    func testStandingStillIsNil() {
        let fixes = route([(120, 3.0), (60, 0.1), (120, 3.0)])
        let track = RouteTrack.build(fixes)
        let mid = track.index(atMeters: 361)
        XCTAssertNil(track.speed[mid + 10])   // the middle of the stop
    }

    func testHeartRateMatchedByTimestamp() {
        let fixes = route([(100, 3.0)], step: 10)
        let hr = [RouteTrack.HeartRate(t: 0, bpm: 100), RouteTrack.HeartRate(t: 100, bpm: 150)]
        let track = RouteTrack.build(fixes, heartRate: hr)
        XCTAssertEqual(track.heartRate[0]!, 100, accuracy: 1e-9)
        XCTAssertEqual(track.heartRate[5]!, 125, accuracy: 1e-9)
        XCTAssertEqual(track.heartRate.last!!, 150, accuracy: 1e-9)
        // Nothing within tolerance: nil.
        let far = RouteTrack.build(fixes, heartRate: [RouteTrack.HeartRate(t: 10_000, bpm: 120)])
        XCTAssertFalse(far.hasHeartRate)
    }

    func testCoordinateAtMetersInterpolates() {
        let track = RouteTrack.build(route([(100, 5.0)], step: 10))
        let c = track.coordinate(atMeters: 125)!
        XCTAssertEqual(c.lat * mPerDegLat, 125, accuracy: 0.5)
    }

    // MARK: Colouring

    func testFastAndSlowSectionsLandInOppositeBuckets() {
        // 5 min slow, 5 min fast, 5 min slow.
        let track = RouteTrack.build(route([(300, 2.5), (300, 4.5), (300, 2.5)]))
        let range = RouteColoring.percentileRange(track.speed.compactMap { $0 })!
        let runs = RouteColoring.runs(points: track.speed, range: range, buckets: 10)
        func bucket(atMeters m: Double) -> Int {
            let i = track.index(atMeters: m)
            return runs.first { $0.first <= i && i < $0.last }!.bucket
        }
        XCTAssertEqual(bucket(atMeters: 300), 0)      // middle of the first slow stretch
        XCTAssertEqual(bucket(atMeters: 750 + 675), 9) // middle of the fast stretch
        XCTAssertEqual(bucket(atMeters: 2100 + 375), 0)
        // Runs are contiguous and cover every segment.
        XCTAssertEqual(runs.first!.first, 0)
        XCTAssertEqual(runs.last!.last, track.count - 1)
        for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertEqual(a.last, b.first) }
    }

    func testPercentileRangeIgnoresOutliers() {
        let values = Array(repeating: 3.0, count: 50) + Array(repeating: 4.0, count: 48) + [40, 0.01]
        let range = RouteColoring.percentileRange(values)!
        XCTAssertGreaterThanOrEqual(range.lowerBound, 3.0)
        XCTAssertLessThanOrEqual(range.upperBound, 4.0)
        XCTAssertEqual(RouteColoring.bucket(40, in: range, buckets: 8), 7)
        XCTAssertEqual(RouteColoring.bucket(0.01, in: range, buckets: 8), 0)
    }

    func testSteadyEffortIsMidBucket() {
        XCTAssertEqual(RouteColoring.bucket(3, in: 3...3, buckets: 10), 5)
    }

    func testNilSegmentsGetNoValue() {
        let runs = RouteColoring.runs(points: [3, 3, nil, nil, nil, 3], range: 2...4, buckets: 4)
        XCTAssertEqual(runs.map(\.bucket), [2, RouteColoring.noValue, 2])
        XCTAssertEqual(runs.map(\.first), [0, 2, 4])
    }

    func testDiscreteZoneRuns() {
        let runs = RouteColoring.discreteRuns(points: [110, 112, 150, 152, 170]) { bpm in
            bpm < 120 ? 0 : bpm < 160 ? 1 : 2
        }
        XCTAssertEqual(runs.map(\.bucket), [0, 1, 2])
    }

    // MARK: Simplification

    func testDouglasPeuckerKeepsCornersAndDropsCollinear() {
        // An L: 100 points north, then 100 points east.
        var lat: [Double] = [], lon: [Double] = []
        for i in 0...100 { lat.append(Double(i) / mPerDegLat); lon.append(0) }
        for i in 1...100 { lat.append(100 / mPerDegLat); lon.append(Double(i) / mPerDegLat) }
        let kept = RouteSimplify.douglasPeucker(lat: lat, lon: lon, toleranceMeters: 1)
        XCTAssertEqual(kept, [0, 100, 200])
    }

    func testSimplificationStaysWithinTolerance() {
        // A noisy zig-zag: every kept-line deviation must be within the tolerance.
        var lat: [Double] = [], lon: [Double] = []
        for i in 0..<2000 {
            lat.append(Double(i) * 2 / mPerDegLat)
            lon.append(sin(Double(i) / 15) * 30 / mPerDegLat)
        }
        let tol = 5.0
        let kept = RouteSimplify.douglasPeucker(lat: lat, lon: lon, toleranceMeters: tol)
        XCTAssertLessThan(kept.count, 400)
        XCTAssertEqual(kept.first, 0)
        XCTAssertEqual(kept.last, 1999)
        for (a, b) in zip(kept, kept.dropFirst()) {
            for i in a...b {
                let d = RouteSimplify.distanceToSegment(lon[i] * mPerDegLat, lat[i] * mPerDegLat,
                                                        lon[a] * mPerDegLat, lat[a] * mPerDegLat,
                                                        lon[b] * mPerDegLat, lat[b] * mPerDegLat)
                XCTAssertLessThanOrEqual(d, tol + 0.5)
            }
        }
        let capped = RouteSimplify.capped(lat: lat, lon: lon, toleranceMeters: 1, maxPoints: 50)
        XCTAssertLessThanOrEqual(capped.count, 50)
        XCTAssertGreaterThanOrEqual(capped.count, 2)
    }

    // MARK: Splits

    func testSplitRowsWithPartialAndClimb() {
        // 2.5 km at 4 m/s (250 s/km), climbing 10 m per km.
        let track = RouteTrack.build(route([(626, 4.0)], altitude: { $0 / 100 }),
                                     heartRate: [.init(t: 0, bpm: 140), .init(t: 626, bpm: 140)])
        let rows = RouteSplitTable.rows(track, splitMeters: 1000)
        XCTAssertEqual(rows.map(\.index), [1, 2, 3])
        XCTAssertEqual(rows[0].seconds, 250, accuracy: 0.5)
        XCTAssertEqual(rows[0].pace(unitMeters: 1000)!, 250, accuracy: 0.5)
        XCTAssertEqual(rows[2].meters, 504, accuracy: 2)
        XCTAssertEqual(rows[2].pace(unitMeters: 1000)!, 250, accuracy: 1)
        XCTAssertEqual(rows[0].averageHeartRate!, 140, accuracy: 1e-6)
        XCTAssertEqual(rows[0].elevationGain!, 10, accuracy: 1.5)
        XCTAssertEqual(RouteSplitTable.markerDistances(totalMeters: track.totalMeters, splitMeters: 1000),
                       [1000, 2000])
    }
}
