#if !os(watchOS)
// TrendChart uses `.onContinuousHover` (unavailable on watchOS), so the file is excluded there.
import SwiftUI
import Charts

// MARK: - Trend Chart
// Line/area chart whose line is gradient-stroked by value. The gradient defaults to the recovery scale; any gradient + value range works (sleep blue, HRV teal, strain amber).

/// The index runs that `hrGapSegments` implies: one range per unbroken stretch, in order.
/// A hand-drawn sparkline needs the runs to know where to lift the pen, derived from the same source of truth (#2082).
/// Empty input yields no runs; a run of one is still a run (a lone bucket between gaps is real data).
public func hrGapRuns(segments: [String]) -> [ClosedRange<Int>] {
    guard !segments.isEmpty else { return [] }
    var runs: [ClosedRange<Int>] = []
    var start = 0
    for i in 1..<segments.count where segments[i] != segments[i - 1] {
        runs.append(start...(i - 1))
        start = i
    }
    runs.append(start...(segments.count - 1))
    return runs
}

/// Segment ids for a bucketed time series, changing wherever the series SKIPS a bucket.
/// Aggregates only emit rows for buckets with samples, so without this the line joins neighbours across an hour the strap was off and draws a climb the wearer never had.
/// Pass to `TrendPoint.segment` so a gap looks like a gap. A step of exactly one bucket is contiguous; anything longer breaks, with no tolerance for one missing bucket.
public func hrGapSegments(bucketTs: [Int], bucketSeconds: Int) -> [String] {
    var segment = 0
    return bucketTs.enumerated().map { i, ts in
        if i > 0, ts - bucketTs[i - 1] > bucketSeconds { segment += 1 }
        return String(segment)
    }
}

/// One point on a trend line.
public struct TrendPoint: Identifiable, Sendable {
    public var date: Date
    public var value: Double
    /// Sequential line-segment id; points with different ids render as separate lines, so no false transition is drawn across incompatible methods.
    public var segment: String

    /// Stable, content-derived identity (one point per date). A random `UUID()` defeats Swift Charts' diffing and replays the draw animation.
    public var id: Date { date }

    public init(date: Date, value: Double, segment: String = "default") {
        self.date = date
        self.value = value
        self.segment = segment
    }
}

private struct WorkoutTimeAxisModifier: ViewModifier {
    let range: ClosedRange<Date>?

    init(_ range: ClosedRange<Date>?) { self.range = range }

    func body(content: Content) -> some View {
        if let range {
            content
                .chartXScale(domain: range)
                .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(elapsedLabel(date, start: range.lowerBound))
                        }
                    }
                    .foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
                }
            }
        } else {
            content
        }
    }

    private func elapsedLabel(_ date: Date, start: Date) -> String {
        let elapsed = max(0, Int(date.timeIntervalSince(start)))
        let minutes = elapsed / 60
        if minutes >= 60 { return String(format: "%d:%02d", minutes / 60, minutes % 60) }
        return String(format: String(localized: "%lld minutes"), Int64(minutes))
    }
}

/// Find a reading in the date-sorted, full-resolution series by binary search (runs per drag/hover event).
/// Drawing may omit points but selection returns the original reading; an equal-distance tie picks the earlier one.
func nearestTrendPoint(to date: Date, in points: [TrendPoint]) -> TrendPoint? {
    guard !points.isEmpty else { return nil }
    var lower = 0, upper = points.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if points[middle].date < date { lower = middle + 1 } else { upper = middle }
    }
    if lower == 0 { return points[0] }
    if lower == points.count { return points[lower - 1] }
    let before = points[lower - 1], after = points[lower]
    return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
}

public struct TrendChart: View {

