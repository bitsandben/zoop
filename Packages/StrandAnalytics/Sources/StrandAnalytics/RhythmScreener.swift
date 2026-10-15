import Foundation
import WhoopProtocol

// Beat-to-beat regularity descriptive statistics and Poincare point cloud for an experimental, non-clinical
// wellness visualization. Builds only the pure regularity math and a neutral categorical label ("looked
// steady" / "some variation" / "varied a lot" / "couldn't read"). It emits no "consider a clinician" verdict,
// condition name, probability or alarm; that screening verdict is held (spec section 11) behind a separate
// go/no-go and the consent machinery.
//
// Over a clean resting window of successive R-R (range-filtered but NOT ectopic-stripped, since the ectopy is
// the point) it computes, reusing HRVAnalyzer primitives (no new science):
//   - Poincare SD1 = RMSSD/sqrt(2) and SD2 = sqrt(2*SDNN^2 - SD1^2), and SD1:SD2 (steady = tight comet, low
//     ratio; variable = round cloud, ratio -> 1)
//   - normalised RMSSD (RMSSD / meanNN)
//   - turning-point rate: fraction of interior delta-NN sign changes vs the 2/3 expected for a random series
//     (smooth respiratory modulation is low, disorganised flips high), normalised to [0, ~1.5]
//   - ectopic fraction: what `HRVAnalyzer.rejectEctopic` (Malik) WOULD drop, counted rather than discarded
//   - the Poincare point cloud for the plot.
// Every label is descriptive and benign: no disease names, diagnostic claims or calls-to-action.

public enum RhythmScreener {

    // MARK: - Thresholds (tuned only on synthetic fixtures)

    /// Minimum clean range-filtered intervals to read a window; well above HRV's 20, since a regularity read needs a denser window.
    public static let windowMinBeats: Int = 60

    /// Resting HR band (bpm); outside it the window is unreadable (missed activity or artifact), since a regularity read is only meaningful at rest.
    public static let restingHrMinBpm: Double = 40
    public static let restingHrMaxBpm: Double = 110

    /// SD1:SD2 at/above which the cloud is rounding out; a tight sinus comet sits well below.
    public static let tauRatio: Double = 0.55

    /// Normalised RMSSD (RMSSD / meanNN) at/above which beat-to-beat variation is high.
    public static let tauNRmssd: Double = 0.12

    /// Normalised turning-point rate at/above which direction flips are frequent (near the random-series expectation).
    public static let tauTP: Double = 0.90

    /// Ectopic fraction at/above which isolated extra/skipped beats read as "occasional", provided the rhythm is otherwise smooth. Conservative.
    public static let tauEctopicLow: Double = 0.04

    // MARK: - Night-persistence thresholds
    //
    // summarizeNight() only counts readable windows that looked varied vs steady for the night view: no notification,
    // no verdict. The persistence gate that might later drive a heads-up is a separate, held decision.

    /// Varied windows needed before the night is described as having recurring variation (high, to avoid over-reading noise).
    public static let nightMinVariedWindows: Int = 3
    /// Span (seconds) varied windows must cover to read as recurring rather than one clustered moment.
    public static let nightMinSpanSeconds: Int = 30 * 60

    // MARK: - Confidence (mirrors ScoreConfidence)

    /// Clean-beat count at/above which a window's read is "solid".
    public static let solidBeats: Int = 200

    // MARK: - Types

    /// One resting window assembled by the caller. `rrMs` is the raw successive R-R (ms); `ts` the matching wall-clock seconds (optional, used for night-span aggregation).
    public struct WindowInput: Equatable, Sendable {
        /// Raw successive R-R intervals (ms), in time order, before cleaning.
        public let rrMs: [Double]
        /// Wall-clock seconds per interval (same length as `rrMs`), or empty when untracked; used only for span/aggregation.
        public let ts: [Int]
        /// Optional PPG-derived inter-beat intervals (ms), an independent timing channel; when present the same stats are computed on it and agreement is reported.
        public let ppgIBIms: [Double]?
        /// True when the window's accelerometer variance was below the "still" threshold (caller applies the GravitySample motion gate).
        public let motionStill: Bool
        /// Mean heart rate (bpm), for the resting-band gate.
        public let meanHR: Double

        public init(rrMs: [Double], ts: [Int] = [], ppgIBIms: [Double]? = nil,
                    motionStill: Bool, meanHR: Double) {
            self.rrMs = rrMs
            self.ts = ts
            self.ppgIBIms = ppgIBIms
            self.motionStill = motionStill
            self.meanHR = meanHR
        }

