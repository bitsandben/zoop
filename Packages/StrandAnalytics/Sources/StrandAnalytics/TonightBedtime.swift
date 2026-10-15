import Foundation

// MARK: - Recommended bedtime tonight (the one resolver)
//
// The sleep planner, Today's evening card, the coach and the wind-down reminder all name a bedtime for
// tonight. They read it from here, so no screen can show 20:18 while the coach says 22:15.

public enum TonightBedtime {

    /// The usual bedtime: median of the last 14 nights' bedtimes (signed minutes, evening negative),
    /// as a minute of the day. Nil with fewer than three nights.
    public static func usualMinute(signedBedtimes: [Double]) -> Int? {
        let recent = signedBedtimes.suffix(14).sorted()
        guard recent.count >= 3 else { return nil }
        return Int(SleepInsights.clock(fromSigned: recent[recent.count / 2]).rounded())
    }

    /// Wake time minus the planned time in bed, kept within reach of the usual bedtime
    /// (`CoachMorningRules.reasonableBedtime`: at most an hour earlier, not before 21:00 unless that is
    /// the habit, rounded to the quarter hour). Minute of the day.
    public static func recommendedMinute(wakeMinute: Int, inBedMinutes: Double, usualMinute: Int?) -> Int {
        let raw = wakeMinute - Int(inBedMinutes.rounded())
        return CoachMorningRules.reasonableBedtime(raw, usual: usualMinute)
    }
}
