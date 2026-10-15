import Foundation
import CoreLocation
import StrandAnalytics   // WorkoutsTrace + TestCentre: the GPS-fix line for the Workouts test mode

// MARK: - GPS workout recording on Apple (#524)
// GPS route recording for distance-type workouts, added alongside the manual-workout lifecycle; it never
// touches WHOOP, scoring or the HR-window capture path. Pieces, split so geo math and persistence are
// unit-testable off any location stack:
// - `RouteMath`: Haversine distance, pace, and precision-5 encoded polylines (same encoding as Android).
// - `TrackFilter`: stateful gate dropping low-accuracy fixes and impossible jumps (50 m accuracy, ~12 m/s),
// bounding the untrusted OS fix stream before it reaches the stored route.
// - `RouteStore`: on-device UserDefaults side-store keyed by startTs + sport (`WorkoutRow` has no route
// column on Apple), read back by WorkoutDetailView. Never leaves the phone.
// - `GpsWorkoutRecorder`: thin CoreLocation wrapper. Fails safe: with no location hardware or denied
// permission it records nothing and the workout still banks HR + Effort.

// MARK: - RouteMath (pure; Android parity)

/// Pure geo math for GPS workouts, no platform types: Haversine distance, pace, precision-5 polylines.
enum RouteMath {

    /// One geographic point. Plain `Double`s so the math needs no CoreLocation.
    struct LatLng: Equatable {
        let lat: Double
        let lon: Double
        init(_ lat: Double, _ lon: Double) { self.lat = lat; self.lon = lon }
    }

    private static let earthR = 6_371_000.0 // metres

    static func haversineMeters(_ a: LatLng, _ b: LatLng) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthR * 2 * atan2(sqrt(s), sqrt(1 - s))
    }

    static func totalMeters(_ points: [LatLng]) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count { sum += haversineMeters(points[i - 1], points[i]) }
        return sum
    }

    static func paceSecPerKm(meters: Double, seconds: Double) -> Double? {
        meters <= 0 ? nil : seconds / (meters / 1000.0)
    }

    /// Wall-clock workout time minus completed pauses, in seconds. Pure so pause accounting is testable.
    static func activeElapsedSeconds(startMs: Int64, nowMs: Int64, pausedDurationMs: Int64) -> Double {
        Double(nowMs - startMs - pausedDurationMs) / 1000.0
    }

    // MARK: Encoded Polyline Algorithm Format, precision 5

    /// Encode a route to a Google precision-5 polyline string; identical to Android for the same points.
    static func encode(_ points: [LatLng]) -> String {
        var out = ""
        var prevLat = 0, prevLon = 0
        for p in points {
            let lat = Int((p.lat * 1e5).rounded())
            let lon = Int((p.lon * 1e5).rounded())
            encodeSigned(lat - prevLat, into: &out)
            encodeSigned(lon - prevLon, into: &out)
            prevLat = lat
            prevLon = lon
        }
        return out
    }

    static func decode(_ encoded: String) -> [LatLng] {
        var out: [LatLng] = []
        let chars = Array(encoded.unicodeScalars)
        var i = 0
        var lat = 0, lon = 0
        while i < chars.count {
            guard let dLat = decodeSigned(chars, &i) else { break }
            guard let dLon = decodeSigned(chars, &i) else { break }
            lat += dLat
            lon += dLon
            let p = LatLng(Double(lat) / 1e5, Double(lon) / 1e5)
            // Drop anything off the surface of the earth (defensive gate on a value decoded from disk).
            if (-90...90).contains(p.lat) && (-180...180).contains(p.lon) { out.append(p) }
        }
        return out
    }

    private static func encodeSigned(_ v: Int, into out: inout String) {
        var value = v < 0 ? ~(v << 1) : (v << 1)
        while value >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar((0x20 | (value & 0x1f)) + 63)!)
            value >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(value + 63)!)
    }

    /// Decode one signed varint at `i`, advancing it; nil if the buffer ends mid-value.
    private static func decodeSigned(_ chars: [Unicode.Scalar], _ i: inout Int) -> Int? {
        var result = 0, shift = 0, b = 0
        repeat {
            guard i < chars.count else { return nil }
            b = Int(chars[i].value) - 63
            // A byte must be a valid polyline character (>= 63).
            guard b >= 0 else { return nil }
            i += 1
            result |= (b & 0x1f) << shift
            shift += 5
            // Guard against a long run inflating `shift` past Int width.
            if shift > 35 { return nil }
        } while b >= 0x20
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}

