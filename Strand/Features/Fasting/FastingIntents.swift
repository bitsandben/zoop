#if os(iOS)
import AppIntents
import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Shortcuts / Siri: start a fast, end it (opening the eating window), ask where the cycle stands
//
// Run inside Zoop's process without opening it (the SyncStrapIntent idiom), and write through
// `FastingLog`, the same path the screen uses, so the reminder follows either way. A background launch
// may not have built the AppModel yet, so the store is awaited briefly instead of failing at once.

@MainActor
private func fastingStore(waitSeconds: Int = 5) async -> WhoopStore? {
    for _ in 0..<waitSeconds {
        if let model = AppModel.shared { return await model.repo.storeHandle() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return await AppModel.shared?.repo.storeHandle()
}

struct StartFastIntent: AppIntent {
    static var title = LocalizedStringResource("zoop.fasting.intent.start.title", defaultValue: "Start Fast")
    static var description = IntentDescription(LocalizedStringResource(
        "zoop.fasting.intent.start.description", defaultValue: "Start a fast in Zoop with your current plan."))
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = await fastingStore() else { return .result(dialog: IntentDialog(FastingStrings.intentUnavailable)) }
        let now = Date()
        let row = try await FastingLog.start(store: store, at: now, now: now, source: .shortcut)
        return .result(dialog: IntentDialog(row == nil ? FastingStrings.intentAlreadyRunning : FastingStrings.intentStarted))
    }
}

struct EndFastIntent: AppIntent {
    static var title = LocalizedStringResource("zoop.fasting.intent.stop.title", defaultValue: "End Fast")
    static var description = IntentDescription(LocalizedStringResource(
        "zoop.fasting.intent.stop.description", defaultValue: "End the fast that is running in Zoop."))
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = await fastingStore() else { return .result(dialog: IntentDialog(FastingStrings.intentUnavailable)) }
        guard let row = try await FastingLog.stop(store: store, at: Date()), let end = row.endTs else {
            return .result(dialog: IntentDialog(FastingStrings.intentNotRunning))
        }
        let duration = FastingFormat.duration(TimeInterval(end - row.startTs))
        let rows = await FastingLog.load(store: store, now: Date())
        guard case .eating(let window) = FastingLog.state(rows, now: Date()) else {
            return .result(dialog: IntentDialog(FastingStrings.intentStopped(duration)))
        }
        return .result(dialog: IntentDialog(FastingStrings.intentStoppedWindow(
            duration, FastingFormat.time(window.closes))))
    }
}

struct FastingStatusIntent: AppIntent {
    static var title = LocalizedStringResource("zoop.fasting.intent.status.title", defaultValue: "Fasting Status")
    static var description = IntentDescription(LocalizedStringResource(
        "zoop.fasting.intent.status.description", defaultValue: "Say whether you are fasting or in your eating window."))
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = await fastingStore() else { return .result(dialog: IntentDialog(FastingStrings.intentUnavailable)) }
        let now = Date()
        let rows = await FastingLog.reconcile(store: store, now: now)
        return .result(dialog: IntentDialog(Self.line(FastingLog.state(rows, now: now), now: now)))
    }

    /// One sentence for the phase, from the same state the screen and Today read.
    static func line(_ state: FastingCycleState, now: Date) -> LocalizedStringResource {
        switch state {
        case .fasting(_, let s):
            return s.goalReached ? FastingStrings.intentStatusGoalReached(FastingFormat.duration(s.elapsed))
                : FastingStrings.intentStatusFasting(FastingFormat.duration(s.elapsed), FastingFormat.time(s.goalDate))
        case .eating(let w):
            return FastingStrings.windowClosesIn(FastingFormat.duration(w.remaining(now: now)))
        case .due:
            return FastingStrings.timeToFast
        case .waiting(let next):
            return next.map { FastingStrings.nextFastAt(FastingFormat.dayAndTime($0)) } ?? FastingStrings.intentNotRunning
        }
    }
}
#endif
