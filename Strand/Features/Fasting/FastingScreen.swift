#if os(iOS)
import SwiftUI
import StrandDesign

/// Fasting (CONCEPT §3.8): the two-phase timer (fast ↔ eating window), schedule, week strip, stats, body
/// patterns, history of both phases, and the footnote on what the strap cannot measure. View only; state
/// and intents live in `FastingModel`.
struct FastingScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var model = FastingModel()
    @State private var draft: FastingDraft?
    @State private var windowDraft: FastingWindowDraft?
    @State private var showSchedule = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                FastingTimerCard(model: model,
                                 onStartEarlier: { draft = model.draftForStartEarlier() },
                                 onEdit: { if let row = model.activeRow { draft = model.draft(for: row) } })
                if let error = model.saveError {
                    Text(error).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if let summary = model.scheduleSummary {
                    FastingScheduleCard(summary: summary) { showSchedule = true }
                }
                if let week = model.week { FastingTimelineCard(week: week) }
                if let stats = model.stats { FastingStatsGrid(stats: stats) }
                if let patterns = model.patterns { FastingPatternsCard(patterns: patterns) }
                if model.loaded {
                    FastingHistoryCard(items: model.history, onSelect: open)
                }
                FastingFootnote { showAbout = true }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.top, ZoopSpacing.s)
            .padding(.bottom, ZoopMetrics.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .zoopPushedScreen(title: "zoop.fasting.title")
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .sheet(item: $draft) { FastingEditSheet(model: model, draft: $0) }
        .sheet(item: $windowDraft) { FastingWindowEditSheet(model: model, draft: $0) }
        .sheet(isPresented: $showSchedule) { FastingScheduleSheet(model: model) }
        .sheet(isPresented: $showAbout) { FastingAboutSheet() }
    }

    private func open(_ item: FastingHistoryItem) {
        switch item.kind {
        case .fast(let row): draft = model.draft(for: row)
        case .window(let previous, let next): windowDraft = model.windowDraft(previous: previous, next: next)
        }
    }
}
#endif
