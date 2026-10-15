import Foundation
#if os(iOS)
import CoreMotion
#endif

/// One-shot HISTORICAL phone step count for a finished workout window (#398).
///
/// `CMPedometer` retains ~7 days of step history, so a single query at display time reconciles against
/// the strap's counter without live motion updates. iOS only; macOS gets `nil` and falls back to strap
/// steps. `nil` always means "no phone steps" (unavailable / not authorized / failed), never a
/// fabricated zero.
enum WorkoutPedometer {
    #if os(iOS)
    private static let pedometer = CMPedometer()

    /// The phone's step count between two unix-second bounds, or `nil` when unavailable, Motion access is
    /// denied, the window is empty, or the query fails. The first call triggers the Motion & Fitness prompt.
    static func steps(fromSec: Int, toSec: Int) async -> Int? {
        guard fromSec < toSec, CMPedometer.isStepCountingAvailable() else { return nil }
        switch CMPedometer.authorizationStatus() {
        case .denied, .restricted: return nil
        default: break
        }
        let start = Date(timeIntervalSince1970: TimeInterval(fromSec))
        let end = Date(timeIntervalSince1970: TimeInterval(toSec))
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            pedometer.queryPedometerData(from: start, to: end) { data, _ in
                cont.resume(returning: data?.numberOfSteps.intValue)
            }
        }
    }
    #else
    /// macOS has no pedometer; steps come from the strap counter only.
    static func steps(fromSec: Int, toSec: Int) async -> Int? { nil }
    #endif
}
