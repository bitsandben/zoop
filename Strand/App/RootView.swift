import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case intelligence = "Intelligence"
    case insightsHub = "What Moves You"
    case coach = "Coach"
    case live = "Live"
    case breathe = "Breathe"
    case intervals = "Intervals"
    case explore = "Explore"
    case compare = "Compare"
    case insights = "Insights"
    case sleep = "Sleep"
    case trends = "Trends"
    case workouts = "Workouts"
    case health = "Health"
    case stress = "Stress"
    case labBook = "Lab Book"
    case rhythm = "Rhythm"
    case appleHealth = "Apple Health"
    case xiaomi = "Mi Band"
    case dataSources = "Data Sources"
    case backupSync = "Backup & Sync"
    case fusedRecord = "Your Data, Fused"
    case devices = "Devices"
    case noopLimitations = "Zoop Limitations"
    case notifications = "Notifications"
    case automation = "Automations"
    case smartAlarm = "Smart Alarm"
    case powerSaving = "Power saving"
    case settings = "Settings"
    case testCentre = "Test Centre"

    var id: String { rawValue }

    /// Localized sidebar label; each case is a string literal so Xcode extracts it into the String Catalog.
    var titleKey: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .intelligence: return "Intelligence"
        case .insightsHub: return "What Moves You"
        case .coach: return "Coach"
        case .live: return "Live"
        case .breathe: return "Breathe"
        case .intervals: return "Intervals"
        case .explore: return "Explore"
        case .compare: return "Compare"
        case .insights: return "Insights"
        case .sleep: return "Sleep"
        case .trends: return "Trends"
        case .workouts: return "Workouts"
        case .health: return "Health"
        case .stress: return "Stress"
        case .labBook: return "Lab Book"
        case .rhythm: return "Rhythm"
        case .appleHealth: return "Apple Health"
        case .xiaomi: return "Mi Band"
        case .dataSources: return "Data Sources"
        case .backupSync: return "Backup & Sync"
        case .fusedRecord: return "Your Data, Fused"
        case .devices: return "Devices"
        case .noopLimitations: return "Zoop Limitations"
        case .notifications: return "Notifications"
        case .automation: return "Automations"
        // "Alarms" is the one alarm surface (#766): strap wake-alarm plus the evening wind-down reminder. The
        // case name and rawValue stay `smartAlarm`/"Smart Alarm" as the in-memory nav identifier.
        case .smartAlarm: return "Alarms"
        case .powerSaving: return "Power saving"
        case .settings: return "Settings"
        case .testCentre: return "Test Centre"
        }
    }

    /// The same label as `titleKey` as a plain `String`, so the sidebar filter (#915) can match what the user
    /// reads. Keep the two switches in lockstep: a string edit must be mirrored by hand or search misses that row.
    var localizedTitle: String {
        switch self {
        case .today: return String(localized: "Today")
        case .intelligence: return String(localized: "Intelligence")
        case .insightsHub: return String(localized: "What Moves You")
        case .coach: return String(localized: "Coach")
        case .live: return String(localized: "Live")
        case .breathe: return String(localized: "Breathe")
        case .intervals: return String(localized: "Intervals")
        case .explore: return String(localized: "Explore")
        case .compare: return String(localized: "Compare")
        case .insights: return String(localized: "Insights")
        case .sleep: return String(localized: "Sleep")
        case .trends: return String(localized: "Trends")
        case .workouts: return String(localized: "Workouts")
        case .health: return String(localized: "Health")
        case .stress: return String(localized: "Stress")
        case .labBook: return String(localized: "Lab Book")
        case .rhythm: return String(localized: "Rhythm")
        case .appleHealth: return String(localized: "Apple Health")
        case .xiaomi: return String(localized: "Mi Band")
        case .dataSources: return String(localized: "Data Sources")
        case .backupSync: return String(localized: "Backup & Sync")
        case .fusedRecord: return String(localized: "Your Data, Fused")
        case .devices: return String(localized: "Devices")
        case .noopLimitations: return String(localized: "Zoop Limitations")
        case .notifications: return String(localized: "Notifications")
        case .automation: return String(localized: "Automations")
        case .smartAlarm: return String(localized: "Alarms")
        case .powerSaving: return String(localized: "Power saving")
        case .settings: return String(localized: "Settings")
        case .testCentre: return String(localized: "Test Centre")
        }
    }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .intelligence: return "brain.head.profile"
        case .insightsHub: return "wand.and.sparkles"
        case .coach: return "sparkles"
        case .live: return "waveform.path.ecg"
        case .breathe: return "lungs.fill"
        case .intervals: return "timer"
        case .explore: return "square.grid.2x2.fill"
        case .compare: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.fill"
        case .sleep: return "moon.stars.fill"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .health: return "heart.text.square.fill"
        case .stress: return "gauge.with.dots.needle.50percent"
        case .labBook: return "books.vertical.fill"
        case .rhythm: return "waveform.path"
        case .appleHealth: return "heart.fill"
        case .xiaomi: return "figure.walk.motion"
        case .dataSources: return "square.and.arrow.down.fill"
        case .backupSync: return "externaldrive.fill.badge.icloud"
        case .fusedRecord: return "square.stack.3d.up.fill"
        case .devices: return "badge.plus.radiowaves.right"
        case .noopLimitations: return "list.bullet.rectangle"
        case .notifications: return "bell.badge.fill"
        case .automation: return "wand.and.stars"
        case .smartAlarm: return "alarm.fill"
        case .powerSaving: return "battery.25"
        case .settings: return "gearshape.fill"
        case .testCentre: return "stethoscope"
        }
    }
}

