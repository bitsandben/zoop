import SwiftUI

// MARK: - TabRoute
// Value-based routes for every push that leaves a primary tab's root. The iOS tab shell binds each tab's
// `NavigationStack` to a `NavigationPath`, which only tracks pushes made through it, so root-level links
// push a VALUE to let re-tapping the active tab pop to the root (#135, #198). Deeper links stay
// closure-based: popping a route also pops everything above it.
// Shared with macOS because the sidebar shell hosts the same tab roots; each hosting `NavigationStack`
// must register `tabRouteDestinations()` exactly once, or the value double-pushes (see MetricExplorerView, #38).

/// One first-hop destination reachable from a tab root.
enum TabRoute: Hashable {
    /// The whole-day, full-resolution HR timeline.
    case fullDayChart
    /// One metric's detail page by `MetricCatalog` key, shared by Today's cards and Trends' small-multiples.
    case metric(String)
    /// One metric's detail by both key and source. `steps` exists under several sources, and a bare key
    /// resolves to whichever catalog entry is declared first, so this pins the source.
    case metricSourced(key: String, source: String)
    case metricExplorer
    case workouts
    /// The gym log and the interval timer, opened from the iOS Training tab's header.
    case liftLog
    case intervals
    case dataSources
    case stress
    case sleep
    case health
    case hydration
    case coupled
    /// The menstrual cycle calendar (iOS).
    case cycle
    /// What the stored history says: tonight, tomorrow, load and patterns (iOS).
    case patterns
    /// Guided breathing and the strap alarm, reachable from Home's moment card (iOS).
    case breathe
    case alarms
    /// Bedtime for tonight and the strap alarm (iOS).
    case sleepPlanner
    /// Today's Energy Bank estimate (iOS).
    case energyBank
    /// The fitness age and what shapes it (iOS).
    case fitnessAge
    /// The fasting timer, plan and history (iOS).
    case fasting
}

/// The detail screen for one catalog metric. Fitness age has its own screen on iOS, so its routes land there.
@ViewBuilder
func metricDetailDestination(_ metric: MetricDescriptor) -> some View {
    #if os(iOS)
    // Fitness age has its own screen; every route to its catalog entry lands there.
    if metric.key == "fitness_age" {
        FitnessAgeScreen()
    } else if metric.key == HeroRingMetric.charge {
        RecoveryScreen()
    } else {
        MetricDetailView(metric: metric)
    }
    #else
    MetricDetailView(metric: metric)
    #endif
}

extension View {
    /// Maps every `TabRoute` push to its screen. Apply once to the root content of each `NavigationStack`
    /// that hosts a tab-root view.
    func tabRouteDestinations() -> some View {
        navigationDestination(for: TabRoute.self) { route in
            switch route {
            case .fullDayChart: FullDayChartView()
            case .metric(let key):
                // Every caller passes a catalog key, so the fallback is theoretical; Health is the catch-all vitals surface.
                if let m = MetricCatalog.all.first(where: { $0.key == key }) {
                    metricDetailDestination(m)
                } else {
                    HealthView()
                }
            case .metricSourced(let key, let source):
                // Exact (key, source) resolution, falling back to the bare-key entry, then Health, so a stale route never dead-ends.
                if let m = MetricCatalog.metric(key: key, source: source)
                    ?? MetricCatalog.all.first(where: { $0.key == key }) {
                    metricDetailDestination(m)
                } else {
                    HealthView()
                }
            case .metricExplorer: MetricExplorerView()
            case .workouts: WorkoutsView()
            case .liftLog: LiftLogView()
            case .intervals: IntervalTimerView()
            case .dataSources: DataSourcesView()
            case .stress: StressView()
            case .sleep: SleepView()
            case .health: HealthView()
            case .hydration: HydrationView()
            case .coupled: CoupledView()
            case .breathe: BreathingView()
            case .alarms:
                // iOS: one alarm screen everywhere.
                #if os(iOS)
                SleepPlannerHost()
                #else
                SmartAlarmView()
                #endif
            case .sleepPlanner:
                #if os(iOS)
                SleepPlannerHost()
                #else
                SmartAlarmView()
                #endif
            case .patterns:
                #if os(iOS)
                PatternsScreen()
                #else
                EmptyView()
                #endif
            case .cycle:
                #if os(iOS)
                CycleScreen()
                #else
                EmptyView()
                #endif
            case .energyBank:
                #if os(iOS)
                EnergyBankScreen()
                #else
                EmptyView()
                #endif
            case .fitnessAge:
                #if os(iOS)
                FitnessAgeScreen()
                #else
                EmptyView()
                #endif
            case .fasting:
                #if os(iOS)
                FastingScreen()
                #else
                EmptyView()
                #endif
            }
        }
    }
}

/// The catalog keys the hero rings and their Key-Metrics tiles route to, named rather than repeated as
/// literals so a rename cannot leave a ring tappable but landing on the wrong screen (`TabRoute.metric`
/// falls back to Health on an unknown key).
/// Charge keeps its breakdown sheet wherever one exists and takes a route only on the Liquid Today;
/// Effort and Rest have no breakdown, so every surface routes. Rest uses `sleep_performance` here because
/// the platforms' detail screens resolve different key spaces.
/// These are catalog keys, not the series key space (`exploreSeries`, `resolvedSeries`, `sparks[...]`,
/// `provenanceKey`), which spells some of them identically but asks a different question.
enum HeroRingMetric {
    static let charge = "recovery"
    static let effort = "strain"
    static let rest = "sleep_performance"

    /// Charge, Effort, Rest, in hero-row order.
    static let all = [charge, effort, rest]
}
