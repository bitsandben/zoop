import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Patterns (the typical day, workdays and weekend)
//
// Over the last weeks rather than today: when stress usually peaks and settles, and whether the
// weekend differs from the working week. Each card leads with its chart, says one sentence, and opens
// an explainer. Both readings come resolved from `StressPatterns`; nothing is computed here.

struct StressPatternsSection: View {
    let timeOfDay: StressPatterns.TimeOfDay?
    let week: StressPatterns.Week?
    let loaded: Bool

    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable { case day, week; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(StressPatternStrings.title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, ZoopSpacing.xs)
            VStack(spacing: ZoopSpacing.cardGap) {
                dayCard
                weekCard
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .day: daySheet
            case .week: weekSheet
            }
        }
    }

    // MARK: Through the day

    private var dayCard: some View {
        StressPatternCard(title: StressPatternStrings.dayTitle, explains: timeOfDay != nil) { sheet = .day } content: {
            if let timeOfDay {
                StressTypicalDayChart(pattern: timeOfDay).frame(height: 150)
                sentence(daySentence(timeOfDay))
            } else {
                sentence(loaded ? StressPatternStrings.dayPending : StressPatternStrings.dayLoading, muted: true)
            }
        }
    }

    private func daySentence(_ t: StressPatterns.TimeOfDay) -> LocalizedStringResource {
        guard let timing = t.timing else { return StressPatternStrings.dayFlat }
        return StressPatternStrings.dayPeak(StressPatternFormat.clock(timing.peakHour),
                                            StressPatternFormat.clock(timing.calmHour))
    }

    @ViewBuilder private var daySheet: some View {
        if let timeOfDay {
            StressPatternSheet(title: StressPatternStrings.dayTitle, summary: daySentence(timeOfDay),
                               what: StressPatternStrings.dayWhat, methodName: StressPatternStrings.dayMethod,
                               methodSummary: StressPatternStrings.dayMethodSummary,
                               note: StressPatternStrings.dayRelative,
                               data: StressPatternStrings.dayData(timeOfDay.days)) {
                StressTypicalDayChart(pattern: timeOfDay)
            }
        }
    }

    // MARK: Workdays and weekend

    private var weekCard: some View {
        StressPatternCard(title: StressPatternStrings.weekTitle, explains: week != nil) { sheet = .week } content: {
            if let week {
                StressWeekSplit(week: week)
                StressWeekBars(week: week).frame(height: 110)
                sentence(weekSentence(week))
            } else {
                sentence(StressPatternStrings.weekPending, muted: true)
            }
        }
    }

    private func weekSentence(_ w: StressPatterns.Week) -> LocalizedStringResource {
        switch w.verdict {
        case .weekendCalmer: return StressPatternStrings.weekCalmer
        case .weekendMoreStressed: return StressPatternStrings.weekMoreStressed
        case .noClearDifference: return StressPatternStrings.weekNoClear
        }
    }

    @ViewBuilder private var weekSheet: some View {
        if let week {
            let p = week.pValue.formatted(.number.precision(.fractionLength(2)).locale(StressPatternFormat.locale))
            StressPatternSheet(title: StressPatternStrings.weekTitle, summary: weekSentence(week),
                               what: StressPatternStrings.weekWhat, methodName: StressPatternStrings.weekMethod,
                               methodSummary: StressPatternStrings.weekMethodSummary,
                               note: StressPatternStrings.weekSource,
                               data: StressPatternStrings.weekData(week.workdayDays, week.weekendDays, p)) {
                StressWeekBars(week: week)
            }
        }
    }

    private func sentence(_ text: LocalizedStringResource, muted: Bool = false) -> some View {
        Text(text)
            .font(muted ? ZoopType.caption : ZoopType.body)
            .foregroundStyle(muted ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A content card whose title row carries an info button for the explainer.
private struct StressPatternCard<Content: View>: View {
    let title: LocalizedStringResource
    let explains: Bool
    let onExplain: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ContentCard {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: ZoopSpacing.s)
                if explains {
                    Button(action: onExplain) {
                        Image(systemName: "info.circle")
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(StressPatternStrings.explain))
                    .padding(.vertical, -ZoopSpacing.m)
                }
            }
            content()
        }
    }
}

