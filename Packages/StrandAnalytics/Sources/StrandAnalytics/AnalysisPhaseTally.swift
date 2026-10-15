import Foundation

/// Per-phase timing of an `analyzeRecent` pass after its per-day loop (baseline folds, pass 2, persist,
/// weekly metrics, sleep writes, workout rescore), so the dominant phase names itself.
public enum AnalysisPhaseTally {
    /// Render ordered `(name, seconds)` phases as one line in milliseconds, in execution order. The
    /// phases need not sum to the pass total; the difference marks unmeasured work. `scope` names what
    /// was bracketed so a partial measurement does not misreport itself.
    public static func logLine(scope: String, _ phases: [(name: String, seconds: Double)]) -> String {
        let parts = phases.map { "\($0.name)=\(millis($0.seconds))ms" }
        let total = phases.reduce(0.0) { $0 + $1.seconds }
        return "analyzeRecent \(scope) total=\(millis(total))ms "
            + (parts.isEmpty ? "(no phases)" : parts.joined(separator: " "))
    }

    /// Seconds to whole milliseconds, floored at zero: a backwards wall-clock step would otherwise
    /// produce a negative interval where rounding conventions diverge.
    private static func millis(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 1000).rounded())
    }
}
