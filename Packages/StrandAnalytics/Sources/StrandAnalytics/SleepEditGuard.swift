import Foundation

/// Pure guards for the hand-edit sleep-time pickers. A time-only picker edit keeps the calendar DATE,
/// so correcting a late night's bed time could land it on the coming evening: a future-dated night whose
/// staged window came back all-awake and blanked the Sleep tab. Three layered rules:
///   1. `autoCorrectedBed`: a time-only roll that lands the bed in the future, or at/after the night's
///      wake, almost always means the previous evening; decrement the date.
///   2. `isDisjoint`: a window with no overlap of the night's recorded coverage needs explicit confirm.
///   3. `clampedEditWindow`: repository backstop; no path may persist a future or inverted window.
public enum SleepEditGuard {

    /// The longest night span (seconds) the at/after-wake auto-correct will manufacture. A real evening-bed
    /// fix yields ~6 h; moving a nap LATER past its wake would yield ~23 h if decremented, which is not a
    /// plausible night, so those candidates are left verbatim.
    public static let maxAutoCorrectNightSec: TimeInterval = 16 * 3600

    /// Rule 1: cross-midnight bed auto-correct. A deliberate date change (`previousBed` on a different
    /// calendar day) is always respected. For a time-only change, the candidate moves one day back when
    /// it is impossible for a bed time and that lands in the past:
    ///   - the candidate is in the FUTURE (also the "Add a nap" case, `originalWake == nil`);
    ///   - the candidate is at/after `originalWake` AND the decremented bed forms a plausible night
    ///     (before the wake, within `maxAutoCorrectNightSec`), so a legitimate move-later edit isn't
    ///     shoved back a full day.
    public static func autoCorrectedBed(previousBed: Date, candidateBed: Date, originalWake: Date?,
                                        now: Date, calendar: Calendar = .current) -> Date {
        guard calendar.isDate(candidateBed, inSameDayAs: previousBed) else { return candidateBed }
        guard let decremented = calendar.date(byAdding: .day, value: -1, to: candidateBed),
              decremented <= now else { return candidateBed }
        let futureViolation = candidateBed > now
        let wakeViolation: Bool = {
            guard let wake = originalWake, candidateBed >= wake else { return false }
            return decremented < wake && wake.timeIntervalSince(decremented) <= maxAutoCorrectNightSec
        }()
        guard futureViolation || wakeViolation else { return candidateBed }
        return decremented
    }

    /// Rule 2: true when `[newStart, newEnd)` shares nothing with the night's recorded coverage
    /// `[coverageStart, coverageEnd)` (unix seconds). Accepting it silently would fabricate an all-awake
    /// phantom night, so the UI must confirm.
    public static func isDisjoint(newStart: Int, newEnd: Int,
                                  coverageStart: Int, coverageEnd: Int) -> Bool {
        newEnd <= coverageStart || newStart >= coverageEnd
    }

    /// The maximum duration of an edited sleep window; an unbounded date change can re-bucket stages and
    /// totals onto unrelated days.
    public static let maxEditWindowSec: Int = 24 * 3600

    /// Rule 3: caps the corrected wake at `now + slackSec` (a sleep cannot END in the future; slack
    /// absorbs clock skew) and returns nil for a window that is inverted, spans more than a day, or is
    /// entirely in the future once capped. The editor's guards should make this unreachable.
    public static func clampedEditWindow(start: Int, end: Int, now: Int,
                                         slackSec: Int = 300) -> (start: Int, end: Int)? {
        let cappedEnd = min(end, now + slackSec)
        guard cappedEnd > start, cappedEnd - start <= maxEditWindowSec else { return nil }
        return (start, cappedEnd)
    }
}
