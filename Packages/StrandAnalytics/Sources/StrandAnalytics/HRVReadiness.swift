import Foundation

// Opt-in experimental HRV readiness (Plews/Altini smallest-worthwhile-change). Pure and DB-free; surfaced
// read-only behind the `noopHrvReadiness` experiment flag and feeds no downstream gate.
//
// Works in the ln RMSSD domain: a 7-night rolling baseline is compared with a longer personal normal band
// (+/-0.5 SD) and the tier is read off where the baseline sits. Input is DailyMetric.avgHrv (ms, oldest ->
// newest, nils allowed); implausible nights are dropped via Baselines.hrvCfg (5..250 ms). Returns nil
// (calibrating) below `minNights` valid nights, never a fabricated number.
// Early experiment, not validated on varying real data (n=1); wellness estimate only.

/// Where the 7-night HRV baseline sits relative to the personal normal band.
public enum ReadinessTier: String, Equatable, Sendable {
    case primed
    case normal
    case suppressed
}

/// Result of an `HRVReadiness.evaluate` pass. `*Ms` fields are in milliseconds (exp of the log domain).
public struct HRVReadinessResult: Equatable, Sendable {
    public let tier: ReadinessTier
    /// 7-night rolling baseline (ms): exp of the mean ln RMSSD over `rollWindow` nights.
    public let baseline7Ms: Double
    /// Lower edge of the personal normal band (ms).
    public let normalLowMs: Double
    /// Upper edge of the personal normal band (ms).
    public let normalHighMs: Double
    /// Informational only (never changes the tier): falling CV trend while the 7-night baseline is below the long mean.
    public let overreachingWatch: Bool

    public init(tier: ReadinessTier, baseline7Ms: Double, normalLowMs: Double, normalHighMs: Double,
                overreachingWatch: Bool) {
        self.tier = tier
        self.baseline7Ms = baseline7Ms
        self.normalLowMs = normalLowMs
        self.normalHighMs = normalHighMs
        self.overreachingWatch = overreachingWatch
    }
}

/// Opt-in experimental HRV-readiness engine.
public enum HRVReadiness {

    // MARK: - Constants

    /// Short rolling baseline window (nights).
    public static let rollWindow: Int = 7
    /// Long personal-normal window (nights).
    public static let longWindow: Int = 60
    /// Long-window fallback (nights) when fewer than `longWindow` valid nights exist.
    public static let longWindowFallback: Int = 30
    /// Half-width factor: the normal band is longMean +/- swcK*longSD.
    public static let swcK: Double = 0.5
    /// Minimum valid nights before a reading is offered; deliberately not aliased to `WatchRecovery.minBaselineNights`.
    public static let minNights: Int = 14
    /// Trailing nights over which the CV trend is fit.
    public static let cvTrendWindow: Int = 28
    /// Floor on the long-window SD so a flat history gives a tiny band rather than an ULP-fragile zero-width one.
    public static let longSDFloor: Double = 1e-9

    // MARK: - Evaluate

    /// Computes the HRV-readiness reading, or nil (calibrating) below `minNights` valid nights.
    ///
    /// - Parameter avgHrv: nightly RMSSD (ms), oldest -> newest; nils = missing nights.
    public static func evaluate(avgHrv: [Double?]) -> HRVReadinessResult? {
        let cfg = Baselines.hrvCfg
        // Drop nils and implausible nights.
        let valid = avgHrv.compactMap { v -> Double? in
            guard let v = v, cfg.minVal <= v && v <= cfg.maxVal else { return nil }
            return v
        }
        guard valid.count >= minNights else { return nil }

        // ln RMSSD; max(.,1) guards ln of a sub-1 value.
        let ell = valid.map { log(max($0, 1.0)) }

        let baseline7 = RecoveryForecaster.mean(Array(ell.suffix(rollWindow)))

        // Long window if enough valid nights, else the 30-night fallback.
        let longWin = valid.count >= longWindow ? longWindow : longWindowFallback
        let longEll = Array(ell.suffix(longWin))
        let longMean = RecoveryForecaster.mean(longEll)
        // Fall back to the 7-night SD with <2 long nights; floored to keep the band non-degenerate.
        let longSDraw = longEll.count >= 2 ? RecoveryForecaster.sampleSD(longEll)
                                           : RecoveryForecaster.sampleSD(Array(ell.suffix(rollWindow)))
        let longSD = max(longSDraw, longSDFloor)

        let swcHalf = swcK * longSD
        let normalLow = longMean - swcHalf
        let normalHigh = longMean + swcHalf

        // Above the band -> primed; inside (low edge inclusive) -> normal; below -> suppressed.
        let tier: ReadinessTier
        if baseline7 > normalHigh {
            tier = .primed
        } else if baseline7 >= normalLow {
            tier = .normal
        } else {
            tier = .suppressed
        }

        // Informational overreaching watch: OLS slope of a rolling-7 CV series over the last cvTrendWindow nights.
        var cvSeries: [Double] = []
        let cvStart = max(rollWindow - 1, ell.count - cvTrendWindow)
        var i = cvStart
        while i < ell.count {
            let w = Array(ell[(i - rollWindow + 1)...i])
            let m = RecoveryForecaster.mean(w)
            let cv = m != 0.0 ? 100.0 * RecoveryForecaster.sampleSD(w) / m : 0.0
            cvSeries.append(cv)
            i += 1
        }
        let cvSlope = RecoveryForecaster.leastSquaresSlope(cvSeries)
        let overreachingWatch = cvSlope < 0.0 && baseline7 < longMean

        return HRVReadinessResult(tier: tier,
                                  baseline7Ms: exp(baseline7),
                                  normalLowMs: exp(normalLow),
                                  normalHighMs: exp(normalHigh),
                                  overreachingWatch: overreachingWatch)
    }
}
