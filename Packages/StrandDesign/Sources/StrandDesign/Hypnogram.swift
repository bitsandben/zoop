#if !os(watchOS)
// Excluded on watchOS (uses .onContinuousHover + ChartHover helpers).
import SwiftUI

// MARK: - Hypnogram (Sleep)
//
// A sleep-stage banded timeline. Four faint stage lanes (awake top → deep bottom) anchor height to
// stage; each interval is a flat, square-ended bar whose WIDTH tracks its duration (brief stages stay
// slim ticks), coloured with the sleep tokens. Transitions are quiet vertical risers, so the night
// reads as one staircase.

/// A single stage interval. `start`/`end` are seconds from the start of the night.
public struct SleepInterval: Identifiable, Sendable {
    public var stage: SleepStage
    public var start: TimeInterval
    public var end: TimeInterval

    /// Stable, CONTENT-derived identity (stage + start + end). A random `UUID()` re-identified every band
    /// on each body eval and rebuilt the whole chart. Intervals within a night do not overlap, so this is unique.
    public var id: String { "\(stage.rawValue)|\(start)|\(end)" }

    public init(stage: SleepStage, start: TimeInterval, end: TimeInterval) {
        self.stage = stage
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public struct Hypnogram: View {

    public var intervals: [SleepInterval]
    public var height: CGFloat
    public var showsStageAxis: Bool
    /// Whether hovering a stage band highlights it and shows a tooltip. Defaults on.
    public var showsHover: Bool
    /// Optional wall-clock time the night began; when set the tooltip shows clock times, otherwise elapsed time.
    public var nightStart: Date?
    /// Whether to anchor the timeline with an x time axis (onset, midpoint, wake). Needs `nightStart`. Defaults off.
    public var showsTimeAxis: Bool
    /// When set, this stage's segments and lane render at full strength while others recede.
    public var highlightedStage: SleepStage?
    /// When true, each band extends from its lane DOWN to the baseline (filled stepped-area) instead of the slim ribbon.
    public var filled: Bool
    /// The stage-colour ramp: Zoop tokens by default, Oura's (Ribbon) or Garmin's (Garmin Fill) for the Sleep-tab stepped chart.
    public var stagePalette: SleepStagePalette

    public init(
        intervals: [SleepInterval],
        height: CGFloat = 180,
        showsStageAxis: Bool = true,
        showsHover: Bool = true,
        nightStart: Date? = nil,
        showsTimeAxis: Bool = false,
        smoothingSeconds: TimeInterval = 300,
        highlightedStage: SleepStage? = nil,
        filled: Bool = false,
        stagePalette: SleepStagePalette = .noop
    ) {
        let sorted = intervals.sorted { $0.start < $1.start }
        self.intervals = smoothingSeconds > 0
            ? Hypnogram.displaySmoothed(sorted, minDuration: smoothingSeconds)
            : sorted
        self.height = height
        self.showsStageAxis = showsStageAxis
        self.showsHover = showsHover
        self.nightStart = nightStart
        self.showsTimeAxis = showsTimeAxis
        self.highlightedStage = highlightedStage
        self.filled = filled
        self.stagePalette = stagePalette
    }

    // MARK: Display smoothing
    //
    // The stager emits 30s-epoch runs, so a night arrives as 60–100 fragments whose risers render as an
    // unreadable "comb". Brief fragments are absorbed into their surroundings AT DISPLAY TIME only; totals
    // and stored data come from the raw segments. `smoothingSeconds: 0` renders the raw timeline. Public so
    // other stage-timeline renderings reuse it.
    public static func displaySmoothed(_ sorted: [SleepInterval], minDuration: TimeInterval) -> [SleepInterval] {
        guard sorted.count > 2 else { return sorted }

        // Coalesce adjacent same-stage runs (also bridges zero-length epoch seams).
        func coalesce(_ ivs: [SleepInterval]) -> [SleepInterval] {
            var out: [SleepInterval] = []
            for iv in ivs {
                if let last = out.last, last.stage == iv.stage, iv.start - last.end < 1 {
                    out[out.count - 1] = SleepInterval(stage: last.stage, start: last.start, end: iv.end)
                } else {
                    out.append(iv)
                }
            }
            return out
        }

        var ivs = coalesce(sorted)
        // Repeatedly absorb the shortest sub-threshold fragment into a neighbour until all blocks clear the threshold.
        while ivs.count > 1 {
            guard let idx = ivs.indices
                .filter({ ivs[$0].duration < minDuration })
                .min(by: { ivs[$0].duration < ivs[$1].duration }) else { break }
            let victim = ivs[idx]
            let prev = idx > 0 ? ivs[idx - 1] : nil
            let next = idx < ivs.count - 1 ? ivs[idx + 1] : nil
            if let p = prev, let n = next {
                // Absorb into the longer neighbour so the dominant stage wins.
                if p.duration >= n.duration {
                    ivs[idx - 1] = SleepInterval(stage: p.stage, start: p.start, end: victim.end)
                } else {
                    ivs[idx + 1] = SleepInterval(stage: n.stage, start: victim.start, end: n.end)
                }
            } else if let p = prev {
                ivs[idx - 1] = SleepInterval(stage: p.stage, start: p.start, end: victim.end)
            } else if let n = next {
                ivs[idx + 1] = SleepInterval(stage: n.stage, start: victim.start, end: n.end)
            } else {
                break
            }
            ivs.remove(at: idx)
            ivs = coalesce(ivs)
        }
        return ivs
    }

    @State private var hoverIndex: Int? = nil

    private static let clockFormatter: DateFormatter = {
        // "jmm" respects the device's 12-/24-hour setting (#337).
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()

    /// Formats a seconds-from-night-start offset as wall-clock (if `nightStart` is set) or elapsed H:MM.
    /// Deliberately does NOT subtract `origin`: that is a layout anchor (first VISIBLE interval), and on a
    /// holed/partial timeline surviving stages can start hours into the night. `internal` so tests can pin the math.
    func timeLabel(_ secondsFromNightStart: TimeInterval) -> String {
        if let nightStart {
            let d = nightStart.addingTimeInterval(secondsFromNightStart)
            return Hypnogram.clockFormatter.string(from: d)
        }
        let total = Int(secondsFromNightStart.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }

    private var span: TimeInterval {
        guard let first = intervals.first, let last = intervals.max(by: { $0.end < $1.end }) else { return 1 }
        return max(1, last.end - first.start)
    }
    private var origin: TimeInterval { intervals.first?.start ?? 0 }

    /// ONE spoken summary of the whole night (total time per stage) for VoiceOver, instead of one element per
    /// interval, which was a heavy semantics subtree (#707). e.g. "Sleep stages, 2 hours deep, 1 hour 30 minutes REM, ...".
    private var axSummary: String {
        guard !intervals.isEmpty else { return String(localized: "Sleep stages, no data", bundle: .module) }
        // Natural read order (deep, REM, light, awake); only stages that occur are named.
        var parts: [String] = []
        for stage in [SleepStage.deep, .rem, .light, .awake] {
            let total = intervals.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration }
            if total > 0 { parts.append("\(Hypnogram.durationPhrase(total)) \(stage.label.lowercased())") }
        }
        return parts.isEmpty ? String(localized: "Sleep stages, no data", bundle: .module)
                             : String(localized: "Sleep stages, \(parts.joined(separator: ", "))", bundle: .module)
    }

    /// A spoken duration phrase ("2 hours 5 minutes", "45 minutes").
    private static func durationPhrase(_ seconds: TimeInterval) -> String {
        let total = Int((seconds / 60).rounded())   // whole minutes
        let h = total / 60
        let m = total % 60
        // Whole-phrase per unit so each key can carry its own plural rule.
        func hours(_ n: Int) -> String { n == 1 ? String(localized: "1 hour", bundle: .module) : String(localized: "\(n) hours", bundle: .module) }
        func minutes(_ n: Int) -> String { n == 1 ? String(localized: "1 minute", bundle: .module) : String(localized: "\(n) minutes", bundle: .module) }
        if h > 0 && m > 0 { return "\(hours(h)) \(minutes(m))" }
        if h > 0 { return hours(h) }
        return minutes(max(m, 1))
    }

    // 4 stage rows; awake = rank 0 (top), deep = rank 3 (bottom).
    private let rowCount = 4

    /// The band/lane colour for a stage: the brand ramp (Garmin/Oura) when opted in, else the Zoop sleep tokens.
    private func stageColor(_ stage: SleepStage) -> Color {
        StrandPalette.sleepStageColor(stage, palette: stagePalette)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showsStageAxis { axis }
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack {
                        // STATIC LAYER: rebuilds only when intervals/size/hover change, flattened to one cached raster via
                        // .drawingGroup() (flat solid pills, so pixel-identical). The hover overlay stays OUTSIDE. drawingGroup
                        // strips child accessibility, which is served by ONE collapsed element (`axSummary`).
                        ZStack {
                            // Faint per-stage lanes so the eye maps height to stage even across gaps.
                            ForEach(0..<rowCount, id: \.self) { rank in
                                let stage = stagesTopToBottom[rank]
                                let rowStep = geo.size.height / CGFloat(rowCount)
                                // The highlighted stage's lane brightens.
                                let lane = highlightedStage == stage ? 0.16 : 0.07
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(stageColor(stage).opacity(lane))
                                    .frame(width: geo.size.width, height: rowStep * 0.74)
                                    .position(x: geo.size.width / 2, y: rowY(rank, in: geo.size.height))
                            }

                            // time-axis hairlines: onset, midpoint, wake
                            if showsTimeAxis, nightStart != nil {
                                ForEach([0.0, 0.5, 1.0], id: \.self) { frac in
                                    let x = geo.size.width * frac
                                    Path { p in
                                        p.move(to: CGPoint(x: x, y: 0))
                                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                                    }
                                    .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 1)
                                }
                            }

                            risers(in: geo.size)

                            // stage bands (visual only)
                            ForEach(Array(intervals.enumerated()), id: \.element.id) { idx, interval in
                                let band = bandRect(for: interval, in: geo.size)
                                // FILLED: extend the band down to the baseline. RIBBON: the slim band.
                                let rect = filled
                                    ? CGRect(x: band.minX, y: band.midY, width: band.width,
                                             height: max(0, geo.size.height - band.midY))
                                    : band
                                let color = stageColor(interval.stage)
                                let hoverDimmed = hoverIndex != nil && hoverIndex != idx
                                let stageDimmed = highlightedStage != nil && interval.stage != highlightedStage
                                // Squared segments: a brief stage draws at its true duration as a thin tick, never inflated into a dot.
                                // A highlighted stage makes everything else recede.
                                RoundedRectangle(cornerRadius: filled ? 0 : 2.5, style: .continuous)
                                    .fill(color)
                                    .frame(width: rect.width, height: rect.height)
                                    .opacity(stageDimmed ? 0.22 : (hoverDimmed ? 0.45 : 1.0))
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                        // No .drawingGroup() here: the per-instance offscreen flatten cost more than it saved.
                        .accessibilityHidden(true)

                        if showsHover, let idx = hoverIndex, idx < intervals.count {
                            let interval = intervals[idx]
                            let rect = bandRect(for: interval, in: geo.size)
                            let color = stageColor(interval.stage)
                            CrosshairRule(x: rect.midX, height: geo.size.height)
                            RoundedRectangle(cornerRadius: (rect.height + 6) / 2)
                                .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                                .frame(width: rect.width + 6, height: rect.height + 6)
                                .position(x: rect.midX, y: rect.midY)
                            PositionedTooltip(
                                anchor: CGPoint(x: rect.midX, y: rect.midY),
                                container: geo.size,
                                tooltip: ChartTooltip(
                                    value: interval.stage.label,
                                    label: "\(timeLabel(interval.start))-\(timeLabel(interval.end)) · \(Int((interval.duration / 60).rounded()))m",
                                    accent: color
                                )
                            )
                        }
                    }
                    .animation(StrandMotion.fade, value: hoverIndex == nil)
                    .animation(StrandMotion.fade, value: highlightedStage)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        guard showsHover else { return }
                        switch phase {
                        case .active(let location):
                            hoverIndex = intervalIndex(atX: location.x, in: geo.size)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    .zoopChartScrub(isEnabled: showsHover && !intervals.isEmpty,
                                    onChange: { hoverIndex = intervalIndex(atX: $0.x, in: geo.size) },
                                    onEnd: { hoverIndex = nil })
                    // ONE collapsed VoiceOver element for the whole hypnogram (see `axSummary`); the bands are accessibilityHidden.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(axSummary))
                }
                .frame(height: height)

                // x time axis: onset, midpoint, wake clock labels
                if showsTimeAxis, nightStart != nil {
                    HStack(spacing: 0) {
                        Text(timeLabel(origin)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(timeLabel(origin + span / 2)).frame(maxWidth: .infinity, alignment: .center)
                        Text(timeLabel(origin + span)).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    /// The interval whose horizontal span contains a local x, or the nearest.
    private func intervalIndex(atX x: CGFloat, in size: CGSize) -> Int? {
        guard !intervals.isEmpty, size.width > 0 else { return nil }
        let t = origin + Double(x / size.width) * span
        for (i, iv) in intervals.enumerated() where t >= iv.start && t <= iv.end {
            return i
        }
        return intervals.enumerated().min(by: { a, b in
            abs(midTime(a.element) - t) < abs(midTime(b.element) - t)
        })?.offset
    }

    private func midTime(_ iv: SleepInterval) -> TimeInterval { (iv.start + iv.end) / 2 }

    // MARK: Axis

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(stagesTopToBottom, id: \.self) { stage in
                Text(stage.label)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 44, height: height)
    }

    private var stagesTopToBottom: [SleepStage] {
        [.awake, .rem, .light, .deep]
    }

    // MARK: Geometry

    private func rowY(_ rank: Int, in totalHeight: CGFloat) -> CGFloat {
        let usable = totalHeight
        let step = usable / CGFloat(rowCount)
        return step * (CGFloat(rank) + 0.5)
    }

    private func bandRect(for interval: SleepInterval, in size: CGSize) -> CGRect {
        let x0 = CGFloat((interval.start - origin) / span) * size.width
        let x1 = CGFloat((interval.end - origin) / span) * size.width
        // Slim UNIFORM ribbon thickness: the night reads as one stepped line, not slabs.
        let thickness: CGFloat = 12
        // Width is the TRUE duration, floored at a hairline; never floored to the thickness (that inflated short stages into dots).
        let width = max(2, x1 - x0)
        let mid = (x0 + x1) / 2
        let y = rowY(interval.stage.bandRank, in: size.height)
        return CGRect(x: mid - width / 2, y: y - thickness / 2, width: width, height: thickness)
    }

    // Quiet vertical hairlines between consecutive stage levels; they recede while a stage is highlighted.
    private func risers(in size: CGSize) -> some View {
        Path { p in
            for i in 0..<(intervals.count - (intervals.isEmpty ? 0 : 1)) {
                let a = intervals[i]
                let b = intervals[i + 1]
                let x = CGFloat((b.start - origin) / span) * size.width
                let ya = rowY(a.stage.bandRank, in: size.height)
                let yb = rowY(b.stage.bandRank, in: size.height)
                p.move(to: CGPoint(x: x, y: ya))
                p.addLine(to: CGPoint(x: x, y: yb))
            }
        }
        .stroke(StrandPalette.textTertiary.opacity(highlightedStage == nil ? 0.35 : 0.15),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

#if DEBUG
private func sampleNight() -> [SleepInterval] {
    var t: TimeInterval = 0
    func add(_ stage: SleepStage, _ minutes: Double) -> SleepInterval {
        let s = SleepInterval(stage: stage, start: t, end: t + minutes * 60)
        t += minutes * 60
        return s
    }
    return [
        add(.awake, 6),
        add(.light, 22),
        add(.deep, 38),
        add(.light, 18),
        add(.rem, 24),
        add(.light, 14),
        add(.deep, 30),
        add(.rem, 28),
        add(.light, 20),
        add(.awake, 4),
        add(.rem, 32),
        add(.light, 26),
        add(.awake, 8),
    ]
}

#Preview("Hypnogram") {
    let start = Calendar.current.date(bySettingHour: 23, minute: 18, second: 0, of: Date())
    return VStack(alignment: .leading, spacing: 12) {
        Text("Last night").strandOverline()
        Text("Hover a band: stage name, clock start–end and duration.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        Hypnogram(intervals: sampleNight(), height: 200, nightStart: start)
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
