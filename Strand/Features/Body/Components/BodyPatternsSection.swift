#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Patterns (habits from the logbook, weekdays, evening stress)

struct BodyPatternsSection: View {
    @ObservedObject var model: BodyModel
    /// The weekday and evening-stress patterns; off on the Insights tab, which files them under Body and Sleep.
    var includesOthers = true
    let onSelect: (BodyFinding) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            BodySectionTitle(title: BodyStrings.patternsTitle, note: BodyStrings.patternsNote)
            habits
            if includesOthers && !model.patterns.others.isEmpty {
                ListCard {
                    ForEach(Array(model.patterns.others.enumerated()), id: \.element.id) { i, f in
                        BodyFindingRow(finding: f, isFirst: i == 0, onSelect: onSelect)
                    }
                }
            }
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                    Text(BodyStrings.needsMoreData)
                        .font(ZoopType.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, ZoopSpacing.xs)
            }
        }
    }

    @ViewBuilder private var habits: some View {
        if !model.patterns.habits.isEmpty || model.habitOutcome != .recovery {
            ContentCard(BodyStrings.habitsCardKey) {
                VStack(alignment: .leading, spacing: 0) {
                    Picker(selection: $model.habitOutcome) {
                        ForEach(BodyOutcome.allCases) { Text(BodyStrings.outcomeLabel($0)).tag($0) }
                    } label: { Text(BodyStrings.outcomePicker) }
                    .pickerStyle(.segmented)
                    .padding(.bottom, ZoopSpacing.s)
                    if model.patterns.habits.isEmpty {
                        Text(BodyStrings.habitsEmptyForOutcome)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(model.patterns.habits.enumerated()), id: \.element.id) { i, f in
                        BodyFindingRow(finding: f, isFirst: i == 0, onSelect: onSelect)
                    }
                }
            }
        }
    }

    /// While the stream-walking readings load, their "needs more data" line would be premature.
    private var pending: [LocalizedStringResource] {
        model.loadingSlow ? model.patterns.pending.filter { $0 != BodyStrings.pendingEvening } : model.patterns.pending
    }
}

// MARK: - Links (all metrics, lab book, report)

struct BodyLinksCard: View {
    let onLabBook: () -> Void
    let onReport: () -> Void

    var body: some View {
        ListCard {
            NavigationLink(value: TabRoute.metricExplorer) {
                row(BodyStrings.linkAllMetrics, BodyStrings.linkAllMetricsDetail)
            }
            .buttonStyle(.plain)
            .listCardRow(isFirst: true)
            Button(action: onLabBook) { row(BodyStrings.linkLabBook, BodyStrings.linkLabBookDetail) }
                .buttonStyle(.plain)
                .listCardRow()
            Button(action: onReport) { row(BodyStrings.linkReport, BodyStrings.linkReportDetail) }
                .buttonStyle(.plain)
                .listCardRow()
        }
    }

    private func row(_ title: LocalizedStringResource, _ detail: LocalizedStringResource) -> some View {
        HStack(spacing: ZoopSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(detail).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: ZoopSpacing.s)
            BodyChevron()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
