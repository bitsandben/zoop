import Foundation

// MARK: - Route split table (coloured route maps)
//
// Per-kilometre (or per-mile) rows for a finished route: moving time, average heart rate and climb, plus
// the trailing partial split. Split boundaries come from `WorkoutSplits.splits` over the track's moving
// time, so the finished table and the live screen's splits agree for the same fixes.

public enum RouteSplitTable {

    public struct Row: Equatable, Sendable, Identifiable {
        /// 1-based split number.
        public let index: Int
        /// Length in metres: the split distance, or less for the trailing partial split.
        public let meters: Double
        /// Moving seconds the split took.
        public let seconds: Double
        public let averageHeartRate: Double?
        /// Climb in metres; nil when the route carries no altitude.
        public let elevationGain: Double?
        public var id: Int { index }
        /// Seconds per `unitMeters` for this split; nil for a zero-length split.
        public func pace(unitMeters: Double) -> Double? {
            meters > 0 ? seconds / (meters / unitMeters) : nil
        }
        public init(index: Int, meters: Double, seconds: Double, averageHeartRate: Double?, elevationGain: Double?) {
            self.index = index; self.meters = meters; self.seconds = seconds
            self.averageHeartRate = averageHeartRate; self.elevationGain = elevationGain
        }
    }

    /// Rows of `splitMeters`, plus a trailing partial row when at least `minPartialMeters` remain.
    public static func rows(_ track: RouteTrack.Track, splitMeters: Double,
                            minPartialMeters: Double = 50) -> [Row] {
        guard track.count >= 2, splitMeters > 0 else { return [] }
        let samples = zip(track.movingSeconds, track.meters).map { WorkoutSplits.Sample(seconds: $0, meters: $1) }
        let splits = WorkoutSplits.splits(samples, splitMeters: splitMeters)
        var out: [Row] = []
        var startMeters = 0.0
        var startSeconds = 0.0
        for s in splits {
            let end = startMeters + splitMeters
            out.append(row(track, index: s.index, from: startMeters, to: end, seconds: s.seconds))
            startMeters = end
            startSeconds = s.endSeconds
        }
        let remaining = track.totalMeters - startMeters
        if remaining >= minPartialMeters {
            let seconds = max(0, (track.movingSeconds.last ?? 0) - startSeconds)
            out.append(row(track, index: out.count + 1, from: startMeters, to: track.totalMeters, seconds: seconds))
        }
        return out
    }

    private static func row(_ track: RouteTrack.Track, index: Int, from: Double, to: Double,
                            seconds: Double) -> Row {
        let lo = track.index(atMeters: from)
        let hi = min(track.count - 1, track.index(atMeters: to) + 1)
        let range = lo...max(lo, hi)
        let hr = range.compactMap { track.heartRate[$0] }
        let alt = range.compactMap { track.altitude[$0] }
        return Row(index: index, meters: to - from, seconds: seconds,
                   averageHeartRate: hr.isEmpty ? nil : hr.reduce(0, +) / Double(hr.count),
                   elevationGain: alt.count >= 2 ? WorkoutSplits.elevationGain(alt) : nil)
    }

    /// Distances (metres) of each whole split boundary along the route, for the map's split markers.
    public static func markerDistances(totalMeters: Double, splitMeters: Double) -> [Double] {
        guard splitMeters > 0, totalMeters >= splitMeters else { return [] }
        return stride(from: splitMeters, through: totalMeters, by: splitMeters).map { $0 }
    }
}
