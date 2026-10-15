#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Insight tiles and rows
//
// A tile leads with a small chart, then the number, its verdict word (polarity-coloured) and one short
// line saying what the number is measured against. The full sentence, the sample and the method sit
// in the explainer behind the tap. Tiles are laid out two-up by `BodyInsightGrid`; the row is the
// compact form for the logbook habits.

struct BodyInsightGrid: View {
    let findings: [BodyFinding]
    let onSelect: (BodyFinding) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: ZoopSpacing.cardGap) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: ZoopSpacing.cardGap) {
                    ForEach(row) { BodyInsightTile(finding: $0, onSelect: onSelect) }
                }
                // Both tiles of a row take the taller one's height.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Pairs, one per row at accessibility sizes; an odd last tile spans the width.
    private var rows: [[BodyFinding]] {
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        return stride(from: 0, to: findings.count, by: perRow).map {
            Array(findings[$0..<min($0 + perRow, findings.count)])
        }
    }
}

struct BodyInsightTile: View {
    let finding: BodyFinding
    let onSelect: (BodyFinding) -> Void

    var body: some View {
        Button { onSelect(finding) } label: {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.xs) {
                    Text(finding.title)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    BodyChevron()
                }
                if let visual = finding.visual {
                    BodyMiniChart(visual: visual)
                        .frame(height: 44)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: finding.value)
                        .font(ZoopType.metric)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    BodyVerdictText(verdict: finding.verdict, alignment: .leading)
                }
                Text(finding.comparison)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .zoopTileSurface()
            .contentShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
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
                    Text(finding.comparison)
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
    var alignment: TextAlignment = .trailing

    var body: some View {
        Text(verdict.text)
            .font(ZoopType.caption.weight(.semibold))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
    }

    /// Verdict text tokens (AA on the card surface), as on the metric tiles.
    private var color: Color {
        verdict.needsAttention ? StrandPalette.textWarning
            : verdict.isGood ? StrandPalette.textPositive : StrandPalette.textSecondary
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
