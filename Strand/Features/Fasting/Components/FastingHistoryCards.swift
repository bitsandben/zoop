#if os(iOS)
import SwiftUI
import StrandDesign

/// Fasts and eating windows, newest first. A row opens the matching edit sheet.
struct FastingHistoryCard: View {
    let items: [FastingHistoryItem]
    let onSelect: (FastingHistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader("zoop.fasting.history.title")
            if items.isEmpty {
                ContentCard {
                    Text(FastingStrings.historyEmpty).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                }
            } else {
                ListCard {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { onSelect(item) } label: { row(item) }
                            .buttonStyle(.plain)
                            .listCardRow(isFirst: index == 0)
                    }
                }
            }
        }
    }

    private func row(_ item: FastingHistoryItem) -> some View {
        HStack(spacing: ZoopSpacing.m) {
            Circle()
                .fill(item.isWindow ? StrandPalette.metricAmber : StrandPalette.metricCyan)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ZoopSpacing.xs) {
                    Text(item.title).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                    Text(verbatim: item.duration).font(ZoopType.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(verbatim: item.when).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: ZoopSpacing.s)
            if let goal = item.goal {
                Text(goal).font(ZoopType.caption)
                    .foregroundStyle(item.goalMet ? StrandPalette.metricCyan : StrandPalette.textTertiary)
            }
            Image(systemName: "chevron.right").font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Overnight values on fasting vs. other nights, always with n, or an honest "not enough data".
struct FastingPatternsCard: View {
    let patterns: FastingPatterns

    var body: some View {
        ContentCard("zoop.fasting.patterns.title") {
            switch patterns {
            case .notEnough(let line):
                Text(line).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            case .rows(let rows):
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                            Text(row.result).font(ZoopType.caption).foregroundStyle(StrandPalette.textPrimary)
                            Text(row.sample).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        .listCardRow(isFirst: index == 0)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(FastingStrings.patternsNote).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

/// The one-line "what the strap can't measure" footnote; ⓘ opens the about sheet.
struct FastingFootnote: View {
    let onInfo: () -> Void

    var body: some View {
        Button(action: onInfo) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                Text(FastingStrings.footnote).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "info.circle").accessibilityHidden(true)
            }
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ZoopSpacing.xs)
    }
}
#endif
