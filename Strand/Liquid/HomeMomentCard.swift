#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Home moment card
//
// One card at the top of My Day that says what matters right now. High stress in the last hour wins
// (with a breathing session one tap away); in the evening it is the night ahead (alarm, bedtime,
// reminder); in the morning it is how hard today can be. Outside those it draws nothing.

enum HomeMoment: Equatable {
    case breathe(level: Double)
    case evening
    case morning(recovery: Double)

    /// Stress level (0–3) from which an hour counts as high.
    static let highStress = 2.0
    /// How recent the stress reading must be to count as "now".
    static let stressMaxAge: TimeInterval = 90 * 60

    /// The moment for `now`: recent high stress between 08:00 and 23:00, else the morning from 05:00 to
    /// 11:00 when today's recovery is known, else the night ahead.
    static func pick(now: Date, hours: [DaytimeStress.HourPoint], recovery: Double?,
                     calendar: Calendar = .current) -> HomeMoment? {
        let h = calendar.component(.hour, from: now)
        let nowTs = Int(now.timeIntervalSince1970)
        if (8..<23).contains(h),
           let latest = hours.last(where: { $0.level != nil && $0.startTs <= nowTs }),
           TimeInterval(nowTs - latest.startTs) <= stressMaxAge + 3600,
           let level = latest.level, level >= highStress {
            return .breathe(level: level)
        }
        if (5..<11).contains(h), let r = recovery { return .morning(recovery: r) }
        return .evening
    }
}

struct HomeMomentCard: View {
    let hours: [DaytimeStress.HourPoint]
    let recovery: Double?
    /// Today's strain target in the user's Effort scale, e.g. "Target 4–10", from the hero.
    let strainTarget: String?

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @StateObject private var patterns = PatternsModel()

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            if let moment = HomeMoment.pick(now: ctx.date, hours: hours, recovery: recovery) {
                content(moment, now: ctx.date)
                    .transition(.opacity)
            }
        }
        .task(id: repo.refreshSeq) {
            await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm())
        }
    }

    @ViewBuilder
    private func content(_ moment: HomeMoment, now: Date) -> some View {
        switch moment {
        case .breathe(let level): breathe(level)
        case .evening: evening(now: now)
        case .morning(let r): morning(r)
        }
    }

    // MARK: Breathe

    private func breathe(_ level: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(icon: "wind", title: "Stress is high right now", tint: StrandPalette.stressHigh)
            Text(String(localized: "\(String(format: "%.1f", level)) of 3 in the last hour. A few minutes of slow breathing usually brings it down."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: TabRoute.breathe) {
                Label("Breathe for 3 minutes", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(Capsule().fill(StrandPalette.textPrimary))
            }
            .buttonStyle(.plain)
        }
        .cardChrome()
    }

    // MARK: Evening

    /// The night ahead, as the sleep planner states it: the recommended bedtime on the left, the alarm on
    /// the right with its state, and a way into the planner.
    @ViewBuilder
    private func evening(now: Date) -> some View {
        let alarm = model.nextArmedStrapAlarm(from: now)
        let t = patterns.tonight
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sleep tonight")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(alignment: .top) {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sunset.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(t?.bedtime.map { PatternsScreen.clock($0 / 60) } ?? "–")
                            .font(StrandFont.display(32))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("Recommended bedtime")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(StrandPalette.textTertiary)
                    .frame(width: 34, height: 1)
                    .padding(.top, 20)
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(alarm.map(Self.time) ?? t?.wake.map { PatternsScreen.clock($0 / 60) } ?? "–")
                            .font(StrandFont.display(32))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(alarm == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                            .frame(width: 7, height: 7)
                        Text(alarmStatus(alarm))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(alarm == nil ? StrandPalette.textSecondary : StrandPalette.accent)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Text(alarm == nil ? "Set alarm" : "Edit alarm")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Capsule().fill(StrandPalette.surfaceBase))
        }
        .cardChrome()
        .overlay {
            // The whole card opens the planner.
            NavigationLink(value: TabRoute.sleepPlanner) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
    }

    /// "Alarm on", or with a smart-wake window "From 06:20", or why it will not ring.
    private func alarmStatus(_ alarm: Date?) -> String {
        guard let alarm else {
            return model.behavior.smartAlarmEnabled ? String(localized: "Not armed") : String(localized: "Alarm off")
        }
        let window = SmartWakeWindow.windowMinutes
        if window > 0 {
            return String(localized: "From \(Self.time(alarm.addingTimeInterval(-Double(window * 60))))")
        }
        return String(localized: "Alarm on")
    }

    // MARK: Morning

    private func morning(_ r: Double) -> some View {
        let line: String
        switch r {
        case 67...: line = String(localized: "You're recovered. A hard day suits you.")
        case 34..<67: line = String(localized: "A moderate day suits you.")
        default: line = String(localized: "Keep today light. Easy movement helps more than a hard session.")
        }
        return NavigationLink(value: TabRoute.coupled) {
            VStack(alignment: .leading, spacing: 10) {
                header(icon: "sunrise.fill", title: "Today", tint: StrandPalette.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Int(r.rounded()))%")
                        .font(StrandFont.display(36))
                        .foregroundStyle(StrandPalette.recoveryColor(r))
                    Text("Recovery")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let strainTarget {
                        Text(strainTarget)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(line)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .cardChrome()
        }
        .buttonStyle(.plain)
    }

    // MARK: Pieces

    private func header(icon: String, title: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(StrandPalette.surfaceBase))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func row(icon: String, text: String, detail: String, accent: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent ? StrandPalette.accent : StrandPalette.textPrimary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent ? StrandPalette.accent : StrandPalette.textPrimary)
            Spacer()
            Text(detail)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StrandPalette.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .contentShape(Rectangle())
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jj:mm")
        return f.string(from: date)
    }

    /// "in 9 h 20 min" for the alarm, resolved against the same clock the card picked its moment with.
    static func until(_ date: Date, from now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        return String(localized: "in \(minutes / 60) h \(minutes % 60) min")
    }
}

private extension View {
    func cardChrome() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(ZoopPanelSurface())
    }
}
#endif
