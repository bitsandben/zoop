import SwiftUI
import StrandDesign
import StrandImport
import WhoopStore

// MARK: - GPS route (#524)
//
// The captured-route card: a map of the polyline with start and end markers, distance and pace read off
// the route, and a GPX/FIT export. Shown ONLY when at least two points were captured, so there is an
// honest "no map" on a Mac with no GPS, with permission denied, or for a sport without distance.

extension WorkoutDetailView {

    @ViewBuilder var routeCard: some View {
        if model.route.count >= 2 {
            RouteCard(row: row, route: model.route, format: format)
        }
    }
}

private struct RouteCard: View {
    let row: WorkoutRow
    let route: [RouteMath.LatLng]
    let format: TrainingFormat

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @State private var showExport = false

    var body: some View {
        ContentCard("Route") {
            WorkoutRouteMap(points: route)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
                .accessibilityLabel(String(localized: "Map of your \(WorkoutSource.displaySport(row.sport)) route, \(format.distance(meters: row.distanceM))."))
            HStack(spacing: ZoopSpacing.m) {
                stat(String(localized: "Distance"), format.distance(meters: row.distanceM))
                stat(String(localized: "Avg pace"), paceLabel)
                stat(String(localized: "Points"), route.count.formatted(.number.locale(AppLanguage.activeLocale)))
            }
            Text(description)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showExport = true
            } label: {
                Label("Export route", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
            .confirmationDialog("Export route", isPresented: $showExport, titleVisibility: .visible) {
                Button("GPX — Strava, Garmin, most apps") { export(.gpx) }
                Button("FIT — Garmin Connect") { export(.fit) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Save this route as a standard file you can import into Strava, Garmin Connect, and other apps.")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(ZoopType.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Average pace from the row's GPS distance and duration, in the user's unit system. An en dash when
    /// either is missing, because the pace is then undefined.
    private var paceLabel: String {
        guard let meters = row.distanceM, meters > 0 else { return "\u{2013}" }
        let seconds = row.durationS ?? Double(row.endTs - row.startTs)
        guard seconds > 0 else { return "\u{2013}" }
        let system = UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                               override: distanceSystemRaw)
        return UnitFormatter.paceFromSecPerKm(seconds / (meters / 1000), system: system)
    }

    /// #1205: honest about where the route came from. An imported route (Apple Health, Health Connect) must
    /// not be described as recorded by this phone.
    private var description: String {
        switch WorkoutSource.classify(row.source) {
        case .apple, .whoop, .lifting, .activityFile:
            return String(localized: "This stays on your device. It is never uploaded, never synced, never shared.")
        case .detected, .manual:
            return String(localized: "Your GPS route for this session, recorded and stored on your device. Nothing leaves your phone.")
        }
    }

    /// Write the route to a GPX/FIT file and hand it to the system share sheet. Points are the stored
    /// polyline (lat/lon only), so the exporter interpolates per-point times across the session window and
    /// carries the workout's summary. The encode and the disk write run off the main actor; only the
    /// share-sheet present hops back.
    @MainActor private func export(_ format: RouteExporter.Format) {
        let points = route.map { RoutePoint(lat: $0.lat, lon: $0.lon) }
        // Named by the workout's start, not the export time, so re-exporting gives the same name.
        let name = "zoop-route-\(row.startTs).\(format.ext)"
        let row = row
        Task.detached(priority: .userInitiated) {
            let data = RouteExporter.render(
                format, route: points, startTs: row.startTs, endTs: row.endTs, sport: row.sport,
                distanceM: row.distanceM, energyKcal: row.energyKcal, avgHr: row.avgHr, maxHr: row.maxHr)
            let url = ZoopScratch.file(name)
            do { try data.write(to: url) } catch { return }
            await MainActor.run { FileExport.exportFile(at: url, suggestedName: name) }
        }
    }
}
