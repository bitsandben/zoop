import Foundation
import WhoopProtocol

// DaytimeBaselines.swift - turns past DAYTIME history into the personal rolling baselines that
// `DaytimeStress.analyze(mode: .baselineRelative(hr:rmssd:))` scores today's waking hours against.
//
// The scorer takes a finished `BaselineState` and never fetches history; this is the caller side.
// It computes one daytime aggregate per past day, using DaytimeStress's own bucketing, gates and
// HRVAnalyzer so the value folded into the baseline and the value later z-scored against it are the
// same quantity, then folds the series through `Baselines.foldHistory` (Winsorized EWMA) with
// `daytimeHRCfg` / `daytimeRMSSDCfg`.

public extension DaytimeStress {

    // MARK: - Per-day daytime aggregate

    /// Percentile of a day's waking-hour mean HRs used as the daytime-HR aggregate: the 10th, the calm
    /// floor. Validated (~65 bpm pooled, 26-day Oura-reference correlation behind
    /// `baselineRelativeHighMarginBPM`). It is the floor because the HR term pairs it with a fixed bpm
    /// margin, making "floor + margin" the exact HIGH cutoff.
    static let daytimeHRAggregatePercentile: Double = 0.10

    /// Percentile of a day's waking-hour RMSSDs used as the daytime-RMSSD aggregate: the median, not a
    /// mirror of HR's floor. The RMSSD term is scaled by the person's own spread, so the baseline must
    /// be the typical value for a typical hour to read neutral; a calm-ceiling percentile would put an
    /// ordinary hour 1-2 sigma "below baseline" and stack a false stress term. First pass pending an
    /// HR+HRV validation (the study was HR-only).
    static let daytimeRMSSDAggregatePercentile: Double = 0.50

    /// One local day's waking HR and R-R streams, the input to the baseline fold. `tzOffsetSeconds`
    /// (east of UTC for that day) places them on the local clock as `analyze` does, so DST-varying days
    /// carry their own offset. Not `Sendable` (`HRSample` / `RRInterval` aren't).
    struct DaytimeDayStreams: Equatable {
        public let hr: [HRSample]
        public let rr: [RRInterval]
        public let tzOffsetSeconds: Int
        public init(hr: [HRSample], rr: [RRInterval], tzOffsetSeconds: Int) {
            self.hr = hr; self.rr = rr; self.tzOffsetSeconds = tzOffsetSeconds
        }
    }

    /// One day's daytime aggregates, computed with the scorer's own hourly bucketing so the folded value
    /// matches what `.baselineRelative` later references.
    ///   - `hr`: the P10 of the day's waking-hour mean HRs, each hour gated at `minHourHRSamples`;
    ///     nil if no hour clears the gate (sparse or imported day).
    ///   - `rmssd`: the P50 of the day's waking-hour RMSSDs through `HRVAnalyzer.analyze(rawRR:)`
    ///     (ectopic beats can't fabricate variability); nil when no hour had enough clean R-R.
    /// Either may be nil independently. Bucketing keys off HR buckets, so an hour with R-R but no HR counts for neither.
    static func dayDaytimeAggregate(hr: [HRSample], rr: [RRInterval],
                                    tzOffsetSeconds: Int) -> (hr: Double?, rmssd: Double?) {
        guard !hr.isEmpty else { return (nil, nil) }

        // Bucket HR and R-R into local hour-of-day buckets, as the scorer does.
        var hrByBucket: [Int: [Double]] = [:]
        for s in hr {
            let local = s.ts + tzOffsetSeconds
            let bucket = floorDiv(local, bucketSeconds) * bucketSeconds
            hrByBucket[bucket, default: []].append(Double(s.bpm))
        }
        var rrByBucket: [Int: [Double]] = [:]
        for s in rr {
            let local = s.ts + tzOffsetSeconds
            let bucket = floorDiv(local, bucketSeconds) * bucketSeconds
            rrByBucket[bucket, default: []].append(Double(s.rrMs))
        }

        // Per waking hour: gated mean HR and cleaned RMSSD, keyed off HR buckets like the scorer.
        var wakingMeanHRs: [Double] = []
        var wakingRMSSDs: [Double] = []
        for (bucket, hrs) in hrByBucket where isWakingHour(bucket) {
            if hrs.count >= minHourHRSamples, let m = mean(hrs) { wakingMeanHRs.append(m) }
            if let rmssd = HRVAnalyzer.analyze(rawRR: rrByBucket[bucket] ?? []).rmssd {
                wakingRMSSDs.append(rmssd)
            }
        }

        let hrAgg = wakingMeanHRs.isEmpty
            ? nil : quantile(wakingMeanHRs.sorted(), daytimeHRAggregatePercentile)
        let rmssdAgg = wakingRMSSDs.isEmpty
            ? nil : quantile(wakingRMSSDs.sorted(), daytimeRMSSDAggregatePercentile)
        return (hrAgg, rmssdAgg)
    }

