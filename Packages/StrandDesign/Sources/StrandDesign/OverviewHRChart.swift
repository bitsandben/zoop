#if !os(watchOS)
// Excluded on watchOS (.onContinuousHover / MagnificationGesture are unavailable there).
import SwiftUI
import Charts

// MARK: - Overview HR Chart (Today day-in-review)
//
// The 24h heart-rate line with a sleep band, a recovery marker at wake, a strain marker at "now" and a
// sport glyph at each workout's HR peak. The line and hover mirror `TrendChart`; the x-axis is pinned to
// the HR window so markers never stretch the timeline. Tokens only.

public struct OverviewHRChart: View {

    /// The sleep period to shade as a band, with an optional corner label (e.g. duration "6:06").
    public struct SleepSpan: Sendable {
        public var start: Date
        public var end: Date
        public var label: String?
        public init(start: Date, end: Date, label: String? = nil) {
            self.start = start; self.end = end; self.label = label
        }
    }

    /// A workout window; the sport glyph sits at the HR peak inside [start, end].
    public struct WorkoutSpan: Identifiable, Sendable {
        public let id = UUID()
        public var start: Date
        public var end: Date
        public var symbol: String          // SF Symbol (see `sportSymbol`)
        public init(start: Date, end: Date, symbol: String) {
            self.start = start; self.end = end; self.symbol = symbol
        }
    }

    /// A labelled vertical marker pinned to a moment in the day.
    public struct EdgeMarker: Sendable {
        public var date: Date
        public var label: String
        public var color: Color
        public var alignment: HorizontalAlignment
        public init(date: Date, label: String, color: Color, alignment: HorizontalAlignment = .leading) {
            self.date = date; self.label = label; self.color = color; self.alignment = alignment
        }
    }

    public var points: [TrendPoint]
    public var sleep: SleepSpan?
    public var workouts: [WorkoutSpan]
    public var recovery: EdgeMarker?
    public var effort: EdgeMarker?
    public var gradient: Gradient
    public var valueRange: ClosedRange<Double>
    /// Explicit x-axis window: when set the axis spans exactly this range (missing data shows as empty space); nil derives it from the data.
    public var xRange: ClosedRange<Date>?
    public var height: CGFloat
    public var showsHover: Bool
    /// Legacy opt-in for the iPhone touch scrub; every chart now scrubs through `zoopChartScrub` when `showsHover` is on. Kept so call sites compile.
    public var touchScrub: Bool
    public var valueFormat: (Double) -> String
    public var dateFormat: (Date) -> String

    /// Deep-Timeline zoom/pan window. When bound it OVERRIDES `xRange`/data extent as the visible x-domain
    /// and is mutated by pinch/scroll zoom and drag-pan. `bounds` is the full clamp it can never escape. nil elsewhere.
    @Binding public var zoomDomain: ClosedRange<Date>?
    public var zoomBounds: ClosedRange<Date>?

    /// Tint for the workout glyph badges.
    public var workoutTint: Color

    private let averageValue: Double

