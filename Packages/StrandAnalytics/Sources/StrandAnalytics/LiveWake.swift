import Foundation
import WhoopProtocol

// LiveWake: a HEURISTIC read of awake / light / deep from the strap's ~1 Hz live heart rate inside the smart
// alarm window. It compares the last two minutes against the night's sleeping heart-rate level: a sustained
// rise with movement reads as awake, a smaller or shorter rise (or movement alone) as light, a flat heart rate
// at the sleeping level as deep. Unvalidated against polysomnography or on hardware; it only feeds the
// experimental smart alarm, never a stored metric. Pure and clock-free: every time is an epoch second passed in.

public enum LiveWake {

    public enum State: String, Codable, Sendable {
        /// Heart rate well above the sleeping level for a sustained stretch, with movement (or a large rise).
        case awake
        /// A smaller or shorter rise, or movement alone.
        case light
        /// Flat heart rate at the sleeping level.
        case deep
        /// Enough data, but none of the above: no signal either way.
        case steady
    }

    public struct Reading: Equatable, Sendable {
        /// nil when there is not enough fresh live data, or no sleeping level to compare against.
        public let state: State?
        /// Median of the recent window (bpm).
        public let recentBpm: Double?
        public let sleepingBpm: Double?
        /// How long, up to now, heart rate has stayed `awakeRiseBpm` above the sleeping level (seconds).
        public let elevatedS: Int
        /// Live samples in the recent window.
        public let samples: Int
    }

    /// The window the state is read over, and how much of it must carry samples (~1 Hz expected).
    public static let recentS = 120
    public static let minRecentSamples = 40
    /// The newest sample must be at most this old.
    public static let maxSampleAgeS = 20
    /// Medians are taken over bins this long, so one spike cannot carry a run.
    public static let binS = 10
    static let minSamplesPerBin = 3
    /// Rise above the sleeping level that counts as awake when sustained `awakeSustainS` with movement.
    public static let awakeRiseBpm = 10.0
    public static let awakeSustainS = 90
    /// A rise this large, sustained `strongSustainS`, reads as awake without movement.
    public static let strongRiseBpm = 20.0
    public static let strongSustainS = 120
    /// A smaller rise, sustained `lightSustainS`, reads as light.
    public static let lightRiseBpm = 5.0
    public static let lightSustainS = 60
    /// Deep: recent median within this of the sleeping level, and bin medians within `deepMaxSpreadBpm`.
    public static let deepMarginBpm = 3.0
    public static let deepMaxSpreadBpm = 4.0

    /// The sleeping heart-rate level: the lower quartile of 5-minute medians over `[from, to)`, from at least
    /// six buckets (half an hour) of data. The lower quartile, not the minimum, so one quiet bucket does not set it.
    public static func sleepingLevel(_ hr: [HRSample], from: Int, to: Int) -> Double? {
        var buckets: [Int: [Double]] = [:]
        for s in hr where s.ts >= from && s.ts < to {
            buckets[s.ts / 300, default: []].append(Double(s.bpm))
        }
        let medians = buckets.values.filter { $0.count >= 5 }.map(median).sorted()
        guard medians.count >= 6 else { return nil }
        return medians[(medians.count - 1) / 4]
    }

    /// The state at `now` from live samples, against `sleepingBpm`. `moving` is the wrist-movement signal the
    /// caller has (it comes from synced motion and may be a few minutes old).
    public static func classify(live: [HRSample], sleepingBpm: Double?, moving: Bool, now: Int) -> Reading {
        let recent = live.filter { $0.ts > now - recentS && $0.ts <= now }
        let recentMedian = recent.isEmpty ? nil : median(recent.map { Double($0.bpm) })
        guard let sleeping = sleepingBpm, recent.count >= minRecentSamples,
              let newest = recent.map(\.ts).max(), now - newest <= maxSampleAgeS
        else { return Reading(state: nil, recentBpm: recentMedian, sleepingBpm: sleepingBpm, elevatedS: 0,
                              samples: recent.count) }
        let bins = binMedians(recent, end: newest)
        let awakeRun = trailingRun(bins, above: sleeping + awakeRiseBpm)
        let strongRun = trailingRun(bins, above: sleeping + strongRiseBpm)
        let lightRun = trailingRun(bins, above: sleeping + lightRiseBpm)
        let state: State
        if (awakeRun >= awakeSustainS && moving) || strongRun >= strongSustainS {
            state = .awake
        } else if awakeRun >= awakeSustainS || lightRun >= lightSustainS || moving {
            state = .light
        } else if let m = recentMedian, m <= sleeping + deepMarginBpm,
                  let lo = bins.compactMap({ $0 }).min(), let hi = bins.compactMap({ $0 }).max(),
                  hi - lo <= deepMaxSpreadBpm {
            state = .deep
        } else {
            state = .steady
        }
        return Reading(state: state, recentBpm: recentMedian, sleepingBpm: sleeping, elevatedS: awakeRun,
                       samples: recent.count)
    }

    /// Per-bin medians over `recentS` ending at the newest sample, oldest first; nil for a bin with too few samples.
    static func binMedians(_ recent: [HRSample], end: Int) -> [Double?] {
        let count = recentS / binS
        var bins = Array(repeating: [Double](), count: count)
        for s in recent {
            let idx = (s.ts - (end - recentS) - 1) / binS
            guard idx >= 0, idx < count else { continue }
            bins[idx].append(Double(s.bpm))
        }
        return bins.map { $0.count >= minSamplesPerBin ? median($0) : nil }
    }

    /// Seconds, counted back from the newest bin, that every bin's median stayed at or above `level`. A bin
    /// without enough samples ends the run, so a gap never counts as elevated.
    static func trailingRun(_ bins: [Double?], above level: Double) -> Int {
        var n = 0
        for b in bins.reversed() {
            guard let b, b >= level else { break }
            n += 1
        }
        return n * binS
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
