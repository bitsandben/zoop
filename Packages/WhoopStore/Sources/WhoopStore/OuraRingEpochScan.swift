import Foundation

/// Groups Oura sidecar rows by the ring epoch each implies, so a session filed under the wrong
/// anchor is visible without a trusted anchor to compare against.
///
/// Every row implies `epoch = utc - ringTs / 10`, the UTC at which the ring's tick counter read zero.
/// Rows anchored correctly against one ring boot all imply the same epoch; a session anchored as
/// seconds x 10 implies one `0.9 x anchorTicks` seconds earlier, constant across that session.
///
/// This describes, it does not classify: a genuine ring restart also starts a new epoch, and telling
/// that from a mis-anchored session is the caller's call.
public enum OuraRingEpochScan {

    /// One run of rows agreeing on where the ring's clock started.
    public struct Cluster: Equatable, Sendable {
        /// Implied UTC of ring tick 0, taken as the median of the run so one outlying row cannot move it.
        public let epochUnix: Int
        public let rows: Int
        /// The stored-UTC span of this run, which is what a reader sees on a calendar.
        public let firstStoredUtc: Int
        public let lastStoredUtc: Int

        public init(epochUnix: Int, rows: Int, firstStoredUtc: Int, lastStoredUtc: Int) {
            self.epochUnix = epochUnix
            self.rows = rows
            self.firstStoredUtc = firstStoredUtc
            self.lastStoredUtc = lastStoredUtc
        }
    }

    /// Six hours, the default gap that separates one epoch from the next.
    ///
    /// Not tight on purpose: the ring clock runs at 9.94 to 10.25 ticks per second, so dividing by 10
    /// drifts by hours within a correctly anchored fortnight. The defect being surfaced moves the epoch
    /// by days.
    public static let defaultToleranceSeconds = 21_600

    /// One report line when rows disagree about where the ring's clock started, or nil when they agree.
    /// Nil is the common, healthy answer and leaves a healthy report unchanged.
    ///
    /// States the gap in days rather than naming a cause: a gap near 41.7 days is the ticks x 10
    /// signature, a few days is more likely a real restart.
    public static func summaryLine(_ clusters: [Cluster]) -> String? {
        guard clusters.count > 1, let newest = clusters.first else { return nil }
        var line = "ouraRingEpoch clusters=\(clusters.count) newest=\(isoDay(newest.epochUnix)) rows=\(newest.rows)"
        for older in clusters.dropFirst() {
            let gapDays = Double(newest.epochUnix - older.epochUnix) / 86_400
            line += " | epoch=\(isoDay(older.epochUnix)) rows=\(older.rows)"
                + " gapDays=\(String(format: "%.1f", gapDays))"
                + " stored=\(isoDay(older.firstStoredUtc))..\(isoDay(older.lastStoredUtc))"
        }
        return line
    }

    /// UTC calendar day for a unix second, as the report prints dates elsewhere.
    static func isoDay(_ unix: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Clusters `rows` by implied ring epoch, newest epoch first. Input order does not matter and only
    /// `ringTs` and the stored `utc` are read. A row with `ringTs` 0 is dropped: it has no time axis.
    public static func cluster(_ rows: [(ringTs: UInt32, utc: Int)],
                               toleranceSeconds: Int = defaultToleranceSeconds) -> [Cluster] {
        let points = rows
            .filter { $0.ringTs > 0 }
            .map { (epoch: $0.utc - Int($0.ringTs) / 10, utc: $0.utc) }
            .sorted { $0.epoch < $1.epoch }
        guard !points.isEmpty else { return [] }

        // Runs are collected first and clustered after, not closed by a nested function the parity ledger cannot pair.
        var runs: [[(epoch: Int, utc: Int)]] = []
        var run: [(epoch: Int, utc: Int)] = [points[0]]

        for point in points.dropFirst() {
            // Compared with the previous row, not the run's first: a long session drifts steadily and would
            // otherwise split one boot in two.
            if point.epoch - run[run.count - 1].epoch <= toleranceSeconds {
                run.append(point)
            } else {
                runs.append(run)
                run = [point]
            }
        }
        runs.append(run)

        let clusters = runs.map { r -> Cluster in
            let epochs = r.map(\.epoch).sorted()
            let utcs = r.map(\.utc)
            return Cluster(epochUnix: epochs[epochs.count / 2],
                           rows: r.count,
                           firstStoredUtc: utcs.min() ?? 0,
                           lastStoredUtc: utcs.max() ?? 0)
        }
        // Tie-broken because `sorted(by:)` is not stable: equal median epochs must order the same on both
        // platforms so `summaryLine` names the same cluster "newest".
        return clusters.sorted {
            if $0.epochUnix != $1.epochUnix { return $0.epochUnix > $1.epochUnix }
            if $0.rows != $1.rows { return $0.rows > $1.rows }
            return $0.firstStoredUtc > $1.firstStoredUtc
        }
    }
}