    public init(
        points: [TrendPoint],
        sleep: SleepSpan? = nil,
        workouts: [WorkoutSpan] = [],
        recovery: EdgeMarker? = nil,
        effort: EdgeMarker? = nil,
        gradient: Gradient = Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
        valueRange: ClosedRange<Double> = 40...120,
        xRange: ClosedRange<Date>? = nil,
        height: CGFloat = 220,
        showsHover: Bool = true,
        touchScrub: Bool = false,
        workoutTint: Color = StrandPalette.strain033,
        zoomDomain: Binding<ClosedRange<Date>?> = .constant(nil),
        zoomBounds: ClosedRange<Date>? = nil,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) }
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.sleep = sleep
        self.workouts = workouts
        self.recovery = recovery
        self.effort = effort
        self.gradient = gradient
        self.valueRange = valueRange
        self.xRange = xRange
        self.height = height
        self.showsHover = showsHover
        self.touchScrub = touchScrub
        self.workoutTint = workoutTint
        self._zoomDomain = zoomDomain
        self.zoomBounds = zoomBounds
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.averageValue = sorted.isEmpty
            ? valueRange.lowerBound
            : sorted.map(\.value).reduce(0, +) / Double(sorted.count)
        // Deep Timeline (the only caller supplying `zoomBounds`) keeps full resolution so pinch-zoom stays
        // crisp; the static Today chart downsamples. `zoomBounds` is the stable discriminator (set once),
        // unlike `zoomDomain`, which is nil until the first zoom.
        self.displayPoints = (zoomBounds != nil)
            ? sorted
            : ChartDownsample.minMaxBucketed(sorted, threshold: ChartDownsample.markThreshold,
                                             targetCount: ChartDownsample.targetVertices)
    }

    @State private var hoverX: CGFloat? = nil
    /// Zoom window captured at the start of a gesture, so it applies against a stable anchor instead of compounding per frame.
    @State private var gestureAnchorDomain: ClosedRange<Date>? = nil
    #if os(iOS)
    /// True while a touch scrub is engaged, so the zoom pan is masked off and cannot slide the window from under the crosshair (#1342).
    @State private var scrubEngaged = false
    #endif

    /// PERF: the point set handed to the line/area marks. The 24h series can exceed the plot's pixel width;
    /// outside the Deep Timeline it is min/max-bucketed to ~pixel width (keeps every visible spike).
    /// Computed ONCE in `init`; hover, markers and accessibility use the full `points`.
    private let displayPoints: [TrendPoint]

    /// Smallest zoom window (1 minute); past this the line is two points and pinch jitters.
    public static let minZoomSpan: TimeInterval = 60

    // MARK: Zoom / pan math (pure, testable)

    /// The visible domain after scaling `base` about `anchorFraction` (0…1) by `scale` (>1 zooms in), clamped into `bounds` and floored at `minZoomSpan`.
    public static func zoomed(_ base: ClosedRange<Date>, scale: Double, anchorFraction: Double,
                              bounds: ClosedRange<Date>, minSpan: TimeInterval = minZoomSpan) -> ClosedRange<Date> {
        let lo = base.lowerBound.timeIntervalSince1970
        let hi = base.upperBound.timeIntervalSince1970
        let span = hi - lo
        guard span > 0, scale > 0 else { return base }
        let pivot = lo + span * min(max(anchorFraction, 0), 1)
        let boundsSpan = bounds.upperBound.timeIntervalSince1970 - bounds.lowerBound.timeIntervalSince1970
        let newSpan = min(max(span / scale, minSpan), max(boundsSpan, minSpan))
        var newLo = pivot - (pivot - lo) * (newSpan / span)
        var newHi = newLo + newSpan
        if newLo < bounds.lowerBound.timeIntervalSince1970 {
            newLo = bounds.lowerBound.timeIntervalSince1970; newHi = newLo + newSpan
        }
        if newHi > bounds.upperBound.timeIntervalSince1970 {
            newHi = bounds.upperBound.timeIntervalSince1970; newLo = newHi - newSpan
        }
        newLo = max(newLo, bounds.lowerBound.timeIntervalSince1970)
        return Date(timeIntervalSince1970: newLo)...Date(timeIntervalSince1970: max(newLo + 1, newHi))
    }

    // MARK: Annotation scoping (pure, testable)

    /// The single sleep to band for a visible window: the LONGEST overlapping candidate (the main night,
    /// never a nap). A sleep ending exactly at the window start (or starting at its end) does NOT count.
    public static func mainSleep(_ candidates: [SleepSpan], overlapping window: ClosedRange<Date>) -> SleepSpan? {
        candidates
            .filter { $0.end > window.lowerBound && $0.start < window.upperBound }
            .max(by: { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) })
    }

    /// The workout spans overlapping a visible window (an out-of-window glyph would be clamp-dragged to the
    /// plot edge and lie about its time). Edge-touching spans are kept; order preserved.
    public static func workouts(_ candidates: [WorkoutSpan], overlapping window: ClosedRange<Date>) -> [WorkoutSpan] {
        candidates.filter { $0.end >= window.lowerBound && $0.start <= window.upperBound }
    }

    /// The visible domain after panning `base` by `deltaSeconds`, clamped into `bounds` (span preserved).
    public static func panned(_ base: ClosedRange<Date>, deltaSeconds: Double,
                              bounds: ClosedRange<Date>) -> ClosedRange<Date> {
        let lo = base.lowerBound.timeIntervalSince1970
        let hi = base.upperBound.timeIntervalSince1970
        let span = hi - lo
        var newLo = lo + deltaSeconds
        newLo = min(max(newLo, bounds.lowerBound.timeIntervalSince1970),
                    bounds.upperBound.timeIntervalSince1970 - span)
        newLo = max(newLo, bounds.lowerBound.timeIntervalSince1970)
        return Date(timeIntervalSince1970: newLo)...Date(timeIntervalSince1970: newLo + span)
    }

    // MARK: Geometry helpers

    /// The x-axis window: the caller's `xRange` wins (so a gap in samples reads as empty space), otherwise
    /// it is pinned to the HR data so markers cannot stretch the timeline.
    private var xDomain: ClosedRange<Date> {
        // Deep Timeline: the bound zoom window wins over everything.
        if let zoomDomain, zoomDomain.upperBound > zoomDomain.lowerBound { return zoomDomain }
        if let xRange, xRange.upperBound > xRange.lowerBound { return xRange }
        let lo = points.first?.date ?? Date(timeIntervalSince1970: 0)
        let hi = points.last?.date ?? lo.addingTimeInterval(3600)
        return hi > lo ? lo...hi : lo...lo.addingTimeInterval(3600)
    }

    /// The hard clamp a zoom/pan window may never escape: the caller's bounds, else the data extent.
    private var zoomClampBounds: ClosedRange<Date> {
        if let zoomBounds, zoomBounds.upperBound > zoomBounds.lowerBound { return zoomBounds }
        if let xRange, xRange.upperBound > xRange.lowerBound { return xRange }
        let lo = points.first?.date ?? Date(timeIntervalSince1970: 0)
        let hi = points.last?.date ?? lo.addingTimeInterval(3600)
        return hi > lo ? lo...hi : lo...lo.addingTimeInterval(3600)
    }

    private func clampX(_ d: Date) -> Date {
        min(max(d, xDomain.lowerBound), xDomain.upperBound)
    }

    /// Maps a value onto 0...1 over the value range, for the gradient stops.
    private func unit(_ value: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    private var valueGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    /// The peak HR sample inside a workout window, where its glyph is anchored.
    private func peak(in w: WorkoutSpan) -> TrendPoint? {
        points
            .filter { $0.date >= w.start && $0.date <= w.end }
            .max(by: { $0.value < $1.value })
    }

    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return nearestTrendPoint(to: date, in: points)
    }

    // MARK: Mark layers
    //
    // Only lines/bands are Chart marks; text labels and workout glyphs are drawn in the overlay via the
    // proxy, because `.annotation` overflow-clamping needs macOS 14 and clips on 13.

    @ChartContentBuilder private var marks: some ChartContent {
        // Share styles across marks so a dense series does not recreate the gradient per vertex.
        let areaFill = LinearGradient(
            colors: [StrandPalette.sample(stops: gradient.toStops(), at: unit(averageValue)).opacity(0.28), .clear],
            startPoint: .top, endPoint: .bottom)
        let lineStroke = valueGradient
        // Sleep band, drawn first so the HR line/area sit on top.
        if let sleep, sleep.end > xDomain.lowerBound {
            RectangleMark(
                xStart: .value("Sleep start", clampX(sleep.start)),
                xEnd: .value("Sleep end", clampX(sleep.end))
            )
            .foregroundStyle(StrandPalette.sleepDeep.opacity(0.32))
        }

        ForEach(displayPoints) { p in
            AreaMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(areaFill)
        }
        ForEach(displayPoints) { p in
            LineMark(x: .value("Time", p.date), y: .value("BPM", p.value))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(lineStroke)
        }

        // Wake divider (sleep→day boundary), shown with the band even before recovery calibrates.
        if let sleep, sleep.end > xDomain.lowerBound, sleep.end < xDomain.upperBound {
            RuleMark(x: .value("Wake", clampX(sleep.end)))
                .foregroundStyle(StrandPalette.sleepLight.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if let recovery {
            RuleMark(x: .value("Recovery", clampX(recovery.date)))
                .foregroundStyle(recovery.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if let effort {
            RuleMark(x: .value("Effort", clampX(effort.date)))
                .foregroundStyle(effort.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    // MARK: Overlay helpers

    /// Screen x for a date in container coords; nil if off-scale.
    private func xPos(_ date: Date, _ proxy: ChartProxy, _ plot: CGRect) -> CGFloat? {
        proxy.position(forX: date).map { $0 + plot.minX }
    }

    /// Rough label width for edge-clamping.
    private func estWidth(_ s: String, extra: CGFloat = 18) -> CGFloat { CGFloat(s.count) * 6.5 + extra }

    /// Places a label centred on `x`, clamped inside the plot edges.
    @ViewBuilder
    private func placed<V: View>(_ view: V, atX x: CGFloat, topY: CGFloat, width: CGFloat, plot: CGRect) -> some View {
        let half = width / 2
        let cx = min(max(x, plot.minX + half + 4), plot.maxX - half - 4)
        view.position(x: cx, y: topY)
    }

    @ViewBuilder
    private func markerLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        let topY = plot.minY + 12
        if let sleep, let label = sleep.label, sleep.end > xDomain.lowerBound {
            placed(SleepBandLabel(text: label),
                   atX: xPos(clampX(sleep.start), proxy, plot) ?? plot.minX,
                   topY: topY, width: estWidth(label, extra: 34), plot: plot)
        }
        if let recovery, let rx = xPos(clampX(recovery.date), proxy, plot) {
            placed(MarkerLabel(text: recovery.label, color: recovery.color),
                   atX: rx, topY: topY, width: estWidth(recovery.label), plot: plot)
        }
        if let effort, let sx = xPos(clampX(effort.date), proxy, plot) {
            placed(MarkerLabel(text: effort.label, color: effort.color),
                   atX: sx, topY: topY, width: estWidth(effort.label), plot: plot)
        }
        ForEach(workouts) { w in
            if let pk = peak(in: w),
               let px = xPos(pk.date, proxy, plot),
               let pyRel = proxy.position(forY: pk.value) {
                let cx = min(max(px, plot.minX + 14), plot.maxX - 14)
                WorkoutBadge(symbol: w.symbol, tint: workoutTint)
                    .position(x: cx, y: max(topY + 26, pyRel + plot.minY - 20))
            }
        }
    }

    @ViewBuilder
    private func hoverLayer(proxy: ChartProxy, plot: CGRect, container: CGSize) -> some View {
        if showsHover, let hx = hoverX,
           let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
           let pxRel = proxy.position(forX: p.date),
           let pyRel = proxy.position(forY: p.value) {
            let cx = pxRel + plot.minX
            let cy = pyRel + plot.minY
            let color = StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value))
            CrosshairRule(x: cx, height: container.height)
            HighlightDot(color: color).position(x: cx, y: cy)
            PositionedTooltip(
                anchor: CGPoint(x: cx, y: cy),
                container: container,
                tooltip: ChartTooltip(value: valueFormat(p.value), label: dateFormat(p.date), accent: color)
            )
        }
    }

    #if os(iOS)
    /// Touch scrub via `zoopChartScrub`. Where a plain horizontal drag pans the window (zoomed in, or a window
    /// narrower than its pan bounds), only the short hold engages a scrub; otherwise a sideways drag scrubs.
    /// Drives the SAME `hoverX` as Mac pointer hover.
    private var scrubStart: ZoopChartScrubStart {
        guard zoomBounds != nil else { return .horizontalDragOrHold }
        let canPan = zoomDomain != nil || xDomain != zoomClampBounds
        return canPan ? .holdOnly : .horizontalDragOrHold
    }

    private func scrubMoved(_ location: CGPoint) {
        scrubEngaged = true
        hoverX = location.x
    }

    private func scrubEnded() {
        scrubEngaged = false
        hoverX = nil
    }
    #endif

    // MARK: Body

    /// Round wall-clock x-axis ticks for the visible domain, chosen by span. Sub-hour tiers open only for the
    /// Deep Timeline, keyed on `zoomBounds` (set once), not `zoomDomain` (nil until first pinch), or the tiers would switch under the user (#829).
    private var xTicks: [Date] {
        chartTimeTicks(start: xDomain.lowerBound, end: xDomain.upperBound,
                       deepZoom: zoomBounds != nil)
    }

    public var body: some View {
        Chart { marks }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: valueRange)
        // catmullRom overshoots on sharp turns and the area gradient draws unclipped: clip the plot (see TrendChart).
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            // Manual ticks by visible span (6h down to 1min); `.automatic(desiredCount:)` can't guarantee per-minute ticks at deep zoom.
            AxisMarks(values: xTicks) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    markerLabels(proxy: proxy, plot: plot)
                    hoverLayer(proxy: proxy, plot: plot, container: geo.size)
                }
                .animation(StrandMotion.fade, value: hoverX == nil)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    // Non-animating transaction: crossing the plot edge would re-run the line's draw-on animation and flicker (TrendChart #104).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
                #if os(iOS)
                // Touch scrub on every call site (`touchScrub` is kept for source compatibility). onContinuousHover is
                // pointer-only; while zoomed, horizontal drags go to the pan (ZoomPanModifier).
                .zoopChartScrub(isEnabled: showsHover, start: scrubStart,
                                onChange: { scrubMoved($0) }, onEnd: { scrubEnded() })
                #endif
            }
        }
        .frame(height: height)
        // Zoom/pan: active whenever a zoom binding is supplied. Keyed on `zoomBounds` (stable), NOT the live
        // `zoomDomain` (nil until first zoom), or the gestures would be unmounted when the first pinch must land (#829).
        // `apply` normalises a window covering the full clamp back to nil so an un-zoomed drag never flips to "Zoomed in".
        .modifier(ZoomPanModifier(
            isActive: zoomBounds != nil,
            scrubActive: {
                #if os(iOS)
                scrubEngaged
                #else
                false
                #endif
            },
            isZoomed: { zoomDomain != nil },
            current: { xDomain },
            bounds: zoomClampBounds,
            anchor: $gestureAnchorDomain,
            apply: { newDomain in
                zoomDomain = (newDomain.lowerBound <= zoomClampBounds.lowerBound
                              && newDomain.upperBound >= zoomClampBounds.upperBound) ? nil : newDomain
            },
            reset: { zoomDomain = nil },
            zoom: { base, scale, frac, bounds in Self.zoomed(base, scale: scale, anchorFraction: frac, bounds: bounds) },
            pan: { base, dx, plotWidth, bounds in
                let span = base.upperBound.timeIntervalSince1970 - base.lowerBound.timeIntervalSince1970
                let secPerPoint = plotWidth > 0 ? span / Double(plotWidth) : 0
                return Self.panned(base, deltaSeconds: -dx * secPerPoint, bounds: bounds)
            }
        ))
        // Collapse the Charts marks into ONE VoiceOver element with a summary (hover is dead on touch, so the chart otherwise spoke no heart rate).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate, 24 hours"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    /// One-line VoiceOver summary: the day's HR (count, mean, range) plus the band/marker context.
    private var accessibilitySummary: String {
        guard !points.isEmpty else { return String(localized: "No heart-rate data", bundle: .module) }
        let values = points.map(\.value)
        let lo = values.min() ?? valueRange.lowerBound
        let hi = values.max() ?? valueRange.upperBound
        var parts = [String(localized: "\(points.count) readings", bundle: .module),
                     String(localized: "average \(valueFormat(averageValue)) bpm", bundle: .module),
                     String(localized: "range \(valueFormat(lo)) to \(valueFormat(hi))", bundle: .module)]
        if let sleep {
            parts.append(String(localized: "asleep \(Self.hoursMinutes(sleep.end.timeIntervalSince(sleep.start)))", bundle: .module))
        }
        if let recovery { parts.append(recovery.label) }
        if let effort { parts.append(effort.label) }
        if !workouts.isEmpty {
            parts.append(workouts.count == 1 ? String(localized: "1 workout", bundle: .module) : String(localized: "\(workouts.count) workouts", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }

    private static func hoursMinutes(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let h = total / 3_600, m = (total % 3_600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

// MARK: - Chart time ticks (x-axis)

/// Round wall-clock x-axis tick DATES for a `[start, end]` window at intervals chosen by span (a full day
/// ticks every 6h, a 1h window every 15min), stepping in LOCAL wall-clock time from local midnight so
/// midnight crossings and DST stay round. Pure and clock-free; returns dates, never strings.
///
/// `deepZoom` opens the sub-hour tiers (5/2/1 min) for the Deep Timeline. Off by default: Today cards
/// hand this the RENDERED extent of banked buckets, and ten minutes of HR would draw ten 1-minute gridlines.
public func chartTimeTicks(start: Date, end: Date, calendar: Calendar = .current,
                           deepZoom: Bool = false) -> [Date] {
    guard end > start else { return [] }
    let spanMinutes = end.timeIntervalSince(start) / 60.0
    // Thresholds sit below the nominal Today-card windows (24h/12h/6h/3h/1h) so a window with slightly less
    // banked data still lands on its interval; deep-zoom tiers (≤30min to 1-min) serve the Deep Timeline.
    let stepMinutes: Int = {
        switch spanMinutes {
        case (20 * 60)...: return 360   // 6h ticks above 20h
        case (10 * 60)...: return 180   // 3h ticks above 10h
        case (5 * 60)...:  return 120   // 2h ticks above 5h
        case (2 * 60)...:  return 60    // 1h ticks above 2h
        default: break
        }
        // Below 2h the static cards stop at 15min.
        guard deepZoom else { return 15 }
        switch spanMinutes {
        case 60...: return 15   // 15min ticks above 1h
        case 30...: return 5    // 5min ticks above 30min
        case 10...: return 2    // 2min ticks above 10min
        default:    return 1    // 1min ticks below 10min
        }
    }()

    var components = calendar.dateComponents([.year, .month, .day], from: start)
    components.hour = 0; components.minute = 0; components.second = 0
    var tick = calendar.date(from: components) ?? start
    var out: [Date] = []
    var last = Date.distantPast
    // Bounded walk so a malformed window cannot spin.
    var steps = 0
    while steps < 4096 {
        steps += 1
        if tick > end { break }
        if tick >= start && tick > last {
            out.append(tick)
            last = tick
        }
        tick = calendar.date(byAdding: .minute, value: stepMinutes, to: tick) ?? end
    }
    return out
}

// MARK: - Marker chrome

/// Sport glyph in a tinted badge, anchored above a workout's HR peak.
private struct WorkoutBadge: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
            )
            .shadow(color: tint.opacity(0.5), radius: 4, y: 1)
            .allowsHitTesting(false)
    }
}

/// Small caps read-out for the recovery / strain edge markers.
private struct MarkerLabel: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(ZoopPanelSurface(cornerRadius: 6, elevated: true, surfaceOpacity: 0.92))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// Moon glyph + sleep duration at the leading corner of the sleep band.
private struct SleepBandLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.fill").font(.system(size: 9))
            Text(text).font(StrandFont.footnote).fontWeight(.semibold)
        }
        .foregroundStyle(StrandPalette.sleepLight)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(ZoopPanelSurface(cornerRadius: 6, elevated: true, surfaceOpacity: 0.92))
        .fixedSize()
        .allowsHitTesting(false)
    }
}

