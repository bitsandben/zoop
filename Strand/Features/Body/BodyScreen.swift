#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - BodyScreen: the Insights tab (CONCEPT §3.6)
//
// "How is my body doing over time?" in the order a reader needs it: what the body shows (the
// interpretations), the five vitals against their personal ranges, the sleep type, one trend to explore, the patterns
// in habits and weekdays, and the ways out (all metrics, lab book, report). Each fact appears once.
// The screen holds no logic; `BodyModel` builds everything it shows.
//
// Not observing `LiveState`/`AppModel` on purpose: both publish about once a second while a strap
// streams, and nothing here is live.

struct BodyScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @StateObject private var model = BodyModel()

    @State private var selectedFinding: BodyFinding?
    @State private var selectedVital: BodyVital?
    @State private var showingReport = false

    var body: some View {
        ScreenScaffold(title: "zoop.body.title", onRefresh: { await repo.refresh() }, lazy: true) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded ? "zoop.body.empty" : "zoop.body.loading")
            } else {
                VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                    BodyInterpretationsSection(summary: model.vitalsSummary, findings: model.findings,
                                               loading: model.loadingSlow) { selectedFinding = $0 }
                    BodyVitalsSection(vitals: model.vitals) { selectedVital = $0 }
                    BodySleepTypeSection(content: model.sleepType)
                    BodyTrendCard(model: model)
                    BodyPatternsSection(model: model) { selectedFinding = $0 }
                    BodyLinksCard(onLabBook: { router.openLabBook() }, onReport: { showingReport = true })
                }
            }
        }
        .task(id: repo.refreshSeq) {
            await model.load(repo: repo, profile: profile, effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw))
        }
        .onChangeCompat(of: effortScaleRaw) { model.updateEffortScale(UnitPrefs.resolveEffortScale($0)) }
        .sheet(item: $selectedFinding) { BodyFindingSheet(finding: $0) }
        .sheet(item: $selectedVital) { MetricExplainerSheet($0.readout, explanation: $0.metric.explanation) }
        .sheet(isPresented: $showingReport) { TrendsReportSheet(days: repo.days) }
    }
}

// MARK: - What your body shows

struct BodyInterpretationsSection: View {
    let summary: LocalizedStringResource?
    let findings: [BodyFinding]
    let loading: Bool
    let onSelect: (BodyFinding) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            BodySectionTitle(title: BodyStrings.showsTitle)
            if let summary {
                ContentCard {
                    Text(summary)
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(findings) { BodyFindingCard(finding: $0, onSelect: onSelect) }
            if findings.isEmpty && !loading {
                Text(BodyStrings.showsEmpty)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZoopSpacing.xs)
            }
        }
    }
}

// MARK: - Patterns as a page of its own (legacy routes: Patterns, What Moves You)

/// The patterns section on its own page, for the routes that still push "Patterns" or "What Moves You".
/// It is the same section the Insights tab shows, so the two can never disagree.
struct BodyPatternsPage: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @StateObject private var model = BodyModel()
    @State private var selected: BodyFinding?

    var body: some View {
        ScreenScaffold(title: "zoop.body.patterns.title") {
            BodyPatternsSection(model: model) { selected = $0 }
        }
        .task(id: repo.refreshSeq) {
            await model.load(repo: repo, profile: profile, effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw))
        }
        .sheet(item: $selected) { BodyFindingSheet(finding: $0) }
    }
}
#endif
