import Foundation

/// On-demand "take an HRV reading now": the single-value spot RMSSD path (#537).
///
/// Wraps `HRVAnalyzer` for the live ~60 s R-R snapshot. It uses the same cleaning pipeline and (n-1)
/// denominator (Task Force 1996) as the nightly `avgHrv`, so a spot value stays comparable to the
/// overnight number. A value is returned ONLY when enough clean beats survive; otherwise `.insufficient`.
public enum SpotHrvReading {

    /// Where the live R-R intervals came from; drives the caveat (optical PPG is noisier).
    public enum Source: Sendable {
        /// WHOOP 5/MG: R-R derived from the optical PPG waveform.
        case opticalPPG
        /// WHOOP 4 or a chest strap (e.g. Polar H10) over the standard 0x2A37 profile: electrical R-R.
        case chestStrap
        /// Source not known.
        case unknown
    }

    /// Outcome of an on-demand spot reading.
    public enum Outcome: Equatable, Sendable {
        /// A trustworthy spot value: RMSSD (ms), mean HR (or nil), clean-beat count, and the full analyzer result.
        case reading(rmssdMs: Double, hrBpm: Double?, beats: Int, full: HRVAnalyzer.HRVResult)
        /// Too few clean beats to report; carries survived vs needed counts for the UI.
        case insufficient(clean: Int, needed: Int, input: Int)
    }

    /// Computes a spot HRV reading from raw R-R intervals (ms) in capture order. Returns `.insufficient`
    /// rather than a number when too few clean beats survive.
    ///
    /// - Parameters:
    ///   - rrMs: raw R-R intervals (untrusted BLE input; the analyzer's range filter bounds-checks each).
    ///   - maxRejectedFraction: spot honesty gate (#585): refuse the reading when more than this fraction of
    ///     beats was dropped as noise. The nightly path does not use it.
    public static func compute(_ rrMs: [Int],
                               maxRejectedFraction: Double = HRVAnalyzer.defaultSpotMaxRejectedFraction) -> Outcome {
        let result = HRVAnalyzer.analyze(rawRR: rrMs.map(Double.init),
                                         maxRejectedFraction: maxRejectedFraction)
        guard let rmssd = result.rmssd else {
            return .insufficient(clean: result.nClean, needed: HRVAnalyzer.minBeats, input: result.nInput)
        }
        return .reading(rmssdMs: rmssd,
                        hrBpm: meanHrFromNN(result.meanNN),
                        beats: result.nClean,
                        full: result)
    }

    /// Mean heart rate (bpm) from the mean NN interval (ms); nil when missing or <= 0.
    public static func meanHrFromNN(_ meanNN: Double?) -> Double? {
        guard let meanNN, meanNN > 0 else { return nil }
        return 60_000.0 / meanNN
    }

    /// Source-aware caveat for a spot reading: a 60 s spot is not the overnight baseline and needs enough
    /// clean beats; optical-PPG straps add a noise note.
    public static func caveatFor(_ source: Source) -> String {
        let base =
            "This is a spot reading over a short, still capture, not your overnight HRV baseline. " +
            "Take it seated, still, and at a consistent time of day for comparable numbers, and " +
            "only a reading with enough clean beats is shown."
        switch source {
        case .opticalPPG:
            return base + " On a WHOOP 5.0/MG the intervals come from the optical pulse signal, which is " +
                "noisier than a chest strap, so treat the number as a rough estimate."
        case .chestStrap, .unknown:
            return base
        }
    }
}
