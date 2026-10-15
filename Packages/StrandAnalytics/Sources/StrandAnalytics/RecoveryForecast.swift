import Foundation

// Evening estimate of tomorrow-morning Charge, with an honest +/- band. Pure, deterministic, DB-free.
//
// An estimate, not a measurement: morning recovery comes from the next night's HRV/RHR/respiration, which don't
// exist yet, so this leans on the levers known tonight via a simple transparent weighting (not a learned model).
//
//   center   = mean(recent Charge over ~baselineWindow days)
//   adj1     = -strainWeight x (todayEffort - meanEffort) / effortSpread            (clamped; strain debt)
//   adj2     = sleepWeight x clamp(sleepHours/needHours - 1, -1, +0.25)             (sleep adequacy)
//   adj3     = -reversionWeight x recentSlopePerDay                                  (mean reversion, clamped)
//   forecast = clamp(center + adj1 + adj2 + adj3, 0, 100)
//
// Band: the recent day-to-day SD of Charge, floored at minBandPoints and inflated on a thin baseline.
// Returns nil below minBaselineNights of recent Charge, so a cold start never sees a fabricated number.

// MARK: - Result

/// Evening projection of tomorrow-morning Charge (0-100); approximate.
public struct RecoveryForecast: Equatable, Sendable {
    /// Point estimate, 0-100, whole number.
    public let charge: Double
    /// Symmetric +/- band on `charge`, in points.
    public let band: Double
    /// Recent Charge baseline (mean) the projection is anchored to.
    public let baseline: Double
    /// Planned/banked sleep hours tonight that the projection assumed.
    public let plannedSleepHours: Double
    /// Personal sleep need (hours) the adequacy term compared against.
    public let needHours: Double
    /// Nights of recent Charge history behind the baseline.
    public let nights: Int
    /// Certainty tier (shared Charge/Effort/Rest confidence ladder).
    public let confidence: ScoreConfidence

    public init(charge: Double, band: Double, baseline: Double,
                plannedSleepHours: Double, needHours: Double,
                nights: Int, confidence: ScoreConfidence) {
        self.charge = charge
        self.band = band
        self.baseline = baseline
        self.plannedSleepHours = plannedSleepHours
        self.needHours = needHours
        self.nights = nights
        self.confidence = confidence
    }

    /// Low end of the band, clamped to [0, 100].
    public var low: Double { Swift.max(0, charge - band) }
    /// High end of the band, clamped to [0, 100].
    public var high: Double { Swift.min(100, charge + band) }
}

// MARK: - Engine

public enum RecoveryForecaster {

    // MARK: Tunables (deterministic, not learned)

    /// Trailing Charge nights for the baseline mean / SD / slope.
    public static let baselineWindow: Int = 14
    /// Minimum recent Charge nights before a forecast is offered.
    public static let minBaselineNights: Int = 5
    /// Trailing Effort nights for the strain-debt reference average.
    public static let effortWindow: Int = 14

    /// Charge points a one-spread excess of today's Effort removes.
    public static let strainWeight: Double = 9.0
    /// Effort spread (points) defining one unit of strain excess; a fixed, explainable value rather than a personal SD.
    public static let effortSpread: Double = 12.0
    /// Max |strain-debt| nudge (points), so one freak day can't dominate.
    public static let strainAdjCap: Double = 12.0

    /// Charge points a full night short/over of sleep need moves the estimate.
    public static let sleepWeight: Double = 14.0
    /// Sleep beyond need helps only up to this fraction.
    public static let sleepOverCap: Double = 0.25

    /// Mean-reversion damping: Charge points removed per point/day of up-slope (added back for down-slope).
    public static let reversionWeight: Double = 1.0
    /// Max |mean-reversion| nudge (points).
    public static let reversionAdjCap: Double = 8.0

    /// Floor on the +/- band (points).
    public static let minBandPoints: Double = 8.0
    /// Extra +/- points while the baseline is below `trustedNights`.
    public static let thinBandPoints: Double = 6.0
    /// Recent Charge nights at/above which the band is no longer inflated.
    public static let trustedNights: Int = 10
    /// Nights informing the sleep need at/above which it is "solid" (matches the building-vs-solid threshold of 7).
    public static let solidNeedNights: Int = 7

