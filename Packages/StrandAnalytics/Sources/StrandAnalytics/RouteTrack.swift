import Foundation

// MARK: - Route track (coloured route maps)
//
// Pure math behind the workout detail's coloured route: turns the stored GPS fixes (lat, lon, time and an
// optional altitude) into a cleaned, smoothed track the map can colour by pace, heart rate or altitude.
//   - Spikes: a fix that implies a speed above the sport's ceiling from the last kept fix is dropped, so a
//     GPS teleport does not paint one segment as the fastest of the run.
//   - Pauses: a time gap longer than `gapSeconds`, or a smoothed speed below `stopSpeedMps`, is not a pace.
//     Those points carry a nil speed and the map draws them as neutral, never as "very slow".
//   - Smoothing: speed at a point is distance over time across a centred window of at least
//     `windowSeconds` and `windowMeters` (capped at three windows), never crossing a gap. Altitude is a centred moving mean.
// Nothing here knows about MapKit, colours or units on screen.

public enum RouteTrack {

    /// One stored GPS fix. `t` is seconds since the epoch.
    public struct Fix: Equatable, Sendable {
        public let lat: Double
        public let lon: Double
        public let t: Double
        public let altitude: Double?
        public init(lat: Double, lon: Double, t: Double, altitude: Double? = nil) {
            self.lat = lat; self.lon = lon; self.t = t; self.altitude = altitude
        }
    }

    /// One heart-rate reading (seconds since the epoch, bpm).
    public struct HeartRate: Equatable, Sendable {
        public let t: Double
        public let bpm: Double
        public init(t: Double, bpm: Double) { self.t = t; self.bpm = bpm }
    }

    /// Tuning for one sport. Defaults suit running; `cycling` raises the speed ceiling.
    public struct Options: Equatable, Sendable {
        public var maxSpeedMps: Double
        public var windowSeconds: Double
        public var windowMeters: Double
        public var gapSeconds: Double
        public var stopSpeedMps: Double
        public var altitudeWindow: Int
        public var heartRateTolerance: Double

        public init(maxSpeedMps: Double = 12, windowSeconds: Double = 20, windowMeters: Double = 50,
                    gapSeconds: Double = 30, stopSpeedMps: Double = 0.5, altitudeWindow: Int = 5,
                    heartRateTolerance: Double = 90) {
            self.maxSpeedMps = maxSpeedMps
            self.windowSeconds = windowSeconds
            self.windowMeters = windowMeters
            self.gapSeconds = gapSeconds
            self.stopSpeedMps = stopSpeedMps
            self.altitudeWindow = altitudeWindow
            self.heartRateTolerance = heartRateTolerance
        }

        public static let foot = Options()
        public static let cycling = Options(maxSpeedMps: 25, windowSeconds: 15, windowMeters: 80)
    }

    /// The cleaned track, one entry per kept fix in every array.
    public struct Track: Equatable, Sendable {
        public let fixes: [Fix]
        /// Cumulative metres from the start.
        public let meters: [Double]
        /// Cumulative moving seconds (pauses and gaps excluded).
        public let movingSeconds: [Double]
        /// Smoothed speed in m/s; nil while paused, stopped or across a gap.
        public let speed: [Double?]
        /// Smoothed altitude in metres; nil where the fix carried none.
        public let altitude: [Double?]
        /// Heart rate matched by time; nil where no reading lies within the tolerance.
        public let heartRate: [Double?]

        public var count: Int { fixes.count }
        public var totalMeters: Double { meters.last ?? 0 }
        public var hasAltitude: Bool { altitude.contains { $0 != nil } }
        public var hasHeartRate: Bool { heartRate.contains { $0 != nil } }

        /// The point `meters` along the route, interpolated between the fixes either side.
        public func coordinate(atMeters target: Double) -> (lat: Double, lon: Double)? {
            guard let first = fixes.first else { return nil }
            guard count > 1, target > 0 else { return (first.lat, first.lon) }
            let i = index(atMeters: target)
            guard i + 1 < count else { return (fixes[count - 1].lat, fixes[count - 1].lon) }
            let span = meters[i + 1] - meters[i]
            let f = span > 0 ? min(1, max(0, (target - meters[i]) / span)) : 0
            let a = fixes[i], b = fixes[i + 1]
            return (a.lat + (b.lat - a.lat) * f, a.lon + (b.lon - a.lon) * f)
        }

        /// Index of the last fix at or before `target` metres (binary search over the cumulative distance).
        public func index(atMeters target: Double) -> Int {
            var lo = 0, hi = count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if meters[mid] <= target { lo = mid } else { hi = mid - 1 }
            }
            return max(0, lo)
        }

