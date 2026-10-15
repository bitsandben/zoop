import Foundation

// The "silent guardian" coach for a Live Session. Pure, deterministic, DB-free.
//
// Watches live HR against a recovery-gated target band and emits at most two haptic cues: a gentle PUSH when
// you drift too easy for today and a firmer EASE-OFF when you push harder than today's recovery can pay for.
// Silence means on track. Time is passed into every `update(now:bpm:)`, so a session replays deterministically
// from a synthetic HR trace; the transport (live HR, buzz) lives in the app.
//
// Two rules dominate every threshold: a wrong buzz is unforgivable while a missed one is fine (dwell,
// cool-down and hysteresis are core), and never fabricate (impossible samples are rejected, a stale stream
// pauses coaching).
public struct LiveSessionEngine {

    // MARK: - Tuning constants (pinned by test)

    /// Target-band ceiling (fraction of HRR) on a fully-depleted Charge day.
    public static let ceilingPctAtLowCharge: Double = 0.60
    /// Target-band ceiling (fraction HRR) on a fully-recovered Charge day.
    public static let ceilingPctAtHighCharge: Double = 0.82
    /// Band width (ceiling - floor) as a fraction of HRR.
    public static let bandWidthPctHRR: Double = 0.15
    /// The floor never drops below this fraction of HRR.
    public static let minFloorPctHRR: Double = 0.40
    /// Charge fraction used when today's Charge is unknown (conservative mid-point).
    public static let defaultChargeFraction: Double = 0.5

    /// Trailing window (s) for the smoothed HR median: coach on the trend, never a spike.
    public static let smoothingWindowSec: Int = 12
    /// A reading is stale (coaching pauses) after this long with no accepted sample.
    public static let staleAfterSec: Int = 8
    /// Warm-up from session start: classify and accrue in-band time but emit no cues (optical lag).
    public static let warmupSec: Int = 60
    /// After a sharp climb, suppress the "too easy" cue this long (a low reading is likely lag).
    public static let climbGraceSec: Int = 45

    /// Continuous seconds out of band required before any cue fires.
    public static let dwellSec: Int = 25
    /// Minimum seconds before the same cue direction may fire again.
    public static let cooldownSec: Int = 50
    /// Hysteresis margin (bpm) around each band edge.
    public static let hysteresisMarginBpm: Double = 2.0
    /// Largest inter-update gap (s) credited to in-band time.
    public static let maxAccrualDtSec: Int = 5

    /// A smoothed rise of this many bpm within `stepChangeWindowSec` is a sharp climb (new effort).
    public static let stepChangeBpm: Double = 8.0
    public static let stepChangeWindowSec: Int = 15
    /// An above-ceiling breach is a step-change breach (ease-off eligible) if a climb was detected this recently; otherwise it is slow drift (no ease-off).
    public static let climbAttributionSec: Int = 20

    /// Slow, plausible time above the ceiling before it may drift up (adapting to a strong day).
    public static let ceilingDriftAfterSec: Int = 90
    /// Each drift step raises the ceiling this many bpm...
    public static let ceilingDriftStepBpm: Double = 2.0
    /// ...up to this bounded total.
    public static let ceilingDriftMaxBpm: Double = 8.0

    /// Below this (bpm) a live reading is a dropout artifact.
    public static let minPlausibleBpm: Double = 25.0
    /// A reading above HRmax by more than this (bpm) is rejected as noise.
    public static let aboveHRmaxRejectBpm: Double = 5.0
    /// A jump larger than this (bpm) from the last accepted reading within a few seconds is rejected as artifact.
    public static let maxJumpBpm: Double = 45.0

    // MARK: - Config

    public struct Config: Equatable, Sendable {
        public let restingHR: Double
        public let hrMax: Double
        /// Today's Charge (0...100); nil = unknown, use the conservative default curve.
        public let charge: Double?
        public init(restingHR: Double, hrMax: Double, charge: Double?) {
            self.restingHR = restingHR; self.hrMax = hrMax; self.charge = charge
        }
    }

    // MARK: - Band

    public struct Band: Equatable, Sendable {
        public let floorBpm: Double
        public let ceilingBpm: Double
        public let floorPctHRR: Double
        public let ceilingPctHRR: Double
        public init(floorBpm: Double, ceilingBpm: Double, floorPctHRR: Double, ceilingPctHRR: Double) {
            self.floorBpm = floorBpm; self.ceilingBpm = ceilingBpm
            self.floorPctHRR = floorPctHRR; self.ceilingPctHRR = ceilingPctHRR
        }
    }

    // MARK: - Output

