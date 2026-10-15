import Foundation

/// The days a date axis puts a mark on: day-aligned, distinct, newest always among them. For charts whose
/// x-axis spans DAYS; hour-spanning charts want time marks instead.
public enum ChartAxisDays {

    /// Day marks for the axis, walking BACK from the newest day so it is always labelled, then ascending as
    /// `AxisMarks(values:)` expects. Explicit dates rather than `.automatic(desiredCount:)` (sub-day strides
    /// put duplicate labels in one day) or `.stride(by:)` (steps from the LOWER bound, leaving the newest
    /// day unlabelled, and can widen the inferred domain).
    public static func spanning(_ dates: [Date],
                                targetLabels: Int = 5,
                                calendar: Calendar = .current) -> [Date] {
        guard targetLabels > 0, let first = dates.min(), let last = dates.max() else { return [] }
        let lo = calendar.startOfDay(for: first)
        let hi = calendar.startOfDay(for: last)
        let span = calendar.dateComponents([.day], from: lo, to: hi).day ?? 0
        guard span > 0 else { return [hi] }
        // Days INCLUSIVE of both ends: a 4-day span carries 5 days.
        let stride = max(1, Int((Double(span + 1) / Double(targetLabels)).rounded(.up)))
        var days: [Date] = []
        var day = hi
        while day >= lo {
            days.append(day)
            guard let previous = calendar.date(byAdding: .day, value: -stride, to: day) else { break }
            // Re-anchored every step: a day-add preserves time of day, and in zones that shift clocks at midnight
            // the 00:00 target may not exist (Foundation returns 01:00), which every later mark would inherit.
            day = calendar.startOfDay(for: previous)
        }
        return days.reversed()
    }
    /// Whether the axis labels need a YEAR to stay distinct. Day-only labels collide for marks exactly a year
    /// apart (e.g. an ALL range over ~4 years), so this is asked of the MARKS, not the span.
    public static func needsYear(_ marks: [Date], calendar: Calendar = .current) -> Bool {
        let monthDays = marks.map { mark -> String in
            let parts = calendar.dateComponents([.month, .day], from: mark)
            return "\(parts.month ?? 0)-\(parts.day ?? 0)"
        }
        return Set(monthDays).count != monthDays.count
    }

    /// The label format for a set of marks: day-only, with the year added when [needsYear] says they would collide.
    /// Shared so every date axis formats the same marks identically.
    public static func labelFormat(for marks: [Date], calendar: Calendar = .current) -> Date.FormatStyle {
        needsYear(marks, calendar: calendar)
            ? .dateTime.month(.abbreviated).day().year(.twoDigits)
            : .dateTime.month(.abbreviated).day()
    }

}
