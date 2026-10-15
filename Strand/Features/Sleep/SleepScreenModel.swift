import Foundation
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Everything the Sleep screen shows for the night it is on.
struct SleepNightPage {
    let offset: Int
    let night: Night
    /// false for a day whose blocks decoded to no stages; the night still shows, without numbers.
    let hasStages: Bool
    let title: LocalizedStringResource
    let spanLabel: String
    let canGoOlder: Bool
    let canGoNewer: Bool
    let metrics: SleepNightMetrics
    let caveats: [SleepCaveat]
    let stageSource: SleepStageSource
    let editTarget: CachedSleepSession?
    /// Why this block is the day's main sleep; only when the day had more than one block.
    let mainSleepReason: String?
    let naps: [CachedSleepSession]
    /// Movement during the night against earlier nights; nil without stored motion or on a ring.
    let restlessness: SleepRestlessContent?
}

enum SleepCaveat: Hashable {
    case lowConfidence, incomplete
    case partial(percent: Int)
}

/// Where the night's stages came from, for the timeline's one-line footnote.
enum SleepStageSource { case estimated, ring, imported }

/// A point of the overnight heart-rate overlay.
struct SleepHRPoint: Identifiable {
    let date: Date
    let bpm: Double
    var id: Date { date }
}

// MARK: - SleepScreenModel
//
// Loads the stored sleep blocks, resolves the displayed night and builds every readout. The screen
// only renders `page` / `overview` and calls the intents. `ObservableObject` rather than `@Observable`
// because the shared macOS target still deploys to macOS 13.

@MainActor
final class SleepScreenModel: ObservableObject {
    @Published private(set) var base: SleepModel?
    @Published private(set) var page: SleepNightPage?
    @Published private(set) var overview: SleepOverviewMetrics?
    @Published private(set) var heartRate: [SleepHRPoint] = []
    @Published var undo: SleepUndo?
    @Published var resultChanged = false

    private(set) var offset = 0
    private var navDays: [[CachedSleepSession]] = []
    private var allSessions: [CachedSleepSession] = []
    private var habitual: Int?
    private var motions: [Int: [Double]] = [:]
    private var restEntries: [Int: SleepRestlessReadouts.Entry] = [:]
    private var loadedRefresh: Int?
    var resultTracker = SleepResultChangeTracker()
    var resultScope: String?
    var undoTask: Task<Void, Never>?

    weak var repo: Repository?
    weak var intelligence: IntelligenceEngine?

    func attach(repo: Repository, intelligence: IntelligenceEngine) {
        self.repo = repo
        self.intelligence = intelligence
        if base == nil { rebuild(resetOffset: true) }
    }

    /// Fetches every stored block (naps and split nights included), the learned midsleep and the
    /// stored motion, then rebuilds. Runs whenever the repository's sleep inputs change.
    func reload() async {
        guard let repo else { return }
        let refresh = repo.refreshSeq
        let sessions = await repo.allSleepSessions()
        let habitual = await repo.habitualMidsleepSec()
        let motions = await repo.sessionMotions(sessions: sessions)
        guard !Task.isCancelled, refresh == repo.refreshSeq else { return }
        allSessions = sessions
        self.habitual = habitual
        self.motions = motions
        rebuild(resetOffset: true)
        loadedRefresh = refresh
        observeResult()
    }

    // MARK: Navigation

    func showOlder() { show(offset: offset + 1) }
    func showNewer() { show(offset: offset - 1) }

    private func show(offset newOffset: Int) {
        guard newOffset >= 0, newOffset < max(navDays.count, 1), newOffset != offset else { return }
        offset = newOffset
        page = buildPage()
        resetResultNotice()
        observeResult()
    }