        /// The same track restricted to `indices` (ascending), e.g. after simplification for drawing.
        public func subset(_ indices: [Int]) -> Track {
            let valid = indices.filter { $0 >= 0 && $0 < count }
            return Track(fixes: valid.map { fixes[$0] }, meters: valid.map { meters[$0] },
                         movingSeconds: valid.map { movingSeconds[$0] }, speed: valid.map { speed[$0] },
                         altitude: valid.map { altitude[$0] }, heartRate: valid.map { heartRate[$0] })
        }
    }

    // MARK: Geometry

    private static let earthR = 6_371_000.0

    public static func haversineMeters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * .pi / 180
        let dLon = (bLon - aLon) * .pi / 180
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(aLat * .pi / 180) * cos(bLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthR * 2 * atan2(sqrt(s), sqrt(max(0, 1 - s)))
    }

    // MARK: Cleaning

    /// Drops invalid and out-of-order fixes, then any fix reached faster than `maxSpeedMps` from the last kept one.
    public static func removeSpikes(_ fixes: [Fix], maxSpeedMps: Double) -> [Fix] {
        var out: [Fix] = []
        out.reserveCapacity(fixes.count)
        for f in fixes where f.lat.isFinite && f.lon.isFinite && f.t.isFinite
            && (-90...90).contains(f.lat) && (-180...180).contains(f.lon) {
            guard let last = out.last else { out.append(f); continue }
            let dt = f.t - last.t
            guard dt > 0 else { continue }
            let d = haversineMeters(last.lat, last.lon, f.lat, f.lon)
            if d / dt > maxSpeedMps { continue }
            out.append(f)
        }
        return out
    }

    // MARK: Build

    /// The cleaned, smoothed track. Fewer than two usable fixes give an empty track.
    public static func build(_ raw: [Fix], heartRate: [HeartRate] = [], options: Options = .foot) -> Track {
        let fixes = removeSpikes(raw, maxSpeedMps: options.maxSpeedMps)
        guard fixes.count >= 2 else {
            return Track(fixes: [], meters: [], movingSeconds: [], speed: [], altitude: [], heartRate: [])
        }
        let n = fixes.count
        var meters = [Double](repeating: 0, count: n)
        var gapBefore = [Bool](repeating: false, count: n)
        for i in 1..<n {
            meters[i] = meters[i - 1]
                + haversineMeters(fixes[i - 1].lat, fixes[i - 1].lon, fixes[i].lat, fixes[i].lon)
            gapBefore[i] = fixes[i].t - fixes[i - 1].t > options.gapSeconds
        }
        let speed = smoothedSpeed(fixes: fixes, meters: meters, gapBefore: gapBefore, options: options)
        var moving = [Double](repeating: 0, count: n)
        for i in 1..<n {
            let counts = !gapBefore[i] && (speed[i] != nil || speed[i - 1] != nil)
            moving[i] = moving[i - 1] + (counts ? fixes[i].t - fixes[i - 1].t : 0)
        }
        return Track(fixes: fixes, meters: meters, movingSeconds: moving, speed: speed,
                     altitude: smoothedAltitude(fixes.map(\.altitude), window: options.altitudeWindow),
                     heartRate: matchHeartRate(times: fixes.map(\.t), samples: heartRate,
                                               tolerance: options.heartRateTolerance))
    }

    /// Centred-window speed per fix, bounded by gaps; nil below `stopSpeedMps` or with no usable window.
    static func smoothedSpeed(fixes: [Fix], meters: [Double], gapBefore: [Bool], options: Options) -> [Double?] {
        let n = fixes.count
        var out = [Double?](repeating: nil, count: n)
        // Stretches of fixes with no gap inside: [start, end].
        var stretchStart = 0
        for end in 0..<n where end == n - 1 || gapBefore[end + 1] {
            for i in stretchStart...end {
                var j = i, k = i
                while true {
                    let dt = fixes[k].t - fixes[j].t
                    let dm = meters[k] - meters[j]
                    if dt >= options.windowSeconds && dm >= options.windowMeters { break }
                    // Cap the window so a stop is not averaged away by the running on either side.
                    if dt >= options.windowSeconds * 3 { break }
                    let canBack = j > stretchStart, canFwd = k < end
                    if !canBack && !canFwd { break }
                    // Grow on the side that keeps the window centred in time.
                    let backSpan = fixes[i].t - fixes[j].t, fwdSpan = fixes[k].t - fixes[i].t
                    if canBack && (!canFwd || backSpan <= fwdSpan) { j -= 1 } else { k += 1 }
                }
                let dt = fixes[k].t - fixes[j].t
                guard dt > 0 else { continue }
                let v = (meters[k] - meters[j]) / dt
                out[i] = v >= options.stopSpeedMps ? v : nil
            }
            stretchStart = end + 1
        }
        return out
    }

    /// Centred moving mean over the fixes that carry an altitude; nil stays nil.
    static func smoothedAltitude(_ values: [Double?], window: Int) -> [Double?] {
        let half = max(0, window / 2)
        return values.indices.map { i in
            guard values[i]?.isFinite == true else { return nil }
            let lo = max(0, i - half), hi = min(values.count - 1, i + half)
            let usable = values[lo...hi].compactMap { $0 }.filter(\.isFinite)
            return usable.isEmpty ? nil : usable.reduce(0, +) / Double(usable.count)
        }
    }

    /// Heart rate at each time: linear between the readings either side when both are within `tolerance`,
    /// else the nearer one within `tolerance`, else nil. `samples` need not be sorted.
    static func matchHeartRate(times: [Double], samples: [HeartRate], tolerance: Double) -> [Double?] {
        let hr = samples.filter { $0.t.isFinite && $0.bpm.isFinite && $0.bpm > 0 }.sorted { $0.t < $1.t }
        guard !hr.isEmpty else { return times.map { _ in nil } }
        return times.map { t in
            // First reading at or after t.
            var lo = 0, hi = hr.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if hr[mid].t < t { lo = mid + 1 } else { hi = mid }
            }
            let after = lo < hr.count ? hr[lo] : nil
            let before = lo > 0 ? hr[lo - 1] : nil
            switch (before, after) {
            case let (b?, a?) where t - b.t <= tolerance && a.t - t <= tolerance:
                let span = a.t - b.t
                return span > 0 ? b.bpm + (a.bpm - b.bpm) * (t - b.t) / span : a.bpm
            case let (b?, a?):
                let nearer = (t - b.t) <= (a.t - t) ? b : a
                return abs(nearer.t - t) <= tolerance ? nearer.bpm : nil
            case let (b?, nil): return t - b.t <= tolerance ? b.bpm : nil
            case let (nil, a?): return a.t - t <= tolerance ? a.bpm : nil
            case (nil, nil): return nil
            }
        }
    }
}
