#if os(iOS)
import AppIntents
import Foundation
import WhoopStore

// MARK: - Shortcuts / Siri: start and end a fast
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
        return .result(dialog: IntentDialog(FastingStrings.intentStopped(duration)))
    }
}
#endif
