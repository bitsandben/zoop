import Foundation
import WhoopStore

/// On-device Readiness: a pure, deterministic synthesis of established non-medical sports-science signals from
/// the daily-metrics history into one readiness read plus its drivers.
///
/// - HRV readiness: z-score of today's HRV vs the personal trailing baseline; a drop of ~0.5 SD flags autonomic
///   fatigue (Plews 2013; Buchheit 2014).
/// - Resting-HR drift: elevated RHR vs baseline signals overtraining / illness (Lamberts 2004).
/// - Respiratory-rate drift: a rise in sleeping rate is an early illness signal.
/// - Training monotony: mean/SD of daily strain over a week (Foster 1998).
///
/// ACWR is deliberately absent (a statistical artefact, Impellizzeri 2020/2021); load is reported once by
/// `TrainingLoadEngine`. Not medical advice: approximate trends in the user's own data.
public enum ReadinessEngine {

    // MARK: Output types

    public enum Level: String, Sendable, Equatable {
        case primed       // signals aligned, load supported
        case balanced     // nothing notable either way
        case strained     // one meaningful signal down / load high
        case rundown      // several recovery signals down
        case insufficient // not enough history yet
    }

    public enum Flag: String, Sendable, Equatable {
        case good, neutral, watch, bad
    }

    /// Locale-free numeric evidence; clients format and localize it at the display boundary.
    public enum Evidence: Sendable, Equatable {
        case metric(value: Double, baseline: Double, unit: String, decimals: Int)
        case monotony(Double)
    }

    public struct Signal: Sendable, Equatable {
        public let key: String      // "hrv" | "rhr" | "respRate" | "monotony"
        public let label: String    // short human label
        public let evidence: String?
        public let evidenceData: Evidence?
        public let detail: String   // one-line plain-English read
        public let flag: Flag
        public init(key: String, label: String, evidence: String? = nil,
                    evidenceData: Evidence? = nil, detail: String, flag: Flag) {
            self.key = key; self.label = label; self.evidence = evidence
            self.evidenceData = evidenceData; self.detail = detail; self.flag = flag
        }
    }

    public struct Readiness: Sendable, Equatable {
        public let level: Level
        public let headline: String
        public let summary: String
        public let signals: [Signal]
        /// Foster training monotony over the last week; nil without enough strain history.
        public let monotony: Double?
        /// How much history backs this read (HRV/RHR baseline density), so the card shows calibrating / building / solid.
        public let confidence: ScoreConfidence
        public init(level: Level, headline: String, summary: String,
                    signals: [Signal], monotony: Double?,
                    confidence: ScoreConfidence = .calibrating) {
            self.level = level; self.headline = headline; self.summary = summary
            self.signals = signals; self.monotony = monotony
            self.confidence = confidence
        }
    }

    // MARK: Tunables

    private static let baselineWindow = 30   // days for HRV / RHR / RR baselines
    private static let minBaseline    = 7    // need at least this many baseline nights
    private static let monotonyWindow = 7
    private static let minStrainDays  = 14   // strain history needed before monotony is read

    // MARK: Entry point

    /// Evaluates readiness from daily metrics (any order); the most recent day is "today" unless `today` (YYYY-MM-DD) is given.
    public static func evaluate(days: [DailyMetric], today: String? = nil) -> Readiness {
        // #707: `evaluate` sorts the full history and is read from SwiftUI computed properties, so it would re-run on
        // each ~1 Hz live-HR tick. This cache is keyed by `today` plus a fingerprint of only the row fields the
        // synthesis reads, shielding every caller; a new sync re-keys, a cosmetic reorder does not.
        let key = ReadinessKey(today: today, rows: Self.rowsFingerprint(days))
        return evaluateCache.value(key) { evaluateUncached(days: days, today: today) }
    }

    private struct ReadinessKey: Hashable { let today: String?; let rows: StreamFingerprint }
    private static let evaluateCache = AnalyticsMemoCache<ReadinessKey, Readiness>(capacity: 16)