    public var points: [TrendPoint]
    /// The gradient the line/area is stroked with (defaults to the recovery scale).
    public var gradient: Gradient
    /// The value range mapped onto the gradient (0 → bottom color, max → top color).
    public var valueRange: ClosedRange<Double>
    /// Whether to draw the soft area fill below the line.
    public var showsArea: Bool
    /// Draw vertical bars from the axis baseline instead of line + area + points (one value-ramp-filled `BarMark` per down-sampled sample). Display-only; `showsArea` is ignored in bar mode.
    public var showsBars: Bool
    public var yAxisStep: Double?
    public var showsBarValues: Bool
    public var largeSelection: Bool
    @State private var selectedPoint: TrendPoint?
    @State private var holdingBar = false

    /// Optional personal-baseline reference, drawn as a dashed rule UNDER the series. Nil draws nothing; the rule rides the chart's y domain, so an out-of-range value falls off instead of being clamped.
    public var baselineValue: Double?
    public var height: CGFloat
    /// Whether hovering reveals a crosshair + tooltip for the nearest point.
    public var showsHover: Bool
    /// Formats a point's value for the tooltip's bold line (default: rounded int).
    public var valueFormat: (Double) -> String
    /// Formats a point's date for the tooltip's secondary line.
    public var dateFormat: (Date) -> String
    /// Optional human-readable series name for VoiceOver (e.g. "HRV trend"). When nil the
    /// element falls back to a generic "Trend" label so it's never unlabeled.
    public var accessibilityLabel: String?
    /// When set, draws a glowing "now" end-cap on the latest point in the chart's own coordinate space (via the overlay proxy) so it sits on the line (#458). nil = no cap.
    public var nowCapColor: Color?
    /// Y-axis domain when it should differ from `valueRange` (e.g. fitted to the data window while the gradient stays on the full scale). nil = `valueRange`.
    /// Widening the TOP keeps a peak and the top axis label clear of the plot clip (#974); pure data space, no macOS14/iOS17 padding API.
    public var yDomain: ClosedRange<Double>?
    /// Optional elapsed time window for a workout trace, with workout-relative tick labels.
    public var workoutTimeAxis: ClosedRange<Date>?
    /// Draws the value/date tooltip beside the scrub rule. A host that prints the scrubbed reading itself turns it off; the rule and dot stay.
    public var showsTooltip: Bool
    /// Called with the point under the finger while a touch scrub runs, and with nil when it ends (iOS).
    public var onSelectionChange: ((TrendPoint?) -> Void)?

    /// Mean of all point values, computed once in `init` rather than per mark per render.
    private let averageValue: Double

    /// One-line VoiceOver summary (count + mean + range), built once in `init`.
    private let a11ySummary: String

