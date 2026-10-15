import Foundation

/// How the Sleep hero names the night it is showing. Only the arithmetic lives here; the wording stays
/// in the view because it returns a `LocalizedStringKey` whose literals must remain in source for
/// catalogue extraction.
public enum SleepNightLabel {

    /// How many nights back the carousel entry at `offset` is FROM TODAY.
    ///
    /// Measured from today, not the newest recorded night: anchoring on the newest made offset 0 always
    /// zero, so the hero read "Last night" over a night days old.
    ///
    /// `wakeTimestamps` is newest-first, one per carousel entry, optional so an entry with no session falls
    /// back to the offset. `today` must be the LOGICAL day (04:00 roll) and the wake instants must NOT be
    /// rolled: rolling both could collapse two distinct entries onto one label.
    ///
    /// A negative distance is normal (between waking before 04:00 and the roll, the night's calendar date is
    /// already tomorrow logically); falling back to the offset is correct there.
    public static func nightsAgo(
        wakeTimestamps: [Int?],
        offset: Int,
        today: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard offset >= 0, offset < wakeTimestamps.count,
              let shownTs = wakeTimestamps[offset] else { return offset }
        let shown = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(shownTs)))
        let todayStart = calendar.startOfDay(for: today)
        let d = calendar.dateComponents([.day], from: shown, to: todayStart).day ?? offset
        return d >= 0 ? d : offset
    }
}
