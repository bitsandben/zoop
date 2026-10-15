#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// Every suggestion the coach made in the retention window, grouped by day, newest first, with how
/// it was answered. Pushed from the Coach chat's menu.
struct CoachSuggestionHistoryPage: View {
    @ObservedObject private var store = CoachSuggestionStore.shared

    private struct DayGroup: Identifiable {
        let id: Date
        let items: [CoachSuggestion]
    }

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                if store.history.isEmpty {
                    ZoopEmptyState(systemImage: "sparkles", title: CoachStrings.historyEmptyTitle,
                                   message: CoachStrings.historyEmptyMessage)
                }
                ForEach(groups) { group in
                    Text(group.id.formatted(.dateTime.weekday(.wide).day().month(.wide)
                        .locale(AppLanguage.activeLocale)))
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, ZoopSpacing.s)
                    ListCard {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            row(item, now: now).listCardRow(isFirst: index == 0)
                        }
                    }
                }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.bottom, ZoopSpacing.xxl)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .zoopPushedScreen(title: LocalizedStringKey(CoachStrings.historyTitle.key))
    }

    private var groups: [DayGroup] {
        let byDay = Dictionary(grouping: store.history) { Calendar.current.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(id: $0, items: byDay[$0] ?? []) }
    }

    private func row(_ item: CoachSuggestion, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(item.title)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(item.body)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZoopSpacing.s)
            Text(CoachStrings.status(item, now: now))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
