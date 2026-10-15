import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - LiveSessionRunner
// Transport half of Live Sessions: the pure `LiveSessionEngine` decides what should happen; this object
// is the only place touching a clock, the live HR stream, the strap buzz and the store. One 1 Hz timer
// feeds the engine `LiveState.heartRate` (nil lets the engine detect a quiet stream itself), publishes
// each `Output`, walks a cue's pulses out through the existing hardware buzz, and books the session in
// the `liveSession` table (at start with endTs nil, at end with totals). Session-scoped: one runner per
// presentation, never restarted.
// Honesty rules from the engine: the published `Output` is the engine's verbatim; a cue that cannot be
// delivered cleanly is dropped, never queued (a late buzz is a wrong buzz); ten minutes of continuous
// stale ends the session.

/// UserDefaults keys for the Live Sessions beta gate.
enum LiveSessionPrefs {
    /// Master switch, default ON (beta-labelled in-UI); off removes the Start-session control from Today.
    static let betaKey = "zoop.liveSessionsBeta"
}

@MainActor
final class LiveSessionRunner: ObservableObject {

    /// Continuous stale seconds after which the session ends itself; a "guarding" screen over no data would be false.
    static let autoEndStaleSec = 600
    /// v1 only coaches the strap's live feed (see `LiveSessionRow.hrSource`).
    static let hrSource = "whoop"
    /// The tick needs no exact wakeup; 10% tolerance lets the system coalesce it. Elapsed-time math uses the
    /// wall clock, so totals do not drift.
    static let timerToleranceSec: TimeInterval = 0.1

    // MARK: Published state (the session screen reads ONLY these — it never observes LiveState)

    @Published private(set) var output: LiveSessionEngine.Output?
    @Published private(set) var pushCount = 0
    @Published private(set) var easeCount = 0
    /// Set once when the session ends; the summary sheet presents off this.
    @Published private(set) var finalRow: LiveSessionRow?

    private(set) var startTs = 0
    private(set) var chargeAtStart: Double?
    private(set) var baseBand: LiveSessionEngine.Band?

    // MARK: Session wiring (held only while running)

    private var engine: LiveSessionEngine?
    private var timer: Timer?
    private var hrSink: AnyCancellable?
    private var model: AppModel?
    private var repo: Repository?
    private var ble: BLEManager?

    /// Out-of-band accrual, mirroring the engine's `inBandSeconds`: per-tick dt clamped to
    /// `maxAccrualDtSec`, nothing accrues while stale.
    private var belowSec: Double = 0
    private var aboveSec: Double = 0
    private var lastTickTs = 0
    private var staleSinceTs: Int?
    /// When the in-flight pulse walk finishes. A cue arriving earlier is skipped: overlapping fire-and-forget
    /// walks would land as one unreadable buzz.
    private var hapticWalkUntil = Date.distantPast

    deinit { timer?.invalidate() }

    // MARK: - Start

