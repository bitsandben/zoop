import Foundation

/// How to satisfy one day's windowed stream read given what the previous day already read (#1538).
///
/// `analyzeRecent`'s pass-1 loop walks BACKWARDS and reads a 54-hour window per night, so consecutive windows
/// overlap by 30 hours and every row is materialised ~2.25 times per pass (field log: prep 48129 ms vs
/// score 31516 ms on a cold 21-day pass). This is the pure DECISION half; splicing stays with the caller.
///
/// The planner REFUSES rather than guesses: any case it cannot prove safe returns `.fullRead`, the
/// pre-existing behaviour. An optimisation on the scoring path may only skip work, never change a number.
public enum WindowedStreamPlan {

    /// The line emitted beside `analyzeRecent`'s `prep`/`score` split. `read` is rows fetched, `served` rows
    /// a buffer supplied. `served` near 0 means the windows are declining (truncation, an owner flip, or a
    /// dayCache gap). `truncated` separates the cause that is also a BUG: reads are `ORDER BY ts ASC LIMIT`,
    /// so a read at the cap drops the NEWEST rows and the day is scored on a window missing its tail (a field
    /// log showed 192,680 rows against the 200,000 cap).
    public static func logLine(
        hrRead: Int,
        hrServed: Int,
        hrTruncated: Int,
        rrRead: Int,
        rrServed: Int,
        rrTruncated: Int,
        hrOwnerFlips: Int = 0,
        rrOwnerFlips: Int = 0,
        hrReuseOff: Int = 0,
        rrReuseOff: Int = 0
    ) -> String {
        // #2073: `ownerFlips` separates owner changes from gaps, and `reuseOff` covers streams told not to
        // reuse at all, where served=0 is by design and not a decline.
        "analyzeRecent windows hr[read=\(hrRead) served=\(hrServed) truncated=\(hrTruncated) "
            + "ownerFlips=\(hrOwnerFlips) reuseOff=\(hrReuseOff)] "
            + "rr[read=\(rrRead) served=\(rrServed) truncated=\(rrTruncated) "
            + "ownerFlips=\(rrOwnerFlips) reuseOff=\(rrReuseOff)]"
    }

    /// What the caller should do to obtain rows for the requested window.
    public enum Plan: Equatable {
        /// Read the whole window from the store; nothing usable is buffered.
        case fullRead
        /// The buffer already covers the window; slice it, read nothing.
        case serve
        /// Read only `[readFrom, readTo]` (inclusive) and prepend it to the buffer. `readTo` is one second
        /// BELOW the buffer's start, since the store's range predicate is inclusive at both ends.
        case extend(readFrom: Int, readTo: Int)
    }

    /// Plans the read for `[from, to]` against a buffer holding `[cachedFrom, cachedTo]` for `cachedOwner`
    /// (nil = nothing buffered). `cachedTruncated` means the buffered read hit the row limit, so it can
    /// never be sliced. After the caller acts, the buffer covers exactly `[from, to]`: rows above `to` are
    /// dropped, keeping the peak footprint at one window.
    public static func plan(cachedOwner: String?,
                            cachedFrom: Int,
                            cachedTo: Int,
                            cachedTruncated: Bool,
                            owner: String,
                            from: Int,
                            to: Int) -> Plan {
        // Nothing buffered, a different owner, or a truncated buffer cannot be sliced; a wrong slice is a wrong score.
        guard let cachedOwner, cachedOwner == owner, !cachedTruncated else { return .fullRead }
        // A degenerate or inverted buffer holds nothing meaningful.
        if cachedFrom > cachedTo { return .fullRead }
        // An inverted request is not this planner's business to repair.
        if from > to { return .fullRead }
        // The buffer covers the request outright.
        if from >= cachedFrom && to <= cachedTo { return .serve }
        // The only extension this walk produces: the window moved earlier and its tail is inside the buffer.
        // Anything else reads in full rather than being reasoned about.
        if from < cachedFrom && to >= cachedFrom && to <= cachedTo {
            return .extend(readFrom: from, readTo: cachedFrom - 1)
        }
        return .fullRead
    }
}