/// One collapsible sidebar section. The flat `NavItem` cases are grouped into a few labelled sections;
/// `NavGroup.all` is the single source of truth, so the routability test can assert every `NavItem` case
/// appears across the groups.
struct NavGroup: Identifiable {
    let title: LocalizedStringKey
    let id: String
    let items: [NavItem]

    /// The sidebar sections, in order, mirroring the iOS More-tab grouping. Devices/pairing sits at the top of
    /// Data & App. Every `NavItem` appears exactly once across the groups (asserted by the routability test).
    static let all: [NavGroup] = [
        NavGroup(title: "Today", id: "today", items: [.today]),
        NavGroup(title: "Sleep", id: "sleep", items: [.sleep]),
        NavGroup(title: "Body", id: "body", items: [
            .workouts, .live, .health, .stress, .intervals, .breathe,
        ]),
        // The overlapping insight surfaces collapse under this single Insights group.
        NavGroup(title: "Insights", id: "insights", items: [
            .intelligence, .insightsHub, .coach, .explore, .compare, .insights,
            .labBook, .rhythm, .trends,
        ]),
        NavGroup(title: "Data & App", id: "data_app", items: [
            .devices, .noopLimitations, .dataSources, .appleHealth, .xiaomi, .backupSync, .fusedRecord,
            .notifications, .automation, .smartAlarm, .powerSaving, .settings, .testCentre,
        ]),
    ]