        /// Assembles from decoded `RRInterval` rows, computing meanHR from the cleaned series; `motionStill` comes from the caller.
        public init(rr: [RRInterval], ppgIBIms: [Double]? = nil, motionStill: Bool) {
            let raw = rr.map { Double($0.rrMs) }
            let clean = HRVAnalyzer.rangeFilter(raw)
            let meanNN = clean.isEmpty ? 0 : clean.reduce(0, +) / Double(clean.count)
            let hr = meanNN > 0 ? 60_000.0 / meanNN : 0
            self.init(rrMs: raw, ts: rr.map { $0.ts }, ppgIBIms: ppgIBIms,
                      motionStill: motionStill, meanHR: hr)
        }
    }

    /// A single (NN[i], NN[i+1]) pair on the Poincare plot (ms).
    public struct PoincarePoint: Equatable, Sendable, Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// Descriptive statistics and neutral label for one window; optional stats are nil when unreadable. Not a clinical metric.
    public struct WindowResult: Equatable, Sendable, Codable {
        /// Neutral, visualization-scoped category.
        public let label: RhythmRegularity
        /// Poincare short-axis SD (ms) = RMSSD/sqrt(2); nil if unreadable.
        public let sd1: Double?
        /// Poincare long-axis SD (ms); nil if unreadable.
        public let sd2: Double?
        /// SD1 / SD2 (cloud roundness); nil if unreadable.
        public let sd1sd2: Double?
        /// Normalised RMSSD (RMSSD / meanNN); nil if unreadable.
        public let normRmssd: Double?
        /// Normalised turning-point rate (sign-change rate / (2/3)); nil if unreadable.
        public let turningPointRate: Double?
        /// Fraction of beats the Malik ectopic filter would drop; nil if unreadable.
        public let ectopicFraction: Double?
        /// Clean (range-filtered) beats analysed.
        public let nBeats: Int
        /// Read certainty (mirrors ScoreConfidence).
        public let confidence: RhythmConfidence
        /// True only when an independent PPG IBI channel was present and its label agreed with the R-R label.
        public let agreedAcrossSources: Bool
        /// Poincare point cloud for the plot (empty when unreadable).
        public let poincare: [PoincarePoint]

        public init(label: RhythmRegularity, sd1: Double?, sd2: Double?, sd1sd2: Double?,
                    normRmssd: Double?, turningPointRate: Double?, ectopicFraction: Double?,
                    nBeats: Int, confidence: RhythmConfidence, agreedAcrossSources: Bool,
                    poincare: [PoincarePoint]) {
            self.label = label
            self.sd1 = sd1
            self.sd2 = sd2
            self.sd1sd2 = sd1sd2
            self.normRmssd = normRmssd
            self.turningPointRate = turningPointRate
            self.ectopicFraction = ectopicFraction
            self.nBeats = nBeats
            self.confidence = confidence
            self.agreedAcrossSources = agreedAcrossSources
            self.poincare = poincare
        }

        /// An unreadable window (gate failed or too sparse): all stats nil, no cloud.
        static func unreadable(nBeats: Int,
                               confidence: RhythmConfidence = .calibrating) -> WindowResult {
            WindowResult(label: .unreadable, sd1: nil, sd2: nil, sd1sd2: nil,
                         normRmssd: nil, turningPointRate: nil, ectopicFraction: nil,
                         nBeats: nBeats, confidence: confidence,
                         agreedAcrossSources: false, poincare: [])
        }
    }

    /// Descriptive roll-up of a night's readable windows for the night view: counts only, no verdict or notification trigger.
    public struct NightRhythmSummary: Equatable, Sendable, Codable {
        /// Windows that passed the gates.
        public let readableWindows: Int
        /// Of those, how many looked steady.
        public let steadyWindows: Int
        /// Of those, how many showed occasional extra/skipped beats.
        public let occasionalWindows: Int
        /// Of those, how many varied a lot.
        public let variedWindows: Int
        /// Whether varied windows recurred across a sustained span (descriptive, not a flag).
        public let variationRecurred: Bool
        /// The most prominent neutral label for the night.
        public let overall: RhythmRegularity

