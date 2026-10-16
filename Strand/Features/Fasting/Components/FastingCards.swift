#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// Plan name, split and when fasts start; the whole card opens the schedule editor.
struct FastingScheduleCard: View {
    let summary: FastingScheduleSummary
    let onChange: () -> Void

    var body: some View {
        Button(action: onChange) {
            ContentCard("zoop.fasting.schedule.title", showsChevron: true) {
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                    Text(summary.name).font(ZoopType.metric).foregroundStyle(StrandPalette.textPrimary)
                    Text(summary.split).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                    Text(summary.timing).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Seven 24-hour bars, one per day: fasting pieces in cyan, eating windows in amber, with a legend and
/// the goal takeaway under it.
struct FastingTimelineCard: View {
    let week: FastingTimelineWeek
    @ScaledMetric(relativeTo: .footnote) private var barHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .footnote) private var axisHeight: CGFloat = 16

    var body: some View {
        ContentCard("zoop.fasting.week.title") {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                ForEach(week.rows) { row in
                    HStack(spacing: ZoopSpacing.s) {
                        Text(verbatim: row.label).font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: labelWidth, alignment: .leading)
                        bar(row.segments)
                    }
                }
                axis
                legend
                Text(week.takeaway).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(week.takeaway))
        }
    }

    private func bar(_ segments: [FastingTimelineSegment]) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    let width = max(2, geo.size.width * (s.endFraction - s.startFraction))
                    Capsule()
                        .fill(color(s.kind).opacity(s.isLive ? 0.6 : 1))
                        .frame(width: width)
                        .offset(x: geo.size.width * s.startFraction)
                }
            }
        }
        .frame(height: barHeight)
    }

    /// Clock labels under the bars at 0, 6, 12 and 18 h, aligned to the bar's quarters.
    private var axis: some View {
        HStack(spacing: ZoopSpacing.s) {
            Color.clear.frame(width: labelWidth, height: 1)
            GeometryReader { geo in
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(verbatim: FastingFormat.minuteOfDay(h * 60)).font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .offset(x: geo.size.width * Double(h) / 24)
                }
            }
            .frame(height: axisHeight)
        }
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: ZoopSpacing.l) {
            key(StrandPalette.metricCyan, FastingStrings.legendFasting)
            key(StrandPalette.metricAmber, FastingStrings.legendEating)
        }
    }

    private func key(_ color: Color, _ label: LocalizedStringResource) -> some View {
        HStack(spacing: ZoopSpacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func color(_ kind: FastingSegmentKind) -> Color {
        kind == .fasting ? StrandPalette.metricCyan : StrandPalette.metricAmber
    }
}

/// Average fast, longest, streak and plan adherence over the last 30 days.
struct FastingStatsGrid: View {
    let stats: FastingStatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader("zoop.fasting.stats.title")
            switch stats {
            case .empty:
                ContentCard {
                    Text(FastingStrings.statsEmpty).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                }
            case .tiles(let tiles):
                TileGrid {
                    ForEach(tiles) { tile($0) }
                }
            }
        }
    }

    private func tile(_ t: FastingStatsModel.Tile) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(t.label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: t.value).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
            if let note = t.note {
                Text(note).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoopTileSurface()
        .accessibilityElement(children: .combine)
    }
}
#endif