    static func group(containing item: NavItem) -> NavGroup? {
        all.first { $0.items.contains(item) }
    }
}

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR stream); the live status pill is
    // isolated in SidebarStatus so frame ticks do not re-render the whole shell.
    @EnvironmentObject var repo: Repository
    /// Cross-screen navigation requests; lets a screen switch the sidebar selection without owning it. See `NavRouter`.
    @EnvironmentObject var router: NavRouter
    /// The Coach master switch (`zoop.coachEnabled`, shared with iOS). Default ON.
    @AppStorage("zoop.coachEnabled") private var coachEnabled = true

    @State private var selection: NavItem? = .today
    /// Which sidebar groups are expanded; default is the group owning the launch selection. Single-item
    /// Today/Sleep always read expanded; multi-item groups collapse to their header.
    @State private var expandedGroups: Set<String> = Self.initialExpandedGroups(for: .today)
    /// Sidebar filter text (#915): filters every group by localized row title so any screen is reachable
    /// without knowing which section owns it.
    @State private var searchQuery = ""
    /// Expand/collapse state at the instant a search began (trimmed query empty to non-empty), restored when
    /// the search clears. nil means no search in flight; whitespace-only never arms one.
    @State private var preSearchExpansion: Set<String>? = nil

    /// Groups expanded at rest: every single-item group plus the group owning the selection. `internal` so
    /// the routability test can pin it via `@testable`.
    static func initialExpandedGroups(for item: NavItem?) -> Set<String> {
        var open = Set(NavGroup.all.filter { $0.items.count == 1 }.map(\.id))
        if let item, let g = NavGroup.group(containing: item) { open.insert(g.id) }
        return open
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // A real row above the list, not a `.safeAreaInset`: a macOS `List(.sidebar)` does not inset its scroll
                // content for a top inset, so the lockup floated over the rows.
                brand
                // Collapsible sections: each multi-item group is a DisclosureGroup bound to `expandedGroups`;
                // single-item groups (Today / Sleep) render their row directly.
                List(selection: $selection) {
                    // One pass over NavGroup.all in data order (never split singles from multis; ordering must survive new
                    // groups). While searching each group shows only matching rows; bare-row vs DisclosureGroup keys on the
                    // group's full size, so Today/Sleep stay bare rows that drop out on a miss.
                    ForEach(NavGroup.all) { group in
                        let visible = visibleItems(in: group)
                        if group.items.count == 1 {
                            ForEach(visible) { sidebarRow($0) }
                        } else if !visible.isEmpty {
                            DisclosureGroup(isExpanded: groupExpansion(group.id)) {
                                ForEach(visible) { sidebarRow($0) }
                            } label: {
                                Text(group.title)
                                    .font(StrandFont.rounded(11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .textCase(.uppercase)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // Hide the sidebar vibrancy material so rows sit on the same flat surfaceBase as the brand header.
                .scrollContentBackground(.hidden)
                // Native .searchable on the sidebar column (system search field with focus, clear and Escape for free).
                // macOS-only by design: iOS's tab bar plus More list already reaches every destination.
                .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")

                Divider().overlay(StrandPalette.hairline)
                SidebarStatus().padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(StrandPalette.surfaceBase)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            // The crossfade `.id` lives on the inner switched content, not the detail-column root: an `.id` on the
            // root re-created the hosted subtree on each switch, cold-starting the target screen and re-running its
            // O(full-history) @MainActor reads, which froze macOS on a large DB (#833). The child still gets a
            // per-selection identity, so the ~240ms opacity crossfade fires unchanged.
            ZStack {
                detail
                    .id(selection ?? .today)
                    .transition(.opacity)
            }
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .task {
            await repo.refresh()
            // Backup & Sync on-launch catch-up, gated on the auto toggle (default OFF). A whole-DB ZIP can be 100MB+,
            // so run it in a detached utility-priority task after the launch-critical refresh, off the main actor.
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Honour a cross-screen request to open a top-level destination, then clear it so the same tap can fire again.
        .onChangeCompat(of: router.requestedDestination) { dest in
            switch dest {
            case .devices: selection = .devices
            case .insightsHub: selection = .insightsHub
            case .labBook: selection = .labBook
            case .fusedRecord: selection = .fusedRecord
            case .rhythm: selection = .rhythm
            case .trends: selection = .trends
            // The Today active-workout indicator routes to Live; LiveView consumes the one-shot `presentActiveWorkout` flag.
            case .activeWorkout: selection = .live
            // Live Sessions starts from Today's own entry (a cover, not a sidebar item), so a deep link lands on Today.
            case .liveSession: selection = .today
            case .journal: selection = .insights
            // The Today Coach launcher hands off here so the send/stream/consent surface stays in one place (#1862).
            case .coach: selection = .coach
            case .alarms: selection = .smartAlarm
            case nil: break
            }
            if dest != nil { router.requestedDestination = nil }
        }
        // When the selection moves, expand the group that owns it so the selected row is not hidden in a
        // collapsed section. User collapses of other groups are preserved.
        .onChangeCompat(of: selection) { sel in
            if let sel, let g = NavGroup.group(containing: sel) {
                expandedGroups.insert(g.id)
            }
        }
        // Search transitions (#915): entering a search snapshots the expand/collapse state once, then each
        // keystroke auto-expands groups with matches. Clearing restores the snapshot, except the group owning the
        // current selection stays expanded.
        .onChangeCompat(of: searchQuery) { raw in
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                guard let saved = preSearchExpansion else { return }
                preSearchExpansion = nil
                expandedGroups = saved
                if let sel = selection, let g = NavGroup.group(containing: sel) {
                    expandedGroups.insert(g.id)
                }
            } else {
                if preSearchExpansion == nil { preSearchExpansion = expandedGroups }
                for group in NavGroup.all
                where group.items.contains(where: { $0.localizedTitle.localizedStandardContains(query) }) {
                    expandedGroups.insert(group.id)
                }
            }
        }
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A group's rows under the filter: all when no search, else those whose localized title contains the
    /// query (`localizedStandardContains`: case-, diacritic- and locale-aware). A group with no hits disappears.
    private func visibleItems(in group: NavGroup) -> [NavItem] {
        // Coach is dropped at the render site, not from `NavGroup.all`: that catalogue is asserted complete, and
        // the destination must stay routable because a saved selection or deep link can still name `.coach`.
        let items = coachEnabled ? group.items : group.items.filter { $0 != .coach }
        let query = trimmedQuery
        guard !query.isEmpty else { return items }
        return items.filter { $0.localizedTitle.localizedStandardContains(query) }
    }

    private func sidebarRow(_ item: NavItem) -> some View {
        Label(item.titleKey, systemImage: item.icon)
            .font(StrandFont.rounded(13, weight: .medium))
            .tag(item)
    }

    private func groupExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            }
        )
    }

    private var brand: some View {
        HStack(spacing: 8) {
            // In-app logo: the open recovery-ring mark as a lockup with the wordmark; flat gold gradient, low glow.
            BrandMark(size: 22)
            Text("Zoop")
                .font(StrandFont.rounded(20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
        }
        // Top padding clears the traffic-light controls (the window hides its title bar).
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: todayDetail
        case .intelligence: IntelligenceView()
        case .insightsHub: InsightsHubView()
        case .coach: CoachView()
        case .live: liveDetail
        case .breathe: BreathingView()
        case .intervals: IntervalTimerView()
        case .explore: MetricExplorerView()
        case .compare: CompareView()
        case .insights: InsightsView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .stress: StressView()
        case .labBook: LabBookView()
        case .rhythm: RhythmHost()
        case .appleHealth: AppleHealthView()
        case .xiaomi: XiaomiBandView()
        case .dataSources: DataSourcesView()
        case .backupSync: BackupSyncView()
        case .fusedRecord: FusedRecordHost()
        case .devices: DevicesView()
        case .noopLimitations: ZoopLimitationsView()
        case .notifications: NotificationSettingsView()
        case .automation: AutomationsView()
        case .smartAlarm: SmartAlarmView()
        case .powerSaving: PowerSavingView()
        case .settings: settingsDetail
        case .testCentre: TestCentreView()
        }
    }

    // Today's "Your Cards" rows push detail pages via NavigationLink. The macOS detail column has no
    // NavigationStack of its own, so those pushes had no Back chrome and switching sidebar items hung (#753).
    // Wrap the pane in its own stack, as MetricExplorerView does. iOS tabs are already wrapped.
    @ViewBuilder private var todayDetail: some View {
        #if os(macOS)
        NavigationStack {
            // Today's root-level links push TabRoute values (#198), so register their destinations once per stack
            // (a double registration double-pushes, #38).
            TodayView()
                .tabRouteDestinations()
        }
        #else
        TodayView()
        #endif
    }

    // Settings pushes into Test Centre; same macOS NavigationStack wrap (#753) for Back chrome.
    @ViewBuilder private var settingsDetail: some View {
        #if os(macOS)
        NavigationStack { SettingsView() }
        #else
        SettingsView()
        #endif
    }

    // Live's strap-log card pushes into Test Centre (#507/#509); same macOS NavigationStack wrap.
    @ViewBuilder private var liveDetail: some View {
        #if os(macOS)
        NavigationStack { LiveView() }
        #else
        LiveView()
        #endif
    }
}

/// The Zoop logo mark: an open recovery ring (~80% arc, round caps, from 12 o'clock) with a solid centre
/// core dot, in the gold gradient, flat and low-glow. Drawn from design tokens; sized to x-height-match the wordmark.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            // Open ring: trim 0 to 0.8 leaves a ~20% gap, rotated to the top; the gradient sweeps clockwise from 12 o'clock.
            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(gradient: StrandPalette.goldGradient,
                                    center: .center,
                                    angle: .degrees(-90)),
                    style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.84, height: size * 0.84)

            Circle()
                .fill(LinearGradient(gradient: StrandPalette.goldGradient,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Isolated live-status pill: owns the LiveState observation so the rest of RootView does not re-render
/// on the ~1 Hz HR / frame stream.
private struct SidebarStatus: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .shadow(color: statusColor.opacity(0.6), radius: live.connected ? 4 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(StrandFont.rounded(12, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                // Gated on both the link and whose device it is: `batteryPct` is never cleared, so ungated this showed
                // the strap's last charge with nothing connected and the `nil` branch was unreachable (#2208).
                Text(live.connected && live.activeIsWhoop
                     ? live.batteryPct.map { String(localized: "Battery \(Int($0))%") } ?? String(localized: "Strap not connected")
                     : String(localized: "Strap not connected"))
                    .font(StrandFont.rounded(11))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
        }
        .padding(10)
        .zoopInsetSurface(radius: 10)
    }

    // Shares LiveState.connectionStatus* with the Settings strap card so they never disagree (#266); a
    // connected-but-unbonded 5/MG reads "Connected" here too.
    private var statusColor: Color {
        live.connectionStatusIsActive ? StrandPalette.statusPositive
            : live.connectionStatusIsIdle ? StrandPalette.statusWarning
            : StrandPalette.statusCritical
    }
    private var statusText: String {
        live.connectionStatusLabel
    }
}
