import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol
#if os(iOS)
import UIKit
#endif

/// Keeps the app running through the smart-alarm window by holding the strap's live heart-rate stream open:
/// from `leadS` before the window until the wake, iOS wakes the app for each live notification (the
/// bluetooth-central background mode), so evaluations run on the samples themselves instead of on timers that
/// do not fire while suspended. The stream is the SAME one the Live screen arms (`AppModel.setSmartWakeRealtime`
/// → `BLEManager.startRealtime/stopRealtime`); no new strap command. The smart alarm holds its own reference,
/// so it never switches off a stream a Live surface holds, and it hands the stream to the Live screen when the
/// user opens it. Every request, sample count, gap and the reason it let go is written to the night's record.
@MainActor
final class SmartWakeLiveStream {
    nonisolated static let keepAwakeKey = "zoop.smartWake.keepAwake"
    /// The deadline the stream is held for, persisted so the next launch can make sure a previous run did not
    /// leave it on.
    nonisolated static let heldKey = "zoop.smartWake.liveHeldDeadline"
    /// On this long before the window start; off this long after the window end or the early wake.
    static let leadS = 10 * 60
    static let tailS = 2 * 60
    /// Still held this long after the window end: off, and the record says the watchdog did it.
    static let watchdogS = 15 * 60
    /// Evaluations driven by live samples run at most this often.
    static let evaluateEveryS = 60
    /// Record writes (sample counts) at most this often while samples flow.
    static let flushEveryS = 60
    /// Live samples kept in memory for the wake read.
    static let bufferS = 10 * 60

    /// "Keep the app awake in the window", on unless turned off.
    nonisolated static var enabled: Bool {
        UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool ?? true
    }

    /// The night the window follows now (the active deadline's record).
    var activeNight: () -> SmartAlarmNight? = { nil }
    /// A live sample arrived inside the window, at most once per `evaluateEveryS`.
    var onEvaluate: () -> Void = {}