// MARK: - Zoom / pan gesture host
//
// A standalone modifier so the platform split (pinch on iOS, scroll-to-zoom on macOS, drag-pan on both) lives in one place. No-op when `isActive` is false.

private struct ZoomPanModifier: ViewModifier {
    let isActive: Bool
    /// True while a touch scrub is engaged, so the pan drag is masked off and cannot also slide the window (#1342). Always false on macOS.
    let scrubActive: () -> Bool
    /// True while zoomed in (a reset is meaningful), read at double-tap time.
    let isZoomed: () -> Bool
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    @Binding var anchor: ClosedRange<Date>?
    let apply: (ClosedRange<Date>) -> Void
    let reset: () -> Void
    let zoom: (ClosedRange<Date>, Double, Double, ClosedRange<Date>) -> ClosedRange<Date>
    let pan: (ClosedRange<Date>, CGFloat, CGFloat, ClosedRange<Date>) -> ClosedRange<Date>

    @State private var plotWidth: CGFloat = 1
    // Reduce Motion: the reset snaps; gesture frames are never animated.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resets the window, snapping when Reduce Motion is on.
    private func resetZoom() {
        guard isZoomed() else { return }
        withAnimation(ZoopMotion.gated(StrandMotion.interactive, reduced: reduceMotion)) { reset() }
    }

