#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Sleep planner
//
// Tonight at a glance and the strap alarm, kept as plain as a clock app: the bedtime and wake time with
// the time in bed between them, the goal for tomorrow, the alarm switch with its weekly schedule as rows
// ("Mon–Fri 06:50", "Sat–Sun 08:30"), gentle wake, and the wind-down reminder. Anything that stops the
// alarm from working shows as one banner with the fix, not as text. Every time comes from the same
// funnels the rest of the app reads (`AppModel.nextArmedStrapAlarm`, `PatternsModel.tonight`).

struct SleepPlannerScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var behavior: BehaviorStore
    @StateObject private var patterns = PatternsModel()
    @AppStorage(SleepGoal.storageKey) private var goalRaw = SleepGoal.peak.rawValue
    @AppStorage(PuffinExperiment.defaultsKey) private var whoop5AlarmUnlocked = false
    /// Consecutive arms the strap answered with a different time (written by the alarm path).
    @AppStorage("alarm.rejectStreak") private var alarmRejectStreak = 0
    @State private var editing: AlarmGroup?
    @State private var overrides = WindDownNudge.perDayWakeOverrides

    init(behavior: BehaviorStore) { self.behavior = behavior }

    private var goal: SleepGoal { SleepGoal(rawValue: goalRaw) ?? .peak }
    private var alarm: Date? { model.nextArmedStrapAlarm() }
    /// On, but this strap will not take it: a WHOOP 5/MG arms only with its experimental features on.
    private var needsUnlock: Bool { behavior.smartAlarmEnabled && model.whoop5Detected && !whoop5AlarmUnlocked }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if needsUnlock { unlockBanner }
                if behavior.smartAlarmEnabled && alarmRejectStreak >= 2 { rejectedBanner }
                if let t = patterns.tonight { tonightCard(t) }
                goalPicker
                SmartAlarmMorningLine()
                alarmCard
                SmartAlarmModeCard(deadline: model.nextSmartAlarmDeadline())
                if let t = patterns.tonight { windDownCard(t) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.snappy, value: needsUnlock)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Sleep planner")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(repo.refreshSeq)-\(goalRaw)-\(behavior.smartAlarmEnabled)-\(behavior.smartAlarmMinutes)-\(overrides.count)-\(whoop5AlarmUnlocked)") {
            await reload()
        }
        .sheet(item: $editing) { g in
            AlarmTimeSheet(behavior: behavior, days: g.days, minutes: g.minutes ?? behavior.smartAlarmMinutes) {
                overrides = WindDownNudge.perDayWakeOverrides
                Task { await reload() }
            }
            .presentationDetents([.fraction(0.72)])
        }
    }

    private func reload() async {
        await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm())
    }

    // MARK: Banner

    private var unlockBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(ZoopType.icon(18))
                .foregroundStyle(StrandPalette.stressHigh)
            Text("Your WHOOP 5/MG needs one switch for the alarm.")
                .font(ZoopType.caption.weight(.medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                whoop5AlarmUnlocked = true
                model.applySmartAlarm()
            } label: {
                Text("Turn on")
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.primaryButtonText)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(StrandPalette.primaryButtonFill))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceRaised))
    }

    /// The strap keeps storing a different time than the one sent, so its alarm will not fire.
    private var rejectedBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ZoopType.icon(18))
                .foregroundStyle(StrandPalette.statusWarning)
            Text("Your strap isn't taking the alarm. Charge and reconnect it, and keep a phone alarm until it does.")
                .font(ZoopType.caption.weight(.medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceRaised))
    }

    // MARK: Tonight

    /// Shown instead of a time while no wake time is known (never a dash).
    static var unset: String {
        String(localized: LocalizedStringResource("zoop.sleep.planner.unset", defaultValue: "Not set"))
    }

    private func tonightCard(_ t: PatternsModel.Tonight) -> some View {
        ContentCard {
            VStack(spacing: 16) {
                HStack(alignment: .top) {
                    timeColumn(t.bedtime.map { PatternsScreen.clock($0 / 60) } ?? Self.unset,
                               label: "Bedtime", icon: "moon.fill")
                    Spacer()
                    timeColumn(t.wake.map { PatternsScreen.clock($0 / 60) } ?? Self.unset,
                               label: alarm == nil ? "Wake up" : "Alarm", icon: "alarm.fill")
                }
                ZStack {
                    Capsule().fill(StrandPalette.accent.opacity(0.22)).frame(height: 8)
                    Text(Self.duration(t.inBedMin))
                        .font(ZoopType.label.weight(.bold).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(StrandPalette.surfaceRaised))
                        .overlay(Capsule().strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5))
                }
                Text("Time in bed")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func timeColumn(_ value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(StrandFont.display(38))
                .foregroundStyle(StrandPalette.textPrimary)
            Label(label, systemImage: icon)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: Goal

    private var goalPicker: some View {
        Menu {
            Picker("Tomorrow I want to", selection: $goalRaw) {
                ForEach(SleepGoal.allCases) { g in
                    Text("\(g.title) · \(Int((g.fraction * 100).rounded()))%").tag(g.rawValue)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Tomorrow I want to")
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                // The goal wraps instead of being cut ("meinen Schlafbedarf erre…").
                Text(goal.title)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(ZoopType.icon(12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .font(ZoopType.label.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, ZoopSpacing.s)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 25, style: .continuous).fill(StrandPalette.surfaceRaised))
        }
    }

    // MARK: Alarm

    struct AlarmGroup: Identifiable {
        let days: [Int]
        let minutes: Int?
        var id: String { days.map(String.init).joined(separator: ",") + "-\(minutes ?? -1)" }
    }

    /// Monday first.
    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]

    private var groups: [AlarmGroup] {
        let on = behavior.smartAlarmWeekdays
        var byTime: [Int: [Int]] = [:]
        var off: [Int] = []
        for d in Self.weekOrder {
            if on.isEmpty || on.contains(d) {
                byTime[overrides[d] ?? behavior.smartAlarmMinutes, default: []].append(d)
            } else {
                off.append(d)
            }
        }
        var out = byTime
            .sorted { (Self.weekOrder.firstIndex(of: $0.value[0]) ?? 0) < (Self.weekOrder.firstIndex(of: $1.value[0]) ?? 0) }
            .map { AlarmGroup(days: $0.value, minutes: $0.key) }
        if !off.isEmpty { out.append(AlarmGroup(days: off, minutes: nil)) }
        return out
    }

    private var alarmCard: some View {
        ListCard {
            HStack {
                Text("Alarm")
                    .font(ZoopType.headline.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { behavior.smartAlarmEnabled },
                    set: { behavior.smartAlarmEnabled = $0; model.applySmartAlarm() }))
                    .labelsHidden()
                    .tint(StrandPalette.accent)
            }
            .frame(height: 58)
            ForEach(groups) { g in
                Divider().overlay(StrandPalette.hairline)
                Button { editing = g } label: {
                    HStack {
                        Text(Self.dayRange(g.days))
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text(g.minutes.map { PatternsScreen.clock($0) } ?? String(localized: "Off"))
                            .font(ZoopType.number(22, weight: .bold))
                            .foregroundStyle(g.minutes == nil || !behavior.smartAlarmEnabled
                                             ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(ZoopType.icon(12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(StrandPalette.hairline)
            Button { editing = AlarmGroup(days: [], minutes: behavior.smartAlarmMinutes) } label: {
                Label("Add a time", systemImage: "plus")
                    .font(ZoopType.label.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 50)
            }
            .buttonStyle(.plain)
        }
    }

    private func windDownCard(_ t: PatternsModel.Tonight) -> some View {
        ListCard {
            WindDownReminderRow(suggestedWakeMinute: t.wake.map { $0 / 60 }) { Task { await reload() } }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
        }
    }

    // MARK: Formatting

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func short(_ weekday: Int) -> String {
        Calendar.current.shortStandaloneWeekdaySymbols[(weekday - 1) % 7]
    }

    /// "Mon–Fri", "Sat–Sun", "Mon, Wed, Fri": runs of three or more consecutive days collapse to a range.
    static func dayRange(_ days: [Int]) -> String {
        if days.count == 7 { return String(localized: "Every day") }
        let idx = days.compactMap { weekOrder.firstIndex(of: $0) }.sorted()
        var parts: [String] = []
        var i = 0
        while i < idx.count {
            var j = i
            while j + 1 < idx.count && idx[j + 1] == idx[j] + 1 { j += 1 }
            let first = short(weekOrder[idx[i]]), last = short(weekOrder[idx[j]])
            if j - i >= 1 && (j - i >= 2 || idx[i] == 5) { parts.append("\(first)–\(last)") }
            else { parts.append(contentsOf: (i...j).map { short(weekOrder[idx[$0]]) }) }
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

}

#endif
