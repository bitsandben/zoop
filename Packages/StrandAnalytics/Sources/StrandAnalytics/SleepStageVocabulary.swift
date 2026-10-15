/// Which stage strings mean "awake" in a stored hypnogram.
///
/// The tree carries two stage vocabularies on purpose: segment `stage` strings (`StageSegment.stage`,
/// hypnogram rows) canonicalise to "wake" (`SleepStagerV2` renames its internal "awake" on the way
/// out), while minutes-dictionary keys (`SleepStageTotals`, `SleepWindowReclip`) use "awake". Imports
/// bypass `SleepStagerV2` (Oura's phase table uses "awake"), so a bare `stage == "wake"` misfiles those
/// segments and `stage != "wake"` counts them as sleep.
///
/// A predicate, not a canonicaliser: it fixes comparisons without rewriting stored strings.
public enum SleepStageVocabulary {

    /// True for either spelling of the wake stage, ignoring case and surrounding whitespace. Use on a
    /// SEGMENT stage string; minutes dictionaries are keyed "awake" already.
    public static func isWake(_ stage: String) -> Bool {
        let s = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "wake" || s == "awake"
    }
}
