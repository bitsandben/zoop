import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Recovery calibration UI (Zoop)
//
// Three surfaces over `RecoveryCalibrationStore`:
//   - `MorningCheckInCard`: the Home card. Invites the wearer to start calibration once, then asks the
//     morning question (1–5 plus symptom chips) until today is answered.
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

// MARK: - Morning check-in (Home)

struct MorningCheckInCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var intelligence: IntelligenceEngine
    @AppStorage(RecoveryCalibrationStore.enabledKey) private var enabled = false
    /// The Home invite is shown until it is either accepted or dismissed once.
    @AppStorage("zoop.recoveryCalibration.inviteDismissed") private var inviteDismissed = false

    @State private var answered: MorningCheckIn?
    @State private var loaded = false
    @State private var feeling: Int?
    @State private var headache = false
    @State private var soreness = false
    @State private var ill = false
    @State private var stress = false
    @State private var saving = false
    @State private var editing = false

    private var today: String { Repository.dayString(Date()) }

    var body: some View {
        Group {
            if !enabled {
                if !inviteDismissed { invite } else { Color.clear.frame(height: 0) }
            } else if !loaded {
                // A real (zero-height) view rather than EmptyView: modifiers on an EmptyView never fire, so
                // the `.task` below would never load the day's answer.
                Color.clear.frame(height: 0)
            } else if let answered, !editing {
                answeredRow(answered)
            } else {
                question
            }
        }
        .task(id: enabled) { await load() }
    }

    private func load() async {
        guard enabled else { return }
        answered = await repo.morningCheckIn(day: today)
        if let a = answered {
            feeling = a.feeling; headache = a.headache; soreness = a.soreness; ill = a.ill; stress = a.stress
        }
        loaded = true
    }

    private var invite: some View {
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

    private var question: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Morning check-in").strandOverline()
                    Spacer()
                    NavigationLink { RecoveryCalibrationView() } label: {
                        Image(systemName: "info.circle").foregroundStyle(StrandPalette.textTertiary)
                    }
                    .accessibilityLabel(Text("About Recovery calibration"))
                }
                Text("How recovered do you feel?")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: ZoopMetrics.space1) {
                    ForEach(Array(MorningCheckIn.scale), id: \.self) { v in
                        Button { feeling = v } label: {
                            VStack(spacing: 2) {
                                Text(verbatim: "\(v)").font(StrandFont.headline)
                                Text(RecoveryCalibrationCopy.feelingLabel(v))
                                    .font(StrandFont.caption).lineLimit(1).minimumScaleFactor(0.6)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, ZoopMetrics.space2)
                            .foregroundStyle(feeling == v ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(feeling == v ? StrandPalette.accent.opacity(0.22) : StrandPalette.surfaceInset))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(feeling == v ? StrandPalette.accent : StrandPalette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(v), \(RecoveryCalibrationCopy.feelingLabel(v))"))
                        .accessibilityAddTraits(feeling == v ? .isSelected : [])
                    }
                }
                Text("Anything else this morning?")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: ZoopMetrics.space2) {
                    chip("Headache", isOn: $headache)
                    chip("Sore muscles", isOn: $soreness)
                }
                HStack(spacing: ZoopMetrics.space2) {
                    chip("Feeling ill", isOn: $ill)
                    chip("Stressed", isOn: $stress)
                }
                HStack {
                    Text(RecoveryCalibrationCopy.phaseLine(RecoveryCalibrationStore.lastResult))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: ZoopMetrics.space2)
                    if saving {
                        ProgressView().controlSize(.small).tint(StrandPalette.accent)
                    } else {
                        ZoopButton("Save") { save() }
                            .disabled(feeling == nil)
                    }
                }
            }
        }
    }

    private func answeredRow(_ a: MorningCheckIn) -> some View {
        ZoopCard {
            HStack(spacing: ZoopMetrics.space3) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning check-in: \(a.feeling)/5, \(RecoveryCalibrationCopy.feelingLabel(a.feeling))")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(RecoveryCalibrationCopy.phaseLine(RecoveryCalibrationStore.lastResult))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { editing = true } label: {
                    Text("Edit").font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(title)
                .font(StrandFont.subhead)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ZoopMetrics.space2)
                .foregroundStyle(isOn.wrappedValue ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .background(Capsule().fill(isOn.wrappedValue ? StrandPalette.accent.opacity(0.22) : StrandPalette.surfaceInset))
                .overlay(Capsule().strokeBorder(isOn.wrappedValue ? StrandPalette.accent : StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func save() {
        guard let feeling, !saving else { return }
        let c = MorningCheckIn(feeling: feeling, headache: headache, soreness: soreness, ill: ill, stress: stress)
        saving = true
        Task {
            await repo.saveMorningCheckIn(day: today, c)
            answered = c
            editing = false
            // Re-score so today's symptoms and the refreshed personal weights reach the Recovery ring.
            await intelligence.analyzeRecent()
            await repo.refresh()
            saving = false
        }
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
