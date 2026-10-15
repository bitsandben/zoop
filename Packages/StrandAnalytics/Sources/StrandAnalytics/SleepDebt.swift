import Foundation

// SleepDebt.swift — recency-weighted sleep-debt estimate over the last N nights.
//
// Pure and DB-free. Given per-night total sleep (minutes) and a personal need (hours), it keeps a
// running debt over a capped trailing window (14 nights): 55% of any unmet need carries into the
// next night's need, and results under ten minutes clear to zero.
//
// A planning estimate, not a physiological claim: meeting base need plus the current estimate clears
// the debt, and extra sleep never creates a surplus. Nights with no usable total are skipped (no
// zero-fill), so a wear gap never reads as a full night of debt. The caller supplies the need.

/// One night's contribution: day key, minutes slept, and the signed delta against need.
public struct SleepDebtNight: Equatable, Sendable {
    /// "yyyy-MM-dd" day key for the night.
    public let day: String
    /// Total sleep for the night (minutes).
    public let sleptMin: Double
    /// sleptMin − needMin (minutes); positive = surplus.
    public let deltaMin: Double

    public init(day: String, sleptMin: Double, deltaMin: Double) {
        self.day = day; self.sleptMin = sleptMin; self.deltaMin = deltaMin
    }
}

/// The sleep-debt estimate over the capped trailing window.
public struct SleepDebtLedger: Equatable, Sendable {
    /// Current estimate in the signed UI convention: negative = debt, zero = on target. Never positive.
    public let balanceMin: Double
    /// Per-night contributions, oldest → newest; skipped nights are absent.
    public let nights: [SleepDebtNight]
    /// Personal sleep need (minutes) the ledger was computed against.
    public let needMin: Double

    public init(balanceMin: Double, nights: [SleepDebtNight], needMin: Double) {
        self.balanceMin = balanceMin; self.nights = nights; self.needMin = needMin
    }

    public var nightCount: Int { nights.count }
    /// True when the net balance is a debt.
    public var isDebt: Bool { balanceMin < 0 }
    public var magnitudeMin: Double { abs(balanceMin) }
}

public enum SleepDebt {

    /// Trailing two weeks: recent enough to be actionable, short enough that a rough patch doesn't
    /// compound for months.
    public static let defaultWindowNights: Int = 14

    /// Share of the unmet need carried into the following night.
    public static let debtCarryFactor: Double = 0.55

    /// Debts smaller than this (minutes) are too small to be actionable.
    public static let minimumDebtMin: Double = 10.0

    /// "On target" deadband (minutes): a smaller |balance| reads as balanced.
    public static let onTargetBandMin: Double = minimumDebtMin

    /// Sleep credited toward debt for one day. Naps add repayment credit without changing the canonical
    /// `mainSleepMin`; a day with no usable main sleep stays missing, and a negative nap total is ignored.
    public static func creditedSleepMin(mainSleepMin: Double?, napSleepMin: Double = 0) -> Double? {
        guard let mainSleepMin, mainSleepMin > 0 else { return nil }
        return mainSleepMin + max(napSleepMin, 0)
    }

    /// Debt values oldest → newest for local fallback surfaces. Each usable day is recomputed from the
    /// trailing `window` usable nights; an imported value wins verbatim for that day's output only and
    /// never seeds the recurrence. Imported-only rows don't consume a usable-night slot; rows with
    /// neither usable sleep nor an imported value are omitted.
    public static func debtSeries(
        series: [(day: String, totalSleepMin: Double?)],
        needHours: Double = AnalyticsEngine.Rest.defaultNeedHours,
        importedDebtMin: [String: Double] = [:],
        window: Int = defaultWindowNights
    ) -> [(day: String, value: Double)] {
        let cap = max(window, 1)
        var usableHistory: [(day: String, totalSleepMin: Double?)] = []
        usableHistory.reserveCapacity(cap)
        var result: [(day: String, value: Double)] = []
        result.reserveCapacity(series.count)

        for row in series {
            let sleptMin = row.totalSleepMin.flatMap { $0 > 0 ? $0 : nil }
            if let sleptMin {
                usableHistory.append((row.day, sleptMin))
                if usableHistory.count > cap { usableHistory.removeFirst() }
            }

            if let imported = importedDebtMin[row.day] {
                result.append((row.day, imported))
            } else if sleptMin != nil {
                let debt = ledger(series: usableHistory, needHours: needHours, window: cap).magnitudeMin
                result.append((row.day, debt))
            }
        }
        return result
    }

