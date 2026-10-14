import Foundation

/// A forced re-score that arrived while another pass held the engine. Every caller queued behind one
/// pass collapses into this single follow-up, which keeps the strongest gate any of them asked for and
/// the name of the caller that decided it, so the strap log attributes the follow-up correctly.
struct QueuedRescore: Equatable {
    /// True when at least one queued caller needs the pass to run whatever the fingerprint says
    /// (an edit, an import, a recalibrate). False when every caller only asked "re-score if new data
    /// landed", which the follow-up can still answer with the fingerprint gate.
    let unconditional: Bool
    /// The trigger name the follow-up is logged under.
    let label: String

    /// Folds one more caller into the queue. An unconditional caller upgrades a gated queue and names
    /// the pass, because it is the reason the pass now runs; otherwise the first caller keeps the name.
    static func merge(_ existing: QueuedRescore?, unconditional: Bool, label: String) -> QueuedRescore {
        guard let existing else { return QueuedRescore(unconditional: unconditional, label: label) }
        if unconditional && !existing.unconditional {
            return QueuedRescore(unconditional: true, label: label)
        }
        return existing
    }

    /// The trigger name a re-score is logged under. A caller that passes its own label wins; otherwise
    /// the name is derived from how it gated the pass.
    static func triggerName(force: Bool, skipIfUnchanged: Bool, label: String?) -> String {
        label ?? (!force ? "idle" : (skipIfUnchanged ? "post-offload" : "forced"))
    }
}
