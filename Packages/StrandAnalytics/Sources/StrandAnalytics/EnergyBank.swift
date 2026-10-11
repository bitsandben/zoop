import Foundation
import WhoopProtocol

// EnergyBank.swift — a 0–100 ESTIMATE of how much energy the body has right now, in the spirit of a
// "body battery": it opens at a morning value set by last night's recovery, drains through the waking
// day (faster with exertion and stress) and refills during sleep and calm, low-heart-rate rest.
//
// This is a new, deliberately simple estimate, not a validated physiological measure. Every rate below
// is a named constant so the behaviour can be read off the code and explained in one sentence:
//
//   • morning value  = morningFloor + morningRecoverySpan × recovery/100, lowered when last night's
//                      sleep fell short of the need (sleepShortfallPenalty × shortfall share).
//   • each step      : asleep            → + sleepChargePerHour × sleep quality
//                      awake, HR near rest and not stressed → + calmChargePerHour
//                      awake otherwise   → − passiveDrainPerHour
//                                          − exertionDrainPerHour × exertion share of HR reserve
//                                          − stressDrainPerHour × stress share above the baseline band
//   • the level is clamped to 0…100 after every step.
//
// Pure: no I/O, no clock. The caller passes the window, the samples and the context.

public enum EnergyBank {

    // MARK: Constants

    /// Step length in seconds. Five minutes is fine enough for a day curve and coarse enough that a few
    /// noisy samples do not swing a step.
    public static let stepSeconds = 300
    /// Morning value at 0 % recovery.
    public static let morningFloor = 20.0
    /// Added on top of the floor at 100 % recovery (so 100 % recovery opens at 95).
    public static let morningRecoverySpan = 75.0
    /// Morning value when last night's recovery is unknown.
    public static let morningDefault = 60.0
    /// Points removed at the morning when last night's sleep was entirely missing; scaled by the share
    /// of the sleep need that was missed (half the need → half this penalty).
    public static let sleepShortfallPenalty = 20.0
    /// Recharge per hour of sleep at full sleep quality (eight good hours ≈ +80 before the clamp).
    public static let sleepChargePerHour = 10.0
    /// Sleep quality used when a sleep span carries none.
    public static let defaultSleepQuality = 0.85
    /// Recharge per hour of calm, low-heart-rate wakefulness (sitting quietly, resting).
    public static let calmChargePerHour = 2.0
    /// HR-reserve share at or below which an awake step counts as calm.
    public static let calmReserveCeiling = 0.10
    /// Stress (0–3) below which a low-HR step may count as calm. Unknown stress does not block calm.
    public static let calmStressCeiling = 1.0
    /// The baseline cost of being awake, per hour (sixteen waking hours ≈ −40).
    public static let passiveDrainPerHour = 2.5
    /// HR-reserve share above which exertion starts to drain on top of the passive cost.
    public static let exertionReserveFloor = 0.20
    /// Extra drain per hour at 100 % of HR reserve; scales linearly from `exertionReserveFloor`
    /// (an hour at 60 % reserve ≈ −15 on top of the passive cost).
    public static let exertionDrainPerHour = 30.0
    /// Stress (0–3) above which stress drains on top of the passive cost (the middle of the scale).
    public static let stressFloor = 1.5
    /// Extra drain per hour at the top of the stress scale; scales linearly from `stressFloor`.
    public static let stressDrainPerHour = 6.0
    /// Resting heart rate assumed when none is known.
    public static let defaultRestingHR = 60.0
    /// Maximum heart rate assumed when none is known.
    public static let defaultMaxHR = 190.0
    /// A stress reading applies to steps up to this many seconds after it (the hourly curve's grain).
    public static let stressValiditySeconds = 3600

    // MARK: Types

