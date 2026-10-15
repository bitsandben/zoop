import Foundation

/// A forced re-score that arrived while another pass held the engine. Callers queued behind one
/// pass collapse into this single follow-up, keeping the strongest gate and the deciding caller's name.
struct QueuedRescore: Equatable {
    /// True when a queued caller needs the pass to run whatever the fingerprint says (an edit, import
    /// or recalibrate); false when all only asked "re-score if new data landed".
    let unconditional: Bool
    /// The trigger name the follow-up is logged under.
    let label: String

    /// Folds one more caller into the queue. An unconditional caller upgrades a gated queue and names
    /// the pass; otherwise the first caller keeps the name.
    static func merge(_ existing: QueuedRescore?, unconditional: Bool, label: String) -> QueuedRescore {
        guard let existing else { return QueuedRescore(unconditional: unconditional, label: label) }
        if unconditional && !existing.unconditional {
            return QueuedRescore(unconditional: true, label: label)
        }
        return existing
    }

    /// The trigger name a re-score is logged under: the caller's own label, else derived from its gate.
    static func triggerName(force: Bool, skipIfUnchanged: Bool, label: String?) -> String {
        label ?? (!force ? "idle" : (skipIfUnchanged ? "post-offload" : "forced"))
    }
}
