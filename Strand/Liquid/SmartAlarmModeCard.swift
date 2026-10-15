#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Smart alarm mode (sleep planner)
//
// What the alarm waits for inside its wake window: a fixed time (optionally earlier in light sleep), tonight's
// sleep need, or a recovery estimate. The strap is always armed at the window end; the settings live in
// `GoalWakeSettings` and every change re-arms through `applySmartAlarm`.

struct SmartAlarmModeCard: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(GoalWakeSettings.modeKey) private var modeRaw = GoalWake.Mode.fixedTime.rawValue
    @AppStorage(GoalWakeSettings.thresholdKey) private var threshold = GoalWake.defaultRecoveryThreshold
    @AppStorage(GoalWakeSettings.preferLightKey) private var preferLight = true
    @AppStorage(SmartWakeWindow.windowKey) private var windowMinutes = 0
    @AppStorage(SmartWakeLiveStream.keepAwakeKey) private var keepAwake = true
    /// The deadline the window ends at (the next plain alarm), for the "06:20–06:50" readout.
    let deadline: Date?

    private var mode: GoalWake.Mode { GoalWake.Mode(rawValue: modeRaw) ?? .fixedTime }
    private var effectiveWindow: Int { GoalWakeSettings.windowMinutes }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader("Smart alarm", subtitle: "Experimental")
            ListCard {
                modeRow
                if mode == .recovery {
                    Divider().overlay(StrandPalette.hairline)
                    thresholdRow
                }
                Divider().overlay(StrandPalette.hairline)
                windowRow
                if mode != .fixedTime {
                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: Binding(get: { preferLight }, set: { preferLight = $0; model.applySmartAlarm() })) {
                        Text("Prefer light sleep")
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .tint(StrandPalette.accent)
                    .frame(minHeight: 54)
                }
                if effectiveWindow > 0 {
                    Divider().overlay(StrandPalette.hairline)
                    keepAwakeRow
                }
            }
            Text("The strap always wakes you by the window end; earlier needs Zoop running in the background with the strap in range.")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ZoopSpacing.xs)
        }
    }

    /// Holds the strap's live heart rate open around the window so iOS keeps waking the app (`SmartWakeLiveStream`).
    private var keepAwakeRow: some View {
        Toggle(isOn: Binding(get: { keepAwake }, set: { keepAwake = $0; model.applySmartAlarm() })) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text("Keep the app awake in the window")
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Streams live heart rate from 10 min before the window until you wake, so strap and phone use more battery for about that long.")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(StrandPalette.accent)
        .padding(.vertical, ZoopSpacing.s)
        .frame(minHeight: 54)
    }

    private var modeRow: some View {
        menuRow(title: "Wake me", value: SmartAlarmNightText.mode(mode)) {
            Picker("Wake me", selection: Binding(get: { modeRaw }, set: { modeRaw = $0; model.applySmartAlarm() })) {
                ForEach(GoalWake.Mode.allCases, id: \.self) { m in
                    Text(SmartAlarmNightText.mode(m)).tag(m.rawValue)
                }
            }
        }
    }

    private var thresholdRow: some View {
        menuRow(title: "Recovery at least", value: "≥ \(SmartAlarmNightText.percent(Double(threshold)))") {
            Picker("Recovery at least", selection: Binding(get: { threshold }, set: { threshold = $0; model.applySmartAlarm() })) {
                ForEach(GoalWakeSettings.thresholdChoices, id: \.self) { v in
                    Text(v == Goal.green ? String(localized: "\(v) % (green)") : "\(v) %").tag(v)
                }
            }
        }
    }

    private var windowRow: some View {
        menuRow(title: "Wake window", value: windowValue) {
            Picker("Wake window", selection: Binding(get: { effectiveWindow },
                                                     set: { windowMinutes = $0; model.applySmartAlarm() })) {
                ForEach(SmartWakeWindow.choices.filter { mode == .fixedTime || $0 > 0 }, id: \.self) { m in
                    Text(m == 0 ? String(localized: "Off") : String(localized: "\(m) min")).tag(m)
                }
            }
        }
    }

    /// "06:20–06:50" when the next alarm is known, else the length.
    private var windowValue: String {
        guard effectiveWindow > 0 else { return String(localized: "Off") }
        guard let deadline else { return String(localized: "\(effectiveWindow) min") }
        let start = deadline.addingTimeInterval(-Double(effectiveWindow * 60))
        return "\(start.formatted(date: .omitted, time: .shortened))–\(deadline.formatted(date: .omitted, time: .shortened))"
    }

    private enum Goal { static let green = GoalWake.defaultRecoveryThreshold }

    private func menuRow<P: View>(title: LocalizedStringKey, value: String, @ViewBuilder picker: () -> P) -> some View {
        Menu { picker() } label: {
            HStack {
                Text(title)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(value)
                    .font(ZoopType.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
    }
}

/// "Today: woken at 06:41 – sleep need reached", from the same night record the Test Centre lists.
struct SmartAlarmMorningLine: View {
    @ObservedObject private var log = SmartAlarmNightLog.shared

    var body: some View {
        let now = Int(Date().timeIntervalSince1970)
        if let line = SmartAlarmNightText.morningLine(log.lastFinished(now: now), now: now) {
            Label(line, systemImage: "sunrise")
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ZoopSpacing.xs)
        }
    }
}
#endif
