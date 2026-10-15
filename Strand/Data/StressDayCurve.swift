import Foundation
import StrandAnalytics

/// Scores today's stress for the surfaces that draw it, as rarely as it can.
///
/// Scoring reads today's heart rate, R-R and gravity (three reads of up to 200 000 rows). A widget
/// producer runs on the publish path (app activation, every Health sync), so nothing is read until
/// `Repository`'s cheap heart-rate fingerprint (a COUNT and a MAX over an indexed column) says today's
/// heart rate moved; otherwise the previous curve is reused.
///
/// Background callers keep the `.dayRelative` default, since resolving the personal lens reads trailing
/// days of heart rate. Today's hosted card passes its selected lens so it agrees with Stress detail.
enum StressDayCurve {

    /// What the last scoring saw and produced, swapped in as ONE immutable value so a concurrent call can
    /// never read one call's fingerprint beside another's result.
    private struct Memo {
        let count: Int
        let maxTs: Int
        let day: Int
        let personalBaseline: Bool
        let result: DaytimeStress.Result
        /// When this memo was scored, for the refresh throttle.
        let at: Date
    }

    /// Rescore at most this often. While the strap streams the fingerprint changes every second, so the
    /// fingerprint gate alone made every surface re-score the whole day on each tick.
    static let minRescoreInterval: TimeInterval = 300

    /// A scoring already under way, shared by every caller that asks meanwhile.
    @MainActor private static var inFlight: [Bool: Task<(result: DaytimeStress.Result, day: Int)?, Never>] = [:]

    /// One slot per lens. With a single slot the background publishers (default lens) and Today (selected
    /// lens) evicted each other's entry and every call missed the fingerprint gate.
    @MainActor private static var memos: [Bool: Memo] = [:]

    /// Today's curve and the local day number it belongs to, or nil when it could not be scored.
    ///
    /// Nil means "say nothing about stress right now": a caller that persists this must carry forward what
    /// it had. An EMPTY result with a day is the real "nothing scored today" answer.
    ///
    /// Returns the analytics `Result` rather than a drawing type, because the iOS widget and the Today host
    /// card (shared with macOS) both read it.
    @MainActor
    static func today(repo: Repository, now: Date = Date(),
                      calendar: Calendar = .current,
                      personalBaseline: Bool = false) async -> (result: DaytimeStress.Result, day: Int)? {
        let startOfDay = calendar.startOfDay(for: now)
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)
        let day = localDayNumber(now, calendar: calendar)

        guard let fingerprint = await repo.hrFingerprint(from: from, to: to) else { return nil }
        // Same day, same heart rate, same lens: nothing can have changed the score. The day is checked so a
        // fingerprint matching across midnight cannot serve yesterday's curve.
        if let memo = memos[personalBaseline], memo.day == day,
           memo.count == fingerprint.count, memo.maxTs == fingerprint.maxTs {
            return (memo.result, day)
        }
        if let memo = memos[personalBaseline], memo.day == day,
           now.timeIntervalSince(memo.at) < minRescoreInterval {
            return (memo.result, day)
        }
        if let running = inFlight[personalBaseline] { return await running.value }
        let task = Task { @MainActor in
            await score(repo: repo, now: now, calendar: calendar, personalBaseline: personalBaseline,
                        from: from, to: to, day: day, startOfDay: startOfDay, fingerprint: fingerprint)
        }
        inFlight[personalBaseline] = task
        let out = await task.value
        inFlight[personalBaseline] = nil
        return out
    }

    @MainActor
    private static func score(repo: Repository, now: Date, calendar: Calendar, personalBaseline: Bool,
                              from: Int, to: Int, day: Int, startOfDay: Date,
                              fingerprint: (count: Int, maxTs: Int)) async -> (result: DaytimeStress.Result, day: Int)? {

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        var scored: DaytimeStress.Result = .empty
        if hr.count >= DaytimeStress.minHourHRSamples {
            let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
            // Wrist accelerometer for the motion gate; empty without gravity, which degrades to no masking.
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
            let tz = TimeZone.current.secondsFromGMT(for: now)
            let mode = await DaytimeStressMode.selected(
                repo: repo,
                startOfToday: startOfDay,
                calendar: calendar,
                personalBaseline: personalBaseline
            )
            // Scored OFF the main actor (`runUnescalated`, not an awaited detached task, which would inherit the
            // caller's priority and race the UI for cores). This runs unprompted on activation and after every
            // Health sync, exactly when the UI is busy, so it must yield (#2181). The samples are value structs.
            // The half-step display series is requested because both readers draw a curve.
            scored = await runUnescalated {
                DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity,
                                      tzOffsetSeconds: tz, mode: mode,
                                      includeTimeline: true)
            }
        }
        // Too little signal leaves an EMPTY result, a real answer: readers drop yesterday's line.
        memos[personalBaseline] = Memo(count: fingerprint.count, maxTs: fingerprint.maxTs, day: day,
                                       personalBaseline: personalBaseline, result: scored, at: now)
        return (scored, day)
    }

    /// Days since the epoch on the LOCAL calendar.
    ///
    /// Restated from `WidgetSnapshot.localDayNumber` because no module is visible to both the widget
    /// extension and this file. The two MUST agree (the widget compares them to decide whether its stored
    /// curve is still today's); `HostedCardPrefsTests` pins them equal. Counted by the calendar, not by
    /// dividing by 86 400, which is wrong on a DST day.
    static func localDayNumber(_ date: Date, calendar: Calendar = .current) -> Int {
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: epoch,
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Drops both memo slots so a test starts from a known state.
    @MainActor
    static func resetForTest() { memos.removeAll() }
}
