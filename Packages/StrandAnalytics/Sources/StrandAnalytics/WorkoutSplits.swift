import Foundation

// MARK: - Workout splits and pace (live GPS workouts)
//
// Pure math behind the live workout screen's distance, pace and split readouts. The app feeds it a
// growing series of samples (active seconds since start, cumulative metres), one per accepted GPS fix;
// nothing here knows about CoreLocation, units on screen or the clock.
//   - Splits interpolate the moment the route crossed each whole split distance (1 km or 1 mile), so a
//     split's time does not depend on where the fixes happened to land.
//   - Current pace is the pace over the last `window` seconds (at least `minMeters` of route), and goes
//     nil once the newest fix is older than `staleAfter`: standing still is not a pace.
//   - Elevation gain sums climbs past a hysteresis threshold so GPS altitude noise does not add up.

public enum WorkoutSplits {

    public static let kilometer = 1000.0
    public static let mile = 1609.344

    /// One point of the route: active (pause-free) seconds since the start, and metres covered so far.
    public struct Sample: Equatable, Sendable {
        public let seconds: Double
        public let meters: Double
        public init(seconds: Double, meters: Double) {
            self.seconds = seconds
            self.meters = meters
        }
    }

    /// One completed split. `seconds` is the time the split took, which is also its pace per split unit.
    public struct Split: Equatable, Sendable, Identifiable {
        /// 1-based split number.
        public let index: Int
        public let seconds: Double
        /// Active seconds at which the split was completed.
        public let endSeconds: Double
        public var id: Int { index }
        public init(index: Int, seconds: Double, endSeconds: Double) {
            self.index = index
            self.seconds = seconds
            self.endSeconds = endSeconds
        }
    }

    /// Completed splits of `splitMeters` each, interpolated between the samples either side of each boundary.
    /// Samples must be in time order; non-finite or backwards samples are skipped.
    public static func splits(_ samples: [Sample], splitMeters: Double = kilometer) -> [Split] {
        guard splitMeters > 0 else { return [] }
        var out: [Split] = []
        var previous: Sample?
        var nextBoundary = splitMeters
        var lastEnd = 0.0
        for s in samples where s.seconds.isFinite && s.meters.isFinite {
            guard let p = previous else {
                // The first sample anchors the walk.
                previous = s
                continue
            }
            // A backwards sample is corrupt input: skip it and keep the last good anchor.
            guard s.meters >= p.meters, s.seconds >= p.seconds else { continue }
            previous = s
            while s.meters >= nextBoundary {
                let span = s.meters - p.meters
                let f = span > 0 ? (nextBoundary - p.meters) / span : 1
                let t = p.seconds + f * (s.seconds - p.seconds)
                out.append(Split(index: out.count + 1, seconds: t - lastEnd, endSeconds: t))
                lastEnd = t
                nextBoundary += splitMeters
            }
        }
        return out
    }

    /// The split in progress: metres and seconds since the last completed boundary. Nil without samples.
    public static func currentSplit(_ samples: [Sample], splitMeters: Double = kilometer)
        -> (meters: Double, seconds: Double)? {
        guard let last = samples.last, splitMeters > 0 else { return nil }
        let done = splits(samples, splitMeters: splitMeters)
        let startSeconds = done.last?.endSeconds ?? 0
        let startMeters = Double(done.count) * splitMeters
        return (max(0, last.meters - startMeters), max(0, last.seconds - startSeconds))
    }

    /// Average pace in seconds per `unitMeters`; nil until there is enough distance to mean anything.
    public static func averagePace(meters: Double, seconds: Double, unitMeters: Double = kilometer,
                                   minMeters: Double = 10) -> Double? {
        guard meters.isFinite, seconds.isFinite, meters >= minMeters, seconds > 0, unitMeters > 0 else { return nil }
        return seconds / (meters / unitMeters)
    }

    /// Pace over the recent stretch, seconds per `unitMeters`. Uses the last `window` seconds, reaching back
    /// further until at least `minMeters` are covered. Nil when the newest sample is older than `staleAfter`
    /// at `now` (standing still), or when the stretch is too short.
    public static func currentPace(_ samples: [Sample], now: Double, unitMeters: Double = kilometer,
                                   window: Double = 30, minMeters: Double = 25,
                                   staleAfter: Double = 15) -> Double? {
        guard let last = samples.last, unitMeters > 0, now - last.seconds <= staleAfter else { return nil }
        var first = last
        for s in samples.reversed() {
            first = s
            if last.seconds - s.seconds >= window && last.meters - s.meters >= minMeters { break }
        }
        let dm = last.meters - first.meters
        let dt = last.seconds - first.seconds
        guard dm >= minMeters, dt > 0 else { return nil }
        return dt / (dm / unitMeters)
    }

    /// Total climb in metres: a rise counts once it exceeds `threshold` above the lowest point since the
    /// last counted climb, so altitude jitter of a few metres adds nothing.
    public static func elevationGain(_ altitudes: [Double], threshold: Double = 3) -> Double {
        var gain = 0.0
        var anchor: Double?
        for a in altitudes where a.isFinite {
            guard let base = anchor else { anchor = a; continue }
            if a < base {
                anchor = a
            } else if a - base >= threshold {
                gain += a - base
                anchor = a
            }
        }
        return gain
    }

    /// A pace or duration as a clock: "5:07", or "1:02:09" from an hour. Nil for non-finite or negative input.
    public static func clock(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(m):\(two(sec))"
    }
}
