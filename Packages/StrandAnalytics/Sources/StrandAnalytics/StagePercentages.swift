/// Largest-remainder (Hamilton) apportionment of parts into whole percentages that sum to exactly 100.
///
/// Rounding each share independently can total 99 or 101; this floors every share, then gives leftover
/// units to the largest fractional remainders (ties: lower index first).
public enum StagePercentages {

    /// `parts` are raw non-negative magnitudes (e.g. stage minutes) in a FIXED order; the result lines up with
    /// them. Nil when the total is <= 0, so the caller shows no share rather than an unmeasured `0%`.
    public static func wholePercentages(_ parts: [Double]) -> [Int]? {
        let clamped = parts.map { Swift.max(0, $0) }
        let total = clamped.reduce(0, +)
        guard total > 0 else { return nil }

        let raw = clamped.map { $0 / total * 100 }
        var whole = raw.map { Int($0.rounded(.down)) }
        var remaining = 100 - whole.reduce(0, +)   // the fractional units the floors dropped; in 0..<count
        guard remaining > 0 else { return whole }

        // Largest remainder first; ties by lower index.
        let order = raw.indices.sorted { i, j in
            let fi = raw[i] - Double(whole[i])
            let fj = raw[j] - Double(whole[j])
            if fi != fj { return fi > fj }
            return i < j
        }
        var k = 0
        while remaining > 0 && k < order.count {
            whole[order[k]] += 1
            remaining -= 1
            k += 1
        }
        return whole
    }
}
