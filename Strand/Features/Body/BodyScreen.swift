#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - BodyScreen: the Insights tab (CONCEPT §3.6)
//
// "How is my body doing over time?" in the order a reader needs it: four sections (Body, Sleep,
// Training, Stress), each a header over chart-led tiles (the vitals and sleep type lead their sections),
// then one trend to explore, the logbook habits, and the ways out (all metrics, lab book, report).
// Each fact appears once; sentences, samples and methods live in the explainers behind the tiles.
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
                    BodyInsightSections(model: model, onFinding: { selectedFinding = $0 },
                                        onVital: { selectedVital = $0 })
                    BodyTrendCard(model: model)
                    BodyPatternsSection(model: model, includesOthers: false) { selectedFinding = $0 }
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

// MARK: - Sections (Body, Sleep, Training, Stress)

/// The interpretations grouped by what they are about, each a header over a two-up grid of tiles.
/// Body opens with the vitals and their one-line summary; Sleep with the sleep type.
struct BodyInsightSections: View {
    @ObservedObject var model: BodyModel
    let onFinding: (BodyFinding) -> Void
    let onVital: (BodyVital) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            section(.body, note: model.vitalsSummary) {
                BodyVitalsSection(vitals: model.vitals, showsTitle: false, onSelect: onVital)
            }
            section(.sleep, lead: model.sleepType != nil) {
                BodySleepTypeSection(content: model.sleepType, showsTitle: false)
            }
            section(.training)
            section(.stress)
            if all.isEmpty && !model.loadingSlow {
                Text(BodyStrings.showsEmpty)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZoopSpacing.xs)
            }
        }
    }

    /// Interpretations first, then the weekday and evening patterns, in a stable order.
    private var all: [BodyFinding] { model.findings + model.patterns.others }

    @ViewBuilder
    private func section<Lead: View>(_ kind: BodyInsightSection, note: LocalizedStringResource? = nil,
                                     lead: Bool = true, @ViewBuilder content: () -> Lead) -> some View {
        let items = all.filter { $0.section == kind }
        if lead || !items.isEmpty {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                BodySectionTitle(title: kind.title, note: note)
                if lead { content() }
                if !items.isEmpty { BodyInsightGrid(findings: items, onSelect: onFinding) }
            }
        }
    }

    private func section(_ kind: BodyInsightSection) -> some View {
        section(kind, lead: false) { EmptyView() }
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
