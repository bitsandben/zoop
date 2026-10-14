#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Home moment card
//
// One card at the top of My Day that says what matters right now. High stress in the last hour wins
// (with a breathing session one tap away); otherwise it is the night ahead (alarm, bedtime). Recovery
// is not repeated here: the rings above already show it.

enum HomeMoment: Equatable {
    case breathe(level: Double)
    case evening

    /// Stress level (0–3) from which an hour counts as high.
    static let highStress = 2.0

    /// The night ahead shows from this hour until 04:00; earlier in the day there is nothing to plan yet.
    static let eveningFromHour = 17

    /// The moment for `now`: stress that is high right now between 08:00 and 23:00, else the night ahead
    /// in the evening, else nothing.
    ///
    /// "Right now" means the hour in progress scores high AND the last ten minutes of heart rate
    /// (`recentHR`) still sit at or above that hour's mean, so one tense moment earlier in the hour does
    /// not keep the card up once the body has settled.
    static func pick(now: Date, hours: [DaytimeStress.HourPoint], recentHR: Double?,
                     calendar: Calendar = .current) -> HomeMoment? {
        let h = calendar.component(.hour, from: now)
        let nowTs = Int(now.timeIntervalSince1970)
        if (8..<23).contains(h),
           let current = hours.last(where: { $0.startTs <= nowTs && nowTs - $0.startTs < 3600 }),
           let level = current.level, level >= highStress,
           let recent = recentHR, let hourMean = current.meanHR, recent >= hourMean {
            return .breathe(level: level)
        }
        return (h >= eveningFromHour || h < 4) ? .evening : nil
    }
}

struct HomeMomentCard: View {
    let hours: [DaytimeStress.HourPoint]

    @EnvironmentObject private var repo: Repository
    /// The alarm settings this card reads, observed so an alarm change shows at once. The app model is
    /// reached WITHOUT observing it: it publishes the smoothed heart rate every few seconds, which re-ran
    /// this card (and its minute timeline) mid-scroll for a value it never shows. The minute timeline
    /// re-reads the alarm anyway.
    @EnvironmentObject private var behavior: BehaviorStore
    private var model: AppModel? { AppModel.shared }
    @StateObject private var patterns = PatternsModel()
    /// Mean heart rate over the last ten minutes, or nil when the strap sent too little.
    @State private var recentHR: Double?

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            if let moment = HomeMoment.pick(now: ctx.date, hours: hours, recentHR: recentHR) {
                content(moment, now: ctx.date)
                    .transition(.opacity)
            }
        }
        .task(id: repo.refreshSeq) {
            await patterns.loadQuick(repo: repo, alarm: model?.nextArmedStrapAlarm())
        }
        .task {
            // Refresh the recent heart rate once a minute while Home is on screen.
            while !Task.isCancelled {
                let now = Int(Date().timeIntervalSince1970)
                let hr = await repo.hrSamples(from: now - 600, to: now, limit: 2_000)
                recentHR = hr.count >= 20 ? Double(hr.map(\.bpm).reduce(0, +)) / Double(hr.count) : nil
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func content(_ moment: HomeMoment, now: Date) -> some View {
        switch moment {
        case .breathe(let level): breathe(level)
        case .evening: evening(now: now)
        }
    }

    // MARK: Breathe

    private func breathe(_ level: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(icon: "wind", title: "Stress is high right now", tint: StrandPalette.stressHigh)
            Text("A few minutes of slow breathing usually brings it down.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: TabRoute.breathe) {
                Label("Breathe for 3 minutes", systemImage: "play.fill")
                    .font(StrandFont.ui(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.primaryButtonText)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(Capsule().fill(StrandPalette.primaryButtonFill))
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
        let alarm = model?.nextArmedStrapAlarm(from: now)
        let t = patterns.tonight
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sleep tonight")
                    .font(StrandFont.ui(17, weight: .semibold))
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
                .font(StrandFont.ui(15, weight: .semibold))
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
            return behavior.smartAlarmEnabled ? String(localized: "Not armed") : String(localized: "Alarm off")
        }
        let window = SmartWakeWindow.windowMinutes
        if window > 0 {
            return String(localized: "From \(Self.time(alarm.addingTimeInterval(-Double(window * 60))))")
        }
        return String(localized: "Alarm on")
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
                .font(StrandFont.ui(17, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jj:mm")
        return f.string(from: date)
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
