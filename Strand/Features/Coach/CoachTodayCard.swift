#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// Today's coach card: the morning brief and the suggestions still waiting for an answer.
///
/// Draws nothing when the coach is off or no brief exists for today, so it can sit on Today
/// unconditionally. All decisions live in `CoachSuggestionStore` / `CoachSuggestionActions`.
struct CoachTodayCard: View {
    @ObservedObject private var store = CoachSuggestionStore.shared
    @AppStorage("zoop.coachEnabled") private var coachEnabled = true
    @AppStorage(CoachMorningBrief.proactiveKey) private var proactive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The history is also reachable from the Coach chat; here it serves people without a provider,
    /// for whom the chat shows its setup screen instead.
    @State private var showsHistory = false

    var body: some View {
        // Re-evaluated every few minutes so a snoozed suggestion comes back without a reload.
        TimelineView(.periodic(from: .now, by: 300)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let day = Repository.localDayKey(now)
        if coachEnabled, proactive, let brief = store.brief(for: day) {
            let active = store.active(at: now)
            ContentCard(LocalizedStringKey(CoachStrings.cardTitle.key)) {
                Text(brief.text)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(active) { suggestion in
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                    CoachSuggestionRow(suggestion: suggestion, answer: answer)
                }
                if store.hasAnsweredAll(day: day, at: now) {
                    Text(CoachStrings.allAnswered)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Button { showsHistory = true } label: {
                    Text(CoachStrings.historyOpen)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .animation(ZoopMotion.gated(ZoopMotion.card, reduced: reduceMotion), value: active.map(\.id))
            .sheet(isPresented: $showsHistory) {
                NavigationStack { CoachSuggestionHistoryPage() }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func answer(_ suggestion: CoachSuggestion, _ answer: CoachSuggestionRow.Answer) {
        switch answer {
        case .accept: CoachSuggestionActions.accept(suggestion)
        case .later: CoachSuggestionActions.later(suggestion)
        case .dismiss: CoachSuggestionActions.dismiss(suggestion)
        }
    }
}

/// One suggestion: what, why, and the three answers.
struct CoachSuggestionRow: View {
    enum Answer { case accept, later, dismiss }

    let suggestion: CoachSuggestion
    let answer: (CoachSuggestion, Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(suggestion.title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(suggestion.body)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !suggestion.rationale.isEmpty {
                Text(suggestion.rationale)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            // Side by side when they fit, stacked at large Dynamic Type sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZoopSpacing.s) { buttons }
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) { buttons }
            }
            .padding(.top, ZoopSpacing.xs)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        Button { answer(suggestion, .accept) } label: { Text(CoachStrings.accept) }
            .buttonStyle(ZoopButtonStyle(.secondary))
        quiet(CoachStrings.later) { answer(suggestion, .later) }
        quiet(CoachStrings.dismiss) { answer(suggestion, .dismiss) }
    }

    /// Low-emphasis text answer with a full 44 pt target.
    private func quiet(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, ZoopSpacing.s)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