// MARK: - TrackFilter (pure; Android parity)

struct RawFix: Equatable {
    let lat: Double
    let lon: Double
    let accuracyM: Double   // horizontal accuracy radius; < 0 from CoreLocation means "invalid"
    let tMs: Int64          // fix time, ms since epoch
}

/// Stateful fix gate: returns the accepted point or nil, keeping the last accepted fix to gate the next.
final class TrackFilter {
    // 50 m is the realistic consumer-GPS accuracy gate during activity; the speed gate still rejects teleports.
    // Thresholds match Android (#324).
    private let maxAccuracyM: Double
    private let maxSpeedMps: Double   // ~43 km/h; well above running, below GPS teleports
    private var last: RawFix?

    init(maxAccuracyM: Double = 50, maxSpeedMps: Double = 12) {
        self.maxAccuracyM = maxAccuracyM
        self.maxSpeedMps = maxSpeedMps
    }

    /// Accept a fix or reject it (nil): invalid or too-coarse accuracy, out-of-range coordinate, or a jump
    /// from the last accepted fix faster than `maxSpeedMps`.
    func accept(_ fix: RawFix) -> RouteMath.LatLng? {
        // CoreLocation reports a negative horizontalAccuracy for an invalid fix; treat as a drop.
        if fix.accuracyM < 0 || fix.accuracyM > maxAccuracyM { return nil }
        guard (-90...90).contains(fix.lat), (-180...180).contains(fix.lon) else { return nil }
        if let prev = last {
            let dt = Double(fix.tMs - prev.tMs) / 1000.0
            if dt > 0 {
                let d = RouteMath.haversineMeters(RouteMath.LatLng(prev.lat, prev.lon),
                                                  RouteMath.LatLng(fix.lat, fix.lon))
                if d / dt > maxSpeedMps { return nil }
            }
        }
        last = fix
        return RouteMath.LatLng(fix.lat, fix.lon)
    }

    /// Whether a fix could plausibly follow an earlier captured point, by the same speed rule as `accept`.
    /// Needed at a restored-route seam: seeding `last` with the banked point would stall the track if the
    /// wearer resumed elsewhere, since a rejected fix does not advance `last`.
    func couldFollow(_ fix: RawFix, from lat: Double, _ lon: Double, at fromMs: Int64) -> Bool {
        let dt = Double(fix.tMs - fromMs) / 1000.0
        guard dt > 0 else { return false }
        let d = RouteMath.haversineMeters(RouteMath.LatLng(lat, lon), RouteMath.LatLng(fix.lat, fix.lon))
        return d / dt <= maxSpeedMps
    }
}

// MARK: - RouteStore (on-device side-store)

/// A waypoint with its CoreLocation measurements (horizontal accuracy in metres, time in epoch ms),
/// matching `RawFix` without putting CoreLocation in persisted data.
struct WorkoutRoutePoint: Equatable, Codable {
    var lat: Double
    var lon: Double
    var accuracyM: Double
    var tMs: Int64
}

/// The route persisted for one finished workout: polyline, GPS distance and, when available, the
/// per-point measurements. Legacy entries may lack point metadata.
struct WorkoutRoute: Equatable, Codable {
    var polyline: String
    var distanceM: Double
    /// Filtered GPS measurements; nil for routes saved before this field existed.
    var points: [WorkoutRoutePoint]? = nil

    /// Whether the route has trustworthy per-point data for a HealthKit time-series export. Legacy routes
    /// stay drawable but are never exported with guessed values.
    var hasExportableMeasurements: Bool {
        guard let points, points.count >= 2 else { return false }
        var previousTimestamp: Int64?
        for point in points {
            guard point.lat.isFinite, (-90...90).contains(point.lat),
                  point.lon.isFinite, (-180...180).contains(point.lon),
                  point.accuracyM.isFinite, point.accuracyM >= 0, point.tMs > 0 else { return false }
            if let previousTimestamp, point.tMs <= previousTimestamp { return false }
            previousTimestamp = point.tMs
        }
        return true
    }
}

