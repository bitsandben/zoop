#if os(iOS)
import SwiftUI
import MapKit
import StrandDesign

// MARK: - Coloured route: full-screen map and split table
//
// The full-screen cover the route card opens: the same coloured route on an interactive map, a standard /
// satellite switch, and the metric switch with its legend in a panel at the bottom. Plus the split table
// card shown under the route card.

struct WorkoutRouteFullScreen: View {
    let insights: WorkoutRouteInsights
    @Binding var metric: WorkoutRouteInsights.Metric

    @Environment(\.dismiss) private var dismiss
    @State private var satellite = false

    var body: some View {
        WorkoutRouteColorMap(insights: insights, metric: metric, interactive: true, satellite: satellite)
            .ignoresSafeArea()
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottom) { panel }
    }

    private var topBar: some View {
        HStack(spacing: ZoopSpacing.m) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(StrandPalette.surfaceOverlay))
            }
            .accessibilityLabel(RouteStrings.close)
            Spacer()
            Picker(RouteStrings.mapStandard, selection: $satellite) {
                Text(RouteStrings.mapStandard).tag(false)
                Text(RouteStrings.mapSatellite).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .padding(ZoopSpacing.xs)
            .background(Capsule().fill(StrandPalette.surfaceOverlay))
        }
        .padding(.horizontal, ZoopSpacing.gutter)
        .padding(.top, ZoopSpacing.s)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            if insights.metrics.count > 1 { RouteMetricPicker(insights: insights, metric: $metric) }
            if let layer = insights.layers[metric] { RouteLegend(layer: layer) }
        }
        .padding(ZoopSpacing.cardPadding)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous).fill(StrandPalette.surfaceRaised))
        .padding(.horizontal, ZoopSpacing.gutter)
        .padding(.bottom, ZoopSpacing.s)
    }
}

/// Per-kilometre (or mile) table: split, moving time, pace or speed, average heart rate and climb.
struct RouteSplitsCard: View {
    let insights: WorkoutRouteInsights

    private var paceHeader: String {
        insights.usesPace ? RouteStrings.pace + " /" + insights.distanceUnit
            : (insights.system == .imperial ? "mph" : "km/h")
    }
    private var climbHeader: String {
        RouteStrings.splitClimb + (insights.system == .imperial ? " ft" : " m")
    }

    var body: some View {
        ContentCard(LocalizedStringKey(RouteStrings.splitsTitle)) {
            Grid(alignment: .trailing, horizontalSpacing: ZoopSpacing.s, verticalSpacing: ZoopSpacing.s) {
                GridRow {
                    Text(insights.distanceUnit).gridColumnAlignment(.leading)
                    Text(RouteStrings.splitTime)
                    Text(paceHeader)
                    Text(RouteStrings.splitHR)
                    Text(climbHeader)
                }
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                ForEach(insights.splits) { line in
                    Divider().overlay(StrandPalette.hairline)
                    GridRow {
                        Text(line.label).foregroundStyle(StrandPalette.textSecondary)
                        Text(line.time)
                        Text(line.pace).foregroundStyle(StrandPalette.textPrimary).fontWeight(.semibold)
                        Text(line.heartRate)
                        Text(line.climb)
                    }
                    .font(ZoopType.body.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
