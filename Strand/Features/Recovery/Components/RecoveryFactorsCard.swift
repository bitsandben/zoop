import SwiftUI
import StrandDesign

/// "What set your recovery today": the ranked factors, one sentence each, then one thing that helps
/// and a way into the coach for the rest. The coach's own suggestions are not repeated here.
struct RecoveryFactorsCard: View {
    let content: RecoveryFactorsContent
    #if os(iOS)
    @State private var showsCoach = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(RecoveryStrings.factorsTitle, subtitle: RecoveryStrings.factorsNote)
                .padding(.top, ZoopSpacing.s)
            ListCard {
                if content.items.isEmpty {
                    sentence(RecoveryStrings.factorsNone).listCardRow(isFirst: true)
                }
                ForEach(Array(content.items.enumerated()), id: \.element.id) { index, item in
                    row(item).listCardRow(isFirst: index == 0)
                }
                if let advice = content.advice {
                    helps(advice).listCardRow(isFirst: content.items.isEmpty)
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showsCoach) {
            CoachBriefSheet().presentationDetents([.medium, .large])
        }
        #endif
    }

    private func row(_ item: RecoveryFactorItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
            icon(item.effect)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            sentence(item.sentence)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func icon(_ effect: MetricExplanation.Contributor.Effect) -> some View {
        switch effect {
        case .lowers: Image(systemName: "arrow.down").accessibilityLabel(Text(RecoveryStrings.factorLowers))
        case .raises: Image(systemName: "arrow.up").accessibilityLabel(Text(RecoveryStrings.factorRaises))
        case .neutral: Image(systemName: "minus").accessibilityHidden(true)
        }
    }

    private func sentence(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(ZoopType.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func helps(_ advice: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(RecoveryStrings.helpsTitle)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(advice)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Button { showsCoach = true } label: {
                HStack(spacing: ZoopSpacing.xs) {
                    Text(RecoveryStrings.helpsCoach)
                    Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
                }
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #endif
        }
    }
}
