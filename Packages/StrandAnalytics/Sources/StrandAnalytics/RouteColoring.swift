import Foundation

// MARK: - Route colouring (coloured route maps)
//
// Splits a route into runs of consecutive segments that share one colour bucket, so the map draws a
// handful of polylines instead of one per segment. A continuous metric (speed, altitude) is scaled to this
// workout's own 5th-95th percentile, so one sprint or one GPS spike cannot flatten every other colour;
// values outside the range clamp to the end buckets. A discrete metric (heart-rate zone) maps straight to
// its bucket. A segment with no value (paused, stopped, no reading) gets `RouteColoring.noValue`.

public enum RouteColoring {

    /// The bucket of a segment without a value; the map draws it in a neutral colour.
    public static let noValue = -1

    /// One run of segments sharing a bucket: points `first...last` (at least two) of the track.
    public struct Run: Equatable, Sendable {
        public let bucket: Int
        public let first: Int
        public let last: Int
        public init(bucket: Int, first: Int, last: Int) {
            self.bucket = bucket; self.first = first; self.last = last
        }
    }

    /// The `low`-`high` percentile range of the finite values (linear interpolation), or nil without any.
    public static func percentileRange(_ values: [Double], low: Double = 0.05, high: Double = 0.95)
        -> ClosedRange<Double>? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        func at(_ p: Double) -> Double {
            let pos = min(max(p, 0), 1) * Double(sorted.count - 1)
            let i = Int(pos.rounded(.down))
            let f = pos - Double(i)
            return i + 1 < sorted.count ? sorted[i] + (sorted[i + 1] - sorted[i]) * f : sorted[i]
        }
        let lo = at(low), hi = at(high)
        return lo <= hi ? lo...hi : hi...lo
    }

    /// Position of `value` inside `range`, clamped to 0...1. A degenerate range (steady effort) is 0.5.
    public static func position(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 1e-9 else { return 0.5 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    /// Bucket 0..<`buckets` for `value` inside `range` (0 = low end).
    public static func bucket(_ value: Double, in range: ClosedRange<Double>, buckets: Int) -> Int {
        guard buckets > 1 else { return 0 }
        return min(buckets - 1, Int(position(value, in: range) * Double(buckets)))
    }

    /// Per-segment values from per-point values: segment i joins points i and i+1 and takes their mean, or
    /// the one that exists; nil when neither does.
    public static func segmentValues(_ points: [Double?]) -> [Double?] {
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).map { i in
            switch (points[i], points[i + 1]) {
            case let (a?, b?): return (a + b) / 2
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    /// Runs over a continuous metric scaled to the workout's own percentile range.
    public static func runs(points: [Double?], range: ClosedRange<Double>?, buckets: Int) -> [Run] {
        let segments = segmentValues(points)
        let codes = segments.map { v -> Int in
            guard let v, v.isFinite, let range else { return noValue }
            return bucket(v, in: range, buckets: buckets)
        }
        return merge(codes)
    }

    /// Runs over a discrete metric: `bucketFor` returns the bucket for a point value, or nil for none.
    public static func discreteRuns(points: [Double?], bucketFor: (Double) -> Int?) -> [Run] {
        let codes = segmentValues(points).map { v in v.flatMap(bucketFor) ?? noValue }
        return merge(codes)
    }

    /// Merges consecutive equal segment codes into runs. Segment i spans points i...i+1.
    static func merge(_ codes: [Int]) -> [Run] {
        var out: [Run] = []
        var start = 0
        for i in codes.indices where i == codes.count - 1 || codes[i + 1] != codes[i] {
            out.append(Run(bucket: codes[i], first: start, last: i + 1))
            start = i + 1
        }
        return out
    }
}

// MARK: - Douglas-Peucker simplification

public enum RouteSimplify {

    /// Indices (ascending, always including the first and last) of the points that keep the line within
    /// `toleranceMeters` of the original. Iterative, so a long route cannot overflow the stack.
    public static func douglasPeucker(lat: [Double], lon: [Double], toleranceMeters: Double) -> [Int] {
        let n = min(lat.count, lon.count)
        guard n > 2 else { return Array(0..<n) }
        // Local equirectangular projection in metres around the mean latitude.
        let meanLat = lat.prefix(n).reduce(0, +) / Double(n) * .pi / 180
        let mPerDeg = 111_320.0
        let xs = (0..<n).map { lon[$0] * mPerDeg * cos(meanLat) }
        let ys = (0..<n).map { lat[$0] * mPerDeg }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true; keep[n - 1] = true
        var stack: [(Int, Int)] = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var maxD = -1.0, maxI = a
            for i in (a + 1)..<b {
                let d = distanceToSegment(xs[i], ys[i], xs[a], ys[a], xs[b], ys[b])
                if d > maxD { maxD = d; maxI = i }
            }
            if maxD > toleranceMeters {
                keep[maxI] = true
                stack.append((a, maxI))
                stack.append((maxI, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    /// Douglas-Peucker with the tolerance doubled until at most `maxPoints` remain (never below 2).
    public static func capped(lat: [Double], lon: [Double], toleranceMeters: Double, maxPoints: Int) -> [Int] {
        var tolerance = max(toleranceMeters, 0.1)
        var kept = douglasPeucker(lat: lat, lon: lon, toleranceMeters: tolerance)
        while kept.count > max(2, maxPoints) && tolerance < 100_000 {
            tolerance *= 2
            kept = douglasPeucker(lat: lat, lon: lon, toleranceMeters: tolerance)
        }
        return kept
    }

    static func distanceToSegment(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double,
                                  _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(px - ax, py - ay) }
        let t = min(1, max(0, ((px - ax) * dx + (py - ay) * dy) / len2))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }
}
