import Foundation

/// What the Today status line can honestly say about the active device's charge.
///
/// The inputs are independent live signals: the link, the strap's charge % (never cleared when the link
/// drops), the strap's charging flag (a different event, which can arrive before any %), and a ring's own
/// charge. Resolving them in one pure place keeps a stale % or another device's charge off the line.
enum StrapBatteryDisplay: Equatable {
    /// The strap is the active device but not linked: a stale % is worse than none.
    case offline
    /// Linked, no charge reading yet; charging can still be known on its own.
    case pending(charging: Bool)
    /// A reading from the current link, for the strap or (`isRing`) the active ring.
    case charge(pct: Double, charging: Bool, isRing: Bool)
    /// The active device is neither the strap nor a ring that reported its charge (#2208).
    case notActiveDevice

    /// No defaults on purpose: a forgotten flag would reinstate #2208 and still compile.
    static func resolve(activeIsWhoop: Bool, connected: Bool,
                        batteryPct: Double?, charging: Bool?,
                        ringPct: Int?, ringCharging: Bool) -> StrapBatteryDisplay {
        guard activeIsWhoop else {
            guard let ringPct else { return .notActiveDevice }
            return .charge(pct: Double(ringPct), charging: ringCharging, isRing: true)
        }
        guard connected else { return .offline }
        guard let pct = batteryPct else { return .pending(charging: charging == true) }
        return .charge(pct: pct, charging: charging == true, isRing: false)
    }
}
