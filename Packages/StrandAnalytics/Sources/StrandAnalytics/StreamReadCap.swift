import Foundation

/// Per-stream read caps for the `analyzeRecent` sliding windows (#1538).
///
/// A single 200,000 cap sized for HR let ten R-R windows (21 nights, WHOOP 5/MG) come back AT the cap. The
/// read is `ORDER BY ts ASC LIMIT`, so the NEWEST rows were dropped and every HRV number from those windows
/// was computed on a night missing its tail, silently. R-R arrives in BURSTS (average below HR's 1/s, peaks
/// far above), and HR's full 54-hour window (~194,400 rows) sat only 3% under the cap. Caps are therefore
/// sized to what a window can PEAK at; the rate constants are deliberately generous ceilings.
///
/// Invariant: a cap must exceed what a full window can legitimately hold, or a complete read is
/// indistinguishable from a truncated one. `capExceedsFullWindow` pins this per stream. The cap is a
/// ceiling, not an allocation.
public enum StreamReadCap {

    /// How far BEFORE the day boundary the pass reads. EVERY lookback in the engine takes this value (per-day
    /// `from`, window start, skin-anchor scan) so the window and the caps derived from it cannot drift apart.
    public static let lookbackSeconds = 30 * 3_600

    /// How far AFTER the day boundary, capped at `now` for a day in progress.
    public static let forwardSeconds = 24 * 3_600

    /// The per-day read window: `dayStart - 30h` through the night, i.e. 54 hours.
    public static let windowSeconds = lookbackSeconds + forwardSeconds

    /// HR: one sample per second.
    public static let hrRowsPerSecond = 1.0

    /// R-R at its PEAK. The average is below 1/s (bursts), but bursts reach a cap, and #1008's cross-second
    /// overcount can double a burst. A ceiling, not typical density.
    public static let rrRowsPerSecond = 2.0

    /// Gravity: one sample per second over the same 54-hour window (a field capture measured 192,698 rows,
    /// 96% of the old shared cap). Most dangerous: it is a PLAIN read, not a `SlidingStreamWindow`, so nothing
    /// counts a truncation, and a clip mis-stages a night.
    public static let gravityRowsPerSecond = 1.0

    /// Headroom over a full window, so a legitimate read cannot land ON the cap and look truncated.
    public static let headroom = 1.5

    /// Cap on the sleep engine's skin-temp reads, named so the no-night line can say when one came back AT it.
    /// Not derived from a row rate: skin density was never measured (gravity ranged 177 to 192,698 rows across
    /// 54 h in one capture). Shared by the night-window read and the ~21-day WHOOP 4.0 anchor scan; only the
    /// window read's count reaches the no-night line, so a clipped anchor scan goes unreported.
    public static let skin = 200_000

    /// The cap for a stream producing `rowsPerSecond` at its densest.
    public static func cap(rowsPerSecond: Double) -> Int {
        Int((Double(windowSeconds) * rowsPerSecond * headroom).rounded(.up))
    }

    /// 291,600: a full HR window plus half again. STORED, not computed, so the read cap and the truncation
    /// threshold are provably one value.
    public static let hr = cap(rowsPerSecond: hrRowsPerSecond)

    /// 583,200: a full R-R window at its densest, plus half again. Stored like `hr`.
    public static let rr = cap(rowsPerSecond: rrRowsPerSecond)

    /// 291,600: same shape as `hr`. Only the 54-hour read needs it; day-scoped gravity reads span 24 hours.
    public static let gravity = cap(rowsPerSecond: gravityRowsPerSecond)
}
