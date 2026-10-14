#if os(iOS)
import SwiftUI
import Charts
import StrandDesign

/// Plan name, split and eating window, with the "Change" affordance.
struct FastingPlanCard: View {
    let summary: FastingPlanSummary
    let onChange: () -> Void

    var body: some View {
        Button(action: onChange) {
            ContentCard("zoop.fasting.plan.title", showsChevron: true) {
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                    Text(summary.name).font(ZoopType.metric).foregroundStyle(StrandPalette.textPrimary)
                    Text(summary.split).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                    if let window = summary.window {
                        Text(window).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Seven bars of fasted hours against the plan goal (dashed rule), with a one-line takeaway.
struct FastingWeekCard: View {
    let week: FastingWeek

    var body: some View {
        ContentCard("zoop.fasting.week.title") {
            Chart {
                ForEach(week.bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Hours", bar.hours))
                        .foregroundStyle(bar.met ? StrandPalette.metricCyan
                                         : StrandPalette.metricCyan.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                RuleMark(y: .value("Goal", week.goalHours)).zoopReferenceRule()
            }
            .chartYScale(domain: 0...max(24, week.bars.map(\.hours).max() ?? 0))
            .zoopDayXAxis(days: 7)
            .zoopYAxis { FastingFormat.axisHours($0) }
            .frame(height: 160)
            .accessibilityLabel(Text(week.takeaway))
            Text(week.takeaway).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Streak and 30-day consistency, two tiles.
struct FastingStatsGrid: View {
    let streak: LocalizedStringResource
    let consistency: LocalizedStringResource

    var body: some View {
        TileGrid {
            tile(FastingStrings.streakLabel, streak)
            tile(FastingStrings.consistencyLabel, consistency)
        }
    }

    private func tile(_ label: LocalizedStringResource, _ value: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
        }
        .zoopTileSurface()
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

/// Finished fasts, newest first. A row opens the edit sheet.
struct FastingHistoryCard: View {
    let items: [FastingHistoryItem]
    let onSelect: (FastingHistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(FastingStrings.historyTitle).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.duration).font(ZoopType.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: item.when).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: ZoopSpacing.s)
            Text(item.goalMet ? FastingStrings.goalReached : item.goal)
                .font(ZoopType.caption)
                .foregroundStyle(item.goalMet ? StrandPalette.metricCyan : StrandPalette.textTertiary)
            Image(systemName: "chevron.right").font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
