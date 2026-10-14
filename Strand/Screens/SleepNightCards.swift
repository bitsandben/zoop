import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Sleep night cards (Zoop, iOS)
//
// The Sleep screen's per-night pieces in the redesign: stage lanes, stage cells with a share ring and the
// wearer's typical range, the time it took to fall asleep, and the overnight signal chart. Every number
// comes from the displayed night's own stages or the shared `SleepModel`; the math lives in
// `StrandAnalytics/SleepNightReadouts.swift`.

/// Minutes → "Xm" / "Yh Zm", identical to `SleepView.durationText`.
private func nightDurationText(_ minutes: Double) -> String {
    let m = max(0, Int(minutes.rounded()))
    if m < 60 { return String(localized: "\(m)m") }
    return String(localized: "\(m / 60)h \(m % 60)m")
}

// MARK: Stage lanes

/// Four lanes (Awake, REM, Light, Deep) with a block wherever that stage occurred, and the night's start
/// and end clock times underneath. Tapping a stage cell highlights its lane.
struct SleepStageLanes: View {
    let intervals: [SleepInterval]
    let nightStart: Date
    var selected: SleepStage?
    var palette: SleepStagePalette = .noop

    private static let order: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        let sorted = Hypnogram.displaySmoothed(intervals.sorted { $0.start < $1.start }, minDuration: 90)
        let origin = sorted.first?.start ?? 0
        let span = max(1, (sorted.map(\.end).max() ?? 1) - origin)
        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
            VStack(spacing: 6) {
                ForEach(Self.order, id: \.self) { stage in
                    lane(stage, intervals: sorted, origin: origin, span: span)
                }
            }
            HStack {
                timeLabel(icon: "moon.fill", date: nightStart.addingTimeInterval(origin))
                Spacer()
                timeLabel(icon: "sun.max.fill", date: nightStart.addingTimeInterval(origin + span))
            }
            .padding(.leading, 52)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep stages through the night"))
    }

    private func lane(_ stage: SleepStage, intervals: [SleepInterval], origin: TimeInterval,
                      span: TimeInterval) -> some View {
        let color = StrandPalette.sleepStageColor(stage, palette: palette)
        let dimmed = selected != nil && selected != stage
        return HStack(spacing: 8) {
            Text(stage.label)
                .font(StrandFont.caption)
                .foregroundStyle(dimmed ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    ForEach(intervals.filter { $0.stage == stage }) { iv in
                        let x0 = CGFloat((iv.start - origin) / span) * geo.size.width
                        let w = max(2, CGFloat((iv.end - iv.start) / span) * geo.size.width)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(dimmed ? StrandPalette.textTertiary.opacity(0.4) : color)
                            .frame(width: w, height: geo.size.height)
                            .offset(x: x0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 22)
        }
    }

    private func timeLabel(icon: String, date: Date) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(AppClock.hourMinuteFormatter().string(from: date))
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textTertiary)
    }
}

// MARK: Stage cells

/// A 2×2 grid, one cell per stage: its name, time, share of the night and a squircle ring filled to that
/// share. A thin outer arc marks the wearer's typical range (25th to 75th percentile, last 30 nights).
struct StageShareCells: View {
    let stages: Stages
    let bands: StageShareBands.Bands
    var palette: SleepStagePalette = .noop
    @Binding var selected: SleepStage?

    private static let order: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        let pct = StagePercentages.wholePercentages([stages.awake, stages.light, stages.deep, stages.rem])
        VStack(alignment: .leading, spacing: ZoopMetrics.space2) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoopMetrics.space2),
                                GridItem(.flexible(), spacing: ZoopMetrics.space2)],
                      spacing: ZoopMetrics.space2) {
                ForEach(Self.order, id: \.self) { stage in
                    cell(stage, percent: percent(stage, pct))
                }
            }
            if hasAnyBand {
                HStack(spacing: 6) {
                    Capsule().fill(StrandPalette.textSecondary).frame(width: 12, height: 3)
                    Text("Typical range")
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            }
        }
    }

    private var hasAnyBand: Bool {
        bands.awake != nil || bands.light != nil || bands.deep != nil || bands.rem != nil
    }

    private func minutes(_ s: SleepStage) -> Double {
        switch s {
        case .awake: return stages.awake
        case .light: return stages.light
        case .deep:  return stages.deep
        case .rem:   return stages.rem
        }
    }

    private func band(_ s: SleepStage) -> ClosedRange<Double>? {
        switch s {
        case .awake: return bands.awake
        case .light: return bands.light
        case .deep:  return bands.deep
        case .rem:   return bands.rem
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

    private func cell(_ stage: SleepStage, percent: Int) -> some View {
        let color = StrandPalette.sleepStageColor(stage, palette: palette)
        let share = stages.total > 0 ? min(1, max(0, minutes(stage) / stages.total)) : 0
        let isSelected = selected == stage
        let dimmed = selected != nil && !isSelected
        let typical = band(stage)
        return HStack(alignment: .center, spacing: ZoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(nightDurationText(minutes(stage)))
                    .font(StrandFont.number(19))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(percent)%")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(color)
            }
            Spacer(minLength: 4)
            ZStack {
                SquircleShape().stroke(StrandPalette.hairline, lineWidth: 4)
                SquircleShape().trim(from: 0, to: share)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                if let typical {
                    SquircleShape().trim(from: typical.lowerBound, to: max(typical.upperBound, typical.lowerBound + 0.01))
                        .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(-5)
                }
            }
            .frame(width: 38, height: 38)
            .padding(5)
            .accessibilityHidden(true)
        }
        .padding(ZoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isSelected ? StrandPalette.hairlineStrong : Color.clear, lineWidth: 1.5))
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(StrandMotion.fade) { selected = isSelected ? nil : stage }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(stage, percent: percent, typical: typical))
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilityText(_ stage: SleepStage, percent: Int, typical: ClosedRange<Double>?) -> String {
        let d = nightDurationText(minutes(stage))
        if let typical {
            let lo = Int((typical.lowerBound * 100).rounded()), hi = Int((typical.upperBound * 100).rounded())
            return String(localized: "\(stage.label): \(d), \(percent) percent of the night, typically \(lo) to \(hi) percent")
        }
        return "\(stage.label): \(d), \(percent)%"
    }
}

