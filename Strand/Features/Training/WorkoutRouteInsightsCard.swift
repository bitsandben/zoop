#if os(iOS)
import SwiftUI
import Charts
import MapKit
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Coloured route: card
//
// The workout detail's route card when the fixes carry their times: the route coloured by the selected
// metric, its legend, a chart of that metric over distance (drag to find the spot on the map) and the
// split table. Tapping the map opens it full screen. Built off the main actor once per unit system.

struct WorkoutRouteInsightsCard: View {
    let row: WorkoutRow
    let points: [WorkoutRoutePoint]
    let heartRate: [RouteTrack.HeartRate]
    let zones: HRZoneSet
    let system: UnitSystem
    /// Shown while the colour layers build and when the fixes cannot be coloured.
    let fallback: AnyView

    @State private var insights: WorkoutRouteInsights?
    @State private var metric: WorkoutRouteInsights.Metric
    @State private var selection: Double?
    @State private var fullScreen = false

    init(row: WorkoutRow, points: [WorkoutRoutePoint], heartRate: [RouteTrack.HeartRate], zones: HRZoneSet,
         system: UnitSystem, fallback: AnyView, initialMetric: WorkoutRouteInsights.Metric = .pace,
         initialFullScreen: Bool = false) {
        self.row = row
        self.points = points
        self.heartRate = heartRate
        self.zones = zones
        self.system = system
        self.fallback = fallback
        _metric = State(initialValue: initialMetric)
        _fullScreen = State(initialValue: initialFullScreen)
    }

    var body: some View {
        Group {
            if let insights {
                content(insights)
            } else {
                fallback
            }
        }
        .task(id: "\(system.rawValue)|\(heartRate.count)") { await build() }
    }

    private func content(_ insights: WorkoutRouteInsights) -> some View {
        let layerMetric = insights.layers[metric] != nil ? metric : (insights.metrics.first ?? .pace)
        let picked = selection.flatMap { insights.selection(at: $0, metric: layerMetric) }
        return VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
            ContentCard(LocalizedStringKey(RouteStrings.title)) {
                if insights.metrics.count > 1 { RouteMetricPicker(insights: insights, metric: $metric) }
                WorkoutRouteColorMap(insights: insights, metric: layerMetric,
                                     highlight: picked.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { fullScreen = true }
                    .accessibilityLabel(RouteStrings.mapAccessibility(
                        sport: WorkoutSource.displaySport(row.sport),
                        distance: RouteFormat(system: system, onFoot: insights.usesPace).distance(insights.track.totalMeters)))
                    .accessibilityHint(RouteStrings.expand)
                    .accessibilityAddTraits(.isButton)
                if let layer = insights.layers[layerMetric] { RouteLegend(layer: layer) }
                RouteMetricChart(insights: insights, metric: layerMetric, selection: $selection, readout: picked?.text)
            }
            if !insights.splits.isEmpty {
                RouteSplitsCard(insights: insights)
            }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            WorkoutRouteFullScreen(insights: insights, metric: $metric)
        }
    }

    private func build() async {
        let points = points, heartRate = heartRate, zones = zones, system = system
        let onFoot = WorkoutCatalog.isOnFoot(row.sport) || WorkoutCatalog.isOnFoot(WorkoutSource.displaySport(row.sport))
        let result = await Task.detached(priority: .userInitiated) {
            WorkoutRouteInsights.build(points: points, heartRate: heartRate, zones: zones, onFoot: onFoot, system: system)
        }.value
        guard !Task.isCancelled else { return }
        insights = result
        if let result, result.layers[metric] == nil, let first = result.metrics.first { metric = first }
    }
}

// MARK: - Chart

/// The selected metric over distance; dragging picks a distance that the map marks.
struct RouteMetricChart: View {
    let insights: WorkoutRouteInsights
    let metric: WorkoutRouteInsights.Metric
    @Binding var selection: Double?
    let readout: String?

    private var points: [WorkoutRouteInsights.ChartPoint] { insights.chart(metric) }
    private var color: Color {
        switch metric {
        case .pace: return StrandPalette.zone4
        case .heartRate: return StrandPalette.zone5
        case .altitude: return StrandPalette.metricPurple
        }
    }

    var body: some View {
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(readout ?? RouteStrings.scrubHint)
                    .font(ZoopType.caption.monospacedDigit())
                    .foregroundStyle(readout == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                chart.frame(height: 140)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                if let v = p.value {
                    AreaMark(x: .value("Distance", p.distance), yStart: .value("Base", domain.lowerBound), yEnd: .value("Value", v),
                             series: .value("Seg", p.segment))
                        .foregroundStyle(color.opacity(ZoopChartStyle.bandOpacity))
                    LineMark(x: .value("Distance", p.distance), y: .value("Value", v), series: .value("Seg", p.segment))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            if let selection { RuleMark(x: .value("Selected", selection)).zoopScrubRule() }
        }
        .chartYScale(domain: domain)
        .zoopYAxis { yLabel($0) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(ZoopNumber.decimal(d, digits: d < 10 ? 1 : 0) + " " + insights.distanceUnit)
                            .font(ZoopType.caption)
                    }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                            let x = g.location.x - frame.origin.x
                            if let d: Double = proxy.value(atX: x) {
                                selection = min(max(0, d), points.last?.distance ?? d)
                            }
                        })
            }
        }
        .accessibilityLabel(RouteStrings.scrubHint)
    }

    private var domain: ClosedRange<Double> { insights.chartDomain(metric) }

    private func yLabel(_ v: Double) -> String {
        guard metric == .pace, insights.usesPace else { return ZoopNumber.decimal(v, digits: 0) }
        // Pace is plotted negated so faster sits higher.
        return WorkoutSplits.clock(abs(v) * 60) ?? ""
    }
}
#endif
