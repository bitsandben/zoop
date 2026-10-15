import Foundation
import StrandAnalytics

// MARK: - Coloured route: model
//
// Everything the coloured route card and its full-screen map draw, built once off the main actor from the
// stored GPS fixes and the session's heart rate: the cleaned track (`RouteTrack`), a simplified copy for
// drawing, one colour layer per metric (`RouteColoring`), split markers and rows (`RouteSplitTable`), and
// the chart series. All numbers are formatted here, in the user's units; the views only lay them out.

struct WorkoutRouteInsights {

    enum Metric: String, CaseIterable, Identifiable {
        case pace, heartRate, altitude
        var id: String { rawValue }
    }

    /// How a layer's buckets map to colour: a gradient across `buckets`, or the five heart-rate zones.
    enum Scale: Equatable { case gradient, zones }

    struct Layer {
        let metric: Metric
        let scale: Scale
        let runs: [RouteColoring.Run]
        let buckets: Int
        let lowLabel: String
        let highLabel: String
        let caption: String
    }

    struct Marker: Identifiable {
        let id: Int
        let lat: Double
        let lon: Double
        let label: String
    }

    /// One chart point: distance in the display unit and the metric's value (nil breaks the line).
    struct ChartPoint: Identifiable {
        let id: Int
        let distance: Double
        let value: Double?
        let segment: Int
    }

    struct SplitLine: Identifiable {
        let id: Int
        let label: String
        let time: String
        let pace: String
        let heartRate: String
        let climb: String
    }

    static let gradientBuckets = 12

    let track: RouteTrack.Track
    let display: RouteTrack.Track
    let layers: [Metric: Layer]
    let markers: [Marker]
    let splits: [SplitLine]
    let usesPace: Bool
    let system: UnitSystem
    private let charts: [Metric: [ChartPoint]]

    var metrics: [Metric] { Metric.allCases.filter { layers[$0] != nil } }
    func chart(_ metric: Metric) -> [ChartPoint] { charts[metric] ?? [] }

    /// The chart's y domain: the series' extent with a little headroom. Pace on foot is plotted negated
    /// (minutes per unit times -1) so faster sits higher without a reversed scale.
    func chartDomain(_ metric: Metric) -> ClosedRange<Double> {
        let values = chart(metric).compactMap(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.08, 0.5)
        return (lo - pad)...(hi + pad)
    }

    /// Display units per metre: kilometres or miles.
    var unitMeters: Double { system == .imperial ? WorkoutSplits.mile : WorkoutSplits.kilometer }
    var distanceUnit: String { UnitFormatter.distanceUnit(system) }

    // MARK: Build

    /// Nil when fewer than two fixes survive cleaning, or the fixes carry no time (legacy routes).
    static func build(points: [WorkoutRoutePoint], heartRate: [RouteTrack.HeartRate], zones: HRZoneSet,
                      onFoot: Bool, system: UnitSystem) -> WorkoutRouteInsights? {
        let fixes = points.filter { $0.tMs > 0 }.map {
            RouteTrack.Fix(lat: $0.lat, lon: $0.lon, t: Double($0.tMs) / 1000, altitude: $0.altM)
        }
        let track = RouteTrack.build(fixes, heartRate: heartRate, options: onFoot ? .foot : .cycling)
        guard track.count >= 2 else { return nil }
        let kept = RouteSimplify.capped(lat: track.fixes.map(\.lat), lon: track.fixes.map(\.lon),
                                        toleranceMeters: 2, maxPoints: 1500)
        let display = track.subset(kept)
        let format = RouteFormat(system: system, onFoot: onFoot)

        var layers: [Metric: Layer] = [:]
        var charts: [Metric: [ChartPoint]] = [:]
        if let range = RouteColoring.percentileRange(track.speed.compactMap { $0 }) {
            layers[.pace] = Layer(metric: .pace, scale: .gradient,
                                  runs: RouteColoring.runs(points: display.speed, range: range, buckets: gradientBuckets),
                                  buckets: gradientBuckets,
                                  lowLabel: format.speed(range.lowerBound), highLabel: format.speed(range.upperBound),
                                  caption: RouteStrings.paceCaption)
            charts[.pace] = series(track, unitMeters: format.unitMeters) { i in
                // Clamped to the colour range so a stop or spike does not flatten the curve.
                track.speed[i].map { v in
                    let y = format.chartValue(speed: min(max(v, range.lowerBound), range.upperBound))
                    return onFoot ? -y : y
                }
            }
        }
        if track.hasHeartRate {
            let bpm = track.heartRate.compactMap { $0 }
            layers[.heartRate] = Layer(metric: .heartRate, scale: .zones,
                                       runs: RouteColoring.discreteRuns(points: display.heartRate) {
                                           max(0, zones.zoneNumber(forBPM: $0) - 1)
                                       },
                                       buckets: 5,
                                       lowLabel: format.bpm(bpm.min() ?? 0), highLabel: format.bpm(bpm.max() ?? 0),
                                       caption: RouteStrings.heartRateCaption)
            charts[.heartRate] = series(track, unitMeters: format.unitMeters) { track.heartRate[$0] }
        }
        if track.hasAltitude, let range = RouteColoring.percentileRange(track.altitude.compactMap { $0 }, low: 0, high: 1) {
            layers[.altitude] = Layer(metric: .altitude, scale: .gradient,
                                      runs: RouteColoring.runs(points: display.altitude, range: range, buckets: gradientBuckets),
                                      buckets: gradientBuckets,
                                      lowLabel: format.altitude(range.lowerBound), highLabel: format.altitude(range.upperBound),
                                      caption: RouteStrings.altitudeCaption)
            charts[.altitude] = series(track, unitMeters: format.unitMeters) { track.altitude[$0].map(format.altitudeValue) }
        }

        let splitRows = RouteSplitTable.rows(track, splitMeters: format.unitMeters)
        let markers = RouteSplitTable.markerDistances(totalMeters: track.totalMeters, splitMeters: format.unitMeters)
            .enumerated().compactMap { i, m -> Marker? in
                track.coordinate(atMeters: m).map { Marker(id: i + 1, lat: $0.lat, lon: $0.lon, label: "\(i + 1)") }
            }
        return WorkoutRouteInsights(
            track: track, display: display, layers: layers, markers: markers,
            splits: splitRows.map { format.line($0) }, usesPace: onFoot, system: system, charts: charts)
    }

