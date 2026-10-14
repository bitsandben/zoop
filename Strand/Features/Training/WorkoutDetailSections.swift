import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Workout detail sections: numbers, heart rate, zones

extension WorkoutDetailView {

    // MARK: Number tiles

    /// Heart rate is a `MetricTile` once the sport has enough history to say what is typical; every other
    /// figure is a fact of this one session, so it shows value and unit without a verdict it cannot back.
    var tiles: some View {
        TileGrid {
            factTile(String(localized: "Duration"), format.duration(seconds: row.durationS))
            if let readout = model.avgHeartRateReadout() {
                MetricTile(readout)
            } else if let hr = row.avgHr {
                factTile(String(localized: "Avg HR"), String(localized: "\(hr) bpm"))
            }
            if let readout = model.maxHeartRateReadout() {
                MetricTile(readout)
            } else if let hr = row.maxHr {
                factTile(String(localized: "Max HR"), String(localized: "\(hr) bpm"))
            }
            if let kcal = row.energyKcal, kcal > 0 {
                factTile(String(localized: "Calories"), format.energy(kcal))
            }
            if let meters = row.distanceM, meters > 0 {
                factTile(String(localized: "Distance"), format.distance(meters: meters))
            }
            // Shown for every on-foot sport even before the count lands, so the tile does not pop in.
            if WorkoutCatalog.isOnFoot(row.sport) {
                factTile(String(localized: "Steps"),
                         model.steps.map { $0.count.formatted(.number.locale(AppLanguage.activeLocale)) } ?? "\u{2013}",
                         caption: model.steps.map { $0.fromStrap ? String(localized: "strap") : String(localized: "phone") })
            }
        }
    }

    private func factTile(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(ZoopType.metric)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(ZoopSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous).fill(StrandPalette.surfaceRaised))
        .accessibilityElement(children: .combine)
    }

    // MARK: Heart rate

    @ViewBuilder var heartRateCard: some View {
        if model.hrPoints.count > 1 {
            let values = model.hrPoints.map(\.value)
            ContentCard("zoop.training.detail.heartRate") {
                TrendChart(
                    points: model.hrPoints,
                    gradient: StrandPalette.effortGradient,
                    valueRange: max(0, (values.min() ?? 60) - 8)...((values.max() ?? 180) + 8),
                    showsArea: true,
                    valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                    dateFormat: { AppClock.hourMinuteFormatter().string(from: $0) },
                    accessibilityLabel: String(localized: "Heart rate during \(WorkoutSource.displaySport(row.sport))"),
                    workoutTimeAxis: Date(timeIntervalSince1970: TimeInterval(row.startTs))...Date(timeIntervalSince1970: TimeInterval(row.endTs))
                )
                .frame(height: ZoopMetrics.chartHeight)
                HStack(spacing: ZoopSpacing.m) {
                    heartRateStat("Avg", row.avgHr.map { Double($0) } ?? values.reduce(0, +) / Double(values.count))
                    heartRateStat("Peak", row.maxHr.map { Double($0) } ?? values.max() ?? 0)
                    heartRateStat("Low", values.min() ?? 0)
                }
                // The row's Avg HR can be EDITED on the manual sheet while the graph, zones and Effort stay
                // from the recorded session (#18). Say so when the typed average disagrees with the trace.
                if avgHrWasEdited(traceMean: values.reduce(0, +) / Double(values.count)) {
                    Text("The average above was edited. The graph, zones and Effort stay from the recorded session.")
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if model.loaded {
            ContentCard("zoop.training.detail.heartRate") {
                Text("No heart-rate samples were recorded over this session's window.")
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heartRateStat(_ label: LocalizedStringKey, _ bpm: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(String(localized: "\(Int(bpm.rounded())) bpm"))
                .font(ZoopType.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// True only when the row carries CAPTURED strain or zones (so the graph, zones and Effort are from a
    /// real recording) AND its Avg HR differs from the trace mean by more than rounding and bucketing drift.
    private func avgHrWasEdited(traceMean: Double) -> Bool {
        guard let avg = row.avgHr, row.strain != nil || row.zonesJSON != nil else { return false }
        return abs(Double(avg) - traceMean) > 3
    }

    // MARK: Zones

    @ViewBuilder var zonesCard: some View {
        if let minutes = model.zoneMinutes, minutes.reduce(0, +) > 0 {
            let total = minutes.reduce(0, +)
            ContentCard("HR Zones") {
                TrainingZoneBar(minutes: minutes, height: 24)
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { zoneStat($0 + 1, minutes: minutes[$0], total: total) }
                }
                Text(model.zonesFromImport ? TrainingStrings.zonesImported : TrainingStrings.zonesDerived)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text(verbatim: "Z\(zone)").font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Text(ZoopNumber.percent(minutes / max(total, 0.001) * 100))
                .font(ZoopType.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
            Text(format.duration(seconds: minutes * 60))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
