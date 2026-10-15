#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Finding explainer
//
// The same section order as `MetricExplainerSheet` (CONCEPT §1.1): the finding itself, then what it
// is, how it is computed, which data went in and how sure it is, with the chart where one exists.

struct BodyFindingSheet: View {
    let finding: BodyFinding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.xl) {
                    head
                    if let visual = finding.visual {
                        BodyFindingChart(visual: visual)
                            .frame(height: 180)
                            .accessibilityLabel(Text(finding.meaning))
                    }
                    section(BodyStrings.sheetWhatItIs) { paragraph(finding.explanation.whatItIs) }
                    section(BodyStrings.sheetMethod) { method }
                    section(BodyStrings.sheetDataUsed) { paragraph(finding.explanation.dataUsed) }
                    section(BodyStrings.sheetConfidence) { confidence }
                }
                .padding(ZoopSpacing.l)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text(finding.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(BodyStrings.done) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                Text(verbatim: finding.value)
                    .font(ZoopType.display)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                BodyVerdictText(verdict: finding.verdict)
            }
            (Text(finding.comparison) + Text(verbatim: " · ") + Text(finding.sample))
                .font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(finding.meaning)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var method: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(finding.explanation.methodName)
                .font(ZoopType.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            paragraph(finding.explanation.methodSummary)
            if let citation = finding.explanation.citation {
                Text(verbatim: citation).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var confidence: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(finding.explanation.confidence == .solid ? BodyStrings.confidenceSolid : BodyStrings.confidenceBuilding)
                .font(ZoopType.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            paragraph(finding.explanation.confidenceReason)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringResource,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func paragraph(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(ZoopType.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
