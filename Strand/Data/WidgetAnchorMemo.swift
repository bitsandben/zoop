import Foundation
import WhoopStore

/// Memoizes `Repository.widgetAnchor` across the high-frequency live-HR path.
///
/// The Live Activity's `$heartRate` / `$connected` closures resolve the anchor on EVERY live tick
/// (~1-3 Hz), each time re-deriving two day keys and up to two full-history `days.last(where:)` scans on
/// the MainActor, before the banner's own 2 s throttle can help. The anchor only changes when `days`
/// changes (`Repository.refreshSeq`) or the local/logical day rolls, so keying on
/// `(seq, logicalKey, localKey)` is behavior-preserving. Pure given `compute`, so unit-testable; only
/// touched on the MainActor, so no locking (#1051).
struct WidgetAnchorMemo {
    private var cached: (seq: Int, logicalKey: String, localKey: String, row: DailyMetric?)?

    /// Returns the anchor for `(seq, logicalKey, localKey)`, recomputing via `compute` only when the key
    /// differs from the last one.
    mutating func resolve(
        days: [DailyMetric],
        seq: Int,
        logicalKey: String,
        localKey: String,
        compute: ([DailyMetric], String, String) -> DailyMetric?
    ) -> DailyMetric? {
        if let cached, cached.seq == seq, cached.logicalKey == logicalKey, cached.localKey == localKey {
            return cached.row
        }
        let row = compute(days, logicalKey, localKey)
        cached = (seq, logicalKey, localKey, row)
        return row
    }
}
