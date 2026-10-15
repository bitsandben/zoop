#if os(iOS)
import SwiftUI
import MapKit
import StrandDesign
import StrandAnalytics

// MARK: - Coloured route: map
//
// The route as many short polylines, one per colour run of the selected metric, over a casing line so it
// reads on any map tile. Start and finish pins, a numbered marker at each kilometre or mile, and the
// position picked on the chart. Colours are design tokens: the heart-rate zone ramp for pace and zones,
// cyan over amber to rose for elevation, `textTertiary` for pauses. Shared by the card and the full-screen map.

enum RouteColors {

    /// Colour of one run's bucket for a layer; `RouteColoring.noValue` is neutral.
    static func color(bucket: Int, layer: WorkoutRouteInsights.Layer) -> Color {
        guard bucket != RouteColoring.noValue else { return StrandPalette.textTertiary }
        switch layer.scale {
        case .zones:
            let zones = StrandPalette.hrZones
            return zones[min(zones.count - 1, bucket + 1)]
        case .gradient:
            let t = layer.buckets > 1 ? (Double(bucket) + 0.5) / Double(layer.buckets) : 0.5
            return StrandPalette.sample(stops: stops(layer.metric), at: t)
        }
    }

    /// Low-to-high gradient stops for the legend bar and the route.
    static func stops(_ metric: WorkoutRouteInsights.Metric) -> [Gradient.Stop] {
        let colors: [Color]
        switch metric {
        case .pace, .heartRate:
            colors = [StrandPalette.zone1, StrandPalette.zone2, StrandPalette.zone3, StrandPalette.zone4, StrandPalette.zone5]
        case .altitude:
            colors = [StrandPalette.metricCyan, StrandPalette.metricAmber, StrandPalette.metricRose]
        }
        return colors.enumerated().map { i, c in
            Gradient.Stop(color: c, location: colors.count > 1 ? Double(i) / Double(colors.count - 1) : 0)
        }
    }
}

struct WorkoutRouteColorMap: View {
    let insights: WorkoutRouteInsights
    let metric: WorkoutRouteInsights.Metric
    /// The point picked on the chart, drawn as a dot.
    var highlight: CLLocationCoordinate2D?
    var interactive = false
    var satellite = false

    @State private var position: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        insights.display.fixes.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var body: some View {
        let coords = coordinates
        Map(position: $position, interactionModes: interactive ? .all : []) {
            MapPolyline(coordinates: coords)
                .stroke(StrandPalette.surfaceRaised, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            if let layer = insights.layers[metric] {
                ForEach(Array(layer.runs.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: Array(coords[run.first...min(run.last, coords.count - 1)]))
                        .stroke(RouteColors.color(bucket: run.bucket, layer: layer),
                                style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(insights.markers) { m in
                Annotation(m.label, coordinate: CLLocationCoordinate2D(latitude: m.lat, longitude: m.lon)) {
                    Text(m.label)
                        .font(ZoopType.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(ZoopSpacing.xs)
                        .background(Circle().fill(StrandPalette.surfaceOverlay))
                        .overlay(Circle().stroke(StrandPalette.hairlineStrong, lineWidth: 1))
                }
                .annotationTitles(.hidden)
            }
            if let first = coords.first, let last = coords.last {
                Marker(RouteStrings.start, systemImage: "flag", coordinate: first).tint(StrandPalette.statusPositive)
                Marker(RouteStrings.finish, systemImage: "flag.checkered", coordinate: last).tint(StrandPalette.textPrimary)
            }
            if let highlight {
                Annotation("", coordinate: highlight) {
                    Circle()
                        .fill(StrandPalette.textPrimary)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(satellite ? .hybrid(elevation: .flat) : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(interactive ? .automatic : .hidden)
        .onAppear { position = Self.framing(coords) }
    }

    /// The route's bounding rect with a margin, so the line is not flush with the edges.
    static func framing(_ coords: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard !coords.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        let pad = max(rect.width, rect.height) * 0.15 + 200
        return .rect(rect.insetBy(dx: -pad, dy: -pad))
    }
}

/// Low-to-high colour bar with its two end labels, or the five zone swatches for heart rate.
struct RouteLegend: View {
    let layer: WorkoutRouteInsights.Layer

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Group {
                if layer.scale == .zones {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { z in
                            StrandPalette.hrZones[z].overlay(
                                Text("Z\(z)").font(ZoopType.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.surfaceBase))
                        }
                    }
                } else {
                    LinearGradient(stops: RouteColors.stops(layer.metric), startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(height: layer.scale == .zones ? 18 : 8)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            HStack {
                Text(layer.lowLabel)
                Spacer()
                Text(layer.highLabel)
            }
            .font(ZoopType.caption.monospacedDigit())
            .foregroundStyle(StrandPalette.textSecondary)
            Text(layer.caption + " " + RouteStrings.pausedNote)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The metric switch: Pace (or Speed), Heart rate, Elevation, only those the route has data for.
struct RouteMetricPicker: View {
    let insights: WorkoutRouteInsights
    @Binding var metric: WorkoutRouteInsights.Metric

    var body: some View {
        Picker(RouteStrings.title, selection: $metric) {
            ForEach(insights.metrics) { m in Text(label(m)).tag(m) }
        }
        .pickerStyle(.segmented)
    }

    private func label(_ m: WorkoutRouteInsights.Metric) -> String {
        switch m {
        case .pace: return insights.usesPace ? RouteStrings.pace : RouteStrings.speed
        case .heartRate: return RouteStrings.heartRate
        case .altitude: return RouteStrings.altitude
        }
    }
}
#endif