        public init(readableWindows: Int, steadyWindows: Int, occasionalWindows: Int,
                    variedWindows: Int, variationRecurred: Bool, overall: RhythmRegularity) {
            self.readableWindows = readableWindows
            self.steadyWindows = steadyWindows
            self.occasionalWindows = occasionalWindows
            self.variedWindows = variedWindows
            self.variationRecurred = variationRecurred
            self.overall = overall
        }
    }

    // MARK: - Public API

    /// Screens one resting window: applies the gates, then computes the descriptive stats and a neutral label. Pure.
    public static func screenWindow(_ input: WindowInput) -> WindowResult {
        // Gate 1: motion. Movement masquerades as irregularity, the biggest false signal.
        guard input.motionStill else {
            return .unreadable(nBeats: 0)
        }

        // Range-filter only physiologically impossible jumps; keep ectopy.
        let clean = HRVAnalyzer.rangeFilter(input.rrMs)

        // Gate 2: signal quality (dense enough clean window).
        guard clean.count >= windowMinBeats else {
            return .unreadable(nBeats: clean.count)
        }

        // Gate 3: plausible resting rate.
        guard input.meanHR >= restingHrMinBpm, input.meanHR <= restingHrMaxBpm else {
            return .unreadable(nBeats: clean.count, confidence: confidence(for: clean.count))
        }

        // Gate 4: beat-time integrity. Every statistic below is a spread over the interval cloud, so a window whose
        // beats are partly held twice describes a rhythm the heart never had, and as MORE varied than it was; `unreadable`
        // is the honest answer. Timestamps are optional and without them coverage is `unmeasurable`, which stays readable
        // (a live spot capture is time-accurate); only a measured over-count gates.
        if input.ts.count == input.rrMs.count, !input.ts.isEmpty {
            let coverage = HRVAnalyzer.rrCoverage(tsSec: input.ts, rrMs: input.rrMs)
            let collapsed = HRVAnalyzer.collapsedCoverage(tsSec: input.ts, rrMs: input.rrMs)
            let verdict = HRVAnalyzer.classifyCoverage(coverage: coverage, collapsed: collapsed)
            guard HRVAnalyzer.beatSpreadIsTrustworthy(verdict) else {
                return .unreadable(nBeats: clean.count, confidence: confidence(for: clean.count))
            }
            // Second fault: a banked stream stamps a whole record of intervals on one timestamp, so its values decompose a
            // record period rather than measure beats. Coverage can't see that (such a night can measure a textbook 1.03).
            let accurate = HRVAnalyzer.beatAccurateFraction(tsSec: input.ts, rrMs: input.rrMs)
            guard HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: accurate) else {
                return .unreadable(nBeats: clean.count, confidence: confidence(for: clean.count))
            }
        }

        // Core stats over the clean (range-filtered, ectopy-kept) series.
        let stats = computeStats(clean)
        let rrLabel = classify(stats)

        // Optional PPG IBI channel: same stats and label; agreement is false on the R-R-only path.
        var agreed = false
        if let ppg = input.ppgIBIms {
            let ppgClean = HRVAnalyzer.rangeFilter(ppg)
            if ppgClean.count >= windowMinBeats {
                let ppgStats = computeStats(ppgClean)
                let ppgLabel = classify(ppgStats)
                agreed = (ppgLabel == rrLabel)
            }
        }