    public enum Status: String, Equatable, Sendable, Codable {
        case warmup   // first `warmupSec` — guarding, but never buzzing yet
        case active   // guarding and coaching
        case stale    // no live reading — coaching paused, ring greys
    }

    public enum Position: String, Equatable, Sendable, Codable {
        case below    // too easy for today
        case inBand   // on track (silence)
        case above    // too hard for today
    }

    public enum Cue: String, Equatable, Sendable, Codable {
        case pushNudge  // soft double-tap: give a bit more
        case easeOff    // firm triple: ease off, today can't pay for this
    }

    public struct Output: Equatable, Sendable {
        public let status: Status
        public let position: Position
        /// Trailing-median HR the engine coaches on; nil before the first accepted sample or while stale.
        public let smoothedBpm: Double?
        public let band: Band
        /// Seconds held in band this session (time-held ring fill).
        public let inBandSeconds: Double
        /// A fresh valid sample was accepted on this update (liveness pulse).
        public let sampleArrived: Bool
        /// The cue to fire on this update; nil on the vast majority.
        public let cue: Cue?
        public init(status: Status, position: Position, smoothedBpm: Double?, band: Band,
                    inBandSeconds: Double, sampleArrived: Bool, cue: Cue?) {
            self.status = status; self.position = position; self.smoothedBpm = smoothedBpm
            self.band = band; self.inBandSeconds = inBandSeconds
            self.sampleArrived = sampleArrived; self.cue = cue
        }
    }

    // MARK: - Band from Charge (pure, testable in isolation)

    /// The recovery-gated target band: Charge scales the ceiling between the anchors; the floor sits a fixed HRR width below, never under `minFloorPctHRR`.
    public static func band(config: Config) -> Band {
        let cn: Double = {
            guard let c = config.charge else { return defaultChargeFraction }
            return min(max(c / 100.0, 0.0), 1.0)
        }()
        let ceilingPct = ceilingPctAtLowCharge + (ceilingPctAtHighCharge - ceilingPctAtLowCharge) * cn
        let floorPct = max(ceilingPct - bandWidthPctHRR, minFloorPctHRR)
        let reserve = max(config.hrMax - config.restingHR, 1.0)
        return Band(
            floorBpm: config.restingHR + floorPct * reserve,
            ceilingBpm: config.restingHR + ceilingPct * reserve,
            floorPctHRR: floorPct,
            ceilingPctHRR: ceilingPct
        )
    }

    // MARK: - State

    private let config: Config
    private let baseBand: Band
    private let startTs: Int

    private struct Reading { let ts: Int; let bpm: Int }
    private var buffer: [Reading] = []          // accepted readings within the smoothing window
    private var smoothedHistory: [(ts: Int, bpm: Double)] = []  // for step-change detection

    private var lastUpdateTs: Int
    private var lastValidTs: Int?
    private var lastAcceptedBpm: Double?
    private var currentPosition: Position = .inBand
    private var inBandSeconds: Double = 0

    private var belowSinceTs: Int?
    private var aboveSinceTs: Int?
    private var aboveSlowSinceTs: Int?
    private var lastClimbTs: Int?
    private var lastPushCueTs: Int?
    private var lastEaseCueTs: Int?
    private var ceilingDriftBpm: Double = 0

    public init(config: Config, startTs: Int) {
        self.config = config
        self.baseBand = LiveSessionEngine.band(config: config)
        self.startTs = startTs
        self.lastUpdateTs = startTs
    }

    // MARK: - Update

