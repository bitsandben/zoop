import SwiftUI

// MARK: - MetricExplainerSheet (tap target of every Metric* view)
//
// The readout's own anatomy sits on top, then the fixed explainer sections.

public struct MetricExplainerSheet: View {
    private let readout: MetricReadout
    private let explanation: MetricExplanation
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    public init(_ readout: MetricReadout, explanation: MetricExplanation) {
        self.readout = readout
        self.explanation = explanation
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MetricHero(readout, showsInfo: false)
                    section(MetricStrings.whatItIs) { paragraph(explanation.whatItIs) }
                    section(MetricStrings.method) { method }
                    section(MetricStrings.dataUsed) {
                        Text(verbatim: explanation.dataUsed.summary(locale: locale)).explainerBody()
                    }
                    section(MetricStrings.confidence) { confidence }
                    if !explanation.trend.isEmpty {
                        section(MetricStrings.trend) { MetricTrendChart(readout: readout, points: explanation.trend) }
                    }
                    if !explanation.contributors.isEmpty {
                        section(MetricStrings.contributors) { contributors }
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text(readout.label))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(MetricStrings.done) }
                }
            }
        }
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(explanation.method.name)
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            paragraph(explanation.method.summary)
            if let citation = explanation.method.citation {
                Text(verbatim: citation)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var confidence: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MetricPresentation.confidenceTitle(readout.confidence))
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            if let note = MetricPresentation.note(for: readout), case .calibrating = readout.confidence {
                paragraph(note)
            }
            if let reason = explanation.confidenceReason { paragraph(reason) }
        }
    }

    private var contributors: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(explanation.contributors) { contributor in
                ContributorRow(contributor: contributor)
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringResource,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func paragraph(_ text: LocalizedStringResource) -> some View {
        Text(text).explainerBody()
    }
}

private struct ContributorRow: View {
    let contributor: MetricExplanation.Contributor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityLabel(effectLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(contributor.label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = contributor.detail { Text(detail).explainerBody() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch contributor.effect {
        case .raises: return "arrow.up"
        case .lowers: return "arrow.down"
        case .neutral: return "minus"
        }
    }

    private var effectLabel: Text {
        switch contributor.effect {
        case .raises: return Text(MetricStrings.raises)
        case .lowers: return Text(MetricStrings.lowers)
        case .neutral: return Text(verbatim: "")
        }
    }
}

private extension Text {
    func explainerBody() -> some View {
        self.font(StrandFont.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
