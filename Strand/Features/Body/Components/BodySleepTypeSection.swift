#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Sleep type summary (Insights tab)
//
// One row: the sleep type, the workday vs free-day shift and the habitual mid-sleep. It renders the
// same `SleepChronotypeContent` as the Sleep screen's card, so the two cannot disagree, and pushes to
// Sleep for the full card and its explainer.

struct BodySleepTypeSection: View {
    let content: SleepChronotypeContent?
    /// Off inside the Insights "Sleep" section, which carries its own header.
    var showsTitle = true

    var body: some View {
        if let content {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                if showsTitle { BodySectionTitle(title: SleepChronotypeStrings.title) }
                ListCard {
                    NavigationLink(value: TabRoute.sleep) { BodySleepTypeRow(content: content) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct BodySleepTypeRow: View {
    let content: SleepChronotypeContent

    var body: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.m) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(content.typeName).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(content.shiftSentence)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(content.sample)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZoopSpacing.s)
            VStack(alignment: .trailing, spacing: ZoopSpacing.xs) {
                Text(verbatim: content.rows.first?.value ?? content.typeMidSleep)
                    .font(ZoopType.headline.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(SleepChronotypeStrings.midSleep)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            BodyChevron()
        }
        .contentShape(Rectangle())
        .listCardRow(isFirst: true)
        .accessibilityElement(children: .combine)
    }
}
#endif
