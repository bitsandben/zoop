import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - RecoveryScreen (CONCEPT §3.2)
//
// Answers one question: why is my Recovery what it is. Hero first, then what shaped it, the trend, the
// estimate for tomorrow and how check-ins tune the score. Each fact appears once; the explainer sheets
// hold the method and data behind it.

struct RecoveryScreen: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = RecoveryModel()

    var body: some View {
        // A ZStack with the canvas, not a bare Group: an empty Group has no view, so its `.task` never
        // ran and the pushed screen stayed blank.
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()
            if let content = model.content { RecoveryContentView(content: content) }
        }
        .task { await model.load(repo: repo) }
        // A re-score or a sync replaces `repo.days`; follow it so the screen never shows a stale night.
        .onChangeCompat(of: repo.refreshSeq) { _ in Task { await model.load(repo: repo) } }
    }
}

/// The layout for finished content, separate from loading so fixtures can render every state.
struct RecoveryContentView: View {
    let content: RecoveryContent
    @State private var explainer: ExplainerTarget?

    private struct ExplainerTarget: Identifiable {
        let readout: MetricReadout
        let explanation: MetricExplanation
        var id: MetricID { readout.id }
    }

    var body: some View {
        ScreenScaffold(title: "zoop.recovery.title") {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                hero
                if !content.timeline.isEmpty { RecoveryTimelineCard(steps: content.timeline) }
                if !content.contributors.isEmpty { contributors }
                if content.state == .scored { RecoveryTrendCard(days: content.trend, band: content.typicalRange) }
                if let forecast = content.forecast { RecoveryForecastCard(forecast: forecast) }
                RecoveryPersonalisationCard(kind: content.personalisation, todayFeeling: content.todayFeeling)
            }
        }
        .sheet(item: $explainer) { MetricExplainerSheet($0.readout, explanation: $0.explanation) }
    }

    private var hero: some View {
        HeroCard {
            Button {
                explainer = ExplainerTarget(readout: content.hero, explanation: content.heroExplanation)
            } label: {
                MetricHero(content.hero)
            }
            .buttonStyle(.plain)
        }
    }

    private var contributors: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(RecoveryStrings.contributorsTitle).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(RecoveryStrings.contributorsNote).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.top, ZoopSpacing.s)
            ListCard {
                ForEach(Array(content.contributors.enumerated()), id: \.element.id) { index, item in
                    RecoveryContributorRow(item: item, isFirst: index == 0) {
                        explainer = ExplainerTarget(readout: item.readout, explanation: item.explanation)
                    }
                }
            }
        }
    }
}
