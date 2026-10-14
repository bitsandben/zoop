#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

// MARK: - Vitals (five metric tiles with a 30-day sparkline)

/// The vitals section with its own loading, for pages that show only the vitals (iOS Health monitor).
struct BodyVitalsBlock: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = BodyModel()
    @State private var selected: BodyVital?

    var body: some View {
        BodyVitalsSection(vitals: model.vitals) { selected = $0 }
            .task(id: repo.refreshSeq) { await model.loadVitals(repo: repo) }
            .sheet(item: $selected) { MetricExplainerSheet($0.readout, explanation: $0.metric.explanation) }
    }
}

struct BodyVitalsSection: View {
    let vitals: [BodyVital]
    let onSelect: (BodyVital) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            BodySectionTitle(title: BodyStrings.vitalsTitle, note: BodyStrings.vitalsNote)
            TileGrid {
                ForEach(paired) { vital in tile(vital) }
            }
            // An odd tile spans the width instead of leaving a hole in the grid.
            if let last = single { tile(last) }
        }
    }

    /// Measured vitals first, so a missing one (SpO₂ on a WHOOP 4.0) is the one that spans.
    private var ordered: [BodyVital] { vitals.filter { !$0.isUnavailable } + vitals.filter(\.isUnavailable) }
    private var paired: [BodyVital] { ordered.count % 2 == 0 ? ordered : Array(ordered.dropLast()) }
    private var single: BodyVital? { ordered.count % 2 == 0 ? nil : ordered.last }

    private func tile(_ vital: BodyVital) -> some View {
        Button { onSelect(vital) } label: {
            VStack(spacing: 0) {
                MetricTile(vital.readout)
                if vital.trend.count >= 2 {
                    BodySparkline(points: vital.trend, band: vital.readout.typicalRange,
                                  muted: vital.isUnavailable || vital.readout.isStale)
                        .frame(height: 28)
                        .padding(.horizontal, ZoopSpacing.l)
                        .padding(.bottom, ZoopSpacing.l)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .contentShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Thirty days against the band: no axes, because the tile above it states the value and the range,
/// and the explainer behind the tap draws the labelled chart.
struct BodySparkline: View {
    let points: [MetricExplanation.TrendPoint]
    let band: ClosedRange<Double>?
    let muted: Bool

    var body: some View {
        let tint = muted ? StrandPalette.textTertiary : StrandPalette.textSecondary
        Chart {
            if let band, let first = points.first, let last = points.last {
                ZoopBandMark(x: .value("Day", first.date), low: band.lowerBound, high: band.upperBound, color: tint)
                ZoopBandMark(x: .value("Day", last.date), low: band.lowerBound, high: band.upperBound, color: tint)
            }
            ForEach(points) { p in
                LineMark(x: .value("Day", p.date), y: .value("Value", p.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            if let last = points.last {
                PointMark(x: .value("Day", last.date), y: .value("Value", last.value))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .symbolSize(18)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
#endif
