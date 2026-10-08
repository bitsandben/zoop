#if os(iOS)
import SwiftUI
import StrandDesign

/// Tab tags for the iPhone bar: Home, Health, Trends, More, and Coach as the separate round button.
/// Coach keeps its own tag when the master switch hides it, so More does not inherit Coach's
/// navigation path.
private enum IOSTab {
    static let home = 0
    static let health = 1
    static let coach = 2
    static let more = 3
    static let trends = 4
    static let count = 5
}

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with Home, Health, AI Coach, and everything else under More.
/// Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    /// #1841: shared with Android by NAME and meaning, not by storage — the two platforms keep their own
    /// stores, exactly as the Clock format setting does.
    ///
    /// Default FALSE here while Android defaults true, and the divergence is deliberate. Apple's forums
    /// report `.tabBarMinimizeBehavior(.onScrollDown)` failing to trigger in tabs built on
    /// `NavigationStack(path:)` — which is every primary tab in this file, bound deliberately so a tab
    /// root can pop and re-scroll. So this may well be inert on our structure, and defaulting ON would
    /// advertise a behaviour that never happens. Off until someone confirms it on an iOS 26 device.
    /// The Coach master switch, under the same `noop.` key Android writes. Default ON, so every install
    /// that shipped with the tab is unchanged.
    ///
    /// Not tab chrome: with this off the AI is off. The tab goes, the Today launcher card goes, and the
    /// daily brief is cancelled, because the brief calls a provider from the BACKGROUND with no UI
    /// attached and would otherwise keep posting AI notifications for a feature the wearer switched off.
    @AppStorage("zoop.coachEnabled") private var coachEnabled = true
    @AppStorage("zoop.bottomBarAutoHide") private var bottomBarAutoHide = false

    /// The live gym session, owned at the app root — see `LiftSessionController`.
    @EnvironmentObject private var liftSession: LiftSessionController
    /// External entry points must wait until the mandatory first-run gates have completed. The root owns
    /// that state; keeping it explicit here prevents this shell's window-level sheet from covering a gate.
    let homeScreenQuickActionsEnabled: Bool

    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter
    /// The scene-local receiver for actions chosen from Zoop's Home Screen icon menu.
    @EnvironmentObject private var homeScreenQuickActions: HomeScreenQuickActionSceneDelegate

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// The Coach chat, raised by the Coach button in the tab bar.
    @State private var showCoach = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int = 0
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute`/`MoreDestination` VALUES — closure-destination links bypass the path.
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: IOSTab.count)
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: IOSTab.count)
    /// V8 liquid redesign is the default Today; the Settings toggle lets a user fall back to the classic
    /// Today if they prefer it (keyed identically to the SettingsView toggle). Default ON.
    @AppStorage("zoop.liquidTodayEnabled") private var liquidTodayEnabled = true

    /// The Today tab root, honouring the liquid/classic preference.
    @ViewBuilder private var todayTabRoot: some View {
        if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
    }

    /// Native tab selection binding. SwiftUI sends taps on the already-selected item through the
    /// setter, which lets the system tab bar retain the app's refresh / pop-to-root / scroll-to-top
    /// convention without placing a custom hit-testing layer over the platform bar.
    private var nativeTabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tag in
                // Coach is not a destination: its button raises the chat sheet over whatever is open.
                if tag == IOSTab.coach {
                    showCoach = true
                } else if tag == selectedTab {
                    reselectTab(tag)
                } else {
                    selectedTab = tag
                    // A page always opens at its top, not wherever it was left.
                    if tabPaths[tag].isEmpty { scrollTop[tag] += 1 }
                }
            }
        )
    }

    private func reselectTab(_ tag: Int) {
        Task { await repo.refresh() }
        if !tabPaths[tag].isEmpty {
            tabPaths[tag] = NavigationPath()
        } else {
            scrollTop[tag] += 1
        }
    }

    /// The platform tab bar is intentionally left native. iOS 26 supplies Liquid Glass and its
    /// interaction with scrolling content; older releases use the system material from the same
    /// TabView.
    ///
    /// The tags stay LITERAL rather than being renumbered when Coach is absent: `tabPaths` and
    /// `scrollTop` are indexed by tag, so a wearer's More tab keeps its identity, navigation path and
    /// scroll position across a Coach flip instead of inheriting Coach's.
    @ViewBuilder private var tabShell: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: nativeTabSelection) {
                // Icon-only items, as in the concept; the name stays as the spoken label.
                Tab(value: IOSTab.home) {
                    tabStack(todayTabRoot, path: $tabPaths[IOSTab.home], scrollSignal: scrollTop[IOSTab.home])
                } label: { iconLabel("Home", "house") }
                Tab(value: IOSTab.health) {
                    tabStack(HealthView(), path: $tabPaths[IOSTab.health], scrollSignal: scrollTop[IOSTab.health])
                } label: { iconLabel("Health", "heart") }
                Tab(value: IOSTab.trends) {
                    tabStack(TrendsView(), path: $tabPaths[IOSTab.trends], scrollSignal: scrollTop[IOSTab.trends])
                } label: { iconLabel("Trends", "chart.xyaxis.line") }
                Tab(value: IOSTab.more) {
                    moreStack(path: $tabPaths[IOSTab.more], scrollSignal: scrollTop[IOSTab.more])
                } label: { iconLabel("More", "line.3.horizontal") }
                // A role is what moves Coach into its own round button at the trailing end of the bar,
                // apart from the four destinations. Hidden rather than left out when Coach is off, so
                // the tab keeps its tag and path.
                Tab(value: IOSTab.coach, role: Self.coachTabRole) {
                    // Never shown: selecting this tab opens `CoachChatSheet` instead (see `nativeTabSelection`).
                    Color.clear
                } label: { iconLabel("Coach", "sparkles") }
                .hidden(!coachEnabled)
            }
        } else {
            TabView(selection: nativeTabSelection) {
                tab(todayTabRoot, "Home", "house", path: $tabPaths[IOSTab.home], scrollSignal: scrollTop[IOSTab.home]).tag(IOSTab.home)
                tab(HealthView(), "Health", "heart", path: $tabPaths[IOSTab.health], scrollSignal: scrollTop[IOSTab.health]).tag(IOSTab.health)
                tab(TrendsView(), "Trends", "chart.xyaxis.line", path: $tabPaths[IOSTab.trends], scrollSignal: scrollTop[IOSTab.trends]).tag(IOSTab.trends)
                moreStack(path: $tabPaths[IOSTab.more], scrollSignal: scrollTop[IOSTab.more])
                    .tabItem { Label("More", systemImage: "line.3.horizontal") }
                    .tag(IOSTab.more)
                if coachEnabled {
                    tab(CoachView(), "Coach", "sparkles", path: $tabPaths[IOSTab.coach], scrollSignal: scrollTop[IOSTab.coach]).tag(IOSTab.coach)
                }
            }
        }
    }

    /// A transparent tap target laid exactly over the system Coach button. A system tab is drawn as
    /// selected (its empty content filling the screen) before the selection binding can refuse it, which
    /// flashed black on every tap. Catching the touch above the bar opens the sheet without the tab ever
    /// being selected; the binding's own redirect stays as the path VoiceOver takes.
    private var coachButton: some View {
        Color.clear
            .frame(width: 66, height: 66)
            .contentShape(Circle())
            .onTapGesture { showCoach = true }
            .accessibilityHidden(true)
            .padding(.trailing, 19)
            .padding(.bottom, 19)
            .ignoresSafeArea(.container, edges: .bottom)
            .sensoryFeedback(.impact(weight: .light), trigger: showCoach)
    }

    /// A tab item that shows only its glyph; the title is still read by VoiceOver.
    private func iconLabel(_ title: LocalizedStringKey, _ icon: String) -> some View {
        Image(systemName: icon).accessibilityLabel(Text(title))
    }

    /// iOS 27's prominent role draws a separate accented button; earlier releases separate the
    /// search role instead.
    @available(iOS 18.0, *)
    private static var coachTabRole: TabRole {
        // `.prominent` exists only in the iOS 27 SDK (Swift 6.4 / Xcode 27); an Xcode 26 build, such as a
        // CI runner without Xcode 27, must not even see the symbol.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        return .search
    }

    var body: some View {
        tabShell
        .overlay(alignment: .bottomTrailing) {
            if coachEnabled, #available(iOS 18.0, *) { coachButton }
        }
        // The selected tab reads white, as in the reference; colour is kept for the data.
        .tint(StrandPalette.textPrimary)
        // Switching Coach off while STANDING on it leaves `selectedTab` pointing at a tag no tab claims
        // any more, which renders as an empty tab rather than as an error. Send that wearer to Today, and
        // only in that case, so a flip made from anywhere else does not move them.
        .onChangeCompat(of: coachEnabled) { enabled in
            if !enabled && selectedTab == IOSTab.coach { selectedTab = IOSTab.home }
        }
        // #1841: the same "Hide bar when scrolling" preference Android drives its own bar with. Here the
        // system owns the behaviour — iOS 26's tab bar MINIMISES to a pill on scroll down rather than
        // sliding away entirely, so this is the platform's read of the same intent, not a copy of ours.
        .noopTabBarAutoHide(bottomBarAutoHide)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1).
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
            // Tabs change only from the tab bar. A horizontal drag used to step between Today, Trends,
            // Sleep, Coach and More, which fought day-swipes, charts and the back gesture. The system
            // back swipe on a pushed screen stays; it is not a tab change.
        .task {
            await repo.refresh()
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
                .presentationDetents([.fraction(0.75), .large])
                .presentationDragIndicator(.visible)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
                .presentationDetents([.fraction(0.75), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCoach) {
            CoachChatSheet()
        }
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
                .presentationDetents([.fraction(0.75), .large])
                .presentationDragIndicator(.visible)
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .alarms:
                routedPillar = dest
                router.requestedDestination = nil
            case .coach:
                // K3: Coach is now a top-level tab (tag 3) — switch to it directly instead of
                // presenting it as a pillar sheet.
                //
                // Guarded on the master switch, because this route is reachable with Coach OFF. A brief
                // notification already sitting in Notification Centre still calls `openCoach()` when it is
                // tapped (StrandApp wires `onCoachBriefTapped` to it), and with no tab claiming tag 3 the
                // wearer would land on a BLANK tab. Dropping the request leaves them where they were, which
                // is the honest answer for a feature that is switched off.
                guard coachEnabled else {
                    router.requestedDestination = nil
                    break
                }
                showCoach = true
                router.requestedDestination = nil
            case .trends:
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = IOSTab.trends }
                tabPaths[IOSTab.trends] = NavigationPath()
                router.requestedDestination = nil
            case .activeWorkout:
                // The Today active-workout indicator opens Live through the quick-action Live sheet; once
                // it's up, LiveView consumes the one-shot `presentActiveWorkout` flag and presents the
                // in-exercise screen. Calm sheet easing, matching the other quick-action presents.
                withAnimation(Self.sheetEase) { quickAction = .live }
                router.requestedDestination = nil
            case .liveSession:
                // Live Sessions is presented from Today's own Start entry (a cover, not a routed sheet),
                // so a deep-link lands on the Today tab where that entry lives.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                router.requestedDestination = nil
            case .journal:
                // The #627 Today logbook widget opens the quick-action Logbook sheet (LogbookView),
                // matching the FAB's "Fill in logbook" action. Calm sheet easing.
                withAnimation(Self.sheetEase) { quickAction = .journal }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // A tapped notification: go to Home and push the screen it is about on top of a fresh Home stack.
        .onChange(of: router.notificationTarget) { _, target in
            guard let target else { return }
            showCoach = false
            quickAction = nil
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = IOSTab.home }
            var path = NavigationPath()
            if case .route(let route) = target { path.append(route) }
            tabPaths[IOSTab.home] = path
            router.notificationTarget = nil
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
        // A cold-launch selection is already pending when this shell appears; a warm selection arrives
        // through the change callback. Both route through the same screens as the centre FAB.
        .onAppear {
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActions.pendingAction) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActionsEnabled) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
        // The running gym session, reachable from ANY tab. It sits above the tab bar rather than
        // inside the Lift Log screen, because a workout outlives whichever screen you wandered to —
        // and because swiping the sheet away must minimise the session, not end it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if liftSession.isActive {
                LiftSessionBar()
                    .padding(.horizontal, 14)
                    // Clear the floating tab bar with the same constant every screen uses, or the
                    // session bar sits on top of the tab labels.
                    .padding(.bottom, ZoopMetrics.tabBarClearance)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: liftSession.isActive)
        // A session left running by a previous launch is back before this view exists
        // (`LiftSessionController.resumeSaved`, from `StrandiOSApp.init`), as the BAR — not as a sheet
        // thrown in the user's face; they open it when they want it.
        .sheet(isPresented: $liftSession.isPresented) {
            LiftSessionView { }
        }
    }

    /// Mandatory launch gates defer an external action. Once the shell is available, an explicit Home
    /// Screen choice supersedes any ordinary shell sheet; choosing the already-open destination simply
    /// consumes the request and leaves that screen in place.
    private func presentPendingHomeScreenQuickActionIfPossible() {
        guard homeScreenQuickActionsEnabled,
              let action = homeScreenQuickActions.pendingAction else { return }

        let destination: QuickAction = switch action {
        case .liveHeartRate: .live
        case .startWorkout: .workout
        case .logJournal: .journal
        case .breathe: .breathe
        }
        homeScreenQuickActions.consume(action)
        withAnimation(Self.sheetEase) {
            showDevices = false
            routedPillar = nil
            quickAction = destination
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // .trends is never presented as a pillar sheet on iPhone (it's a primary tab — the
                // requestedDestination handler switches `selectedTab` instead), but the switch must stay
                // exhaustive. Fall back to Trends inside the sheet host if it ever arrives here.
                case .trends: TrendsView()
                // .activeWorkout routes through the quick-action Live sheet (handled above); this keeps the
                // switch exhaustive and falls back to Live if it ever reaches the pillar host.
                case .activeWorkout: LiveView()
                // .liveSession routes to the Today tab (handled above — its Start entry owns the cover);
                // this keeps the switch exhaustive and falls back to Today if it ever reaches the host.
                case .liveSession: LiquidTodayView()
                // .journal opens through the quick-action Logbook sheet (handled above); this keeps the
                // switch exhaustive and falls back to the Logbook if it ever reaches here.
                case .journal: LogbookView(onClose: { routedPillar = nil })
                // .coach switches to the Coach tab (handled above — the morning-brief tap-through and the
                // #1862 launcher both arrive that way, the launcher's question riding on
                // `AICoachEngine.pendingPrompt`); this keeps the switch exhaustive and falls back to Coach if
                // it ever reaches the host.
                case .coach: CoachView()
                case .alarms: SmartAlarmView()
                }
            }
            // The Trends/Today fallbacks above emit TabRoute value pushes (#198), which need a
            // destination registered in THIS sheet's stack to resolve.
            .tabRouteDestinations()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // #1027: same fix as quickScreen — the pillar screens draw the full-bleed liquid sky, so a
            // transparent nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
                }
            }
            .presentationDetents([.height(344)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(LogbookView(onClose: { quickAction = nil }))
        case .breathe:
            quickScreen(BreathingView())
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: same fix as quickScreen — Devices draws the full-bleed liquid sky, so a transparent
                // nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        tabStack(view, path: path, scrollSignal: scrollSignal)
            .tabItem { Label(title, systemImage: icon) }
    }

    private func tabStack<V: View>(_ view: V, path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        NavigationStack(path: path) {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .tabRouteDestinations()
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
    }

    // The "More" tab is the app's catch-all index. It was a plain SwiftUI `List` with system large-title
    // + system title-case section headers, so it didn't match any other page (which all use ScreenScaffold
    // + SectionHeader's UPPERCASE overline + the 28pt section rhythm). Rebuilt on the shared page chrome:
    // ScreenScaffold for the title1 "More" + subtitle, a `SectionHeader` overline per group, and the group's
    // rows in a single grouped ZoopCard with hairline dividers — the same row idiom Settings/Health use.
    private func moreStack(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           quietSubtitle: true,
                           onRefresh: { await repo.refresh() },
                           topBackground: liquidScaffoldSky()) {
                MoreDeviceHeader()
                moreSection("Body") {
                    MoreRow("Sleep", "bed.double.fill", .sleep, subtitle: "Stages, debt and consistency")
                    MoreRow("Workouts", "figure.run", .workouts, subtitle: "Sessions, zones and routes")
                    MoreRow("Stress", "bolt.heart.fill", .stress, subtitle: "Load across your day")
                    MoreRow("Live", "waveform.path.ecg", .live, subtitle: "Heart rate in real time")
                    MoreRow("Lift Log", "dumbbell.fill", .liftLog, subtitle: "Programs and sets")
                    MoreRow("Breathe", "wind", .breathe, subtitle: "Guided breathing")
                    MoreRow("Intervals", "timer", .intervals, subtitle: "Haptic interval timer")
                    MoreRow("Lab Book", "books.vertical.fill", .labBook, subtitle: "Experiments on yourself")
                    MoreRow("Rhythm", "waveform.path", .rhythm, subtitle: "Beat-to-beat timing")
                }
                moreSection("Insights") {
                    MoreRow("Patterns", "chart.bar.doc.horizontal.fill", .patterns, subtitle: "Tonight, tomorrow and your habits")
                    MoreRow("What Moves You", "wand.and.sparkles", .insightsHub, subtitle: "What changes your scores")
                    MoreRow("Intelligence", "brain.head.profile", .intelligence, subtitle: "Patterns across your history")
                    MoreRow("Insights", "lightbulb.fill", .insights, subtitle: "Logbook and correlations")
                    MoreRow("Explore", "square.grid.2x2.fill", .explore, subtitle: "Every metric, every range")
                    MoreRow("Compare", "rectangle.split.2x1.fill", .compare, subtitle: "Metrics side by side")
                }
                moreSection("Data") {
                    MoreRow("Data Sources", "externaldrive.fill", .dataSources, subtitle: "Where each number comes from")
                    MoreRow("Your Data, Fused", "square.stack.3d.up.fill", .fusedRecord, subtitle: "One record from every source")
                    MoreRow("Apple Health", "heart.fill", .appleHealth, subtitle: "Import and write-back")
                    MoreRow("Mi Band", "figure.walk.motion", .miBand, subtitle: "Steps and heart rate")
                    MoreRow("Backup & Sync", "externaldrive.fill.badge.icloud", .backupSync, subtitle: "Back up and restore")
                    MoreRow("Shortcuts Export", "square.and.arrow.up.fill", .shortcutsExport, subtitle: "Send data to Shortcuts")
                    MoreRow("Zoop Limitations", "list.bullet.rectangle", .noopLimitations, subtitle: "What is not measured yet")
                }
                moreSection("App") {
                    MoreRow("Settings", "gearshape.fill", .settings, subtitle: "Profile, units and appearance")
                    MoreRow("Alarms", "alarm.fill", .alarms, subtitle: "Strap alarm and wind-down")
                    MoreRow("Automations", "wand.and.stars", .automations, subtitle: "Alerts and reminders")
                    MoreRow("Power saving", "battery.25", .powerSaving, subtitle: "Ease the strap's battery")
                    MoreRow("Siri & Shortcuts", "mic.fill", .siriShortcuts, subtitle: "Voice and automation")
                    MoreRow("Test Centre", "stethoscope", .testCentre, subtitle: "Diagnostics and logs")
                }
            }
            // The rows push MoreDestination VALUES so a re-tap of the More tab can pop them off the
            // bound path (#135/#198). Each destination keeps the per-screen wrapper the rows used to
            // apply inline (surfaceBase background, inline title bar, hidden bar background):
            // #1027 — a pushed sky-scaffold screen (Live, Workouts, Health, …) draws a full-bleed liquid
            // sky; an opaque surfaceBase nav-bar band sat over it and clipped the top on scroll. A hidden
            // bar background keeps the sky edge-to-edge. On the flat (no-sky) screens this is visually
            // identical at rest — the destination's own surfaceBase background shows through the bar.
            .navigationDestination(for: MoreDestination.self) { route in
                route.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
    }

    /// One group in the More index: a small grey label over the group's rows in a single card. Every
    /// group is always open, so the whole index reads at a glance.
    @ViewBuilder
    private func moreSection<Rows: View>(_ title: LocalizedStringKey,
                                         @ViewBuilder rows: @escaping () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { rows() }
                .background(ZoopPanelSurface())
                .clipShape(RoundedRectangle(cornerRadius: ZoopMetrics.cardRadius, style: .continuous))
        }
    }
}

private enum MoreDestination: Hashable {
    case patterns, insightsHub, intelligence, coach, insights, explore, compare
    case sleep, trends, live, workouts, liftLog, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, testCentre, siriShortcuts, powerSaving, settings

    @ViewBuilder var destination: some View {
        switch self {
        case .patterns:        PatternsScreen()
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .sleep:           SleepView()
        case .trends:          TrendsView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .liftLog:         LiftLogView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .noopLimitations: ZoopLimitationsView()
        case .backupSync:      BackupSyncView()
        case .shortcutsExport: ShortcutExportSettingsView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .powerSaving:     PowerSavingView()
        case .settings:        SettingsView()
        }
    }
}


/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol icon tinted `StrandPalette.accent`, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target.
private struct MoreRow: View {
    let title: LocalizedStringKey
    let icon: String
    let route: MoreDestination
    let subtitle: LocalizedStringKey?

    init(_ title: LocalizedStringKey, _ icon: String, _ route: MoreDestination, subtitle: LocalizedStringKey? = nil) {
        self.title = title; self.icon = icon; self.route = route; self.subtitle = subtitle
    }

    var body: some View {
        NavigationLink(value: route) {
            ZoopIconRow(title, subtitle: subtitle, icon: icon)
                .overlay(alignment: .bottom) {
                    // Hairline between rows, inset to the text; the card clips the last one.
                    Rectangle()
                        .fill(StrandPalette.hairline)
                        .frame(height: 1)
                        .padding(.leading, 68)
                }
        }
        .buttonStyle(.plain)
    }
}

/// The More index's header card: the profile picture beside the active strap's connection, battery and
/// last sync, tapping through to Devices.
private struct MoreDeviceHeader: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter

    private var status: String {
        guard live.connected else { return String(localized: "Not connected") }
        if let pct = live.batteryPct {
            return String(localized: "Connected · \(Int(pct.rounded()))%")
        }
        return String(localized: "Connected")
    }

    private var syncLine: String {
        guard let t = live.lastSyncedAt else { return String(localized: "Not synced yet") }
        let when = Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named))
        return String(localized: "Last sync \(when)")
    }

    var body: some View {
        Button { router.openDevices() } label: {
            HStack(spacing: 14) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: 52)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(live.connected ? StrandPalette.accent : StrandPalette.textTertiary)
                            .frame(width: 8, height: 8)
                        Text(status)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text(syncLine)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoopPanelSurface())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(status). \(syncLine). Opens Devices."))
    }
}

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor) { onPick(.workout) }
                row("Fill in logbook", icon: "square.and.pencil", tint: StrandPalette.accent) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZoopChromeSurface()
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border.
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(StrandPalette.surfaceInset))
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(ZoopPanelSurface(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif

/// #1841: apply the iOS 26 tab-bar minimise behaviour, doing nothing on older systems.
///
/// The availability branch is deliberately the ONLY branch. `RootTabView` already documents what happens
/// when a condition that flips at runtime wraps this `TabView`: #519 put two states in separate
/// `_ConditionalContent` branches, and every navigation rebuilt the whole subtree, resetting `@State`
/// inside the tab roots — scroll offsets, chart ranges, expanded sections.
///
/// So the preference must NOT select between branches. It selects the modifier's ARGUMENT, while the
/// availability check — fixed for the life of the process — is what picks a branch. Toggling the setting
/// changes a value, never the view's identity.
extension View {
    @ViewBuilder
    func noopTabBarAutoHide(_ enabled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            // `.onScrollDown` minimises to a pill on downward scroll; `.never` pins it fully visible.
            self.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            self
        }
    }
}
