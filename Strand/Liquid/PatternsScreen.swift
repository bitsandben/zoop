#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// MARK: - Patterns
//
// `PatternsModel` holds tonight's sleep plan and the best-bedtime window that Home and the sleep planner
// read. The pattern readings themselves (habits, weekdays, evening stress) live on the Insights tab
// (`BodyPatternsSection`); `PatternsScreen` is the legacy route to that same section.

@MainActor
final class PatternsModel: ObservableObject {
    struct Tonight: Equatable {
        let need: SleepDebt.NeedTonight; let bedtime: Int?; let wake: Int?
        /// The armed strap alarm the wake time came from, when there is one.
        var alarm: Date? = nil
        /// Minutes in bed for the chosen goal, and the goal itself (share of the need).
        var inBedMin: Double = 0
        var goal: Double = 1
        /// Bedtime for the full need, for the planner's "optimal" line.
        var fullNeedBedtime: Int? = nil
    }

    @Published var tonight: Tonight?
    @Published var bedtime: PatternInsights.BedtimeWindow?

    private static let day = 86_400

    /// The quick, in-memory readings (used by Home as well as this screen).
    func loadQuick(repo: Repository, alarm: Date? = nil) async {
        let days = repo.days
        guard !days.isEmpty else { return }
        let today = days.last
        let need = SleepModel.debtNeedMin(days: days)
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        let strain21 = today?.strain.map { $0 * 0.21 }
        let sleepNeed = SleepDebt.needTonight(baseNeedMin: need, strain21: strain21,
                                              debtMin: ledger.isDebt ? ledger.magnitudeMin : 0)
        // Time in bed for the chosen goal, from the recent share of time in bed spent asleep.
        let effs = days.suffix(14).compactMap(\.efficiency)
        let eff = effs.isEmpty ? nil : effs.reduce(0, +) / Double(effs.count)
        let goal = SleepGoal.current.fraction
        let inBed = PatternInsights.inBedMinutes(needMin: sleepNeed.totalMin, goal: goal, efficiency: eff)
        let fullInBed = PatternInsights.inBedMinutes(needMin: sleepNeed.totalMin, goal: 1, efficiency: eff)
        // The reminder counts back the same time in bed, so it is handed over every time it is computed.
        WindDownNudge.updateTonightNeed(Int(inBed.rounded()))
        // One wake time for the card and the reminder: an armed strap alarm within the next day first,
        // then the wake time set for the reminder, then the habitual one from past nights.
        var bed: Int?, wake: Int?
        let usableAlarm = alarm.flatMap { $0.timeIntervalSinceNow < 26 * 3600 ? $0 : nil }
        if let a = usableAlarm {
            let c = Calendar.current.dateComponents([.hour, .minute], from: a)
            wake = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) * 60
        } else if WindDownNudge.isEnabled {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            wake = WindDownNudge.wakeMinutes(forWeekday: Calendar.current.component(.weekday, from: tomorrow)) * 60
        } else if let mid = await repo.habitualMidsleepSec() {
            let typical = (SleepModel.sleepNeedMin(days: days)) * 60
            wake = (mid + Int(typical / 2)) % Self.day
        }
        var fullBed: Int?
        if let w = wake {
            bed = ((w - Int(inBed * 60)) % Self.day + Self.day) % Self.day
            fullBed = ((w - Int(fullInBed * 60)) % Self.day + Self.day) % Self.day
        }
        tonight = Tonight(need: sleepNeed, bedtime: bed, wake: wake, alarm: usableAlarm,
                          inBedMin: inBed, goal: goal, fullNeedBedtime: fullBed)
    }

    /// The best-bedtime window from the last five months of nights; returns those nights for reuse.
    @discardableResult
    func loadBedtime(repo: Repository) async -> [CachedSleepSession] {
        let now = Int(Date().timeIntervalSince1970)
        var byDay: [String: DailyMetric] = [:]
        for d in repo.days { byDay[d.day] = d }
        let sessions = await repo.sleepSessions(from: now - 150 * Self.day, to: now, limit: 600)
            .filter { $0.endTs - $0.effectiveStartTs >= 3 * 3600 }
        var onsetPairs: [(onsetMinute: Int, recovery: Double)] = []
        for s in sessions {
            let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            guard let r = byDay[wakeDay]?.recovery else { continue }
            let c = Calendar.current.dateComponents([.hour, .minute],
                                                    from: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)))
            var m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if m < 12 * 60 { m += 24 * 60 }
            onsetPairs.append((m, r))
        }
        bedtime = PatternInsights.bedtimeWindow(nights: onsetPairs)
        return sessions
    }
}

// MARK: - Screen

/// The legacy "Patterns" route. It shows the Insights tab's patterns section, so the two can never
/// disagree; the clock helper stays here for the sleep planner and Home.
struct PatternsScreen: View {
    var body: some View { BodyPatternsPage() }

    static func clock(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
#endif

#if os(iOS)
/// The wind-down reminder from the Tonight card: its time when it is on, a button to turn it on when not.
struct WindDownReminderRow: View {
    /// The wake time the card shows, handed to the reminder when none was set yet so both use one time.
    let suggestedWakeMinute: Int?
    let onChange: () -> Void
    @State private var enabled = WindDownNudge.isEnabled && WindDownNudge.followsSleepNeed
    @State private var denied = false

    private var reminderMinute: Int {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return WindDownNudge.nudgeMinuteOfDay(forWeekday: Calendar.current.component(.weekday, from: tomorrow))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: enabled ? "bell.fill" : "bell")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            if enabled {
                Text("Reminder at \(PatternsScreen.clock(reminderMinute))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if denied {
                Text("Notifications are off for Zoop")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Button {
                    WindDownNudge.setFollowsSleepNeed(true)
                    if !WindDownNudge.hasWakeSetting, let wake = suggestedWakeMinute {
                        WindDownNudge.setWakeMinutes(wake)
                    }
                    WindDownNudge.setEnabled(true) { outcome in
                        onChange()
                        withAnimation(.snappy) {
                            enabled = outcome == .scheduled
                            denied = outcome == .denied
                        }
                    }
                } label: {
                    Text("Remind me to wind down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif

#if os(iOS)
/// How much of tonight's sleep need the plan aims for. Chosen in the sleep planner; the bedtime, the
/// Home card and the wind-down reminder all follow it.
enum SleepGoal: String, CaseIterable, Identifiable {
    case peak, perform, getBy
    var id: String { rawValue }
    static let storageKey = "zoop.sleepPlanner.goal"

    static var current: SleepGoal {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SleepGoal.init(rawValue:)) ?? .peak
    }

    var fraction: Double {
        switch self {
        case .peak: return 1.0
        case .perform: return 0.85
        case .getBy: return 0.7
        }
    }

    var title: String {
        switch self {
        case .peak: return String(localized: "Get all the sleep I need")
        case .perform: return String(localized: "Perform well")
        case .getBy: return String(localized: "Just get by")
        }
    }
}
#endif
