#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The Today tab (§3.1): how ready you are, what the day holds, and what matters right now. Layout only;
/// everything shown comes from `TodayModel`.
struct TodayScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(RecoveryCalibrationStore.enabledKey) private var calibrationEnabled = false
    @AppStorage(TodayDashboardPrefs.storageKey) private var dashboardTilesRaw = ""

    @State private var model = TodayModel()
    @State private var explained: MetricReadout?
    @State private var sheet: TodaySheet?
    @State private var napEditHaptic = 0
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    private static let topID = "today.top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                    header.id(Self.topID)
                    if let content = model.content { TodayContentStack(content: content, actions: actions) }
                }
                .padding(.horizontal, ZoopSpacing.gutter)
                .padding(.top, ZoopSpacing.xs)
                // The tab bar already insets the scroll content by its own height; this only leaves
                // a little air under the last card.
                .padding(.bottom, ZoopSpacing.l)
                // The page is exactly as wide as the screen, whatever a card asks for. A card wider
                // than the viewport (the rings at large text sizes, long German labels) otherwise made
                // the scroll content wider than the screen: the page sat off-centre and could be
                // dragged sideways, rubber-banding back while the day swipe stepped the day.
                .containerRelativeFrame(.horizontal)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .refreshable { await syncAndRefresh() }
            .background { background }
            .simultaneousGesture(daySwipe)
            .sensoryFeedback(.selection, trigger: model.dayOffset)
            .sensoryFeedback(.impact(weight: .medium), trigger: napEditHaptic)
            .onChange(of: scrollToTopSignal) { _, _ in
                withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
            #if DEBUG
            // Screenshot harness: `-zoopTodayDayOffset N` opens N days back and `-zoopTodayScrollTo
            // myDay|dashboard` lands on that section once loaded.
            .onChange(of: model.content == nil) { _, _ in
                let offset = UserDefaults.standard.integer(forKey: "zoopTodayDayOffset")
                if offset > 0, model.dayOffset == 0 { model.select(offset) }
                guard let anchor = UserDefaults.standard.string(forKey: "zoopTodayScrollTo") else { return }
                Task { try? await Task.sleep(for: .seconds(1)); proxy.scrollTo(anchor, anchor: .top) }
            }
            #endif
        }
        .task(id: loadKey) { await model.load(environment) }
        .task(id: model.dayOffset) { await refreshLiveWhileOpen() }
        .onChange(of: scenePhase) { old, new in
            if old == .background, new != .background { model.returnToToday() }
        }
        .onChange(of: router.autoWorkoutSheetRequested) { _, _ in presentRequestedDetectedWorkout() }
        .onChange(of: model.content?.activities) { _, _ in presentRequestedDetectedWorkout() }
        .sheet(item: $explained) { readout in
            MetricExplainerSheet(readout, explanation: model.explanation(for: readout))
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $sheet, onDismiss: { Task { await model.load(environment) } }) { sheet in
            TodaySheetContent(sheet: sheet, onDetectedHandled: model.removeDetectedWorkout,
                              dashboardTiles: $dashboardTilesRaw)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            TodayHeader(dayOffset: model.dayOffset, today: Repository.logicalDay(Date()),
                        onSelectDay: { offset in withAnimation(StrandMotion.interactive) { model.select(offset) } },
                        onProfile: { sheet = .settings },
                        onQuickActions: { router.requestQuickActions() })
            TodayStatusLine { router.openDevices() }
        }
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            StrandPalette.surfaceBase
            if backgroundStore.isActive { BackgroundImageBackdrop() }
        }
        .ignoresSafeArea()
    }

    private var actions: TodayContentStack.Actions {
        TodayContentStack.Actions(
            explain: { explained = $0 },
            openActivity: openActivity,
            editNap: { item in
                guard let nap = item.nap else { return }
                napEditHaptic &+= 1
                sheet = .napEdit(nap)
            },
            startCheckIn: { model.acceptCheckInInvite(); calibrationEnabled = true },
            dismissCheckIn: model.dismissCheckInInvite,
            answerCheckIn: { sheet = .checkIn },
            quickActions: { router.requestQuickActions() },
            customiseDashboard: { sheet = .customiseDashboard })
    }

    private func openActivity(_ item: TodayActivity) {
        if let detected = item.detected { sheet = .detected(detected) }
        else if let workout = item.workout { sheet = .workout(workout) }
        else if let nap = item.nap { sheet = .nap(nap) }
    }

    // MARK: Loading

    private var environment: TodayEnvironment {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return TodayEnvironment(repo: repo, profile: profile,
                                whoopScale: UnitPrefs.resolveEffortScale(effortScaleRaw) == .whoop,
                                temperatureUnit: UnitPrefs.resolveTemperature(system: system, override: temperatureRaw),
                                dayCycleMode: DayCycleMode.persisted(dayCycleModeRaw),
                                dashboardTiles: TodayDashboardPrefs.decode(dashboardTilesRaw))
    }

    private var loadKey: String {
        "\(repo.refreshSeq)-\(model.dayOffset)-\(dayCycleModeRaw)-\(effortScaleRaw)-\(calibrationEnabled)-\(dashboardTilesRaw)"
    }

    /// The stress tile, the moment card and the Energy Bank follow the day while Today is open.
    private func refreshLiveWhileOpen() async {
        guard model.dayOffset == 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await model.refreshLive(environment)
        }
    }

    /// A pull asks the strap for its stored history; the status line reports how that goes.
    private func syncAndRefresh() async {
        if ble.state.historyReady { ble.syncNow() }
        let seq = repo.refreshSeq
        await repo.refresh()
        if repo.refreshSeq == seq { await model.load(environment) }
    }

    /// A tapped "Workout detected" notification opens its sheet once the candidate is loaded.
    private func presentRequestedDetectedWorkout() {
        guard router.autoWorkoutSheetRequested,
              let detected = model.content?.activities.first(where: { $0.kind == .detected })?.detected else { return }
        router.autoWorkoutSheetRequested = false
        sheet = .detected(detected)
    }

    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50, !ZoopChartScrubState.isActiveOrRecent else { return }
                withAnimation(StrandMotion.interactive) { model.step(TodayLogic.daySwipeDelta(dx: dx)) }
            }
    }
}
#endif