// MARK: Sleep latency

/// How long the night took to fall asleep, on a Fast / Normal / Late track. Only drawn when the night has
/// a staged timeline to measure it from.
struct SleepLatencyCard: View {
    let minutes: Double

    var body: some View {
        let band = SleepLatency.band(minutes: minutes)
        let fraction = SleepLatency.trackFraction(minutes: minutes)
        ZoopCard(padding: ZoopMetrics.cardInnerPadding) {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Time to fall asleep").strandOverline()
                    Spacer()
                    Text(Self.bandText(band))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(Self.bandColor(band))
                }
                Text("\(Int(minutes.rounded())) min")
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                GeometryReader { geo in
                    let w = geo.size.width
                    let fastEnd = w * CGFloat(SleepLatency.fastBelowMin / SleepLatency.trackMaxMin)
                    let lateStart = w * CGFloat(SleepLatency.lateAboveMin / SleepLatency.trackMaxMin)
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset).frame(height: 6)
                        // Zone edges as hairline ticks, so the three labels below line up with the track.
                        ForEach([fastEnd, lateStart], id: \.self) { x in
                            Rectangle().fill(StrandPalette.hairlineStrong)
                                .frame(width: 1, height: 10)
                                .position(x: x, y: geo.size.height / 2)
                        }
                        Circle()
                            .fill(Self.bandColor(band))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(StrandPalette.surfaceBase, lineWidth: 3))
                            .position(x: min(max(8, w * CGFloat(fraction)), w - 8), y: geo.size.height / 2)
                    }
                }
                .frame(height: 16)
                GeometryReader { geo in
                    let w = geo.size.width
                    let fastEnd = w * CGFloat(SleepLatency.fastBelowMin / SleepLatency.trackMaxMin)
                    let lateStart = w * CGFloat(SleepLatency.lateAboveMin / SleepLatency.trackMaxMin)
                    ZStack(alignment: .topLeading) {
                        Text(Self.bandText(.fast)).position(x: fastEnd / 2, y: 8)
                        Text(Self.bandText(.normal)).position(x: (fastEnd + lateStart) / 2, y: 8)
                        Text(Self.bandText(.late)).position(x: (lateStart + w) / 2, y: 8)
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(height: 16)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Time to fall asleep: \(Int(minutes.rounded())) minutes, \(Self.bandText(band))"))
    }

    static func bandText(_ b: SleepLatency.Band) -> String {
        switch b {
        case .fast:   return String(localized: "Fast")
        case .normal: return String(localized: "Normal")
        case .late:   return String(localized: "Late")
        }
    }

    static func bandColor(_ b: SleepLatency.Band) -> Color {
        switch b {
        case .fast, .normal: return StrandPalette.statusPositive
        case .late:          return StrandPalette.statusWarning
        }
    }
}

// MARK: Night signal chart

/// The night's heart rate, HRV, breathing rate or blood oxygen as a curve across the sleep window, with
/// a tile row to switch metric. Tiles appear only for metrics with a plausible stream for this night.
/// The 30-night comparison numbers stay in `NightVitalsCard`; this card is the curve. Heart rate shows
/// its night average (Night vitals carries resting HR, a different fact); the other three show the
/// curve's low to high, so no number here repeats a Night vitals tile.
struct NightSignalCard: View {
    @EnvironmentObject private var repo: Repository
    let startTs: Int
    let endTs: Int

    @State private var series: [NightSignal.Metric: [TrendPoint]] = [:]
    @State private var selected: NightSignal.Metric = .heartRate