    /// Build the ledger from a chronological `[(day, totalSleepMin?)]` series (oldest → newest).
    ///
    /// - Parameters:
    ///   - series: a nil or non-positive `totalSleepMin` marks a night with no usable data; it is skipped.
    ///   - needHours: personal sleep need, defaulting to `AnalyticsEngine.Rest.defaultNeedHours`.
    ///   - window: most-recent COUNTED nights to include (default 14, clamped to ≥ 1).
    ///
    /// Per retained night, `nextDebt = 0.55 × max(0, need + debt − slept)`; results below ten minutes
    /// clear to zero. `SleepDebtNight.deltaMin` stays the raw `slept − base need` used by the bars.
    public static func ledger(series: [(day: String, totalSleepMin: Double?)],
                              needHours: Double = AnalyticsEngine.Rest.defaultNeedHours,
                              window: Int = defaultWindowNights) -> SleepDebtLedger {
        let needMin = max(needHours, 0.0) * 60.0
        let cap = max(window, 1)

        // Keep nights with usable sleep, then take the most-recent `cap`.
        let usable = series.filter { ($0.totalSleepMin ?? 0) > 0 }
        let windowed = usable.suffix(cap)

        var nights: [SleepDebtNight] = []
        nights.reserveCapacity(windowed.count)
        var debt = 0.0
        for row in windowed {
            let slept = row.totalSleepMin ?? 0
            let delta = slept - needMin
            let calculatedDebt = debtCarryFactor * max(0, needMin + debt - slept)
            debt = calculatedDebt < minimumDebtMin ? 0 : calculatedDebt
            nights.append(SleepDebtNight(day: row.day, sleptMin: slept, deltaMin: delta))
        }
        return SleepDebtLedger(balanceMin: round1(-debt), nights: nights, needMin: needMin)
    }

    // MARK: - Need tonight

    /// Tonight's sleep need and what it is made of, in minutes.
    public struct NeedTonight: Equatable, Sendable {
        public let totalMin: Double
        public let baseMin: Double
        public let strainMin: Double
        public let debtMin: Double
    }

    /// Strain (0–21 scale) above this adds sleep need.
    public static let strainFreeUpTo: Double = 10.0
    /// Extra minutes per strain point above `strainFreeUpTo`, so a maximal day asks ~45 min more.
    public static let minutesPerStrainPoint: Double = 4.0
    /// Most debt asked back in one night. Without a bound a long run of short nights would ask for an
    /// impossible night; the rest of the estimate stays on the ledger for the nights after.
    public static let maxDebtRepayPerNightMin: Double = 120.0

    /// Tonight's need: base need, a strain add-on, and the ledger's current debt estimate.
    ///
    /// The debt part is the ledger's own (already 55 % carried): asking back a different share would make
    /// the plan and the debt figure disagree. `debtMin` is the ledger magnitude (≥ 0), `strain21` today's
    /// strain on 0–21 (nil when unknown).
    public static func needTonight(baseNeedMin: Double, strain21: Double?, debtMin: Double) -> NeedTonight {
        let strainMin = max(0, ((strain21 ?? 0) - strainFreeUpTo) * minutesPerStrainPoint)
        let debtPart = min(maxDebtRepayPerNightMin, max(0, debtMin))
        return NeedTonight(totalMin: baseNeedMin + strainMin + debtPart, baseMin: baseNeedMin,
                           strainMin: strainMin, debtMin: debtPart)
    }

    /// Round to 1 decimal place.
    static func round1(_ v: Double) -> Double { (v * 10.0).rounded() / 10.0 }
}
