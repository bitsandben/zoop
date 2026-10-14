#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Finding card and row
//
// The card leads with the interpretation sentence; the number, what it is compared with, the verdict
// and the sample sit under it. The row is the compact form for lists of patterns. Both open the
// explainer sheet.

struct BodyFindingCard: View {
    let finding: BodyFinding
    let onSelect: (BodyFinding) -> Void

    var body: some View {
        Button { onSelect(finding) } label: {
            ContentCard {
                VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                        Text(finding.title).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: ZoopSpacing.s)
                        BodyVerdictText(verdict: finding.verdict)
                        BodyChevron()
                    }
                    Text(finding.meaning)
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                        Text(verbatim: finding.value)
                            .font(ZoopType.metric)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(finding.comparison)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(finding.sample).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(BodyStrings.opensExplainer))
    }
}

struct BodyFindingRow: View {
    let finding: BodyFinding
    let isFirst: Bool
    let onSelect: (BodyFinding) -> Void

    var body: some View {
        Button { onSelect(finding) } label: {
            HStack(alignment: .top, spacing: ZoopSpacing.m) {
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                    Text(finding.title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(finding.meaning)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // What the number on the right is measured against, so it is never a bare figure.
                    (Text(finding.comparison) + Text(verbatim: " · ") + Text(finding.sample))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ZoopSpacing.s)
                VStack(alignment: .trailing, spacing: ZoopSpacing.xs) {
                    Text(verbatim: finding.value)
                        .font(ZoopType.headline.monospacedDigit())
                        .foregroundStyle(finding.verdict == .noClearDifference
                                         ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    BodyVerdictText(verdict: finding.verdict)
                }
                BodyChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listCardRow(isFirst: isFirst)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(BodyStrings.opensExplainer))
    }
}

struct BodyVerdictText: View {
    let verdict: BodyVerdict
    var body: some View {
        Text(verdict.text)
            .font(ZoopType.caption.weight(.semibold))
            .foregroundStyle(verdict.needsAttention ? StrandPalette.statusWarning : StrandPalette.textSecondary)
            .multilineTextAlignment(.trailing)
    }
}

struct BodyChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
    }
}

/// Section label above a card (§2.4: one component, no overline caps), with an optional one-line note.
struct BodySectionTitle: View {
    let title: LocalizedStringResource
    var note: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, ZoopSpacing.xs)
    }
}
#endif