    // MARK: Building

    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? (repo?.sleeps ?? []) : allSessions
    }

    private func rebuild(resetOffset: Bool) {
        guard let repo else { return }
        if resetOffset { offset = 0 }
        navDays = SleepModel.navDays(navSessions: navSessions)
        // A ring stores its own 1–4 movement classes, not gravity counts, so it gets no stillness card.
        restEntries = repo.activeDeviceIsOura ? [:]
            : SleepRestlessReadouts.entries(navDays: navDays, habitualMidsleepSec: habitual, motions: motions)
        base = SleepModel.build(SleepModelInputs(
            days: repo.days, sleeps: repo.sleeps, allSessions: allSessions,
            importedSleep: repo.importedSleep, habitualMidsleepSec: habitual, motionByStart: motions))
        page = buildPage()
        if let base {
            overview = SleepReadouts.overview(model: base,
                                              windows: navSessions.map { ($0.effectiveStartTs, $0.endTs) },
                                              newestWake: base.night.wakeDate)
        } else {
            overview = nil
        }
    }

    private func buildPage() -> SleepNightPage? {
        guard let repo, let base else { return nil }
        let blocks = navDays.indices.contains(offset) ? navDays[offset] : []
        let merged: Night? = offset == 0
            ? (base.isStubNight ? nil : base.night)
            : SleepModel.decodedNight(at: offset, navDays: navDays, habitualMidsleepSec: habitual, motionByStart: motions)
        let night: Night
        if let merged {
            night = merged
        } else if offset == 0 {
            night = base.night
        } else if let stub = SleepScreen.stubDaySession(blocks, habitualMidsleepSec: habitual) {
            night = Night(session: stub, stages: .zero, sourceBlocks: blocks, habitualMidsleepSec: habitual)
        } else {
            return nil
        }
        let hasStages = merged != nil
        return SleepNightPage(
            offset: offset, night: night, hasStages: hasStages,
            title: relativeTitle(),
            spanLabel: night.spanLabel,
            canGoOlder: offset < navDays.count - 1,
            canGoNewer: offset > 0,
            metrics: SleepReadouts.night(night, hasStages: hasStages, days: repo.days, imported: repo.importedSleep),
            caveats: hasStages ? caveats(night) : [],
            stageSource: repo.activeDeviceIsOura ? .ring : (night.hasRealTimeline ? .estimated : .imported),
            editTarget: night.editTarget,
            mainSleepReason: night.sourceBlocks.count > 1 ? mainSleepReason(night) : nil,
            naps: night.naps,
            restlessness: hasStages ? SleepRestlessReadouts.content(offset: offset, entries: restEntries) : nil)
    }

    /// "Last night" / "N nights ago", counted in calendar nights from today, so a night the strap was
    /// off is a visible gap rather than two neighbours reading as consecutive.
    private func relativeTitle() -> LocalizedStringResource {
        let n = SleepNightLabel.nightsAgo(wakeTimestamps: navDays.map { $0.first.map { Int($0.endTs) } },
                                          offset: offset, today: Repository.logicalDay(Date()))
        return n == 0 ? SleepStrings.lastNight : SleepStrings.nightsAgo(n)
    }

    private func caveats(_ night: Night) -> [SleepCaveat] {
        var out: [SleepCaveat] = []
        let s = night.stages
        if let eff = night.session.efficiency,
           SleepScreen.isStagingLowConfidence(asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem,
                                              efficiency: eff <= 1 ? eff : eff / 100) {
            out.append(.lowConfidence)
        }
        if SleepScreen.stageSparseNoteApplies(stagingSparse: night.sourceBlocks.contains { $0.stagingSparse == true },
                                              asleepMin: s.asleep) {
            out.append(.incomplete)
        }
        let group = SleepScreen.mainNightGroup(night.sourceBlocks, habitualMidsleepSec: night.habitualMidsleepSec)
        if let coverage = HypnogramCoverage.groupFraction(group.isEmpty ? night.sourceBlocks : group),
           coverage < HypnogramCoverage.minCoverage {
            // Floored, never rounded: 94.8 % must not print as 95 % beside the gate that flagged it.
            out.append(.partial(percent: Int((coverage * 100).rounded(.down))))
        }
        return out
    }

    /// The selector's own reason for picking this block, worded from `MainNightReason`.
    private func mainSleepReason(_ night: Night) -> String? {
        guard let sel = SleepStageTotals.mainNightSelection(
            night.sourceBlocks.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: SleepScreen.tzOffsetSec, habitualMidsleepSec: habitual) else { return nil }
        let dur = SleepReadouts.durationText(seconds: sel.asleepMinutes * 60)
        switch sel.reason {
        case .onlyBlock:
            return String(localized: "This is your only sleep block today.")
        case .longest:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)).")
        case .longestNearUsual:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime.")
        case .alignedToUsual:
            return String(localized: "Picked as your main sleep because it started near your usual sleep time.")
        }
    }

    // MARK: Heart-rate overlay

    /// The displayed night's heart rate, thinned to about 120 points; empty when nothing plausible.
    func loadHeartRate() async {
        guard let repo, let night = page?.night, night.session.endTs > night.session.effectiveStartTs else {
            heartRate = []
            return
        }
        let series = await repo.timelineSeries(metric: .hr, from: night.session.effectiveStartTs,
                                               to: night.session.endTs, targetPoints: 120)
        guard !Task.isCancelled else { return }
        let keep = NightSignal.plottable(series.points.map(\.value), metric: .heartRate) ?? []
        heartRate = keep.map { SleepHRPoint(date: series.points[$0].date, bpm: series.points[$0].value) }
    }

    // MARK: Result-change notice

    /// Compares the displayed night with the last snapshot once loading and scoring have settled.
    func observeResult() {
        guard let repo, let intelligence, loadedRefresh == repo.refreshSeq, !intelligence.computing else { return }
        guard let night = page?.night else { resetResultNotice(); return }
        let day = Calendar.current.startOfDay(for: night.wakeDate)
        let sources = Set(night.sourceBlocks.compactMap(\.deviceId)).sorted().joined(separator: ",")
        let snapshot = SleepResultSnapshot(
            scope: "\(repo.deviceId):\(sources):\(day.timeIntervalSince1970)",
            onset: night.session.effectiveStartTs, wake: night.session.endTs,
            asleepMinutes: night.stages.asleep,
            edited: night.session.userEdited || night.sourceBlocks.contains { $0.userEdited })
        if resultScope != snapshot.scope { resultChanged = false }
        resultScope = snapshot.scope
        if resultTracker.observe(snapshot, ready: true) { resultChanged = true }
    }

    func resetResultNotice() {
        resultTracker = SleepResultChangeTracker()
        resultChanged = false
        resultScope = nil
    }
}
