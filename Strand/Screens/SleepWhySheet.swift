#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - "Why this sleep?" (Zoop, iOS)
//
// The evidence behind a night's start and end: the heart rate and wrist movement around falling asleep
// and waking, with markers where the wrist went still, where sleep was counted from and where the night
// ended, and one sentence naming the rule that decided it. Every number comes from
// `SleepStager.explainOnset` (the onset rule itself, run on this night's raw streams under the current
// settings), never from a re-derivation here. The Detection panel is the one place the onset rule is
// tuned: its strictness, and whether a personal offset is learned from the wearer's own corrections.

/// What the Sleep screen hands the sheet about the night it shows.
struct SleepWhySeed: Identifiable {
    /// The night's immutable detected start (its stored key).
    let detectedStartTs: Int
    /// The start the screen shows (a hand-set start when edited).
    let effectiveStartTs: Int
    let endTs: Int
    let userEdited: Bool
    /// Why this block is the day's main sleep, when the day had more than one candidate.
    let mainSleepReason: String?
    var id: Int { detectedStartTs }
}

struct SleepWhySheet: View {
    let seed: SleepWhySeed
    let loadEvidence: () async -> SleepOnsetEvidence?
    /// Re-detects the recent nights and refreshes the screen after a Detection change.
    let applySettings: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SleepOnsetPrefs.strictnessKey) private var strictnessRaw = SleepOnsetStrictness.standard.rawValue
    @AppStorage(SleepOnsetPrefs.learnKey) private var learnEnabled = true
    @AppStorage(SleepOnsetPrefs.correctionsKey) private var correctionsRaw = "[]"

    @State private var evidence: SleepOnsetEvidence?
    @State private var loaded = false
    @State private var applying = false
    @State private var applyTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                    header
                    if let ev = evidence {
                        onsetPanel(ev)
                        wakePanel(ev)
                    } else if loaded {
                        panel {
                            Text("This night has no strap data to show, for example because it was imported.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                    detectionPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, ZoopMetrics.space3)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Why this sleep?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(StrandPalette.accent)
        .task { await reload() }
    }

    private func reload() async {
        let ev = await loadEvidence()
        evidence = ev
        loaded = true
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
            Text(verbatim: "\(clock(seed.effectiveStartTs)) – \(clock(seed.endTs))")
                .font(StrandFont.display(36))
                .foregroundStyle(StrandPalette.textPrimary)
            if let reason = seed.mainSleepReason {
                Text(reason)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ZoopMetrics.space1)
    }

    // MARK: Falling asleep

    private func onsetPanel(_ ev: SleepOnsetEvidence) -> some View {
        let userStart = seed.userEdited && abs(seed.effectiveStartTs - ev.onsetTs) >= 60 ? seed.effectiveStartTs : nil
        let lo = min(ev.stillSinceTs, userStart ?? ev.stillSinceTs) - 30 * 60
        let hi = max(ev.onsetTs, userStart ?? ev.onsetTs) + 45 * 60
        var markers = [Marker(ts: ev.stillSinceTs, label: String(localized: "Still"), color: StrandPalette.textTertiary)]
        if ev.onsetTs != ev.stillSinceTs {
            markers.append(Marker(ts: ev.onsetTs, label: String(localized: "Fell asleep"), color: StrandPalette.restBright))
        } else {
            markers[0] = Marker(ts: ev.onsetTs, label: String(localized: "Fell asleep"), color: StrandPalette.restBright)
        }
        if let userStart {
            markers.append(Marker(ts: userStart, label: String(localized: "You"), color: StrandPalette.textPrimary))
        }
        return panel {
            SleepPanelLabel("Falling asleep")
            Text(onsetSentence(ev))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if ev.appliedOffsetMin != 0 {
                Text(ev.appliedOffsetMin > 0
                     ? String(localized: "Moved \(ev.appliedOffsetMin) min later by what Zoop learned from your corrections.")
                     : String(localized: "Moved \(-ev.appliedOffsetMin) min earlier by what Zoop learned from your corrections."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let userStart {
                Text("You set the start to \(clock(userStart)) yourself.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            EvidenceChart(evidence: ev, from: lo, to: hi, markers: markers)
                .frame(height: 170)
            legend(ev)
        }
    }

    private func onsetSentence(_ ev: SleepOnsetEvidence) -> String {
        let still = clock(ev.stillSinceTs)
        let rule = clock(ev.ruleOnsetTs)
        switch ev.outcome {
        case .trimmed:
            return String(localized: "Heart rate stayed \(ev.leadAboveLevelBpm ?? 0) bpm above your sleeping level until \(rule), so the quiet time before doesn't count as sleep.")
        case .settledPromptly:
            return String(localized: "Your heart rate reached your sleeping level soon after you lay still, so sleep starts at \(still).")
        case .leadAtSleepingLevel:
            return String(localized: "Your heart rate was already close to your sleeping level while you lay still, so sleep starts at \(still).")
        case .neverSettled:
            return String(localized: "Your heart rate never settled clearly, so sleep starts when you lay still at \(still).")
        case .sparseHR:
            return String(localized: "There was too little heart rate data to check, so sleep starts when you lay still at \(still).")
        case .tooShortToTrim:
            return String(localized: "The night was too short to trim, so sleep starts when you lay still at \(still).")
        }
    }

    // MARK: Waking up

    private func wakePanel(_ ev: SleepOnsetEvidence) -> some View {
        let lo = min(ev.stillUntilTs, seed.endTs) - 60 * 60
        let hi = max(ev.stillUntilTs, seed.endTs) + 30 * 60
        var markers = [Marker(ts: seed.endTs, label: String(localized: "Awake"), color: StrandPalette.restBright)]
        let refined = abs(seed.endTs - ev.stillUntilTs) > 120
        if refined, !seed.userEdited {
            markers.insert(Marker(ts: ev.stillUntilTs, label: String(localized: "Moving"), color: StrandPalette.textTertiary), at: 0)
        }
        return panel {
            SleepPanelLabel("Waking up")
            Text(wakeSentence(ev, refined: refined))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            EvidenceChart(evidence: ev, from: lo, to: hi, markers: markers)
                .frame(height: 150)
        }
    }

    private func wakeSentence(_ ev: SleepOnsetEvidence, refined: Bool) -> String {
        if seed.userEdited { return String(localized: "You set the wake time to \(clock(seed.endTs)) yourself.") }
        if refined {
            return String(localized: "The still stretch ended at \(clock(ev.stillUntilTs)); heart rate and movement placed your wake time at \(clock(seed.endTs)).")
        }
        return String(localized: "You started moving at \(clock(seed.endTs)), so the night ends there.")
    }

    // MARK: Legend

    private func legend(_ ev: SleepOnsetEvidence) -> some View {
        HStack(spacing: ZoopMetrics.space3) {
            legendItem(Capsule().fill(StrandPalette.metricRose).frame(width: 12, height: 3), "Heart rate")
            if ev.sleepLevelBpm != nil {
                legendItem(dash(StrandPalette.restBright), "Sleeping level")
            }
            if ev.awakeBarBpm != nil {
                legendItem(dash(StrandPalette.metricRose.opacity(0.6)), "Awake level")
            }
            legendItem(RoundedRectangle(cornerRadius: 1).fill(StrandPalette.textTertiary.opacity(0.5)).frame(width: 6, height: 9), "Movement")
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }

    private func dash(_ color: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(color).frame(width: 3, height: 1.5) }
        }
    }

    private func legendItem<S: View>(_ swatch: S, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { swatch; Text(label) }
    }

    // MARK: Detection

    private var strictness: SleepOnsetStrictness { SleepOnsetStrictness(rawValue: strictnessRaw) ?? .standard }

    private var detectionPanel: some View {
        let corrections = OnsetCorrectionLearning.decode(correctionsRaw)
        let learned = OnsetCorrectionLearning.learnedOffsetMin(corrections)
        return panel {
            HStack {
                SleepPanelLabel("Detection")
                Spacer()
                if applying { ProgressView().controlSize(.small) }
            }
            Picker("Sleep onset detection", selection: Binding(
                get: { strictness },
                set: { strictnessRaw = $0.rawValue; settingsChanged() })) {
                Text("Strict").tag(SleepOnsetStrictness.strict)
                Text("Standard").tag(SleepOnsetStrictness.standard)
                Text("Relaxed").tag(SleepOnsetStrictness.relaxed)
            }
            .pickerStyle(.segmented)
            Text(strictnessCaption(strictness))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(StrandPalette.hairline)
            Toggle(isOn: Binding(get: { learnEnabled },
                                 set: { learnEnabled = $0; if learned != nil { settingsChanged() } })) {
                Text("Learn from my corrections")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.accent)
            if learnEnabled {
                Text(learningStatus(corrections: corrections, learned: learned))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !corrections.isEmpty {
                Button(role: .destructive) {
                    SleepOnsetPrefs.resetCorrections()
                    correctionsRaw = "[]"
                    if learned != nil { settingsChanged() }
                } label: {
                    Text("Reset what was learned").font(StrandFont.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.statusCritical)
            }
        }
    }

    private func strictnessCaption(_ s: SleepOnsetStrictness) -> String {
        switch s {
        case .strict:   return String(localized: "Counts quiet time as sleep only once your heart rate has clearly settled.")
        case .standard: return String(localized: "Quiet time before sleep is cut when your heart rate is clearly awake.")
        case .relaxed:  return String(localized: "Counts quiet time in bed as sleep sooner; only a clearly raised heart rate is cut.")
        }
    }

    private func learningStatus(corrections: [OnsetCorrectionLearning.Correction], learned: Int?) -> String {
        if let learned {
            return learned > 0
                ? String(localized: "You usually fall asleep about \(learned) min later than detected; applied.")
                : String(localized: "You usually fall asleep about \(-learned) min earlier than detected; applied.")
        }
        if corrections.count >= OnsetCorrectionLearning.minCount {
            return String(localized: "Your corrections point different ways, so nothing is applied.")
        }
        if corrections.isEmpty {
            return String(localized: "Learns after 3 start-time corrections in the same direction.")
        }
        return String(localized: "Learns after 3 start-time corrections in the same direction (\(corrections.count) so far).")
    }

    /// Re-detect with the new settings, then reload the evidence. A newer change cancels the wait.
    private func settingsChanged() {
        applyTask?.cancel()
        applying = true
        applyTask = Task {
            await applySettings()
            guard !Task.isCancelled else { return }
            await reload()
            applying = false
        }
    }

    // MARK: Pieces

    private func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space3) { content() }
            .padding(ZoopMetrics.cardInnerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoopPanelSurface())
    }

    private func clock(_ ts: Int) -> String {
        AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// MARK: - Evidence chart

private struct Marker: Hashable {
    let ts: Int
    let label: String
    let color: Color
}

/// Per-minute heart rate over `[from, to]` with the night's sleeping and awake levels as dashed lines,
/// wrist movement as faint bars along the floor, and labelled markers.
private struct EvidenceChart: View {
    let evidence: SleepOnsetEvidence
    let from: Int
    let to: Int
    let markers: [Marker]

    private struct Pt: Identifiable { let id: Int; let date: Date; let hr: Double?; let moving: Double? }

    private var points: [Pt] {
        let ev = evidence
        let i0 = max(0, (from - ev.seriesStartTs) / 60)
        let i1 = min(ev.minuteHR.count - 1, (to - ev.seriesStartTs) / 60)
        guard i1 > i0 else { return [] }
        return (i0...i1).map { i in
            Pt(id: i, date: Date(timeIntervalSince1970: TimeInterval(ev.seriesStartTs + i * 60)),
               hr: ev.minuteHR[i], moving: ev.minuteMoving[i])
        }
    }

    var body: some View {
        let pts = points
        let hrs = pts.compactMap(\.hr)
        let refs = [evidence.sleepLevelBpm, evidence.awakeBarBpm].compactMap { $0 }
        let lo0 = (hrs + refs).min() ?? 40, hi0 = (hrs + refs).max() ?? 100
        let pad = max(3, (hi0 - lo0) * 0.1)
        let floor = lo0 - pad - (hi0 - lo0 + 2 * pad) * 0.3   // room for the movement bars
        let hi = hi0 + pad
        let barTop = lo0 - pad
        Chart {
            ForEach(pts) { p in
                if let m = p.moving, m > 0 {
                    RectangleMark(x: .value("Time", p.date), yStart: .value("Floor", floor),
                                  yEnd: .value("Movement", floor + (barTop - floor) * min(1, m * 1.6)), width: 2)
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                }
            }
            ForEach(pts) { p in
                if let hr = p.hr {
                    LineMark(x: .value("Time", p.date), y: .value("Heart rate", hr))
                        .foregroundStyle(StrandPalette.metricRose)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let level = evidence.sleepLevelBpm {
                RuleMark(y: .value("Sleeping level", level))
                    .foregroundStyle(StrandPalette.restBright)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let bar = evidence.awakeBarBpm {
                RuleMark(y: .value("Awake level", bar))
                    .foregroundStyle(StrandPalette.metricRose.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(markers, id: \.self) { m in
                RuleMark(x: .value("Marker", Date(timeIntervalSince1970: TimeInterval(m.ts))))
                    .foregroundStyle(m.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, spacing: 2) {
                        Text(m.label)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(m.color)
                    }
            }
        }
        .chartXScale(domain: Date(timeIntervalSince1970: TimeInterval(from))...Date(timeIntervalSince1970: TimeInterval(to)))
        .chartYScale(domain: floor...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                if let d = v.as(Double.self), d >= barTop {
                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate and movement"))
    }
}
#endif
