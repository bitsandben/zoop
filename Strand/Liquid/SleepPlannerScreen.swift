#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Sleep planner
//
// Tonight in one place: when to be in bed for the chosen share of the sleep need, when the strap alarm
// wakes you, and the alarm itself (on/off, mode, time, weekly schedule). Every time shown here comes from
// the same two funnels the rest of the app reads: `AppModel.nextArmedStrapAlarm` for the alarm and
// `PatternsModel.tonight` for the bedtime, so Home, Alarms and this screen cannot disagree.

struct SleepPlannerScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var behavior: BehaviorStore
    @StateObject private var patterns = PatternsModel()
    @AppStorage(SleepGoal.storageKey) private var goalRaw = SleepGoal.peak.rawValue
    @AppStorage(SmartWakeWindow.windowKey) private var windowMinutes = 0
    @State private var editTime = false

    init(behavior: BehaviorStore) { self.behavior = behavior }

    private var goal: SleepGoal { SleepGoal(rawValue: goalRaw) ?? .peak }
    private var alarm: Date? { model.nextArmedStrapAlarm() }

    /// The weekday the planner edits: the next alarm's, else tomorrow's.
    private var targetWeekday: Int {
        let date = alarm ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.component(.weekday, from: date)
    }

    private var targetWakeMinutes: Int {
        WindDownNudge.perDayWakeOverrides[targetWeekday] ?? behavior.smartAlarmMinutes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summary
                goalPicker
                if let t = patterns.tonight { timeline(t) }
                alarmSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Sleep planner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AlarmScheduleScreen(behavior: behavior)
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .accessibilityLabel("My schedule")
            }
        }
        .task(id: "\(repo.refreshSeq)-\(goalRaw)-\(behavior.smartAlarmEnabled)-\(behavior.smartAlarmMinutes)") {
            await reload()
        }
        .sheet(isPresented: $editTime) {
            AlarmTimeSheet(behavior: behavior, days: [targetWeekday], minutes: targetWakeMinutes) {
                Task { await reload() }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func reload() async {
        await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm())
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 56, height: 56)
                .background(SquircleShape().fill(StrandPalette.surfaceRaised))
            Text(summaryText)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The alarm's state in words: when it next buzzes, that it is off, or that it is on but this strap
    /// will not take it (a WHOOP 5/MG arms only with Experimental on, #864).
    private var alarmStatus: String {
        if let a = alarm { return String(localized: "Next: \(Self.weekdayTime(a))") }
        if behavior.smartAlarmEnabled { return String(localized: "Not armed: a WHOOP 5/MG needs Experimental on in Settings") }
        return String(localized: "Off")
    }

    private var summaryText: String {
        guard let t = patterns.tonight, let bed = t.bedtime else {
            return String(localized: "Set an alarm and Zoop works out when you should be in bed.")
        }
        let pct = Int((t.goal * 100).rounded())
        let bedText = PatternsScreen.clock(bed / 60)
        if let a = alarm {
            if windowMinutes > 0 {
                let from = HomeMomentCard.time(a.addingTimeInterval(-Double(windowMinutes * 60)))
                return String(localized: "Your alarm wakes you between \(from) and \(HomeMomentCard.time(a)), when you sleep lightest. Be in bed by \(bedText) to get \(pct)% of your sleep need.")
            }
            return String(localized: "Your alarm goes off at \(HomeMomentCard.time(a)). Be in bed by \(bedText) to get \(pct)% of your sleep need.")
        }
        let wake = t.wake.map { PatternsScreen.clock($0 / 60) } ?? "–"
        if behavior.smartAlarmEnabled {
            return String(localized: "Your alarm is not armed on this strap. To wake at \(wake) with \(pct)% of your sleep need, be in bed by \(bedText).")
        }
        return String(localized: "No alarm set. To wake at \(wake) with \(pct)% of your sleep need, be in bed by \(bedText).")
    }

    // MARK: Goal

    private var goalPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tomorrow I want to")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            Menu {
                Picker("Goal", selection: $goalRaw) {
                    ForEach(SleepGoal.allCases) { g in
                        Text("\(g.title) · \(Int((g.fraction * 100).rounded()))%").tag(g.rawValue)
                    }
                }
            } label: {
                HStack {
                    Text(goal.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(Int((goal.fraction * 100).rounded()))%")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.accent)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Capsule().strokeBorder(StrandPalette.textPrimary.opacity(0.6), lineWidth: 1.5))
            }
        }
    }

    // MARK: Timeline

    private func timeline(_ t: PatternsModel.Tonight) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                timeColumn(t.bedtime.map { PatternsScreen.clock($0 / 60) } ?? "–",
                           label: "Recommended bedtime", icon: "sunset.fill")
                Spacer()
                timeColumn(t.wake.map { PatternsScreen.clock($0 / 60) } ?? "–",
                           label: alarm == nil ? "Usual wake" : "Your wake time", icon: "alarm.fill")
            }
            ZStack {
                Capsule().fill(StrandPalette.accent.opacity(0.22)).frame(height: 10)
                Capsule().strokeBorder(StrandPalette.accent, lineWidth: 1.5).frame(height: 10)
                Text(Self.duration(t.inBedMin))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(StrandPalette.surfaceBase))
                    .overlay(Capsule().strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5))
            }
            Text("Time in bed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            if t.goal < 1, let full = t.fullNeedBedtime, let wake = t.wake {
                Text(String(localized: "For your full need: \(PatternsScreen.clock(full / 60)) – \(PatternsScreen.clock(wake / 60))"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(String(localized: "Sleep need \(Self.duration(t.need.totalMin)), with time to fall asleep and wake in the night added."))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
        .background(ZoopPanelSurface())
    }

    private func timeColumn(_ value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(StrandFont.display(34))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: Alarm

    private var alarmSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(StrandPalette.surfaceBase))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Strap alarm")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(alarmStatus)
                        .font(StrandFont.footnote)
                        .foregroundStyle(alarm == nil ? StrandPalette.textSecondary : StrandPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { behavior.smartAlarmEnabled },
                    set: { behavior.smartAlarmEnabled = $0; model.applySmartAlarm() }))
                    .labelsHidden()
                    .tint(StrandPalette.accent)
            }
            HStack(spacing: 10) {
                Menu {
                    Picker("Wake window", selection: Binding(
                        get: { windowMinutes },
                        set: { windowMinutes = $0; model.applySmartAlarm() })) {
                        ForEach(SmartWakeWindow.choices, id: \.self) { m in
                            Text(m == 0 ? String(localized: "Off") : String(localized: "\(m) min before")).tag(m)
                        }
                    }
                } label: {
                    tileLabel(caption: "Wake window",
                              value: windowMinutes == 0 ? String(localized: "Off") : String(localized: "\(windowMinutes) min"))
                }
                tile(caption: "Alarm set to", value: PatternsScreen.clock(targetWakeMinutes)) { editTime = true }
            }
            if windowMinutes > 0 {
                Text(String(localized: "Experimental. In the \(windowMinutes) minutes before your alarm, Zoop checks every few minutes for movement or a rising heart rate and buzzes as soon as it sees one. If it sees nothing, or Zoop isn't running, the alarm rings at its time."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let t = patterns.tonight {
                WindDownReminderRow(suggestedWakeMinute: t.wake.map { $0 / 60 }) { Task { await reload() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .background(ZoopPanelSurface())
    }

    private func tile(caption: LocalizedStringKey, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(caption: caption, value: value) }
            .buttonStyle(.plain)
    }

    private func tileLabel(caption: LocalizedStringKey, value: String) -> some View {
            VStack(spacing: 4) {
                Text(caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceBase))
    }

    // MARK: Formatting

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func weekdayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        return f.string(from: date)
    }
}

// MARK: - Weekly schedule

/// The alarm per weekday, grouped by time like a clock app's schedule: tap a group to change its time or
/// its days. Days that are off are listed on their own.
struct AlarmScheduleScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var behavior: BehaviorStore
    @State private var editing: Group?
    @State private var overrides = WindDownNudge.perDayWakeOverrides

    struct Group: Identifiable {
        let days: [Int]
        let minutes: Int?
        var id: String { days.map(String.init).joined(separator: ",") + "-\(minutes ?? -1)" }
    }

    /// Monday first.
    private static let order = [2, 3, 4, 5, 6, 7, 1]

    private var groups: [Group] {
        let on = behavior.smartAlarmWeekdays
        var byTime: [Int: [Int]] = [:]
        var off: [Int] = []
        for d in Self.order {
            if on.isEmpty || on.contains(d) {
                byTime[overrides[d] ?? behavior.smartAlarmMinutes, default: []].append(d)
            } else {
                off.append(d)
            }
        }
        var out = byTime.sorted { (Self.order.firstIndex(of: $0.value[0]) ?? 0) < (Self.order.firstIndex(of: $1.value[0]) ?? 0) }
            .map { Group(days: $0.value, minutes: $0.key) }
        if !off.isEmpty { out.append(Group(days: off, minutes: nil)) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text("Strap alarm")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { behavior.smartAlarmEnabled },
                        set: { behavior.smartAlarmEnabled = $0; model.applySmartAlarm() }))
                        .labelsHidden().tint(StrandPalette.accent)
                }
                .padding(16)
                .background(ZoopPanelSurface())

                ForEach(groups) { g in
                    Button { editing = g } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(g.days.map(Self.short).joined(separator: " · "))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                            HStack {
                                Text(g.minutes.map { PatternsScreen.clock($0) } ?? String(localized: "Off"))
                                    .font(StrandFont.display(38))
                                    .foregroundStyle(g.minutes == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ZoopPanelSurface())
                        .opacity(behavior.smartAlarmEnabled ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                }
                Text("The strap buzzes at these times. Tap a row to change its time or days.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("My schedule")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { g in
            AlarmTimeSheet(behavior: behavior, days: g.days, minutes: g.minutes ?? behavior.smartAlarmMinutes) {
                overrides = WindDownNudge.perDayWakeOverrides
            }
            .presentationDetents([.large])
        }
    }

    static func short(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        return symbols[(weekday - 1) % 7]
    }
}

// MARK: - Time sheet

/// Set a wake time for some weekdays. Selected days get the time (as their own override unless it equals
/// the base time); days taken out of the selection stop ringing.
struct AlarmTimeSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var behavior: BehaviorStore
    let originalDays: [Int]
    let onSave: () -> Void
    @State private var selected: Set<Int>
    @State private var time: Date
    @Environment(\.dismiss) private var dismiss

    init(behavior: BehaviorStore, days: [Int], minutes: Int, onSave: @escaping () -> Void) {
        self.behavior = behavior
        self.originalDays = days
        self.onSave = onSave
        _selected = State(initialValue: Set(days))
        var c = DateComponents(); c.hour = minutes / 60; c.minute = minutes % 60
        _time = State(initialValue: Calendar.current.date(from: c) ?? Date())
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Wake time")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: 6) {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in
                    let on = selected.contains(d)
                    Button {
                        if on { selected.remove(d) } else { selected.insert(d) }
                    } label: {
                        Text(AlarmScheduleScreen.short(d))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Circle().fill(on ? StrandPalette.accent : StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                }
            }
            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
            Button(action: save) {
                Text("Save")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(StrandPalette.textPrimary))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationBackground(StrandPalette.surfaceBase)
    }

    private func save() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let minutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
        var days = behavior.smartAlarmWeekdays.isEmpty ? Set(1...7) : behavior.smartAlarmWeekdays
        for d in selected {
            days.insert(d)
            WindDownNudge.setWakeOverride(weekday: d, minutes: minutes == behavior.smartAlarmMinutes ? nil : minutes)
        }
        for d in originalDays where !selected.contains(d) { days.remove(d) }
        // Keep at least one day on; an empty set would read as every day.
        if !days.isEmpty { behavior.smartAlarmWeekdays = days.count == 7 ? [] : days }
        if !behavior.smartAlarmEnabled { behavior.smartAlarmEnabled = true }
        model.applySmartAlarm()
        onSave()
        dismiss()
    }
}
#endif

#if os(iOS)
/// The planner as a route destination: hands it the alarm settings from the app model.
struct SleepPlannerHost: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { SleepPlannerScreen(behavior: model.behavior) }
}
#endif
