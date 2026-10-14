#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Sleep night cards (Zoop, iOS)
//
// The Sleep screen's per-night pieces in the flat redesign, styled like Home's panels and the Stress
// hero: a calm hypnogram with soft rounded stage bars, a four-column stage summary (time and share only;
// the factor grid further down rates deep and REM, so nothing here grades them a second time), and the
// overnight signal chart. Every number comes from the displayed night's own stages or its raw streams;
// the math lives in StrandAnalytics.

/// Minutes → "Xm" / "Yh Zm", identical to `SleepView.durationText`.
func nightDurationText(_ minutes: Double) -> String {
    let m = max(0, Int(minutes.rounded()))
    if m < 60 { return String(localized: "\(m)m") }
    return String(localized: "\(m / 60)h \(m % 60)m")
}

/// The panel header used across the night area: one quiet semibold line, as on the Stress hero.
struct SleepPanelLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(StrandFont.footnote.weight(.semibold))
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

// MARK: Hypnogram

/// One stepped hypnogram: Awake on top, Deep at the bottom, each stretch a soft rounded bar on its stage's
/// row with a faint riser to the next, and the night's start and end underneath. A selected stage keeps
/// its colour while the others recede.
struct SleepFlatHypnogram: View {
    let intervals: [SleepInterval]
    let nightStart: Date
    var selected: SleepStage?
    var palette: SleepStagePalette = .noop

    static let order: [SleepStage] = [.awake, .rem, .light, .deep]
    private let labelWidth: CGFloat = 44

    var body: some View {
        let sorted = Hypnogram.displaySmoothed(intervals.sorted { $0.start < $1.start }, minDuration: 90)
        let origin = sorted.first?.start ?? 0
        let span = max(1, (sorted.map(\.end).max() ?? 1) - origin)
        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
            HStack(alignment: .top, spacing: ZoopMetrics.space2) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.order, id: \.self) { stage in
                        Text(stage.label)
                            .font(StrandFont.caption)
                            .foregroundStyle(selected == nil || selected == stage
                                             ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(width: labelWidth, alignment: .leading)
                Canvas { ctx, size in
                    draw(ctx, size: size, sorted: sorted, origin: origin, span: span)
                }
            }
            .frame(height: 132)
            HStack {
                timeLabel(nightStart.addingTimeInterval(origin))
                Spacer()
                timeLabel(nightStart.addingTimeInterval(origin + span))
            }
            .padding(.leading, labelWidth + ZoopMetrics.space2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep stages through the night"))
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, sorted: [SleepInterval],
                      origin: TimeInterval, span: TimeInterval) {
        let rows = CGFloat(Self.order.count)
        let rowH = size.height / rows
        let barH = min(16, rowH * 0.55)
        func rowIndex(_ s: SleepStage) -> CGFloat { CGFloat(Self.order.firstIndex(of: s) ?? 0) }
        func midY(_ s: SleepStage) -> CGFloat { rowH * (rowIndex(s) + 0.5) }
        func x(_ t: TimeInterval) -> CGFloat { CGFloat((t - origin) / span) * size.width }

        // Faint row guides, so an empty row still reads as a row.
        for s in Self.order {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: midY(s)))
            guide.addLine(to: CGPoint(x: size.width, y: midY(s)))
            ctx.stroke(guide, with: .color(StrandPalette.hairline), lineWidth: 1)
        }
        // Risers between consecutive stretches.
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.stage != b.stage {
            var riser = Path()
            let xb = x(b.start)
            riser.move(to: CGPoint(x: xb, y: midY(a.stage)))
            riser.addLine(to: CGPoint(x: xb, y: midY(b.stage)))
            ctx.stroke(riser, with: .color(StrandPalette.hairlineStrong), lineWidth: 1)
        }
        for iv in sorted {
            let x0 = x(iv.start)
            let w = max(3, x(iv.end) - x0)
            let rect = CGRect(x: x0, y: midY(iv.stage) - barH / 2, width: w, height: barH)
            let dimmed = selected != nil && selected != iv.stage
            let color = StrandPalette.sleepStageColor(iv.stage, palette: palette)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(barH / 2, w / 2), style: .continuous),
                     with: .color(dimmed ? color.opacity(0.22) : color))
        }
    }

    private func timeLabel(_ date: Date) -> some View {
        Text(AppClock.hourMinuteFormatter().string(from: date))
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textTertiary)
    }
}

