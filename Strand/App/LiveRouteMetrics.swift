import Foundation
import CoreLocation
import StrandAnalytics

// MARK: - Live route metrics (live workout screen)
//
// The per-fix series the live workout screen turns into distance, current / average pace, splits and
// climb. Fed by `GpsWorkoutRecorder` for every accepted fix; all the math is `WorkoutSplits` (pure,
// tested in StrandAnalytics). Lives only for the running session: nothing here is persisted, the stored
// route stays `RouteStore`'s.

/// Whether the phone may record a route. `GpsWorkoutRecorder` publishes it so the screen can say why
/// there is no distance instead of showing an empty tile.
enum LocationAccess: Equatable {
    case notDetermined, authorized, denied, unavailable

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .authorized
        case .denied, .restricted: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .unavailable
        }
    }
}

@MainActor
final class LiveRouteMetrics: ObservableObject {

    /// Active seconds since the start and cumulative metres, one per accepted fix.
    @Published private(set) var samples: [WorkoutSplits.Sample] = []
    /// Metres climbed; nil until the phone reports a usable altitude.
    @Published private(set) var elevationGainM: Double?

    private var altitudes: [Double] = []
    /// Vertical accuracy above this is GPS guesswork for climb.
    static let maxVerticalAccuracyM = 15.0

    var distanceM: Double { samples.last?.meters ?? 0 }

    func reset() {
        samples = []
        altitudes = []
        elevationGainM = nil
    }

    /// Seed from a banked route after an app relaunch; the pause history per point is gone, so seconds are
    /// wall-clock offsets from the start minus the pause total known now.
    func restore(points: [WorkoutRoutePoint], startMs: Int64, pausedDurationMs: Int64) {
        reset()
        var meters = 0.0
        var prev: WorkoutRoutePoint?
        samples = points.map { p in
            if let prev {
                meters += RouteMath.haversineMeters(RouteMath.LatLng(prev.lat, prev.lon), RouteMath.LatLng(p.lat, p.lon))
            }
            prev = p
            return WorkoutSplits.Sample(seconds: max(0, Double(p.tMs - startMs - pausedDurationMs) / 1000), meters: meters)
        }
    }

    /// One accepted fix: its active seconds, the metres it adds and an altitude when trustworthy.
    func append(seconds: Double, addedMeters: Double, altitude: Double?, verticalAccuracy: Double?) {
        let meters = distanceM + max(0, addedMeters)
        samples.append(WorkoutSplits.Sample(seconds: max(samples.last?.seconds ?? 0, seconds), meters: meters))
        if let altitude, let verticalAccuracy, verticalAccuracy >= 0,
           verticalAccuracy <= Self.maxVerticalAccuracyM, altitude.isFinite {
            altitudes.append(altitude)
            elevationGainM = WorkoutSplits.elevationGain(altitudes)
        }
    }
}
