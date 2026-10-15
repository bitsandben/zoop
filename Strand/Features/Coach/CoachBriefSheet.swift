#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// The coach's full morning brief, opened from the compact Today card: the brief, every waiting
/// suggestion with its "because" line and answers, and the history link.
struct CoachBriefSheet: View {
    @ObservedObject private var store = CoachSuggestionStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 300)) { context in
                ScrollView { content(now: context.date) }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(CoachStrings.cardTitle))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func content(now: Date) -> some View {
        let day = Repository.localDayKey(now)
        let active = store.active(at: now)
        return VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            if let brief = store.brief(for: day) {
                Text(brief.text)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(active) { suggestion in
                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                CoachSuggestionRow(suggestion: suggestion, answer: answer)
            }
            if store.hasAnsweredAll(day: day, at: now) {
                Text(CoachStrings.allAnswered)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            NavigationLink { CoachSuggestionHistoryPage() } label: {
                Text(CoachStrings.historyOpen)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ZoopSpacing.gutter)
        .padding(.vertical, ZoopSpacing.m)
        .animation(ZoopMotion.gated(ZoopMotion.card, reduced: reduceMotion), value: active.map(\.id))
    }

    private func answer(_ suggestion: CoachSuggestion, _ answer: CoachSuggestionRow.Answer) {
        switch answer {
        case .accept: CoachSuggestionActions.accept(suggestion)
        case .later: CoachSuggestionActions.later(suggestion)
        case .dismiss: CoachSuggestionActions.dismiss(suggestion)
        }
    }
}

/// One suggestion: what, why, and the three answers. The main answer is the design system's primary
/// button (high contrast in both themes); "Later" and "Dismiss" are quiet text buttons of the same
/// height, so the row reads as one control group.
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Side by side when they fit, stacked at large Dynamic Type sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ZoopSpacing.xs) { buttons }
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) { buttons }
            }
            .padding(.top, ZoopSpacing.s)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var buttons: some View {
        Button { answer(suggestion, .accept) } label: { Text(CoachStrings.accept(suggestion.action)) }
            .buttonStyle(ZoopButtonStyle(.primary))
        quiet(CoachStrings.later) { answer(suggestion, .later) }
        quiet(CoachStrings.dismiss) { answer(suggestion, .dismiss) }
    }

    /// Low-emphasis text answer at the primary button's height, with a full hit target.
    private func quiet(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, ZoopSpacing.s)
                .frame(height: ZoopButtonMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
    }
}
#endif