    /// Default personal sleep need (hours) when the caller has none.
    public static let defaultNeedHours: Double = AnalyticsEngine.Rest.defaultNeedHours

    // MARK: - Forecast

    /// Projects tomorrow-morning Charge from tonight's known levers; nil until `minBaselineNights` of recent Charge exist. Approximate.
    ///
    /// - Parameters:
    ///   - recentCharge: daily Charge (0-100), oldest to newest; the trailing `baselineWindow` are used.
    ///   - recentEffort: daily Effort (0-100), oldest to newest; the trailing `effortWindow` set the strain reference. May be empty (term drops).
    ///   - todayEffort: today's Effort, or nil to drop the strain term.
    ///   - plannedSleepHours: sleep planned / banked tonight; negative is treated as 0.
    ///   - needHours: personal sleep need; nil uses `defaultNeedHours`.
    ///   - needNights: nights that informed `needHours` (0 = still the default); drives the confidence tier.
    public static func forecast(recentCharge: [Double],
                                recentEffort: [Double] = [],
                                todayEffort: Double?,
                                plannedSleepHours: Double,
                                needHours: Double? = nil,
                                needNights: Int = 0) -> RecoveryForecast? {
        let chargeWindow = Array(recentCharge.suffix(baselineWindow))
        let nights = chargeWindow.count
        guard nights >= minBaselineNights else { return nil }

        let center = mean(chargeWindow)
        let sd = sampleSD(chargeWindow)
        let slope = leastSquaresSlope(chargeWindow)

        // Strain debt: today vs recent average Effort.
        var strainAdj = 0.0
        if let today = todayEffort, !recentEffort.isEmpty {
            let meanEffort = mean(Array(recentEffort.suffix(effortWindow)))
            let excess = (today - meanEffort) / effortSpread
            strainAdj = clamp(-strainWeight * excess, -strainAdjCap, strainAdjCap)
        }

        // Sleep adequacy: planned sleep vs personal need.
        let need = Swift.max(needHours ?? defaultNeedHours, 0.1)
        let sleep = Swift.max(plannedSleepHours, 0.0)
        let sleepRatio = clamp(sleep / need - 1.0, -1.0, sleepOverCap)
        let sleepAdj = sleepWeight * sleepRatio

        // Mean reversion: dampen a recent streak toward the baseline.
        let reversionAdj = clamp(-reversionWeight * slope, -reversionAdjCap, reversionAdjCap)

        let raw = center + strainAdj + sleepAdj + reversionAdj
        let charge = (clamp(raw, 0.0, 100.0)).rounded()

        // +/- band: recent SD, floored, inflated while the baseline is thin.
        var band = Swift.max(sd, minBandPoints)
        if nights < trustedNights { band += thinBandPoints }
        band = band.rounded()

        // Same ladder as the daily scores: never .calibrating here; .building on a thin baseline or default sleep need; .solid only with a full baseline (>= trustedNights) and an informed need.
        let confidence: ScoreConfidence =
            (nights >= trustedNights && needNights >= solidNeedNights) ? .solid : .building

        return RecoveryForecast(charge: charge, band: band, baseline: center,
                                plannedSleepHours: sleep, needHours: need,
                                nights: nights, confidence: confidence)
    }

    // MARK: - Stats

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (ddof = 1); 0 for fewer than 2 values.
    static func sampleSD(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let m = mean(values)
        var ss = 0.0
        for v in values { let d = v - m; ss += d * d }
        return (ss / Double(n - 1)).squareRoot()
    }

    /// OLS slope of value vs 0-based index; 0 for < 2 points.
    static func leastSquaresSlope(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let meanX = Double(n - 1) / 2.0
        let meanY = mean(values)
        var num = 0.0, den = 0.0
        for (i, v) in values.enumerated() {
            let dx = Double(i) - meanX
            num += dx * (v - meanY)
            den += dx * dx
        }
        return den == 0 ? 0 : num / den
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        // Return x itself on inclusive bounds so IEEE signed zero is preserved (#56).
        if x < lo { return lo }
        if x > hi { return hi }
        return x
    }
}
