import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Recovery calibration UI (Zoop)
//
// Surfaces over `RecoveryCalibrationStore`:
//   - `RecoveryCalibrationInviteCard`: the one-time Home invite to start calibration.
//   - `MorningCheckInSheet`: the morning question (five faces plus symptom tiles) as a bottom sheet,
//     raised once a morning by the iOS shell (`MorningCheckInPrompt`) and for edits from
//     `MorningCheckInSummaryRow` (today's answer, on the Recovery detail and the calibration screen).
//   - `RecoveryCalibrationView`: the full screen (Settings, the Home card, the Recovery detail): on/off,
//     progress through the calibration phase, the personal weights next to the standard ones, and how
//     the mornings compared with the measured Recovery.
//   - `RecoveryInsightCard`: on the Recovery detail, the "what shaped it" breakdown plus the
//     calibration status.

/// Shared wording for the calibration phase, so the Home card, the detail card and the screen agree.
enum RecoveryCalibrationCopy {
    static func phaseLine(_ r: RecoveryCalibrationResult) -> String {
        switch r.phase {
        case .collecting:
            return String(localized: "Collecting: \(r.mornings) of \(RecoveryCalibration.previewDays) mornings until the first preview")
        case .preview:
            return String(localized: "Preview: \(r.mornings) of \(RecoveryCalibration.fullDays) mornings, getting more precise every day")
        case .calibrated:
            return String(localized: "Calibrated on \(r.mornings) mornings, still learning with every answer")
        }
    }

    static func termName(_ t: ChargeTerm) -> String {
        switch t {
        case .hrv: return String(localized: "Heart rate variability")
        case .rhr: return String(localized: "Resting heart rate")
        case .sleep: return String(localized: "Sleep vs need")
        case .resp: return String(localized: "Respiratory rate")
        case .skinTemp: return String(localized: "Skin temperature")
        }
    }

    static func feelingLabel(_ v: Int) -> String {
        switch v {
        case ...1: return String(localized: "Exhausted")
        case 2: return String(localized: "Tired")
        case 3: return String(localized: "Okay")
        case 4: return String(localized: "Good")
        default: return String(localized: "Fully recovered")
        }
    }

    /// The face for a 1–5 answer, from exhausted to fully recovered.
    static func feelingFace(_ v: Int) -> String {
        switch v {
        case ...1: return "😫"
        case 2: return "😕"
        case 3: return "😐"
        case 4: return "🙂"
        default: return "😄"
        }
    }

    /// "2/5 · Tired · Headache, Stressed" — the answer and any reported symptoms on one line.
    static func summary(_ c: MorningCheckIn) -> String {
        var symptoms: [String] = []
        if c.headache { symptoms.append(String(localized: "Headache")) }
        if c.soreness { symptoms.append(String(localized: "Sore muscles")) }
        if c.ill { symptoms.append(String(localized: "Feeling ill")) }
        if c.stress { symptoms.append(String(localized: "Stressed")) }
        var parts = ["\(c.feeling)/5", feelingLabel(c.feeling)]
        if !symptoms.isEmpty { parts.append(symptoms.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Progress bar through the calibration phase (to `fullDays`).
private struct CalibrationProgressBar: View {
    let result: RecoveryCalibrationResult
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                Capsule().fill(StrandPalette.accent)
                    .frame(width: g.size.width * min(1, Double(result.mornings) / Double(RecoveryCalibration.fullDays)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Home invite

/// The one-time Home invite to start calibration. Shown until it is accepted or dismissed; once
/// calibration is on, the morning question lives in `MorningCheckInSheet` (auto-presented by the iOS
/// shell) and today's answer on the Recovery detail, so Home shows nothing.
struct RecoveryCalibrationInviteCard: View {
    @AppStorage(RecoveryCalibrationStore.enabledKey) private var enabled = false
    @AppStorage(RecoveryCalibrationStore.inviteDismissedKey) private var inviteDismissed = false

    var body: some View {
        if !enabled && !inviteDismissed {
            ZoopCard {
                VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                    Text("Personal Recovery").strandOverline()
                    Text("Tune Recovery to how you feel")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Answer one short question each morning. After a week Zoop shows a first preview of your personal weighting, and it keeps getting more precise.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ZoopMetrics.space2) {
                        ZoopButton("Start calibration", systemImage: "slider.horizontal.3") {
                            enabled = true
                        }
                        ZoopButton("Not now", kind: .tertiary) { inviteDismissed = true }
                    }
                }
            }
        }
    }
}

// MARK: - Morning check-in sheet

/// The morning question as a bottom sheet: five faces for how recovered the wearer feels, a grid of
/// symptom tiles, and Save. Used for the automatic morning prompt and for editing from the Recovery
/// detail; it preloads the day's stored answer when there is one.
struct MorningCheckInSheet: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var intelligence: IntelligenceEngine
    @Environment(\.dismiss) private var dismiss

    var day: String = Repository.dayString(Date())
    /// Called after the answer is stored and Recovery re-scored.
    var onSaved: (MorningCheckIn) -> Void = { _ in }

    @State private var feeling: Int?
    @State private var headache = false
    @State private var soreness = false
    @State private var ill = false
    @State private var stress = false
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopMetrics.space6) {
                VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
                    Text("Good morning").strandOverline()
                    Text("How do you feel this morning?")
                        .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                faces
                VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                    Text("Anything else?")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoopMetrics.space3),
                                        GridItem(.flexible(), spacing: ZoopMetrics.space3)],
                              spacing: ZoopMetrics.space3) {
                        symptomTile("Headache", systemImage: "brain.head.profile", isOn: $headache)
                        symptomTile("Sore muscles", systemImage: "figure.strengthtraining.traditional", isOn: $soreness)
                        symptomTile("Feeling ill", systemImage: "thermometer.medium", isOn: $ill)
                        symptomTile("Stressed", systemImage: "cloud.bolt.rain", isOn: $stress)
                    }
                }
                VStack(spacing: ZoopMetrics.space2) {
                    if saving {
                        ProgressView().tint(StrandPalette.accent).frame(maxWidth: .infinity)
                    } else {
                        ZoopButton("Save", systemImage: "checkmark", fullWidth: true) { save() }
                            .disabled(feeling == nil)
                    }
                    Text(RecoveryCalibrationCopy.phaseLine(RecoveryCalibrationStore.lastResult))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, ZoopMetrics.screenPadding)
            .padding(.top, ZoopMetrics.space6)
            .padding(.bottom, ZoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .task { await load() }
    }

