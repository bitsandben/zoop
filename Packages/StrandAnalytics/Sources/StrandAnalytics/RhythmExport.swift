import Foundation

// Plain-text (CSV) export of the descriptive rhythm-screening data (#1298, the "share with my clinician" path):
// formats the already-computed, on-device RhythmScreener output (per-window regularity statistics + night roll-up).
//
// Non-clinical by construction: the artifact carries the non-diagnostic disclaimer as a header comment, emits
// only the engine's neutral labels (steady / occasionalEctopy / varied / unreadable), and names no condition,
// verdict, probability or call-to-action. The numbers come from the pure RhythmScreener and `num` pre-rounds, so
// an iPhone and an Android export of the same night are identical. Pure, no clock, no I/O.
public enum RhythmExport {

    /// The disclaimer stamped on every export, verbatim from the Rhythm screen's copy.
    public static let disclaimer: String =
        "Zoop Rhythm export — experimental wellness visualization, NOT a diagnosis. Not an ECG and "
        + "not a medical device; it cannot detect any heart condition. Beat-to-beat variation has many "
        + "ordinary, benign causes (breathing, movement, an imperfect optical reading, or the occasional "
        + "extra or skipped beat most healthy people have). Everything was computed on your device. "
        + "Share with a qualified professional if you wish; in an emergency, contact your local emergency service."

    static let header =
        "window,beats,sd1_ms,sd2_ms,sd1_sd2,norm_rmssd,turning_point_rate,ectopic_fraction,label,confidence"

    /// Builds the CSV text for a night: a commented disclaimer and summary block, then one row per window
    /// (1-indexed, night order). A nil statistic (unreadable window) exports as an empty field, never a fabricated 0.
    public static func csv(summary: RhythmScreener.NightRhythmSummary,
                           windows: [RhythmScreener.WindowResult]) -> String {
        var lines: [String] = []
        for chunk in disclaimer.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("# \(chunk)")
        }
        lines.append("#")
        lines.append("# summary: readableWindows=\(summary.readableWindows) steady=\(summary.steadyWindows) "
            + "occasional=\(summary.occasionalWindows) varied=\(summary.variedWindows) "
            + "overall=\(summary.overall.rawValue) variationRecurred=\(summary.variationRecurred)")
        lines.append("#")
        lines.append(header)
        for (i, w) in windows.enumerated() {
            lines.append([
                String(i + 1),
                String(w.nBeats),
                num(w.sd1), num(w.sd2), num(w.sd1sd2), num(w.normRmssd),
                num(w.turningPointRate), num(w.ectopicFraction),
                w.label.rawValue, w.confidence.rawValue,
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Formats an optional statistic to 3 decimals ("" when unreadable). Pre-rounds half-away-from-zero before
    /// `%.3f` because `String(format:)` rounds half-to-even and would diverge from Java's half-up (0.0625 -> 0.062 vs 0.063).
    private static func num(_ x: Double?) -> String {
        guard let x else { return "" }
        return String(format: "%.3f", (x * 1000).rounded() / 1000)
    }
}
