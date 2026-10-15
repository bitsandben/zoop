import SwiftUI
import StrandDesign
import UserNotifications

@main
struct StrandApp: App {
    init() {
        LocalSettingsArchive.restoreIfEmpty()
        AppLanguage.installAtLaunch()
        // Pin the Overnight-only continuous-HRV default for existing installs before anything reads it (#1008). Idempotent.
        PuffinExperiment.migrateContinuousHrvOvernightDefault()
        // Clear preferences whose Settings controls were removed, so none is stuck on.
        SettingsMigration.run()
        #if DEBUG
        // DEBUG-only promo-screenshot harness: `--demo-hour <Int>` pins Today to that hour's scene. No-op when
        // the arg is absent. See DemoDayHarness.swift.
        DemoDayHarness.applyLaunchArgsIfNeeded()
        // DEBUG-only: `--demo-sync` drives the Today header's charge-to-sync control with synthetic data. See DemoSyncHarness.swift.
        DemoSyncHarness.applyLaunchArgsIfNeeded()
        #endif
        // Without a delegate macOS suppresses a notification banner while the app is frontmost.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        // Tapping a scheduled morning-brief notification routes to Coach via the shared NavRouter.
        let router = NavRouter()
        _router = StateObject(wrappedValue: router)
        NotificationPresenter.shared.onCoachBriefTapped = { [weak router] in router?.openCoach() }
        LocalSettingsArchive.snapshot()
    }

    @StateObject private var model = AppModel()
    /// Shared cross-screen navigation hook; the macOS shell (`RootView`) drives the sidebar from it.
    @StateObject private var router: NavRouter
    /// Drives a foreground sync kick when the window becomes active.
    @Environment(\.scenePhase) private var scenePhase
    /// Appearance preference (System/Light/Dark); defaults to the OS.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// Chart data-colour style; re-colours gauges and charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    /// Chrome accent colour only, never the data colour worlds.
    @AppStorage(AccentColor.storageKey) private var accentRaw = AccentColor.mint.rawValue
    @AppStorage(AccentColor.customHexKey) private var accentCustomHex = AccentColor.defaultCustomHex

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.ble)   // #334: Today pull-to-sync reads BLEManager (no HR churn)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                // Shared stress check-in nudge surface, so Breathe observes the same instance the central detector posts to.
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .frame(minWidth: 1000, minHeight: 700)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                // Keep date/number words on the same bundle language as localized strings; a pending Settings change
                // becomes active only after the documented reopen.
                .environment(\.locale, AppLanguage.activeLocale)
                .chartStyle(chartStyleRaw)
                .noopAccent(accentRaw, customHex: accentCustomHex)
                // Cap Dynamic Type at accessibility1 so fixed-geometry tiles/gauges do not clip.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                // Pull a fresh sync on foreground instead of waiting for the 900s timer. Floored at 90s and never
                // suppressed (BackfillPolicy.shouldRun `.foreground`). Single-param onChange form: the two-param overload needs macOS 14.
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.ble.requestSync(.foreground) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        // Menu-bar extra: live HR and a compact popover.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
                .environment(\.locale, AppLanguage.activeLocale)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
                .environment(\.locale, AppLanguage.activeLocale)
        }
        .menuBarExtraStyle(.window)
    }
}