    /// Order-independent fingerprint of the readiness-relevant columns (`evaluate` sorts internally, so order never matters).
    private static func rowsFingerprint(_ days: [DailyMetric]) -> StreamFingerprint {
        var sum: UInt64 = 1469598103934665603
        var minDayHash = 0, maxDayHash = 0
        for (i, d) in days.enumerated() {
            // Folds stay in UInt64: `Double.bitPattern` can exceed Int64.max, so an Int64 round-trip would trap.
            var h: UInt64 = UInt64(bitPattern: Int64(d.day.hashValue))
            h = (h &* 1099511628211) ^ (d.avgHrv ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.restingHr.map { UInt64(bitPattern: Int64($0)) } ?? .max)
            h = (h &* 1099511628211) ^ (d.respRateBpm ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.strain ?? -1).bitPattern
            sum ^= h                                   // commutative fold → order-independent
            let dh = d.day.hashValue
            if i == 0 { minDayHash = dh; maxDayHash = dh } else { minDayHash = min(minDayHash, dh); maxDayHash = max(maxDayHash, dh) }
        }
        return StreamFingerprint(count: days.count, firstTs: minDayHash, lastTs: maxDayHash, checksum: sum)
    }

    private static func evaluateUncached(days: [DailyMetric], today: String?) -> Readiness {
        let sorted = days.sorted { $0.day < $1.day }
        // With an explicit `today`, use that day's row only: a stale import has no row for today, so the card reads
        // "insufficient" instead of synthesizing off an old row (#23/#24). Without `today`, use the most recent row.
        let latestRow: DailyMetric?
        if let today { latestRow = sorted.first { $0.day == today } } else { latestRow = sorted.last }
        guard let latest = latestRow else {
            return Readiness(level: .insufficient,
                             headline: "Readiness",
                             summary: "Wear the strap for a few nights and your readiness read will appear here.",
                             signals: [], monotony: nil)
        }
        let history = sorted.filter { $0.day < latest.day }   // everything before today

        var signals: [Signal] = []

        let hrvSignal = zSignal(
            value: latest.avgHrv,
            baseline: history.suffix(baselineWindow).compactMap { $0.avgHrv },
            key: "hrv", label: "HRV",
            unit: "ms",
            decimals: 0,
            higherIsBetter: true,
            logDomain: true,   // RD1: lnRMSSD — HRV is right-skewed
            cfg: Baselines.readinessHRVLnCfg,   // RD2: ln-space spine, reject off
            goodText: "above your baseline - well recovered",
            neutralText: "in your normal range",
            watchText: "a touch below baseline",
            badText: "suppressed - a sign of autonomic fatigue")
        if let s = hrvSignal { signals.append(s) }

        let rhrSignal = zSignal(
            value: latest.restingHr.map(Double.init),
            baseline: history.suffix(baselineWindow).compactMap { $0.restingHr.map(Double.init) },
            key: "rhr", label: "Resting HR",
            unit: "bpm",
            decimals: 0,
            higherIsBetter: false,
            cfg: Baselines.restingHRCfg,   // RD2: raw-bpm spine, reject off
            goodText: "at or below baseline",
            neutralText: "in your normal range",
            watchText: "running a little high",
            badText: "elevated - overtraining or illness can do this")
        if let s = rhrSignal { signals.append(s) }

        // Respiratory rate may be a clean cloud value or a noisier on-device RSA estimate: gate the latest value and the
        // baseline mean to the plausible sleeping band (8-25 bpm) and use wider resp-only z thresholds (WATCH 1.5 / BAD 2.0)
        // so one noisy night can't flip RUNDOWN (#78).
        if let rr = latest.respRateBpm, SleepStager.respPlausibleRangeBpm.contains(rr) {
            let base = history.suffix(baselineWindow).compactMap { $0.respRateBpm }
            if base.count >= minBaseline, let m = mean(base),
               SleepStager.respPlausibleRangeBpm.contains(m), let sd = sampleSD(base), sd > 0 {
                let z = (rr - m) / sd
                if z >= 2.0 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        evidenceData: .metric(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "up vs baseline - sometimes an early sign of getting sick", flag: .bad))
                } else if z >= 1.5 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        evidenceData: .metric(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "slightly raised vs baseline", flag: .watch))
                }
            }
        }

        let strainSeries = sorted.compactMap { $0.strain }
        var monotony: Double? = nil
        if strainSeries.count >= minStrainDays {
            let week = Array(strainSeries.suffix(monotonyWindow))
            if week.count >= 4, let sd = sampleSD(week), sd > 0, let m = mean(week) {
                let mono = m / sd
                monotony = mono
                if mono >= 2.0 {
                    signals.append(Signal(key: "monotony", label: "Training variety",
                        evidence: "monotony \(String(format: "%.1f", mono))",
                        evidenceData: .monotony(mono),
                        detail: "low - similar strain every day raises strain/illness risk", flag: .watch))
                }
            }
        }

        let (level, headline, summary) = synthesize(signals: signals,
                                                    hasHistory: !history.isEmpty)
        // Surface how much history backs the read (HRV baseline density); a 7-night baseline must not look as certain as a full 30-night window.
        let hrvBaselineNights = history.suffix(baselineWindow).compactMap { $0.avgHrv }.count
        let confidence = ScoreConfidence.readiness(hasRead: level != .insufficient,
                                                   baselineNights: hrvBaselineNights,
                                                   fullWindow: baselineWindow)
        return Readiness(level: level, headline: headline, summary: summary,
                         signals: signals, monotony: monotony,
                         confidence: confidence)
    }

    // MARK: Signal builders

    /// Builds a z-score signal against the trailing-window baseline.
    private static func zSignal(value: Double?, baseline: [Double],
                                key: String, label: String, unit: String, decimals: Int,
                                higherIsBetter: Bool, logDomain: Bool = false,
                                cfg: MetricCfg,
                                goodText: String, neutralText: String,
                                watchText: String, badText: String) -> Signal? {
        guard let v = value, baseline.count >= minBaseline else { return nil }
        // Right-skewed metrics (HRV/RMSSD) are z-scored in the log domain (Plews/Altini), where a symmetric z is valid;
        // RHR/resp stay linear. The baseline shown is then the geometric mean, a typical night rather than an outlier-inflated mean.
        let tv = logDomain ? log(max(v, 1.0)) : v
        let tb = logDomain ? baseline.map { log(max($0, 1.0)) } : baseline
        // Fold the baseline through the shared Winsorized-EWMA spine (recency-weighted, sigma-floored, Winsor-clamped).
        // Hard-outlier rejection is off so a re-folded window adapts to a sustained shift (fitness change, device swap)
        // instead of rejecting the new normal. `cfg` is in the same space as `tb` (ln for HRV, linear for RHR).
        let state = Baselines.foldHistory(tb.map { Optional($0) }, cfg: cfg, rejectHardOutliers: false)
        guard state.usable else { return nil }
        let sigma = max(1.253 * state.spread, 1e-9)   // robust σ from the EWMA-abs-dev spread
        guard sigma > 0 else { return nil }
        let m = state.baseline
        // Orient z so positive means better.
        let z = (higherIsBetter ? (tv - m) : (m - tv)) / sigma
        let flag: Flag
        let text: String
        switch z {
        case 0.5...:        flag = .good;    text = goodText
        case -0.5..<0.5:    flag = .neutral; text = neutralText
        case -1.0 ..< -0.5: flag = .watch;   text = watchText
        default:            flag = .bad;     text = badText
        }
        return Signal(key: key, label: label,
                      evidence: evidence(value: v, baseline: logDomain ? exp(m) : m,
                                         unit: unit, decimals: decimals),
                      evidenceData: .metric(value: v, baseline: logDomain ? exp(m) : m,
                                            unit: unit, decimals: decimals),
                      detail: text, flag: flag)
    }

    private static func evidence(value: Double, baseline: Double, unit: String, decimals: Int) -> String {
        "\(format(value, decimals: decimals)) vs \(format(baseline, decimals: decimals)) \(unit)"
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(decimals)f", value)
    }

    // MARK: Synthesis

    private static func synthesize(signals: [Signal], hasHistory: Bool) -> (Level, String, String) {
        guard hasHistory, !signals.isEmpty else {
            return (.insufficient, "Readiness",
                    "A few more nights of data and your readiness read will sharpen.")
        }
        let bad = signals.filter { $0.flag == .bad }
        let watch = signals.filter { $0.flag == .watch }
        let good = signals.filter { $0.flag == .good }
        let recoveryDown = signals.contains { ["hrv", "rhr", "respRate"].contains($0.key) && ($0.flag == .bad) }

        if bad.count >= 2 {
            return (.rundown, "Run down",
                    "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.")
        }
        if recoveryDown || bad.count >= 1 {
            return (.strained, "Strained",
                    "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.")
        }
        if good.count >= 2 && watch.isEmpty {
            return (.primed, "Primed",
                    "Your signals are aligned and your load is supported. A harder session is well backed today.")
        }
        return (.balanced, "Balanced",
                "Nothing's flagging. Train to feel - your body's holding steady.")
    }

    // MARK: Stats helpers

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n-1); nil for fewer than 2 points.
    static func sampleSD(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