    private weak var model: AppModel?
    private let log: SmartAlarmNightLog
    /// The deadline the smart alarm holds the stream for; nil while it holds nothing.
    private(set) var heldFor: Int?
    private var samples: [HRSample] = []
    private var pending: [Int] = []
    private var lastSecond = 0
    private var lastFlush = 0
    private var lastEvaluate = 0
    private var lastReconcile = 0
    private var leftOnByPreviousRun: Bool
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, log: SmartAlarmNightLog) {
        self.model = model
        self.log = log
        leftOnByPreviousRun = UserDefaults.standard.object(forKey: Self.heldKey) != nil
        model.live.onReadableHeartRate = { [weak self] bpm in self?.noteSample(bpm) }
        model.live.$connected.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }.store(in: &cancellables)
        model.live.$bonded.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }.store(in: &cancellables)
        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.release(.appTerminating, keepMarker: true) }
        }.store(in: &cancellables)
        #endif
    }

    // MARK: Reading

    /// The live wake read at `now` from the samples received (heuristic, `LiveWake`).
    func read(now: Int, sleepingBpm: Double?, moving: Bool) -> LiveWake.Reading {
        LiveWake.classify(live: samples, sleepingBpm: sleepingBpm, moving: moving, now: now)
    }

    var newestSampleAt: Int? { samples.last?.ts }

    // MARK: Samples

    private func noteSample(_ bpm: Int) {
        let now = Int(Date().timeIntervalSince1970)
        guard now != lastSecond else { return }   // the raw flood repeats one value many times a second
        lastSecond = now
        guard let night = heldFor.flatMap({ log.night(deadline: $0) }) ?? activeNight(),
              now >= night.windowStart - Self.leadS, now <= night.deadline + Self.tailS else { return }
        samples.append(HRSample(ts: now, bpm: bpm))
        if samples.count > Self.bufferS + 60 { samples.removeFirst(samples.count - Self.bufferS) }
        if heldFor != nil { pending.append(now) }
        if now - lastFlush >= Self.flushEveryS { flush(now: now) }
        if now - lastReconcile >= 15 { reconcile(now: now) }
        if now >= night.windowStart, now - lastEvaluate >= Self.evaluateEveryS {
            lastEvaluate = now
            onEvaluate()
        }
    }

    /// Folds the samples received since the last write into the held night's record.
    func flush(now: Int = Int(Date().timeIntervalSince1970)) {
        lastFlush = now
        guard let dl = heldFor, !pending.isEmpty else { return }
        let ts = pending
        pending.removeAll()
        log.update(deadline: dl) { n in
            var l = n.liveStream ?? .init()
            l.note(samples: ts, window: GoalWake.Window(start: n.windowStart, end: n.deadline))
            n.liveStream = l
        }
    }

    /// The evaluation ran: a stream-driven one counts toward the throttle too.
    func didEvaluate(at now: Int) { lastEvaluate = max(lastEvaluate, now) }

    // MARK: Holding the stream

    /// Brings the hold in line with the night: on from `leadS` before the window while the strap is connected
    /// and bonded, off on the first reason to stop. Safe to call from every app wake.
    func reconcile(now: Int = Int(Date().timeIntervalSince1970)) {
        lastReconcile = now
        guard let model else { return }
        let ready = model.live.connected && model.live.bonded
        if let reason = releaseReason(now: now, ready: ready) {
            release(reason)
        }
        if leftOnByPreviousRun, heldFor == nil, ready, !model.realtimeSurfaceActive, wanted(now: now) == nil {
            leftOnByPreviousRun = false
            if let dl = UserDefaults.standard.object(forKey: Self.heldKey) as? Int {
                log.update(deadline: dl) { n in
                    var l = n.liveStream ?? .init()
                    l.toggle(on: false, reason: .leftOnByPreviousRun, at: now)
                    n.liveStream = l
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.heldKey)
            model.ble.disarmRealtimeLeftByPreviousRun()
            model.live.append(log: AppModel.stamped("Smart alarm: live stream left on by a previous run, turned off"))
        }
        if heldFor == nil, ready, !model.realtimeSurfaceActive, let night = wanted(now: now) {
            acquire(night, now: now)
        }
        scheduleTimer(now: now)
    }

    /// The night the stream should be held for at `now`, ignoring the connection; nil when none.
    func wanted(now: Int) -> SmartAlarmNight? {
        guard Self.enabled, let n = activeNight(), !n.plannedChecks.isEmpty, n.strapFiredAt == nil,
              n.earlyWake == nil, now >= n.windowStart - Self.leadS, now < n.deadline + Self.tailS else { return nil }
        return n
    }

    private func releaseReason(now: Int, ready: Bool) -> SmartAlarmNight.LiveReason? {
        guard let dl = heldFor else { return nil }
        guard let n = log.night(deadline: dl) else { return .settingOff }
        if now >= n.deadline + Self.watchdogS { return .watchdog }
        if n.strapFiredAt != nil { return .woken }
        if let e = n.earlyWake, now >= e.wakeAt + Self.tailS { return .earlyWakePassed }
        if now >= n.deadline + Self.tailS { return .windowEnded }
        if !Self.enabled || activeNight()?.deadline != dl { return .settingOff }
        if !ready { return .strapDisconnected }
        return nil
    }

    private func acquire(_ night: SmartAlarmNight, now: Int) {
        guard let model else { return }
        let reason: SmartAlarmNight.LiveReason
        switch night.liveStream?.lastOff?.reason {
        case .strapDisconnected?: reason = .reconnected
        case .liveScreenOpened?: reason = .liveScreenClosed
        default: reason = .windowOpening
        }
        heldFor = night.deadline
        leftOnByPreviousRun = false
        UserDefaults.standard.set(night.deadline, forKey: Self.heldKey)
        record(on: true, reason: reason, deadline: night.deadline, now: now)
        model.setSmartWakeRealtime(true)
        model.live.append(log: AppModel.stamped("Smart alarm: live stream on (\(reason.rawValue))"))
    }

    /// Lets go of the stream. `keepMarker` leaves the persisted marker so the next launch double-checks (iOS
    /// may close the app before the off command reaches the strap).
    func release(_ reason: SmartAlarmNight.LiveReason, keepMarker: Bool = false) {
        guard let dl = heldFor, let model else { return }
        let now = Int(Date().timeIntervalSince1970)
        flush(now: now)
        heldFor = nil
        if !keepMarker { UserDefaults.standard.removeObject(forKey: Self.heldKey) }
        record(on: false, reason: reason, deadline: dl, now: now)
        model.setSmartWakeRealtime(false)
        model.live.append(log: AppModel.stamped("Smart alarm: live stream off (\(reason.rawValue))"))
    }

    /// The Live screen opened while the smart alarm held the stream: the screen owns it now (it stays on).
    func screenTookOver() {
        release(.liveScreenOpened)
    }

    /// The last Live surface closed: whether the smart alarm takes the stream back instead of switching it off.
    func takeBackFromScreen() -> Bool {
        let now = Int(Date().timeIntervalSince1970)
        guard heldFor == nil, let model, model.live.connected, model.live.bonded, let night = wanted(now: now)
        else { return false }
        heldFor = night.deadline
        UserDefaults.standard.set(night.deadline, forKey: Self.heldKey)
        record(on: true, reason: .liveScreenClosed, deadline: night.deadline, now: now)
        return true
    }

    private func record(on: Bool, reason: SmartAlarmNight.LiveReason, deadline: Int, now: Int) {
        log.update(deadline: deadline) { n in
            var l = n.liveStream ?? .init()
            l.toggle(on: on, reason: reason, at: now)
            n.liveStream = l
        }
    }

    /// A timer at the next transition (lead start, window end + tail, watchdog). It only fires while iOS lets
    /// the app run; samples, syncs and connection changes reconcile too.
    private func scheduleTimer(now: Int) {
        timer?.invalidate(); timer = nil
        var next: Int?
        if let dl = heldFor, let n = log.night(deadline: dl) {
            next = [n.deadline + Self.tailS, n.earlyWake.map { $0.wakeAt + Self.tailS }].compactMap { $0 }
                .filter { $0 > now }.min() ?? (n.deadline + Self.watchdogS)
        } else if Self.enabled, let n = activeNight(), !n.plannedChecks.isEmpty, n.windowStart - Self.leadS > now {
            next = n.windowStart - Self.leadS
        }
        guard let next else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, next - now)), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }
}