    private var key: String { "\(startTs)-\(endTs)-\(repo.refreshSeq)" }

    private var available: [NightSignal.Metric] {
        NightSignal.Metric.allCases.filter { (series[$0]?.count ?? 0) > 0 }
    }

    var body: some View {
        Group {
            let metrics = available
            if let metric = metrics.contains(selected) ? selected : metrics.first,
               let points = series[metric] {
                ZoopCard(padding: ZoopMetrics.cardInnerPadding) {
                    VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                        Text("Night signals").strandOverline()
                        headline(metric, points: points)
                        chart(metric, points: points)
                            .frame(height: 150)
                        if metrics.count > 1 {
                            HStack(spacing: ZoopMetrics.space2) {
                                ForEach(metrics, id: \.self) { m in tile(m, active: m == metric) }
                            }
                        }
                    }
                }
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

    @ViewBuilder
    private func headline(_ m: NightSignal.Metric, points: [TrendPoint]) -> some View {
        let values = points.map(\.value)
        VStack(alignment: .leading, spacing: 2) {
            if m == .heartRate, let avg = NightSignal.mean(values) {
                Text(verbatim: "\(Self.format(avg, m)) \(Self.unit(m))")
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Average heart rate").strandOverline()
            } else if let lo = values.min(), let hi = values.max() {
                Text(verbatim: "\(Self.format(lo, m))–\(Self.format(hi, m)) \(Self.unit(m))")
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Self.rangeCaption(m)).strandOverline()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ m: NightSignal.Metric, points: [TrendPoint]) -> some View {
        let color = Self.color(m)
        let t0 = Double(startTs), t1 = Double(max(endTs, startTs + 1))
        let values = points.map(\.value)
        let smooth = NightSignal.smoothed(values, window: 7)
        let lo0 = values.min() ?? 0, hi0 = values.max() ?? 1
        let pad = max((hi0 - lo0) * 0.12, Self.minPad(m))
        let lo = lo0 - pad, hi = hi0 + pad
        let grid = Self.gridValues(lo: lo, hi: hi)
        return VStack(spacing: ZoopMetrics.space1) {
            Canvas { ctx, size in
                let plotW = size.width - 30
                func x(_ d: Date) -> CGFloat { CGFloat((d.timeIntervalSince1970 - t0) / (t1 - t0)) * plotW }
                func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((v - lo) / max(0.0001, hi - lo))) }
                for g in grid {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(g)))
                    line.addLine(to: CGPoint(x: plotW, y: y(g)))
                    ctx.stroke(line, with: .color(StrandPalette.hairline),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    ctx.draw(Text(verbatim: Self.gridFormat(g, m))
                                .font(StrandFont.caption)
                                .foregroundColor(StrandPalette.textTertiary),
                             at: CGPoint(x: size.width - 2, y: y(g)), anchor: .trailing)
                }
                for p in points {
                    let c = CGPoint(x: x(p.date), y: y(p.value))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)),
                             with: .color(color.opacity(0.35)))
                }
                var path = Path()
                var prev: Date?
                for (i, p) in points.enumerated() {
                    let c = CGPoint(x: x(p.date), y: y(smooth[i]))
                    if let prev, p.date.timeIntervalSince(prev) <= 20 * 60 { path.addLine(to: c) } else { path.move(to: c) }
                    prev = p.date
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            HStack {
                timeLabel(icon: "moon.fill", ts: startTs)
                Spacer()
                timeLabel(icon: "sun.max.fill", ts: endTs)
            }
            .padding(.trailing, 30)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.title(m)))
    }

    private func tile(_ m: NightSignal.Metric, active: Bool) -> some View {
        Button {
            withAnimation(StrandMotion.fade) { selected = m }
        } label: {
            Text(Self.short(m))
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(active ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: active ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.title(m))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func timeLabel(icon: String, ts: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts))))
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textTertiary)
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

    static func rangeCaption(_ m: NightSignal.Metric) -> String {
        switch m {
        case .heartRate:       return String(localized: "Heart rate range")
        case .hrv:             return String(localized: "HRV range")
        case .respiratoryRate: return String(localized: "Breathing rate range")
        case .spo2:            return String(localized: "Blood oxygen range")
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
        case .respiratoryRate, .heartRate:
            return v.formatted(.number.precision(.fractionLength(1))
                .locale(AppLanguage.activeLocale))
        case .hrv, .spo2:
            return "\(Int(v.rounded()))"
        }
    }

    /// Gridline labels: whole numbers, except breathing rate.
    static func gridFormat(_ v: Double, _ m: NightSignal.Metric) -> String {
        m == .respiratoryRate ? format(v, m) : "\(Int(v.rounded()))"
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

    /// Three evenly spaced gridline values inside the padded range.
    private static func gridValues(lo: Double, hi: Double) -> [Double] {
        let step = (hi - lo) / 4
        return [lo + step, lo + 2 * step, lo + 3 * step]
    }
}