    /// Advances the session to `now`; pass the live bpm if one arrived, or nil for a plain time tick (detects staleness). Returns the coaching state and any cue.
    public mutating func update(now: Int, bpm: Int?) -> Output {
        let dt = max(now - lastUpdateTs, 0)

        // Validate and accept the sample.
        var sampleArrived = false
        if let raw = bpm, isPlausible(bpm: Double(raw), now: now) {
            buffer.append(Reading(ts: now, bpm: raw))
            lastValidTs = now
            lastAcceptedBpm = Double(raw)
            sampleArrived = true
        }

        // Prune the smoothing window; compute the trend.
        let windowStart = now - Self.smoothingWindowSec
        buffer.removeAll { $0.ts < windowStart }
        let smoothed = buffer.isEmpty ? nil : median(buffer.map { Double($0.bpm) })

        // Staleness: coaching pauses, nothing accrues, dwell freezes.
        let sinceValid = lastValidTs.map { now - $0 } ?? (now - startTs)
        let isStale = sinceValid > Self.staleAfterSec
        let band = currentBand()

        if isStale || smoothed == nil {
            lastUpdateTs = now
            return Output(status: .stale, position: currentPosition, smoothedBpm: nil, band: band,
                          inBandSeconds: inBandSeconds, sampleArrived: sampleArrived, cue: nil)
        }
        let s = smoothed!

        // Sharp-climb detection off the smoothed trend.
        smoothedHistory.append((ts: now, bpm: s))
        smoothedHistory.removeAll { $0.ts < now - Self.stepChangeWindowSec - 2 }
        if let past = smoothedHistory.first(where: { now - $0.ts >= Self.stepChangeWindowSec }),
           s - past.bpm >= Self.stepChangeBpm {
            lastClimbTs = now
        }

        // Classify with hysteresis.
        let newPosition = classify(smoothed: s, band: band, previous: currentPosition)

        // Dwell trackers.
        switch newPosition {
        case .below:
            if currentPosition != .below { belowSinceTs = now }
            aboveSinceTs = nil; aboveSlowSinceTs = nil
        case .above:
            if currentPosition != .above {
                aboveSinceTs = now
                let fromClimb = lastClimbTs.map { now - $0 <= Self.climbAttributionSec } ?? false
                aboveSlowSinceTs = fromClimb ? nil : now
            }
            belowSinceTs = nil
        case .inBand:
            belowSinceTs = nil; aboveSinceTs = nil; aboveSlowSinceTs = nil
        }

        // Accrue in-band time (dt clamped).
        if newPosition == .inBand {
            inBandSeconds += Double(min(dt, Self.maxAccrualDtSec))
        }

        let status: Status = (now - startTs < Self.warmupSec) ? .warmup : .active

        // Cue decision: only when active, at most one, silent by default.
        var cue: Cue? = nil
        if status == .active {
            if newPosition == .below,
               let since = belowSinceTs, now - since >= Self.dwellSec,
               (lastPushCueTs.map { now - $0 >= Self.cooldownSec } ?? true),
               (lastClimbTs.map { now - $0 >= Self.climbGraceSec } ?? true) {
                cue = .pushNudge
                lastPushCueTs = now
                belowSinceTs = now
            } else if newPosition == .above,
                      let since = aboveSinceTs, now - since >= Self.dwellSec,
                      (lastEaseCueTs.map { now - $0 >= Self.cooldownSec } ?? true),
                      aboveSlowSinceTs == nil {   // only a step-change breach earns an ease-off
                cue = .easeOff
                lastEaseCueTs = now
                aboveSinceTs = now
            }
        }

        // Bounded ceiling drift for a genuinely strong, slow day.
        if newPosition == .above, let slowSince = aboveSlowSinceTs,
           now - slowSince >= Self.ceilingDriftAfterSec,
           ceilingDriftBpm < Self.ceilingDriftMaxBpm {
            ceilingDriftBpm = min(ceilingDriftBpm + Self.ceilingDriftStepBpm, Self.ceilingDriftMaxBpm)
            aboveSlowSinceTs = now
        }

        currentPosition = newPosition
        lastUpdateTs = now
        return Output(status: status, position: newPosition, smoothedBpm: s, band: band,
                      inBandSeconds: inBandSeconds, sampleArrived: sampleArrived, cue: cue)
    }

    // MARK: - Internals

    private func currentBand() -> Band {
        guard ceilingDriftBpm != 0 else { return baseBand }
        let reserve = max(config.hrMax - config.restingHR, 1.0)
        let ceilingBpm = baseBand.ceilingBpm + ceilingDriftBpm
        return Band(floorBpm: baseBand.floorBpm, ceilingBpm: ceilingBpm,
                    floorPctHRR: baseBand.floorPctHRR,
                    ceilingPctHRR: (ceilingBpm - config.restingHR) / reserve)
    }

    private func isPlausible(bpm: Double, now: Int) -> Bool {
        guard bpm >= Self.minPlausibleBpm else { return false }
        guard bpm <= config.hrMax + Self.aboveHRmaxRejectBpm else { return false }
        if let last = lastAcceptedBpm, let lastTs = lastValidTs,
           now - lastTs <= Self.smoothingWindowSec, abs(bpm - last) > Self.maxJumpBpm {
            return false
        }
        return true
    }

    private func classify(smoothed s: Double, band: Band, previous: Position) -> Position {
        let m = Self.hysteresisMarginBpm
        if s > band.ceilingBpm + m { return .above }
        if s < band.floorBpm - m { return .below }
        if s >= band.floorBpm + m && s <= band.ceilingBpm - m { return .inBand }
        return previous   // inside the margin zone: hold, don't flicker
    }

    private func median(_ xs: [Double]) -> Double {
        let sorted = xs.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}
