import SwiftUI

// MARK: - MetricTile (2-up grid)
//
// Label, number, range bar, verdict. The meaning sentence is too long for half a screen width, so the
// tile speaks it as the VoiceOver hint and shows it in the explainer the tap opens.

public struct MetricTile: View {
    private let readout: MetricReadout
    @Environment(\.locale) private var locale
    /// 28 pt at the default size (§7.1 `metric`).
    @ScaledMetric(relativeTo: .title) private var numberSize: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var unitSize: CGFloat = 15

    /// Tile corner radius and padding (§7.2).
    private static let radius: CGFloat = 18
    private static let padding: CGFloat = 16

    public init(_ readout: MetricReadout) {
        self.readout = readout
    }

    public var body: some View {
        let p = MetricPresentation(readout, locale: locale)
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: p.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if p.number != nil {
                MetricValueText(presentation: p,
                                numberFont: StrandFont.number(numberSize),
                                unitFont: StrandFont.number(unitSize, weight: .medium),
                                color: MetricStyle.valueColor(readout))
                MetricRangeBar(readout)
            }
            Spacer(minLength: 0)
            MetricVerdictText(readout: readout, presentation: p, font: StrandFont.subhead.weight(.semibold))
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .metricAccessibility(p)
    }
}