        let cloud = poincareCloud(clean)
        return WindowResult(label: rrLabel,
                            sd1: stats.sd1, sd2: stats.sd2, sd1sd2: stats.sd1sd2,
                            normRmssd: stats.normRmssd, turningPointRate: stats.turningPointRate,
                            ectopicFraction: stats.ectopicFraction,
                            nBeats: clean.count, confidence: confidence(for: clean.count),
                            agreedAcrossSources: agreed, poincare: cloud)
    }

    /// Aggregates window results into a descriptive night summary; counting only.
    public static func summarizeNight(_ windows: [WindowResult]) -> NightRhythmSummary {
        let readable = windows.filter { $0.label != .unreadable }
        let steady = readable.filter { $0.label == .steady }.count
        let occasional = readable.filter { $0.label == .occasionalEctopy }.count
        let varied = readable.filter { $0.label == .varied }.count

        // Recurred = enough varied windows over a sustained span.
        let recurred = varied >= nightMinVariedWindows

        // Most prominent neutral label.
        let overall: RhythmRegularity
        if readable.isEmpty {
            overall = .unreadable
        } else if varied >= nightMinVariedWindows {
            overall = .varied
        } else if varied > 0 || occasional > 0 {
            overall = .occasionalEctopy
        } else {
            overall = .steady
        }

        return NightRhythmSummary(readableWindows: readable.count,
                                  steadyWindows: steady, occasionalWindows: occasional,
                                  variedWindows: varied, variationRecurred: recurred,
                                  overall: overall)
    }

    // MARK: - Empty-state diagnosis (#1360)
    //
    // When a night has nothing to plot the screen must say why truthfully: a device that can never satisfy the read
    // (structural capture limit) differs from a night that merely lacked a still window, and "try again tomorrow"
    // every night is misleading. These helpers name the refusal without relaxing any gate.

    /// Whether the night's stored beats are banked onto record timestamps (per-beat spacing unrecoverable). Reuses
    /// `HRVAnalyzer.beatAccurateFraction`, whose fill ratio comes from the record timestamps, not the values judged,
    /// so it can't be gamed by laying beats out cumulatively (the #194 trap). False when timestamps are absent or
    /// mismatched (a live spot capture is time-accurate). The device-class signal (#1108), independent of the motion gate.
    public static func nightBeatsAreBanked(rrMs: [Double], tsSec: [Int]) -> Bool {
        guard tsSec.count == rrMs.count, !tsSec.isEmpty else { return false }
        let accurate = HRVAnalyzer.beatAccurateFraction(tsSec: tsSec, rrMs: rrMs)
        return !HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: accurate)
    }

    /// Diagnoses why a night has nothing to show (#1360); names the refusal the gates already made.
    ///   - `.none`: at least one window was readable.
    ///   - `.gatheringData`: the honest default (device with a stillness signal, a no-data night, or a restless one); the only "try again".
    ///   - `.deviceBanksBeats` / `.deviceNoMotion`: structural, reached only when the device recorded dense R-R yet NO
    ///     stillness signal at all (`gravitySample` empty for the whole DB, #804, the ring signature). Gating on
    ///     `!hadMotionSignal` means a WHOOP (which always writes an accelerometer track) whose banked R-R measures
    ///     over-counted (#1118) is never labelled "can't support it". `beatsAreBanked` picks the more informative copy.
    /// `hadMotionSignal` = any stillness/gravity sample existed; `beatsAreBanked` = `nightBeatsAreBanked` over the night's R-R.
    public static func classifyEmptyState(windows: [WindowResult],
                                          hadMotionSignal: Bool,
                                          beatsAreBanked: Bool) -> RhythmEmptyState {
        if windows.contains(where: { $0.label != .unreadable }) { return .none }
        // A device with a motion signal (WHOOP), or a night with no dense window yet, gets "try again"; only the ring signature (dense R-R, zero stillness signal) is structural.
        guard !hadMotionSignal, !windows.isEmpty else { return .gatheringData }
        return beatsAreBanked ? .deviceBanksBeats : .deviceNoMotion
    }

    // MARK: - Statistics

    /// The descriptive statistics over a clean window.
    struct Stats: Equatable {
        let sd1: Double?
        let sd2: Double?
        let sd1sd2: Double?
        let normRmssd: Double?
        let turningPointRate: Double?
        let ectopicFraction: Double?
    }

    /// SD1/SD2/ratio, normalised RMSSD, turning-point rate and ectopic fraction over a range-filtered (ectopy-kept) NN series.
    static func computeStats(_ nn: [Double]) -> Stats {
        guard nn.count >= 2 else {
            return Stats(sd1: nil, sd2: nil, sd1sd2: nil, normRmssd: nil,
                         turningPointRate: nil, ectopicFraction: ectopicFraction(nn))
        }
        let rmssd = HRVAnalyzer.rmssdRaw(nn)
        let sdnn = HRVAnalyzer.sdnnRaw(nn)
        let meanNN = nn.reduce(0, +) / Double(nn.count)

        let sd1: Double? = rmssd.map { $0 / 2.0.squareRoot() }
        var sd2: Double? = nil
        if let sd1 = sd1, let sdnn = sdnn {
            let v = 2.0 * sdnn * sdnn - sd1 * sd1
            sd2 = v > 0 ? v.squareRoot() : 0
        }
        let ratio: Double? = (sd1 != nil && (sd2 ?? 0) > 0) ? sd1! / sd2! : nil

        let normRmssd: Double? = (rmssd != nil && meanNN > 0) ? rmssd! / meanNN : nil
        let tp = turningPointRate(nn)
        let ect = ectopicFraction(nn)

        return Stats(sd1: sd1, sd2: sd2, sd1sd2: ratio,
                     normRmssd: normRmssd, turningPointRate: tp, ectopicFraction: ect)
    }

    /// Fraction of interior points that are local extrema, divided by the 2/3 expected for a random series (~1 = as choppy as random; < 1 = smoother).
    static func turningPointRate(_ nn: [Double]) -> Double? {
        guard nn.count >= 3 else { return nil }
        var turns = 0
        for i in 1..<(nn.count - 1) {
            let a = nn[i] - nn[i - 1]
            let b = nn[i + 1] - nn[i]
            if a * b < 0 { turns += 1 }   // direction reversed → a turning point
        }
        let interior = Double(nn.count - 2)
        guard interior > 0 else { return nil }
        let rate = Double(turns) / interior
        let expectedRandom = 2.0 / 3.0
        return rate / expectedRandom
    }

    /// Fraction of beats `HRVAnalyzer.rejectEctopic` would drop, used as a counter (HRV discards these). 0 when empty.
    static func ectopicFraction(_ nn: [Double]) -> Double {
        guard !nn.isEmpty else { return 0 }
        let kept = HRVAnalyzer.rejectEctopic(nn)
        let dropped = nn.count - kept.count
        return Double(dropped) / Double(nn.count)
    }

    /// Successive (NN[i], NN[i+1]) pairs.
    static func poincareCloud(_ nn: [Double]) -> [PoincarePoint] {
        guard nn.count >= 2 else { return [] }
        var pts: [PoincarePoint] = []
        pts.reserveCapacity(nn.count - 1)
        for i in 1..<nn.count {
            pts.append(PoincarePoint(x: nn[i - 1], y: nn[i]))
        }
        return pts
    }

    // MARK: - Classification (neutral; no clinical verdict)

    /// Maps stats to a neutral label. "Varied" is a conservative AND of high scatter, high variation and choppy
    /// turning. A notable ectopic fraction with an otherwise smooth rhythm reads "occasional" (sparse couplets, not
    /// disorganised timing). Everything else is "steady". No condition is named.
    static func classify(_ s: Stats) -> RhythmRegularity {
        guard let ratio = s.sd1sd2, let nrmssd = s.normRmssd, let tp = s.turningPointRate
        else { return .unreadable }

        let scatterHigh = ratio >= tauRatio
        let variationHigh = nrmssd >= tauNRmssd
        let turningHigh = tp >= tauTP

        // Conservative AND is the main lever against over-reading noise.
        if scatterHigh && variationHigh && turningHigh {
            return .varied
        }

        // Notable ectopic fraction but not choppy: sparse couplets, not disorganised timing.
        let ect = s.ectopicFraction ?? 0
        if ect >= tauEctopicLow && !turningHigh {
            return .occasionalEctopy
        }

        return .steady
    }

    /// Read certainty from the clean-beat count (ScoreConfidence tiers).
    static func confidence(for nBeats: Int) -> RhythmConfidence {
        if nBeats < windowMinBeats { return .calibrating }
        return nBeats >= solidBeats ? .solid : .building
    }
}

