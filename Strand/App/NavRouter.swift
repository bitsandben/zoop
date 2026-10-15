import SwiftUI
import Combine

// MARK: - NavRouter
// Shared navigation hook so a screen can ask the app shell to open another top-level destination without
// knowing how the shell is built (macOS `NavigationSplitView` in `RootView`, iOS `TabView` in
// `RootTabView`). Each consumer clears the request once handled. Injected at both app roots as an
// `@EnvironmentObject`.
/// A `zoop://<host>` link that lands on a tab or screen. Other hosts (`import-health`, ...) belong to
/// other handlers and parse to nil here so they are never swallowed.
enum DeepLink: String, CaseIterable {
    case today, recovery, sleep, stress, fasting, training, insights, sync

    init?(url: URL) {
        guard url.scheme?.lowercased() == "zoop", let host = url.host?.lowercased() else { return nil }
        self.init(rawValue: host)
    }
}

@MainActor
final class NavRouter: ObservableObject {
    /// A top-level destination a screen can ask the shell to open.
    enum Destination: String, Equatable, Identifiable {
        case devices
        case insightsHub
        case labBook
        case fusedRecord
        case rhythm
        case trends
        case activeWorkout
        case liveSession
        case journal
        /// The Coach screen, opened from the Today Coach launcher or the scheduled morning-brief notification.
        /// The launcher owns no send/stream/consent surface; it hands the question to this screen (#1862).
        case coach
        case alarms

        var id: String { rawValue }

        /// Map a stored `UpdateItem.deepLink` route key to a Destination; nil for unknown keys.
        init?(deepLinkKey: String) {
            self.init(rawValue: deepLinkKey)
        }
    }

    /// The destination a screen has asked the shell to open; the shell resets it to nil once handled.
    @Published var requestedDestination: Destination?

    /// Set when a top-bar "+" asks the shell to open the quick-action sheet; the shell resets it.
    @Published var quickActionsRequested = false

    /// One-shot: `LiveView` reads this on appear to present the in-exercise screen for an already-running
    /// workout (routing alone only reaches the Live root), then clears it.
    @Published var presentActiveWorkout = false

    /// A `zoop://` link waiting for the shell; held so a cold-launch link survives until first-run gates are done.
    @Published var pendingDeepLink: DeepLink?

    @Published var notificationTarget: NotificationTarget?

    func open(_ target: NotificationTarget) { notificationTarget = target }

    /// One-shot: Home presents the detected-workout sheet, then clears this.
    @Published var autoWorkoutSheetRequested = false

    func requestQuickActions() { quickActionsRequested = true }

    func openDevices() { requestedDestination = .devices }
    func openCoach() { requestedDestination = .coach }
    func openAlarms() { requestedDestination = .alarms }
    func openInsightsHub() { requestedDestination = .insightsHub }
    func openLabBook() { requestedDestination = .labBook }
    func openFusedRecord() { requestedDestination = .fusedRecord }
    func openRhythm() { requestedDestination = .rhythm }
    /// Open the active workout: route to Live and raise the one-shot flag, consumed by
    /// `LiveView.consumeActiveWorkoutRequest()`.
    func openActiveWorkout() { presentActiveWorkout = true; requestedDestination = .activeWorkout }
    /// Journal day-offset (daysBack; -1 = Tomorrow) the Today journal widget deep-linked to; `InsightsView`
    /// consumes it on appear and clears it. nil opens at today.
    @Published var pendingJournalDayOffset: Int?

    /// Open the journal (hosted in the classic Insights screen), optionally at a specific day offset (nil = today).
    func openJournal(day offset: Int? = nil) {
        pendingJournalDayOffset = offset
        requestedDestination = .journal
    }
}
