import Foundation
import WhoopProtocol

// SmartWake.swift — experimental: is the wearer in light sleep or stirring, right now?
//
// The smart-wake window keeps the strap alarm armed at the latest wake time and, inside the window,
// asks this after each fresh sync. A yes moves the alarm to now, so the wearer is woken when it is easy
// rather than from deep sleep; a no (or not enough fresh data) changes nothing and the alarm rings at its
// time. The signals are the two the strap reliably banks overnight: wrist movement and a heart rate that
// has risen off its night low. Unvalidated on hardware; the caller keeps it opt-in.

public enum SmartWake {

    public enum Signal: String, Equatable, Sendable {
        case moving
        case heartRateRising
    }

    /// Data must reach at least this close to `now` to count as current.
    static let freshness = 6 * 60
    /// Movement: a sample-to-sample change in the gravity vector above this (g)…
    static let movementDeltaG = 0.08
    /// …in at least this many distinct minutes of the last five.
    static let movingMinutes = 2
    static let movementLookback = 5 * 60
    /// Heart rate: the last three minutes this far above the night's lowest three-minute mean…
    static let riseBpm = 6.0
    static let recentWindow = 3 * 60
    /// …taken over the last half hour.
    static let baselineLookback = 30 * 60

    /// The signal that says the wearer is near waking at `now`, or nil.
    public static func lightSleepSignal(hr: [HRSample], gravity: [GravitySample], now: Int) -> Signal? {
        if isMoving(gravity, now: now) { return .moving }
        if heartRateRising(hr, now: now) { return .heartRateRising }
        return nil
    }

    static func isMoving(_ gravity: [GravitySample], now: Int) -> Bool {
        let recent = gravity.filter { $0.ts > now - movementLookback && $0.ts <= now }.sorted { $0.ts < $1.ts }
        guard let last = recent.last, now - last.ts <= freshness, recent.count >= 2 else { return false }
        var minutes = Set<Int>()
        for (a, b) in zip(recent, recent.dropFirst()) {
            let d = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y) + (b.z - a.z) * (b.z - a.z)).squareRoot()
            if d > movementDeltaG { minutes.insert(b.ts / 60) }
        }
        return minutes.count >= movingMinutes
    }

    static func heartRateRising(_ hr: [HRSample], now: Int) -> Bool {
        let window = hr.filter { $0.ts > now - baselineLookback && $0.ts <= now }
        guard let last = window.map(\.ts).max(), now - last <= freshness else { return false }
        let recent = window.filter { $0.ts > last - recentWindow }.map { Double($0.bpm) }
        guard recent.count >= 5 else { return false }
        let recentMean = recent.reduce(0, +) / Double(recent.count)
        // Lowest three-minute mean over the half hour, from three-minute buckets with enough samples.
        var buckets: [Int: (Double, Int)] = [:]
        for s in window {
            let b = s.ts / recentWindow
            let cur = buckets[b] ?? (0, 0)
            buckets[b] = (cur.0 + Double(s.bpm), cur.1 + 1)
        }
        let means = buckets.values.filter { $0.1 >= 5 }.map { $0.0 / Double($0.1) }
        guard means.count >= 3, let low = means.min() else { return false }
        return recentMean >= low + riseBpm
    }
}
