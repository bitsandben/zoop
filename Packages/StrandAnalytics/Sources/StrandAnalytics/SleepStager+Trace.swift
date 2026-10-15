import Foundation

// SleepStager+Trace.swift - the per-candidate-run GATE TRACE formatter (Sleep & Rest test mode).
//
// Pure string builders that never touch detection state, so a fixture night's exact line can be
// asserted. Emitters are gated by TestCentre.active(.sleep) at the detectSleep call site and exit
// through the redacting sink. Counts and seconds only, no wall-clock.

extension SleepStager {

    /// Whether a candidate in-bed run survived a gate or was dropped by it.
    public enum GateVerdict: String, Sendable { case kept = "KEPT", dropped = "DROPPED" }

    /// The gate-trace line formatters. Compact and parseable.
    public enum GateTrace {

        /// Why the HR-only spine did or did not run. The funnel line only exists when the spine is CALLED, so
        /// its absence was ambiguous (gate never opened vs sink never wired); this says which.
        ///
        /// `day` leads the line: a re-score emits one per night in quick succession, and without the date the
        /// block cannot be attributed to a night.
        public static func hrOnlyGateLine(day: String, attempted: Bool, reason: String,
                                          gravRows: Int, storedNights: Int) -> String {
            "[sleep] hr-only gate day=\(day) attempted=\(attempted) reason=\(reason) "
                + "grav=\(gravRows) stored=\(storedNights)"
        }

        /// The HR-only spine's own funnel line. Its numbers separate a band too tight (`sleepRuns` near zero)
        /// from a duration gate eating real runs (`sleepRuns` high, `longestMin` under `minSleepMin`).
        /// `anchorBpm` and `bandBpm` are printed because they are DERIVED per window (a percentile), not
        /// configured. `day` leads, as on the gate line.
        public static func hrOnlyLine(day: String, anchorBpm: Double?, bandBpm: Double?,
                                      hrP50: Double?, hrP90: Double?, epochs: Int,
                                      runs: Int, mergedRuns: Int, sleepRuns: Int,
                                      longestSleepMin: Int, staged: Int, kept: Int,
                                      minSleepMin: Int) -> String {
            "[sleep] hr-only spine day=\(day) anchorBpm=\(round1(anchorBpm)) bandBpm=\(round1(bandBpm)) "
                + "hrP50=\(round1(hrP50)) hrP90=\(round1(hrP90)) "
                + "epochs=\(epochs) runs=\(runs) merged=\(mergedRuns) sleepRuns=\(sleepRuns) "
                + "longestMin=\(longestSleepMin) staged=\(staged) kept=\(kept) minSleepMin=\(minSleepMin)"
        }

        /// One decimal by ARITHMETIC rather than `String(format:)`, so the output is deterministic IEEE
        /// arithmetic instead of printf's half-to-even on the binary value (which disagreed with a
        /// decimal HALF_UP on 64.05). Non-negative only: `-0.5` would print "0.5" (truncating division
        /// loses the sign to `abs`); every caller is a bpm.
        private static func round1(_ v: Double?) -> String {
            guard let v else { return "nil" }
            let tenths = Int((v * 10.0).rounded())
            return "\(tenths / 10).\(abs(tenths % 10))"
        }

        /// One verdict line for a candidate run. `gate` names the constant that decided it; `detail` carries
        /// that gate's numbers. `startTs`/`endTs` are seconds only (the sink scrubs identifiers).
        public static func runLine(index: Int, startTs: Int, endTs: Int,
                                   verdict: GateVerdict, gate: String, detail: String) -> String {
            let spanS = max(0, endTs - startTs)
            return "gate run=\(index) spanS=\(spanS) \(verdict.rawValue) gate=\(gate) \(detail)"
        }

        /// One per-epoch wake<->sleep flip and the threshold it crossed.
        public static func flipLine(epoch: Int, from: String, to: String, threshold: String) -> String {
            "epoch=\(epoch) flip \(from)->\(to) threshold=\(threshold)"
        }
    }

    /// Round to 2 decimal places for trace detail fields (formatting only, never a scoring path).
    static func round2(_ v: Double) -> Double { (v * 100.0).rounded() / 100.0 }
}