    /// Begin guarding: build the engine config from today's banked numbers (Charge may be nil), arm the
    /// realtime HR stream (ref-counted in AppModel, balanced by `end()`), bank the in-progress row, start the
    /// 1 Hz tick. No-op if already running or ended.
    func start(model: AppModel, repo: Repository, ble: BLEManager, profile: ProfileStore) {
        guard timer == nil, finalRow == nil else { return }
        self.model = model
        self.repo = repo
        self.ble = ble

        // Resting HR: today's, else the most recent banked night's, else a deliberately ordinary 60 (the band is
        // conservative until the first night is banked).
        let resting = repo.today?.restingHr
            ?? repo.days.last(where: { $0.restingHr != nil })?.restingHr
            ?? 60
        chargeAtStart = repo.today?.recovery
        let config = LiveSessionEngine.Config(restingHR: Double(resting),
                                              hrMax: Double(profile.hrMax),
                                              charge: chargeAtStart)
        let band = LiveSessionEngine.band(config: config)
        baseBand = band

        let now = Int(Date().timeIntervalSince1970)
        startTs = now
        lastTickTs = now
        engine = LiveSessionEngine(config: config, startTs: now)

        model.startRealtimeHR()

        persist(row(endTs: nil, band: band))

        let tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tickTimer.tolerance = Self.timerToleranceSec
        timer = tickTimer

        // Pocket-the-phone survival: a suspended app stops Timers, but CoreBluetooth still delivers HR notifies,
        // which update `live.heartRate`. Ticking on sample arrival keeps coaching going; in the foreground the
        // extra tick is harmless. Staleness still needs the Timer, which resumes with the app.
        hrSink = model.live.$heartRate.sink { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - End

    /// Stop guarding: kill the timer, release the realtime HR arm, bank final totals, publish the row.
    /// A second call (End tap vs auto-end race) is a no-op returning the final row.
    @discardableResult
    func end() -> LiveSessionRow? {
        guard timer != nil else { return finalRow }
        timer?.invalidate()
        timer = nil
        hrSink?.cancel()
        hrSink = nil
        model?.stopRealtimeHR()

        // Prefer the engine's live band (its ceiling may have drifted) over the base.
        let final = row(endTs: Int(Date().timeIntervalSince1970), band: output?.band ?? baseBand
                        ?? LiveSessionEngine.Band(floorBpm: 0, ceilingBpm: 0, floorPctHRR: 0, ceilingPctHRR: 0))
        persist(final)
        finalRow = final

        engine = nil
        model = nil
        ble = nil
        repo = nil
        return final
    }

    // MARK: - Tick (1 Hz)

    private func tick() {
        guard timer != nil else { return }
        let now = Int(Date().timeIntervalSince1970)
        // The engine takes the live reading if current, or nil as a plain time tick; staleness is its call
        // (no reading is forwarded as exactly that, never held or guessed).
        guard let out = engine?.update(now: now, bpm: model?.live.heartRate) else { return }

        // Mirror the engine's clamped accrual for the two out-of-band buckets; nothing accrues on a stale tick.
        let dt = Double(min(max(now - lastTickTs, 0), LiveSessionEngine.maxAccrualDtSec))
        if out.status != .stale {
            switch out.position {
            case .below:  belowSec += dt
            case .above:  aboveSec += dt
            case .inBand: break   // the engine's own inBandSeconds carries this bucket
            }
        }
        lastTickTs = now

        // Stale watchdog: ten continuous minutes without a reading ends the session.
        if out.status == .stale {
            if staleSinceTs == nil { staleSinceTs = now }
            if let since = staleSinceTs, now - since >= Self.autoEndStaleSec {
                output = out
                end()
                return
            }
        } else {
            staleSinceTs = nil
        }

        if let cue = out.cue { fire(cue) }
        output = out
    }

    // MARK: - Cue → wrist

    /// Walk a cue's pulse list out through the strap like the Haptic Clock: each pulse is the hardware-confirmed
    /// notification buzz (long = 2-loop, short = 1). If a walk is in flight the cue is skipped, never queued or
    /// retried, because a delayed correction corrects nothing. Only a delivered cue is counted.
    private func fire(_ cue: LiveSessionEngine.Cue) {
        let nowDate = Date()
        guard nowDate >= hapticWalkUntil, let ble else { return }

        let signal: LiveSessionHaptics.Signal = (cue == .pushNudge) ? .push : .easeOff
        let pulses = LiveSessionHaptics.pulses(for: signal)
        guard !pulses.isEmpty else { return }

        var offsetMs = 0
        // Live Session cues are opt-in (#1115). Gate only the wrist output; the cue still counts toward the
        // saved row's push/ease stats.
        if HapticPrefs.enabled(HapticPrefs.liveSession) {
            for pulse in pulses {
                let loops = pulse.isLong ? 2 : 1
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak ble] in
                    ble?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
                }
                offsetMs += pulse.durationMs + pulse.gapMs
            }
        }
        hapticWalkUntil = nowDate.addingTimeInterval(Double(offsetMs) / 1000)

        switch cue {
        case .pushNudge: pushCount += 1
        case .easeOff:   easeCount += 1
        }
    }

    // MARK: - Persistence

    private func row(endTs: Int?, band: LiveSessionEngine.Band) -> LiveSessionRow {
        LiveSessionRow(startTs: startTs, endTs: endTs, chargeAtStart: chargeAtStart,
                       floorBpm: band.floorBpm, ceilingBpm: band.ceilingBpm,
                       inBandSec: output?.inBandSeconds ?? 0, belowSec: belowSec, aboveSec: aboveSec,
                       pushCount: pushCount, easeCount: easeCount, hrSource: Self.hrSource)
    }

    /// Idempotent upsert on (deviceId, startTs); start and end writes land on one row.
    private func persist(_ row: LiveSessionRow) {
        guard let repo else { return }
        let deviceId = repo.deviceId
        Task {
            guard let store = await repo.storeHandle() else { return }
            _ = try? await store.upsertLiveSession(row, deviceId: deviceId)
        }
    }
}