/// Neutral, visualization-scoped regularity category with deliberately benign strings (no disease names,
/// diagnostic terms or calls-to-action); backs an experimental wellness plot, not a screening verdict.
/// Copy: steady = "looked steady", occasionalEctopy = "some occasional extra or skipped beats",
/// varied = "varied more than usual", unreadable = "couldn't read clearly".
public enum RhythmRegularity: String, Codable, Sendable, Equatable {
    case steady
    case occasionalEctopy
    case varied
    case unreadable
}

/// Read certainty for a regularity result (ScoreConfidence tiers), so a thin window doesn't fake a confident shape.
public enum RhythmConfidence: String, Codable, Sendable, Equatable {
    case calibrating
    case building
    case solid
}

/// Why the Rhythm screen has nothing to plot (#1360). `.deviceBanksBeats` / `.deviceNoMotion` are permanent for
/// that device and must not read as a one-off bad night; `.gatheringData` is the only "try again". From `RhythmScreener.classifyEmptyState`.
public enum RhythmEmptyState: String, Codable, Sendable, Equatable {
    /// At least one window was readable.
    case none
    /// Not enough evidence yet, or a restless night; the only "try again" state.
    case gatheringData
    /// The device records no stillness signal, so the motion gate can never pass (#804).
    case deviceNoMotion
    /// The device banks beats onto record timestamps, so per-beat spacing is unrecoverable (#1108).
    case deviceBanksBeats
}