    // MARK: - Fold the trailing history into personal baselines

    /// Folds trailing per-day daytime streams (oldest to newest, today excluded) into the personal
    /// baselines `.baselineRelative` consumes, replaying the per-day aggregates through
    /// `Baselines.foldHistory`. Nil aggregates become skip-and-hold nights.
    ///
    /// The HR baseline is always returned (maybe `.calibrating`; callers check `.usable`). The RMSSD
    /// baseline is returned only when `.usable` (>= `Baselines.minNightsSeed` days carried one), so the
    /// scorer runs HR-only rather than z-scoring against a 1-2 day HRV baseline.
    static func foldDaytimeBaselines(days: [DaytimeDayStreams]) -> (hr: BaselineState, rmssd: BaselineState?) {
        foldAggregates(days.map {
            dayDaytimeAggregate(hr: $0.hr, rr: $0.rr, tzOffsetSeconds: $0.tzOffsetSeconds)
        })
    }

    /// The same fold over days already reduced to their `dayDaytimeAggregate` pair, so a caller can
    /// drop each day's raw samples after reducing it instead of holding thirty days at once (#2107,
    /// an Android heap OOM). `foldDaytimeBaselines(days:)` is this with eager reduction: one fold, two entry points.
    static func foldAggregates(_ aggregates: [(hr: Double?, rmssd: Double?)])
        -> (hr: BaselineState, rmssd: BaselineState?) {
        var hrAggs: [Double?] = []
        var rmssdAggs: [Double?] = []
        hrAggs.reserveCapacity(aggregates.count)
        rmssdAggs.reserveCapacity(aggregates.count)
        for agg in aggregates {
            hrAggs.append(agg.hr)
            rmssdAggs.append(agg.rmssd)
        }
        let hrState = Baselines.foldHistory(hrAggs, cfg: Baselines.daytimeHRCfg)
        let rmssdState = Baselines.foldHistory(rmssdAggs, cfg: Baselines.daytimeRMSSDCfg)
        return (hrState, rmssdState.usable ? rmssdState : nil)
    }

    /// The scoring mode for TODAY from trailing daytime `history`: `.baselineRelative` once the personal
    /// HR baseline is `.usable` (>= `Baselines.minNightsSeed` days), else `.dayRelative`. This is the
    /// single graceful-degradation gate for cold starts and sparse/imported windows.
    static func scoringMode(history days: [DaytimeDayStreams]) -> ScoringMode {
        scoringModeFromAggregates(days.map {
            dayDaytimeAggregate(hr: $0.hr, rr: $0.rr, tzOffsetSeconds: $0.tzOffsetSeconds)
        })
    }

    /// `scoringMode(history:)` for days already reduced to aggregates (see `foldAggregates`).
    static func scoringModeFromAggregates(_ aggregates: [(hr: Double?, rmssd: Double?)]) -> ScoringMode {
        let baselines = foldAggregates(aggregates)
        guard baselines.hr.usable else { return .dayRelative }
        // RMSSD stays out of the live score until validated (`DaytimeStress.daytimeRMSSDScoringEnabled`);
        // the baseline is still folded so the machinery and tests exercise the real path.
        let rmssd = DaytimeStress.daytimeRMSSDScoringEnabled ? baselines.rmssd : nil
        return .baselineRelative(hr: baselines.hr, rmssd: rmssd)
    }
}
