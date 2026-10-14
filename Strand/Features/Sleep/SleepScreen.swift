import SwiftUI
import StrandDesign
import WhoopStore

/// Existing routes and the shared night selectors address the screen by its old name.
typealias SleepView = SleepScreen

// MARK: - SleepScreen (CONCEPT §3.3)
//
// "How did I sleep and what do I need tonight?" in a fixed order: the night, its timeline, its stages,
// naps, debt and rhythm, the night's vitals, tonight's plan and at most two insights. The screen holds
// no logic: `SleepScreenModel` builds every readout and owns the edit, delete and undo intents.
//
// The screen deliberately does not observe `LiveState` or `AppModel`: both publish about once a second
// while a strap streams. The leaves that need them (the freshness note, the plan card) observe them.

struct SleepScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var router: NavRouter
    @StateObject private var model = SleepScreenModel()

    @State private var selected: SleepMetric?
    @State private var edit: SleepEditRequest?
    @State private var napSeed: SleepNapSeed?
    #if os(iOS)
    @State private var why: SleepWhySeed?
    #endif

    var body: some View {
        ScreenScaffold(title: "Sleep", onRefresh: { await repo.refresh() }) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                notices
                if let page = model.page {
                    nightSections(page)
                    if let overview = model.overview {
                        SleepRhythmCard(overview: overview) { selected = $0 }
                    }
                    SleepVitalsGrid(metrics: page.metrics.vitals) { selected = $0 }
                    tonight
                    #if os(iOS)
                    SleepInsightsSection()
                    #else
                    SleepMarkCard()
                    #endif
                } else {
                    ComingSoon(what: repo.loaded
                        ? "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed."
                        : "Loading your sleep history…")
                    tonight
                }
            }
        }
        .task(id: inputKey) {
            model.attach(repo: repo, intelligence: intelligence)
            await model.reload()
        }
        .task(id: heartRateKey) { await model.loadHeartRate() }
        .task(id: model.resultChanged) {
            guard model.resultChanged else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            model.resultChanged = false
        }
        .onChangeCompat(of: intelligence.computing) { _ in model.observeResult() }
        .onDisappear { model.resetResultNotice() }
        .sheet(item: $selected) { MetricExplainerSheet($0.readout, explanation: $0.explanation) }
        .sheet(item: $edit) { editor($0) }
        .sheet(item: $napSeed) { seed in
            SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                            title: "Add a nap", blurb: "Saved as its own session, apart from the night.",
                            bedLabel: "Nap started", wakeLabel: "Nap ended") { start, end in
                await model.addNap(start: start, end: end)
            }
        }
        #if os(iOS)
        .sheet(item: $why) { seed in
            SleepWhySheet(seed: seed,
                          loadEvidence: { await model.onsetEvidence(startTs: seed.detectedStartTs, endTs: seed.endTs) },
                          applySettings: { await model.rescore() })
        }
        #endif
    }

    // MARK: Sections

    @ViewBuilder
    private var notices: some View {
        if let undo = model.undo {
            SleepUndoBanner(message: model.undoMessage(undo)) { Task { await model.undoDelete() } }
        }
        SleepFreshnessNote(latestWakeTs: model.base?.night.session.endTs)
        if model.resultChanged {
            DataPendingNote(title: "Sleep result updated",
                            message: "This night's sleep times or total asleep changed by at least five minutes.",
                            symbol: "checkmark.circle")
        }
    }

    @ViewBuilder
    private func nightSections(_ page: SleepNightPage) -> some View {
        SleepHeroCard(page: page,
                      onOlder: { model.showOlder() }, onNewer: { model.showNewer() },
                      onSelect: { selected = $0 },
                      onEdit: { edit = model.editRequestForNight() },
                      onWhy: whyAction(page))
        SleepTimelineCard(page: page, heartRate: model.heartRate)
        if page.hasStages {
            SleepMetricListCard(title: SleepStrings.stagesCard, metrics: page.metrics.stages) { selected = $0 }
        }
        if !page.naps.isEmpty {
            SleepNapsCard(naps: page.naps,
                          onEdit: { edit = model.editRequest(nap: $0) },
                          onAdd: { napSeed = model.napSeed() })
        }
    }

    @ViewBuilder
    private var tonight: some View {
        #if os(iOS)
        SleepPlanEntryCard()
        #else
        Button { router.openAlarms() } label: {
            ContentCard("Alarms", showsChevron: true) { EmptyView() }
        }
        .buttonStyle(.plain)
        #endif
    }

    private func whyAction(_ page: SleepNightPage) -> (() -> Void)? {
        #if os(iOS)
        guard let target = page.editTarget else { return nil }
        return {
            why = SleepWhySeed(detectedStartTs: target.startTs, effectiveStartTs: target.effectiveStartTs,
                               endTs: target.endTs, userEdited: target.userEdited,
                               mainSleepReason: page.mainSleepReason)
        }
        #else
        return nil
        #endif
    }

    private func editor(_ edit: SleepEditRequest) -> some View {
        SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs, coverage: edit.coverage,
                        suppressesReDetection: !edit.userEdited,
                        onSave: { bed, wake in await model.save(edit, bed: bed, wake: wake) },
                        onDelete: { await model.delete(edit) })
    }

    // MARK: Reload keys

    /// Changes exactly when the stored sleep inputs do, so hover, animation and live ticks never reload.
    private var inputKey: SleepInputKey {
        SleepInputKey(loaded: repo.loaded, daysCount: repo.days.count, sleepsCount: repo.sleeps.count,
                      lastDay: repo.days.last, lastSleep: repo.sleeps.last, refreshSeq: repo.refreshSeq)
    }

    private var heartRateKey: String {
        guard let night = model.page?.night else { return "" }
        return "\(night.session.effectiveStartTs)-\(night.session.endTs)-\(repo.refreshSeq)"
    }
}

private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let lastDay: DailyMetric?
    let lastSleep: CachedSleepSession?
    let refreshSeq: Int
}
