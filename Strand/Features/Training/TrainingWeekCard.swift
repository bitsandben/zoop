import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// MARK: - This week
//
// Effort per day as bars, the last seven days as a tappable strip underneath, and their totals. Bars
// and strip share one column grid, so a bar sits directly above its day. The strip replaces the old
// month calendar: it answers "what did I do this week" and opens the day's sheet (workouts, today's
// planned Lift Log routine) on tap.

struct TrainingWeekCard: View {
    let week: TrainingWeek
    let effortScale: EffortScale
    let format: TrainingFormat
    let onSelectDay: (TrainingWeek.Day) -> Void

    private static let barHeight: CGFloat = 96
    private static let dayDiameter: CGFloat = 36

    var body: some View {
        ContentCard {
            header
            if week.isEmpty {
                Text(TrainingStrings.weekEmpty)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if week.days.contains(where: { $0.effort != nil }) { effortBars }
            dayStrip
            if !week.isEmpty { totals }
            if let zones = week.zones { zoneSplit(zones) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(TrainingStrings.weekTitle)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: ZoopSpacing.s)
            NavigationLink(value: TrainingCalendarRoute()) {
                Label(TrainingStrings.month, systemImage: "calendar")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.accent)
            }
            // The empty sentence below already says "none"; a "0 sessions" beside it would say it twice.
            if !week.isEmpty {
                Text(TrainingStrings.sessionCount(week.sessions.count))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: Bars

    /// One bar per day that has an Effort figure. The plot spans exactly the seven day slots, so a bar
    /// is centred over its day button below.
    private var effortBars: some View {
        let top = TrainingEffort.scaleMax(effortScale)
        let first = week.days.first?.date ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: week.days.count, to: first) ?? first
        return VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Chart {
                ForEach(week.days) { day in
                    if let effort = day.effort {
                        BarMark(x: .value("Day", day.date, unit: .day),
                                y: .value("Effort", TrainingEffort.value(effort, scale: effortScale)))
                            .foregroundStyle(StrandPalette.effortColor)
                            .cornerRadius(4)
                            .annotation(position: .top, spacing: 2) {
                                Text(ZoopNumber.decimal(TrainingEffort.value(effort, scale: effortScale),
                                                        digits: effortScale == .hundred ? 0 : 1))
                                    .font(ZoopType.caption.monospacedDigit())
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                    }
                }
            }
            .chartXScale(domain: first...end)
            .chartYScale(domain: 0...top)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: Self.barHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TrainingStrings.barsAccessibility)
            .accessibilityValue(barsSpokenValue)

            Text(TrainingStrings.barsCaption(maxValue: ZoopNumber.decimal(top, digits: 0)))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var barsSpokenValue: String {
        week.days.compactMap { day -> String? in
            guard let effort = day.effort else { return nil }
            let weekday = day.date.formatted(Date.FormatStyle().weekday(.wide).locale(AppLanguage.activeLocale))
            return "\(weekday) \(TrainingEffort.text(effort, scale: effortScale))"
        }.joined(separator: ", ")
    }

    // MARK: Strip

    private var dayStrip: some View {
        HStack(spacing: 0) {
            ForEach(week.days) { day in
                // A day opens its sheet only when there is something to show: sessions, or today's routine.
                let hasPlan = !day.planned.isEmpty && day.isToday
                Button { onSelectDay(day) } label: { dayCell(day) }
                    .buttonStyle(.plain)
                    .disabled(day.sessions.isEmpty && !hasPlan)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(accessibilityLabel(day))
            }
        }
    }

    private func dayCell(_ day: TrainingWeek.Day) -> some View {
        VStack(spacing: ZoopSpacing.xs) {
            ZStack {
                if let lead = day.sessions.first {
                    Circle().fill(TrainingCalendarStyle.color(for: lead.sport))
                    Image(systemName: sportSymbol(lead.sport))
                        .font(ZoopType.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.surfaceBase)
                } else if !day.planned.isEmpty, day.isToday {
                    Circle().strokeBorder(StrandPalette.effortColor, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    Image(systemName: sportSymbol("Strength"))
                        .font(ZoopType.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.effortColor)
                } else {
                    Circle().fill(StrandPalette.surfaceRaised)
                }
            }
            .frame(width: Self.dayDiameter, height: Self.dayDiameter)
            .overlay {
                if day.isToday { Circle().strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5).padding(-3) }
            }
            .overlay(alignment: .topTrailing) {
                if day.sessions.count > 1 {
                    Text(verbatim: "\(day.sessions.count)")
                        .font(ZoopType.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(3)
                        .background(Circle().fill(StrandPalette.surfaceBase))
                        .offset(x: 6, y: -6)
                        .accessibilityHidden(true)
                }
            }
            Text(day.date.formatted(Date.FormatStyle().weekday(.narrow).locale(AppLanguage.activeLocale)))
                .font(ZoopType.caption)
                .foregroundStyle(day.isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
        }
        .contentShape(Rectangle())
    }

    private func accessibilityLabel(_ day: TrainingWeek.Day) -> String {
        let date = day.date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
        if !day.sessions.isEmpty { return "\(date), \(TrainingStrings.sessionCount(day.sessions.count))" }
        if let planned = day.planned.first, day.isToday {
            return "\(date), \(String(localized: "Planned")): \(planned.name)"
        }
        return date
    }

    // MARK: Totals

    private var totals: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.m) {
            stat(TrainingStrings.time, format.duration(seconds: week.totalSeconds))
            stat(TrainingStrings.energy, format.energy(week.totalKcal))
            if let distance = format.totalDistance(of: week.sessions) {
                stat(TrainingStrings.distance, distance)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(ZoopType.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func zoneSplit(_ zones: WorkoutZones.Summary) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(TrainingStrings.zones).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            TrainingZoneBar(minutes: zones.minutes, height: 10)
        }
    }
}

/// Heart-rate zone minutes as one stacked bar (Z1 to Z5). The widest zone carries a thin outline so the
/// busiest zone reads without a legend.
struct TrainingZoneBar: View {
    let minutes: [Double]
    var height: CGFloat = 10

    var body: some View {
        let total = max(minutes.reduce(0, +), 0.001)
        let busiest = minutes.indices.max { minutes[$0] < minutes[$1] } ?? 0
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<min(minutes.count, 5), id: \.self) { i in
                    Rectangle()
                        .fill(StrandPalette.hrZoneColor(i + 1))
                        .frame(width: max(0, CGFloat(minutes[i] / total) * geo.size.width))
                        .overlay {
                            if i == busiest {
                                Rectangle().strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                            }
                        }
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TrainingStrings.zoneSplitAccessibility(
            percents: minutes.prefix(5).map { Int(($0 / total * 100).rounded()) }))
    }
}
