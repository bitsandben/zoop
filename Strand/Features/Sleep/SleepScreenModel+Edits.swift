import Foundation
import SwiftUI
import StrandAnalytics
import WhoopStore

/// The night (or nap) a sleep-time edit writes against. Its detected `startTs` is the stored key and
/// never moves, so it doubles as the sheet identity.
struct SleepEditRequest: Identifiable {
    let detectedStartTs: Int
    let bedTs: Int
    let wakeTs: Int
    let stagesJSON: String?
    /// Hand-edited and added rows are never re-detected, so deleting them writes no tombstone and the
    /// confirmation must not promise one.
    let userEdited: Bool
    /// Only a main night's start correction teaches the onset offset; a nap never does.
    let isMainNight: Bool
    var id: Int { detectedStartTs }

    /// The recorded coverage the editor guards against: from the detected onset (or an earlier
    /// hand-set one) to the current wake. A window outside it has no data to stage from.
    var coverage: ClosedRange<Int> {
        let lo = min(detectedStartTs, bedTs)
        return lo...max(wakeTs, lo + 1)
    }
}

/// Seeds the "add a nap" picker: 30 minutes, an hour after the night's wake.
struct SleepNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    var id: Int { bedTs }
}

/// The transient undo strip after a delete. `identityStart` is the stored key, so a stale auto-dismiss
/// can tell whether it still owns the banner.
struct SleepUndo {
    let snapshot: SleepDeletionSnapshot
    let identityStart: Int
    let displayStart: Int
    let windowEnd: Int
}

extension SleepScreenModel {

    // MARK: Edit requests

    func editRequestForNight() -> SleepEditRequest? {
        guard let target = page?.editTarget else { return nil }
        return SleepEditRequest(detectedStartTs: target.startTs, bedTs: target.effectiveStartTs,
                                wakeTs: target.endTs, stagesJSON: target.stagesJSON,
                                userEdited: target.userEdited, isMainNight: true)
    }

    func editRequest(nap: CachedSleepSession) -> SleepEditRequest {
        SleepEditRequest(detectedStartTs: nap.startTs, bedTs: nap.effectiveStartTs, wakeTs: nap.endTs,
                         stagesJSON: nap.stagesJSON, userEdited: true, isMainNight: false)
    }

    func napSeed() -> SleepNapSeed? {
        guard let night = page?.night else { return nil }
        let anchor = night.session.endTs + 3_600
        return SleepNapSeed(bedTs: anchor, wakeTs: anchor + 30 * 60)
    }

    // MARK: Intents

    func save(_ edit: SleepEditRequest, bed: Int, wake: Int) async {
        if edit.isMainNight, bed != edit.bedTs {
            SleepOnsetPrefs.recordCorrection(nightKey: edit.detectedStartTs, detectedStartTs: edit.detectedStartTs,
                                             correctedStartTs: bed)
        }
        await repo?.editSleepTimes(detectedStartTs: edit.detectedStartTs, oldEndTs: edit.wakeTs,
                                   storedStagesJSON: edit.stagesJSON, newStartTs: bed, newEndTs: wake)
        await rescore()
    }

    /// Deletes the session so every metric recomputes as if the night was never recorded, then offers
    /// a few seconds to undo it.
    func delete(_ edit: SleepEditRequest) async {
        let snapshot = await repo?.deleteSleepSession(detectedStartTs: edit.detectedStartTs, endTs: edit.wakeTs)
        await rescore()
        if let snapshot { presentUndo(snapshot, displayStart: edit.bedTs, windowEnd: edit.wakeTs) }
    }

    func addNap(start: Int, end: Int) async {
        await repo?.addManualNap(startTs: start, endTs: end)
        await rescore()
    }

    func undoDelete() async {
        guard let undo else { return }
        undoTask?.cancel()
        await repo?.undoDeleteSleepSession(undo.snapshot)
        await rescore()
        withAnimation(.easeOut(duration: 0.2)) { self.undo = nil }
    }

    /// Re-scores so the day's aggregates honour the change, then refreshes the read cache.
    func rescore() async {
        await intelligence?.analyzeRecent()
        await repo?.refresh()
    }

    func onsetEvidence(startTs: Int, endTs: Int) async -> SleepOnsetEvidence? {
        await repo?.sleepOnsetEvidence(startTs: startTs, endTs: endTs)
    }

    // MARK: Undo banner

    /// Only the most recent delete is undoable; the banner clears itself after seven seconds.
    private func presentUndo(_ snapshot: SleepDeletionSnapshot, displayStart: Int, windowEnd: Int) {
        undoTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            undo = SleepUndo(snapshot: snapshot, identityStart: snapshot.session.startTs,
                             displayStart: displayStart, windowEnd: windowEnd)
        }
        let armed = snapshot.session.startTs
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled, let self, self.undo?.identityStart == armed else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.undo = nil }
        }
    }

    /// The banner sentence. A hand-edited night writes no tombstone, so only a detected one promises
    /// that its window will not be detected again.
    func undoMessage(_ undo: SleepUndo) -> String {
        guard !undo.snapshot.session.userEdited else { return String(localized: "Sleep deleted.") }
        let from = Night.clockString(undo.displayStart), to = Night.clockString(undo.windowEnd)
        return String(localized: "Sleep deleted. Zoop won't detect sleep between \(from) and \(to) again.")
    }
}
