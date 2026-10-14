#if os(iOS)
import SwiftUI
import StrandDesign

/// "My Day" as one card: what matters right now (high stress, or the night ahead from 17:00) on top,
/// then the day's sleeps, naps and workouts.
struct TodayMyDayCard: View {
    let moment: TodayMoment?
    let activities: [TodayActivity]
    let onOpen: (TodayActivity) -> Void
    let onEditNap: (TodayActivity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let moment {
                TodayMomentSection(moment: moment)
                    .padding(.bottom, ZoopSpacing.m)
                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            }
            if activities.isEmpty {
                Text(TodayCopy.activitiesEmpty)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.vertical, ZoopSpacing.m)
            }
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
                    }
            }
        }
        .padding(.horizontal, ZoopSpacing.cardPadding)
        .padding(.vertical, moment == nil ? 0 : ZoopSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous).fill(StrandPalette.surfaceRaised))
    }

    @ViewBuilder
    private func row(_ item: TodayActivity) -> some View {
        if item.kind == .sleep {
            NavigationLink(value: TabRoute.sleep) { TodayActivityRow(item: item) }
                .buttonStyle(LiquidPressStyle())
        } else if item.kind == .nap {
            // A nap opens its own detail; pressing and holding opens the Sleep screen's time editor.
            TodayActivityRow(item: item)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(item) }
                .onLongPressGesture(minimumDuration: 0.45) { onEditNap(item) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(TodayCopy.editNap)) { onEditNap(item) }
        } else {
            Button { onOpen(item) } label: { TodayActivityRow(item: item) }
                .buttonStyle(LiquidPressStyle())
        }
    }
}

/// One activity: a glyph, the title, the time span and its length.
struct TodayActivityRow: View {
    let item: TodayActivity

    private var icon: String {
        switch item.kind {
        case .sleep: return "moon.fill"
        case .nap: return "bed.double.fill"
        case .workout: return "figure.run"
        case .detected: return "sparkles"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .sleep, .nap: return StrandPalette.metricPurple
        case .workout, .detected: return StrandPalette.effortColor
        }
    }

    var body: some View {
        let start = Date(timeIntervalSince1970: TimeInterval(item.start))
        let end = Date(timeIntervalSince1970: TimeInterval(item.end))
        HStack(spacing: ZoopSpacing.m) {
            Image(systemName: icon)
                .font(ZoopType.headline)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if item.kind == .detected {
                    Text(TodayCopy.activityDetectedHint)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text(verbatim: "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                        .font(ZoopType.caption.monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: ZoopSpacing.s)
            Text(Duration.seconds(max(0, item.end - item.start)),
                 format: .units(allowed: [.hours, .minutes], width: .narrow))
                .font(ZoopType.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.vertical, ZoopSpacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The top of My Day: a breathing nudge while stress is high, else the night ahead in the evening.
struct TodayMomentSection: View {
    let moment: TodayMoment

    var body: some View {
        switch moment {
        case .breathe:
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                Text(TodayCopy.breatheTitle).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(TodayCopy.breatheBody).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink(value: TabRoute.breathe) {
                    Label { Text(TodayCopy.breatheAction) } icon: { Image(systemName: "wind") }
                }
                .buttonStyle(ZoopButtonStyle(.primary))
            }
        case .evening(let bedtime, let alarm):
            NavigationLink(value: TabRoute.sleepPlanner) {
                VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                    HStack {
                        Text(TodayCopy.eveningTitle).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right").font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    HStack(alignment: .top) {
                        timeColumn(TodayCopy.bedtime, value: bedtime.map(Self.clock) ?? String(localized: TodayCopy.noBedtime))
                        timeColumn(TodayCopy.alarm, value: alarm.map { $0.formatted(date: .omitted, time: .shortened) }
                                   ?? String(localized: TodayCopy.alarmOff))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func timeColumn(_ label: LocalizedStringResource, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: value).font(ZoopType.metric).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A minute of the day as a clock time in the user's 12/24-hour setting.
    static func clock(_ minuteOfDay: Int) -> String {
        let m = ((minuteOfDay % 1440) + 1440) % 1440
        let date = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
#endif
