#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Home nap detail + editor
//
// A nap row in Home's "Today's activities" opens these two sheets: a tap shows the nap itself (its
// window, stages and heart rate), and a press and hold opens the same time editor the Sleep tab's nap
// row uses. Both read the stored session directly, so neither re-derives what the Sleep tab shows.

/// One nap, as the item a Home sheet is presented for.
struct HomeNapTarget: Identifiable {
    let session: CachedSleepSession
    var id: Int { session.startTs }
}

/// The Sleep tab's nap editor (`SleepTimeEditor`), presented from Home. The save path is the one the
/// Sleep tab's nap row runs: re-stage the corrected window, re-score the day, refresh the read cache.
/// Delete is left to the Sleep tab, which carries the undo banner a delete there offers.
struct HomeNapTimeEditor: View {
    let nap: CachedSleepSession
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine

    var body: some View {
        // The recorded coverage for the #940 guards, built exactly as the Sleep tab builds it.
        let coverageLo = min(nap.startTs, nap.effectiveStartTs)
        SleepTimeEditor(bedTs: nap.effectiveStartTs, wakeTs: nap.endTs,
                        title: "Edit nap times",
                        bedLabel: "Nap started", wakeLabel: "Nap ended",
                        coverage: coverageLo...max(nap.endTs, coverageLo + 1),
                        // A nap row is always user-owned, so nothing re-detects it (as on the Sleep tab).
                        suppressesReDetection: false,
                        onSave: { newStart, newEnd in
            await repo.editSleepTimes(detectedStartTs: nap.startTs, oldEndTs: nap.endTs,
                                      storedStagesJSON: nap.stagesJSON,
                                      newStartTs: newStart, newEndTs: newEnd)
            await intelligence.analyzeRecent()
            await repo.refresh()
        })
    }
}

/// What one nap was: its window, how much of it was sleep, its stages and its heart rate.
struct HomeNapDetailSheet: View {
    let nap: CachedSleepSession
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var heartRate: [Double] = []
    @State private var editing = false

    private var start: Date { Date(timeIntervalSince1970: TimeInterval(nap.effectiveStartTs)) }
    private var end: Date { Date(timeIntervalSince1970: TimeInterval(nap.endTs)) }
    private var inBedMinutes: Double { Double(max(0, nap.endTs - nap.effectiveStartTs)) / 60 }

    /// Stage totals and, for an on-device nap, the real timeline. The two stored formats are read the
    /// way the Sleep tab reads them (segment array first for the timeline, minute totals otherwise).
    private var decoded: (stages: Stages, intervals: [SleepInterval])? {
        if let seg = SleepView.decodeSegments(nap.stagesJSON, sessionStart: nap.effectiveStartTs) {
            return seg
        }
        return SleepView.decodeStages(nap.stagesJSON).map { ($0, []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
                    header
                    statsRow
                    stagesCard
                    heartRateCard
                }
                .padding(.horizontal, ZoopMetrics.screenHPadding)
                .padding(.vertical, ZoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Nap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit") { editing = true }.foregroundStyle(StrandPalette.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(StrandPalette.accent)
                }
            }
        }
        .noopSheetPresentation(largeFirst: false)
        .task(id: nap.startTs) {
            heartRate = await repo.hrBuckets(from: nap.effectiveStartTs, to: nap.endTs, bucketSeconds: 60)
                .map(\.bpm)
        }
        .sheet(isPresented: $editing) {
            HomeNapTimeEditor(nap: nap)
        }
    }

    private var header: some View {
        HStack(spacing: ZoopMetrics.space3) {
            Image(systemName: "bed.double.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.surfaceBase)
                .frame(width: 48, height: 40)
                .background(SquircleShape().fill(StrandPalette.restColor))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                    .font(StrandFont.rounded(22, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(start.formatted(date: .complete, time: .omitted))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: ZoopMetrics.space3) {
            stat("Time in bed", durationText(inBedMinutes))
            if let asleep = decoded?.stages.asleep, asleep > 0 {
                stat("Time asleep", durationText(asleep))
            }
            if !heartRate.isEmpty {
                stat("Avg HR", "\(Int((heartRate.reduce(0, +) / Double(heartRate.count)).rounded()))")
            }
        }
    }

    @ViewBuilder
    private var stagesCard: some View {
        if let decoded {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                Text("Stages")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if !decoded.intervals.isEmpty {
                    Hypnogram(intervals: decoded.intervals, height: 120, showsStageAxis: false,
                              showsHover: false, nightStart: start, showsTimeAxis: true)
                }
                ForEach([SleepStage.awake, .light, .deep, .rem], id: \.self) { stage in
                    stageRow(stage, minutes: minutes(of: stage, in: decoded.stages),
                             total: decoded.stages.total)
                }
            }
            .padding(ZoopMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoopPanelSurface())
        }
    }

    @ViewBuilder
    private var heartRateCard: some View {
        if heartRate.count >= 2 {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                Text("Heart rate")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                LiquidThread(bpm: heartRate, tint: StrandPalette.liquidHeart, height: 92, animated: false)
                HStack {
                    hrStat("Min", heartRate.min())
                    Spacer()
                    hrStat("Avg", heartRate.reduce(0, +) / Double(heartRate.count))
                    Spacer()
                    hrStat("Max", heartRate.max())
                }
            }
            .padding(ZoopMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoopPanelSurface())
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(StrandFont.rounded(20, weight: .bold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(ZoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface())
    }

    private func stageRow(_ stage: SleepStage, minutes: Double, total: Double) -> some View {
        HStack(spacing: ZoopMetrics.space2) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 10, height: 10)
            Text(stage.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(durationText(minutes))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(total > 0 ? "\(Int((minutes / total * 100).rounded()))%" : "–")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    private func hrStat(_ label: String.LocalizationValue, _ value: Double?) -> some View {
        HStack(spacing: 5) {
            Text(String(localized: label)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func minutes(of stage: SleepStage, in stages: Stages) -> Double {
        switch stage {
        case .awake: return stages.awake
        case .light: return stages.light
        case .deep: return stages.deep
        case .rem: return stages.rem
        }
    }

    /// "1h 05m"-style text through the same localized key the Sleep tab's durations use.
    private func durationText(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}
#endif
