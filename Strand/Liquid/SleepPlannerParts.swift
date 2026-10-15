#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

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
                            .font(ZoopType.caption.weight(.semibold))
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
                    .font(ZoopType.headline.weight(.semibold))
                    .foregroundStyle(StrandPalette.primaryButtonText)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Capsule().fill(selected.isEmpty ? StrandPalette.textTertiary : StrandPalette.primaryButtonFill))
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
    /// Reached WITHOUT observing: only the alarm is read, inside the load task, while the app model
    /// publishes the smoothed heart rate every few seconds and re-ran this view mid-scroll for it.
    private var model: AppModel? { AppModel.shared }
    @StateObject private var patterns = PatternsModel()

    var body: some View {
        NavigationLink(value: TabRoute.sleepPlanner) {
            ContentCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "moon.stars.fill")
                            .font(ZoopType.icon(15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(StrandPalette.surfaceBase))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tonight")
                                .font(ZoopType.caption.weight(.semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                            Text(line)
                                .font(ZoopType.headline.monospacedDigit())
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(ZoopType.icon(13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if let w = patterns.bedtime, w.windowMean - w.overallMean >= 3 {
                        Text(String(localized: "You recover best after falling asleep between \(PatternsScreen.clock(w.startMinute)) and \(PatternsScreen.clock(w.endMinute))."))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: repo.refreshSeq) {
            await patterns.loadQuick(repo: repo, alarm: model?.nextArmedStrapAlarm())
            await patterns.loadBedtime(repo: repo)
        }
    }

    private var line: String {
        guard let t = patterns.tonight, let bed = t.bedtime else { return String(localized: "Plan your sleep") }
        let wake = t.wake.map { PatternsScreen.clock($0 / 60) } ?? SleepPlannerScreen.unset
        return "\(PatternsScreen.clock(bed / 60)) → \(wake)"
    }
}

/// The planner as a route destination: hands it the alarm settings from the app model.
struct SleepPlannerHost: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { SleepPlannerScreen(behavior: model.behavior) }
}
#endif
