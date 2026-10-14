#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - BodyModel (the Insights tab's one view model)
//
// Loads once per refresh and publishes ready-to-render content: the interpretations, the vitals, the
// trend for the chosen metric and window, and the patterns for the chosen outcome. The pickers only
// re-run the pure builders; nothing re-reads the database.

@MainActor
final class BodyModel: ObservableObject {
    @Published private(set) var findings: [BodyFinding] = []
    @Published private(set) var vitals: [BodyVital] = []
    @Published private(set) var vitalsSummary: LocalizedStringResource?
    @Published private(set) var trend: BodyTrend?
    @Published private(set) var patterns = BodyPatternsContent()
    /// The slow readings (streams, journal) are still loading.
    @Published private(set) var loadingSlow = true

    @Published var trendMetric: BodyTrendMetric = .recovery { didSet { rebuildTrend() } }
    @Published var trendWindow: BodyTrendWindow = .month { didSet { rebuildTrend() } }
    @Published var habitOutcome: BodyOutcome = .recovery { didSet { rebuildPatterns() } }

    private let loader = BodyLoader()
    private var snapshot = BodySnapshot()
    private var days: [DailyMetric] = []
    private var effortScale: EffortScale = .hundred

    func load(repo: Repository, profile: ProfileStore, effortScale: EffortScale) async {
        self.effortScale = effortScale
        days = repo.days

        snapshot = loader.quick(repo: repo)
        await loadVitals(repo: repo)
        rebuildFindings()
        rebuildTrend()

        var s = snapshot
        await loader.journal(into: &s, repo: repo)
        snapshot = s
        rebuildPatterns()

        await loader.slow(into: &s, repo: repo, zoneSet: profile.hrZoneSet, maxHR: profile.hrMax)
        guard !Task.isCancelled else { return }
        snapshot = s
        rebuildFindings()
        rebuildPatterns()
        loadingSlow = false
    }

    /// The vitals alone, for pages that show only them (iOS Health monitor).
    func loadVitals(repo: Repository) async {
        // #1118: nights whose HRV the WHOOP 4.0 over-counted are left out rather than shown as fact.
        let overCount = await repo.exploreSeries(key: "hrv_rr_overcount", source: "my-whoop", days: 45)
        let flagged = Set(overCount.filter { $0.value >= 0.5 }.map(\.day))
        vitals = BodyVitals.build(rows: repo.vitalMetricRows, overCountDays: flagged,
                                  today: Repository.localDayKey(Date()))
        vitalsSummary = BodyVitals.summary(vitals)
    }

    func updateEffortScale(_ scale: EffortScale) {
        guard scale != effortScale else { return }
        effortScale = scale
        rebuildFindings()
        rebuildTrend()
    }

    private func rebuildFindings() {
        findings = BodyFindings.build(snapshot, effortScale: effortScale)
    }

    private func rebuildTrend() {
        guard !days.isEmpty else { trend = nil; return }
        trend = BodyTrend.build(days: days, metric: trendMetric, window: trendWindow, scale: effortScale)
    }

    private func rebuildPatterns() {
        patterns = BodyPatterns.build(snapshot, outcome: habitOutcome)
    }
}
#endif
