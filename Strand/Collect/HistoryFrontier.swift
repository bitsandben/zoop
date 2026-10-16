import Foundation
import WhoopProtocol

/// The newest record the strap's HISTORY offload has stored, per device. Only the Backfiller advances it.
///
/// The store-wide newest sample cannot stand in for it: the live heart-rate stream (Live screen, or the
/// smart alarm holding it open around the wake window) stores samples at the phone's clock as they arrive,
/// so that value reads "now" while hours of the night are still on the strap. The morning brief reads this
/// value to tell a finished, offloaded night from one cut off by the end of the data
/// (`MorningBriefReadiness`). It never steers the offload itself.
enum HistoryFrontier {

    private static func key(_ deviceId: String) -> String { "zoop.sync.historyFrontier.\(deviceId)" }

    static func value(deviceId: String, defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: key(deviceId)) as? Int
    }

    /// Newest heart-rate, PPG heart-rate or motion timestamp in a stored history chunk.
    static func newest(in streams: Streams) -> Int? {
        [streams.hr.map(\.ts).max(), streams.ppgHr.map(\.ts).max(), streams.gravity.map(\.ts).max()].compactMap { $0 }.max()
    }

    /// Monotonic: an older chunk (the strap offloads oldest first, and re-sends) never moves it back.
    static func advance(deviceId: String, to ts: Int?, defaults: UserDefaults = .standard) {
        guard let ts else { return }
        if let current = value(deviceId: deviceId, defaults: defaults), current >= ts { return }
        defaults.set(ts, forKey: key(deviceId))
    }
}
