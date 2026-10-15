import SwiftUI
import Charts
import StrandDesign

/// The night's stages over time, with an optional heart-rate overlay, the stored movement on the same
/// timeline, where the stages came from, and any caveat about this night's staging.
struct SleepTimelineCard: View {
    let page: SleepNightPage
    let heartRate: [SleepHRPoint]

    @AppStorage(SleepChartStyle.storageKey) private var chartStyleRaw = SleepChartStyle.classic.rawValue
    @State private var showsHeartRate = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            SleepSectionTitle(SleepStrings.timelineCard)
            ContentCard { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        if page.hasStages {
            if !heartRate.isEmpty { heartRateToggle }
            SleepStageChart(night: page.night, style: SleepChartStyle.resolve(chartStyleRaw),
                            heartRate: showsHeartRate ? heartRate : [])
            if page.night.motionEpochs.count >= 2 { movement }
            Text(footnote)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(page.caveats, id: \.self) { SleepCaveatRow(caveat: $0) }
        } else {
            Text(SleepStrings.noStages)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var heartRateToggle: some View {
        Button { withAnimation(StrandMotion.fade) { showsHeartRate.toggle() } } label: {
            Label { Text(SleepStrings.heartRate) } icon: {
                Image(systemName: showsHeartRate ? "heart.fill" : "heart")
                    .foregroundStyle(showsHeartRate ? StrandPalette.metricRose : StrandPalette.textTertiary)
            }
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showsHeartRate ? .isSelected : [])
    }

    /// Movement is normalised to this night's own peak, so heights do not compare between nights.
    private var movement: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(SleepStrings.movement)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            MotionTrace(epochs: page.night.motionEpochs, height: 26, tint: StrandPalette.textTertiary)
        }
    }

    private var footnote: LocalizedStringResource {
        switch page.stageSource {
        case .estimated: return SleepStrings.estimatedStages
        case .ring: return SleepStrings.ringStages
        case .imported: return SleepStrings.importedStages
        }
    }
}

/// Stage bars on four rows (awake on top, deep at the bottom). Classic draws a bar inside each row,
/// Fill drops each stretch to the baseline, Ribbon draws a slim band; the palette follows the style.
/// The heart-rate overlay is scaled into the chart's height: it shows shape, not a second axis.
struct SleepStageChart: View {
    let night: Night
    let style: SleepChartStyle
    let heartRate: [SleepHRPoint]
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 160

    private static let rows: [SleepStage] = [.deep, .light, .rem, .awake]

    private struct Bar: Identifiable {
        let stage: SleepStage
        let start: Date
        let end: Date
        var id: Date { start }
    }

    var body: some View {
        let bars = self.bars
        let palette = style == .classic ? SleepStagePalette.noop : style.stagePalette
        Chart {
            ForEach(bars) { bar in
                let row = Double(Self.rows.firstIndex(of: bar.stage) ?? 0)
                RectangleMark(xStart: .value("Start", bar.start), xEnd: .value("End", bar.end),
                              yStart: .value("Low", lower(row)), yEnd: .value("High", upper(row)))
                    .foregroundStyle(StrandPalette.sleepStageColor(bar.stage, palette: palette))
            }
            ForEach(scaledHeartRate, id: \.date) { point in
                LineMark(x: .value("Time", point.date), y: .value("Heart rate", point.y),
                         series: .value("Series", "hr"))
                    .foregroundStyle(StrandPalette.metricRose)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...4)
        .chartXScale(domain: night.onsetDate...max(night.wakeDate, night.onsetDate.addingTimeInterval(60)))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.5, 1.5, 2.5, 3.5]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.rows[min(3, max(0, Int(v)))].label).font(ZoopType.caption)
                    }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SleepStrings.timelineSummary(
            SleepReadouts.durationText(seconds: night.stages.asleep * 60),
            SleepReadouts.durationText(seconds: night.stages.total * 60))))
    }

    private var bars: [Bar] {
        let sorted = night.intervals.sorted { $0.start < $1.start }
        return Hypnogram.displaySmoothed(sorted, minDuration: 90).map {
            Bar(stage: $0.stage, start: night.onsetDate.addingTimeInterval($0.start),
                end: night.onsetDate.addingTimeInterval($0.end))
        }
    }

    private func lower(_ row: Double) -> Double {
        switch style {
        case .filled, .garminFilled: return 0
        case .ribbon: return row + 0.4
        case .classic: return row + 0.15
        }
    }

    private func upper(_ row: Double) -> Double { style == .ribbon ? row + 0.6 : row + 0.85 }

    /// Heart rate mapped into the plot's 0.2…3.8 band.
    private var scaledHeartRate: [(date: Date, y: Double)] {
        guard let lo = heartRate.map(\.bpm).min(), let hi = heartRate.map(\.bpm).max() else { return [] }
        let span = max(hi - lo, 1)
        return heartRate.map { ($0.date, 0.2 + ($0.bpm - lo) / span * 3.6) }
    }
}

/// One caveat under the timeline: a warning glyph, a short title and one sentence.
struct SleepCaveatRow: View {
    let caveat: SleepCaveat

    var body: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ZoopType.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(text).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringResource {
        switch caveat {
        case .lowConfidence: return SleepStrings.lowConfidenceTitle
        case .incomplete: return SleepStrings.incompleteTitle
        case .partial: return SleepStrings.partialTitle
        }
    }

    private var text: LocalizedStringResource {
        switch caveat {
        case .lowConfidence: return SleepStrings.lowConfidenceText
        case .incomplete: return SleepStrings.incompleteText
        case .partial(let percent): return SleepStrings.partialText(percent)
        }
    }
}