// MARK: - Charts

/// The typical day: mean level per hour against the day average, peak and calmest hour marked when the
/// pattern is clear.
struct StressTypicalDayChart: View {
    let pattern: StressPatterns.TimeOfDay

    var body: some View {
        let timing = pattern.timing
        Chart {
            RuleMark(y: .value("Average", pattern.dayMean)).zoopReferenceRule()
            ForEach(pattern.hours, id: \.hour) { h in
                AreaMark(x: .value("Hour", h.hour), y: .value("Stress", h.level))
                    .foregroundStyle(StrandPalette.stressMedium.opacity(ZoopChartStyle.bandOpacity))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", h.hour), y: .value("Stress", h.level))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let timing {
                marker(hour: timing.peakHour, level: timing.peakMean, color: StrandPalette.stressHigh, top: true)
                marker(hour: timing.calmHour, level: timing.calmMean, color: StrandPalette.stressLow, top: false)
            }
        }
        .chartYScale(domain: 0...3)
        .chartXScale(domain: (pattern.hours.first?.hour ?? 7)...(pattern.hours.last?.hour ?? 22))
        .chartXAxis {
            AxisMarks(values: .stride(by: 4)) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(verbatim: StressPatternFormat.clock(h)).font(ZoopType.caption)
                    }
                }
            }
        }
        .zoopYAxis { StressTrace.displayLevel($0, locale: StressPatternFormat.locale) }
        .accessibilityLabel(Text(StressPatternStrings.dayA11y))
    }

    private func marker(hour: Int, level: Double, color: Color, top: Bool) -> some ChartContent {
        PointMark(x: .value("Hour", hour), y: .value("Stress", level))
            .foregroundStyle(color)
            .symbolSize(70)
            .annotation(position: top ? .top : .bottom, spacing: 4) {
                Text(verbatim: StressPatternFormat.clock(hour))
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
    }
}

/// The two group means side by side, each with its sample size and the swatch of its bars. Which group
/// is higher is said by the sentence under the chart, not by colour.
struct StressWeekSplit: View {
    let week: StressPatterns.Week

    var body: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.xl) {
            group(StressPatternStrings.workdays, week.workdayMean, week.workdayDays, swatch: StressWeekBars.workdayColor)
            group(StressPatternStrings.weekend, week.weekendMean, week.weekendDays, swatch: StressWeekBars.weekendColor)
            Spacer(minLength: 0)
        }
    }

    private func group(_ label: LocalizedStringResource, _ mean: Double, _ days: Int, swatch: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ZoopSpacing.xs) {
                Circle().fill(swatch).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Text(verbatim: StressTrace.displayLevel(mean, locale: StressPatternFormat.locale))
                .font(ZoopType.metric)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(StressPatternStrings.days(days)).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Mean stress per weekday: weekend bars in the stress colour, workdays muted.
struct StressWeekBars: View {
    let week: StressPatterns.Week

    static var workdayColor: Color { StrandPalette.textTertiary.opacity(0.45) }
    static var weekendColor: Color { StrandPalette.stressHigh }

    var body: some View {
        Chart {
            ForEach(week.weekdays, id: \.weekday) { d in
                BarMark(x: .value("Weekday", StressPatternFormat.shortWeekday(d.weekday)),
                        y: .value("Stress", d.mean), width: .ratio(0.6))
                    .foregroundStyle(d.weekday >= 6 ? Self.weekendColor : Self.workdayColor)
                    .cornerRadius(4)
            }
        }
        .chartYScale(domain: 0...3)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary) }
        }
        .zoopYAxis { StressTrace.displayLevel($0, locale: StressPatternFormat.locale) }
        .accessibilityLabel(Text(StressPatternStrings.weekA11y))
    }
}

// MARK: - Formatting (app locale)

enum StressPatternFormat {
    static var locale: Locale { AppLanguage.activeLocale }

    static func clock(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
    }

    /// Short weekday name for an ISO weekday (1 = Monday).
    static func shortWeekday(_ iso: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        return cal.shortStandaloneWeekdaySymbols[iso % 7]
    }
}