    func body(content: Content) -> some View {
        guard isActive else { return AnyView(content) }
        // 10 pt (not 6) so the pan cannot start inside the scrub long-press's 8 pt hold window (#1342).
        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                let base = anchor ?? current()
                if anchor == nil { anchor = base }
                apply(pan(base, value.translation.width, plotWidth, bounds))
            }
            .onEnded { _ in anchor = nil }

        let magnify = MagnificationGesture()
            .onChanged { scale in
                let base = anchor ?? current()
                if anchor == nil { anchor = base }
                // Pinch zooms about the window centre (MagnificationGesture gives no focal point).
                apply(zoom(base, Double(scale), 0.5, bounds))
            }
            .onEnded { _ in anchor = nil }

        // Double-tap resets to the full window. No accessibility action: the chart is one labelled VoiceOver element, so the tap never steals double-tap-to-activate.
        let doubleTapReset = TapGesture(count: 2).onEnded { resetZoom() }

        let measured = content.background(
            GeometryReader { geo in
                Color.clear.onAppear { plotWidth = geo.size.width }
                    .onChangeCompat(of: geo.size.width) { plotWidth = $0 }
            }
        )

        #if os(macOS)
        // macOS: drag pans; scroll-to-zoom is handled by the Deep Timeline host's scroll modifier.
        return AnyView(measured.gesture(drag).simultaneousGesture(doubleTapReset))
        #else
        // Mask the pan off while a scrub is engaged (the pan is `.simultaneous`, so it would otherwise co-recognise with the scrub) (#1342).
        return AnyView(measured.gesture(magnify)
            .simultaneousGesture(drag, including: scrubActive() ? .subviews : .all)
            .simultaneousGesture(doubleTapReset))
        #endif
    }
}

#if DEBUG
#Preview("OverviewHRChart") {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let pts: [TrendPoint] = (0..<288).map { i in
        let t = now.addingTimeInterval(Double(i) * 300 - 288 * 300)
        let base = 58.0 + 18 * abs(sin(Double(i) / 30.0))
        let spike = (i > 200 && i < 215) ? 75.0 : 0
        return TrendPoint(date: t, value: base + spike)
    }
    return VStack(alignment: .leading, spacing: 12) {
        Text("Overview HR").strandOverline()
        OverviewHRChart(
            points: pts,
            sleep: .init(start: pts.first!.date, end: pts.first!.date.addingTimeInterval(6 * 3600 + 6 * 60), label: "6:06"),
            workouts: [.init(start: pts[200].date, end: pts[215].date, symbol: "figure.run")],
            recovery: .init(date: pts.first!.date.addingTimeInterval(6 * 3600), label: "67% Recovery", color: StrandPalette.recoveryColor(67)),
            effort: .init(date: pts.last!.date, label: "12.5 Effort", color: StrandPalette.strainColor(12.5), alignment: .trailing),
            valueRange: 45...140
        )
    }
    .padding(28)
    .frame(width: 760, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
