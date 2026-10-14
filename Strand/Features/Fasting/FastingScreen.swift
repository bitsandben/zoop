#if os(iOS)
import SwiftUI
import StrandDesign

/// Fasting (CONCEPT §3.8): timer, plan, week, streak, body patterns, history, and the footnote on what
/// the strap cannot measure. View only; state and intents live in `FastingModel`.
struct FastingScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var model = FastingModel()
    @State private var draft: FastingDraft?
    @State private var showPlan = false
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
                if let summary = model.planSummary {
                    FastingPlanCard(summary: summary) { showPlan = true }
                }
                if let week = model.week { FastingWeekCard(week: week) }
                if let streak = model.streak, let consistency = model.consistency {
                    FastingStatsGrid(streak: streak, consistency: consistency)
                }
                if let patterns = model.patterns { FastingPatternsCard(patterns: patterns) }
                if model.loaded {
                    FastingHistoryCard(items: model.history) { draft = model.draft(for: $0.row) }
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
        .sheet(isPresented: $showPlan) { FastingPlanSheet(model: model) }
        .sheet(isPresented: $showAbout) { FastingAboutSheet() }
    }
}
#endif
