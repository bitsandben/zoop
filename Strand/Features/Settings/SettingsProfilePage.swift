import SwiftUI
import PhotosUI
import StrandDesign
import StrandAnalytics

/// Profile & goals: the body numbers that power zones, calories and baselines, plus units and the
/// definition of a day.
struct SettingsProfilePage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var profile: ProfileStore

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue

    /// Cleared back to nil once the picked photo's bytes are loaded, so the same photo can be re-picked.
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var showStepsCalibration = false

    private var fields: SettingsBodyFields {
        SettingsBodyFields(profile: profile, imperial: UnitSystem(rawValue: unitSystemRaw) == .imperial)
    }

    var body: some View {
        SettingsPageScaffold(title: "zoop.settings.profile.title") {
            bodyGroup
            heartRateGroup
            SettingsUnitsGroup()
            dayAndStepsGroup
            streakGroup
        }
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: model.repo, onClose: { showStepsCalibration = false })
                .environmentObject(profile)
        }
    }

    // MARK: Body

    private var bodyGroup: some View {
        SettingsGroup(title: "zoop.settings.group.body", footer: Text("zoop.settings.profile.footer")) {
            photoRow.listCardRow(isFirst: true)
            SettingsRow(label: "Date of birth") {
                HStack(spacing: ZoopSpacing.m) {
                    Text(verbatim: "\(profile.age)")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                    // #146: age is derived from the date of birth, so it advances on its own.
                    DatePicker("Date of birth", selection: $profile.dateOfBirth,
                               in: ProfileStore.dateOfBirthRange, displayedComponents: .date)
                        .labelsHidden()
                        .tint(StrandPalette.accent)
                        .accessibilityLabel("Date of birth, age \(profile.age) years")
                }
            }
            // A menu rather than a segmented control: segments overflow the row with long German labels
            // or enlarged text (#43).
            SettingsMenuRow(label: "Sex", selection: $profile.sex) {
                Text("Male").tag("male")
                Text("Female").tag("female")
                Text("Non-binary").tag("nonbinary")
            }
            SettingsRow(label: "Weight") { fields.weight }
            SettingsRow(label: "Height") { fields.height }
            SettingsRow(label: "zoop.settings.profile.waist", note: "zoop.settings.profile.waistNote") { fields.waist }
        }
    }

    /// The avatar stays inside the body group so an optional photo does not cost a top-level section.
    private var photoRow: some View {
        let hasAvatar = profile.hasAvatar
        return HStack(spacing: ZoopSpacing.m) {
            ProfileAvatarView(imageData: profile.avatarImageData, size: ZoopMetrics.profileAvatarDiameter)
                .accessibilityLabel(hasAvatar ? "Your profile photo" : "No profile photo set")
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    Text(hasAvatar ? "Change photo" : "Choose photo")
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.accent)
                }
                SettingsNote("zoop.settings.profile.photoNote")
            }
            Spacer(minLength: 0)
            if hasAvatar {
                Button { profile.clearAvatar() } label: { Image(systemName: "trash") }
                    .buttonStyle(ZoopButtonStyle(.tertiary))
                    .accessibilityLabel("Remove photo")
            }
        }
        .onChangeCompat(of: avatarPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { profile.setAvatar(data) }
                    avatarPickerItem = nil
                }
            }
        }
    }

    // MARK: Heart rate

    private var heartRateGroup: some View {
        SettingsGroup(title: "zoop.settings.group.heartRate") {
            SettingsRow(label: "Max heart rate", isFirst: true) {
                VStack(alignment: .trailing, spacing: ZoopSpacing.xs) {
                    fields.hrMax
                    Text(profile.hrMaxOverride > 0 ? "Manual override" : "Auto · \(profile.hrMax) bpm (Tanaka)")
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            // #531: five personal bpm lower bounds replace the %HRmax bands while this is on.
            SettingsToggleRow(
                label: "Custom HR zones",
                isOn: Binding(get: { profile.hasCustomHRZones }, set: { profile.setCustomHRZonesEnabled($0) }),
                note: profile.hasCustomHRZones ? "zoop.settings.zones.note" : nil)
            if profile.hasCustomHRZones {
                ForEach(profile.hrZoneThresholds.indices, id: \.self) { index in
                    SettingsRow(label: "Zone \(index + 1) starts") { fields.zoneStart(index) }
                }
            }
        }
    }

    // MARK: Day & steps

    private var dayAndStepsGroup: some View {
        SettingsGroup(title: "zoop.settings.group.dayAndSteps") {
            SettingsMenuRow(
                label: "Day cycle",
                selection: Binding(
                    get: { DayCycleMode.persisted(dayCycleModeRaw) },
                    set: { mode in
                        dayCycleModeRaw = mode.rawValue
                        // Steps and in-progress Effort are bucketed by day, so the recent days re-score.
                        Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                    }),
                note: dayCycleModeRaw == DayCycleMode.midnight.rawValue
                    ? "zoop.settings.dayCycle.midnight" : "zoop.settings.dayCycle.sleep",
                isFirst: true
            ) {
                Text("Main sleep").tag(DayCycleMode.sleepOnset)
                Text(verbatim: "00:00").tag(DayCycleMode.midnight)
            }
            // #139: the 5/MG step counter can overcount by ~24x, hence a divisor up to 30.
            SettingsRow(label: "Step calibration", note: "zoop.settings.steps.tickNote") { fields.stepTicks }
            // A different thing from the divisor above: a WHOOP 4.0 sends no step count at all, so its steps
            // are estimated from motion and calibrated against the phone.
            SettingsActionRow(label: "Steps estimate", value: stepsCalibrationSummary) {
                showStepsCalibration = true
            }
            .accessibilityHint(Text("zoop.settings.steps.estimateNote"))
        }
    }

    private var stepsCalibrationSummary: String {
        if profile.stepsManualCoefficient > 0 { return String(localized: "Manual") }
        if profile.stepsCalibrationCoefficient > 0 {
            return String(localized: "Auto · \(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) confidence")
        }
        return String(localized: "Not calibrated")
    }

    // MARK: Streak

    /// #569: consecutive days with a Charge score. Read-only, so it sits with the goals rather than in
    /// a card of its own.
    private var streakGroup: some View {
        let days = model.repo.days
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let streak = StreakCalculator.streaks(dayKeys: days.map { $0.day },
                                              qualified: days.map { $0.recovery != nil },
                                              today: today)
        return SettingsGroup {
            SettingsRow(label: "Streak", isFirst: true) {
                Text("zoop.settings.streak.value \(streak.current) \(streak.longest)")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
