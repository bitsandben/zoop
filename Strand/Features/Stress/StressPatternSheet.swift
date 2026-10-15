import SwiftUI
import StrandDesign

// MARK: - Pattern explainer
//
// The same order as the metric explainer (CONCEPT §1.1): the reading and its chart, then what it is,
// how it is computed and which data went in, sample sizes included.

struct StressPatternSheet<Chart: View>: View {
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let what: LocalizedStringResource
    let methodName: LocalizedStringResource
    let methodSummary: LocalizedStringResource
    let note: LocalizedStringResource
    let data: LocalizedStringResource
    @ViewBuilder let chart: () -> Chart

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.xl) {
                    VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                        chart().frame(height: 180)
                        Text(summary)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    section(StressPatternStrings.whatItIs) { paragraph(what) }
                    section(StressPatternStrings.method) {
                        Text(methodName)
                            .font(ZoopType.body.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        paragraph(methodSummary)
                        paragraph(note)
                    }
                    section(StressPatternStrings.dataUsed) { paragraph(data) }
                }
                .padding(ZoopSpacing.l)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text(title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(StressStrings.breatheDone) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
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
