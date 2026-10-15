import SwiftUI

// MARK: - MetricHero (screen top)
//
// The full anatomy, largest. Hosted inside a hero card; draws no surface of its own.

public struct MetricHero: View {
    private let readout: MetricReadout
    @Environment(\.locale) private var locale
    /// 56 pt at the default size, scaled with the user's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var unitSize: CGFloat = 22

    private let showsInfo: Bool
    private let compact: Bool

    /// `compact` for small containers (rings, narrow cards): the empty state uses its short wording.
    public init(_ readout: MetricReadout, compact: Bool = false) {
        self.init(readout, showsInfo: true, compact: compact)
    }

    /// The explainer reuses the hero without the info affordance it was opened from.
    init(_ readout: MetricReadout, showsInfo: Bool, compact: Bool = false) {
        self.readout = readout
        self.showsInfo = showsInfo
        self.compact = compact
    }

    public var body: some View {
        let p = MetricPresentation(readout, locale: locale)
        VStack(alignment: .leading, spacing: 12) {
            header(p)
            if p.number != nil {
                VStack(alignment: .leading, spacing: 4) {
                    MetricValueText(presentation: p,
                                    numberFont: StrandFont.display(numberSize),
                                    unitFont: StrandFont.number(unitSize, weight: .medium),
                                    color: MetricStyle.valueColor(readout))
                    MetricDeltaText(presentation: p)
                }
                range(p)
                MetricVerdictText(readout: readout, presentation: p)
            } else {
                // The reason takes the number's place: a dash is never a valid state.
                MetricVerdictText(readout: readout, presentation: p, font: StrandFont.title2, compact: compact)
            }
            Text(verbatim: p.meaning)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricAccessibility(p)
    }

    private func header(_ p: MetricPresentation) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: p.label)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            if showsInfo {
                Image(systemName: "info.circle")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func range(_ p: MetricPresentation) -> some View {
        if readout.typicalRange != nil {
            VStack(alignment: .leading, spacing: 6) {
                MetricRangeBar(readout)
                if let range = p.range {
                    Text(verbatim: range)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
