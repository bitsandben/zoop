#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// Today's coach card, compact: the day's main takeaway in one line, how many suggestions wait, and a
/// chevron. Tapping opens `CoachBriefSheet` with the full brief and the answers, so Today never
/// carries a paragraph or button rows.
///
/// Draws nothing when the coach is off or no brief exists for today, so it can sit on Today
/// unconditionally. All decisions live in `CoachSuggestionStore` / `CoachSuggestionActions`.
struct CoachTodayCard: View {
    @ObservedObject private var store = CoachSuggestionStore.shared
    @AppStorage("zoop.coachEnabled") private var coachEnabled = true
    @AppStorage(CoachMorningBrief.proactiveKey) private var proactive = true
    @State private var showsBrief = false

    var body: some View {
        // Re-evaluated every few minutes so a snoozed suggestion comes back without a reload.
        TimelineView(.periodic(from: .now, by: 300)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let day = Repository.localDayKey(now)
        if coachEnabled, proactive, store.brief(for: day) != nil {
            let active = store.active(at: now)
            Button { showsBrief = true } label: {
                ContentCard(LocalizedStringKey(CoachStrings.cardTitle.key), showsChevron: true) {
                    VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                        Text(CoachTodayCard.headline(active: active))
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !active.isEmpty {
                            Text(CoachStrings.pending(active.count))
                                .font(ZoopType.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .sheet(isPresented: $showsBrief) {
                CoachBriefSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .opaqueSheetBackground()
            }
        }
    }

    /// The single most important takeaway: the top waiting suggestion's title, or, once everything is
    /// answered, the all-set line. Never the paragraph.
    static func headline(active: [CoachSuggestion]) -> String {
        if let top = active.first { return top.title }
        return String(localized: CoachStrings.allAnswered)
    }
}
#endif
