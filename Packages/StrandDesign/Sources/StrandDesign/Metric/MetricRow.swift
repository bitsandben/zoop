import SwiftUI

// MARK: - MetricRow (list)
//
// One list-card line: label and verdict left, value and delta right, chevron to the explainer.
// At accessibility text sizes the two sides stack so nothing truncates.

public struct MetricRow: View {
    private let readout: MetricReadout
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ readout: MetricReadout) {
        self.readout = readout
    }

    public var body: some View {
        let p = MetricPresentation(readout, locale: locale)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        HStack(spacing: 8) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: p.label)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    MetricVerdictText(readout: readout, presentation: p, font: StrandFont.subhead)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                trailing(p)
            }
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .metricAccessibility(p)
    }

    @ViewBuilder
    private func trailing(_ p: MetricPresentation) -> some View {
        if p.number != nil {
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                MetricValueText(presentation: p,
                                numberFont: StrandFont.bodyNumber.weight(.semibold),
                                unitFont: StrandFont.captionNumber,
                                color: MetricStyle.valueColor(readout))
                MetricDeltaText(presentation: p)
            }
        }
    }
}