    public init(
        points: [TrendPoint],
        gradient: Gradient = StrandPalette.recoveryGradient,
        valueRange: ClosedRange<Double> = 0...100,
        showsArea: Bool = true,
        showsBars: Bool = false,
        baselineValue: Double? = nil,
        height: CGFloat = 220,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) },
        accessibilityLabel: String? = nil,
        nowCapColor: Color? = nil,
        yDomain: ClosedRange<Double>? = nil,
        workoutTimeAxis: ClosedRange<Date>? = nil,
        yAxisStep: Double? = nil,
        showsBarValues: Bool = false,
        largeSelection: Bool = false,
        showsTooltip: Bool = true,
        onSelectionChange: ((TrendPoint?) -> Void)? = nil
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.gradient = gradient
        self.valueRange = valueRange
        self.showsArea = showsArea
        self.showsBars = showsBars
        self.baselineValue = baselineValue
        self.height = height
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.accessibilityLabel = accessibilityLabel
        self.nowCapColor = nowCapColor
        self.yDomain = yDomain
        self.workoutTimeAxis = workoutTimeAxis
        self.yAxisStep = yAxisStep
        self.showsBarValues = showsBarValues
        self.largeSelection = largeSelection
        self.showsTooltip = showsTooltip
        self.onSelectionChange = onSelectionChange
        let avg = sorted.isEmpty
            ? valueRange.lowerBound
            : sorted.map(\.value).reduce(0, +) / Double(sorted.count)
        self.averageValue = avg

        // Point set handed to the marks: full resolution up to the threshold, else min/max-bucketed to ~the plot pixel width. Computed once.
        self.displayPoints = ChartDownsample.minMaxBucketed(sorted, threshold: ChartDownsample.markThreshold,
                                                            targetCount: ChartDownsample.targetVertices)

        // VoiceOver one-liner (count + mean + range) uses the tooltip's valueFormat so units match. Computed once.
        if sorted.isEmpty {
            self.a11ySummary = String(localized: "No data", bundle: .module)
        } else {
            let vals = sorted.map(\.value)
            let lo = vals.min()!, hi = vals.max()!
            self.a11ySummary = String(localized: "\(sorted.count) points, mean \(valueFormat(avg)), range \(valueFormat(lo)) to \(valueFormat(hi))", bundle: .module)
        }
    }

    /// The x-position the cursor is hovering, in chart-local coordinates.
    @State private var hoverX: CGFloat? = nil

    /// PERF: a 365-day series feeds Charts hundreds of catmullRom vertices, mostly sub-pixel. `displayPoints` is full resolution up to a threshold, else min/max-per-bucket to ~the plot pixel width,
    /// keeping every visible peak and trough. Computed once in `init`; hover, now-cap and accessibility stay on the full-resolution `points`.
    private let displayPoints: [TrendPoint]

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    /// Default tooltip date format ("EEE d MMM"), exposed to seed the `dateFormat` default argument.
    public static func defaultDateString(_ date: Date) -> String {
        sharedDateFormatter.string(from: date)
    }

    private static func axisNumberLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// The point nearest a given chart-local x, using the proxy to map back.
    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return nearestTrendPoint(to: date, in: points)
    }

    /// The days the x-axis marks, so marks and label format agree. Spans `displayPoints` (what the marks are built from), not `points`:
    /// bucketing keeps extremes so they agree today, but deriving the axis from an undrawn collection stops being true quietly.
    private var axisDays: [Date] { ChartAxisDays.spanning(displayPoints.map(\.date)) }

    // Map data values onto the unit interval for gradient stops.
    private func unit(_ value: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    // A vertical gradient keyed to the value axis so the stroke color tracks value.
    private var valueGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    /// The Y domain applied to axis and plot clip: the explicit `yDomain` if given, else the gradient's `valueRange`. Internal so a test can pin it without rendering.
    var resolvedYDomain: ClosedRange<Double> { yDomain ?? valueRange }

    /// `resolvedYDomain` floored at (or below) 0 in bar mode so bar length stays proportional to value (see `.chartYScale` in `body`). Line mode is unaffected.
    var plotYDomain: ClosedRange<Double> {
        if let step = yAxisStep, step > 0 {
            return 0...max(step, ceil((points.map(\.value).max() ?? 0) / step) * step)
        }
        return showsBars ? min(0, resolvedYDomain.lowerBound)...resolvedYDomain.upperBound : resolvedYDomain
    }

    public var body: some View {
        // Resolve against current data so the marker and readout never refer to a removed date.
        let currentSelection = selectedPoint.flatMap { selected in points.first { $0.date == selected.date } }
        // All marks share these styles, resolved once per update rather than per vertex.
        let stops = gradient.toStops()
        let areaFill = LinearGradient(
            colors: [StrandPalette.sample(stops: stops, at: unit(averageValue)).opacity(0.28), .clear],
            startPoint: .top, endPoint: .bottom)
        let lineStroke = valueGradient
        VStack(alignment: .leading, spacing: 8) {
        if largeSelection {
            let point = currentSelection ?? points.last
            VStack(alignment: .leading, spacing: 3) {
                Text(point.map { dateFormat($0.date) } ?? "—").font(.headline)
                Text(point.map { valueFormat($0.value) } ?? "—").font(.title2.bold()).monospacedDigit()
            }
            .foregroundStyle(StrandPalette.textPrimary)
        }
        Chart {
            if let baselineValue {
                RuleMark(y: .value("Baseline", baselineValue))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            if showsBars {
                // Bar mode: one value-ramp-filled BarMark per down-sampled sample from the baseline, replacing line, area and points. The same `displayPoints` feed it;
                // hover, axes, domain and accessibility read the full `points`.
                ForEach(displayPoints) { p in
                    BarMark(
                        x: .value("Date", p.date),
                        y: .value("Value", p.value)
                    )
                    .foregroundStyle(lineStroke)
                    .cornerRadius(min(2, max(0, CGFloat(p.value / max(1, plotYDomain.upperBound)) * height * 0.2)))
                    .opacity(holdingBar && currentSelection != nil && currentSelection?.date != p.date ? 0.3 : 1)
                    .annotation(position: .top, spacing: 3) {
                        if showsBarValues {
                            Text(p.value.formatted(.number.precision(.fractionLength(0))))
                                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                if showsHover, let selectedPoint = currentSelection {
                    RuleMark(x: .value("Date", selectedPoint.date))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else {
                if showsArea {
                    ForEach(displayPoints) { p in
                        AreaMark(
                            x: .value("Date", p.date),
                            y: .value("Value", p.value),
                            series: .value("Segment", p.segment)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(areaFill)
                    }
                }
                ForEach(displayPoints) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Value", p.value),
                        series: .value("Segment", p.segment)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(lineStroke)
                }
                // 18pt dots are invisible on dense series but still cost a mark each, so hide them past a threshold. The gate stays on the full `points.count` (≤60 is never downsampled).
                if points.count <= 60 {
                    ForEach(displayPoints) { p in
                        PointMark(
                            x: .value("Date", p.date),
                            y: .value("Value", p.value)
                        )
                        .symbolSize(18)
                        .foregroundStyle(StrandPalette.sample(stops: stops, at: unit(p.value)))
                    }
                }
            }
        }
        // Domain drives BOTH axis extent and plot clip. A `yDomain` with headroom above the data keeps a peak and the top label clear of the clip (#974); the gradient still keys off `valueRange`.
        // Bars need a zero baseline to be truthful, but the LINE uses a data-fitted domain (e.g. RHR ~48…61) that would float every bar near full height,
        // so bar mode drops the floor to 0 (or below for negatives). The upper bound is unchanged.
        .chartYScale(domain: plotYDomain)
        // Clip the plot to its bounds: catmullRom overshoots on sharp turns and the AreaMark gradient is drawn unclipped, so a spiky HR fill bled down the page behind the cards.
        .chartPlotStyle { plotArea in
            if showsBarValues { plotArea.padding(.top, 18) } else { plotArea.clipped() }
        }
        // Marks are pinned to WHOLE DAYS, not requested by count: `.automatic(desiredCount:)` may pick a sub-day stride, putting several marks in one calendar day so the axis prints "Sep 21" twice.
        // Explicit distinct start-of-day instants make duplicates impossible, and the day-only format keeps a time from printing.
        .chartXAxis {
            AxisMarks(values: axisDays) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel(format: ChartAxisDays.labelFormat(for: axisDays))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .modifier(WorkoutTimeAxisModifier(workoutTimeAxis))
        .chartYAxis {
            if let step = yAxisStep, step > 0 {
                AxisMarks(position: .leading, values: Array(stride(from: 0.0, through: plotYDomain.upperBound, by: step))) { value in
                    if let number = value.as(Double.self), number > 0, number < plotYDomain.upperBound {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .foregroundStyle(StrandPalette.textSecondary.opacity(0.45))
                    }
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(TrendChart.axisNumberLabel(number))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
            } else {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    if showsHover,
                       let hx = hoverX,
                       let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
                       let px = proxy.position(forX: p.date),
                       let py = proxy.position(forY: p.value) {
                        let cx = px + plot.minX
                        let cy = py + plot.minY
                        let color = StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value))

                        // Vertical crosshair at the nearest x.
                        CrosshairRule(x: cx, height: geo.size.height)

                        // Highlighted dot on the line.
                        HighlightDot(color: color)
                            .position(x: cx, y: cy)

                        // Tooltip near the point, kept in bounds.
                        if showsTooltip {
                            PositionedTooltip(
                                anchor: CGPoint(x: cx, y: cy),
                                container: geo.size,
                                tooltip: ChartTooltip(
                                    value: valueFormat(p.value),
                                    label: dateFormat(p.date),
                                    accent: color
                                )
                            )
                        }
                    }

                    // "Now" end-cap on the latest point (#458), positioned with the same proxy mapping as the line so it lands on the curve (a sibling overlay guessing axis insets floated off it).
                    if !showsBars, let capColor = nowCapColor, let last = points.last,
                       let px = proxy.position(forX: last.date),
                       let py = proxy.position(forY: last.value) {
                        NowCapDot(color: capColor)
                            .position(x: px + plot.minX, y: py + plot.minY)
                            .allowsHitTesting(false)
                    }
                }
                // Fade the readout in and out only; while scrubbing it tracks the finger with no easing.
                .animation(StrandMotion.fade, value: hoverX == nil)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                #if os(macOS)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard showsHover, showsBars else { return }
                        let x = min(max(value.location.x, plot.minX), plot.maxX)
                        selectedPoint = nearestPoint(toX: x, proxy: proxy, plot: plot)
                        holdingBar = true
                        hoverX = largeSelection ? nil : x
                    }
                    .onEnded { _ in holdingBar = false; hoverX = nil },
                    including: showsHover && showsBars ? .all : .none)
                #else
                // Touch scrub for lines and bars alike (the shared mechanism): a sideways drag or a short
                // hold engages it, a vertical drag still scrolls the page.
                .zoopChartScrub(isEnabled: showsHover, onChange: { location in
                    let x = min(max(location.x, plot.minX), plot.maxX)
                    selectedPoint = nearestPoint(toX: x, proxy: proxy, plot: plot)
                    holdingBar = showsBars
                    hoverX = largeSelection ? nil : x
                    onSelectionChange?(selectedPoint)
                }, onEnd: {
                    holdingBar = false
                    hoverX = nil
                    onSelectionChange?(nil)
                })
                #endif
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    // Update hover in a NON-animating transaction: entering or leaving flips hoverX inside an animated context and Charts re-runs the line's draw-on animation, flickering the curve (#104).
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
            }
        }
        .frame(height: height)
        // No outer `.clipped()`: the plot is already clipped by `.chartPlotStyle`, and clipping the whole chart cropped the axis-label gutter (top y value, first/last x labels) (#1019).
        // Collapse the marks into ONE VoiceOver element with series context. The decorative under-glow copy (showsHover:false, no label) is hidden so the series isn't announced twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel.map(Text.init) ?? Text("Trend", bundle: .module))
        .accessibilityValue(Text(a11ySummary))
        .accessibilityHidden(!showsHover && accessibilityLabel == nil)
        }
        .onChange(of: points.map(\.date)) { _ in
            selectedPoint = nil
            holdingBar = false
            hoverX = nil
            onSelectionChange?(nil)
        }
    }
}

// MARK: - Chart downsampling (pure)
// Reduces a dense series to ~the plot's pixel width BEFORE it reaches Charts. Min/max per bucket keeps every visible peak and trough; first and last points are always kept.

public enum ChartDownsample {
    /// Above this many points we downsample; at or below, the series passes through untouched (7/30/90-day trends and ≤60-point dotted series).
    public static let markThreshold = 120
    /// Target drawn-vertex budget — a touch above a typical ~360pt plot so the line stays crisp.
    public static let targetVertices = 400

    /// Min/max-bucketed copy of `points` when it exceeds `threshold`, else `points` unchanged.
    /// Assumes `points` is already sorted by date (both chart callers sort in their init).
    public static func minMaxBucketed(_ points: [TrendPoint], threshold: Int, targetCount: Int) -> [TrendPoint] {
        minMaxBucketed(points, threshold: threshold, targetCount: targetCount,
                       date: { $0.date }, value: { $0.value })
    }

    /// Generic form keyed by caller-supplied `date`/`value` accessors, so chart types outside this package share the one implementation.
    /// Pure and deterministic; identical to the `TrendPoint` overload when the accessors project the same fields.
    public static func minMaxBucketed<Point>(
        _ points: [Point],
        threshold: Int,
        targetCount: Int,
        date: (Point) -> Date,
        value: (Point) -> Double
    ) -> [Point] {
        let n = points.count
        guard n > threshold, n > 2, targetCount >= 4 else { return points }

        // Reserve first and last; bucket the interior. Each bucket yields up to 2 vertices (min+max), so use ~targetCount/2 buckets.
        let first = points[0]
        let last = points[n - 1]
        let interior = n - 2
        let bucketCount = max(1, (targetCount - 2) / 2)
        guard bucketCount < interior else { return points }

        var out: [Point] = []
        out.reserveCapacity(targetCount)
        out.append(first)

        var lastEmittedDate = date(first)
        for b in 0..<bucketCount {
            // Interior indices [1 ... n-2] split into `bucketCount` contiguous ranges.
            let lo = 1 + (b * interior) / bucketCount
            let hi = 1 + ((b + 1) * interior) / bucketCount // exclusive
            guard lo < hi else { continue }

            var minIdx = lo, maxIdx = lo
            var i = lo + 1
            while i < hi {
                if value(points[i]) < value(points[minIdx]) { minIdx = i }
                if value(points[i]) > value(points[maxIdx]) { maxIdx = i }
                i += 1
            }

            // Emit the two extremes in chronological order, skipping duplicates (monotone bucket → one
            // point) and any whose date would not advance (keeps `id: Date` unique for ForEach).
            let lowFirst = minIdx <= maxIdx
            let aIdx = lowFirst ? minIdx : maxIdx
            let bIdx = lowFirst ? maxIdx : minIdx
            for idx in [aIdx, bIdx] {
                let p = points[idx]
                let d = date(p)
                if d > lastEmittedDate {
                    out.append(p)
                    lastEmittedDate = d
                }
            }
        }

        if date(last) > lastEmittedDate { out.append(last) }
        return out
    }
}

// MARK: - Gradient → stops bridge

extension Gradient {
    /// Ordered stops from a Gradient via the public `stops` mirror.
    func toStops() -> [Gradient.Stop] {
        self.stops
    }
}

#if DEBUG
private func sampleTrend(days: Int, base: Double, swing: Double) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<days).map { i in
        let date = cal.date(byAdding: .day, value: -(days - 1 - i), to: today)!
        let v = base + swing * sin(Double(i) / 3.0) + Double((i * 17) % 9) - 4
        return TrendPoint(date: date, value: max(0, v))
    }
}

#Preview("TrendChart — recovery") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — 30 days").strandOverline()
        Text("Hover the line: crosshair + dot + date/value tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(points: sampleTrend(days: 30, base: 62, swing: 22))
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("TrendChart — HRV") {
    VStack(alignment: .leading, spacing: 12) {
        Text("HRV (ms) — 30 days").strandOverline()
        Text("Hover to read each day's HRV in ms.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(
            points: sampleTrend(days: 30, base: 58, swing: 14),
            gradient: StrandPalette.recoveryGradient,
            valueRange: 20...100,
            showsArea: true,
            valueFormat: { "\(Int($0.rounded())) ms" }
        )
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