// MARK: Stage summary

/// Four columns, one per stage: a colour dot and the name, the time, and the share of the night. Tapping a
/// column highlights that stage on the hypnogram.
struct SleepStageSummaryRow: View {
    let stages: Stages
    var palette: SleepStagePalette = .noop
    @Binding var selected: SleepStage?

    var body: some View {
        let pct = StagePercentages.wholePercentages([stages.awake, stages.light, stages.deep, stages.rem])
        HStack(alignment: .top, spacing: ZoopMetrics.space2) {
            ForEach(SleepFlatHypnogram.order, id: \.self) { stage in
                column(stage, percent: percent(stage, pct))
            }
        }
    }

    private func minutes(_ s: SleepStage) -> Double {
        switch s {
        case .awake: return stages.awake
        case .light: return stages.light
        case .deep:  return stages.deep
        case .rem:   return stages.rem
        }
    }

    private func percent(_ s: SleepStage, _ p: [Int]?) -> Int {
        guard let p else { return 0 }
        switch s {
        case .awake: return p[0]
        case .light: return p[1]
        case .deep:  return p[2]
        case .rem:   return p[3]
        }
    }

    private func column(_ stage: SleepStage, percent: Int) -> some View {
        let isSelected = selected == stage
        let dimmed = selected != nil && !isSelected
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(StrandPalette.sleepStageColor(stage, palette: palette))
                    .frame(width: 7, height: 7)
                Text(stage.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(isSelected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(nightDurationText(minutes(stage)))
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: "\(percent)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StrandMotion.fade) { selected = isSelected ? nil : stage }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(nightDurationText(minutes(stage))), \(percent)%")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Night signal chart

/// The night's heart rate, HRV, breathing rate or blood oxygen across the sleep window, drawn like the
/// Stress hero: one quiet label, the number large, a smooth line over a soft fill, scrub to read a moment.
/// Text tabs switch metric; a metric appears only when this night has a plausible stream for it. Heart
/// rate leads with its night average (Night vitals carries resting HR, a different fact); the others with
/// the curve's low to high, so no number here repeats a Night vitals tile.
struct NightSignalCard: View {
    @EnvironmentObject private var repo: Repository
    let startTs: Int
    let endTs: Int

    @State private var series: [NightSignal.Metric: [TrendPoint]] = [:]
    @State private var selected: NightSignal.Metric = .heartRate
    @State private var scrubbed: TrendPoint?

    private var key: String { "\(startTs)-\(endTs)-\(repo.refreshSeq)" }

    private var available: [NightSignal.Metric] {
        NightSignal.Metric.allCases.filter { (series[$0]?.count ?? 0) > 0 }
    }

    var body: some View {
        Group {
            let metrics = available
            if let metric = metrics.contains(selected) ? selected : metrics.first,
               let points = series[metric] {
                VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                    HStack(alignment: .firstTextBaseline) {
                        SleepPanelLabel("Night signals")
                        Spacer(minLength: ZoopMetrics.space2)
                        if metrics.count > 1 { tabs(metrics, active: metric) }
                    }
                    headline(metric, points: points)
                    chart(metric, points: points)
                        .frame(height: 170)
                }
                .padding(ZoopMetrics.cardInnerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZoopPanelSurface())
            }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        guard endTs > startTs else { series = [:]; return }
        var out: [NightSignal.Metric: [TrendPoint]] = [:]
        for m in NightSignal.Metric.allCases {
            let s = await repo.timelineSeries(metric: Self.timeline(m), from: startTs, to: endTs, targetPoints: 120)
            let values = s.points.map(\.value)
            if let keep = NightSignal.plottable(values, metric: m) {
                out[m] = keep.map { s.points[$0] }
            }
            if Task.isCancelled { return }
        }
        series = out
    }

    private static func timeline(_ m: NightSignal.Metric) -> Repository.TimelineMetric {
        switch m {
        case .heartRate:       return .hr
        case .hrv:             return .hrv
        case .respiratoryRate: return .respiration
        case .spo2:            return .spo2
        }
    }

    // MARK: Pieces

    private func tabs(_ metrics: [NightSignal.Metric], active: NightSignal.Metric) -> some View {
        HStack(spacing: ZoopMetrics.space3) {
            ForEach(metrics, id: \.self) { m in
                Button {
                    scrubbed = nil
                    withAnimation(StrandMotion.fade) { selected = m }
                } label: {
                    Text(Self.short(m))
                        .font(StrandFont.footnote.weight(m == active ? .semibold : .regular))
                        .foregroundStyle(m == active ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.title(m))
                .accessibilityAddTraits(m == active ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func headline(_ m: NightSignal.Metric, points: [TrendPoint]) -> some View {
        let values = points.map(\.value)
        HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
            if let s = scrubbed {
                Text(Self.format(s.value, m))
                    .font(StrandFont.display(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: Self.unit(m))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(s.date.formatted(date: .omitted, time: .shortened))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if m == .heartRate, let avg = NightSignal.mean(values) {
                Text(Self.format(avg, m))
                    .font(StrandFont.display(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: Self.unit(m))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("average")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if let lo = values.min(), let hi = values.max() {
                Text(verbatim: "\(Self.format(lo, m))–\(Self.format(hi, m))")
                    .font(StrandFont.display(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: Self.unit(m))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("range")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private func chart(_ m: NightSignal.Metric, points: [TrendPoint]) -> some View {
        let color = Self.color(m)
        let values = points.map(\.value)
        let smooth = NightSignal.smoothed(values, window: 7)
        let lo0 = values.min() ?? 0, hi0 = values.max() ?? 1
        let pad = max((hi0 - lo0) * 0.12, Self.minPad(m))
        let lo = lo0 - pad, hi = hi0 + pad
        let indexed = Array(points.enumerated())
        return Chart {
            ForEach(indexed, id: \.offset) { i, p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Low", lo), yEnd: .value("Value", smooth[i]))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Value", smooth[i]))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let s = scrubbed {
                RuleMark(x: .value("Selected", s.date))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.5))
                PointMark(x: .value("Selected", s.date), y: .value("Value", s.value))
                    .symbol { Circle().fill(color).frame(width: 10, height: 10) }
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                Color.clear
                    .contentShape(Rectangle())
                    .zoopChartScrub(onChange: { location in
                        let x = min(max(location.x, plot.minX), plot.maxX) - plot.minX
                        guard let d: Date = proxy.value(atX: x) else { return }
                        scrubbed = points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
                    }, onEnd: { scrubbed = nil })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.title(m)))
    }

    // MARK: Metric metadata

    static func short(_ m: NightSignal.Metric) -> String {
        switch m {
        case .heartRate:       return String(localized: "HR")
        case .hrv:             return "HRV"
        case .respiratoryRate: return String(localized: "RR")
        case .spo2:            return "SpO₂"
        }
    }

    static func title(_ m: NightSignal.Metric) -> String {
        switch m {
        case .heartRate:       return String(localized: "Heart rate during sleep")
        case .hrv:             return String(localized: "HRV during sleep")
        case .respiratoryRate: return String(localized: "Breathing rate during sleep")
        case .spo2:            return String(localized: "Blood oxygen during sleep")
        }
    }

    static func unit(_ m: NightSignal.Metric) -> String {
        switch m {
        case .heartRate:       return "bpm"
        case .hrv:             return "ms"
        case .respiratoryRate: return String(localized: "rpm")
        case .spo2:            return "%"
        }
    }

    static func format(_ v: Double, _ m: NightSignal.Metric) -> String {
        switch m {
        case .respiratoryRate:
            return v.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.activeLocale))
        case .heartRate, .hrv, .spo2:
            return "\(Int(v.rounded()))"
        }
    }

    static func color(_ m: NightSignal.Metric) -> Color {
        switch m {
        case .heartRate:       return StrandPalette.metricRose
        case .hrv:             return StrandPalette.chargeColor
        case .respiratoryRate: return StrandPalette.metricPurple
        case .spo2:            return StrandPalette.metricCyan
        }
    }

    private static func minPad(_ m: NightSignal.Metric) -> Double {
        switch m {
        case .heartRate, .hrv: return 3
        case .respiratoryRate, .spo2: return 0.5
        }
    }
}
#endif