/// The route of a GPS workout while it is running, so an OS kill mid-session cannot silently shorten it
/// (a short route and distance that look real are worse than none). Only points are stored; the track is
/// derivable from them. Written on a point-count throttle because the blob grows with the route. Never
/// leaves the device.
enum ActiveRouteStore {

    static let defaultsKey = "zoop.activeWorkoutRoute"

    /// Points captured between writes: at `distanceFilter` 5 m a kill risks ~125 m of route, for one rewrite
    /// per 25 fixes.
    static let pointsPerWrite = 25

    /// Pure codec. An empty array reads back as nil ("nothing captured" equals "no workout running").
    static func encode(_ points: [WorkoutRoutePoint]) -> Data? { try? JSONEncoder().encode(points) }

    static func decode(_ data: Data?) -> [WorkoutRoutePoint]? {
        guard let data, !data.isEmpty,
              let points = try? JSONDecoder().decode([WorkoutRoutePoint].self, from: data),
              !points.isEmpty else { return nil }
        return points
    }

    static func store(_ points: [WorkoutRoutePoint], into defaults: UserDefaults = .standard) {
        guard !points.isEmpty, let data = encode(points) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> [WorkoutRoutePoint]? {
        decode(defaults.data(forKey: defaultsKey))
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Per-workout GPS point measurements, one `UserDefaults` key each rather than in `RouteStore`'s map.
/// A point array is ~13x the size of the polyline (~75 bytes of JSON per fix, ~2000 fixes for a 10 km
/// run), and kept in the routes map every `RouteStore.load` would decode tens of megabytes to answer one
/// key. One key per workout keeps the map small and leaves the heavy series to the one reader that wants it.
enum RoutePointStore {

    static func defaultsKey(for mapKey: String) -> String { "zoop.workoutRoutePoints." + mapKey }

    /// Pure codec. An empty array reads back as nil, so "no points" and "saved before points existed" match.
    static func encode(_ points: [WorkoutRoutePoint]) -> Data? { try? JSONEncoder().encode(points) }

    static func decode(_ data: Data?) -> [WorkoutRoutePoint]? {
        guard let data, !data.isEmpty,
              let points = try? JSONDecoder().decode([WorkoutRoutePoint].self, from: data),
              !points.isEmpty else { return nil }
        return points
    }

    static func load(for mapKey: String, from defaults: UserDefaults = .standard) -> [WorkoutRoutePoint]? {
        decode(defaults.data(forKey: defaultsKey(for: mapKey)))
    }

    /// Persist or clear one workout's points; nil/empty removes the key.
    static func store(_ points: [WorkoutRoutePoint]?, for mapKey: String,
                      into defaults: UserDefaults = .standard) {
        guard let points, !points.isEmpty, let data = encode(points) else {
            defaults.removeObject(forKey: defaultsKey(for: mapKey))
            return
        }
        defaults.set(data, forKey: defaultsKey(for: mapKey))
    }

    static func remove(for mapKey: String, from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey(for: mapKey))
    }
}

/// On-device persistence for finished GPS routes, keyed by startTs + sport. `WorkoutRow` carries no route
/// column on Apple. The codec (`encodeMap` / `decodeMap`) is pure; `store` / `load` / `remove` thread a
/// `UserDefaults` through it. Bounded so the blob cannot grow without limit. Never leaves the device.
enum RouteStore {

    static let defaultsKey = "zoop.workoutRoutes"

    /// Cap on stored routes: newest kept, oldest evicted (keys sort by leading startTs).
    static let maxRoutes = 400

    /// Natural key "<startTs>|<sport>", matching the `WorkoutRow` key; sport avoids collisions on a shared start second.
    static func key(startTs: Int, sport: String) -> String { "\(startTs)|\(sport)" }

    /// Encode a route map to JSON, first dropping entries with a non-finite or negative distance: JSON has no
    /// NaN/Inf, so one corrupt distance would make `JSONEncoder` throw and lose every route.
    static func encodeMap(_ map: [String: WorkoutRoute]) -> Data? {
        let clean = map.filter { $0.value.distanceM.isFinite && $0.value.distanceM >= 0 }
        return try? JSONEncoder().encode(clean)
    }

    /// Decode a route map, dropping entries with a non-finite or negative distance (never trust the blob).
    /// nil/garbage yields an empty map.
    static func decodeMap(_ data: Data?) -> [String: WorkoutRoute] {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode([String: WorkoutRoute].self, from: data) else { return [:] }
        return raw.filter { $0.value.distanceM.isFinite && $0.value.distanceM >= 0 }
    }

    static func loadMap(from defaults: UserDefaults = .standard) -> [String: WorkoutRoute] {
        decodeMap(defaults.data(forKey: defaultsKey))
    }

    static func load(startTs: Int, sport: String, from defaults: UserDefaults = .standard) -> WorkoutRoute? {
        loadMap(from: defaults)[key(startTs: startTs, sport: sport)]
    }

    /// Persist `route`, evicting the oldest beyond the cap. No-op without a usable polyline (honest "no route").
    static func store(_ route: WorkoutRoute, startTs: Int, sport: String,
                      into defaults: UserDefaults = .standard) {
        storeAll([(route, startTs, sport)], into: defaults)
    }

    /// Persist many routes in one blob rewrite. `store` decodes and re-encodes the whole (up to 400 entry)
    /// map per call, so a 500-workout import would churn about a gigabyte of JSON through `UserDefaults`.
    /// Eviction runs once after the batch, by `startTs`, so a large import evicts its own oldest entries
    /// rather than routes recorded on this device.
    static func storeAll(_ entries: [(route: WorkoutRoute, startTs: Int, sport: String)],
                         into defaults: UserDefaults = .standard) {
        let usable = entries.filter { !$0.route.polyline.isEmpty }
        guard !usable.isEmpty else { return }
        var map = loadMap(from: defaults)
        for e in usable {
            let k = key(startTs: e.startTs, sport: e.sport)
            // The map holds the polyline only; points go to `RoutePointStore` so the map stays small enough for the
            // every-read full decode its cap assumes.
            var light = e.route
            light.points = nil
            map[k] = light
            RoutePointStore.store(e.route.points, for: k, into: defaults)
        }
        if map.count > maxRoutes {
            let ordered = map.keys.sorted { lhs, rhs in
                (Int(lhs.split(separator: "|").first ?? "") ?? 0)
                    < (Int(rhs.split(separator: "|").first ?? "") ?? 0)
            }
            for k in ordered.prefix(map.count - maxRoutes) {
                map.removeValue(forKey: k)
                RoutePointStore.remove(for: k, from: defaults)
            }
        }
        guard let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func remove(startTs: Int, sport: String, from defaults: UserDefaults = .standard) {
        var map = loadMap(from: defaults)
        RoutePointStore.remove(for: key(startTs: startTs, sport: sport), from: defaults)
        guard map.removeValue(forKey: key(startTs: startTs, sport: sport)) != nil,
              let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The route with its recorded points, for the HealthKit route export. Everything that only draws the path uses `load`.
    static func loadWithPoints(startTs: Int, sport: String,
                               from defaults: UserDefaults = .standard) -> WorkoutRoute? {
        let k = key(startTs: startTs, sport: sport)
        guard var route = loadMap(from: defaults)[k] else { return nil }
        route.points = RoutePointStore.load(for: k, from: defaults)
        return route
    }
}

// MARK: - GpsWorkoutRecorder (CoreLocation wrapper)

/// Records the route of an in-flight GPS workout from CoreLocation. Thin and fail-safe: requests
/// When-In-Use, streams fixes through `TrackFilter`, accumulates route, live distance and pace. `AppModel`
/// starts it for a distance-type sport and reads the route on End.
/// iOS needs `NSLocationWhenInUseUsageDescription` and the `location` UIBackgroundMode for the route to
/// accrue with the screen off. On macOS most Macs have no GPS, so the route stays empty.
/// `@MainActor` drives `@Published` values into SwiftUI; the manager is created on main so its delegate
/// callbacks arrive there, and `@preconcurrency` lets this type satisfy the nonisolated delegate requirements.
@MainActor
final class GpsWorkoutRecorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var distanceM: Double = 0
    @Published private(set) var paceSecPerKm: Double?
    @Published private(set) var pointCount = 0
    /// Location permission as last seen, so the live screen can explain a missing distance.
    @Published private(set) var access: LocationAccess = .notDetermined
    /// Per-fix distance / pace / climb series for the live screen (`LiveRouteMetrics`).
    let metrics = LiveRouteMetrics()

    private let manager = CLLocationManager()
    private var filter = TrackFilter()
    private var track: [RouteMath.LatLng] = []
    private var routePoints: [WorkoutRoutePoint] = []
    /// Points already written to `ActiveRouteStore`, so the throttle counts only new ones.
    private var persistedPointCount = 0
    /// The last banked point a `restore` adopted, until the first later fix has been judged against it.
    private var restoredSeam: WorkoutRoutePoint?
    private var startMs: Int64 = 0
    private var pausedAtMs: Int64?
    private var pausedDurationMs: Int64 = 0

    /// Test Centre `.workouts` sink for GPS-fix lines, wired by AppModel; nil is inert. Check
    /// `TestCentre.active(.workouts)` before building any line. Diagnostic only. `rawFixCount` counts raw
    /// fixes (accepted + rejected) for the accept rate; reset on `start`.
    var workoutsLog: ((String) -> Void)?
    private var rawFixCount = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // ~5 m between callbacks; `TrackFilter` still gates on accuracy and speed.
        manager.distanceFilter = 5
        #if os(iOS)
        // Keep the route accruing with the screen off. Safe only because the iOS target declares the `location`
        // UIBackgroundMode (project.yml); without it this crashes when updates start.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        #endif
    }

    /// Begin recording a fresh route for a workout started at `startMs` (unix ms). Requests When-In-Use if
    /// undecided; records nothing if denied or unavailable. A re-arm resets the track. Fixes arrive asynchronously.
    func start(startMs: Int64) {
        track.removeAll()
        routePoints.removeAll()
        // A fresh arm owns no earlier route; clearing also drops one left by a killed, never-ended session.
        persistedPointCount = 0
        restoredSeam = nil
        ActiveRouteStore.clear()
        filter = TrackFilter()
        self.startMs = startMs
        pausedAtMs = nil
        pausedDurationMs = 0
        distanceM = 0
        paceSecPerKm = nil
        pointCount = 0
        rawFixCount = 0
        metrics.reset()
        isRecording = true
        access = CLLocationManager.locationServicesEnabled() ? LocationAccess(manager.authorizationStatus) : .unavailable

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            // Denied / restricted: stay armed but capture nothing (saved row carries no route). Do not re-prompt;
            // that is the user's Settings choice.
            break
        }
    }

    /// Re-arm after restoring an in-flight workout from disk. The clock and pause accounting survive so live
    /// pace excludes time spent paused across the relaunch.
    func restore(startMs: Int64, pausedAtMs: Int64?, pausedDurationMs: Int64) {
        // Read before `start` clears the key, then seed, so a restored session continues its route.
        let banked = ActiveRouteStore.load()
        start(startMs: startMs)
        if let banked {
            routePoints = banked
            track = banked.map { RouteMath.LatLng($0.lat, $0.lon) }
            persistedPointCount = banked.count
            restoredSeam = banked.last
            pointCount = track.count
            distanceM = RouteMath.totalMeters(track)
            ActiveRouteStore.store(banked)
            metrics.restore(points: banked, startMs: startMs, pausedDurationMs: max(0, pausedDurationMs))
        }
        self.pausedDurationMs = max(0, pausedDurationMs)
        if let pausedAtMs {
            self.pausedAtMs = pausedAtMs
            manager.stopUpdatingLocation()
            isRecording = false
        }
    }

    /// Stop recording and return the accumulated route (possibly empty; safe when not recording). Tears down
    /// location updates so no battery is spent after.
    @discardableResult
    func stop() -> [RouteMath.LatLng] {
        manager.stopUpdatingLocation()
        isRecording = false
        // End and Discard both come through here. `track` is left so `capturedRoute()` still returns the route to the saver.
        ActiveRouteStore.clear()
        persistedPointCount = 0
        let final = track
        return final
    }

    func pause() {
        guard isRecording else { return }
        pausedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        manager.stopUpdatingLocation()
        isRecording = false
    }

    func resume() {
        guard startMs > 0 else { return }
        if let pausedAtMs {
            pausedDurationMs += Int64(Date().timeIntervalSince1970 * 1000) - pausedAtMs
            self.pausedAtMs = nil
        }
        isRecording = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    /// The polyline and distance for the captured route, or nil with fewer than two points (no route unless
    /// points were captured). Persisted via `RouteStore` when the session ends.
    func capturedRoute() -> WorkoutRoute? {
        guard track.count >= 2 else { return nil }
        return WorkoutRoute(polyline: RouteMath.encode(track),
                            distanceM: RouteMath.totalMeters(track),
                            points: routePoints)
    }

    // MARK: Updates

    fileprivate func beginUpdates() {
        // A Mac without location services must record nothing rather than crash.
        guard CLLocationManager.locationServicesEnabled() else { return }
        manager.startUpdatingLocation()
    }

    /// Fold a batch of fixes into the route, updating live distance and pace. No-op when not recording.
    fileprivate func ingest(_ fixes: [RawFix], altitudes: [(altitude: Double, accuracy: Double)?] = []) {
        guard isRecording else { return }
        rawFixCount += fixes.count
        var changed = false
        for (i, fix) in fixes.enumerated() {
            if let pt = filter.accept(fix) {
                if let seam = restoredSeam {
                    restoredSeam = nil
                    if !filter.couldFollow(fix, from: seam.lat, seam.lon, at: seam.tMs) {
                        // The wearer is somewhere the banked route cannot reach at running speed; joining would draw a straight
                        // line across ground the strap never saw. Drop the banked prefix instead.
                        workoutsLog?("gps route: dropped the banked prefix, the first fix after restore "
                                     + "is further from it than running speed allows")
                        track.removeAll()
                        routePoints.removeAll()
                        distanceM = 0
                        pointCount = 0
                        persistedPointCount = 0
                        ActiveRouteStore.clear()
                        metrics.reset()
                    }
                }
                let added = track.last.map { RouteMath.haversineMeters($0, pt) } ?? 0
                let alt = i < altitudes.count ? altitudes[i] : nil
                metrics.append(seconds: Double(fix.tMs - startMs - pausedDurationMs) / 1000, addedMeters: added,
                               altitude: alt?.altitude, verticalAccuracy: alt?.accuracy)
                track.append(pt)
                routePoints.append(WorkoutRoutePoint(lat: fix.lat, lon: fix.lon,
                                                     accuracyM: fix.accuracyM, tMs: fix.tMs))
                changed = true
            }
        }
        if routePoints.count - persistedPointCount >= ActiveRouteStore.pointsPerWrite {
            ActiveRouteStore.store(routePoints)
            persistedPointCount = routePoints.count
        }
        guard changed else { return }
        pointCount = track.count
        distanceM = RouteMath.totalMeters(track)
        let elapsed = RouteMath.activeElapsedSeconds(
            startMs: startMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            pausedDurationMs: pausedDurationMs
        )
        paceSecPerKm = RouteMath.paceSecPerKm(meters: distanceM, seconds: elapsed)
        // Test Centre `.workouts`: one progress line per batch that added a point (raw fixes seen, accepted,
        // running distance). Cheap when off (one UserDefaults bool read) and silent without a sink.
        if TestCentre.active(.workouts), let workoutsLog {
            workoutsLog(WorkoutsTrace.gpsLine(rawFixes: rawFixCount, acceptedPoints: pointCount,
                                              distanceM: distanceM))
        }
    }
}

// MARK: - CLLocationManagerDelegate
// The queue-less manager (created on main) delivers callbacks on the main thread, so MainActor isolation
// is sound; `@preconcurrency` satisfies the nonisolated delegate requirements.

extension GpsWorkoutRecorder: @preconcurrency CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        access = LocationAccess(manager.authorizationStatus)
        guard isRecording else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CoreLocation hands an untrusted batch; map to RawFix and let `TrackFilter` bound-check every field.
        let fixes: [RawFix] = locations.map {
            RawFix(lat: $0.coordinate.latitude,
                   lon: $0.coordinate.longitude,
                   accuracyM: $0.horizontalAccuracy,
                   tMs: Int64($0.timestamp.timeIntervalSince1970 * 1000))
        }
        ingest(fixes, altitudes: locations.map { (altitude: $0.altitude, accuracy: $0.verticalAccuracy) })
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure (no fix yet) self-heals; a hard denial arrives via the auth callback. Swallow so a GPS hiccup cannot crash a workout.
    }
}