    /// At most ~300 chart points; a nil value starts a new line segment so a pause is a visible break.
    private static func series(_ track: RouteTrack.Track, unitMeters: Double,
                               value: (Int) -> Double?) -> [ChartPoint] {
        let stride = max(1, track.count / 300)
        var out: [ChartPoint] = []
        var segment = 0
        var lastWasNil = false
        for i in Swift.stride(from: 0, to: track.count, by: stride) {
            let v = value(i)
            if v == nil { if !lastWasNil { segment += 1 }; lastWasNil = true; continue }
            lastWasNil = false
            out.append(ChartPoint(id: i, distance: track.meters[i] / unitMeters, value: v, segment: segment))
        }
        return out
    }

    // MARK: Scrub

    /// The route position and a readout for a chart selection at `distance` display units.
    func selection(at distance: Double, metric: Metric) -> (lat: Double, lon: Double, text: String)? {
        let meters = min(max(0, distance * unitMeters), track.totalMeters)
        guard let c = track.coordinate(atMeters: meters) else { return nil }
        let i = track.index(atMeters: meters)
        let format = RouteFormat(system: system, onFoot: usesPace)
        let where_ = format.distance(meters)
        let value: String?
        switch metric {
        case .pace: value = track.speed[i].map(format.speed)
        case .heartRate: value = track.heartRate[i].map(format.bpm)
        case .altitude: value = track.altitude[i].map(format.altitude)
        }
        return (c.lat, c.lon, [where_, value].compactMap { $0 }.joined(separator: " \u{00B7} "))
    }
}

// MARK: - Formatting (user's units, app locale)

struct RouteFormat {
    let system: UnitSystem
    let onFoot: Bool

    private var locale: Locale { AppLanguage.activeLocale }
    var unitMeters: Double { system == .imperial ? WorkoutSplits.mile : WorkoutSplits.kilometer }

    /// Pace ("5:12 /km") on foot, speed ("24,3 km/h") otherwise, from metres per second.
    func speed(_ mps: Double) -> String {
        guard mps > 0 else { return "\u{2013}" }
        if onFoot { return UnitFormatter.paceFromSecPerKm(1000 / mps, system: system) }
        return UnitFormatter.speedFromKilometersPerHour(mps * 3.6, system: system).map(localized) ?? "\u{2013}"
    }

    /// The chart's y value: minutes per display unit on foot, km/h or mph otherwise.
    func chartValue(speed mps: Double) -> Double {
        guard mps > 0 else { return 0 }
        if onFoot { return unitMeters / mps / 60 }
        return system == .imperial ? UnitFormatter.kmToMiles(mps * 3.6) : mps * 3.6
    }

    func bpm(_ value: Double) -> String { "\(Int(value.rounded()))\u{00A0}bpm" }

    func altitudeValue(_ meters: Double) -> Double { system == .imperial ? meters * 3.28084 : meters }

    func altitude(_ meters: Double) -> String {
        Int(altitudeValue(meters).rounded()).formatted(.number.locale(locale))
            + (system == .imperial ? "\u{00A0}ft" : "\u{00A0}m")
    }

    func distance(_ meters: Double) -> String {
        ZoopNumber.decimal(meters / unitMeters, digits: 2) + "\u{00A0}" + UnitFormatter.distanceUnit(system)
    }

    func clock(_ seconds: Double) -> String { WorkoutSplits.clock(seconds) ?? "\u{2013}" }

    func line(_ row: RouteSplitTable.Row) -> WorkoutRouteInsights.SplitLine {
        let partial = row.meters < unitMeters - 1
        let label = partial ? ZoopNumber.decimal(row.meters / unitMeters, digits: 2) : "\(row.index)"
        let pace = row.pace(unitMeters: unitMeters).map { secPerUnit -> String in
            onFoot ? (WorkoutSplits.clock(secPerUnit) ?? "\u{2013}") : speedNumber(unitMeters / secPerUnit)
        } ?? "\u{2013}"
        return .init(id: row.index, label: label, time: clock(row.seconds), pace: pace,
                     heartRate: row.averageHeartRate.map { "\(Int($0.rounded()))" } ?? "\u{2013}",
                     climb: row.elevationGain.map { Int(altitudeValue($0).rounded()).formatted(.number.locale(locale)) }
                        ?? "\u{2013}")
    }

    /// Speed number without unit for the split table ("24,3").
    private func speedNumber(_ mps: Double) -> String { ZoopNumber.decimal(chartValue(speed: mps)) }

    /// `UnitFormatter` prints a POSIX decimal point; swap it for the locale's separator.
    private func localized(_ s: String) -> String {
        let sep = locale.decimalSeparator ?? "."
        return sep == "." ? s : s.replacingOccurrences(of: ".", with: sep)
    }
}
