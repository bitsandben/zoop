import Foundation

// CorrelationEngine.swift - relationships between two daily series.
//
// Pure, DB-free. Pearson r, an OLS line (y on x) and an approximate two-sided p-value for r.
// The p-value uses t = r*sqrt((n-2)/(1-r^2)) with a NORMAL approximation of the tail
// (2*(1-Phi(|t|)), Phi via Abramowitz & Stegun 7.1.26). For small n the true Student-t tails are
// heavier, so pApprox slightly understates p; it is deterministic and needs no tables.
// `alignByDay` inner-joins two "yyyy-MM-dd" series; `lagged` pairs x on day D with y on day D+lag.

/// The result of correlating two aligned series.
public struct Correlation: Equatable, Sendable {
    public let r: Double
    public let n: Int
    /// Approximate two-sided p-value for H0: r = 0 (normal approximation).
    public let pApprox: Double
    public let slope: Double
    public let intercept: Double

    public init(r: Double, n: Int, pApprox: Double, slope: Double, intercept: Double) {
        self.r = r
        self.n = n
        self.pApprox = pApprox
        self.slope = slope
        self.intercept = intercept
    }
}

public enum CorrelationEngine {

    // MARK: - Pearson + regression

    /// Pearson r plus an OLS line and approximate p-value. Nil with fewer than 3 pairs or zero
    /// variance in either variable.
    public static func pearson(_ xy: [(Double, Double)]) -> Correlation? {
        let n = xy.count
        guard n >= 3 else { return nil }
        let nD = Double(n)

        var sumX = 0.0, sumY = 0.0
        for p in xy { sumX += p.0; sumY += p.1 }
        let meanX = sumX / nD
        let meanY = sumY / nD

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in xy {
            let dx = p.0 - meanX
            let dy = p.1 - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }

        guard sxx > 0 && syy > 0 else { return nil }

        var r = sxy / (sxx.squareRoot() * syy.squareRoot())
        // Clamp floating-point overshoot so |r| <= 1.
        if r > 1.0 { r = 1.0 }
        if r < -1.0 { r = -1.0 }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        let p = pValue(r: r, n: n)

        return Correlation(r: r, n: n, pApprox: p, slope: slope, intercept: intercept)
    }

    // MARK: - Day alignment

    /// Inner-joins two "yyyy-MM-dd" series on the day key; (x, y) pairs for days in both, sorted by
    /// day. The last entry wins for a duplicated day.
    public static func alignByDay(_ a: [(day: String, value: Double)],
                                  _ b: [(day: String, value: Double)]) -> [(Double, Double)] {
        var mapA: [String: Double] = [:]
        for row in a { mapA[row.day] = row.value }
        var mapB: [String: Double] = [:]
        for row in b { mapB[row.day] = row.value }

        let commonDays = mapA.keys.filter { mapB[$0] != nil }.sorted()
        return commonDays.map { (mapA[$0]!, mapB[$0]!) }
    }

    // MARK: - Lagged correlation

    /// Correlates x[day] against y[day + lagDays] (positive lag: does x today predict y later).
    /// Nil when fewer than 3 pairs survive or `pearson` rejects them.
    public static func lagged(x: [(day: String, value: Double)],
                              y: [(day: String, value: Double)],
                              lagDays: Int) -> Correlation? {
        var mapY: [String: Double] = [:]
        for row in y { mapY[row.day] = row.value }

        var pairs: [(Double, Double)] = []
        // Sort for deterministic pair order.
        let sortedX = x.sorted { $0.day < $1.day }
        for row in sortedX {
            guard let shifted = shiftDay(row.day, by: lagDays) else { continue }
            if let yv = mapY[shifted] {
                pairs.append((row.value, yv))
            }
        }
        return pearson(pairs)
    }

    // MARK: - p-value

    /// Two-sided p-value for H0: r = 0. n <= 2 gives 1.0; |r| = 1 gives 0.0.
    static func pValue(r: Double, n: Int) -> Double {
        guard n > 2 else { return 1.0 }
        let oneMinusR2 = 1.0 - r * r
        if oneMinusR2 <= 0 { return 0.0 }  // |r| == 1
        let t = r * (Double(n - 2) / oneMinusR2).squareRoot()
        return 2.0 * (1.0 - normalCDF(abs(t)))
    }

    static func normalCDF(_ z: Double) -> Double {
        0.5 * (1.0 + erfApprox(z / 2.0.squareRoot()))
    }

    /// erf(x) — Abramowitz & Stegun 7.1.26, |error| ≤ 1.5e-7.
    static func erfApprox(_ x: Double) -> Double {
        let sign = x < 0 ? -1.0 : 1.0
        let ax = abs(x)
        let t = 1.0 / (1.0 + 0.3275911 * ax)
        let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
                        - 0.284496736) * t + 0.254829592) * t * exp(-ax * ax)
        return sign * y
    }

    // MARK: - Day arithmetic

    /// Shifts a "yyyy-MM-dd" string by `delta` days (UTC calendar, timezone-free); nil if unparseable.
    static func shiftDay(_ day: String, by delta: Int) -> String? {
        if delta == 0 { return day }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }

        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: comps),
              let shifted = cal.date(byAdding: .day, value: delta, to: base) else { return nil }
        let out = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let oy = out.year, let om = out.month, let od = out.day else { return nil }
        return String(format: "%04d-%02d-%02d", oy, om, od)
    }
}
