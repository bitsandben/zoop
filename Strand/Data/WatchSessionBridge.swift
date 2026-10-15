#if os(iOS)
import Foundation
import WatchConnectivity
import StrandDesign
import WhoopStore   // DailyMetric (the anchor row's recovery / strain / sleep fields)

/// The phone side of the watch link. Builds a `WatchScoreSnapshot` (the shared Codable type in
/// StrandDesign) from the latest computed scores and pushes it over WatchConnectivity.
///
/// Transport is `updateApplicationContext` (latest-state, no queue): the watch only wants the most recent
/// snapshot, never a backlog of `transferUserInfo` messages. The snapshot is also written to the shared
/// app group (`latestWatchSnapshot`) so a cold-launched watch app and its complication have a value
/// before the next push lands.
///
/// A calibrating score is sent as `nil` plus its Calibrating flag, never a fabricated number.
@MainActor
final class WatchSessionBridge: NSObject, ObservableObject {

    /// The most recent snapshot built and sent (debug / Settings readout). Also half of the push gate: a
    /// snapshot whose headline values match this one is not pushed.
    @Published private(set) var lastSent: WatchScoreSnapshot?
    private var lastPushedAt: Date?
    /// Minimum spacing between pushes (30 minutes). Complication/context transfers share a system budget
    /// (~50/day), so a push needs BOTH this spacing and changed headline values (see `shouldPush`).
    static let minPushInterval: TimeInterval = 30 * 60
    @Published private(set) var isWatchReachable = false

    private let session: WCSession?

    override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
    }

    // MARK: - Sending

    /// Builds a snapshot from the latest computed scores and pushes it to the watch. Call on every dashboard
    /// refresh; it anchors on the same scored day as the widget so wrist, widget and Today agree.
    ///
    /// Self-throttled: the push goes out only when `shouldPush` passes. A skipped snapshot is not lost; the
    /// next trigger rebuilds it fresh.
    ///
    /// `async` because Rest (sleep_performance) lives in a computed metric series and needs an
    /// `exploreSeries` read.
    func sendLatest(from model: AppModel) async {
        let snap = await Self.buildSnapshot(from: model)
        // A contentless snapshot (a cold launch racing the first repo refresh) must NOT push: it would stomp the
        // watch's last REAL data and burn the spacing gate. Skip without touching lastPushedAt/lastSent.
        let contentless = snap.scoreDay == nil && snap.charge == nil && snap.effort == nil
            && snap.rest == nil && snap.sleepSummary.isEmpty
        if contentless { return }
        let now = Date()
        guard shouldPush(snap, now: now) else { return }
        lastPushedAt = now
        send(snap)
    }

    func pushLatest(from model: AppModel) async {
        await sendLatest(from: model)
    }

    private func shouldPush(_ snap: WatchScoreSnapshot, now: Date) -> Bool {
        if let at = lastPushedAt, now.timeIntervalSince(at) < Self.minPushInterval { return false }
        return Self.headlineChanged(from: lastSent, to: snap)
    }

    /// Whether the headline of `next` (scores with calibrating flags, sleep summary, the day the scores are
    /// ABOUT) differs from the last push. `hr` (~1 Hz) and `asOf` (new each build) are deliberately NOT
    /// headline or the dedup would never hold. nil `last` always counts as changed.
    static func headlineChanged(from last: WatchScoreSnapshot?, to next: WatchScoreSnapshot) -> Bool {
        guard let last else { return true }
        return last.charge != next.charge
            || last.chargeCalibrating != next.chargeCalibrating
            || last.effort != next.effort
            || last.effortCalibrating != next.effortCalibrating
            || last.rest != next.rest
            || last.restCalibrating != next.restCalibrating
            || last.sleepSummary != next.sleepSummary
            || last.scoreDay != next.scoreDay
    }

    static func buildSnapshot(from model: AppModel) async -> WatchScoreSnapshot {
        // Anchor through the shared `Repository.widgetAnchor` (also used by the widget and Live Activity) so
        // all surfaces describe the same day (#911). It folds in the pre-04:00 carve-out (#304) and the
        // future-day guard (#547), anchors on today's row, and carries over the last strictly-prior scored day
        // for the recovery side.
        let days = model.repo.days
        let now = Date()
        let day = Repository.widgetAnchor(days: days, now: now)

        // Rest for the same anchor day (exploreSeries merges imported and on-device like the Today tile). The
        // tail fallback (restSeries.last) is valid ONLY when the anchor is the local today, else it would show
        // a different day's Rest as this day's; it is also gated on freshness (#977) so a stale tail falls
        // through to nil and the watch shows calibrating. Mirrors TodayLogic.freshRestScore.
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: model.deviceId)
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            let anchorIsToday = day.day == Repository.localDayKey(now)
            restScore = TodayLogic.freshRestScore(
                todayValue: restByDay[day.day], lastDay: restSeries.last?.day,
                lastValue: restSeries.last?.value, isTodaySelected: anchorIsToday, todayKey: day.day)
        }

        let hasAnyDay = day != nil
        let charge = day?.recovery
        let effort = day?.strain
        let rest = restScore

        let snap = WatchScoreSnapshot(
            charge: charge,
            chargeCalibrating: hasAnyDay && charge == nil,
            effort: effort,
            effortCalibrating: hasAnyDay && effort == nil,
            rest: rest,
            restCalibrating: hasAnyDay && rest == nil,
            hr: model.bpm ?? model.live.heartRate,
            sleepSummary: sleepSummary(for: day),
            asOf: Date(),
            scoreDay: day?.day
        )
        return snap
    }

    static func sleepSummary(for day: DailyMetric?) -> String {
        guard let day else { return "" }
        var parts: [String] = []
        if let mins = day.totalSleepMin, mins > 0 {
            let h = Int(mins) / 60
            let m = Int(mins) % 60
            parts.append(String(localized: "\(h)h \(m)m"))
        }
        if let eff = day.efficiency, eff > 0 {
            let pct = eff <= 1.0 ? eff * 100 : eff
            parts.append(String(localized: "\(Int(pct.rounded()))%"))
        }
        return parts.joined(separator: " · ")
    }

    func send(_ snap: WatchScoreSnapshot) {
        lastSent = snap
        snap.save()

        guard let session, session.activationState == .activated else { return }
        isWatchReachable = session.isReachable
        do {
            let data = try JSONEncoder().encode(snap)
            try session.updateApplicationContext([Self.contextKey: data])
        } catch {
            // A failed update is non-fatal: the app-group mirror still carries the value and the next refresh retries.
        }
    }

    static let contextKey = "snapshot"
    static let requestLatestKey = "requestLatest"
}

// MARK: - WCSessionDelegate

extension WatchSessionBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
        }
    }

    // iOS requires both of these; re-activate so the link stays live after the watch re-pairs.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[Self.requestLatestKey] != nil else {
            replyHandler([:])
            return
        }
        if let snap = WatchScoreSnapshot.load(), let data = try? JSONEncoder().encode(snap) {
            replyHandler([Self.contextKey: data])
        } else {
            replyHandler([:])
        }
    }
}
#endif
