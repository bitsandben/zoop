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
    @AppStorage(SmartWakeWindow.windowKey) private var windowMinutes = 0
    @AppStorage(PuffinExperiment.defaultsKey) private var whoop5AlarmUnlocked = false
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
                if let t = patterns.tonight { tonightCard(t) }
                goalPicker
                alarmCard
                gentleWakeCard
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
                .font(.system(size: 18))
                .foregroundStyle(StrandPalette.stressHigh)
            Text("Your WHOOP 5/MG needs one switch for the alarm.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                whoop5AlarmUnlocked = true
                model.applySmartAlarm()
            } label: {
                Text("Turn on")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(StrandPalette.textPrimary))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceRaised))
    }

    // MARK: Tonight

    private func tonightCard(_ t: PatternsModel.Tonight) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                timeColumn(t.bedtime.map { PatternsScreen.clock($0 / 60) } ?? "–",
                           label: "Bedtime", icon: "moon.fill")
                Spacer()
                timeColumn(t.wake.map { PatternsScreen.clock($0 / 60) } ?? "–",
                           label: alarm == nil ? "Wake up" : "Alarm", icon: "alarm.fill")
            }
            ZStack {
                Capsule().fill(StrandPalette.accent.opacity(0.22)).frame(height: 8)
                Text(Self.duration(t.inBedMin))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Capsule().fill(StrandPalette.surfaceRaised))
                    .overlay(Capsule().strokeBorder(StrandPalette.textPrimary, lineWidth: 1.5))
            }
            Text("Time in bed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(18)
        .background(ZoopPanelSurface())
    }

    private func timeColumn(_ value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(StrandFont.display(38))
                .foregroundStyle(StrandPalette.textPrimary)
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
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
                Text(goal.title)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Capsule().fill(StrandPalette.surfaceRaised))
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
        VStack(spacing: 0) {
            HStack {
                Text("Alarm")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { behavior.smartAlarmEnabled },
                    set: { behavior.smartAlarmEnabled = $0; model.applySmartAlarm() }))
                    .labelsHidden()
                    .tint(StrandPalette.accent)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            ForEach(groups) { g in
                Divider().overlay(StrandPalette.hairline).padding(.leading, 16)
                Button { editing = g } label: {
                    HStack {
                        Text(Self.dayRange(g.days))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text(g.minutes.map { PatternsScreen.clock($0) } ?? String(localized: "Off"))
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(g.minutes == nil || !behavior.smartAlarmEnabled
                                             ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(StrandPalette.hairline).padding(.leading, 16)
            Button { editing = AlarmGroup(days: [], minutes: behavior.smartAlarmMinutes) } label: {
                Label("Add a time", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
            }
            .buttonStyle(.plain)
        }
        .background(ZoopPanelSurface())
    }

    private var gentleWakeCard: some View {
        VStack(spacing: 0) {
            Menu {
                Picker("Gentle wake", selection: Binding(
                    get: { windowMinutes },
                    set: { windowMinutes = $0; model.applySmartAlarm() })) {
                    ForEach(SmartWakeWindow.choices, id: \.self) { m in
                        Text(m == 0 ? String(localized: "Off") : String(localized: "Up to \(m) min earlier")).tag(m)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gentle wake")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Wakes you a little earlier if you're sleeping lightly")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Text(windowMinutes == 0 ? String(localized: "Off") : String(localized: "\(windowMinutes) min"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(windowMinutes == 0 ? StrandPalette.textSecondary : StrandPalette.accent)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(16)
            }
            if let t = patterns.tonight {
                Divider().overlay(StrandPalette.hairline).padding(.leading, 16)
                WindDownReminderRow(suggestedWakeMinute: t.wake.map { $0 / 60 }) { Task { await reload() } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(ZoopPanelSurface())
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

    static func weekdayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        return f.string(from: date)
    }
}

// MARK: - Time sheet

/// Set a wake time for some weekdays. Selected days get the time; days taken out of an existing row stop
/// ringing.
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
            HStack(spacing: 6) {
                ForEach(SleepPlannerScreen.weekOrder, id: \.self) { d in
                    let on = selected.contains(d)
                    Button {
                        if on { selected.remove(d) } else { selected.insert(d) }
                    } label: {
                        Text(String(SleepPlannerScreen.short(d).prefix(2)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(on ? StrandPalette.accent : StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
            DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
            Button(action: save) {
                Text("Save")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(selected.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty && originalDays.isEmpty)
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDragIndicator(.visible)
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
        // At least one day stays on; an empty set would read as every day.
        if !days.isEmpty { behavior.smartAlarmWeekdays = days.count == 7 ? [] : days }
        if !behavior.smartAlarmEnabled { behavior.smartAlarmEnabled = true }
        model.applySmartAlarm()
        onSave()
        dismiss()
    }
}

/// The Sleep screen's way into the planner: tonight's bedtime and alarm, and the bedtime that has
/// suited you best, when the history shows one.
struct SleepPlanEntryCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @StateObject private var patterns = PatternsModel()

    var body: some View {
        NavigationLink(value: TabRoute.sleepPlanner) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(StrandPalette.surfaceBase))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tonight")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(line)
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let w = patterns.bedtime, w.windowMean - w.overallMean >= 3 {
                    Text(String(localized: "You recover best after falling asleep between \(PatternsScreen.clock(w.startMinute)) and \(PatternsScreen.clock(w.endMinute))."))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(ZoopPanelSurface())
        }
        .buttonStyle(.plain)
        .task(id: repo.refreshSeq) {
            await patterns.loadQuick(repo: repo, alarm: model.nextArmedStrapAlarm())
            await patterns.loadBedtime(repo: repo)
        }
    }

    private var line: String {
        guard let t = patterns.tonight, let bed = t.bedtime else { return String(localized: "Plan your sleep") }
        let wake = t.wake.map { PatternsScreen.clock($0 / 60) } ?? "–"
        return "\(PatternsScreen.clock(bed / 60)) → \(wake)"
    }
}

/// The planner as a route destination: hands it the alarm settings from the app model.
struct SleepPlannerHost: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { SleepPlannerScreen(behavior: model.behavior) }
}
#endif