    private var faces: some View {
        VStack(spacing: ZoopMetrics.space3) {
            HStack(spacing: ZoopMetrics.space2) {
                ForEach(Array(MorningCheckIn.scale), id: \.self) { v in
                    faceButton(v)
                }
            }
            Text(feeling.map { RecoveryCalibrationCopy.feelingLabel($0) } ?? String(localized: "Tap the face that fits"))
                .font(StrandFont.headline)
                .foregroundStyle(feeling == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }

    private func faceButton(_ v: Int) -> some View {
        let selected = feeling == v
        let shape = RoundedRectangle(cornerRadius: ZoopVisualStyle.compactRadius, style: .continuous)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { feeling = v }
        } label: {
            Text(verbatim: RecoveryCalibrationCopy.feelingFace(v))
                .font(.system(size: 34))
                .scaleEffect(selected ? 1.15 : 1)
                .opacity(feeling == nil || selected ? 1 : 0.45)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ZoopMetrics.space3)
                .background(shape.fill(selected ? StrandPalette.accent.opacity(0.22) : StrandPalette.surfaceInset))
                .overlay(shape.strokeBorder(selected ? StrandPalette.accent : Color.clear, lineWidth: 1.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(v), \(RecoveryCalibrationCopy.feelingLabel(v))"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func symptomTile(_ title: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>) -> some View {
        let on = isOn.wrappedValue
        let shape = RoundedRectangle(cornerRadius: ZoopVisualStyle.compactRadius, style: .continuous)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.wrappedValue.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textSecondary)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                }
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(ZoopMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(on ? StrandPalette.accent.opacity(0.18) : StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(on ? StrandPalette.accent : StrandPalette.hairline, lineWidth: on ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func load() async {
        guard let a = await repo.morningCheckIn(day: day) else { return }
        feeling = a.feeling; headache = a.headache; soreness = a.soreness; ill = a.ill; stress = a.stress
    }

    private func save() {
        guard let feeling, !saving else { return }
        let c = MorningCheckIn(feeling: feeling, headache: headache, soreness: soreness, ill: ill, stress: stress)
        saving = true
        Task {
            await repo.saveMorningCheckIn(day: day, c)
            // Re-score so today's symptoms and the refreshed personal weights reach the Recovery ring.
            await intelligence.analyzeRecent()
            await repo.refresh()
            saving = false
            onSaved(c)
            dismiss()
        }
    }
}

/// Today's answer with an Edit button, or an "Answer" button when today is still open. Presents
/// `MorningCheckInSheet` itself. Shown on the Recovery detail and the calibration screen.
struct MorningCheckInSummaryRow: View {
    @EnvironmentObject var repo: Repository
    @State private var answer: MorningCheckIn?
    @State private var loaded = false
    @State private var showSheet = false

    private var today: String { Repository.dayString(Date()) }

    var body: some View {
        ZoopCard {
            HStack(spacing: ZoopMetrics.space3) {
                if let answer {
                    Text(verbatim: RecoveryCalibrationCopy.feelingFace(answer.feeling))
                        .font(.system(size: 26))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ZoopMetrics.spaceHalf) {
                        Text("Morning check-in").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(verbatim: RecoveryCalibrationCopy.summary(answer))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: ZoopMetrics.space2)
                    ZoopButton("Edit", kind: .tertiary) { showSheet = true }
                } else {
                    Image(systemName: "sun.horizon").foregroundStyle(StrandPalette.accent)
                    Text("Morning check-in")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: ZoopMetrics.space2)
                    ZoopButton("Answer morning check-in", kind: .secondary) { showSheet = true }
                }
            }
            .opacity(loaded ? 1 : 0)
        }
        .task { await reload() }
        .sheet(isPresented: $showSheet) {
            MorningCheckInSheet(day: today) { answer = $0 }
                .presentationDetents([.medium, .large])
                .opaqueSheetBackground()
                .presentationDragIndicator(.visible)
        }
    }

    private func reload() async {
        answer = await repo.morningCheckIn(day: today)
        loaded = true
    }
}

// MARK: - Automatic morning prompt

/// When the iOS shell raises `MorningCheckInSheet` on its own: calibration on, today not answered, it is
/// morning, and the sheet was not already raised today. Raising it marks the day, so dismissing it
/// without an answer does not re-open it until tomorrow.
@MainActor
enum MorningCheckInPrompt {
    /// Local day (`Repository.dayString`) the sheet was last raised automatically.
    static let shownDayKey = "zoop.recoveryCalibration.checkInPromptDay"
    /// The prompt is a morning question; a sleep ending at or after this hour (a nap) does not open it.
    static let morningEndHour = 14

    @MainActor
    static func shouldPresent(repo: Repository, now: Date = Date()) async -> Bool {
        guard RecoveryCalibrationStore.isEnabled else { return false }
        let today = Repository.dayString(now)
        guard UserDefaults.standard.string(forKey: shownDayKey) != today else { return false }
        guard isMorning(now: now, latestSleepEnd: repo.sleeps.map(\.endTs).max()) else { return false }
        return await repo.morningCheckIn(day: today) == nil
    }

    /// Morning = after a sleep that ended today before `morningEndHour`, or, without such a sleep (the
    /// night not synced yet), between 04:00 and `morningEndHour`.
    static func isMorning(now: Date, latestSleepEnd: Int?, calendar: Calendar = .current) -> Bool {
        if let latestSleepEnd {
            let end = Date(timeIntervalSince1970: TimeInterval(latestSleepEnd))
            if calendar.isDate(end, inSameDayAs: now), end <= now,
               calendar.component(.hour, from: end) < morningEndHour {
                return true
            }
        }
        let hour = calendar.component(.hour, from: now)
        return hour >= 4 && hour < morningEndHour
    }

    static func markShown(now: Date = Date()) {
        UserDefaults.standard.set(Repository.dayString(now), forKey: shownDayKey)
    }
}

// MARK: - Calibration screen

struct RecoveryCalibrationView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var intelligence: IntelligenceEngine
    @AppStorage(RecoveryCalibrationStore.enabledKey) private var enabled = false
    @State private var result: RecoveryCalibrationResult = RecoveryCalibrationStore.lastResult
    @State private var checkIns: [String: MorningCheckIn] = [:]
    @State private var showResetConfirm = false
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopMetrics.sectionGap) {
                intro
                if enabled {
                    MorningCheckInSummaryRow()
                    progressCard
                    if result.phase != .collecting { weightsCard }
                    if !comparison.isEmpty { comparisonCard }
                    ZoopButton("Reset calibration", systemImage: "arrow.counterclockwise", kind: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
            .padding(ZoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(Text("Recovery calibration"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: enabled) { await reload() }
        // An edit from the check-in row re-scores and refreshes; pick up the new answer and fit.
        .onChangeCompat(of: repo.refreshSeq) { _ in Task { await reload() } }
        .confirmationDialog("Reset Recovery calibration?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every morning answer and the learned weighting. Recovery goes back to the standard weighting.")
        }
    }

    private func reload() async {
        checkIns = await repo.morningCheckIns()
        result = RecoveryCalibrationStore.lastResult
    }

    private func rescore() {
        working = true
        Task {
            await intelligence.analyzeRecent()
            await repo.refresh()
            await reload()
            working = false
        }
    }

    private func reset() {
        Task {
            await repo.resetRecoveryCalibration()
            rescore()
        }
    }

    private var intro: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                Toggle(isOn: Binding(get: { enabled }, set: { enabled = $0; rescore() })) {
                    Text("Calibrate Recovery").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Each morning you rate how recovered you feel and tick symptoms like a headache or sore muscles. Zoop compares your answers with the night's measurements and learns which signals match how you feel.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The measurements stay in charge: each weight moves at most half of its standard value, heart rate variability always weighs most, and symptoms you report lower that morning's Recovery instead of being learned away.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressCard: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Progress").strandOverline()
                    Spacer()
                    if working { ProgressView().controlSize(.small).tint(StrandPalette.accent) }
                }
                CalibrationProgressBar(result: result)
                Text(RecoveryCalibrationCopy.phaseLine(result))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A first preview appears after \(RecoveryCalibration.previewDays) mornings. Full strength takes \(RecoveryCalibration.fullDays) mornings, enough to cover training and rest weeks. Only mornings after a scored night count.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var weightsCard: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                Text(result.phase == .preview ? LocalizedStringKey("Your weighting (preview)") : LocalizedStringKey("Your weighting")).strandOverline()
                ForEach(ChargeTerm.allCases, id: \.self) { t in
                    let std = ChargeWeights.standard.weight(t)
                    let mine = result.weights.weight(t)
                    HStack {
                        Text(RecoveryCalibrationCopy.termName(t))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(verbatim: "\(Int((std * 100).rounded())) %")
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
                        Text(verbatim: "\(Int((mine * 100).rounded())) %")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(abs(mine - std) < 0.005 ? StrandPalette.textSecondary : StrandPalette.accent)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Standard on the left, yours on the right. A signal that rose and fell with how you felt gains weight; one that did not loses weight.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The last 14 answered mornings next to the measured Recovery of the same day.
    private var comparison: [(day: String, felt: MorningCheckIn, measured: Double?)] {
        let byDay = Dictionary(repo.days.map { ($0.day, $0.recovery) }, uniquingKeysWith: { a, _ in a })
        return checkIns.keys.sorted(by: >).prefix(14).map { d in (d, checkIns[d]!, byDay[d] ?? nil) }
    }

    private var comparisonCard: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.rowSpacing) {
                Text("Felt vs measured").strandOverline()
                ForEach(comparison, id: \.day) { row in
                    HStack {
                        Text(verbatim: row.day).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Text(verbatim: "\(row.felt.feeling)/5").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                        if row.felt.symptomLoad > 0 {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 12))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityLabel(Text("Symptoms reported"))
                        }
                        Text(verbatim: row.measured.map { "\(Int($0.rounded())) %" } ?? "–")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(row.measured.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary)
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Recovery detail card

/// The breakdown of the latest scored Recovery plus the calibration status, for the Recovery detail.
struct RecoveryInsightCard: View {
    @EnvironmentObject var repo: Repository
    @AppStorage(RecoveryCalibrationStore.enabledKey) private var enabled = false

    private var row: DailyMetric? { repo.days.last(where: { $0.recovery != nil }) }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
            if let row, let baselines = repo.chargeBaselines,
               let b = ChargeBreakdownWiring.breakdown(baselines: baselines, row: row,
                                                       charge: RecoveryCalibrationStore.lastScoring),
               !b.drivers.isEmpty {
                ZoopCard {
                    VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
                        Text("Latest night: \(row.day)").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        ChargeBreakdownSection(drivers: b.drivers, confidence: b.confidence,
                                               skinTempRel: RecoveryScorer.skinTempRelative(deviationC: row.skinTempDevC))
                    }
                }
            }
            if enabled { MorningCheckInSummaryRow() }
            // Which logged habits move Recovery (What Moves You), reached from here rather than from More.
            NavigationLink { InsightsHubView() } label: {
                ZoopCard {
                    HStack(spacing: ZoopMetrics.space3) {
                        Image(systemName: "wand.and.sparkles").foregroundStyle(StrandPalette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What affects your Recovery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text("From your logbook answers").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            NavigationLink { RecoveryCalibrationView() } label: {
                ZoopCard {
                    HStack(spacing: ZoopMetrics.space3) {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(StrandPalette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recovery calibration").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(enabled ? RecoveryCalibrationCopy.phaseLine(RecoveryCalibrationStore.lastResult)
                                 : String(localized: "Off. Tune Recovery to how you feel in the morning."))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}
