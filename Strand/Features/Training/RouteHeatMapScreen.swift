import SwiftUI
import StrandDesign
import StrandAnalytics
#if os(iOS)
import MapKit
#endif

// MARK: - My routes (route heat map)
//
// Every GPS route of the last 90 days on one map, each drawn faintly so stretches run often build up into
// a strong line. Routes come from `RouteStore` (polyline only, already on the device); each is simplified
// with Douglas-Peucker and the whole set is capped so the map stays fast with hundreds of runs.

enum RouteHeat {

    static let windowDays = 90
    static let maxPointsPerRoute = 300
    static let maxTotalPoints = 30_000

    /// Keys of the stored routes that started within the window, newest first.
    static func recentKeys(_ map: [String: WorkoutRoute], now: Date = Date()) -> [String] {
        let cutoff = Int(now.timeIntervalSince1970) - windowDays * 86_400
        return map.keys
            .compactMap { key -> (String, Int)? in
                guard let ts = Int(key.split(separator: "|").first ?? ""), ts >= cutoff else { return nil }
                return (key, ts)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Number of recent routes, for the Training page's entry row (cheap: no polyline decode).
    static func recentCount(defaults: UserDefaults = .standard) -> Int {
        recentKeys(RouteStore.loadMap(from: defaults)).count
    }

    /// Simplified recent routes as lat/lon lines, within the per-route and total point caps.
    static func lines(_ map: [String: WorkoutRoute], now: Date = Date()) -> [[RouteMath.LatLng]] {
        var out: [[RouteMath.LatLng]] = []
        var total = 0
        for key in recentKeys(map, now: now) {
            guard let route = map[key] else { continue }
            let pts = RouteMath.decode(route.polyline)
            guard pts.count >= 2 else { continue }
            let kept = RouteSimplify.capped(lat: pts.map(\.lat), lon: pts.map(\.lon),
                                            toleranceMeters: 6, maxPoints: maxPointsPerRoute)
            guard total + kept.count <= maxTotalPoints else { break }
            total += kept.count
            out.append(kept.map { pts[$0] })
        }
        return out
    }
}

#if os(iOS)
struct RouteHeatMapScreen: View {
    @State private var lines: [[RouteMath.LatLng]] = []
    @State private var loaded = false
    @State private var position: MapCameraPosition = .automatic
    @State private var satellite = false

    var body: some View {
        ScreenScaffold(title: "\(RouteStrings.heatTitle)") {
            ContentCard(subtitle: loaded ? RouteStrings.heatSubtitle(lines.count) : nil) {
                map
                    .frame(height: 460)
                    .clipShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
                Picker(RouteStrings.mapStandard, selection: $satellite) {
                    Text(RouteStrings.mapStandard).tag(false)
                    Text(RouteStrings.mapSatellite).tag(true)
                }
                .pickerStyle(.segmented)
                Text(RouteStrings.heatCaption)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private var map: some View {
        Map(position: $position) {
            ForEach(lines.indices, id: \.self) { i in
                MapPolyline(coordinates: lines[i].map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(StrandPalette.zone5.opacity(0.35),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(satellite ? .hybrid(elevation: .flat) : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityLabel(RouteStrings.heatSubtitle(lines.count))
    }

    private func load() async {
        let result = await Task.detached(priority: .userInitiated) {
            RouteHeat.lines(RouteStore.loadMap())
        }.value
        lines = result
        loaded = true
        // Frame the newest route's area so the map opens where the user runs, not over the whole world.
        if let newest = result.first {
            position = WorkoutRouteColorMap.framing(newest.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
        }
    }
}

/// Training page entry to the heat map, shown once at least two GPS routes exist in the window.
struct RouteHeatEntry: View {
    @State private var count = 0

    var body: some View {
        Group {
            if count >= 2 {
                NavigationLink { RouteHeatMapScreen() } label: {
                    ContentCard(LocalizedStringKey(RouteStrings.heatTitle), subtitle: RouteStrings.heatSubtitle(count),
                                showsChevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            }
        }
        .task { count = RouteHeat.recentCount() }
    }
}
#endif
