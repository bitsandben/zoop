#if os(iOS) && DEBUG
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Coloured route: DEBUG demo host
//
// `--demo-screen routemap` renders the coloured route card over a synthetic 5 km loop with easy and fast
// stretches, a stop, a pause gap, a GPS spike, rolling altitude and heart rate, so the map can be
// screenshotted on a simulator without recording a run. DEBUG builds only.

struct RouteMapDemoHost: View {
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    private static let start = 1_760_000_000
    private static let data = makeRoute()

    var body: some View {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        let row = WorkoutRow(startTs: Self.start, endTs: Self.start + 1_800, sport: "Running", source: "manual",
                             durationS: 1_700, energyKcal: 420, avgHr: 152, maxHr: 176, strain: 12,
                             distanceM: 5_000, zonesJSON: nil, notes: nil, steps: nil)
        // `-demo.routeMetric heartRate|altitude` picks the layer, `-demo.routeScroll bottom` shows the splits,
        // `-demo.routeFullScreen 1` opens the full-screen map.
        let metric = UserDefaults.standard.string(forKey: "demo.routeMetric")
            .flatMap(WorkoutRouteInsights.Metric.init(rawValue:)) ?? .pace
        ScrollViewReader { proxy in
            ScrollView {
                WorkoutRouteInsightsCard(row: row, points: Self.data.points, heartRate: Self.data.hr,
                                         zones: HRZones.zones(maxHR: 190), system: system,
                                         fallback: AnyView(ProgressView()), initialMetric: metric,
                                         initialFullScreen: UserDefaults.standard.bool(forKey: "demo.routeFullScreen"))
                    .padding(ZoopSpacing.gutter)
                Color.clear.frame(height: 1).id("bottom")
            }
            .task {
                guard UserDefaults.standard.string(forKey: "demo.routeScroll") == "bottom" else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Running")
    }

    /// An ellipse around a park, ~5 km, one fix every 2 s.
    private static func makeRoute() -> (points: [WorkoutRoutePoint], hr: [RouteTrack.HeartRate]) {
        let center = (lat: 52.5145, lon: 13.3501)
        let rx = 1_050.0, ry = 520.0                      // metres east / north
        let mPerDegLat = 111_320.0, mPerDegLon = 111_320.0 * cos(center.lat * .pi / 180)
        // (seconds, m/s): easy, fast, easy, stop, fast, easy.
        let stretches: [(Double, Double)] = [(300, 2.9), (240, 4.6), (200, 3.1), (40, 0.05), (220, 4.4), (500, 3.0)]
        var points: [WorkoutRoutePoint] = []
        var hr: [RouteTrack.HeartRate] = []
        var t = 0.0, angle = 0.0, bpm = 125.0
        for (index, (seconds, speed)) in stretches.enumerated() {
            if index == 4 { t += 90 }                     // a pause: no fixes for 90 s
            for _ in 0..<Int(seconds / 2) {
                t += 2
                let circumferenceStep = speed * 2 / (Double.pi * (rx + ry))
                angle += circumferenceStep * 2 * .pi
                let east = rx * sin(angle), north = ry * (1 - cos(angle))
                let alt = 42 + 9 * sin(angle * 2) + 4 * sin(angle * 5)
                points.append(WorkoutRoutePoint(lat: center.lat + north / mPerDegLat, lon: center.lon + east / mPerDegLon,
                                                accuracyM: 5, tMs: Int64((Double(start) + t) * 1000), altM: alt))
                bpm += ((110 + speed * 14) - bpm) * 0.04
                if Int(t) % 10 == 0 { hr.append(.init(t: Double(start) + t, bpm: bpm)) }
            }
        }
        // One GPS spike, 400 m off the route.
        if points.count > 120 {
            var spike = points[120]
            spike.lat += 400 / mPerDegLat
            spike.tMs += 500
            points.insert(spike, at: 121)
        }
        return (points, hr)
    }
}
#endif