    /// A span of sleep inside (or overlapping) the window. `quality` is 0…1 (sleep efficiency works).
    public struct SleepSpan: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let quality: Double?
        public init(start: Int, end: Int, quality: Double? = nil) {
            self.start = start; self.end = end; self.quality = quality
        }
    }

    /// One intraday stress reading on the 0–3 scale, valid from `ts`.
    public struct StressPoint: Equatable, Sendable {
        public let ts: Int
        public let level: Double
        public init(ts: Int, level: Double) { self.ts = ts; self.level = level }
    }

    public struct Inputs {
        /// Window start (unix seconds), usually the end of last night's sleep.
        public var start: Int
        /// Window end (unix seconds), usually now.
        public var end: Int
        public var heartRate: [HRSample]
        public var sleeps: [SleepSpan]
        public var stress: [StressPoint]
        /// Last night's recovery, 0–100.
        public var morningRecovery: Double?
        /// Last night's sleep as a share of the need (1 = met).
        public var sleepSufficiency: Double?
        public var restingHR: Double?
        public var maxHR: Double?

        public init(start: Int, end: Int, heartRate: [HRSample] = [], sleeps: [SleepSpan] = [],
                    stress: [StressPoint] = [], morningRecovery: Double? = nil,
                    sleepSufficiency: Double? = nil, restingHR: Double? = nil, maxHR: Double? = nil) {
            self.start = start; self.end = end; self.heartRate = heartRate; self.sleeps = sleeps
            self.stress = stress; self.morningRecovery = morningRecovery
            self.sleepSufficiency = sleepSufficiency; self.restingHR = restingHR; self.maxHR = maxHR
        }
    }

    public struct Point: Equatable, Sendable {
        public let ts: Int
        public let level: Double
        public init(ts: Int, level: Double) { self.ts = ts; self.level = level }
    }

    public struct Result: Equatable, Sendable {
        /// The level at the start of the window.
        public let morning: Double
        /// The level at the end of the window.
        public let current: Double
        /// The level at the window start and after every step.
        public let timeline: [Point]
        /// Total points gained over the window (after clamping).
        public let charged: Double
        /// Total points lost over the window (after clamping), as a positive number.
        public let drained: Double
    }

    // MARK: Engine

    /// The morning value from last night's recovery and sleep sufficiency, clamped to 0…100.
    public static func morningLevel(recovery: Double?, sleepSufficiency: Double?) -> Double {
        var level = recovery.map { morningFloor + morningRecoverySpan * min(max($0, 0), 100) / 100 }
            ?? morningDefault
        if let s = sleepSufficiency, s.isFinite {
            level -= sleepShortfallPenalty * (1 - min(max(s, 0), 1))
        }
        return clamp(level)
    }

    /// Walks the window in `stepSeconds` steps and returns the level curve. Deterministic.
    public static func compute(_ input: Inputs) -> Result {
        let morning = morningLevel(recovery: input.morningRecovery, sleepSufficiency: input.sleepSufficiency)
        guard input.end > input.start else {
            return Result(morning: morning, current: morning,
                          timeline: [Point(ts: input.start, level: morning)], charged: 0, drained: 0)
        }
        let rest = input.restingHR.flatMap { $0 > 0 ? $0 : nil } ?? defaultRestingHR
        let maxHR = max(input.maxHR.flatMap { $0 > 0 ? $0 : nil } ?? defaultMaxHR, rest + 20)
        let hr = input.heartRate.filter { $0.ts >= input.start && $0.ts < input.end && $0.bpm > 0 }
            .sorted { $0.ts < $1.ts }
        let stress = input.stress.sorted { $0.ts < $1.ts }

        var level = morning
        var charged = 0.0, drained = 0.0
        var timeline = [Point(ts: input.start, level: morning)]
        timeline.reserveCapacity((input.end - input.start) / stepSeconds + 2)
        var hrIndex = 0
        var stressIndex = 0
        var t = input.start
        while t < input.end {
            let stepEnd = min(t + stepSeconds, input.end)
            let hours = Double(stepEnd - t) / 3600
            let mid = t + (stepEnd - t) / 2

            // Mean HR in this step (samples are sorted, so one forward pass covers the day).
            var sum = 0, count = 0
            while hrIndex < hr.count && hr[hrIndex].ts < stepEnd {
                if hr[hrIndex].ts >= t { sum += hr[hrIndex].bpm; count += 1 }
                hrIndex += 1
            }
            let meanHR: Double? = count > 0 ? Double(sum) / Double(count) : nil

            // The latest stress reading at or before the step's middle, if still fresh.
            while stressIndex + 1 < stress.count && stress[stressIndex + 1].ts <= mid { stressIndex += 1 }
            let stressLevel: Double? = stress.indices.contains(stressIndex)
                && stress[stressIndex].ts <= mid && mid - stress[stressIndex].ts <= stressValiditySeconds
                ? stress[stressIndex].level : nil

            let delta: Double
            if let sleep = input.sleeps.first(where: { mid >= $0.start && mid < $0.end }) {
                let q = min(max(sleep.quality ?? defaultSleepQuality, 0), 1)
                delta = sleepChargePerHour * q * hours
            } else {
                let reserve = meanHR.map { min(max(($0 - rest) / (maxHR - rest), 0), 1) }
                let calm = reserve.map { $0 <= calmReserveCeiling } ?? false
                    && (stressLevel.map { $0 < calmStressCeiling } ?? true)
                if calm {
                    delta = calmChargePerHour * hours
                } else {
                    let exertion = reserve.map {
                        max(0, $0 - exertionReserveFloor) / (1 - exertionReserveFloor)
                    } ?? 0
                    let strain = stressLevel.map { max(0, min($0, 3) - stressFloor) / (3 - stressFloor) } ?? 0
                    delta = -(passiveDrainPerHour + exertionDrainPerHour * exertion
                              + stressDrainPerHour * strain) * hours
                }
            }
            let next = clamp(level + delta)
            if next > level { charged += next - level } else { drained += level - next }
            level = next
            timeline.append(Point(ts: stepEnd, level: level))
            t = stepEnd
        }
        return Result(morning: morning, current: level, timeline: timeline, charged: charged, drained: drained)
    }

    static func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
}
